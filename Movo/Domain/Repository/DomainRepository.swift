//
//  DomainRepository.swift
//  Domain
//
//  1.3 / 5.1：Domain 层不 import SwiftData，经仓储协议读写；
//  所有业务对象使用客户端生成的稳定 UUID；跨边界只传 Sendable 值类型。
//

import Foundation

/// 仓储能力边界。两种实现：`InMemoryRepository`（测试）与 `SwiftDataRepository`（应用）。
/// 二者共享同一套仓储契约测试。
public protocol DomainRepository: Sendable {

    // MARK: - 事务

    /// 开启事务（记录回滚点）。失败整体回滚，不产生半更新。
    func beginTransaction() async throws
    /// 提交事务。
    func commitTransaction() async throws
    /// 回滚到最近一次 `beginTransaction` 的状态。
    func rollbackTransaction() async throws

    // MARK: - Plan
    func plan(_ id: UUID) async -> Plan?
    func allPlans() async -> [Plan]
    func upsert(_ plan: Plan) async throws
    func deletePlan(_ id: UUID) async throws

    // MARK: - Stage
    func stage(_ id: UUID) async -> Stage?
    func stages(planID: UUID) async -> [Stage]
    func upsert(_ stage: Stage) async throws
    func deleteStage(_ id: UUID) async throws

    // MARK: - PlanMetric
    func metric(_ id: UUID) async -> PlanMetric?
    func metrics(planID: UUID) async -> [PlanMetric]
    func upsert(_ metric: PlanMetric) async throws
    func deleteMetric(_ id: UUID) async throws

    // MARK: - Task
    func task(_ id: UUID) async -> Task?
    func tasks(ids: [UUID]) async -> [Task]
    func tasks(planID: UUID) async -> [Task]
    func allTasks() async -> [Task]
    func children(of parentID: UUID) async -> [Task]
    func tasks(scheduledOn day: DateOnly) async -> [Task]
    func templateTasks() async -> [Task]
    func upsert(_ task: Task) async throws
    func deleteTask(_ id: UUID) async throws

    // MARK: - RecurrenceRule
    func rule(_ id: UUID) async -> RecurrenceRule?
    func rule(forTask taskID: UUID) async -> RecurrenceRule?
    func rules() async -> [RecurrenceRule]
    func upsert(_ rule: RecurrenceRule) async throws
    func deleteRule(_ id: UUID) async throws

    // MARK: - RecurrenceOccurrence
    func occurrence(_ id: UUID) async -> RecurrenceOccurrence?
    func occurrences(ruleID: UUID) async -> [RecurrenceOccurrence]
    func occurrences(taskID: UUID) async -> [RecurrenceOccurrence]
    func occurrences(planID: UUID?) async -> [RecurrenceOccurrence]
    func occurrences(scheduledIn range: DateOnlyRange, planID: UUID?) async -> [RecurrenceOccurrence]
    func upsert(_ occurrence: RecurrenceOccurrence) async throws
    func deleteOccurrence(_ id: UUID) async throws

    // MARK: - ActionRecord
    func activity(_ id: UUID) async -> ActionRecord?
    func allActivities() async -> [ActionRecord]
    func activities(planID: UUID?) async -> [ActionRecord]
    func activities(taskID: UUID) async -> [ActionRecord]
    func activities(planID: UUID, on day: DateOnly) async -> [ActionRecord]
    func upsert(_ activity: ActionRecord) async throws
    func deleteActivity(_ id: UUID) async throws

    // MARK: - Measurement
    func measurement(_ id: UUID) async -> Measurement?
    func measurements(metricID: UUID) async -> [Measurement]
    func measurements(planID: UUID) async -> [Measurement]
    func allMeasurements() async -> [Measurement]
    func upsert(_ measurement: Measurement) async throws
    func deleteMeasurement(_ id: UUID) async throws

    // MARK: - Note
    func note(_ id: UUID) async -> Note?
    func allNotes() async -> [Note]
    func notes(planID: UUID?) async -> [Note]
    func upsert(_ note: Note) async throws
    func deleteNote(_ id: UUID) async throws

    // MARK: - Capture
    func capture(_ id: UUID) async -> Capture?
    func allCaptures() async -> [Capture]
    func captures(pendingOnly: Bool) async -> [Capture]
    func upsert(_ capture: Capture) async throws
    func deleteCapture(_ id: UUID) async throws

    // MARK: - Batch / Operation
    func batch(_ id: UUID) async -> OperationBatch?
    func recentBatches(limit: Int) async -> [OperationBatch]
    func upsert(_ batch: OperationBatch) async throws
    func operation(_ id: UUID) async -> Operation?
    func operations(batchID: UUID) async -> [Operation]
    func pendingOperations() async -> [Operation]
    func upsert(_ operation: Operation) async throws

    // MARK: - ChangeEvent（追加-only）
    func append(_ event: ChangeEvent) async throws
    func event(_ id: UUID) async -> ChangeEvent?
    func events(entityID: UUID) async -> [ChangeEvent]
    func events(batchID: UUID) async -> [ChangeEvent]
    func events(unsyncedOnly: Bool) async -> [ChangeEvent]
    func allEvents() async -> [ChangeEvent]
    func eventCount() async -> Int
    func markEventsSynced(ids: [UUID]) async throws
    func deleteEvents(ids: [UUID]) async throws

    // MARK: - Suggestion / ReviewNote
    func suggestion(_ id: UUID) async -> Suggestion?
    func suggestions(status: SuggestionStatus?) async -> [Suggestion]
    func suggestions(weekStart: DateOnly) async -> [Suggestion]
    func upsert(_ suggestion: Suggestion) async throws
    func reviewNote(_ id: UUID) async -> ReviewNote?
    func reviewNotes(weekStart: DateOnly) async -> [ReviewNote]
    func upsert(_ reviewNote: ReviewNote) async throws

    // MARK: - Conflict / Tombstone
    func conflict(_ id: UUID) async -> SyncConflict?
    func conflicts(resolved: Bool) async -> [SyncConflict]
    func upsert(_ conflict: SyncConflict) async throws
    func tombstone(_ id: UUID) async -> Tombstone?
    func tombstones(activeOnly: Bool) async -> [Tombstone]
    func upsert(_ tombstone: Tombstone) async throws
    func deleteTombstone(_ id: UUID) async throws

    // MARK: - 搜索索引（5.3）
    func upsertSearchDocument(_ doc: SearchDocument) async throws
    func removeSearchDocuments(entityID: UUID) async throws
    func searchDocuments() async -> [SearchDocument]
    func removeAllSearchDocuments() async throws

    // MARK: - 全量与维护
    func entityName(type: EntityType, id: UUID) async -> String?
    func purgeAll() async throws
}

// MARK: - 搜索文档

public struct SearchDocument: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID                       // = entityId
    public var entityType: EntityType
    public var entityId: UUID
    public var planID: UUID?
    public var title: String
    public var body: String
    /// 中文 bigram + 完整词；拉丁/数字按空白与标点切词；统一小写
    public var tokens: [String]
    /// 用于"近期/全部"排序
    public var updatedAt: Date

    public init(id: UUID, entityType: EntityType, entityId: UUID, planID: UUID? = nil,
                title: String, body: String = "", tokens: [String], updatedAt: Date = Date()) {
        self.id = id; self.entityType = entityType; self.entityId = entityId; self.planID = planID
        self.title = title; self.body = body; self.tokens = tokens; self.updatedAt = updatedAt
    }
}

// MARK: - 便捷组合读取

public extension DomainRepository {
    /// 校验用的近邻集合（避免全表扫描）
    func constraintNeighbors(planID: UUID?) async -> [Task] {
        guard let planID else { return [] }
        return await tasks(planID: planID)
    }

    /// 未完成前置数量（4.4 dependencyStatus 的输入）
    /// 忽略已取消与已删除前置
    func dependencyBlockers(for task: Task) async -> [Task] {
        guard !task.dependencyIDs.isEmpty else { return [] }
        let deps = await tasks(ids: task.dependencyIDs)
        var blockers: [Task] = []
        for dep in deps {
            if dep.status.satisfiesDependency { continue }
            if await isTombstoned(dep.id) { continue }
            blockers.append(dep)
        }
        return blockers
    }

    func isTombstoned(_ id: UUID) async -> Bool {
        let active = await tombstones(activeOnly: true)
        return active.contains { $0.entityId == id }
    }
}
