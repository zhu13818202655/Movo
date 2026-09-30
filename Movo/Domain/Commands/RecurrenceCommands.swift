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

    public init(operationID: UUID = UUID(), id: UUID = UUID(), taskID: UUID, pattern: RecurrencePattern,
                weekdays: [Int] = [], weeklyCount: Int? = nil,
                effectiveFrom: DateOnly, effectiveUntil: DateOnly? = nil) {
        self.operationID = operationID; self.entityID = id; self.taskID = taskID; self.pattern = pattern
        self.weekdays = weekdays; self.weeklyCount = weeklyCount
        self.effectiveFrom = effectiveFrom; self.effectiveUntil = effectiveUntil
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let task = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        guard await context.repository.rule(forTask: taskID) == nil else {
            throw MovoError.invalidStructure(reason: "「\(task.title)」已经有重复频率了，可以直接修改它。")
        }
        var rule = RecurrenceRule(id: entityID, taskId: taskID, pattern: pattern,
                                  weekdays: pattern == .weekdays ? weekdays : nil,
                                  weeklyCount: pattern == .weeklyCount ? weeklyCount : nil,
                                  effectiveFrom: max(effectiveFrom, context.today),
                                  effectiveUntil: effectiveUntil)
        rule.createdAt = context.now
        try StructurePolicy.validateRuleFields(rule)
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

    public init(operationID: UUID = UUID(), ruleID: UUID, pattern: RecurrencePattern,
                weekdays: [Int] = [], weeklyCount: Int? = nil, effectiveFrom: DateOnly,
                baseRevision: Int = 0) {
        self.operationID = operationID; self.ruleID = ruleID; self.pattern = pattern
        self.weekdays = weekdays; self.weeklyCount = weeklyCount
        self.effectiveFrom = effectiveFrom; self.baseRevision = baseRevision
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
            effectiveFrom: effectiveFrom, today: context.today)
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
