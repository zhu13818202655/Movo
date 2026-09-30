//
//  ProposalValidator.swift
//  Intelligence/Planning
//
//  6.6 校验清单。核心原则：**校验未过绝不猜测**——进收件箱可编辑，而不是猜一个值写下去。
//  高影响动作（依赖建议 / 频率调整 / 硬截止 / 结果单位）一律进"待确认"，确认后才物化为命令。
//

import Foundation

// MARK: - 待确认项

/// 需要用户确认的提议（不自动执行）。确认后由 `ProposalValidator.materialize` 物化为命令。
public struct PendingProposal: Identifiable, Sendable {

    public enum Kind: String, Sendable, CaseIterable {
        case deadlineChange
        case recurrenceChange
        case dependencySuggestion
        case measurementUnitUnclear
        case classificationAmbiguous
        case bulkChange
        case planCreation

        public var displayName: String {
            switch self {
            case .deadlineChange: "修改硬截止"
            case .recurrenceChange: "调整频率"
            case .dependencySuggestion: "先后顺序建议"
            case .measurementUnitUnclear: "结果单位待确认"
            case .classificationAmbiguous: "归属待确认"
            case .bulkChange: "批量改动"
            case .planCreation: "新建计划"
            }
        }
    }

    public var id: String
    public var item: AIProposalItem
    /// 影响到的对象摘要（标题等）
    public var affectedSummary: String
    /// 依赖变化：可读的前置任务标题
    public var dependencyChanges: [String]
    /// 影响预览行
    public var changeSummary: [ImpactPreview.ImpactLine]
    public var kind: PendingProposal.Kind

    public init(id: String, item: AIProposalItem, affectedSummary: String,
                dependencyChanges: [String] = [],
                changeSummary: [ImpactPreview.ImpactLine] = [],
                kind: PendingProposal.Kind) {
        self.id = id; self.item = item; self.affectedSummary = affectedSummary
        self.dependencyChanges = dependencyChanges
        self.changeSummary = changeSummary; self.kind = kind
    }
}

// MARK: - 校验未过项（进收件箱，可编辑）

public struct ProposalIssue: Identifiable, Hashable, Sendable {
    public var itemID: String
    public var sourceSpan: String?
    public var reasons: [RejectReason]
    public var suggestedAction: String?

    public var id: String { "\(itemID)#\(sourceSpan ?? "")" }

    public init(itemID: String, sourceSpan: String?,
                reasons: [RejectReason], suggestedAction: String? = nil) {
        self.itemID = itemID; self.sourceSpan = sourceSpan
        self.reasons = reasons; self.suggestedAction = suggestedAction
    }
}

// MARK: - 校验结果

public struct ValidatedProposal: Sendable {
    /// 可自动执行并撤销的命令
    public var commands: [any DomainCommand]
    public var commandKeys: [UUID: String] = [:]
    /// 需要用户确认的提议
    public var needsConfirmation: [PendingProposal]
    /// 校验未过项（进收件箱）
    public var issues: [ProposalIssue]
    /// 本地自动修正说明（可回看，不改用户原文）
    public var corrections: [String]
    /// 同批重复被合并的条数
    public var mergedDuplicates: Int
    /// 超过单次上限时的说明
    public var truncationNotice: String?

    public init(commands: [any DomainCommand] = [],
                needsConfirmation: [PendingProposal] = [],
                issues: [ProposalIssue] = [],
                corrections: [String] = [],
                mergedDuplicates: Int = 0,
                truncationNotice: String? = nil) {
        self.commands = commands; self.needsConfirmation = needsConfirmation
        self.issues = issues; self.corrections = corrections
        self.mergedDuplicates = mergedDuplicates; self.truncationNotice = truncationNotice
    }

    public var isEmpty: Bool {
        commands.isEmpty && needsConfirmation.isEmpty && issues.isEmpty
    }

    public var totalItemCount: Int {
        commands.count + needsConfirmation.count + issues.count
    }
}

// MARK: - 校验器

public enum ProposalValidator {

    /// 把一次模型输出校验为「可执行命令 + 待确认项 + 收件箱项」。
    public static func validate(proposal: AIProposal,
                                input: AIInput,
                                plans: [Plan],
                                tasks: [UUID: Task],
                                metrics: [UUID: PlanMetric],
                                occurrences: [UUID: RecurrenceOccurrence],
                                today: DateOnly,
                                timeZone: TimeZone,
                                defaults: AppDefaults,
                                deviceId: String,
                                captureID: UUID?,
                                source: SourceKind) -> ValidatedProposal {

        var commands: [any DomainCommand] = []
        var commandKeys: [UUID: String] = [:]
        var needsConfirmation: [PendingProposal] = []
        var issues: [ProposalIssue] = []
        var corrections: [String] = []
        var mergedDuplicates = 0
        var truncationNotice: String?

        let planByID = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let characters = Array(input.text)

        var items = proposal.items
        if items.count > defaults.ai.maxItemsPerInput {
            let dropped = items.count - defaults.ai.maxItemsPerInput
            items = Array(items.prefix(defaults.ai.maxItemsPerInput))
            truncationNotice = "这次内容较多，先处理前 \(items.count) 项，另有 \(dropped) 项已放进收件箱。"
        }

        var dedupKeys: Set<String> = []

        for var item in items {
            let commandStart = commands.count
            defer {
                for (index, command) in commands.dropFirst(commandStart).enumerated() {
                    commandKeys[command.operationID] = "\(item.action.rawValue)|\(item.id)|\(item.task?.title ?? "")|\(index)"
                }
            }
            // 模型容易算错中文/emoji 偏移；只有原文片段唯一精确命中时才修正。
            if let source = item.sourceSpan, !source.isEmpty,
               let range = input.text.range(of: source),
               input.text.range(of: source, range: range.upperBound..<input.text.endIndex) == nil {
                item.span = [input.text.distance(from: input.text.startIndex, to: range.lowerBound),
                             input.text.distance(from: input.text.startIndex, to: range.upperBound)]
            }
            // MARK: V1 原文一致性（定位必须落在发送文本范围内）
            guard item.span.count == 2,
                  item.span[0] >= 0, item.span[1] <= characters.count,
                  item.span[0] < item.span[1] else {
                issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                            reasons: [.spanOutOfRange],
                                            suggestedAction: "可以手动整理这一段。"))
                continue
            }
            let spanText = String(characters[item.span[0]..<item.span[1]])

            if let declared = item.sourceSpan, !declared.isEmpty {
                let actual = spanText.trimmingCharacters(in: .whitespacesAndNewlines)
                let claimed = declared.trimmingCharacters(in: .whitespacesAndNewlines)
                if actual != claimed {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("模型引用的片段与原文不一致，请编辑后重试")]))
                    continue
                }
            }

            // MARK: V2 动作与数据块匹配
            if !item.extraBlocks.isEmpty {
                issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                            reasons: [.mismatchedDataBlock]))
                continue
            }

            // MARK: V11 同批去重
            var dedupKey = item.action.rawValue + "|" + spanText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let target = item.task?.candidateTaskId { dedupKey += "|" + target }
            if let scheduled = item.task?.scheduledDate { dedupKey += "|" + scheduled }
            if let title = item.task?.title { dedupKey += "|" + title }
            if let name = item.plan?.name { dedupKey += "|" + name }
            guard dedupKeys.insert(dedupKey).inserted else {
                mergedDuplicates += 1
                continue
            }

            let spec = item.task

            switch item.action {

            case .createPlan:
                guard let plan = item.plan else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("缺少计划名称或有效类型")]))
                    continue
                }
                do { try StructurePolicy.validatePlanName(plan.name) }
                catch {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("计划名称无效")]))
                    continue
                }
                if let date = plan.targetDate,
                   DateOnly(iso8601DateString: date, sourceTZ: timeZone.identifier) == nil {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unparsableDate]))
                    continue
                }
                guard plan.tasks.count <= defaults.ai.maxItemsPerInput else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("计划待办过多，请分次整理")]))
                    continue
                }
                var taskIssues: [ProposalIssue] = []
                for task in plan.tasks {
                    guard task.planId == nil, task.stageId == nil, task.parentTaskId == nil,
                          task.candidateTaskId == nil, task.dependencyIds.isEmpty,
                          (task.title?.count ?? 0) <= Task.maxTitleLength,
                          !(task.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        taskIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                        reasons: [.structureViolation("计划待办缺少标题或引用了未经确认的结构")]))
                        continue
                    }
                    let child = AIProposalItem(sourceSpan: item.sourceSpan, span: item.span,
                                               action: .createTask, task: task, confidence: item.confidence)
                    let checked = validate(proposal: AIProposal(items: [child]), input: input,
                                           plans: plans, tasks: tasks, metrics: metrics, occurrences: occurrences,
                                           today: today, timeZone: timeZone, defaults: defaults,
                                           deviceId: deviceId, captureID: captureID, source: source)
                    taskIssues += checked.issues
                }
                guard taskIssues.isEmpty else { issues += taskIssues; continue }
                var lines = [ImpactPreview.ImpactLine(entityId: UUID(), title: "计划类型", changeText: plan.kind.displayName)]
                if let goal = plan.goal { lines.append(.init(entityId: UUID(), title: "目标", changeText: goal)) }
                if let date = plan.targetDate { lines.append(.init(entityId: UUID(), title: "目标日期", changeText: date)) }
                lines += plan.tasks.map { task in
                    let details = [task.scheduledDate.map { "安排 \($0)" },
                                   task.hardDeadline.map { "硬截止 \($0)" }, task.notes].compactMap { $0 }
                    return .init(entityId: UUID(), title: "新增：\(task.title ?? "")",
                                 changeText: details.isEmpty ? "未安排" : details.joined(separator: " · "))
                }
                needsConfirmation.append(PendingProposal(id: item.id, item: item,
                                                          affectedSummary: plan.name,
                                                          changeSummary: lines, kind: .planCreation))

            // MARK: needs_clarification → 收件箱补充信息
            case .needsClarification:
                issues.append(ProposalIssue(
                    itemID: item.id, sourceSpan: item.sourceSpan,
                    reasons: [.structureViolation(item.clarificationQuestion ?? "这条信息不足，需要你补充说明")],
                    suggestedAction: "去收件箱补充说明"))

            // MARK: create_task
            case .createTask:
                if let stageID = spec?.stageId, !stageID.isEmpty {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unknownReference(stageID)],
                                                suggestedAction: "先创建待办，再从详情选择阶段。"))
                    continue
                }
                if let rawParent = spec?.parentTaskId, !rawParent.isEmpty,
                   !(UUID(uuidString: rawParent).map { input.allowedTaskIDs.contains($0) } ?? false) {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unknownReference(rawParent)]))
                    continue
                }
                if !(spec?.dependencyIds.isEmpty ?? true) {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("新待办的前置关系需要单独确认")],
                                                suggestedAction: "先创建待办，再在详情设置前置任务。"))
                    continue
                }
                let rawTitle = (spec?.title ?? spanText).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawTitle.isEmpty else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.emptyTitle]))
                    continue
                }
                var title = rawTitle
                if rawTitle.count > Task.maxTitleLength {
                    title = String(rawTitle.prefix(Task.maxTitleLength))
                    corrections.append("标题超过 \(Task.maxTitleLength) 字，已截断保存。")
                }

                var planID: UUID?
                if let raw = spec?.planId, !raw.isEmpty {
                    guard let uuid = UUID(uuidString: raw) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.unknownReference(raw)]))
                        continue
                    }
                    guard input.allowedPlanIDs.contains(uuid), planByID[uuid] != nil else {
                        // 未允许云处理的计划：整条进收件箱（不使用、不转发）
                        issues.append(ProposalIssue(
                            itemID: item.id, sourceSpan: item.sourceSpan,
                            reasons: [.planNotCloudAIEnabled],
                            suggestedAction: "这段内容只在你的设备上处理，可以手动归类。"))
                        continue
                    }
                    if planByID[uuid]?.status == .archived {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.planArchived]))
                        continue
                    }
                    planID = uuid
                }

                var scheduled: DateOnly?
                if let raw = spec?.scheduledDate, !raw.isEmpty {
                    guard let day = DateOnly(iso8601DateString: Self.dayPrefix(raw), sourceTZ: timeZone.identifier) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.unparsableDate]))
                        continue
                    }
                    if day < today {
                        corrections.append("「\(raw)」早于今天，安排日期已改为今天。")
                        scheduled = today
                    } else {
                        scheduled = day
                    }
                }

                var deadline: DateTimeTZ?
                if let raw = spec?.hardDeadline, !raw.isEmpty {
                    if item.dateInterpretation?.isHardDeadline == false {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.deadlineNotAllowed]))
                        continue
                    }
                    guard let parsed = parseDeadline(raw, fallbackTZ: timeZone) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.deadlineNeedsTimeAndZone]))
                        continue
                    }
                    deadline = parsed
                }

                let context = ExecutionContext(confidence: item.confidence,
                                               candidateMatchCount: planID == nil ? 0 : 1,
                                               autoClassificationConfidence: defaults.ai.classificationConfidenceThreshold,
                                               autoClassificationMargin: defaults.ai.classificationMarginThreshold)
                if planID != nil, !ExecutionPolicy.allowsAutoClassification(context) {
                    planID = nil
                    item.task?.planId = nil
                    item.task?.stageId = nil
                    item.task?.parentTaskId = nil
                    corrections.append("「\(title)」已保存为独立待办，可以稍后选择计划。")
                }
                let decision = planID == nil ? ExecutionDecision.auto : ExecutionPolicy.decide(for: item.action, context: context)

                switch decision {
                case .auto:
                    commands.append(CreateTask(
                        title: title,
                        planID: planID,
                        stageID: planID == nil ? nil : spec?.stageId.flatMap { UUID(uuidString: $0) },
                        parentID: planID == nil ? nil : spec?.parentTaskId.flatMap { UUID(uuidString: $0) },
                        notes: spec?.notes,
                        scheduledDate: scheduled,
                        deadline: deadline,
                        estimateMinutes: spec?.estimateMinutes,
                        priority: spec?.priority.flatMap { TaskPriority(rawValue: normalizePriority($0)) },
                        tags: spec?.tags ?? [],
                        dependencyIDs: (spec?.dependencyIds ?? []).compactMap { UUID(uuidString: $0) },
                        recurrence: nil,
                        source: source,
                        captureID: captureID,
                        suggestedFields: spec.map { suggestedFields(for: item, taskSpec: $0) } ?? []))
                case .bulkPreview, .confirm, .inboxSuggestion:
                    needsConfirmation.append(PendingProposal(
                        id: item.id, item: item, affectedSummary: title,
                        changeSummary: [ImpactPreview.ImpactLine(
                            entityId: planID ?? UUID(), title: title,
                            changeText: planID == nil ? "归属还不确定，先放进收件箱" : "新增待办，待你确认")],
                        kind: .classificationAmbiguous))
                case .reject:
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.emptyTitle]))
                }

            // MARK: schedule_existing_task
            case .scheduleExistingTask:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }
                var day = today
                if let rawDate = spec?.scheduledDate, !rawDate.isEmpty {
                    guard let parsed = DateOnly(iso8601DateString: Self.dayPrefix(rawDate),
                                                sourceTZ: timeZone.identifier) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.unparsableDate]))
                        continue
                    }
                    if parsed < today {
                        corrections.append("安排日期早于今天，已改为今天。")
                        day = today
                    } else {
                        day = parsed
                    }
                }
                let context = ExecutionContext(confidence: item.confidence, candidateMatchCount: 1)
                switch ExecutionPolicy.decide(for: item.action, context: context) {
                case .auto:
                    commands.append(ScheduleTask(taskID: taskID, date: day, baseRevision: task.revision))
                default:
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unparsableDate]))
                }

            // MARK: update_task
            case .updateTask:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }

                var deadline: DateTimeTZ?
                if let rawDeadline = spec?.hardDeadline, !rawDeadline.isEmpty {
                    if item.dateInterpretation?.isHardDeadline == false {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.deadlineNotAllowed]))
                        continue
                    }
                    guard let parsed = parseDeadline(rawDeadline, fallbackTZ: timeZone) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.deadlineNeedsTimeAndZone]))
                        continue
                    }
                    deadline = parsed
                }

                var scheduled: DateOnly?
                if let rawDate = spec?.scheduledDate, !rawDate.isEmpty {
                    guard let parsed = DateOnly(iso8601DateString: Self.dayPrefix(rawDate),
                                                sourceTZ: timeZone.identifier) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.unparsableDate]))
                        continue
                    }
                    if parsed < today {
                        corrections.append("安排日期早于今天，已改为今天。")
                        scheduled = today
                    } else {
                        scheduled = parsed
                    }
                }

                let context = ExecutionContext(confidence: item.confidence,
                                               candidateMatchCount: 1,
                                               changesHardDeadline: deadline != nil)
                switch ExecutionPolicy.decide(for: item.action, context: context) {
                case .auto:
                    var patch = TaskPatch()
                    if let rawTitle = spec?.title {
                        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            patch.title = trimmed.count > Task.maxTitleLength
                                ? String(trimmed.prefix(Task.maxTitleLength)) : trimmed
                        }
                    }
                    if let notes = spec?.notes { patch.notes = notes }
                    if let scheduled { patch.scheduledDate = scheduled }
                    if let priority = spec?.priority,
                       let parsed = TaskPriority(rawValue: normalizePriority(priority)) {
                        patch.priority = parsed
                    }
                    if let estimate = spec?.estimateMinutes { patch.estimateMinutes = estimate }
                    if let tags = spec?.tags, !tags.isEmpty { patch.tags = tags }
                    if let stage = spec?.stageId.flatMap({ UUID(uuidString: $0) }) { patch.stageID = stage }
                    if let rawPlan = spec?.planId, let planUUID = UUID(uuidString: rawPlan) {
                        guard input.allowedPlanIDs.contains(planUUID) else {
                            issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                        reasons: [.unknownReference(rawPlan)]))
                            continue
                        }
                        patch.planID = planUUID
                    }
                    guard !patch.isEmpty else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.mismatchedDataBlock],
                                                    suggestedAction: "这条没有需要修改的字段。"))
                        continue
                    }
                    commands.append(UpdateTask(taskID: taskID, patch: patch, baseRevision: task.revision))
                case .confirm, .bulkPreview:
                    needsConfirmation.append(PendingProposal(
                        id: item.id, item: item, affectedSummary: task.title,
                        changeSummary: [ImpactPreview.ImpactLine(
                            entityId: taskID, title: task.title, changeText: "修改硬截止",
                            oldValue: task.hardDeadline?.displayString,
                            newValue: deadline?.displayString)],
                        kind: .deadlineChange))
                default:
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                }

            // MARK: complete_task
            case .completeTask:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }
                if task.status == .done {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.completedCannotComplete]))
                    continue
                }
                if task.status == .cancelled {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unknownReference(raw)]))
                    continue
                }
                let at: TimeValue = .day(resolvedDay(item: item, spec: spec, today: today,
                                                     timeZone: timeZone) ?? today)
                if task.isTemplate {
                    let pending = occurrences.values.filter {
                        $0.taskId == taskID && $0.status == .pending
                            && input.allowedOccurrenceIDs.contains($0.id)
                    }
                    guard pending.count == 1, let occurrence = pending.first else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.templateNeedsOccurrence],
                                                    suggestedAction: "请选择要完成的具体某一次。"))
                        continue
                    }
                    commands.append(CompleteOccurrence(occurrenceID: occurrence.id, at: at,
                                                       baseRevision: occurrence.revision))
                } else {
                    commands.append(CompleteTask(taskID: taskID, at: at,
                                                 baseRevision: task.revision, reason: item.reason))
                }

            // MARK: match_occurrence（唯一匹配既有任务/实例，避免重复新建）
            case .matchOccurrence:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }
                let day = resolvedDay(item: item, spec: spec, today: today, timeZone: timeZone) ?? today
                if task.isTemplate {
                    let pending = occurrences.values.filter {
                        $0.taskId == taskID && $0.status == .pending
                            && input.allowedOccurrenceIDs.contains($0.id)
                    }
                    guard pending.count == 1, let occurrence = pending.first else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.templateNeedsOccurrence],
                                                    suggestedAction: "请选择要处理的具体某一次。"))
                        continue
                    }
                    commands.append(CompleteOccurrence(occurrenceID: occurrence.id, at: .day(day),
                                                       baseRevision: occurrence.revision))
                } else {
                    commands.append(ScheduleTask(taskID: taskID, date: day, baseRevision: task.revision))
                }

            // MARK: log_activity
            case .logActivity:
                guard let rawPlan = spec?.planId, let planID = UUID(uuidString: rawPlan),
                      input.allowedPlanIDs.contains(planID), planByID[planID] != nil else {
                    issues.append(ProposalIssue(
                        itemID: item.id, sourceSpan: item.sourceSpan,
                        reasons: [.requiresCandidateTask],
                        suggestedAction: "去收件箱补充这条记录属于哪个计划。"))
                    continue
                }
                var taskID: UUID?
                if let raw = spec?.candidateTaskId, let id = UUID(uuidString: raw),
                   input.allowedTaskIDs.contains(id) {
                    taskID = id
                }
                let day = resolvedDay(item: item, spec: spec, today: today, timeZone: timeZone) ?? today
                let context = ExecutionContext(confidence: item.confidence, candidateMatchCount: 1)
                switch ExecutionPolicy.decide(for: item.action, context: context) {
                case .auto:
                    commands.append(LogActivity(
                        planID: planID, taskID: taskID, occurrenceID: nil,
                        happenedAt: .day(day), durationMinutes: nil,
                        text: item.note?.text ?? spanText, source: source))
                default:
                    issues.append(ProposalIssue(
                        itemID: item.id, sourceSpan: item.sourceSpan,
                        reasons: [.requiresCandidateTask],
                        suggestedAction: "去收件箱确认这条记录的归属。"))
                }

            // MARK: record_measurement
            case .recordMeasurement:
                guard let measurement = item.measurement,
                      let value = measurement.value, value.isFinite else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.invalidMeasurementValue]))
                    continue
                }
                guard let rawMetric = measurement.metricId, let metricID = UUID(uuidString: rawMetric),
                      input.allowedMetricIDs.contains(metricID), let metric = metrics[metricID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask],
                                                suggestedAction: "去收件箱选择一个结果指标。"))
                    continue
                }
                var measuredAt = today
                if let rawDate = measurement.measuredAt, !rawDate.isEmpty {
                    guard let day = DateOnly(iso8601DateString: Self.dayPrefix(rawDate),
                                             sourceTZ: timeZone.identifier) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.unparsableDate]))
                        continue
                    }
                    measuredAt = day
                }
                let unit = (measurement.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let unitMismatched = !unit.isEmpty && !metric.unit.isEmpty && unit != metric.unit
                let unitMissing = unit.isEmpty && metric.unit.isEmpty

                let context = ExecutionContext(confidence: item.confidence,
                                               candidateMatchCount: 1,
                                               measurementUnitMissing: unitMissing,
                                               measurementUnitMismatched: unitMismatched)
                switch ExecutionPolicy.decide(for: item.action, context: context) {
                case .auto:
                    commands.append(RecordMeasurement(
                        planID: metric.planId, metricID: metricID, measuredAt: measuredAt,
                        value: value, unit: unit.isEmpty ? nil : unit,
                        note: measurement.note, source: source))
                case .confirm, .bulkPreview:
                    // 待确认项必须自带可物化的日期（materialize 需要 measuredAt）
                    item.measurement?.measuredAt = measuredAt.iso8601DateString
                    needsConfirmation.append(PendingProposal(
                        id: item.id, item: item,
                        affectedSummary: "\(metric.name) \(formatValue(value))",
                        changeSummary: [ImpactPreview.ImpactLine(
                            entityId: metricID, title: metric.name,
                            changeText: unitMissing
                                ? "这个指标还没有单位，需要先补上"
                                : "原文单位「\(unit)」与指标单位「\(metric.unitDisplayName)」不一致",
                            oldValue: metric.unitDisplayName, newValue: unit.isEmpty ? nil : unit)],
                        kind: .measurementUnitUnclear))
                default:
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unitMismatch],
                                                suggestedAction: "去收件箱确认单位后保存。"))
                }

            // MARK: save_note
            case .saveNote:
                let text = (item.note?.text ?? spanText).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.emptyTitle]))
                    continue
                }
                var planID: UUID?
                if let raw = spec?.planId, let id = UUID(uuidString: raw) {
                    guard input.allowedPlanIDs.contains(id) else {
                        issues.append(ProposalIssue(
                            itemID: item.id, sourceSpan: item.sourceSpan,
                            reasons: [.planNotCloudAIEnabled],
                            suggestedAction: "这段内容只在你的设备上处理，可以手动归类。"))
                        continue
                    }
                    planID = id
                }
                let kind = NoteKind(rawValue: item.note?.kind ?? "") ?? .idea
                commands.append(CreateNote(text: text, kind: kind, planID: planID,
                                           source: source, captureID: captureID))

            // MARK: set_recurrence（高影响：一律确认）
            case .setRecurrence:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }
                guard let recurrence = item.recurrence,
                      let patternRaw = recurrence.pattern,
                      let pattern = RecurrencePattern(rawValue: patternRaw) else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.incompleteRecurrence]))
                    continue
                }
                if pattern == .weekdays, recurrence.weekdays.isEmpty {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.incompleteRecurrence]))
                    continue
                }
                if pattern == .weeklyCount, !(1...7).contains(recurrence.count ?? 0) {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.incompleteRecurrence]))
                    continue
                }
                let summary = pattern == .weeklyCount
                    ? "每周 \(recurrence.count ?? 0) 次" : pattern.displayName
                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item, affectedSummary: task.title,
                    changeSummary: [ImpactPreview.ImpactLine(
                        entityId: taskID, title: task.title,
                        changeText: "重复频率调整为「\(summary)」，只作用于生效日及以后")],
                    kind: .recurrenceChange))

            // MARK: set_dependency（高影响：一律确认）
            case .setDependency:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }
                let rawDeps = spec?.dependencyIds ?? []
                let depIDs = rawDeps.compactMap { UUID(uuidString: $0) }
                guard !depIDs.isEmpty, depIDs.count == rawDeps.count,
                      depIDs.allSatisfy({ input.allowedTaskIDs.contains($0) && tasks[$0] != nil }) else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.dependencyInvalid]))
                    continue
                }
                // 跨计划与成环一律拒绝（C9）
                guard depIDs.allSatisfy({ tasks[$0]?.planId == task.planId }),
                      !depIDs.contains(taskID),
                      !depIDs.contains(where: { wouldCreateCycle(taskID: taskID, dependsOn: $0, tasks: tasks) }) else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.dependencyInvalid]))
                    continue
                }
                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item, affectedSummary: task.title,
                    dependencyChanges: depIDs.map { tasks[$0]?.title ?? $0.uuidString },
                    changeSummary: depIDs.map { dep in
                        ImpactPreview.ImpactLine(
                            entityId: taskID, title: task.title,
                            changeText: "先完成「\(tasks[dep]?.title ?? "前置任务")」")
                    },
                    kind: .dependencySuggestion))
            }
        }

        var result = ValidatedProposal(commands: commands, needsConfirmation: needsConfirmation,
                                 issues: issues, corrections: corrections,
                                 mergedDuplicates: mergedDuplicates,
                                 truncationNotice: truncationNotice)
        result.commandKeys = commandKeys
        return result
    }

    // MARK: - 私有工具

    /// `2026-09-30T07:00:00Z` → `2026-09-30`
    static func dayPrefix(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
    }

    /// 解析硬截止。ISO8601（含时区）→ 保留其时刻；退化为「某天」→ 当天正午。
    static func parseDeadline(_ raw: String, fallbackTZ: TimeZone) -> DateTimeTZ? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) {
            if text.hasSuffix("Z") || text.contains("+") {
                return DateTimeTZ(epoch: date, tzID: "UTC")
            }
            return DateTimeTZ(date, in: fallbackTZ)
        }
        if let day = DateOnly(iso8601DateString: dayPrefix(text), sourceTZ: fallbackTZ.identifier) {
            return DateTimeTZ(day.noon, in: fallbackTZ)
        }
        return nil
    }

    /// 模型给的优先级字符串 → `TaskPriority.rawValue`
    static func normalizePriority(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "高", "紧急", "urgent", "p1": return TaskPriority.high.rawValue
        case "low", "低", "p3": return TaskPriority.low.rawValue
        case "normal", "普通", "中", "medium", "p2": return TaskPriority.normal.rawValue
        default: return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// 由 AI 推断的字段标「建议」（PRD 4.2）
    static func suggestedFields(for item: AIProposalItem, taskSpec: AIProposalTask) -> [String] {
        var fields: [String] = []
        if taskSpec.planId != nil,
           item.confidence < AppDefaults.fallback.ai.classificationConfidenceThreshold {
            fields.append("planId")
        }
        if taskSpec.scheduledDate != nil, item.dateInterpretation?.resolvedDate == nil {
            fields.append("scheduledDate")
        }
        if taskSpec.priority != nil { fields.append("priority") }
        if !taskSpec.dependencyIds.isEmpty { fields.append("dependencyIDs") }
        return fields
    }

    /// 已解析的日期（优先 date_interpretation.resolved_date，其次 scheduled_date）
    static func resolvedDay(item: AIProposalItem, spec: AIProposalTask?,
                            today: DateOnly, timeZone: TimeZone) -> DateOnly? {
        let raw = item.dateInterpretation?.resolvedDate ?? spec?.scheduledDate
        guard let raw, !raw.isEmpty else { return nil }
        guard let day = DateOnly(iso8601DateString: dayPrefix(raw), sourceTZ: timeZone.identifier) else {
            return nil
        }
        return day < today ? today : day
    }

    /// 依赖成环检测（C9）
    static func wouldCreateCycle(taskID: UUID, dependsOn: UUID, tasks: [UUID: Task]) -> Bool {
        var stack = [dependsOn]
        var visited: Set<UUID> = []
        while let current = stack.popLast() {
            if current == taskID { return true }
            guard visited.insert(current).inserted else { continue }
            stack.append(contentsOf: tasks[current]?.dependencyIDs ?? [])
        }
        return false
    }

    /// `12` → `12`；`12.5` → `12.5`
    static func formatValue(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
