//
//  ProposalService.swift
//  Intelligence/Planning
//
//  6.2 主流水线：C2 隐私分流 → C3 本地直执 → C4 上下文 → C5 调用 → C6 校验 → C7 策略。
//  C1 落库与 C8 提交由 App 层经 `DomainCommand` 完成（唯一写入口）。
//  任何一步失败：原文已落库，可重试、可手动整理；不得丢失已输入原文（REQ 02）。
//

import Foundation

// MARK: - 请求快照

/// 一次整理的输入快照。全部为值类型，便于跨 actor 传递与测试复现。
public struct ProposalRequest: Sendable {

    public var captureID: UUID?
    public var rawText: String
    public var editedText: String?
    public var inputMode: InputMode
    public var today: DateOnly
    public var timeZone: TimeZone
    public var localeIdentifier: String
    public var deviceId: String
    public var source: SourceKind

    public var plans: [Plan]
    public var stagesByPlan: [UUID: [Stage]]
    public var metricsByPlan: [UUID: [PlanMetric]]
    public var tasksByPlan: [UUID: [Task]]
    public var occurrencesByTask: [UUID: [RecurrenceOccurrence]]
    public var preferredPlanID: UUID?

    public init(captureID: UUID? = nil,
                rawText: String,
                editedText: String? = nil,
                inputMode: InputMode = .text,
                today: DateOnly,
                timeZone: TimeZone,
                localeIdentifier: String = "zh-Hans",
                deviceId: String,
                source: SourceKind = .ai,
                plans: [Plan],
                stagesByPlan: [UUID: [Stage]] = [:],
                metricsByPlan: [UUID: [PlanMetric]] = [:],
                tasksByPlan: [UUID: [Task]] = [:],
                occurrencesByTask: [UUID: [RecurrenceOccurrence]] = [:], preferredPlanID: UUID? = nil) {
        self.captureID = captureID; self.rawText = rawText; self.editedText = editedText
        self.inputMode = inputMode; self.today = today; self.timeZone = timeZone
        self.localeIdentifier = localeIdentifier; self.deviceId = deviceId; self.source = source
        self.plans = plans; self.stagesByPlan = stagesByPlan; self.metricsByPlan = metricsByPlan
        self.tasksByPlan = tasksByPlan; self.occurrencesByTask = occurrencesByTask
        self.preferredPlanID = preferredPlanID
    }

    /// 用户编辑过就用编辑后的文本（REQ 02：编辑不影响原文留存）
    public var effectiveText: String { editedText ?? rawText }
}

// MARK: - 结果

public struct ProposalPreparation: Sendable {

    public var captureID: UUID?
    public var input: AIInput?
    public var proposal: AIProposal?
    public var validated: ValidatedProposal
    public var usage: AIUsageRecord?
    public var skippedCloudCall: Bool
    public var error: MovoError?
    /// 以下为提交后的事实，不以可执行命令数量冒充成功数量。
    public var appliedOperations: [Operation] = []
    public var commitRejections: [BatchRejection] = []
    public var undoSummary: String?

    public init(captureID: UUID? = nil,
                input: AIInput? = nil,
                proposal: AIProposal? = nil,
                validated: ValidatedProposal = ValidatedProposal(),
                usage: AIUsageRecord? = nil,
                skippedCloudCall: Bool = false,
                error: MovoError? = nil) {
        self.captureID = captureID; self.input = input; self.proposal = proposal
        self.validated = validated; self.usage = usage; self.skippedCloudCall = skippedCloudCall
        self.error = error
    }

    /// 可自动执行并撤销的命令（已含校验修正）
    public var autoCommands: [any DomainCommand] { validated.commands }

    /// 需要用户确认的提议
    public var pendingProposals: [PendingProposal] { validated.needsConfirmation }

    /// 校验未过项
    public var rejectedIssues: [ProposalIssue] { validated.issues }

    public var needsConfirmation: Bool { !validated.needsConfirmation.isEmpty }

    public var hasWork: Bool {
        !autoCommands.isEmpty || !pendingProposals.isEmpty || !rejectedIssues.isEmpty
    }

    /// 部分完成：有错误、有待确认、或有需要补充信息的项
    public var isPartial: Bool {
        if undoSummary != nil { return false }
        return error != nil || needsConfirmation || !rejectedIssues.isEmpty || !commitRejections.isEmpty
            || validated.truncationNotice != nil
    }

    /// 结果条文案（C9 结果态）
    public var resultMessage: String {
        if let undoSummary { return undoSummary }
        let applied = appliedOperations.count
        if error != nil {
            return applied > 0 ? "已整理 \(applied) 项，其余稍后可重试" : "原文已保存，稍后可重试"
        }
        if isPartial {
            return ExecutionPolicy.partialResultMessage(
                appliedCount: applied,
                pendingCount: pendingProposals.count,
                rejectedCount: rejectedIssues.count + commitRejections.count)
        }
        return ExecutionPolicy.autoResultMessage(appliedCount: applied)
    }
}

// MARK: - 服务

public struct ProposalService: Sendable {

    private let provider: any AIProvider
    private let defaults: AppDefaults
    private let logger: RedactedLogger

    public init(provider: any AIProvider,
                defaults: AppDefaults = .fallback,
                logger: RedactedLogger = RedactedLogger()) {
        self.provider = provider
        self.defaults = defaults
        self.logger = logger
    }

    /// 生产入口：按厂商装配适配器。自定义厂商未配置完整时抛 `MovoError.providerNotConfigured`。
    public static func make(vendor: AIVendor,
                            keyStore: any AIKeyStore,
                            catalog: ModelCatalog = ConfigLoader.loadModelCatalog(),
                            custom: CustomProviderConfig = .empty,
                            defaults: AppDefaults = ConfigLoader.loadDefaults(),
                            model: String? = nil,
                            transport: AITransport? = nil,
                            logger: RedactedLogger = RedactedLogger()) throws -> ProposalService {
        let resolved = try AIProviderResolver.resolve(vendor: vendor, catalog: catalog,
                                                      custom: custom, model: model)
        let provider = OpenAICompatibleAdapter(resolved: resolved, keyStore: keyStore,
                                               defaults: defaults, transport: transport)
        return ProposalService(provider: provider, defaults: defaults, logger: logger)
    }

    public var vendor: AIVendor { provider.id }
    public var model: String { provider.currentModel }

    // MARK: 流水线

    /// 执行提议生成与校验。产出交由用户预览确认后落地。
    public func prepare(_ request: ProposalRequest) async -> ProposalPreparation {
        let text = request.effectiveText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return ProposalPreparation(captureID: request.captureID, skippedCloudCall: true)
        }

        // 上下文构建
        var input = AIContextBuilder.build(sendableText: request.effectiveText,
                                           today: request.today,
                                           timeZone: request.timeZone,
                                           plans: request.plans,
                                           tasksByPlan: request.tasksByPlan,
                                           stagesByPlan: request.stagesByPlan,
                                           metricsByPlan: request.metricsByPlan,
                                           occurrencesByTask: request.occurrencesByTask,
                                           defaults: defaults,
                                           localeIdentifier: request.localeIdentifier)
        if let id = request.preferredPlanID, input.allowedPlanIDs.contains(id) {
            input.instructions += "\n用户为本次新增待办指定了计划 plan_id=\(id.uuidString)。"
        }

        // 调用模型
        let started = Date()
        do {
            var proposal = try await provider.proposeOperations(input)
            guard !proposal.isEmpty else {
                throw MovoError.invalidStructure(reason: "AI 没有返回可处理的事项，尚未创建内容。原文已保留，可以重试或编辑。")
            }
            if let selected = request.preferredPlanID, input.allowedPlanIDs.contains(selected) {
                for index in proposal.items.indices where proposal.items[index].action == .createTask {
                    proposal.items[index].task?.planId = selected.uuidString
                }
            }
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

            // 校验
            let allTasks = request.tasksByPlan.values.flatMap { $0 }
            let tasksByID = Dictionary(allTasks.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
            var metricsByID: [UUID: PlanMetric] = [:]
            for metric in request.metricsByPlan.values.flatMap({ $0 }) { metricsByID[metric.id] = metric }
            var occurrencesByID: [UUID: RecurrenceOccurrence] = [:]
            for occurrence in request.occurrencesByTask.values.flatMap({ $0 }) { occurrencesByID[occurrence.id] = occurrence }

            let validated = ProposalValidator.validate(proposal: proposal,
                                                       input: input,
                                                       plans: request.plans,
                                                       tasks: tasksByID,
                                                       metrics: metricsByID,
                                                       occurrences: occurrencesByID,
                                                       today: request.today,
                                                       timeZone: request.timeZone,
                                                       defaults: defaults,
                                                       deviceId: request.deviceId,
                                                       captureID: request.captureID,
                                                       source: request.source)

            let usage = AIUsageRecord(provider: provider.id.rawValue,
                                      model: provider.currentModel,
                                      promptTokens: proposal.promptTokens ?? 0,
                                      completionTokens: proposal.completionTokens ?? 0,
                                      latencyMs: proposal.latencyMs ?? elapsedMs,
                                      status: AIUsageRecord.successStatus,
                                      date: Date())

            // 只记录元数据，不含任何正文
            logger.logAICall(provider: provider.id.rawValue, model: provider.currentModel,
                             status: AIUsageRecord.successStatus, latencyMs: usage.latencyMs,
                             promptTokens: usage.promptTokens, completionTokens: usage.completionTokens,
                             itemCount: proposal.items.count, rejectedCount: validated.issues.count)
            logger.logValidation(rejectedCount: validated.issues.count,
                                 mergedDuplicates: validated.mergedDuplicates,
                                 correctionCount: validated.corrections.count)

            return ProposalPreparation(captureID: request.captureID,
                                       input: input,
                                       proposal: proposal,
                                       validated: validated,
                                       usage: usage)
        } catch let error as MovoError {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            logger.logAICall(provider: provider.id.rawValue, model: provider.currentModel,
                             status: error.title, latencyMs: elapsedMs,
                             promptTokens: 0, completionTokens: 0, itemCount: 0, rejectedCount: 0)
            return ProposalPreparation(captureID: request.captureID,
                                       input: input,
                                       error: error)
        } catch {
            return ProposalPreparation(captureID: request.captureID,
                                       input: input,
                                       error: .aiFailed(stage: .unknown, cause: "unexpected"))
        }
    }
        } catch let error as MovoError {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            logger.logAICall(provider: provider.id.rawValue, model: provider.currentModel,
                             status: error.title, latencyMs: elapsedMs,
                             promptTokens: 0, completionTokens: 0, itemCount: 0, rejectedCount: 0)
            return ProposalPreparation(captureID: request.captureID,
                                       privacy: privacy,
                                       localMatches: localMatches,
                                       input: input,
                                       error: error)
        } catch {
            return ProposalPreparation(captureID: request.captureID,
                                       privacy: privacy,
                                       localMatches: localMatches,
                                       input: input,
                                       error: .aiFailed(stage: .unknown, cause: "unexpected"))
        }
    }
}
