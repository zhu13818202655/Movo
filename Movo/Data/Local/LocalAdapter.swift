//
//  LocalAdapter.swift
//  Data/Local
//
//  5.1 LocalAdapter 提供 toDomain/fromDomain 与 mapInTransaction；
//  枚举存 rawValue；数组字段存 JSON（此处统一走 payload）。
//

import Foundation

public enum LocalAdapter {

    // MARK: - 编解码

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? makeEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard !data.isEmpty else { return nil }
        return try? makeDecoder().decode(type, from: data)
    }

    static func dayRaw(_ day: DateOnly?) -> String? { day?.iso8601DateString }

    static func day(_ raw: String?, tz: String) -> DateOnly? {
        guard let raw else { return nil }
        return DateOnly(iso8601DateString: raw, sourceTZ: tz)
    }

    // MARK: - Plan

    public static func toM(_ plan: Plan) -> PlanM {
        PlanM(id: plan.id, sortIndex: plan.sortIndex, statusRaw: plan.status.rawValue,
              categoryRaw: plan.category?.rawValue, cloudAIEnabled: plan.cloudAIEnabled,
              syncEnabled: plan.syncEnabled, updatedAt: plan.updatedAt, payload: encode(plan))
    }

    public static func toDomain(_ m: PlanM) -> Plan? {
        decode(Plan.self, from: m.payload) ?? Plan(
            id: m.id, name: "", kind: .delivery, category: m.categoryRaw.flatMap(PlanCategory.init(rawValue:)),
            cloudAIEnabled: m.cloudAIEnabled, syncEnabled: m.syncEnabled,
            status: PlanStatus(rawValue: m.statusRaw) ?? .active,
            sortIndex: m.sortIndex, updatedAt: m.updatedAt)
    }

    // MARK: - Stage

    public static func toM(_ stage: Stage) -> StageM {
        StageM(id: stage.id, planID: stage.planId, sortIndex: stage.sortIndex,
               statusRaw: stage.status.rawValue, payload: encode(stage))
    }

    public static func toDomain(_ m: StageM) -> Stage? {
        decode(Stage.self, from: m.payload) ?? Stage(
            id: m.id, planId: m.planID, name: "",
            status: StageStatus(rawValue: m.statusRaw) ?? .notStarted, sortIndex: m.sortIndex)
    }

    // MARK: - Metric

    public static func toM(_ metric: PlanMetric) -> MetricM {
        MetricM(id: metric.id, planID: metric.planId, name: metric.name, unit: metric.unit,
                createdAt: metric.createdAt, payload: encode(metric))
    }

    public static func toDomain(_ m: MetricM) -> PlanMetric? {
        decode(PlanMetric.self, from: m.payload) ?? PlanMetric(
            id: m.id, planId: m.planID, name: m.name, unit: m.unit, createdAt: m.createdAt)
    }

    // MARK: - Task

    public static func toM(_ task: Task) -> TaskM {
        TaskM(id: task.id, planID: task.planId, stageID: task.stageId, parentID: task.parentId,
              statusRaw: task.status.rawValue, isTemplate: task.isTemplate,
              scheduledOnRaw: task.scheduledDate?.iso8601DateString,
              scheduledTZ: task.scheduledDate?.sourceTZ,
              deadlineEpoch: task.hardDeadline?.epoch, deadlineTZ: task.hardDeadline?.tzID,
              updatedAt: task.updatedAt, payload: encode(task))
    }

    public static func toDomain(_ m: TaskM) -> Task? {
        decode(Task.self, from: m.payload) ?? Task(
            id: m.id, planId: m.planID, stageId: m.stageID, parentId: m.parentID, title: "",
            isTemplate: m.isTemplate, status: TaskStatus(rawValue: m.statusRaw) ?? .todo,
            updatedAt: m.updatedAt)
    }

    // MARK: - Rule

    public static func toM(_ rule: RecurrenceRule) -> RuleM {
        RuleM(id: rule.id, taskID: rule.taskId, version: rule.version,
              patternRaw: rule.pattern.rawValue, statusRaw: rule.status.rawValue,
              effectiveFromRaw: rule.effectiveFrom.iso8601DateString,
              effectiveUntilRaw: rule.effectiveUntil?.iso8601DateString,
              createdAt: rule.createdAt, payload: encode(rule))
    }

    public static func toDomain(_ m: RuleM) -> RecurrenceRule? {
        decode(RecurrenceRule.self, from: m.payload) ?? RecurrenceRule(
            id: m.id, taskId: m.taskID, pattern: RecurrencePattern(rawValue: m.patternRaw) ?? .daily,
            effectiveFrom: DateOnly(iso8601DateString: m.effectiveFromRaw, sourceTZ: "UTC")
                ?? DateOnly(y: 1970, m: 1, d: 1, sourceTZ: "UTC"),
            version: m.version, status: RuleStatus(rawValue: m.statusRaw) ?? .active,
            createdAt: m.createdAt)
    }

    // MARK: - Occurrence

    public static func toM(_ o: RecurrenceOccurrence) -> OccurrenceM {
        OccurrenceM(id: o.id, uniqueKey: o.uniqueKey, ruleID: o.ruleId, ruleVersion: o.ruleVersion,
                    taskID: o.taskId, planID: o.planId,
                    scheduledOnRaw: o.scheduledOn?.iso8601DateString,
                    occurredOnRaw: o.occurredOn?.iso8601DateString,
                    statusRaw: o.status.rawValue, payload: encode(o))
    }

    public static func toDomain(_ m: OccurrenceM) -> RecurrenceOccurrence? {
        decode(RecurrenceOccurrence.self, from: m.payload) ?? RecurrenceOccurrence(
            id: m.id, ruleId: m.ruleID, ruleVersion: m.ruleVersion, taskId: m.taskID,
            planId: m.planID, status: OccurrenceStatus(rawValue: m.statusRaw) ?? .pending)
    }

    // MARK: - Activity

    public static func toM(_ a: ActionRecord) -> ActivityM {
        ActivityM(id: a.id, planID: a.planId, taskID: a.taskId, occurrenceID: a.occurrenceId,
                  happenedEpoch: a.happenedAt.sortEpoch, recordedAt: a.recordedAt,
                  payload: encode(a))
    }

    public static func toDomain(_ m: ActivityM) -> ActionRecord? {
        decode(ActionRecord.self, from: m.payload)
    }

    // MARK: - Measurement

    public static func toM(_ measurement: Measurement) -> MeasurementM {
        MeasurementM(id: measurement.id, planID: measurement.planId, metricID: measurement.metricId,
                     measuredOnRaw: measurement.measuredAt.iso8601DateString, value: measurement.value,
                     recordedAt: measurement.recordedAt, payload: encode(measurement))
    }

    public static func toDomain(_ m: MeasurementM) -> Measurement? {
        decode(Measurement.self, from: m.payload)
    }

    // MARK: - Note

    public static func toM(_ note: Note) -> NoteM {
        NoteM(id: note.id, planID: note.planId, capturedAt: note.capturedAt, payload: encode(note))
    }

    public static func toDomain(_ m: NoteM) -> Note? { decode(Note.self, from: m.payload) }

    // MARK: - Capture

    public static func toM(_ capture: Capture) -> CaptureM {
        CaptureM(id: capture.id, stateRaw: capture.state.rawValue,
                 inputModeRaw: capture.inputMode.rawValue, capturedAt: capture.capturedAt,
                 payload: encode(capture))
    }

    public static func toDomain(_ m: CaptureM) -> Capture? { decode(Capture.self, from: m.payload) }

    // MARK: - Batch / Operation

    public static func toM(_ batch: OperationBatch) -> BatchM {
        BatchM(id: batch.id, captureID: batch.captureId, createdAt: batch.createdAt,
               stateRaw: batch.state.rawValue, payload: encode(batch))
    }

    public static func toDomain(_ m: BatchM) -> OperationBatch? { decode(OperationBatch.self, from: m.payload) }

    public static func toM(_ op: Operation) -> OperationM {
        OperationM(id: op.id, batchID: op.batchId, kindRaw: op.kind.rawValue,
                   entityTypeRaw: op.entityType.rawValue, entityID: op.entityId,
                   statusRaw: op.status.rawValue, createdAt: op.createdAt, payload: encode(op))
    }

    public static func toDomain(_ m: OperationM) -> Operation? { decode(Operation.self, from: m.payload) }

    // MARK: - ChangeEvent

    public static func toM(_ event: ChangeEvent) -> EventM {
        EventM(id: event.id, operationID: event.operationId, batchID: event.batchId,
               entityID: event.entityId, entityTypeRaw: event.entityType.rawValue,
               recordedAt: event.recordedAt, occurredAt: event.occurredAt,
               newRevision: event.newRevision, synced: event.synced, payload: encode(event))
    }

    /// `EventM.synced` 是查询谓词（`!$0.synced`）所依据的权威列，
    /// 而 payload 中内嵌的 `synced` 可能滞后（如 `markEventsSynced` 仅翻转列）。
    /// 读取时以列为准，保证查询与领域对象一致。
    public static func toDomain(_ m: EventM) -> ChangeEvent? {
        guard var event = decode(ChangeEvent.self, from: m.payload) else { return nil }
        event.synced = m.synced
        return event
    }

    // MARK: - Suggestion / ReviewNote

    public static func toM(_ suggestion: Suggestion) -> SuggestionM {
        SuggestionM(id: suggestion.id, planID: suggestion.planId,
                    statusRaw: suggestion.status.rawValue, createdAt: suggestion.createdAt,
                    payload: encode(suggestion))
    }

    public static func toDomain(_ m: SuggestionM) -> Suggestion? { decode(Suggestion.self, from: m.payload) }

    public static func toM(_ note: ReviewNote) -> ReviewNoteM {
        ReviewNoteM(id: note.id, planID: note.planId, createdAt: note.createdAt, payload: encode(note))
    }

    public static func toDomain(_ m: ReviewNoteM) -> ReviewNote? { decode(ReviewNote.self, from: m.payload) }

    // MARK: - Conflict / Tombstone

    public static func toM(_ conflict: SyncConflict) -> ConflictM {
        ConflictM(id: conflict.id, entityTypeRaw: conflict.entityType.rawValue,
                  entityID: conflict.entityId, resolved: conflict.isResolved,
                  detectedAt: conflict.detectedAt, payload: encode(conflict))
    }

    public static func toDomain(_ m: ConflictM) -> SyncConflict? { decode(SyncConflict.self, from: m.payload) }

    public static func toM(_ tombstone: Tombstone) -> TombstoneM {
        TombstoneM(id: tombstone.id, entityTypeRaw: tombstone.entityType.rawValue,
                   entityID: tombstone.entityId, deletedAt: tombstone.deletedAt,
                   purgeAfter: tombstone.purgeAfter, restoredAt: tombstone.restoredAt,
                   payload: encode(tombstone))
    }

    public static func toDomain(_ m: TombstoneM) -> Tombstone? { decode(Tombstone.self, from: m.payload) }

    // MARK: - SearchDoc

    public static func toM(_ doc: SearchDocument) -> SearchDocM {
        SearchDocM(id: doc.id, entityTypeRaw: doc.entityType.rawValue, entityID: doc.entityId,
                   planID: doc.planID, title: doc.title, body: doc.body,
                   tokenBlob: doc.tokens.joined(separator: " "), updatedAt: doc.updatedAt,
                   payload: encode(doc))
    }

    public static func toDomain(_ m: SearchDocM) -> SearchDocument? {
        decode(SearchDocument.self, from: m.payload) ?? SearchDocument(
            id: m.id, entityType: EntityType(rawValue: m.entityTypeRaw) ?? .task,
            entityId: m.entityID, planID: m.planID, title: m.title, body: m.body,
            tokens: m.tokenBlob.split(separator: " ").map(String.init), updatedAt: m.updatedAt)
    }
}
