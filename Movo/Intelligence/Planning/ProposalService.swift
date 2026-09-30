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
                occurrencesByTask: [UUID: [RecurrenceOccurrence]] = [:]) {
        self.captureID = captureID; self.rawText = rawText; self.editedText = editedText
        self.inputMode = inputMode; self.today = today; self.timeZone = timeZone
        self.localeIdentifier = localeIdentifier; self.deviceId = deviceId; self.source = source
        self.plans = plans; self.stagesByPlan = stagesByPlan; self.metricsByPlan = metricsByPlan
        self.tasksByPlan = tasksByPlan; self.occurrencesByTask = occurrencesByTask
    }

    /// 用户编辑过就用编辑后的文本（REQ 02：编辑不影响原文留存）
    public var effectiveText: String { editedText ?? rawText }
}

// MARK: - 结果

public struct ProposalPreparation: Sendable {

    public var captureID: UUID?
    public var privacy: PrivacySplitResult
    public var localMatches: [LocalDirectMatch]
    public var input: AIInput?
    public var proposal: AIProposal?
    public var validated: ValidatedProposal
    public var usage: AIUsageRecord?
    public var skippedCloudCall: Bool
    public var privacyViolations: [String]
    public var error: MovoError?

    public init(captureID: UUID? = nil,
                privacy: PrivacySplitResult,
                localMatches: [LocalDirectMatch] = [],
                input: AIInput? = nil,
                proposal: AIProposal? = nil,
                validated: ValidatedProposal = ValidatedProposal(),
                usage: AIUsageRecord? = nil,
                skippedCloudCall: Bool = false,
                privacyViolations: [String] = [],
                error: MovoError? = nil) {
        self.captureID = captureID; self.privacy = privacy; self.localMatches = localMatches
        self.input = input; self.proposal = proposal; self.validated = validated
        self.usage = usage; self.skippedCloudCall = skippedCloudCall
        self.privacyViolations = privacyViolations; self.error = error
    }

    /// 可自动执行并撤销的命令（已含校验修正）
    public var autoCommands: [any DomainCommand] { validated.commands }

    /// 本地可确定项（不发云、可直接提交）
    public var deterministicLocalMatches: [LocalDirectMatch] {
        localMatches.filter { $0.kind.isDeterministic && $0.command != nil }
    }

    /// 需要用户确认的提议
    public var pendingProposals: [PendingProposal] { validated.needsConfirmation }

    /// 校验未过项（进收件箱）
    public var rejectedIssues: [ProposalIssue] { validated.issues }

    public var needsConfirmation: Bool { !validated.needsConfirmation.isEmpty }

    public var hasWork: Bool {
        !autoCommands.isEmpty || !deterministicLocalMatches.isEmpty
            || !pendingProposals.isEmpty || !rejectedIssues.isEmpty
    }

    /// 部分完成：有错误、有待确认、或有需要补充信息的项
    public var isPartial: Bool {
        error != nil || needsConfirmation || !rejectedIssues.isEmpty
    }

    /// 结果条文案（C9 结果态）
    public var resultMessage: String {
        let applied = autoCommands.count + deterministicLocalMatches.count
        if error != nil {
            return applied > 0 ? "已整理 \(applied) 项，其余稍后可重试" : "原文已保存，稍后可重试"
        }
        if needsConfirmation || !rejectedIssues.isEmpty {
            return ExecutionPolicy.partialResultMessage(
                appliedCount: applied,
                pendingCount: pendingProposals.count,
                rejectedCount: rejectedIssues.count)
        }
        return ExecutionPolicy.autoResultMessage(appliedCount: applied)
    }
}

// MARK: - 服务

public struct ProposalService: Sendable {

    private let provider: any AIProvider
    private let defaults: AppDefaults
    private let healthKeywords: [String]
    private let logger: RedactedLogger

    public init(provider: any AIProvider,
                defaults: AppDefaults = .fallback,
                healthKeywords: [String]? = nil,
                logger: RedactedLogger = RedactedLogger()) {
        self.provider = provider
        self.defaults = defaults
        self.healthKeywords = healthKeywords ?? ConfigLoader.loadHealthKeywords()
        self.logger = logger
    }

    /// 生产入口：按厂商装配适配器
    public static func make(vendor: AIVendor,
                            keyStore: any AIKeyStore,
                            catalog: ModelCatalog = ConfigLoader.loadModelCatalog(),
                            defaults: AppDefaults = ConfigLoader.loadDefaults(),
                            model: String? = nil,
                            transport: AITransport? = nil,
                            logger: RedactedLogger = RedactedLogger()) -> ProposalService {
        let provider: any AIProvider
        switch vendor {
        case .openai:
            provider = OpenAIAdapter(keyStore: keyStore, catalog: catalog,
                                     defaults: defaults, model: model, transport: transport)
        case .claude:
            provider = ClaudeAdapter(keyStore: keyStore, catalog: catalog,
                                     defaults: defaults, model: model, transport: transport)
        }
        return ProposalService(provider: provider, defaults: defaults, logger: logger)
    }

    public var vendor: AIVendor { provider.id }
    public var model: String { provider.currentModel }

    // MARK: 流水线

    /// 执行 C2–C7。产出交由调用方经 `DomainCommand` 落地（C8）。
    public func prepare(_ request: ProposalRequest) async -> ProposalPreparation {
        // C2 隐私分流
        let excludedTermsByPlan = Dictionary(request.plans.map { ($0.id, $0.excludedTerms) },
                                             uniquingKeysWith: { first, _ in first })
        let privacy = PrivacySplitter.split(text: request.effectiveText,
                                           plans: request.plans,
                                           healthKeywords: healthKeywords,
                                           excludedTermsByPlan: excludedTermsByPlan)

        // C3 本地确定性直执（不发云）
        let allTasks = request.tasksByPlan.values.flatMap { $0 }
        let allOccurrences = request.occurrencesByTask.values.flatMap { $0 }
        let localMatches = LocalDirectRouter.route(privacy: privacy,
                                                   plans: request.plans,
                                                   tasks: allTasks,
                                                   occurrences: allOccurrences,
                                                   today: request.today,
                                                   now: Date(),
                                                   source: request.source,
                                                   captureID: request.captureID)

        // 无可发送内容 → 不调用云（6.3 硬约束）
        guard privacy.hasSendableContent else {
            return ProposalPreparation(captureID: request.captureID,
                                       privacy: privacy,
                                       localMatches: localMatches,
                                       skippedCloudCall: true)
        }

        // C4 上下文构建
        let input = AIContextBuilder.build(sendableText: privacy.sendableText,
                                           today: request.today,
                                           timeZone: request.timeZone,
                                           plans: request.plans,
                                           tasksByPlan: request.tasksByPlan,
                                           stagesByPlan: request.stagesByPlan,
                                           metricsByPlan: request.metricsByPlan,
                                           occurrencesByTask: request.occurrencesByTask,
                                           defaults: defaults,
                                           localeIdentifier: request.localeIdentifier)

        // AC16 发送前二次断言
        let restrictedPlans = request.plans.filter { !$0.cloudAIEnabled || $0.status != .active }
        let violations = AIContextBuilder.assertNoRestrictedContent(input: input,
                                                                   restrictedPlans: restrictedPlans,
                                                                   restrictedTitles: [],
                                                                   restrictedKeywords: healthKeywords)
        guard violations.isEmpty else {
            logger.logValidation(rejectedCount: violations.count, mergedDuplicates: 0, correctionCount: 0)
            return ProposalPreparation(captureID: request.captureID,
                                       privacy: privacy,
                                       localMatches: localMatches,
                                       input: input,
                                       skippedCloudCall: true,
                                       privacyViolations: violations)
        }

        // C5 调用模型
        let started = Date()
        do {
            let proposal = try await provider.proposeOperations(input)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

            // C6 校验
            let tasksByID = Dictionary(allTasks.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
            var metricsByID: [UUID: PlanMetric] = [:]
            for metric in request.metricsByPlan.values.flatMap({ $0 }) { metricsByID[metric.id] = metric }
            var occurrencesByID: [UUID: RecurrenceOccurrence] = [:]
            for occurrence in allOccurrences { occurrencesByID[occurrence.id] = occurrence }

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

            // 8.8 只记录元数据，不含任何正文
            logger.logAICall(provider: provider.id.rawValue, model: provider.currentModel,
                             status: AIUsageRecord.successStatus, latencyMs: usage.latencyMs,
                             promptTokens: usage.promptTokens, completionTokens: usage.completionTokens,
                             itemCount: proposal.items.count, rejectedCount: validated.issues.count)
            logger.logValidation(rejectedCount: validated.issues.count,
                                 mergedDuplicates: validated.mergedDuplicates,
                                 correctionCount: validated.corrections.count)

            return ProposalPreparation(captureID: request.captureID,
                                       privacy: privacy,
                                       localMatches: localMatches,
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
