//
//  TaskCommands.swift
//  Domain/Commands
//
//  CreateTask / UpdateTask / ScheduleTask / SetDeadline / CompleteTask /
//  ReopenTask / CancelTask / ReassignTask
//  AC02：scheduledDate（哪天做）与 hardDeadline（最晚完成）分别编辑，不自动联动。
//

import Foundation

public struct RecurrenceDraft: Sendable, Hashable {
    public var pattern: RecurrencePattern
    public var weekdays: [Int]
    public var weeklyCount: Int?
    public var effectiveFrom: DateOnly
    public var effectiveUntil: DateOnly?

    public init(pattern: RecurrencePattern, weekdays: [Int] = [], weeklyCount: Int? = nil,
                effectiveFrom: DateOnly, effectiveUntil: DateOnly? = nil) {
        self.pattern = pattern; self.weekdays = weekdays; self.weeklyCount = weeklyCount
        self.effectiveFrom = effectiveFrom; self.effectiveUntil = effectiveUntil
    }
}

public struct CreateTask: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .createTask
    public let entityID: UUID
    public let entityType: EntityType = .task

    public var title: String
    public var planID: UUID?
    public var stageID: UUID?
    public var parentID: UUID?
    public var notes: String?
    public var scheduledDate: DateOnly?
    public var deadline: DateTimeTZ?
    public var timeHint: TimeOfDayHint?
    public var estimateMinutes: Int?
    public var priority: TaskPriority?
    public var tags: [String]
    public var dependencyIDs: [UUID]
    public var recurrence: RecurrenceDraft?
    public var source: SourceKind
    public var captureID: UUID?
    public var suggestedFields: [String]

    public init(operationID: UUID = UUID(), id: UUID = UUID(), title: String,
                planID: UUID? = nil, stageID: UUID? = nil, parentID: UUID? = nil, notes: String? = nil,
                scheduledDate: DateOnly? = nil, deadline: DateTimeTZ? = nil,
                timeHint: TimeOfDayHint? = nil, estimateMinutes: Int? = nil,
                priority: TaskPriority? = nil, tags: [String] = [], dependencyIDs: [UUID] = [],
                recurrence: RecurrenceDraft? = nil, source: SourceKind = .manual,
                captureID: UUID? = nil, suggestedFields: [String] = []) {
        self.operationID = operationID; self.entityID = id
        self.title = title; self.planID = planID; self.stageID = stageID; self.parentID = parentID
        self.notes = notes; self.scheduledDate = scheduledDate; self.deadline = deadline
        self.timeHint = timeHint; self.estimateMinutes = estimateMinutes; self.priority = priority
        self.tags = tags; self.dependencyIDs = dependencyIDs
        self.recurrence = recurrence; self.source = source; self.captureID = captureID
        self.suggestedFields = suggestedFields
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        try StructurePolicy.validateTitle(title)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try await StructurePolicy.validateExplicitReassign(to: planID, repository: context.repository)

        var task = Task(id: entityID, planId: planID, stageId: stageID, parentId: parentID,
                        title: trimmed, notes: notes, isTemplate: recurrence != nil, status: .todo,
                        scheduledDate: scheduledDate, hardDeadline: deadline, timeHint: timeHint,
                        estimateMinutes: estimateMinutes, priority: priority, tags: tags,
                        dependencyIDs: dependencyIDs, source: source, sourceCaptureId: captureID,
                        suggestedFields: suggestedFields, createdAt: context.now, updatedAt: context.now)
        // 新任务的 revision 由写入路径统一自增
        task.revision = 1
        // V6：硬截止必须含时刻 + 时区
        try Self.validateDeadline(task.hardDeadline)
        for dep in dependencyIDs {
            try await StructurePolicy.validateDependency(taskID: task.id, dependsOn: dep,
                                                         repository: context.repository)
        }
        try await StructurePolicy.validateTaskStructure(task, repository: context.repository,
                                                       requiresRecurrenceRule: recurrence == nil)

        // C4：模板任务必须先有规则——先落任务再落规则，随后复校验
        let saved = try await context.write(task, old: nil)

        if let draft = recurrence {
            var rule = RecurrenceRule(taskId: saved.id, pattern: draft.pattern,
                                      weekdays: draft.pattern == .weekdays ? draft.weekdays : nil,
                                      weeklyCount: draft.pattern == .weeklyCount ? draft.weeklyCount : nil,
                                      effectiveFrom: max(draft.effectiveFrom, context.today),
                                      effectiveUntil: draft.effectiveUntil)
            rule.createdAt = context.now
            try StructurePolicy.validateRuleFields(rule)
            _ = try await context.write(rule, old: nil)
            try await StructurePolicy.validateTaskStructure(saved, repository: context.repository)
        } else if task.isTemplate {
            throw MovoError.invalidStructure(reason: "重复行动必须带有重复频率。")
        }

        context.setUserMessage("已添加「\(saved.title)」")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }

    /// V6：is_hard_deadline=false 时禁止写 hard_deadline；硬截止必须含时刻 + 时区
    public static func validateDeadline(_ deadline: DateTimeTZ?) throws {
        guard let deadline else { return }
        guard TimeZone(identifier: deadline.tzID) != nil else {
            throw MovoError.invalidStructure(reason: "硬截止需要带上时区。")
        }
        guard deadline.epoch.timeIntervalSince1970 > 0 else {
            throw MovoError.invalidStructure(reason: "硬截止需要具体的日期与时刻。")
        }
    }
}

public struct TaskPatch: Sendable, Hashable {
    public var title: String?
    public var notes: String?
    public var planID: UUID?
    public var stageID: UUID?
    public var parentID: UUID?
    public var status: TaskStatus?
    public var timeHint: TimeOfDayHint?
    public var estimateMinutes: Int?
    public var priority: TaskPriority?
    public var tags: [String]?
    /// 安排日期（与硬截止分开，AC02）
    public var scheduledDate: DateOnly?
    public var clearNotes: Bool
    public var clearPriority: Bool
    public var clearEstimate: Bool
    public var clearTimeHint: Bool
    public var clearScheduledDate: Bool

    public init(title: String? = nil, notes: String? = nil, planID: UUID? = nil, stageID: UUID? = nil,
                parentID: UUID? = nil, status: TaskStatus? = nil, timeHint: TimeOfDayHint? = nil,
                estimateMinutes: Int? = nil, priority: TaskPriority? = nil, tags: [String]? = nil,
                scheduledDate: DateOnly? = nil,
                clearNotes: Bool = false, clearPriority: Bool = false, clearEstimate: Bool = false,
                clearTimeHint: Bool = false, clearScheduledDate: Bool = false) {
        self.title = title; self.notes = notes; self.planID = planID; self.stageID = stageID
        self.parentID = parentID; self.status = status; self.timeHint = timeHint
        self.estimateMinutes = estimateMinutes; self.priority = priority; self.tags = tags
        self.scheduledDate = scheduledDate
        self.clearNotes = clearNotes; self.clearPriority = clearPriority
        self.clearEstimate = clearEstimate; self.clearTimeHint = clearTimeHint
        self.clearScheduledDate = clearScheduledDate
    }

    public func apply(to task: Task) -> Task {
        var t = task
        if let title { t.title = title }
        if clearNotes { t.notes = nil } else if let notes { t.notes = notes }
        if let planID { t.planId = planID }
        if let stageID { t.stageId = stageID }
        if let parentID { t.parentId = parentID }
        if let status { t.status = status }
        if clearTimeHint { t.timeHint = nil } else if let timeHint { t.timeHint = timeHint }
        if clearEstimate { t.estimateMinutes = nil } else if let estimateMinutes { t.estimateMinutes = estimateMinutes }
        if clearPriority { t.priority = nil } else if let priority { t.priority = priority }
        if let tags { t.tags = tags }
        if clearScheduledDate { t.scheduledDate = nil } else if let scheduledDate { t.scheduledDate = scheduledDate }
        return t
    }

    public var isEmpty: Bool {
        title == nil && notes == nil && planID == nil && stageID == nil && parentID == nil
            && status == nil && timeHint == nil && estimateMinutes == nil && priority == nil
            && tags == nil && scheduledDate == nil
            && !clearNotes && !clearPriority && !clearEstimate && !clearTimeHint && !clearScheduledDate
    }
}

public struct UpdateTask: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .updateTask
    public var taskID: UUID
    public var entityID: UUID { taskID }
    public let entityType: EntityType = .task
    public var baseRevision: Int
    public var patch: TaskPatch
    /// 仅由 AI 采纳的字段会标"建议"（PRD 4.2）
    public var aiSuggestedFields: [String]

    public init(operationID: UUID = UUID(), taskID: UUID, patch: TaskPatch, baseRevision: Int = 0,
                aiSuggestedFields: [String] = []) {
        self.operationID = operationID; self.taskID = taskID; self.patch = patch
        self.baseRevision = baseRevision; self.aiSuggestedFields = aiSuggestedFields
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        try await StructurePolicy.requireWritable(id: taskID, type: .task, repository: context.repository)
        try context.assertDeclaredRevision(actual: old.revision, entityID: taskID)

        var baseline = old
        let changesStructure = patch.parentID.map { $0 != old.parentId } == true
            || patch.planID.map { $0 != old.planId } == true
            || patch.stageID.map { $0 != old.stageId } == true
        if changesStructure {
            let parent = patch.parentID ?? ((patch.planID != nil || patch.stageID != nil) ? nil : old.parentId)
            let stage = patch.stageID ?? (patch.planID.map { $0 != old.planId } == true ? nil : old.stageId)
            _ = try await ReassignTask(operationID: operationID, taskID: taskID,
                                       planID: patch.planID ?? old.planId,
                                       stageID: stage,
                                       baseRevision: old.revision, parentID: parent).execute(in: context)
            baseline = await context.repository.task(taskID) ?? old
        }
        var updated = patch.apply(to: baseline)
        if patch.status == .done || patch.status == .cancelled {
            let deleted = Set(await context.repository.tombstones(activeOnly: true).map(\.entityId))
            let children = await context.repository.children(of: taskID)
            if children.contains(where: { !deleted.contains($0.id) && $0.status != .cancelled }) {
                throw MovoError.invalidStructure(reason: "请逐项处理子任务；父任务进度会自动汇总。")
            }
        }
        if let title = patch.title { try StructurePolicy.validateTitle(title) }
        if !aiSuggestedFields.isEmpty {
            updated.suggestedFields = Array(Set(old.suggestedFields + aiSuggestedFields)).sorted()
        }
        // 归属变化：校验目标计划与阶段
        if patch.planID != nil || patch.stageID != nil {
            try await StructurePolicy.validateExplicitReassign(to: updated.planId, repository: context.repository)
        }
        if updated.parentId != old.parentId {
            let newParent = updated.parentId.flatMap { id in old.parentId == id ? nil : id }
            if let parentID = newParent {
                let parent = await context.repository.task(parentID)
                try await StructurePolicy.validateReparent(child: updated, to: parent,
                                                           repository: context.repository)
            }
        }
        try await StructurePolicy.validateTaskStructure(updated, repository: context.repository)

        let saved = try await context.write(updated, old: baseline)
        context.setUserMessage("已更新「\(saved.title)」")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

// MARK: - 安排日期（独立于硬截止，AC02）

public struct ScheduleTask: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .scheduleTask
    public var taskID: UUID
    public var entityID: UUID { taskID }
    public let entityType: EntityType = .task
    public var baseRevision: Int
    public var date: DateOnly?

    public init(operationID: UUID = UUID(), taskID: UUID, date: DateOnly?, baseRevision: Int = 0) {
        self.operationID = operationID; self.taskID = taskID; self.date = date; self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: taskID)
        var updated = old
        updated.scheduledDate = date
        updated.updatedAt = context.now
        let saved = try await context.write(updated, old: old)
        context.setUserMessage(date.map { "已安排到 \($0.displayStringWithWeekday)" } ?? "已清除安排日期")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

// MARK: - 硬截止（改截止走确认预览，PRD 10.2）

public struct SetDeadline: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .setDeadline
    public var taskID: UUID
    public var entityID: UUID { taskID }
    public let entityType: EntityType = .task
    public var baseRevision: Int
    public var deadline: DateTimeTZ?
    public var reason: String?

    public init(operationID: UUID = UUID(), taskID: UUID, deadline: DateTimeTZ?,
                baseRevision: Int = 0, reason: String? = nil) {
        self.operationID = operationID; self.taskID = taskID; self.deadline = deadline
        self.baseRevision = baseRevision; self.reason = reason
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: taskID)
        try CreateTask.validateDeadline(deadline)

        var updated = old
        updated.hardDeadline = deadline
        updated.updatedAt = context.now
        context.setReason(reason)
        let saved = try await context.write(updated, old: old)
        context.setUserMessage(deadline.map { "硬截止设为 \($0.displayString)" } ?? "已清除硬截止")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

// MARK: - 完成 / 重开 / 取消

public struct CompleteTask: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .completeTask
    public var taskID: UUID
    public var entityID: UUID { taskID }
    public let entityType: EntityType = .task
    public var baseRevision: Int
    public var at: TimeValue
    /// 由 AI 本地规则唯一匹配触发的完成（PRD 10.2）
    public var reason: String?

    public init(operationID: UUID = UUID(), taskID: UUID, at: TimeValue,
                baseRevision: Int = 0, reason: String? = nil) {
        self.operationID = operationID; self.taskID = taskID; self.at = at
        self.baseRevision = baseRevision; self.reason = reason
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        try await StructurePolicy.requireWritable(id: taskID, type: .task, repository: context.repository)
        try context.assertDeclaredRevision(actual: old.revision, entityID: taskID)
        guard old.status != .done else {
            throw MovoError.invalidStructure(reason: "「\(old.title)」已经完成了。")
        }

        let deleted = Set(await context.repository.tombstones(activeOnly: true).map(\.entityId))
        let children = await context.repository.children(of: taskID)
        if children.contains(where: { !deleted.contains($0.id) && $0.status != .cancelled }) {
            throw MovoError.invalidStructure(reason: "这项待办的进度由子任务汇总，请完成具体子任务。")
        }

        // 模板任务 → 转 CompleteOccurrence（当次完成不影响未来实例 AC13）
        if old.isTemplate {
            return try await Self.completeTemplateOccurrence(task: old, at: at, context: context,
                                                            operationID: operationID)
        }

        var updated = old
        updated.status = .done
        updated.doneAt = context.now
        updated.updatedAt = context.now
        context.setOccurredAt(at.sortEpoch)
        context.setReason(reason)
        let saved = try await context.write(updated, old: old)

        // 完成或取消前置后即时更新依赖派生（不落库）
        let dependents = await StructurePolicy.dependents(of: taskID, repository: context.repository)
        var unlockedCount = 0
        for dependent in dependents where await isReady(dependent, context: context) { unlockedCount += 1 }
        context.setUserMessage(unlockedCount == 0
            ? "已完成「\(saved.title)」"
            : "已完成「\(saved.title)」，\(unlockedCount) 项前置就绪")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision,
                             occurredAt: at.sortEpoch)
    }

    /// 完成前置后该后继是否已就绪（派生，不落库）
    private func isReady(_ task: Task, context: CommandContext) async -> Bool {
        guard let planID = task.planId else { return false }
        let siblings = await context.repository.tasks(planID: planID)
        let tombstoned = Set(await context.repository.tombstones(activeOnly: true).map(\.entityId))
        return DependencyPolicy.status(for: task, planTasks: siblings, tombstoned: tombstoned).isReady
    }

    @MainActor
    static func completeTemplateOccurrence(task: Task, at: TimeValue, context: CommandContext,
                                           operationID: UUID) async throws -> CommandResult {
        guard let rule = await context.repository.rule(forTask: task.id) else {
            throw MovoError.invalidStructure(reason: "这条重复行动缺少频率设置，无法记录本次。")
        }
        let existing = await context.repository.occurrences(ruleID: rule.id)
        let day = at.dateOnly ?? DateOnly(from: at.sortEpoch, in: context.timeZone)

        if rule.pattern == .weeklyCount {
            // weeklyCount：生成 occurredOn 实例
            let occurrence = RecurrenceOccurrence(ruleId: rule.id, ruleVersion: rule.version,
                                                  taskId: task.id, planId: task.planId,
                                                  scheduledOn: nil, occurredOn: day,
                                                  status: .done, doneAt: context.now)
            try await StructurePolicy.validateOccurrence(occurrence, repository: context.repository)
            let saved = try await context.write(occurrence, old: nil)
            context.setOccurredAt(at.sortEpoch)
            context.setUserMessage("已记录「\(task.title)」本周第 \(existing.filter { $0.status == .done }.count + 1) 次")
            return CommandResult(operationID: operationID, entityID: saved.id,
                                 changedFields: context.changedFields,
                                 userMessage: context.userMessage, newRevision: saved.revision,
                                 occurredAt: at.sortEpoch)
        }

        // 固定日期模式：找该 day 的实例；没有则新建后完成
        var target = existing.first { $0.scheduledOn == day }
        if target == nil {
            var created = RecurrencePolicy.makeOccurrence(rule: rule, day: day, planId: task.planId)
            try await StructurePolicy.validateOccurrence(created, repository: context.repository)
            created = try await context.write(created, old: nil)
            target = created
        }
        guard let occurrence = target else {
            throw MovoError.invalidStructure(reason: "没有找到这一天的重复安排。")
        }
        guard occurrence.status == .pending else {
            throw MovoError.invalidStructure(reason: "这一天已经记录了。")
        }
        var updated = occurrence
        updated.status = .done
        updated.occurredOn = day
        updated.doneAt = context.now
        let saved = try await context.write(updated, old: occurrence)
        context.setOccurredAt(at.sortEpoch)
        context.setUserMessage("已完成「\(task.title)」本次（未来实例不受影响）")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision,
                             occurredAt: at.sortEpoch)
    }
}

public struct ReopenTask: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .reopenTask
    public var taskID: UUID
    public var entityID: UUID { taskID }
    public let entityType: EntityType = .task
    public var baseRevision: Int

    public init(operationID: UUID = UUID(), taskID: UUID, baseRevision: Int = 0) {
        self.operationID = operationID; self.taskID = taskID; self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: taskID)
        guard old.status == .done || old.status == .cancelled else {
            throw MovoError.invalidStructure(reason: "「\(old.title)」当前不需要重新打开。")
        }
        var updated = old
        updated.status = .todo
        // 重开保留历史事件：只清空结果字段，不删除任何记录
        updated.doneAt = nil
        updated.cancelledAt = nil
        updated.updatedAt = context.now
        let saved = try await context.write(updated, old: old)
        context.setUserMessage("已重新打开「\(saved.title)」，历史记录都保留着。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct CancelTask: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .cancelTask
    public var taskID: UUID
    public var entityID: UUID { taskID }
    public let entityType: EntityType = .task
    public var baseRevision: Int
    public var reason: String?

    public init(operationID: UUID = UUID(), taskID: UUID, baseRevision: Int = 0, reason: String? = nil) {
        self.operationID = operationID; self.taskID = taskID
        self.baseRevision = baseRevision; self.reason = reason
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: taskID)
        var updated = old
        updated.status = .cancelled
        try await StructurePolicy.requireWritable(id: taskID, type: .task, repository: context.repository)
        let deleted = Set(await context.repository.tombstones(activeOnly: true).map(\.entityId))
        let children = await context.repository.children(of: taskID)
        if children.contains(where: { !deleted.contains($0.id) && $0.status != .cancelled }) {
            throw MovoError.invalidStructure(reason: "请逐项取消子任务，或预览后删除整项待办。")
        }
        updated.cancelledAt = context.now
        updated.updatedAt = context.now
        context.setReason(reason)
        let saved = try await context.write(updated, old: old)

        // 取消的叶子不当作已完成，但也不阻断后继：报告被解除的依赖
        let dependents = await StructurePolicy.dependents(of: taskID, repository: context.repository)
        context.addReleasedDependencies(dependents.count)
        context.setUserMessage("已取消「\(saved.title)」。它不再计入进度，也不阻断后续任务。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

// MARK: - 调整归属（REQ 06）

public struct ReassignTask: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .reassignTask
    public var taskID: UUID
    public var entityID: UUID { taskID }
    public let entityType: EntityType = .task
    public var baseRevision: Int
    public var planID: UUID?
    public var stageID: UUID?
    public var parentID: UUID?
    public var reason: String?
    public var keepStandalone: Bool

    public init(operationID: UUID = UUID(), taskID: UUID, planID: UUID?, stageID: UUID? = nil,
                baseRevision: Int = 0, reason: String? = nil, keepStandalone: Bool = false,
                parentID: UUID? = nil) {
        self.operationID = operationID; self.taskID = taskID; self.planID = planID
        self.stageID = stageID; self.baseRevision = baseRevision; self.reason = reason
        self.keepStandalone = keepStandalone; self.parentID = parentID
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        try await StructurePolicy.requireWritable(id: taskID, type: .task, repository: context.repository)
        try context.assertDeclaredRevision(actual: old.revision, entityID: taskID)
        let deleted = Set(await context.repository.tombstones(activeOnly: true).map(\.entityId))
        let all = await context.repository.allTasks()
        let descendants = TaskHierarchy.descendants(of: taskID, in: all)
        let moving = [old] + descendants.filter { !deleted.contains($0.id) }
        let ids = Set(moving.map(\.id))
        var destinationPlan = keepStandalone ? nil : planID
        var destinationStage = keepStandalone ? nil : stageID
        if let parentID {
            guard !ids.contains(parentID), let parent = await context.repository.task(parentID) else {
                throw MovoError.invalidStructure(reason: "不能移动到自己或自己的子任务下。")
            }
            destinationPlan = parent.planId
            destinationStage = parent.stageId
        }
        try await StructurePolicy.validateExplicitReassign(to: destinationPlan, repository: context.repository)
        context.setReason(reason)
        for task in moving {
            var updated = task
            updated.planId = destinationPlan
            updated.stageId = destinationStage
            if task.id == taskID { updated.parentId = parentID }
            // 跨计划解除外部前置，保留同一子树内部的前置关系。
            if destinationPlan != task.planId {
                updated.dependencyIDs = task.dependencyIDs.filter { id in
                    destinationPlan != nil && (ids.contains(id) || all.contains {
                        $0.id == id && $0.planId == destinationPlan && !deleted.contains(id)
                    })
                }
                context.addReleasedDependencies(task.dependencyIDs.count - updated.dependencyIDs.count)
            }
            try await StructurePolicy.validateTaskStructure(updated, repository: context.repository)
            updated.updatedAt = context.now
            _ = try await context.write(updated, old: task)
            // 实例沿用模板的新归属；历史行动记录保留发生时的计划。
            for occurrence in await context.repository.occurrences(taskID: task.id)
                where occurrence.planId != destinationPlan && !deleted.contains(occurrence.id) {
                var updatedOccurrence = occurrence
                updatedOccurrence.planId = destinationPlan
                _ = try await context.write(updatedOccurrence, old: occurrence)
            }
        }
        // 原计划中的外部任务不能继续依赖已移走的任务。
        if old.planId != destinationPlan {
            for task in all where !ids.contains(task.id) && !deleted.contains(task.id) {
                let dependencies = task.dependencyIDs.filter { !ids.contains($0) }
                guard dependencies != task.dependencyIDs else { continue }
                var updated = task
                updated.dependencyIDs = dependencies
                updated.updatedAt = context.now
                _ = try await context.write(updated, old: task)
            }
        }
        context.setUserMessage("已移动「\(old.title)」及 \(moving.count - 1) 项子任务")
        return CommandResult(operationID: operationID, entityID: taskID,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: old.revision + 1)
    }

    @MainActor
    static func undo(operationID: UUID, context: CommandContext) async throws {
        let events = await context.repository.allEvents().filter { $0.operationId == operationID }
            .sorted { $0.newRevision > $1.newRevision }
        for event in events {
            if event.entityType == .task, let old = await context.repository.task(event.entityId) {
                var values = try JSONDiff.dictionary(old)
                for (field, patch) in event.patch where field != "revision" { values[field] = patch.old }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                var restored = try decoder.decode(Task.self, from: JSONEncoder().encode(values))
                restored.updatedAt = context.now
                _ = try await context.write(restored, old: old)
            } else if event.entityType == .occurrence,
                      let old = await context.repository.occurrence(event.entityId),
                      let patch = event.patch["planId"] {
                var restored = old
                restored.planId = patch.old.stringValue.flatMap(UUID.init(uuidString:))
                _ = try await context.write(restored, old: old)
            }
        }
        // 所有旧归属恢复后统一验证，避免半棵树回退到已删除的父任务或形成环。
        for id in Set(events.filter { $0.entityType == .task }.map(\.entityId)) {
            if let task = await context.repository.task(id) {
                try await StructurePolicy.validateTaskStructure(task, repository: context.repository)
            }
        }
    }
}
