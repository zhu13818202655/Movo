//
//  AppEnvironment+Capture.swift
//  App
//
//  6.1 输入管线：C1 落库 → C2 隐私分流 → C3 本地直执 → C4 上下文 → C5 调用
//  → C6 校验 → C7 策略 → C8 提交 → C9 结果态。任何一步失败，原文已持久化（REQ 02）。
//

import Foundation
import MovoKit

@MainActor
public extension AppEnvironment {

    // MARK: - C1 落库

    /// 保存原文并返回 captureID。幂等：同一 batch 重试复用同一 id（C10）。
    @discardableResult
    func submitCapture(text: String, editedText: String? = nil,
                       inputMode: InputMode = .text,
                       audioRetention: AudioRetention = .none) async -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID()
        do {
            let result = try await store.execute(ProcessCapture(
                id: id, rawText: trimmed, editedText: editedText,
                inputMode: inputMode, state: .saved, audioRetention: audioRetention))
            activeCaptureID = result.entityID
            lastError = nil
            return result.entityID
        } catch let error as MovoError {
            lastError = error
            return nil
        } catch {
            lastError = .invalidStructure(reason: "原文没有保存成功。")
            return nil
        }
    }

    /// 更新 capture 状态（C9）。使用新的 operationID，避免幂等缓存拦截。
    func updateCaptureState(_ captureID: UUID, state: CaptureState,
                            batchID: UUID? = nil) async {
        guard let capture = await store.repository.capture(captureID) else { return }
        _ = try? await store.execute(ProcessCapture(
            id: captureID, rawText: capture.rawText, editedText: capture.editedText,
            inputMode: capture.inputMode, state: state, batchID: batchID ?? capture.batchId,
            audioRetention: capture.audioRetention))
    }

    // MARK: - C2–C9 整理

    /// 执行完整整理管线。产出写入 `lastPreparation`，错误写入 `lastError`。
    func processCapture(_ captureID: UUID, vendor: AIVendor? = nil, model: String? = nil) async {
        guard let capture = await store.repository.capture(captureID) else {
            lastError = .notFound(entityType: .capture, id: captureID)
            return
        }
        isProcessing = true
        defer { isProcessing = false }

        await updateCaptureState(captureID, state: .processing)

        // 组装请求快照
        let plans = await store.repository.allPlans()
        let allTasks = await store.repository.allTasks()
        var tasksByPlan: [UUID: [Task]] = [:]
        for task in allTasks {
            if let planID = task.planId { tasksByPlan[planID, default: []].append(task) }
        }
        var stagesByPlan: [UUID: [Stage]] = [:]
        for plan in plans {
            stagesByPlan[plan.id] = await store.repository.stages(planID: plan.id)
        }
        var metricsByPlan: [UUID: [PlanMetric]] = [:]
        for plan in plans {
            metricsByPlan[plan.id] = await store.repository.metrics(planID: plan.id)
        }
        var occurrencesByTask: [UUID: [RecurrenceOccurrence]] = [:]
        for rule in await store.repository.rules() {
            occurrencesByTask[rule.taskId] = await store.repository.occurrences(ruleID: rule.id)
        }

        let request = ProposalRequest(
            captureID: captureID,
            rawText: capture.rawText,
            editedText: capture.editedText,
            inputMode: capture.inputMode,
            today: store.today,
            timeZone: store.currentTimeZone,
            localeIdentifier: "zh-Hans",
            deviceId: store.deviceId,
            source: capture.inputMode == .voice ? .voice : .text,
            plans: plans, stagesByPlan: stagesByPlan, metricsByPlan: metricsByPlan,
            tasksByPlan: tasksByPlan, occurrencesByTask: occurrencesByTask)

        let hasKey = hasKey(for: vendor)
        var preparation: ProposalPreparation

        if hasKey {
            let service = makeProposalService(vendor: vendor, model: model)
            preparation = await service.prepare(request)
        } else {
            // 无 Key：本地分流结果照常保留，整理稍后重试（7.3）
            preparation = localOnlyPreparation(request)
            preparation.error = .noKey(vendor: vendor ?? self.vendor)
        }

        lastPreparation = preparation
        recordUsage(preparation.usage)

        // C3 + C8：本地可确定项与自动项一次提交，可撤销
        let autoCommands: [any DomainCommand] =
            preparation.deterministicLocalMatches.compactMap(\.command) + preparation.autoCommands

        if !autoCommands.isEmpty {
            await apply(commands: autoCommands, captureID: captureID)
        }

        // C9 结果态
        if let error = preparation.error {
            lastError = error
            let applied = store.lastNotification != nil
            await updateCaptureState(captureID, state: applied ? .aiPartial : .aiFailed)
        } else if preparation.needsConfirmation || !preparation.rejectedIssues.isEmpty {
            await updateCaptureState(captureID, state: .aiPartial)
        } else {
            await updateCaptureState(captureID, state: .aiSucceeded)
        }
    }

    /// 无 Key / 离线时的本地分流：只做隐私拆分与本地直执（不发云）。
    func localOnlyPreparation(_ request: ProposalRequest) -> ProposalPreparation {
        let excluded = Dictionary(request.plans.map { ($0.id, $0.excludedTerms) },
                                  uniquingKeysWith: { a, _ in a })
        let privacy = PrivacySplitter.split(text: request.effectiveText,
                                            plans: request.plans,
                                            healthKeywords: ConfigLoader.loadHealthKeywords(),
                                            excludedTermsByPlan: excluded)
        let tasks = request.tasksByPlan.values.flatMap { $0 }
        let occurrences = request.occurrencesByTask.values.flatMap { $0 }
        let matches = LocalDirectRouter.route(
            privacy: privacy, plans: request.plans, tasks: tasks, occurrences: occurrences,
            today: request.today, now: store.now, source: request.source,
            captureID: request.captureID)
        return ProposalPreparation(captureID: request.captureID, privacy: privacy,
                                   localMatches: matches, skippedCloudCall: true)
    }

    /// C8 整批提交（幂等：同 operationId 重复提交直接返回首次结果）
    @discardableResult
    func apply(commands: [any DomainCommand], captureID: UUID? = nil,
               summary: String? = nil) async -> BatchResult? {
        guard !commands.isEmpty else { return nil }
        let input = BatchInput(captureId: captureID, source: .ai, commands: commands,
                               summary: summary ?? ExecutionPolicy.autoResultMessage(appliedCount: commands.count),
                               deviceId: store.deviceId)
        do {
            let result = try await store.executeBatchAllowingPartial(input)
            lastBatchNotice = store.lastNotification
            return result
        } catch let error as MovoError {
            lastError = error
            return nil
        } catch {
            lastError = .invalidStructure(reason: "这批内容没有提交成功。")
            return nil
        }
    }

    /// 用户确认后采纳待确认项（C8：一次确认，单 batch 提交）。
    func acceptPendingProposals(_ pending: [PendingProposal], captureID: UUID? = nil) async {
        guard !pending.isEmpty else { return }
        let tasks = await store.repository.allTasks()
        let taskIndex = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var metricIndex: [UUID: PlanMetric] = [:]
        for plan in await store.repository.allPlans() {
            for metric in await store.repository.metrics(planID: plan.id) { metricIndex[metric.id] = metric }
        }
        var ruleIndex: [UUID: RecurrenceRule] = [:]
        for rule in await store.repository.rules() { ruleIndex[rule.taskId] = rule }

        var commands: [any DomainCommand] = []
        for item in pending {
            commands += ProposalValidator.materialize(
                item, tasks: taskIndex, metrics: metricIndex, rules: ruleIndex,
                timeZone: store.currentTimeZone, today: store.today,
                source: .ai, captureID: captureID)
        }
        guard !commands.isEmpty else { return }
        await apply(commands: commands, captureID: captureID)
        await updateCaptureStateIfNeeded(captureID)
    }

    func updateCaptureStateIfNeeded(_ captureID: UUID?) async {
        guard let captureID else { return }
        await updateCaptureState(captureID, state: lastError == nil ? .aiSucceeded : .aiPartial)
    }
}
