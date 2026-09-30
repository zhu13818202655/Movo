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
                            batchID: UUID? = nil, editedText: String? = nil) async -> Bool {
        guard let capture = await store.repository.capture(captureID) else { return false }
        do {
            _ = try await store.execute(ProcessCapture(
                id: captureID, rawText: capture.rawText, editedText: editedText ?? capture.editedText,
                inputMode: capture.inputMode, segments: capture.segments, state: state,
                batchID: batchID ?? capture.batchId, audioRetention: capture.audioRetention))
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
            var preparation = ProposalPreparation(captureID: captureID,
                privacy: PrivacySplitter.split(text: "", plans: [], healthKeywords: []))
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
                                      occurrencesByTask: occurrences, preferredPlanID: selectedPlan)
        let target = vendor ?? self.vendor
        var preparation: ProposalPreparation
        if let proposal = savedProposals[captureID] {
            preparation = await ProposalService(provider: SavedProposalProvider(proposal: proposal),
                                                 defaults: defaults).prepare(request)
            // 已建计划可能改变隐私匹配；不能把旧原文重新解释为新的本地完成指令。
            preparation.localMatches.removeAll { $0.kind.isDeterministic }
        } else if isConfigured(for: target) {
            do {
                preparation = await (try makeProposalService(vendor: vendor, model: model)).prepare(request)
                recordUsage(preparation.usage)
            } catch {
                preparation = localOnlyPreparation(request)
                preparation.error = error as? MovoError ?? .aiFailed(stage: .unknown, cause: "provider")
            }
        } else {
            preparation = localOnlyPreparation(request)
            preparation.error = configurationError(for: target)
        }

        // 先保存提案再写命令；重试回放同一提案，不重新生成另一组任务。
        if let proposal = preparation.proposal {
            savedProposals[captureID] = proposal
            do {
                let data = try JSONEncoder().encode(savedProposals)
                capturePreferences?.set(data, forKey: "movo.capture.proposals")
            } catch { recordCaptureError(error); return }
        }
        var commands: [any DomainCommand] = preparation.deterministicLocalMatches.compactMap { match in
            guard let command = match.command else { return nil }
            return CaptureCommand(command, captureID: captureID,
                                  key: "local|\(match.kind.rawValue)|\(match.sourceText)")
        }
        commands += preparation.autoCommands.map { command in
            CaptureCommand(command, captureID: captureID,
                           key: "auto|\(preparation.validated.commandKeys[command.operationID] ?? command.operationID.uuidString)")
        }
        if applyAutomaticCommands {
            if let result = await apply(commands: commands, captureID: captureID) {
                preparation.commitRejections = result.rejected
            } else if !commands.isEmpty {
                preparation.error = lastError
            }
        } else {
            for command in commands {
                if await store.repository.operation(command.operationID) == nil {
                    preparation.commitRejections.append(BatchRejection(operationID: command.operationID,
                                                                    entityID: command.entityID,
                                                                    reason: "这项内容尚未保存，可以重试整理。"))
                }
            }
        }
        var pending: [PendingProposal] = []
        for item in preparation.pendingProposals {
            let operationID = CaptureCommand.stableID(captureID: captureID, key: "confirm|\(item.id)|0")
            if await store.repository.operation(operationID) == nil { pending.append(item) }
        }
        preparation.validated.needsConfirmation = pending
        await finishCapture(captureID, preparation: preparation)
    }

    func localOnlyPreparation(_ request: ProposalRequest) -> ProposalPreparation {
        let excluded = Dictionary(request.plans.map { ($0.id, $0.excludedTerms) }, uniquingKeysWith: { a, _ in a })
        let privacy = PrivacySplitter.split(text: request.effectiveText, plans: request.plans,
                                            healthKeywords: ConfigLoader.loadHealthKeywords(), excludedTermsByPlan: excluded)
        let matches = LocalDirectRouter.route(privacy: privacy, plans: request.plans,
                                               tasks: request.tasksByPlan.values.flatMap { $0 },
                                               occurrences: request.occurrencesByTask.values.flatMap { $0 },
                                               today: request.today, now: store.now, source: request.source,
                                               captureID: request.captureID)
        return ProposalPreparation(captureID: request.captureID, privacy: privacy,
                                   localMatches: matches, skippedCloudCall: true)
    }

    @discardableResult
    func apply(commands: [any DomainCommand], captureID: UUID? = nil,
               summary: String? = nil) async -> BatchResult? {
        guard !commands.isEmpty else { return nil }
        do {
            var remaining: [any DomainCommand] = []
            for command in commands {
                // 不重放已执行或已撤销的命令。
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
        for item in pending where preparation.pendingProposals.contains(where: { $0.id == item.id }) {
            let materialized = ProposalValidator.materialize(
                item, tasks: tasks, metrics: metrics, rules: rules, timeZone: store.currentTimeZone,
                today: store.today, source: .ai, captureID: captureID,
                planID: CaptureCommand.stableID(captureID: captureID, key: "plan|\(item.id)"))
            guard !materialized.isEmpty else {
                lastError = .invalidStructure(reason: "这项建议信息不足，请编辑原文后重新整理。")
                continue
            }
            let commands: [any DomainCommand] = materialized.enumerated().map {
                CaptureCommand($0.element, captureID: captureID, key: "confirm|\(item.id)|\($0.offset)")
            }
            do {
                // 一个新计划与其初始待办必须一起成功，不能留下半份计划。
                _ = try await store.executeBatch(BatchInput(batchID: CaptureCommand.batchID(for: captureID), captureId: captureID,
                                                           source: .ai, commands: commands,
                                                           summary: item.affectedSummary, deviceId: store.deviceId))
                preparation.validated.needsConfirmation.removeAll { $0.id == item.id }
                lastBatchNotice = store.lastNotification
            } catch { recordCaptureError(error) }
        }
        preparation.error = lastError
        await finishCapture(captureID, preparation: preparation)
    }

    func restoreCaptureResult(_ captureID: UUID) async {
        guard captureResults[captureID] == nil, !isProcessing,
              let capture = await store.repository.capture(captureID) else { return }
        let batch = await store.repository.batch(CaptureCommand.batchID(for: captureID))
        if capture.state == .aiSucceeded || batch?.state == .undone {
            var result = ProposalPreparation(captureID: captureID,
                privacy: PrivacySplitter.split(text: "", plans: [], healthKeywords: []))
            result.appliedOperations = await store.repository.operations(batchID: CaptureCommand.batchID(for: captureID)).filter { $0.status == .applied }
            result.undoSummary = batch?.state == .undone ? batch?.summary : nil
            captureResults[captureID] = result
            lastPreparation = result
            return
        }
        // 仅回放本机保存的提案，不在打开界面时发起新的付费请求。
        if savedProposals[captureID] != nil {
            await processCapture(captureID, applyAutomaticCommands: false)
        } else {
            var result = ProposalPreparation(captureID: captureID,
                                             privacy: PrivacySplitter.split(text: "", plans: [], healthKeywords: []))
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
        if !result.privacyViolations.isEmpty {
            result.error = .invalidStructure(reason: "部分内容受隐私设置限制，已留在本机，请到收件箱处理。")
        }
        let state: CaptureState = result.isPartial
            ? (result.appliedOperations.isEmpty && result.error != nil ? .aiFailed : .aiPartial)
            : (result.appliedOperations.isEmpty ? .saved : .aiSucceeded)
        if !(await updateCaptureState(captureID, state: state, batchID: CaptureCommand.batchID(for: captureID))) { result.error = lastError }
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
