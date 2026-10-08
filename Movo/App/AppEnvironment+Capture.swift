import Foundation
import MovoKit

@MainActor
public extension AppEnvironment {
    @discardableResult
    func submitCapture(text: String, editedText: String? = nil, inputMode: InputMode = .text,
                       audioRetention: AudioRetention = .none) async -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let result = try await store.execute(ProcessCapture(rawText: trimmed, editedText: editedText,
                                                               inputMode: inputMode, audioRetention: audioRetention))
            activeCaptureID = result.entityID
            capturePreferences?.set(result.entityID?.uuidString, forKey: "movo.capture.active")
            lastError = nil
            return result.entityID
        } catch { recordCaptureError(error) }
        return nil
    }

    /// 与浮层生命周期分开；收起浮层不会取消整理。
    func submitCaptureDraft() async {
        guard !isSubmittingCapture, !isProcessing,
              !captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSubmittingCapture = true
        defer { isSubmittingCapture = false }
        let text = captureText
        let planID = capturePlanID
        guard let id = await submitCapture(text: text, inputMode: captureInputMode) else { return }
        capturePreferences?.set(planID?.uuidString, forKey: "movo.capture.selectedPlan.\(id)")
        if captureText == text { captureText = "" }
        await processCapture(id, preferredPlanID: planID)
    }

    func continueCapturing() {
        guard !isProcessing else { return }
        activeCaptureID = nil
        capturePreferences?.removeObject(forKey: "movo.capture.active")
        captureInputMode = .text
        lastError = nil
    }

    @discardableResult
    func updateCaptureState(_ captureID: UUID, state: CaptureState,
                            batchID: UUID? = nil, editedText: String? = nil,
                            proposalJSON: String? = nil) async -> Bool {
        guard let capture = await store.repository.capture(captureID) else { return false }
        do {
            _ = try await store.execute(ProcessCapture(
                id: captureID, rawText: capture.rawText, editedText: editedText ?? capture.editedText,
                inputMode: capture.inputMode, segments: capture.segments, state: state,
                batchID: batchID ?? capture.batchId,
                proposalJSON: proposalJSON ?? capture.proposalJSON,
                audioRetention: capture.audioRetention))
            return true
        } catch { recordCaptureError(error); return false }
    }

    func processCapture(_ captureID: UUID, vendor: AIVendor? = nil, model: String? = nil,
                        preferredPlanID: UUID? = nil, applyAutomaticCommands: Bool = true) async {
        guard !isProcessing else { return }
        guard let capture = await store.repository.capture(captureID) else {
            lastError = .notFound(entityType: .capture, id: captureID)
            return
        }
        if let batch = await store.repository.batch(CaptureCommand.batchID(for: captureID)), batch.state == .undone {
            var preparation = ProposalPreparation(captureID: captureID)
            preparation.undoSummary = batch.summary
            await finishCapture(captureID, preparation: preparation)
            return
        }
        isProcessing = true
        activeCaptureID = captureID
        lastError = nil
        defer { isProcessing = false }
        guard await updateCaptureState(captureID, state: .processing) else { return }

        let deleted = Set(await store.repository.tombstones(activeOnly: true).map(\.entityId))
        let plans = await store.repository.allPlans().filter { !deleted.contains($0.id) }
        let allTasks = await store.repository.allTasks().filter { !deleted.contains($0.id) }
        var tasksByPlan: [UUID: [MovoKit.Task]] = [:]
        for task in allTasks {
            if let id = task.planId { tasksByPlan[id, default: []].append(task) }
        }
        var stages: [UUID: [Stage]] = [:]
        var metrics: [UUID: [PlanMetric]] = [:]
        var occurrences: [UUID: [RecurrenceOccurrence]] = [:]
        for plan in plans {
            stages[plan.id] = await store.repository.stages(planID: plan.id)
            metrics[plan.id] = await store.repository.metrics(planID: plan.id)
        }
        for rule in await store.repository.rules() {
            occurrences[rule.taskId] = await store.repository.occurrences(ruleID: rule.id)
        }
        let selectedPlan = preferredPlanID ?? capturePreferences?
            .string(forKey: "movo.capture.selectedPlan.\(captureID)").flatMap(UUID.init(uuidString:))
        let request = ProposalRequest(captureID: captureID, rawText: capture.rawText,
                                      editedText: capture.editedText, inputMode: capture.inputMode,
                                      today: store.today, timeZone: store.currentTimeZone, deviceId: store.deviceId,
                                      source: capture.inputMode == .voice ? .voice : .text, plans: plans,
                                      stagesByPlan: stages, metricsByPlan: metrics, tasksByPlan: tasksByPlan,
                                      occurrencesByTask: occurrences, preferredPlanID: selectedPlan,
                                      globalAIEnabled: globalAIEnabled)
        let target = vendor ?? self.vendor
        var preparation: ProposalPreparation
        if let proposal = savedProposals[captureID] {
            preparation = await ProposalService(provider: SavedProposalProvider(proposal: proposal),
                                                 defaults: defaults).prepare(request)
        } else if !globalAIEnabled {
            preparation = ProposalPreparation(captureID: captureID, skippedCloudCall: true)
            preparation.error = .invalidStructure(reason: "全局 AI 已关闭，原文已保存。可在设置中开启。")
        } else if isConfigured(for: target) {
            do {
                preparation = await (try makeProposalService(vendor: vendor, model: model)).prepare(request)
                recordUsage(preparation.usage)
            } catch {
                preparation = ProposalPreparation(captureID: captureID, skippedCloudCall: true)
                preparation.error = error as? MovoError ?? .aiFailed(stage: .unknown, cause: "provider")
            }
        } else {
            preparation = ProposalPreparation(captureID: captureID, skippedCloudCall: true)
            preparation.error = configurationError(for: target)
        }

        // 保存提案供回放与预览重新打开
        if let proposal = preparation.proposal {
            savedProposals[captureID] = proposal
            do {
                let data = try JSONEncoder().encode(savedProposals)
                capturePreferences?.set(data, forKey: "movo.capture.proposals")
            } catch { recordCaptureError(error); return }
        }

        // AI 的所有写入都先展示预览，不直接自动落库
        var pending: [PendingProposal] = []
        for item in preparation.pendingProposals {
            let operationID = CaptureCommand.stableID(captureID: captureID, key: "confirm|\(item.id)|0")
            if await store.repository.operation(operationID) == nil { pending.append(item) }
        }
        preparation.validated.needsConfirmation = pending
        await finishCapture(captureID, preparation: preparation)
    }

    @discardableResult
    func apply(commands: [any DomainCommand], captureID: UUID? = nil,
               summary: String? = nil) async -> BatchResult? {
        guard !commands.isEmpty else { return nil }
        do {
            var remaining: [any DomainCommand] = []
            for command in commands {
                if await store.repository.operation(command.operationID) == nil { remaining.append(command) }
            }
            guard !remaining.isEmpty else { return BatchResult(batchID: captureID.map(CaptureCommand.batchID(for:)) ?? UUID()) }
            let result = try await store.executeBatchAllowingPartial(BatchInput(
                batchID: captureID.map(CaptureCommand.batchID(for:)) ?? UUID(), captureId: captureID, source: .ai, commands: remaining,
                summary: summary ?? "AI 整理", deviceId: store.deviceId))
            if !result.applied.isEmpty { lastBatchNotice = store.lastNotification }
            return result
        } catch { recordCaptureError(error); return nil }
    }

    func acceptPendingProposals(_ pending: [PendingProposal], captureID: UUID? = nil) async {
        guard let captureID, !isProcessing, var preparation = captureResults[captureID] else { return }
        guard await store.repository.batch(CaptureCommand.batchID(for: captureID))?.state != .undone else { return }
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        let tasks = Dictionary(await store.repository.allTasks().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var metrics: [UUID: PlanMetric] = [:]
        for plan in await store.repository.allPlans() {
            for metric in await store.repository.metrics(planID: plan.id) { metrics[metric.id] = metric }
        }
        let rules = Dictionary(await store.repository.rules().map { ($0.taskId, $0) }, uniquingKeysWith: { a, _ in a })

        let acceptedItems = pending.filter { p in preparation.pendingProposals.contains(where: { $0.id == p.id }) }
        guard !acceptedItems.isEmpty else { return }

        let materialized = ProposalValidator.materializeBatch(
            acceptedItems,
            plans: await store.repository.allPlans(),
            tasks: tasks,
            metrics: metrics,
            rules: rules,
            timeZone: store.currentTimeZone,
            today: store.today,
            source: .ai,
            captureID: captureID)

        let commands: [any DomainCommand] = materialized.enumerated().map {
            CaptureCommand($0.element, captureID: captureID, key: "batch|\($0.offset)")
        }

        do {
            let summaryText = acceptedItems.map(\.affectedSummary).prefix(3).joined(separator: "、")
            _ = try await store.executeBatch(BatchInput(
                batchID: CaptureCommand.batchID(for: captureID),
                captureId: captureID,
                source: .ai,
                commands: commands,
                summary: "AI 整理：" + summaryText,
                deviceId: store.deviceId))

            let acceptedIDs = Set(acceptedItems.map(\.id))
            preparation.validated.needsConfirmation.removeAll { acceptedIDs.contains($0.id) }
            lastBatchNotice = store.lastNotification
        } catch {
            recordCaptureError(error)
        }

        preparation.error = lastError
        await finishCapture(captureID, preparation: preparation)
    }

    func restoreCaptureResult(_ captureID: UUID) async {
        guard captureResults[captureID] == nil, !isProcessing,
              let capture = await store.repository.capture(captureID) else { return }
        let batch = await store.repository.batch(CaptureCommand.batchID(for: captureID))
        if capture.state == .aiSucceeded || batch?.state == .undone {
            var result = ProposalPreparation(captureID: captureID)
            result.appliedOperations = await store.repository.operations(batchID: CaptureCommand.batchID(for: captureID)).filter { $0.status == .applied }
            result.undoSummary = batch?.state == .undone ? batch?.summary : nil
            captureResults[captureID] = result
            lastPreparation = result
            return
        }
        if savedProposals[captureID] == nil, let json = capture.proposalJSON,
           let data = json.data(using: .utf8),
           let prop = try? JSONDecoder().decode(AIProposal.self, from: data) {
            savedProposals[captureID] = prop
        }
        if savedProposals[captureID] != nil {
            await processCapture(captureID, applyAutomaticCommands: false)
        } else {
            var result = ProposalPreparation(captureID: captureID)
            result.error = .invalidStructure(reason: "原文已保留，整理尚未完成。可以重试或手动处理。")
            result.appliedOperations = await store.repository.operations(batchID: CaptureCommand.batchID(for: captureID)).filter { $0.status == .applied }
            captureResults[captureID] = result
            lastPreparation = result
            if capture.state == .processing { _ = await updateCaptureState(captureID, state: .aiPartial) }
        }
    }

    func finishCapture(_ captureID: UUID, preparation: ProposalPreparation) async {
        var result = preparation
        result.appliedOperations = await store.repository.operations(batchID: CaptureCommand.batchID(for: captureID)).filter { $0.status == .applied }
        let batch = await store.repository.batch(CaptureCommand.batchID(for: captureID))
        let state: CaptureState
        if batch?.state == .undone {
            state = .undone
        } else if !result.pendingProposals.isEmpty {
            state = .pendingConfirmation
        } else if !result.appliedOperations.isEmpty {
            state = result.isPartial ? .aiPartial : .aiSucceeded
        } else if result.error != nil {
            state = .aiFailed
        } else {
            state = .saved
        }
        let propJSON = result.proposal.flatMap { p in
            (try? JSONEncoder().encode(p)).flatMap { String(data: $0, encoding: .utf8) }
        }
        if !(await updateCaptureState(captureID, state: state, batchID: CaptureCommand.batchID(for: captureID), proposalJSON: propJSON)) {
            result.error = lastError
        }
        captureResults[captureID] = result
        lastPreparation = result
        lastError = result.error
    }

    func updateCaptureStateIfNeeded(_ captureID: UUID?) async {
        guard let captureID, let result = captureResults[captureID] else { return }
        await finishCapture(captureID, preparation: result)
    }

    func recordCaptureError(_ error: Error) {
        lastError = error as? MovoError ?? .invalidStructure(reason: "内容没有保存成功，请重试。")
    }
}
