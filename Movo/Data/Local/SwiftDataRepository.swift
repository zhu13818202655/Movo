//
//  SwiftDataRepository.swift
//  Data/Local
//
//  5.2 事务与写入路径：事务体在主 ModelContext（@MainActor）内完成；
//  事务内按序：写实体 → 追加 EventM → 更新 SearchDocM →（P3）置 dirty 标记。
//  事务失败整体回滚，UI 收到 MovoError 且数据无半更新。
//

import Foundation
import SwiftData

@MainActor
public final class SwiftDataRepository: DomainRepository {

    public let container: ModelContainer
    public let context: ModelContext
    private var transactionDepth = 0

    public init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
    }

    /// 内存容器（预览 / 单元测试）
    public static func inMemory() throws -> SwiftDataRepository {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema(MovoSchemaV1.models), configurations: config)
        return SwiftDataRepository(container: container)
    }

    /// 磁盘容器（临时路径 round-trip / 迁移 fixture 测试用）
    public static func onDisk(url: URL) throws -> SwiftDataRepository {
        let config = ModelConfiguration(url: url)
        let container = try ModelContainer(for: Schema(MovoSchemaV1.models), configurations: config)
        return SwiftDataRepository(container: container)
    }

    /// 应用默认容器
    public static func applicationDefault() throws -> SwiftDataRepository {
        let container = try ModelContainer(for: Schema(MovoSchemaV1.models),
                                           migrationPlan: MovoMigrationPlan.self,
                                           configurations: ModelConfiguration())
        return SwiftDataRepository(container: container)
    }

    // MARK: - 事务

    public func beginTransaction() async throws {
        transactionDepth += 1
    }

    public func commitTransaction() async throws {
        transactionDepth = max(0, transactionDepth - 1)
        guard transactionDepth == 0 else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw MovoError.invalidStructure(reason: "保存失败，本次更改没有写入。\(error.localizedDescription)")
        }
    }

    public func rollbackTransaction() async throws {
        transactionDepth = 0
        context.rollback()
    }

    // MARK: - 通用查询助手

    private func firstM<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>) -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetch<T: PersistentModel>(_ type: T.Type, _ predicate: Predicate<T>?,
                                           sortBy: [SortDescriptor<T>] = []) -> [T] {
        var descriptor = FetchDescriptor<T>(predicate: predicate, sortBy: sortBy)
        descriptor.fetchLimit = 0
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Plan

    public func plan(_ id: UUID) async -> Plan? {
        guard let m: PlanM = firstM(PlanM.self, where: #Predicate<PlanM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func allPlans() async -> [Plan] {
        fetch(PlanM.self, nil, sortBy: [SortDescriptor(\.sortIndex)])
            .compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ plan: Plan) async throws {
        if let existing: PlanM = firstM(PlanM.self, where: #Predicate<PlanM> { $0.id == plan.id }) {
            let fresh = LocalAdapter.toM(plan)
            existing.sortIndex = fresh.sortIndex; existing.statusRaw = fresh.statusRaw
            existing.categoryRaw = fresh.categoryRaw; existing.cloudAIEnabled = fresh.cloudAIEnabled
            existing.syncEnabled = fresh.syncEnabled; existing.updatedAt = fresh.updatedAt
            existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(plan))
        }
    }

    public func deletePlan(_ id: UUID) async throws {
        if let m: PlanM = firstM(PlanM.self, where: #Predicate<PlanM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - Stage

    public func stage(_ id: UUID) async -> Stage? {
        guard let m: StageM = firstM(StageM.self, where: #Predicate<StageM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func stages(planID: UUID) async -> [Stage] {
        fetch(StageM.self, #Predicate<StageM> { $0.planID == planID }, sortBy: [SortDescriptor(\.sortIndex)])
            .compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ stage: Stage) async throws {
        if let existing: StageM = firstM(StageM.self, where: #Predicate<StageM> { $0.id == stage.id }) {
            let fresh = LocalAdapter.toM(stage)
            existing.planID = fresh.planID; existing.sortIndex = fresh.sortIndex
            existing.statusRaw = fresh.statusRaw; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(stage))
        }
    }

    public func deleteStage(_ id: UUID) async throws {
        if let m: StageM = firstM(StageM.self, where: #Predicate<StageM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - Metric

    public func metric(_ id: UUID) async -> PlanMetric? {
        guard let m: MetricM = firstM(MetricM.self, where: #Predicate<MetricM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func metrics(planID: UUID) async -> [PlanMetric] {
        fetch(MetricM.self, #Predicate<MetricM> { $0.planID == planID }, sortBy: [SortDescriptor(\.createdAt)])
            .compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ metric: PlanMetric) async throws {
        if let existing: MetricM = firstM(MetricM.self, where: #Predicate<MetricM> { $0.id == metric.id }) {
            let fresh = LocalAdapter.toM(metric)
            existing.planID = fresh.planID; existing.name = fresh.name
            existing.unit = fresh.unit; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(metric))
        }
    }

    public func deleteMetric(_ id: UUID) async throws {
        if let m: MetricM = firstM(MetricM.self, where: #Predicate<MetricM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - Task

    public func task(_ id: UUID) async -> Task? {
        guard let m: TaskM = firstM(TaskM.self, where: #Predicate<TaskM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func tasks(ids: [UUID]) async -> [Task] {
        guard !ids.isEmpty else { return [] }
        let set = Set(ids)
        return fetch(TaskM.self, #Predicate<TaskM> { set.contains($0.id) }).compactMap(LocalAdapter.toDomain)
    }

    public func tasks(planID: UUID) async -> [Task] {
        fetch(TaskM.self, #Predicate<TaskM> { $0.planID == planID }, sortBy: [SortDescriptor(\.updatedAt)])
            .compactMap(LocalAdapter.toDomain)
    }

    public func allTasks() async -> [Task] {
        fetch(TaskM.self, nil).compactMap(LocalAdapter.toDomain)
    }

    public func children(of parentID: UUID) async -> [Task] {
        fetch(TaskM.self, #Predicate<TaskM> { $0.parentID == parentID }).compactMap(LocalAdapter.toDomain)
    }

    public func tasks(scheduledOn day: DateOnly) async -> [Task] {
        let raw = day.iso8601DateString
        return fetch(TaskM.self, #Predicate<TaskM> { $0.scheduledOnRaw == raw }).compactMap(LocalAdapter.toDomain)
    }

    public func templateTasks() async -> [Task] {
        fetch(TaskM.self, #Predicate<TaskM> { $0.isTemplate }).compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ task: Task) async throws {
        if let existing: TaskM = firstM(TaskM.self, where: #Predicate<TaskM> { $0.id == task.id }) {
            let fresh = LocalAdapter.toM(task)
            existing.planID = fresh.planID; existing.stageID = fresh.stageID
            existing.parentID = fresh.parentID; existing.statusRaw = fresh.statusRaw
            existing.isTemplate = fresh.isTemplate
            existing.scheduledOnRaw = fresh.scheduledOnRaw; existing.scheduledTZ = fresh.scheduledTZ
            existing.deadlineEpoch = fresh.deadlineEpoch; existing.deadlineTZ = fresh.deadlineTZ
            existing.updatedAt = fresh.updatedAt; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(task))
        }
    }

    public func deleteTask(_ id: UUID) async throws {
        if let m: TaskM = firstM(TaskM.self, where: #Predicate<TaskM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - Rule

    public func rule(_ id: UUID) async -> RecurrenceRule? {
        guard let m: RuleM = firstM(RuleM.self, where: #Predicate<RuleM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func rule(forTask taskID: UUID) async -> RecurrenceRule? {
        fetch(RuleM.self, #Predicate<RuleM> { $0.taskID == taskID }, sortBy: [SortDescriptor(\.version, order: .reverse)])
            .first.flatMap(LocalAdapter.toDomain)
    }

    public func rules() async -> [RecurrenceRule] {
        fetch(RuleM.self, nil).compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ rule: RecurrenceRule) async throws {
        if let existing: RuleM = firstM(RuleM.self, where: #Predicate<RuleM> { $0.id == rule.id }) {
            let fresh = LocalAdapter.toM(rule)
            existing.taskID = fresh.taskID; existing.version = fresh.version
            existing.patternRaw = fresh.patternRaw; existing.statusRaw = fresh.statusRaw
            existing.effectiveFromRaw = fresh.effectiveFromRaw
            existing.effectiveUntilRaw = fresh.effectiveUntilRaw; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(rule))
        }
    }

    public func deleteRule(_ id: UUID) async throws {
        if let m: RuleM = firstM(RuleM.self, where: #Predicate<RuleM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - Occurrence

    public func occurrence(_ id: UUID) async -> RecurrenceOccurrence? {
        guard let m: OccurrenceM = firstM(OccurrenceM.self, where: #Predicate<OccurrenceM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func occurrences(ruleID: UUID) async -> [RecurrenceOccurrence] {
        fetch(OccurrenceM.self, #Predicate<OccurrenceM> { $0.ruleID == ruleID },
              sortBy: [SortDescriptor(\.scheduledOnRaw)]).compactMap(LocalAdapter.toDomain)
    }

    public func occurrences(taskID: UUID) async -> [RecurrenceOccurrence] {
        fetch(OccurrenceM.self, #Predicate<OccurrenceM> { $0.taskID == taskID }).compactMap(LocalAdapter.toDomain)
    }

    public func occurrences(planID: UUID?) async -> [RecurrenceOccurrence] {
        guard let planID else { return fetch(OccurrenceM.self, nil).compactMap(LocalAdapter.toDomain) }
        return fetch(OccurrenceM.self, #Predicate<OccurrenceM> { $0.planID == planID }).compactMap(LocalAdapter.toDomain)
    }

    public func occurrences(scheduledIn range: DateOnlyRange, planID: UUID?) async -> [RecurrenceOccurrence] {
        let lower = range.lower.iso8601DateString
        let upper = range.upper.iso8601DateString
        // 先按日期区间粗筛（scheduledOn 与 occurredOn 两支），再按 planID 精筛
        let byScheduled = fetch(OccurrenceM.self, #Predicate<OccurrenceM> { model in
            (model.scheduledOnRaw ?? "") >= lower && (model.scheduledOnRaw ?? "") <= upper
        })
        let byOccurred = fetch(OccurrenceM.self, #Predicate<OccurrenceM> { model in
            (model.occurredOnRaw ?? "") >= lower && (model.occurredOnRaw ?? "") <= upper
        })
        var merged: [UUID: OccurrenceM] = [:]
        for model in byScheduled { merged[model.id] = model }
        for model in byOccurred { merged[model.id] = model }
        let candidates = merged.values.compactMap(LocalAdapter.toDomain)
        guard let planID else { return candidates }
        return candidates.filter { $0.planId == planID }
    }

    public func upsert(_ occurrence: RecurrenceOccurrence) async throws {
        if let existing: OccurrenceM = firstM(OccurrenceM.self, where: #Predicate<OccurrenceM> { $0.id == occurrence.id }) {
            let fresh = LocalAdapter.toM(occurrence)
            existing.uniqueKey = fresh.uniqueKey
            existing.ruleID = fresh.ruleID; existing.ruleVersion = fresh.ruleVersion
            existing.taskID = fresh.taskID; existing.planID = fresh.planID
            existing.scheduledOnRaw = fresh.scheduledOnRaw; existing.occurredOnRaw = fresh.occurredOnRaw
            existing.statusRaw = fresh.statusRaw; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(occurrence))
        }
    }

    public func deleteOccurrence(_ id: UUID) async throws {
        if let m: OccurrenceM = firstM(OccurrenceM.self, where: #Predicate<OccurrenceM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - Activity

    public func activity(_ id: UUID) async -> ActionRecord? {
        guard let m: ActivityM = firstM(ActivityM.self, where: #Predicate<ActivityM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func allActivities() async -> [ActionRecord] {
        fetch(ActivityM.self, nil, sortBy: [SortDescriptor(\.happenedEpoch, order: .reverse)])
            .compactMap(LocalAdapter.toDomain)
    }

    public func activities(planID: UUID?) async -> [ActionRecord] {
        guard let planID else { return await allActivities() }
        return fetch(ActivityM.self, #Predicate<ActivityM> { $0.planID == planID },
                     sortBy: [SortDescriptor(\.happenedEpoch, order: .reverse)])
            .compactMap(LocalAdapter.toDomain)
    }

    public func activities(taskID: UUID) async -> [ActionRecord] {
        fetch(ActivityM.self, #Predicate<ActivityM> { $0.taskID == taskID },
              sortBy: [SortDescriptor(\.happenedEpoch, order: .reverse)]).compactMap(LocalAdapter.toDomain)
    }

    public func activities(planID: UUID, on day: DateOnly) async -> [ActionRecord] {
        let lower = day.startOfDay(in: day.timeZone)
        let upper = lower.addingTimeInterval(86_400)
        return fetch(ActivityM.self, #Predicate<ActivityM> { model in
            model.planID == planID && model.happenedEpoch >= lower && model.happenedEpoch < upper
        }).compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ activity: ActionRecord) async throws {
        if let existing: ActivityM = firstM(ActivityM.self, where: #Predicate<ActivityM> { $0.id == activity.id }) {
            let fresh = LocalAdapter.toM(activity)
            existing.planID = fresh.planID; existing.taskID = fresh.taskID
            existing.occurrenceID = fresh.occurrenceID; existing.happenedEpoch = fresh.happenedEpoch
            existing.recordedAt = fresh.recordedAt; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(activity))
        }
    }

    public func deleteActivity(_ id: UUID) async throws {
        if let m: ActivityM = firstM(ActivityM.self, where: #Predicate<ActivityM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - Measurement

    public func measurement(_ id: UUID) async -> Measurement? {
        guard let m: MeasurementM = firstM(MeasurementM.self, where: #Predicate<MeasurementM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func measurements(metricID: UUID) async -> [Measurement] {
        fetch(MeasurementM.self, #Predicate<MeasurementM> { $0.metricID == metricID },
              sortBy: [SortDescriptor(\.measuredOnRaw)]).compactMap(LocalAdapter.toDomain)
    }

    public func measurements(planID: UUID) async -> [Measurement] {
        fetch(MeasurementM.self, #Predicate<MeasurementM> { $0.planID == planID },
              sortBy: [SortDescriptor(\.measuredOnRaw)]).compactMap(LocalAdapter.toDomain)
    }

    public func allMeasurements() async -> [Measurement] {
        fetch(MeasurementM.self, nil, sortBy: [SortDescriptor(\.measuredOnRaw)])
            .compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ measurement: Measurement) async throws {
        if let existing: MeasurementM = firstM(MeasurementM.self, where: #Predicate<MeasurementM> { $0.id == measurement.id }) {
            let fresh = LocalAdapter.toM(measurement)
            existing.planID = fresh.planID; existing.metricID = fresh.metricID
            existing.measuredOnRaw = fresh.measuredOnRaw; existing.value = fresh.value
            existing.recordedAt = fresh.recordedAt; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(measurement))
        }
    }

    public func deleteMeasurement(_ id: UUID) async throws {
        if let m: MeasurementM = firstM(MeasurementM.self, where: #Predicate<MeasurementM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - Note

    public func note(_ id: UUID) async -> Note? {
        guard let m: NoteM = firstM(NoteM.self, where: #Predicate<NoteM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func allNotes() async -> [Note] {
        fetch(NoteM.self, nil, sortBy: [SortDescriptor(\.capturedAt, order: .reverse)])
            .compactMap(LocalAdapter.toDomain)
    }

    public func notes(planID: UUID?) async -> [Note] {
        guard let planID else { return await allNotes() }
        return fetch(NoteM.self, #Predicate<NoteM> { $0.planID == planID }).compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ note: Note) async throws {
        if let existing: NoteM = firstM(NoteM.self, where: #Predicate<NoteM> { $0.id == note.id }) {
            let fresh = LocalAdapter.toM(note)
            existing.planID = fresh.planID; existing.capturedAt = fresh.capturedAt
            existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(note))
        }
    }

    public func deleteNote(_ id: UUID) async throws {
        if let m: NoteM = firstM(NoteM.self, where: #Predicate<NoteM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - Capture

    public func capture(_ id: UUID) async -> Capture? {
        guard let m: CaptureM = firstM(CaptureM.self, where: #Predicate<CaptureM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func allCaptures() async -> [Capture] {
        fetch(CaptureM.self, nil, sortBy: [SortDescriptor(\.capturedAt, order: .reverse)])
            .compactMap(LocalAdapter.toDomain)
    }

    public func captures(pendingOnly: Bool) async -> [Capture] {
        let all = await allCaptures()
        guard pendingOnly else { return all }
        return all.filter { $0.state != .aiSucceeded }
    }

    public func upsert(_ capture: Capture) async throws {
        if let existing: CaptureM = firstM(CaptureM.self, where: #Predicate<CaptureM> { $0.id == capture.id }) {
            let fresh = LocalAdapter.toM(capture)
            existing.stateRaw = fresh.stateRaw; existing.inputModeRaw = fresh.inputModeRaw
            existing.capturedAt = fresh.capturedAt; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(capture))
        }
    }

    public func deleteCapture(_ id: UUID) async throws {
        if let m: CaptureM = firstM(CaptureM.self, where: #Predicate<CaptureM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - Batch / Operation

    public func batch(_ id: UUID) async -> OperationBatch? {
        guard let m: BatchM = firstM(BatchM.self, where: #Predicate<BatchM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func recentBatches(limit: Int) async -> [OperationBatch] {
        fetch(BatchM.self, nil, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            .prefix(limit).compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ batch: OperationBatch) async throws {
        if let existing: BatchM = firstM(BatchM.self, where: #Predicate<BatchM> { $0.id == batch.id }) {
            let fresh = LocalAdapter.toM(batch)
            existing.captureID = fresh.captureID; existing.stateRaw = fresh.stateRaw
            existing.createdAt = fresh.createdAt; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(batch))
        }
    }

    public func operation(_ id: UUID) async -> Operation? {
        guard let m: OperationM = firstM(OperationM.self, where: #Predicate<OperationM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func operations(batchID: UUID) async -> [Operation] {
        fetch(OperationM.self, #Predicate<OperationM> { $0.batchID == batchID },
              sortBy: [SortDescriptor(\.createdAt)]).compactMap(LocalAdapter.toDomain)
    }

    public func pendingOperations() async -> [Operation] {
        fetch(OperationM.self, #Predicate<OperationM> { $0.statusRaw == "pending" }).compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ operation: Operation) async throws {
        if let existing: OperationM = firstM(OperationM.self, where: #Predicate<OperationM> { $0.id == operation.id }) {
            let fresh = LocalAdapter.toM(operation)
            existing.batchID = fresh.batchID; existing.kindRaw = fresh.kindRaw
            existing.entityTypeRaw = fresh.entityTypeRaw; existing.entityID = fresh.entityID
            existing.statusRaw = fresh.statusRaw; existing.createdAt = fresh.createdAt
            existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(operation))
        }
    }

    // MARK: - ChangeEvent

    public func append(_ event: ChangeEvent) async throws {
        // 幂等：同 eventID 去重
        if let _: EventM = firstM(EventM.self, where: #Predicate<EventM> { $0.id == event.id }) { return }
        context.insert(LocalAdapter.toM(event))
    }

    public func event(_ id: UUID) async -> ChangeEvent? {
        guard let m: EventM = firstM(EventM.self, where: #Predicate<EventM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func events(entityID: UUID) async -> [ChangeEvent] {
        fetch(EventM.self, #Predicate<EventM> { $0.entityID == entityID },
              sortBy: [SortDescriptor(\.recordedAt)]).compactMap(LocalAdapter.toDomain)
    }

    public func events(batchID: UUID) async -> [ChangeEvent] {
        fetch(EventM.self, #Predicate<EventM> { $0.batchID == batchID }).compactMap(LocalAdapter.toDomain)
    }

    public func events(unsyncedOnly: Bool) async -> [ChangeEvent] {
        guard unsyncedOnly else { return await allEvents() }
        return fetch(EventM.self, #Predicate<EventM> { !$0.synced },
                     sortBy: [SortDescriptor(\.recordedAt)]).compactMap(LocalAdapter.toDomain)
    }

    public func allEvents() async -> [ChangeEvent] {
        fetch(EventM.self, nil, sortBy: [SortDescriptor(\.recordedAt)]).compactMap(LocalAdapter.toDomain)
    }

    public func eventCount() async -> Int {
        (try? context.fetchCount(FetchDescriptor<EventM>())) ?? 0
    }

    public func markEventsSynced(ids: [UUID]) async throws {
        let list = fetch(EventM.self, nil)
        let set = Set(ids)
        for m in list where set.contains(m.id) { m.synced = true }
    }

    public func deleteEvents(ids: [UUID]) async throws {
        let list = fetch(EventM.self, nil)
        let set = Set(ids)
        for m in list where set.contains(m.id) { context.delete(m) }
    }

    // MARK: - Suggestion / ReviewNote

    public func suggestion(_ id: UUID) async -> Suggestion? {
        guard let m: SuggestionM = firstM(SuggestionM.self, where: #Predicate<SuggestionM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func suggestions(status: SuggestionStatus?) async -> [Suggestion] {
        let all = fetch(SuggestionM.self, nil, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            .compactMap(LocalAdapter.toDomain)
        guard let status else { return all }
        return all.filter { $0.status == status }
    }

    public func suggestions(weekStart: DateOnly) async -> [Suggestion] {
        (await suggestions(status: nil)).filter { $0.weekStart == weekStart }
    }

    public func upsert(_ suggestion: Suggestion) async throws {
        if let existing: SuggestionM = firstM(SuggestionM.self, where: #Predicate<SuggestionM> { $0.id == suggestion.id }) {
            let fresh = LocalAdapter.toM(suggestion)
            existing.planID = fresh.planID; existing.statusRaw = fresh.statusRaw
            existing.createdAt = fresh.createdAt; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(suggestion))
        }
    }

    public func reviewNote(_ id: UUID) async -> ReviewNote? {
        guard let m: ReviewNoteM = firstM(ReviewNoteM.self, where: #Predicate<ReviewNoteM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func reviewNotes(weekStart: DateOnly) async -> [ReviewNote] {
        fetch(ReviewNoteM.self, nil).compactMap(LocalAdapter.toDomain)
            .filter { $0.weekStart == weekStart }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func upsert(_ reviewNote: ReviewNote) async throws {
        if let existing: ReviewNoteM = firstM(ReviewNoteM.self, where: #Predicate<ReviewNoteM> { $0.id == reviewNote.id }) {
            let fresh = LocalAdapter.toM(reviewNote)
            existing.planID = fresh.planID; existing.createdAt = fresh.createdAt
            existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(reviewNote))
        }
    }

    // MARK: - Conflict / Tombstone

    public func conflict(_ id: UUID) async -> SyncConflict? {
        guard let m: ConflictM = firstM(ConflictM.self, where: #Predicate<ConflictM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func conflicts(resolved: Bool) async -> [SyncConflict] {
        fetch(ConflictM.self, #Predicate<ConflictM> { $0.resolved == resolved },
              sortBy: [SortDescriptor(\.detectedAt, order: .reverse)]).compactMap(LocalAdapter.toDomain)
    }

    public func upsert(_ conflict: SyncConflict) async throws {
        if let existing: ConflictM = firstM(ConflictM.self, where: #Predicate<ConflictM> { $0.id == conflict.id }) {
            let fresh = LocalAdapter.toM(conflict)
            existing.entityTypeRaw = fresh.entityTypeRaw; existing.entityID = fresh.entityID
            existing.resolved = fresh.resolved; existing.detectedAt = fresh.detectedAt
            existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(conflict))
        }
    }

    public func tombstone(_ id: UUID) async -> Tombstone? {
        guard let m: TombstoneM = firstM(TombstoneM.self, where: #Predicate<TombstoneM> { $0.id == id }) else { return nil }
        return LocalAdapter.toDomain(m)
    }

    public func tombstones(activeOnly: Bool) async -> [Tombstone] {
        let all = fetch(TombstoneM.self, nil, sortBy: [SortDescriptor(\.deletedAt, order: .reverse)])
            .compactMap(LocalAdapter.toDomain)
        return activeOnly ? all.filter(\.isActive) : all
    }

    public func upsert(_ tombstone: Tombstone) async throws {
        if let existing: TombstoneM = firstM(TombstoneM.self, where: #Predicate<TombstoneM> { $0.id == tombstone.id }) {
            let fresh = LocalAdapter.toM(tombstone)
            existing.entityTypeRaw = fresh.entityTypeRaw; existing.entityID = fresh.entityID
            existing.deletedAt = fresh.deletedAt; existing.purgeAfter = fresh.purgeAfter
            existing.restoredAt = fresh.restoredAt; existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(tombstone))
        }
    }

    public func deleteTombstone(_ id: UUID) async throws {
        if let m: TombstoneM = firstM(TombstoneM.self, where: #Predicate<TombstoneM> { $0.id == id }) { context.delete(m) }
    }

    // MARK: - 搜索索引

    public func upsertSearchDocument(_ doc: SearchDocument) async throws {
        if let existing: SearchDocM = firstM(SearchDocM.self, where: #Predicate<SearchDocM> { $0.id == doc.id }) {
            let fresh = LocalAdapter.toM(doc)
            existing.entityTypeRaw = fresh.entityTypeRaw; existing.entityID = fresh.entityID
            existing.planID = fresh.planID; existing.title = fresh.title; existing.body = fresh.body
            existing.tokenBlob = fresh.tokenBlob; existing.updatedAt = fresh.updatedAt
            existing.payload = fresh.payload
        } else {
            context.insert(LocalAdapter.toM(doc))
        }
    }

    public func removeSearchDocuments(entityID: UUID) async throws {
        let list = fetch(SearchDocM.self, nil)
        for m in list where m.entityID == entityID { context.delete(m) }
    }

    public func searchDocuments() async -> [SearchDocument] {
        fetch(SearchDocM.self, nil).compactMap(LocalAdapter.toDomain)
    }

    public func removeAllSearchDocuments() async throws {
        for m in fetch(SearchDocM.self, nil) { context.delete(m) }
    }

    // MARK: - 维护

    public func entityName(type: EntityType, id: UUID) async -> String? {
        switch type {
        case .plan: return await plan(id)?.name
        case .stage: return await stage(id)?.name
        case .metric: return await metric(id)?.name
        case .task: return await task(id)?.title
        case .activity: return await activity(id)?.text
        case .measurement: return await measurement(id)?.note
        case .note: return await note(id)?.text
        case .capture: return await capture(id)?.rawText
        case .suggestion: return await suggestion(id)?.text
        case .reviewNote: return await reviewNote(id)?.text
        default: return nil
        }
    }

    /// 物理清空（DELETE ALL / 永久删除到期内容）
    public func purgeAll() async throws {
        let models: [any PersistentModel] = fetch(PlanM.self, nil) + fetch(StageM.self, nil)
            + fetch(MetricM.self, nil) + fetch(TaskM.self, nil) + fetch(RuleM.self, nil)
            + fetch(OccurrenceM.self, nil) + fetch(ActivityM.self, nil) + fetch(MeasurementM.self, nil)
            + fetch(NoteM.self, nil) + fetch(CaptureM.self, nil) + fetch(BatchM.self, nil)
            + fetch(OperationM.self, nil) + fetch(EventM.self, nil) + fetch(SuggestionM.self, nil)
            + fetch(ReviewNoteM.self, nil) + fetch(ConflictM.self, nil) + fetch(TombstoneM.self, nil)
            + fetch(SearchDocM.self, nil)
        for model in models { context.delete(model) }
        try context.save()
    }

    /// 到期永久删除（T1.9 / T3.4）：级联清理实体、事件、索引
    public func purgeExpiredTombstones(now: Date) async throws {
        let expired = fetch(TombstoneM.self, nil).filter { $0.purgeAfter <= now }
        for m in expired {
            let entityID = m.entityID
            let entityType = EntityType(rawValue: m.entityTypeRaw)
            context.delete(m)
            switch entityType {
            case .plan: if let x: PlanM = firstM(PlanM.self, where: #Predicate<PlanM> { $0.id == entityID }) { context.delete(x) }
            case .stage: if let x: StageM = firstM(StageM.self, where: #Predicate<StageM> { $0.id == entityID }) { context.delete(x) }
            case .metric: if let x: MetricM = firstM(MetricM.self, where: #Predicate<MetricM> { $0.id == entityID }) { context.delete(x) }
            case .task: if let x: TaskM = firstM(TaskM.self, where: #Predicate<TaskM> { $0.id == entityID }) { context.delete(x) }
            case .rule: if let x: RuleM = firstM(RuleM.self, where: #Predicate<RuleM> { $0.id == entityID }) { context.delete(x) }
            case .occurrence: if let x: OccurrenceM = firstM(OccurrenceM.self, where: #Predicate<OccurrenceM> { $0.id == entityID }) { context.delete(x) }
            case .activity: if let x: ActivityM = firstM(ActivityM.self, where: #Predicate<ActivityM> { $0.id == entityID }) { context.delete(x) }
            case .measurement: if let x: MeasurementM = firstM(MeasurementM.self, where: #Predicate<MeasurementM> { $0.id == entityID }) { context.delete(x) }
            case .note: if let x: NoteM = firstM(NoteM.self, where: #Predicate<NoteM> { $0.id == entityID }) { context.delete(x) }
            case .capture: if let x: CaptureM = firstM(CaptureM.self, where: #Predicate<CaptureM> { $0.id == entityID }) { context.delete(x) }
            default: break
            }
            for e in fetch(EventM.self, nil) where e.entityID == entityID { context.delete(e) }
            for d in fetch(SearchDocM.self, nil) where d.entityID == entityID { context.delete(d) }
        }
        if !expired.isEmpty { try context.save() }
    }

    /// 存储占用估算（设置页"管理"区）
    public func storeSizeBytes() -> Int64 {
        let count = (try? context.fetchCount(FetchDescriptor<EventM>())) ?? 0
        // 以事件量为主的粗估：每条事件约 1KB
        return Int64(count) * 1024
    }
}
