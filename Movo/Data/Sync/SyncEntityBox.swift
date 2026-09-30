//
//  SyncEntityBox.swift
//  Data/Sync
//
//  同步实体的编解码盒子：把 9.2 的 stateJSON 与领域实体互转，
//  并支持"用合并后的字段重建实体"（9.4 第 2 步之后回写本机）。
//
//  只包含参与同步的实体（9.2 表）：Plan/Stage/Metric/Task/Rule/Occurrence/
//  Activity/Measurement/Note/Capture/Suggestion/ReviewNote/Conflict/Tombstone。
//  Batch/Operation/Event 不参与实体同步（事件单独走 MovoEvent 记录）。
//

import Foundation

public enum SyncEntityBox: Sendable {
    case plan(Plan)
    case stage(Stage)
    case metric(PlanMetric)
    case task(Task)
    case rule(RecurrenceRule)
    case occurrence(RecurrenceOccurrence)
    case activity(ActionRecord)
    case measurement(Measurement)
    case note(Note)
    case capture(Capture)
    case suggestion(Suggestion)
    case reviewNote(ReviewNote)
    case conflict(SyncConflict)
    case tombstone(Tombstone)

    // MARK: - 元信息

    public var entityType: EntityType {
        switch self {
        case .plan: .plan
        case .stage: .stage
        case .metric: .metric
        case .task: .task
        case .rule: .rule
        case .occurrence: .occurrence
        case .activity: .activity
        case .measurement: .measurement
        case .note: .note
        case .capture: .capture
        case .suggestion: .suggestion
        case .reviewNote: .reviewNote
        case .conflict: .conflict
        case .tombstone: .tombstone
        }
    }

    public var id: UUID {
        switch self {
        case .plan(let v): v.id
        case .stage(let v): v.id
        case .metric(let v): v.id
        case .task(let v): v.id
        case .rule(let v): v.id
        case .occurrence(let v): v.id
        case .activity(let v): v.id
        case .measurement(let v): v.id
        case .note(let v): v.id
        case .capture(let v): v.id
        case .suggestion(let v): v.id
        case .reviewNote(let v): v.id
        case .conflict(let v): v.id
        case .tombstone(let v): v.id
        }
    }

    public var revision: Int {
        switch self {
        case .plan(let v): v.revision
        case .stage(let v): v.revision
        case .metric(let v): v.revision
        case .task(let v): v.revision
        case .rule(let v): v.revision
        case .occurrence(let v): v.revision
        case .activity(let v): v.revision
        case .measurement(let v): v.revision
        case .note(let v): v.revision
        case .capture(let v): v.revision
        case .suggestion(let v): v.revision
        case .reviewNote(let v): v.revision
        case .conflict(let v): v.revision
        case .tombstone(let v): v.revision
        }
    }

    /// 实体自身的时间戳（没有 updatedAt 的用最近活动时间）
    public var updatedAt: Date {
        switch self {
        case .plan(let v): v.updatedAt
        case .task(let v): v.updatedAt
        case .stage(let v): v.createdAt
        case .metric(let v): v.createdAt
        case .rule(let v): v.createdAt
        case .occurrence(let v): v.doneAt ?? Date(timeIntervalSince1970: 0)
        case .activity(let v): v.recordedAt
        case .measurement(let v): v.recordedAt
        case .note(let v): v.capturedAt
        case .capture(let v): v.capturedAt
        case .suggestion(let v): v.createdAt
        case .reviewNote(let v): v.createdAt
        case .conflict(let v): v.detectedAt
        case .tombstone(let v): v.deletedAt
        }
    }

    /// 根计划（9.6 按计划过滤 syncEnabled）
    public var planID: UUID? {
        switch self {
        case .plan(let v): v.id
        case .stage(let v): v.planId
        case .metric(let v): v.planId
        case .task(let v): v.planId
        case .activity(let v): v.planId
        case .measurement(let v): v.planId
        case .note(let v): v.planId
        case .suggestion(let v): v.planId
        case .reviewNote(let v): v.planId
        case .occurrence(let v): v.planId
        // Rule 通过 Task 归属，由引擎补 planID
        case .rule, .capture, .conflict, .tombstone: nil
        }
    }

    public var searchTitle: String {
        switch self {
        case .plan(let v): v.searchTitle
        case .stage(let v): v.searchTitle
        case .metric(let v): v.searchTitle
        case .task(let v): v.searchTitle
        case .rule(let v): v.searchTitle
        case .occurrence(let v): v.searchTitle
        case .activity(let v): v.searchTitle
        case .measurement(let v): v.searchTitle
        case .note(let v): v.searchTitle
        case .capture(let v): v.searchTitle
        case .suggestion(let v): v.searchTitle
        case .reviewNote(let v): v.searchTitle
        case .conflict(let v): v.searchTitle
        case .tombstone(let v): v.searchTitle
        }
    }

    public var searchBody: String {
        switch self {
        case .plan(let v): v.searchBody
        case .stage(let v): v.searchBody
        case .metric(let v): v.searchBody
        case .task(let v): v.searchBody
        case .rule(let v): v.searchBody
        case .occurrence(let v): v.searchBody
        case .activity(let v): v.searchBody
        case .measurement(let v): v.searchBody
        case .note(let v): v.searchBody
        case .capture(let v): v.searchBody
        case .suggestion(let v): v.searchBody
        case .reviewNote(let v): v.searchBody
        case .conflict(let v): v.searchBody
        case .tombstone(let v): v.searchBody
        }
    }

    // MARK: - 编解码

    public func encode() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch self {
        case .plan(let v): return try? encoder.encode(v)
        case .stage(let v): return try? encoder.encode(v)
        case .metric(let v): return try? encoder.encode(v)
        case .task(let v): return try? encoder.encode(v)
        case .rule(let v): return try? encoder.encode(v)
        case .occurrence(let v): return try? encoder.encode(v)
        case .activity(let v): return try? encoder.encode(v)
        case .measurement(let v): return try? encoder.encode(v)
        case .note(let v): return try? encoder.encode(v)
        case .capture(let v): return try? encoder.encode(v)
        case .suggestion(let v): return try? encoder.encode(v)
        case .reviewNote(let v): return try? encoder.encode(v)
        case .conflict(let v): return try? encoder.encode(v)
        case .tombstone(let v): return try? encoder.encode(v)
        }
    }

    public static func decode(type: EntityType, data: Data) -> SyncEntityBox? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch type {
        case .plan: return (try? decoder.decode(Plan.self, from: data)).map(SyncEntityBox.plan)
        case .stage: return (try? decoder.decode(Stage.self, from: data)).map(SyncEntityBox.stage)
        case .metric: return (try? decoder.decode(PlanMetric.self, from: data)).map(SyncEntityBox.metric)
        case .task: return (try? decoder.decode(Task.self, from: data)).map(SyncEntityBox.task)
        case .rule: return (try? decoder.decode(RecurrenceRule.self, from: data)).map(SyncEntityBox.rule)
        case .occurrence:
            return (try? decoder.decode(RecurrenceOccurrence.self, from: data)).map(SyncEntityBox.occurrence)
        case .activity: return (try? decoder.decode(ActionRecord.self, from: data)).map(SyncEntityBox.activity)
        case .measurement:
            return (try? decoder.decode(Measurement.self, from: data)).map(SyncEntityBox.measurement)
        case .note: return (try? decoder.decode(Note.self, from: data)).map(SyncEntityBox.note)
        case .capture: return (try? decoder.decode(Capture.self, from: data)).map(SyncEntityBox.capture)
        case .suggestion: return (try? decoder.decode(Suggestion.self, from: data)).map(SyncEntityBox.suggestion)
        case .reviewNote: return (try? decoder.decode(ReviewNote.self, from: data)).map(SyncEntityBox.reviewNote)
        case .conflict: return (try? decoder.decode(SyncConflict.self, from: data)).map(SyncEntityBox.conflict)
        case .tombstone: return (try? decoder.decode(Tombstone.self, from: data)).map(SyncEntityBox.tombstone)
        // 不参与实体同步
        case .batch, .operation, .event: return nil
        }
    }

    // MARK: - 重建（9.4 结果回写）

    /// 用合并后的字段 + 新的 revision / updatedAt 重建实体。
    /// mergedFields 是实体全量字段，因此直接解码即可拿到合并结果。
    public func applying(mergedFields: [String: JSONValue], revision: Int,
                         updatedAt: Date) -> SyncEntityBox? {
        guard let data = FieldMerge.encode(fields: mergedFields),
              var rebuilt = SyncEntityBox.decode(type: entityType, data: data) else { return nil }
        rebuilt.setRevision(revision)
        rebuilt.setUpdatedAt(updatedAt)
        return rebuilt
    }

    public mutating func setRevision(_ revision: Int) {
        switch self {
        case .plan(var v): v.revision = revision; self = .plan(v)
        case .stage(var v): v.revision = revision; self = .stage(v)
        case .metric(var v): v.revision = revision; self = .metric(v)
        case .task(var v): v.revision = revision; self = .task(v)
        case .rule(var v): v.revision = revision; self = .rule(v)
        case .occurrence(var v): v.revision = revision; self = .occurrence(v)
        case .activity(var v): v.revision = revision; self = .activity(v)
        case .measurement(var v): v.revision = revision; self = .measurement(v)
        case .note(var v): v.revision = revision; self = .note(v)
        case .capture(var v): v.revision = revision; self = .capture(v)
        case .suggestion(var v): v.revision = revision; self = .suggestion(v)
        case .reviewNote(var v): v.revision = revision; self = .reviewNote(v)
        case .conflict(var v): v.revision = revision; self = .conflict(v)
        case .tombstone(var v): v.revision = revision; self = .tombstone(v)
        }
    }

    public mutating func setUpdatedAt(_ date: Date) {
        switch self {
        case .plan(var v): v.updatedAt = date; self = .plan(v)
        case .task(var v): v.updatedAt = date; self = .task(v)
        // 其余实体没有独立的 updatedAt 字段
        case .stage, .metric, .rule, .occurrence, .activity, .measurement,
             .note, .capture, .suggestion, .reviewNote, .conflict, .tombstone:
            break
        }
    }

    // MARK: - 落库

    public func upsert(into repository: any DomainRepository) async throws {
        switch self {
        case .plan(let v): try await repository.upsert(v)
        case .stage(let v): try await repository.upsert(v)
        case .metric(let v): try await repository.upsert(v)
        case .task(let v): try await repository.upsert(v)
        case .rule(let v): try await repository.upsert(v)
        case .occurrence(let v): try await repository.upsert(v)
        case .activity(let v): try await repository.upsert(v)
        case .measurement(let v): try await repository.upsert(v)
        case .note(let v): try await repository.upsert(v)
        case .capture(let v): try await repository.upsert(v)
        case .suggestion(let v): try await repository.upsert(v)
        case .reviewNote(let v): try await repository.upsert(v)
        case .conflict(let v): try await repository.upsert(v)
        case .tombstone(let v): try await repository.upsert(v)
        }
    }

    /// 搜索索引文档（5.3 / 9.3 入站后更新索引）
    public func searchDocument() -> SearchDocument {
        SearchDocument(
            id: id, entityType: entityType, entityId: id, planID: planID,
            title: searchTitle, body: searchBody,
            tokens: SearchTokenizer.tokens(for: searchTitle + " " + searchBody),
            updatedAt: updatedAt)
    }

    /// 从记录还原盒子
    public static func decode(_ record: EntityRecord) -> SyncEntityBox? {
        decode(type: record.entityType, data: record.stateJSON)
    }

    /// 从本地仓库取实体盒子（冲突 UI / 引擎共用）
    public static func fetch(type: EntityType, id: UUID,
                             in repository: any DomainRepository) async -> SyncEntityBox? {
        switch type {
        case .plan: return await repository.plan(id).map(SyncEntityBox.plan)
        case .stage: return await repository.stage(id).map(SyncEntityBox.stage)
        case .metric: return await repository.metric(id).map(SyncEntityBox.metric)
        case .task: return await repository.task(id).map(SyncEntityBox.task)
        case .rule: return await repository.rule(id).map(SyncEntityBox.rule)
        case .occurrence: return await repository.occurrence(id).map(SyncEntityBox.occurrence)
        case .activity: return await repository.activity(id).map(SyncEntityBox.activity)
        case .measurement: return await repository.measurement(id).map(SyncEntityBox.measurement)
        case .note: return await repository.note(id).map(SyncEntityBox.note)
        case .capture: return await repository.capture(id).map(SyncEntityBox.capture)
        case .suggestion: return await repository.suggestion(id).map(SyncEntityBox.suggestion)
        case .reviewNote: return await repository.reviewNote(id).map(SyncEntityBox.reviewNote)
        case .conflict: return await repository.conflict(id).map(SyncEntityBox.conflict)
        case .tombstone: return await repository.tombstone(id).map(SyncEntityBox.tombstone)
        // 不参与实体同步
        case .batch, .operation, .event: return nil
        }
    }

    /// 实体 → 记录（9.2 映射）
    public func record(rev: Int, deviceId: String, deletedAt: Date? = nil,
                       fieldRev: [String: Int] = [:], planID overridePlanID: UUID? = nil,
                       systemFields: Data? = nil) -> EntityRecord? {
        guard let payload = encode() else { return nil }
        return EntityRecord(entityType: entityType, entityID: id, rev: rev, deviceId: deviceId,
                            updatedAt: updatedAt, deletedAt: deletedAt, stateJSON: payload,
                            fieldRev: fieldRev, planID: overridePlanID ?? planID,
                            systemFields: systemFields)
    }
}
