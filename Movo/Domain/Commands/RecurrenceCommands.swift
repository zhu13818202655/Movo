//
//  RecurrenceCommands.swift
//  Domain/Commands
//
//  CreateRecurrence / ChangeRecurrence / CompleteOccurrence / SkipOccurrence
//  当次完成不影响未来实例（AC13）；规则变更仅作用于 effectiveFrom 及以后（AC22）。
//

import Foundation

public struct CreateRecurrence: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .createRecurrence
    public let entityID: UUID
    public let entityType: EntityType = .rule
    public var taskID: UUID
    public var pattern: RecurrencePattern
    public var weekdays: [Int]
    public var weeklyCount: Int?
    public var effectiveFrom: DateOnly
    public var effectiveUntil: DateOnly?
    public var dailyStart: TimeOfDay?
    public var dailyEnd: TimeOfDay?

    public init(operationID: UUID = UUID(), id: UUID = UUID(), taskID: UUID, pattern: RecurrencePattern,
                weekdays: [Int] = [], weeklyCount: Int? = nil,
                effectiveFrom: DateOnly, effectiveUntil: DateOnly? = nil,
                dailyStart: TimeOfDay? = nil, dailyEnd: TimeOfDay? = nil) {
        self.operationID = operationID; self.entityID = id; self.taskID = taskID; self.pattern = pattern
        self.weekdays = weekdays; self.weeklyCount = weeklyCount
        self.effectiveFrom = effectiveFrom; self.effectiveUntil = effectiveUntil
        self.dailyStart = dailyStart; self.dailyEnd = dailyEnd
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let task = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        guard await context.repository.rule(forTask: taskID) == nil else {
            throw MovoError.invalidStructure(reason: "「\(task.title)」已经有重复频率了，可以直接修改它。")
        }
        guard task.parentId == nil else {
            throw MovoError.invalidStructure(reason: "子任务和步骤不能单独设为重复行动。")
        }
        let tombstoned = Set(await context.repository.tombstones(activeOnly: true).map(\.entityId))
        let hasSubtasks = await context.repository.children(of: taskID).contains {
            !tombstoned.contains($0.id) && $0.status != .cancelled && !$0.isTemplate
        }
        guard !hasSubtasks else {
            throw MovoError.invalidStructure(reason: "有子任务的待办不能直接设为重复行动，可以先把子任务转成步骤。")
        }
        var rule = RecurrenceRule(id: entityID, taskId: taskID, pattern: pattern,
                                  weekdays: pattern == .weekdays ? weekdays : nil,
                                  weeklyCount: pattern == .weeklyCount ? weeklyCount : nil,
                                  effectiveFrom: max(effectiveFrom, context.today),
                                  effectiveUntil: effectiveUntil,
                                  dailyStart: dailyStart, dailyEnd: dailyEnd)
        rule.createdAt = context.now
        try StructurePolicy.validateRuleFields(rule)
        try await StructurePolicy.validateRuleTime(rule, task: task, repository: context.repository)
        let saved = try await context.write(rule, old: nil)

        // 挂上规则后任务成为模板
        if !task.isTemplate {
            var updated = task
            updated.isTemplate = true
            updated.updatedAt = context.now
            _ = try await context.write(updated, old: task)
        }
        context.setUserMessage("已设置重复频率：\(saved.ruleDescription)")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct ChangeRecurrence: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .changeRecurrence
    public var ruleID: UUID
    public var entityID: UUID { ruleID }
    public let entityType: EntityType = .rule
    public var baseRevision: Int
    public var pattern: RecurrencePattern
    public var weekdays: [Int]
    public var weeklyCount: Int?
    public var effectiveFrom: DateOnly
    /// 为 true 时用 effectiveUntil 整体替换重复结束日期；否则保留原值
    public var updatesEffectiveUntil: Bool
    public var effectiveUntil: DateOnly?
    /// 为 true 时用 dailyStart/dailyEnd 整体替换每天时刻；否则保留原有时刻
    public var updatesDailyTimes: Bool
    public var dailyStart: TimeOfDay?
    public var dailyEnd: TimeOfDay?

    public init(operationID: UUID = UUID(), ruleID: UUID, pattern: RecurrencePattern,
                weekdays: [Int] = [], weeklyCount: Int? = nil, effectiveFrom: DateOnly,
                updatesEffectiveUntil: Bool = false, effectiveUntil: DateOnly? = nil,
                updatesDailyTimes: Bool = false, dailyStart: TimeOfDay? = nil, dailyEnd: TimeOfDay? = nil,
                baseRevision: Int = 0) {
        self.operationID = operationID; self.ruleID = ruleID; self.pattern = pattern
        self.weekdays = weekdays; self.weeklyCount = weeklyCount
        self.effectiveFrom = effectiveFrom; self.baseRevision = baseRevision
        self.updatesEffectiveUntil = updatesEffectiveUntil; self.effectiveUntil = effectiveUntil
        self.updatesDailyTimes = updatesDailyTimes
        self.dailyStart = dailyStart; self.dailyEnd = dailyEnd
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.rule(ruleID) else {
            throw MovoError.notFound(entityType: .rule, id: ruleID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: ruleID)
        let updated = try RecurrencePolicy.nextVersion(
            of: old, pattern: pattern,
            weekdays: pattern == .weekdays ? weekdays : nil,
            weeklyCount: pattern == .weeklyCount ? weeklyCount : nil,
            effectiveFrom: effectiveFrom, today: context.today,
            updatesEffectiveUntil: updatesEffectiveUntil, effectiveUntil: effectiveUntil,
            updatesDailyTimes: updatesDailyTimes, dailyStart: dailyStart, dailyEnd: dailyEnd)
        if let task = await context.repository.task(old.taskId) {
            try await StructurePolicy.validateRuleTime(updated, task: task, repository: context.repository)
        }
        let saved = try await context.write(updated, old: old)

        // 旧版本已实例化实例与历史不受影响（AC22）：只对 effectiveFrom 之后做实例化规划
        context.setUserMessage("已从 \(saved.effectiveFrom.displayString) 起改为\(saved.ruleDescription)。已记录和跳过的历史保留不变。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct CompleteOccurrence: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .completeOccurrence
    public var occurrenceID: UUID
    public var entityID: UUID { occurrenceID }
    public let entityType: EntityType = .occurrence
    public var baseRevision: Int
    public var at: TimeValue
    public var durationMinutes: Int?
    public var note: String?

    public init(operationID: UUID = UUID(), occurrenceID: UUID, at: TimeValue,
                durationMinutes: Int? = nil, note: String? = nil, baseRevision: Int = 0) {
        self.operationID = operationID; self.occurrenceID = occurrenceID; self.at = at
        self.durationMinutes = durationMinutes; self.note = note; self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.occurrence(occurrenceID) else {
            throw MovoError.notFound(entityType: .occurrence, id: occurrenceID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: occurrenceID)
        guard old.status != .done else {
            throw MovoError.invalidStructure(reason: "这一次已经完成了。")
        }
        var updated = old
        updated.status = .done
        updated.occurredOn = at.dateOnly ?? old.scheduledOn ?? DateOnly(from: at.sortEpoch, in: context.timeZone)
        updated.doneAt = context.now
        try await StructurePolicy.validateOccurrence(updated, repository: context.repository)
        let saved = try await context.write(updated, old: old)
        context.setOccurredAt(at.sortEpoch)
        context.setUserMessage("已完成这一次。未来的安排不受影响。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision,
                             occurredAt: at.sortEpoch)
    }
}

public struct SkipOccurrence: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .skipOccurrence
    public var occurrenceID: UUID
    public var entityID: UUID { occurrenceID }
    public let entityType: EntityType = .occurrence
    public var baseRevision: Int
    public var at: TimeValue?

    public init(operationID: UUID = UUID(), occurrenceID: UUID, at: TimeValue? = nil, baseRevision: Int = 0) {
        self.operationID = operationID; self.occurrenceID = occurrenceID; self.at = at
        self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.occurrence(occurrenceID) else {
            throw MovoError.notFound(entityType: .occurrence, id: occurrenceID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: occurrenceID)
        var updated = old
        updated.status = .skipped
        // 只影响一次：本周完成数不增加、仍计入计划次数（PRD 3.3）
        let day = at?.dateOnly ?? old.scheduledOn ?? DateOnly(from: (at?.sortEpoch ?? context.now), in: context.timeZone)
        updated.occurredOn = day
        try await StructurePolicy.validateOccurrence(updated, repository: context.repository)
        let saved = try await context.write(updated, old: old)
        context.setUserMessage("已跳过这一次。本周次数不受影响，历史会保留这条记录。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

/// 勾选 / 取消勾选重复行动某一次里的一个步骤。
/// 第一次勾选时从模板当前的步骤拍快照；勾选步骤不会自动完成这一次，也不会改动模板。
public struct ToggleOccurrenceStep: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .toggleOccurrenceStep
    public var occurrenceID: UUID
    public var entityID: UUID { occurrenceID }
    public let entityType: EntityType = .occurrence
    public var baseRevision: Int
    public var stepID: UUID
    public var isDone: Bool

    public init(operationID: UUID = UUID(), occurrenceID: UUID, stepID: UUID, isDone: Bool,
                baseRevision: Int = 0) {
        self.operationID = operationID; self.occurrenceID = occurrenceID
        self.stepID = stepID; self.isDone = isDone; self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.occurrence(occurrenceID) else {
            throw MovoError.notFound(entityType: .occurrence, id: occurrenceID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: occurrenceID)
        guard old.status == .pending else {
            throw MovoError.invalidStructure(reason: "这一次已经结束，不能再改步骤。")
        }
        var steps: [OccurrenceStep]
        if let existing = old.steps {
            steps = existing
        } else {
            steps = await RecurrenceStepPolicy.snapshot(templateID: old.taskId,
                                                        repository: context.repository) ?? []
        }
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else {
            throw MovoError.notFound(entityType: .task, id: stepID)
        }
        let parents = Set(steps.compactMap(\.parentId))
        guard !parents.contains(stepID) else {
            throw MovoError.invalidStructure(reason: "上一级步骤由下面的步骤自动汇总，请勾选具体步骤。")
        }
        steps[index].isDone = isDone
        var updated = old
        updated.steps = RecurrenceStepPolicy.withDerivedParents(steps)
        let saved = try await context.write(updated, old: old)
        context.setUserMessage(isDone ? "已勾选步骤" : "已取消勾选")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}
