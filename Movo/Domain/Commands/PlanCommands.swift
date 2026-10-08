//
//  PlanCommands.swift
//  Domain/Commands
//
//  CreatePlan / UpdatePlan / PausePlan / ResumePlan / DeletePlan / RestoreEntity
//

import Foundation

// MARK: - Patch 定义

public struct PlanPatch: Sendable, Hashable {
    public var name: String?
    public var kind: PlanKind?
    public var category: PlanCategory?
    public var goalText: String?
    public var startAt: TimePoint?
    public var endAt: TimePoint?
    public var clearStartAt: Bool
    public var clearEndAt: Bool
    public var aliases: [String]?
    public var contextPhrases: [String]?
    public var excludedTerms: [String]?
    public var cloudAIEnabled: Bool?
    public var syncEnabled: Bool?
    public var status: PlanStatus?
    public var sortIndex: Int?

    public init(name: String? = nil, kind: PlanKind? = nil, category: PlanCategory? = nil,
                goalText: String? = nil, startAt: TimePoint? = nil, endAt: TimePoint? = nil,
                clearStartAt: Bool = false, clearEndAt: Bool = false, aliases: [String]? = nil,
                contextPhrases: [String]? = nil, excludedTerms: [String]? = nil,
                cloudAIEnabled: Bool? = nil, syncEnabled: Bool? = nil,
                status: PlanStatus? = nil, sortIndex: Int? = nil) {
        self.name = name; self.kind = kind; self.category = category
        self.goalText = goalText; self.startAt = startAt; self.endAt = endAt
        self.clearStartAt = clearStartAt; self.clearEndAt = clearEndAt
        self.aliases = aliases; self.contextPhrases = contextPhrases; self.excludedTerms = excludedTerms
        self.cloudAIEnabled = cloudAIEnabled; self.syncEnabled = syncEnabled
        self.status = status; self.sortIndex = sortIndex
    }

    public func apply(to plan: Plan) -> Plan {
        var p = plan
        if let name { p.name = name }
        if let kind { p.kind = kind }
        if let category { p.category = category }
        if let goalText { p.goalText = goalText }
        if clearStartAt { p.startAt = nil } else if let startAt { p.startAt = startAt }
        if clearEndAt { p.endAt = nil } else if let endAt { p.endAt = endAt }
        if let aliases { p.aliases = aliases }
        if let contextPhrases { p.contextPhrases = contextPhrases }
        if let excludedTerms { p.excludedTerms = excludedTerms }
        if let cloudAIEnabled { p.cloudAIEnabled = cloudAIEnabled }
        if let syncEnabled { p.syncEnabled = syncEnabled }
        if let status { p.status = status }
        if let sortIndex { p.sortIndex = sortIndex }
        return p
    }

    public var isEmpty: Bool {
        name == nil && kind == nil && category == nil && goalText == nil
            && startAt == nil && endAt == nil && !clearStartAt && !clearEndAt
            && aliases == nil && contextPhrases == nil && excludedTerms == nil
            && cloudAIEnabled == nil && syncEnabled == nil && status == nil && sortIndex == nil
    }

    /// patch 是否改动了逐计划「同步到 iCloud」开关（默认开启，可逐计划关闭）
    public var touchesSyncSwitch: Bool { syncEnabled != nil }
}

public struct StageDraft: Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var criteriaText: String?
    public var startAt: TimePoint?
    public var endAt: TimePoint?
    public init(id: UUID = UUID(), name: String, criteriaText: String? = nil,
                startAt: TimePoint? = nil, endAt: TimePoint? = nil) {
        self.id = id; self.name = name; self.criteriaText = criteriaText
        self.startAt = startAt; self.endAt = endAt
    }
}

public struct MetricDraft: Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var unit: String
    public var targetValue: Double?
    public var targetDirection: MetricDirection
    public init(id: UUID = UUID(), name: String, unit: String,
                targetValue: Double? = nil, targetDirection: MetricDirection = .none) {
        self.id = id; self.name = name; self.unit = unit
        self.targetValue = targetValue; self.targetDirection = targetDirection
    }
}

// MARK: - CreatePlan

public struct CreatePlan: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .createPlan
    public let entityID: UUID
    public let entityType: EntityType = .plan
    public let baseRevision: Int = 0

    public var name: String
    public var planKind: PlanKind
    public var category: PlanCategory?
    public var goal: String?
    public var startAt: TimePoint?
    public var endAt: TimePoint?
    public var stages: [StageDraft]
    public var metrics: [MetricDraft]
    public var aliases: [String]
    public var contextPhrases: [String]
    public var cloudAIEnabled: Bool?
    public var syncEnabled: Bool

    public init(operationID: UUID = UUID(), id: UUID = UUID(), name: String, kind: PlanKind,
                category: PlanCategory? = nil, goal: String? = nil,
                startAt: TimePoint? = nil, endAt: TimePoint? = nil,
                stages: [StageDraft] = [], metrics: [MetricDraft] = [],
                aliases: [String] = [], contextPhrases: [String] = [],
                cloudAIEnabled: Bool? = nil, syncEnabled: Bool = true) {
        self.operationID = operationID; self.entityID = id; self.name = name; self.planKind = kind
        self.category = category; self.goal = goal; self.startAt = startAt; self.endAt = endAt
        self.stages = stages; self.metrics = metrics; self.aliases = aliases
        self.contextPhrases = contextPhrases; self.cloudAIEnabled = cloudAIEnabled
        self.syncEnabled = syncEnabled
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        try StructurePolicy.validatePlanName(name)

        let plan = Plan(id: entityID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        kind: planKind, category: category, goalText: goal,
                        startAt: startAt, endAt: endAt,
                        aliases: aliases, contextPhrases: contextPhrases,
                        cloudAIEnabled: cloudAIEnabled, syncEnabled: syncEnabled,
                        status: .active, createdAt: context.now, updatedAt: context.now)
        try await StructurePolicy.validatePlanTime(plan, old: nil, repository: context.repository)
        let saved = try await context.write(plan, old: nil)

        var created = 1
        for (index, draft) in stages.enumerated() {
            var stage = Stage(planId: saved.id, name: draft.name, criteriaText: draft.criteriaText,
                              startAt: draft.startAt, endAt: draft.endAt, sortIndex: index)
            stage.id = draft.id
            try await StructurePolicy.validateStageTime(stage, old: nil, repository: context.repository)
            _ = try await context.write(stage, old: nil)
            created += 1
        }
        for draft in metrics {
            try StructurePolicy.validateMetricUnit(draft.unit)
            var metric = PlanMetric(planId: saved.id, name: draft.name, unit: draft.unit,
                                    targetValue: draft.targetValue, targetDirection: draft.targetDirection)
            metric.id = draft.id
            _ = try await context.write(metric, old: nil)
            created += 1
        }

        context.setUserMessage("已建立计划「\(saved.name)」" + (created > 1 ? "，含 \(created - 1) 项结构" : ""))
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

// MARK: - UpdatePlan

public struct UpdatePlan: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .updatePlan
    public var planID: UUID
    public var entityID: UUID { planID }
    public let entityType: EntityType = .plan
    public var baseRevision: Int
    public var patch: PlanPatch
    /// 改动原因的原始说明（历史详情展示）
    public var reason: String?

    public init(operationID: UUID = UUID(), planID: UUID, patch: PlanPatch,
                baseRevision: Int = 0, reason: String? = nil) {
        self.operationID = operationID; self.planID = planID; self.patch = patch
        self.baseRevision = baseRevision; self.reason = reason
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.plan(planID) else {
            throw MovoError.notFound(entityType: .plan, id: planID)
        }
        try await StructurePolicy.requireWritable(id: planID, type: .plan, repository: context.repository)
        try context.assertDeclaredRevision(actual: old.revision, entityID: planID)
        if patch.isEmpty { return CommandResult(operationID: operationID, entityID: planID,
                                                userMessage: "没有需要保存的修改。", newRevision: old.revision) }
        if let newName = patch.name { try StructurePolicy.validatePlanName(newName) }

        var updated = patch.apply(to: old)
        updated.updatedAt = context.now
        try await StructurePolicy.validatePlanTime(updated, old: old, repository: context.repository)
        // 起止时间变更 → 记调整事件
        if updated.startAt != old.startAt || updated.endAt != old.endAt {
            context.setReason(reason)
        }
        let saved = try await context.write(updated, old: old)
        context.setUserMessage("已更新「\(saved.name)」")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

// MARK: - PausePlan / ResumePlan

public struct PausePlan: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .pausePlan
    public var planID: UUID
    public var entityID: UUID { planID }
    public let entityType: EntityType = .plan
    public var baseRevision: Int
    public var from: DateOnly

    public init(operationID: UUID = UUID(), planID: UUID, from: DateOnly, baseRevision: Int = 0) {
        self.operationID = operationID; self.planID = planID; self.from = from; self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.plan(planID) else {
            throw MovoError.notFound(entityType: .plan, id: planID)
        }
        guard old.status == .active else {
            throw MovoError.invalidStructure(reason: "「\(old.name)」当前是\(old.status.displayName)，无法再次暂停。")
        }
        var updated = old
        updated.status = .paused
        updated.pausedAt = from
        updated.resumedAt = nil
        updated.updatedAt = context.now

        let saved = try await context.write(updated, old: old)
        context.setUserMessage("已暂停「\(saved.name)」。暂停期间不会生成重复行动的实例。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct ResumePlan: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .resumePlan
    public var planID: UUID
    public var entityID: UUID { planID }
    public let entityType: EntityType = .plan
    public var baseRevision: Int
    public var from: DateOnly

    public init(operationID: UUID = UUID(), planID: UUID, from: DateOnly, baseRevision: Int = 0) {
        self.operationID = operationID; self.planID = planID; self.from = from; self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.plan(planID) else {
            throw MovoError.notFound(entityType: .plan, id: planID)
        }
        guard old.status == .paused || old.pausedAt != nil else {
            throw MovoError.invalidStructure(reason: "这个计划当前没有处于暂停状态。")
        }
        var updated = old
        updated.status = .active
        updated.resumedAt = from
        updated.updatedAt = context.now

        let saved = try await context.write(updated, old: old)
        // 恢复记 resumedAt，重复规则从 from 起实例化、**不补造**（AC20）
        context.setUserMessage("已恢复「\(saved.name)」，从 \(from.displayString) 继续。暂停期间的安排不会补做。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

// MARK: - DeletePlan（级联 Tombstone）

public struct DeletePlan: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .deletePlan
    public var planID: UUID
    public var entityID: UUID { planID }
    public let entityType: EntityType = .plan
    public var baseRevision: Int

    public init(operationID: UUID = UUID(), planID: UUID, baseRevision: Int = 0) {
        self.operationID = operationID; self.planID = planID; self.baseRevision = baseRevision
    }

    /// 级联清单预览：计划 + 全部后代（带实体类型，供级联 Tombstone 与预览使用）
    public static func cascadeTargets(planID: UUID, repository: DomainRepository) async -> [(EntityType, UUID)] {
        var out: [(EntityType, UUID)] = [(.plan, planID)]
        let stages = await repository.stages(planID: planID)
        out.append(contentsOf: stages.map { (.stage, $0.id) })
        let metrics = await repository.metrics(planID: planID)
        out.append(contentsOf: metrics.map { (.metric, $0.id) })
        let tasks = await repository.tasks(planID: planID)
        out.append(contentsOf: tasks.map { (.task, $0.id) })
        for task in tasks {
            if let rule = await repository.rule(forTask: task.id) { out.append((.rule, rule.id)) }
        }
        let occurrences = await repository.occurrences(planID: planID)
        out.append(contentsOf: occurrences.map { (.occurrence, $0.id) })
        let activities = await repository.activities(planID: planID)
        out.append(contentsOf: activities.map { (.activity, $0.id) })
        let measurements = await repository.measurements(planID: planID)
        out.append(contentsOf: measurements.map { (.measurement, $0.id) })
        let notes = await repository.notes(planID: planID)
        out.append(contentsOf: notes.map { (.note, $0.id) })
        return out
    }

    public static func cascadeIDs(planID: UUID, repository: DomainRepository) async -> [UUID] {
        await cascadeTargets(planID: planID, repository: repository).map(\.1)
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let plan = await context.repository.plan(planID) else {
            throw MovoError.notFound(entityType: .plan, id: planID)
        }
        try context.assertDeclaredRevision(actual: plan.revision, entityID: planID)

        let targets = await DeletePlan.cascadeTargets(planID: planID, repository: context.repository)
        let retention = context.defaults.lifecycle.tombstoneRetentionDays
        for (type, id) in targets {
            let tombstone = Tombstone(entityType: type, entityId: id, deletedAt: context.now,
                                      deviceId: context.deviceId, retentionDays: retention)
            _ = try await context.write(tombstone, old: nil)
        }
        // 计划的 status 保持原值；"已删除"由 Tombstone 表达（3.1）
        context.setUserMessage("已把「\(plan.name)」及其 \(targets.count - 1) 项内容移到最近删除，30 天内可以恢复。")
        return CommandResult(operationID: operationID, entityID: planID,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: plan.revision + 1)
    }
}

// MARK: - RestoreEntity

public struct RestoreEntity: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .restoreEntity
    public var targetType: EntityType
    public var targetID: UUID
    public var entityID: UUID { targetID }
    public var entityType: EntityType { targetType }

    public init(operationID: UUID = UUID(), entityType: EntityType, id: UUID) {
        self.operationID = operationID; self.targetType = entityType; self.targetID = id
    }

    /// 恢复不补造历史行动（9.5）
    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        let all = await context.repository.tombstones(activeOnly: true)
        guard let tombstone = all.first(where: { $0.entityId == targetID }) else {
            throw MovoError.notFound(entityType: .tombstone, id: targetID)
        }
        guard tombstone.isRecoverable(at: context.now) else {
            throw MovoError.invalidStructure(reason: "这项内容已超过 30 天保留期，无法恢复。")
        }
        if targetType == .task, let task = await context.repository.task(targetID) {
            if let planID = task.planId {
                try await StructurePolicy.requireWritable(id: planID, type: .plan, repository: context.repository)
            }
            if let parentID = task.parentId {
                try await StructurePolicy.requireWritable(id: parentID, type: .task, repository: context.repository)
            }
            // 只恢复同一次删除中的后代，不能复活之前单独删除的内容。
            let ids = Set([targetID] + TaskHierarchy.descendants(
                of: targetID, in: await context.repository.allTasks()).map(\.id))
            let events = await context.repository.events(entityID: tombstone.id)
            if let deletion = events.first(where: { $0.baseRevision == 0 }) {
                let relatedEvents = await context.repository.allEvents().filter {
                    $0.operationId == deletion.operationId && $0.entityType == .tombstone
                }
                let relatedIDs = Set(relatedEvents.map(\.entityId))
                for candidate in all where candidate.id != tombstone.id
                    && relatedIDs.contains(candidate.id) && candidate.isRecoverable(at: context.now) {
                    var belongs = ids.contains(candidate.entityId)
                    if candidate.entityType == .rule, let rule = await context.repository.rule(candidate.entityId) {
                        belongs = ids.contains(rule.taskId)
                    }
                    if candidate.entityType == .occurrence,
                       let occurrence = await context.repository.occurrence(candidate.entityId) {
                        belongs = ids.contains(occurrence.taskId)
                    }
                    if belongs {
                        var restoredChild = candidate
                        restoredChild.restoredAt = context.now
                        _ = try await context.write(restoredChild, old: candidate)
                    }
                }
            }
        }
        var restored = tombstone
        restored.restoredAt = context.now
        let saved = try await context.write(restored, old: tombstone)

        // 计划本体从 archived 回到 active
        if targetType == .plan, let plan = await context.repository.plan(targetID) {
            var updated = plan
            updated.status = .active
            updated.updatedAt = context.now
            _ = try await context.write(updated, old: plan)
        }
        context.setUserMessage("已恢复。历史行动记录不会补造。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}
