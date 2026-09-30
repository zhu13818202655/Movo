//
//  StageMetricCommands.swift
//  Domain/Commands
//
//  CreateStage / UpdateStage / CreateMetric / UpdateMetric
//  阶段达成只能由用户确认或预设明确规则触发（REQ 08）。
//

import Foundation

public struct StagePatch: Sendable, Hashable {
    public var name: String?
    public var criteriaText: String?
    public var targetDate: DateOnly?
    public var status: StageStatus?
    public var sortIndex: Int?

    public init(name: String? = nil, criteriaText: String? = nil, targetDate: DateOnly? = nil,
                status: StageStatus? = nil, sortIndex: Int? = nil) {
        self.name = name; self.criteriaText = criteriaText; self.targetDate = targetDate
        self.status = status; self.sortIndex = sortIndex
    }

    public func apply(to stage: Stage) -> Stage {
        var s = stage
        if let name { s.name = name }
        if let criteriaText { s.criteriaText = criteriaText }
        if let targetDate { s.targetDate = targetDate }
        if let status { s.status = status }
        if let sortIndex { s.sortIndex = sortIndex }
        return s
    }
}

public struct CreateStage: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .createStage
    public let entityID: UUID
    public let entityType: EntityType = .stage
    public var planID: UUID
    public var name: String
    public var criteriaText: String?
    public var targetDate: DateOnly?
    public var sortIndex: Int

    public init(operationID: UUID = UUID(), id: UUID = UUID(), planID: UUID, name: String,
                criteriaText: String? = nil, targetDate: DateOnly? = nil, sortIndex: Int = 0) {
        self.operationID = operationID; self.entityID = id; self.planID = planID; self.name = name
        self.criteriaText = criteriaText; self.targetDate = targetDate; self.sortIndex = sortIndex
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let plan = await context.repository.plan(planID) else {
            throw MovoError.notFound(entityType: .plan, id: planID)
        }
        if plan.status == .archived {
            throw MovoError.invalidStructure(reason: "「\(plan.name)」已归档，不能再添加阶段。")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MovoError.invalidStructure(reason: "阶段需要一个名称。")
        }
        var stage = Stage(id: entityID, planId: planID, name: trimmed, criteriaText: criteriaText,
                          targetDate: targetDate, sortIndex: sortIndex)
        stage.createdAt = context.now
        let saved = try await context.write(stage, old: nil)
        context.setUserMessage("已添加阶段「\(saved.name)」")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct UpdateStage: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .updateStage
    public var stageID: UUID
    public var entityID: UUID { stageID }
    public let entityType: EntityType = .stage
    public var baseRevision: Int
    public var patch: StagePatch
    public var reason: String?

    public init(operationID: UUID = UUID(), stageID: UUID, patch: StagePatch,
                baseRevision: Int = 0, reason: String? = nil) {
        self.operationID = operationID; self.stageID = stageID; self.patch = patch
        self.baseRevision = baseRevision; self.reason = reason
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.stage(stageID) else {
            throw MovoError.notFound(entityType: .stage, id: stageID)
        }
        try await StructurePolicy.requireWritable(id: stageID, type: .stage, repository: context.repository)
        try context.assertDeclaredRevision(actual: old.revision, entityID: stageID)

        var updated = patch.apply(to: old)
        // 达成只能由用户确认触发（awaitingConfirm → achieved）
        if let requested = patch.status, requested == .achieved, old.status != .achieved {
            guard old.status == .awaitingConfirm || old.status == .inProgress || old.status == .notStarted else {
                throw MovoError.invalidStructure(reason: "这个阶段当前是\(old.status.displayName)，不能直接标记达成。")
            }
            updated.achievedAt = context.now
            context.setReason(reason)
        }
        // 阶段结构修改保留版本
        if patch.name != nil || patch.criteriaText != nil || patch.targetDate != nil {
            updated.version = old.version + 1
        }
        let saved = try await context.write(updated, old: old)
        context.setUserMessage(saved.status == .achieved ? "已确认阶段「\(saved.name)」达成" : "已更新阶段「\(saved.name)」")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct MetricPatch: Sendable, Hashable {
    public var name: String?
    public var unit: String?
    public var targetValue: Double?
    public var targetDirection: MetricDirection?
    /// 显式清除可选值
    public var clearTargetValue: Bool

    public init(name: String? = nil, unit: String? = nil, targetValue: Double? = nil,
                targetDirection: MetricDirection? = nil, clearTargetValue: Bool = false) {
        self.name = name; self.unit = unit; self.targetValue = targetValue
        self.targetDirection = targetDirection; self.clearTargetValue = clearTargetValue
    }

    public func apply(to metric: PlanMetric) -> PlanMetric {
        var m = metric
        if let name { m.name = name }
        if let unit { m.unit = unit }
        if clearTargetValue { m.targetValue = nil } else if let targetValue { m.targetValue = targetValue }
        if let targetDirection { m.targetDirection = targetDirection }
        return m
    }
}

public struct CreateMetric: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .createMetric
    public let entityID: UUID
    public let entityType: EntityType = .metric
    public var planID: UUID
    public var name: String
    public var unit: String
    public var targetValue: Double?
    public var targetDirection: MetricDirection

    public init(operationID: UUID = UUID(), id: UUID = UUID(), planID: UUID, name: String, unit: String,
                targetValue: Double? = nil, targetDirection: MetricDirection = .none) {
        self.operationID = operationID; self.entityID = id; self.planID = planID; self.name = name
        self.unit = unit; self.targetValue = targetValue; self.targetDirection = targetDirection
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let plan = await context.repository.plan(planID) else {
            throw MovoError.notFound(entityType: .plan, id: planID)
        }
        try StructurePolicy.validateMetricUnit(unit)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MovoError.invalidStructure(reason: "结果指标需要一个名称，例如体重。")
        }
        var metric = PlanMetric(id: entityID, planId: planID, name: trimmed, unit: unit,
                                targetValue: targetValue, targetDirection: targetDirection)
        metric.createdAt = context.now
        let saved = try await context.write(metric, old: nil)
        context.setUserMessage("已为「\(plan.name)」添加结果指标「\(saved.name)」")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct UpdateMetric: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .updateMetric
    public var metricID: UUID
    public var entityID: UUID { metricID }
    public let entityType: EntityType = .metric
    public var baseRevision: Int
    public var patch: MetricPatch

    public init(operationID: UUID = UUID(), metricID: UUID, patch: MetricPatch, baseRevision: Int = 0) {
        self.operationID = operationID; self.metricID = metricID; self.patch = patch
        self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.metric(metricID) else {
            throw MovoError.notFound(entityType: .metric, id: metricID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: metricID)
        if let unit = patch.unit { try StructurePolicy.validateMetricUnit(unit) }
        let updated = patch.apply(to: old)
        let saved = try await context.write(updated, old: old)
        // 单位是冗余字段，改单位时同步既有测量（保持导出一致）
        if patch.unit != nil, patch.unit != old.unit, let unit = patch.unit {
            let measurements = await context.repository.measurements(metricID: metricID)
            for original in measurements where original.unit != unit {
                var m = original
                m.unit = unit
                _ = try await context.write(m, old: original)
            }
        }
        context.setUserMessage("已更新「\(saved.name)」")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}
