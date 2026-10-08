//
//  InMemoryRepository.swift
//  Data/Local
//
//  测试实现：与 SwiftDataRepository 共享同一套仓储契约测试。
//  事务语义：beginTransaction 记录快照，rollback 恢复快照。
//

import Foundation

public actor InMemoryRepository: DomainRepository {

    private var plans: [UUID: Plan] = [:]
    private var stages: [UUID: Stage] = [:]
    private var metrics: [UUID: PlanMetric] = [:]
    private var tasks: [UUID: Task] = [:]
    private var rules: [UUID: RecurrenceRule] = [:]
    private var occurrences: [UUID: RecurrenceOccurrence] = [:]
    private var activities: [UUID: ActionRecord] = [:]
    private var measurements: [UUID: Measurement] = [:]
    private var notes: [UUID: Note] = [:]
    private var captures: [UUID: Capture] = [:]
    private var batches: [UUID: OperationBatch] = [:]
    /// 批的写入顺序（同一 `createdAt` 时用它决定先后，保证 recentBatches 与撤销窗口稳定）
    private var batchOrder: [UUID] = []
    /// 操作的写入顺序（同批内同 `createdAt` 时用它决定先后，保证撤销按逆序补偿）
    private var operationOrder: [UUID] = []
    private var operations: [UUID: Operation] = [:]
    private var events: [ChangeEvent] = []
    private var suggestions: [UUID: Suggestion] = [:]
    private var reviewNotes: [UUID: ReviewNote] = [:]
    private var conflicts: [UUID: SyncConflict] = [:]
    private var tombstones: [UUID: Tombstone] = [:]
    private var searchDocs: [UUID: SearchDocument] = [:]

    private var snapshot: Snapshot?
    /// 性能基线用：模拟写入延迟（默认 0）
    public var artificialWriteDelayNanoseconds: UInt64 = 0

    public init() {}

    private struct Snapshot: Sendable {
        var plans: [UUID: Plan]; var stages: [UUID: Stage]; var metrics: [UUID: PlanMetric]
        var tasks: [UUID: Task]; var rules: [UUID: RecurrenceRule]
        var occurrences: [UUID: RecurrenceOccurrence]; var activities: [UUID: ActionRecord]
        var measurements: [UUID: Measurement]; var notes: [UUID: Note]
        var captures: [UUID: Capture]; var batches: [UUID: OperationBatch]
        var operations: [UUID: Operation]; var events: [ChangeEvent]
        var suggestions: [UUID: Suggestion]; var reviewNotes: [UUID: ReviewNote]
        var conflicts: [UUID: SyncConflict]; var tombstones: [UUID: Tombstone]
        var searchDocs: [UUID: SearchDocument]
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(plans: plans, stages: stages, metrics: metrics, tasks: tasks, rules: rules,
                 occurrences: occurrences, activities: activities, measurements: measurements,
                 notes: notes, captures: captures, batches: batches, operations: operations,
                 events: events, suggestions: suggestions, reviewNotes: reviewNotes,
                 conflicts: conflicts, tombstones: tombstones, searchDocs: searchDocs)
    }

    private func restore(_ s: Snapshot) {
        plans = s.plans; stages = s.stages; metrics = s.metrics; tasks = s.tasks; rules = s.rules
        occurrences = s.occurrences; activities = s.activities; measurements = s.measurements
        notes = s.notes; captures = s.captures; batches = s.batches; operations = s.operations
        events = s.events; suggestions = s.suggestions; reviewNotes = s.reviewNotes
        conflicts = s.conflicts; tombstones = s.tombstones; searchDocs = s.searchDocs
    }

    // MARK: - 事务

    public func beginTransaction() async throws { snapshot = makeSnapshot() }
    public func commitTransaction() async throws { snapshot = nil }
    public func rollbackTransaction() async throws {
        if let snapshot { restore(snapshot) }
        snapshot = nil
    }

    // MARK: - Plan
    public func plan(_ id: UUID) async -> Plan? { plans[id] }
    public func allPlans() async -> [Plan] { plans.values.sorted { $0.sortIndex < $1.sortIndex } }
    public func upsert(_ plan: Plan) async throws { plans[plan.id] = plan }
    public func deletePlan(_ id: UUID) async throws { plans[id] = nil }

    // MARK: - Stage
    public func stage(_ id: UUID) async -> Stage? { stages[id] }
    public func stages(planID: UUID) async -> [Stage] {
        stages.values.filter { $0.planId == planID }.sorted { $0.sortIndex < $1.sortIndex }
    }
    public func upsert(_ stage: Stage) async throws { stages[stage.id] = stage }
    public func deleteStage(_ id: UUID) async throws { stages[id] = nil }

    // MARK: - Metric
    public func metric(_ id: UUID) async -> PlanMetric? { metrics[id] }
    public func metrics(planID: UUID) async -> [PlanMetric] {
        metrics.values.filter { $0.planId == planID }.sorted { $0.createdAt < $1.createdAt }
    }
    public func upsert(_ metric: PlanMetric) async throws { metrics[metric.id] = metric }
    public func deleteMetric(_ id: UUID) async throws { metrics[id] = nil }

    // MARK: - Task
    public func task(_ id: UUID) async -> Task? { tasks[id] }
    public func tasks(ids: [UUID]) async -> [Task] { ids.compactMap { tasks[$0] } }
    public func tasks(planID: UUID) async -> [Task] {
        tasks.values.filter { $0.planId == planID }.sorted { $0.createdAt < $1.createdAt }
    }
    public func allTasks() async -> [Task] { Array(tasks.values) }
    public func children(of parentID: UUID) async -> [Task] {
        tasks.values.filter { $0.parentId == parentID }.sorted { $0.createdAt < $1.createdAt }
    }
    public func tasks(scheduledOn day: DateOnly) async -> [Task] {
        tasks.values.filter { $0.startAt?.dateOnly.isSameDay(as: day) == true }
    }
    public func templateTasks() async -> [Task] { tasks.values.filter { $0.isTemplate && !$0.isStep } }
    public func upsert(_ task: Task) async throws {
        if artificialWriteDelayNanoseconds > 0 {
            try? await _Concurrency.Task<Never, Never>.sleep(nanoseconds: artificialWriteDelayNanoseconds)
        }
        tasks[task.id] = task
    }
    public func deleteTask(_ id: UUID) async throws { tasks[id] = nil }

    // MARK: - Rule
    public func rule(_ id: UUID) async -> RecurrenceRule? { rules[id] }
    public func rule(forTask taskID: UUID) async -> RecurrenceRule? {
        rules.values.filter { $0.taskId == taskID }.max { $0.version < $1.version }
    }
    public func rules() async -> [RecurrenceRule] { Array(rules.values) }
    public func upsert(_ rule: RecurrenceRule) async throws { rules[rule.id] = rule }
    public func deleteRule(_ id: UUID) async throws { rules[id] = nil }

    // MARK: - Occurrence
    public func occurrence(_ id: UUID) async -> RecurrenceOccurrence? { occurrences[id] }
    public func occurrences(ruleID: UUID) async -> [RecurrenceOccurrence] {
        occurrences.values.filter { $0.ruleId == ruleID }
    }
    public func occurrences(taskID: UUID) async -> [RecurrenceOccurrence] {
        occurrences.values.filter { $0.taskId == taskID }
    }
    public func occurrences(planID: UUID?) async -> [RecurrenceOccurrence] {
        guard let planID else { return Array(occurrences.values) }
        return occurrences.values.filter { $0.planId == planID }
    }
    public func occurrences(scheduledIn range: DateOnlyRange, planID: UUID?) async -> [RecurrenceOccurrence] {
        occurrences.values.filter { o in
            guard let d = o.scheduledOn ?? o.occurredOn, range.contains(d) else { return false }
            guard let planID else { return true }
            return o.planId == planID
        }
    }
    public func upsert(_ occurrence: RecurrenceOccurrence) async throws {
        occurrences[occurrence.id] = occurrence
    }
    public func deleteOccurrence(_ id: UUID) async throws { occurrences[id] = nil }

    // MARK: - Activity
    public func activity(_ id: UUID) async -> ActionRecord? { activities[id] }
    public func allActivities() async -> [ActionRecord] { Array(activities.values) }
    public func activities(planID: UUID?) async -> [ActionRecord] {
        guard let planID else { return Array(activities.values) }
        return activities.values.filter { $0.planId == planID }
    }
    public func activities(taskID: UUID) async -> [ActionRecord] {
        activities.values.filter { $0.taskId == taskID }
    }
    public func activities(planID: UUID, on day: DateOnly) async -> [ActionRecord] {
        activities.values.filter { activity in
            guard activity.planId == planID else { return false }
            switch activity.happenedAt {
            case .precise(let d): return DateOnly(from: d, in: TimeZone(secondsFromGMT: 0) ?? .gmt) == day
            case .day(let d), .month(let d): return d == day
            }
        }
    }
    public func upsert(_ activity: ActionRecord) async throws { activities[activity.id] = activity }
    public func deleteActivity(_ id: UUID) async throws { activities[id] = nil }

    // MARK: - Measurement
    public func measurement(_ id: UUID) async -> Measurement? { measurements[id] }
    public func measurements(metricID: UUID) async -> [Measurement] {
        measurements.values.filter { $0.metricId == metricID }.sorted { $0.measuredAt < $1.measuredAt }
    }
    public func measurements(planID: UUID) async -> [Measurement] {
        measurements.values.filter { $0.planId == planID }.sorted { $0.measuredAt < $1.measuredAt }
    }
    public func allMeasurements() async -> [Measurement] { Array(measurements.values) }
    public func upsert(_ measurement: Measurement) async throws { measurements[measurement.id] = measurement }
    public func deleteMeasurement(_ id: UUID) async throws { measurements[id] = nil }

    // MARK: - Note
    public func note(_ id: UUID) async -> Note? { notes[id] }
    public func allNotes() async -> [Note] { Array(notes.values) }
    public func notes(planID: UUID?) async -> [Note] {
        guard let planID else { return Array(notes.values) }
        return notes.values.filter { $0.planId == planID }
    }
    public func upsert(_ note: Note) async throws { notes[note.id] = note }
    public func deleteNote(_ id: UUID) async throws { notes[id] = nil }

    // MARK: - Capture
    public func capture(_ id: UUID) async -> Capture? { captures[id] }
    public func allCaptures() async -> [Capture] { captures.values.sorted { $0.capturedAt > $1.capturedAt } }
    public func captures(pendingOnly: Bool) async -> [Capture] {
        let all = captures.values.sorted { $0.capturedAt > $1.capturedAt }
        guard pendingOnly else { return all }
        return all.filter { $0.state != .aiSucceeded }
    }
    public func upsert(_ capture: Capture) async throws { captures[capture.id] = capture }
    public func deleteCapture(_ id: UUID) async throws { captures[id] = nil }

    // MARK: - Batch / Operation
    public func batch(_ id: UUID) async -> OperationBatch? { batches[id] }
    public func recentBatches(limit: Int) async -> [OperationBatch] {
        let rank = Dictionary(batchOrder.enumerated().map { ($0.element, $0.offset) },
                              uniquingKeysWith: { later, _ in later })
        // 时间戳相同的批次按写入顺序判定先后，避免撤销窗口随字典遍历顺序变化。
        return batches.values
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return (rank[lhs.id] ?? 0) > (rank[rhs.id] ?? 0)
            }
            .prefix(limit)
            .map { $0 }
    }
    public func upsert(_ batch: OperationBatch) async throws {
        if batches[batch.id] == nil { batchOrder.append(batch.id) }
        batches[batch.id] = batch
    }
    public func operation(_ id: UUID) async -> Operation? { operations[id] }
    public func operations(batchID: UUID) async -> [Operation] {
        let rank = Dictionary(operationOrder.enumerated().map { ($0.element, $0.offset) },
                              uniquingKeysWith: { later, _ in later })
        // 时刻相同的操作按写入顺序排列：撤销依赖这个顺序做逆序补偿。
        return operations.values
            .filter { $0.batchId == batchID }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return (rank[lhs.id] ?? 0) < (rank[rhs.id] ?? 0)
            }
    }
    public func pendingOperations() async -> [Operation] { operations.values.filter { $0.status == .pending } }
    public func upsert(_ operation: Operation) async throws {
        if operations[operation.id] == nil { operationOrder.append(operation.id) }
        operations[operation.id] = operation
    }

    // MARK: - ChangeEvent
    public func append(_ event: ChangeEvent) async throws {
        // 幂等：同 eventID 去重
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
    }
    public func event(_ id: UUID) async -> ChangeEvent? { events.first { $0.id == id } }
    public func events(entityID: UUID) async -> [ChangeEvent] {
        events.filter { $0.entityId == entityID }.sorted { $0.recordedAt < $1.recordedAt }
    }
    public func events(batchID: UUID) async -> [ChangeEvent] { events.filter { $0.batchId == batchID } }
    public func events(unsyncedOnly: Bool) async -> [ChangeEvent] {
        unsyncedOnly ? events.filter { !$0.synced } : events
    }
    public func allEvents() async -> [ChangeEvent] { events }
    public func eventCount() async -> Int { events.count }
    public func markEventsSynced(ids: [UUID]) async throws {
        let set = Set(ids)
        events = events.map { e in
            guard set.contains(e.id) else { return e }
            var copy = e; copy.synced = true; return copy
        }
    }
    public func deleteEvents(ids: [UUID]) async throws {
        let set = Set(ids)
        events.removeAll { set.contains($0.id) }
    }

    // MARK: - Suggestion / ReviewNote
    public func suggestion(_ id: UUID) async -> Suggestion? { suggestions[id] }
    public func suggestions(status: SuggestionStatus?) async -> [Suggestion] {
        let all = suggestions.values.sorted { $0.createdAt > $1.createdAt }
        guard let status else { return all }
        return all.filter { $0.status == status }
    }
    public func suggestions(weekStart: DateOnly) async -> [Suggestion] {
        suggestions.values.filter { $0.weekStart == weekStart }
    }
    public func upsert(_ suggestion: Suggestion) async throws { suggestions[suggestion.id] = suggestion }
    public func reviewNote(_ id: UUID) async -> ReviewNote? { reviewNotes[id] }
    public func reviewNotes(weekStart: DateOnly) async -> [ReviewNote] {
        reviewNotes.values.filter { $0.weekStart == weekStart }.sorted { $0.createdAt < $1.createdAt }
    }
    public func upsert(_ reviewNote: ReviewNote) async throws { reviewNotes[reviewNote.id] = reviewNote }

    // MARK: - Conflict / Tombstone
    public func conflict(_ id: UUID) async -> SyncConflict? { conflicts[id] }
    public func conflicts(resolved: Bool) async -> [SyncConflict] {
        conflicts.values.filter { $0.isResolved == resolved }
    }
    public func upsert(_ conflict: SyncConflict) async throws { conflicts[conflict.id] = conflict }
    public func tombstone(_ id: UUID) async -> Tombstone? { tombstones[id] }
    public func tombstones(activeOnly: Bool) async -> [Tombstone] {
        let all = tombstones.values.sorted { $0.deletedAt > $1.deletedAt }
        return activeOnly ? all.filter(\.isActive) : all
    }
    public func upsert(_ tombstone: Tombstone) async throws { tombstones[tombstone.id] = tombstone }
    public func deleteTombstone(_ id: UUID) async throws { tombstones[id] = nil }

    // MARK: - 搜索索引
    public func upsertSearchDocument(_ doc: SearchDocument) async throws { searchDocs[doc.id] = doc }
    public func removeSearchDocuments(entityID: UUID) async throws { searchDocs[entityID] = nil }
    public func searchDocuments() async -> [SearchDocument] { Array(searchDocs.values) }
    public func removeAllSearchDocuments() async throws { searchDocs.removeAll() }

    // MARK: - 维护
    public func entityName(type: EntityType, id: UUID) async -> String? {
        switch type {
        case .plan: return plans[id]?.name
        case .stage: return stages[id]?.name
        case .metric: return metrics[id]?.name
        case .task: return tasks[id]?.title
        case .activity: return activities[id]?.text
        case .measurement: return measurements[id]?.note
        case .note: return notes[id]?.text
        case .capture: return captures[id]?.rawText
        case .suggestion: return suggestions[id]?.text
        case .reviewNote: return reviewNotes[id]?.text
        default: return nil
        }
    }

    public func purgeAll() async throws {
        plans.removeAll(); stages.removeAll(); metrics.removeAll(); tasks.removeAll()
        rules.removeAll(); occurrences.removeAll(); activities.removeAll(); measurements.removeAll()
        notes.removeAll(); captures.removeAll(); batches.removeAll(); operations.removeAll()
        events.removeAll(); suggestions.removeAll(); reviewNotes.removeAll(); conflicts.removeAll()
        tombstones.removeAll(); searchDocs.removeAll()
        batchOrder.removeAll(); operationOrder.removeAll()
    }

    /// 性能基线：批量写入 n 个任务
    public func seedTasks(_ list: [Task]) async {
        for task in list { tasks[task.id] = task }
    }

    /// 性能基线：批量写入事件
    public func seedEvents(_ list: [ChangeEvent]) async { events.append(contentsOf: list) }
}
