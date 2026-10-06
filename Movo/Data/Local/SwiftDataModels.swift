//
//  SwiftDataModels.swift
//  Data/Local
//
//  5.1 领域实体 → @Model 映射。
//  设计：每个 @Model 保留"可查询的标量列"（id / 归属 id / 状态 / 日期），
//  其余字段以 Codable JSON 存于 `payload`，由 LocalAdapter 透明编解码。
//  这样增量查询走索引列，round-trip 由 payload 保证字段完备。
//
//  5.4 Schema 规则：只允许新增列/新增表；删列先弃用一个版本。
//

import Foundation
import SwiftData

// MARK: - Plan

@Model
public final class PlanM {
    @Attribute(.unique) public var id: UUID
    public var sortIndex: Int
    public var statusRaw: String
    public var categoryRaw: String?
    public var cloudAIEnabled: Bool
    public var syncEnabled: Bool
    public var updatedAt: Date
    public var payload: Data

    public init(id: UUID, sortIndex: Int, statusRaw: String, categoryRaw: String?,
                cloudAIEnabled: Bool, syncEnabled: Bool, updatedAt: Date, payload: Data) {
        self.id = id; self.sortIndex = sortIndex; self.statusRaw = statusRaw
        self.categoryRaw = categoryRaw; self.cloudAIEnabled = cloudAIEnabled
        self.syncEnabled = syncEnabled; self.updatedAt = updatedAt; self.payload = payload
    }
}

// MARK: - Stage

@Model
public final class StageM {
    @Attribute(.unique) public var id: UUID
    public var planID: UUID
    public var sortIndex: Int
    public var statusRaw: String
    public var payload: Data

    public init(id: UUID, planID: UUID, sortIndex: Int, statusRaw: String, payload: Data) {
        self.id = id; self.planID = planID; self.sortIndex = sortIndex
        self.statusRaw = statusRaw; self.payload = payload
    }
}

// MARK: - PlanMetric

@Model
public final class MetricM {
    @Attribute(.unique) public var id: UUID
    public var planID: UUID
    public var name: String
    public var unit: String
    public var createdAt: Date
    public var payload: Data

    public init(id: UUID, planID: UUID, name: String, unit: String, createdAt: Date, payload: Data) {
        self.id = id; self.planID = planID; self.name = name; self.unit = unit
        self.createdAt = createdAt; self.payload = payload
    }
}

// MARK: - Task

@Model
public final class TaskM {
    @Attribute(.unique) public var id: UUID
    public var planID: UUID?
    public var stageID: UUID?
    public var parentID: UUID?
    public var statusRaw: String
    public var isTemplate: Bool
    /// 索引列：开始时间所在日期 `yyyy-MM-dd` + 开始时间的时区（列名沿用旧版，避免迁移）
    public var scheduledOnRaw: String?
    public var scheduledTZ: String?
    /// 索引列：结束时间为「某一时刻」时的 epoch + tzID
    public var deadlineEpoch: Date?
    public var deadlineTZ: String?
    public var updatedAt: Date
    public var payload: Data

    public init(id: UUID, planID: UUID?, stageID: UUID?, parentID: UUID?, statusRaw: String,
                isTemplate: Bool, scheduledOnRaw: String?, scheduledTZ: String?,
                deadlineEpoch: Date?, deadlineTZ: String?, updatedAt: Date, payload: Data) {
        self.id = id; self.planID = planID; self.stageID = stageID; self.parentID = parentID
        self.statusRaw = statusRaw; self.isTemplate = isTemplate
        self.scheduledOnRaw = scheduledOnRaw; self.scheduledTZ = scheduledTZ
        self.deadlineEpoch = deadlineEpoch; self.deadlineTZ = deadlineTZ
        self.updatedAt = updatedAt; self.payload = payload
    }
}

// MARK: - RecurrenceRule

@Model
public final class RuleM {
    @Attribute(.unique) public var id: UUID
    public var taskID: UUID
    public var version: Int
    public var patternRaw: String
    public var statusRaw: String
    public var effectiveFromRaw: String
    public var effectiveUntilRaw: String?
    public var createdAt: Date
    public var payload: Data

    public init(id: UUID, taskID: UUID, version: Int, patternRaw: String, statusRaw: String,
                effectiveFromRaw: String, effectiveUntilRaw: String?, createdAt: Date, payload: Data) {
        self.id = id; self.taskID = taskID; self.version = version; self.patternRaw = patternRaw
        self.statusRaw = statusRaw; self.effectiveFromRaw = effectiveFromRaw
        self.effectiveUntilRaw = effectiveUntilRaw; self.createdAt = createdAt; self.payload = payload
    }
}

// MARK: - RecurrenceOccurrence

@Model
public final class OccurrenceM {
    @Attribute(.unique) public var id: UUID
    /// 唯一键 (ruleId, ruleVersion, scheduledOn)
    @Attribute(.unique) public var uniqueKey: String
    public var ruleID: UUID
    public var ruleVersion: Int
    public var taskID: UUID
    public var planID: UUID?
    public var scheduledOnRaw: String?
    public var occurredOnRaw: String?
    public var statusRaw: String
    public var payload: Data

    public init(id: UUID, uniqueKey: String, ruleID: UUID, ruleVersion: Int, taskID: UUID,
                planID: UUID?, scheduledOnRaw: String?, occurredOnRaw: String?,
                statusRaw: String, payload: Data) {
        self.id = id; self.uniqueKey = uniqueKey; self.ruleID = ruleID; self.ruleVersion = ruleVersion
        self.taskID = taskID; self.planID = planID; self.scheduledOnRaw = scheduledOnRaw
        self.occurredOnRaw = occurredOnRaw; self.statusRaw = statusRaw; self.payload = payload
    }
}

// MARK: - ActionRecord

@Model
public final class ActivityM {
    @Attribute(.unique) public var id: UUID
    public var planID: UUID
    public var taskID: UUID?
    public var occurrenceID: UUID?
    public var happenedEpoch: Date
    public var recordedAt: Date
    public var payload: Data

    public init(id: UUID, planID: UUID, taskID: UUID?, occurrenceID: UUID?,
                happenedEpoch: Date, recordedAt: Date, payload: Data) {
        self.id = id; self.planID = planID; self.taskID = taskID; self.occurrenceID = occurrenceID
        self.happenedEpoch = happenedEpoch; self.recordedAt = recordedAt; self.payload = payload
    }
}

// MARK: - Measurement

@Model
public final class MeasurementM {
    @Attribute(.unique) public var id: UUID
    public var planID: UUID
    public var metricID: UUID
    public var measuredOnRaw: String
    public var value: Double
    public var recordedAt: Date
    public var payload: Data

    public init(id: UUID, planID: UUID, metricID: UUID, measuredOnRaw: String, value: Double,
                recordedAt: Date, payload: Data) {
        self.id = id; self.planID = planID; self.metricID = metricID
        self.measuredOnRaw = measuredOnRaw; self.value = value
        self.recordedAt = recordedAt; self.payload = payload
    }
}

// MARK: - Note

@Model
public final class NoteM {
    @Attribute(.unique) public var id: UUID
    public var planID: UUID?
    public var capturedAt: Date
    public var payload: Data

    public init(id: UUID, planID: UUID?, capturedAt: Date, payload: Data) {
        self.id = id; self.planID = planID; self.capturedAt = capturedAt; self.payload = payload
    }
}

// MARK: - Capture

@Model
public final class CaptureM {
    @Attribute(.unique) public var id: UUID
    public var stateRaw: String
    public var inputModeRaw: String
    public var capturedAt: Date
    public var payload: Data

    public init(id: UUID, stateRaw: String, inputModeRaw: String, capturedAt: Date, payload: Data) {
        self.id = id; self.stateRaw = stateRaw; self.inputModeRaw = inputModeRaw
        self.capturedAt = capturedAt; self.payload = payload
    }
}

// MARK: - Batch / Operation

@Model
public final class BatchM {
    @Attribute(.unique) public var id: UUID
    public var captureID: UUID?
    public var createdAt: Date
    public var stateRaw: String
    public var payload: Data

    public init(id: UUID, captureID: UUID?, createdAt: Date, stateRaw: String, payload: Data) {
        self.id = id; self.captureID = captureID; self.createdAt = createdAt
        self.stateRaw = stateRaw; self.payload = payload
    }
}

@Model
public final class OperationM {
    @Attribute(.unique) public var id: UUID
    public var batchID: UUID
    public var kindRaw: String
    public var entityTypeRaw: String
    public var entityID: UUID
    public var statusRaw: String
    public var createdAt: Date
    public var payload: Data

    public init(id: UUID, batchID: UUID, kindRaw: String, entityTypeRaw: String, entityID: UUID,
                statusRaw: String, createdAt: Date, payload: Data) {
        self.id = id; self.batchID = batchID; self.kindRaw = kindRaw
        self.entityTypeRaw = entityTypeRaw; self.entityID = entityID
        self.statusRaw = statusRaw; self.createdAt = createdAt; self.payload = payload
    }
}

// MARK: - ChangeEvent（追加-only）

@Model
public final class EventM {
    @Attribute(.unique) public var id: UUID
    public var operationID: UUID
    public var batchID: UUID
    public var entityID: UUID
    public var entityTypeRaw: String
    public var recordedAt: Date
    public var occurredAt: Date
    public var newRevision: Int
    /// P3 用：是否已推送
    public var synced: Bool
    public var payload: Data

    public init(id: UUID, operationID: UUID, batchID: UUID, entityID: UUID, entityTypeRaw: String,
                recordedAt: Date, occurredAt: Date, newRevision: Int, synced: Bool, payload: Data) {
        self.id = id; self.operationID = operationID; self.batchID = batchID; self.entityID = entityID
        self.entityTypeRaw = entityTypeRaw; self.recordedAt = recordedAt; self.occurredAt = occurredAt
        self.newRevision = newRevision; self.synced = synced; self.payload = payload
    }
}

// MARK: - Suggestion / ReviewNote

@Model
public final class SuggestionM {
    @Attribute(.unique) public var id: UUID
    public var planID: UUID?
    public var statusRaw: String
    public var createdAt: Date
    public var payload: Data

    public init(id: UUID, planID: UUID?, statusRaw: String, createdAt: Date, payload: Data) {
        self.id = id; self.planID = planID; self.statusRaw = statusRaw
        self.createdAt = createdAt; self.payload = payload
    }
}

@Model
public final class ReviewNoteM {
    @Attribute(.unique) public var id: UUID
    public var planID: UUID?
    public var createdAt: Date
    public var payload: Data

    public init(id: UUID, planID: UUID?, createdAt: Date, payload: Data) {
        self.id = id; self.planID = planID; self.createdAt = createdAt; self.payload = payload
    }
}

// MARK: - SyncConflict / Tombstone

@Model
public final class ConflictM {
    @Attribute(.unique) public var id: UUID
    public var entityTypeRaw: String
    public var entityID: UUID
    public var resolved: Bool
    public var detectedAt: Date
    public var payload: Data

    public init(id: UUID, entityTypeRaw: String, entityID: UUID, resolved: Bool,
                detectedAt: Date, payload: Data) {
        self.id = id; self.entityTypeRaw = entityTypeRaw; self.entityID = entityID
        self.resolved = resolved; self.detectedAt = detectedAt; self.payload = payload
    }
}

@Model
public final class TombstoneM {
    @Attribute(.unique) public var id: UUID
    public var entityTypeRaw: String
    public var entityID: UUID
    public var deletedAt: Date
    public var purgeAfter: Date
    public var restoredAt: Date?
    public var payload: Data

    public init(id: UUID, entityTypeRaw: String, entityID: UUID, deletedAt: Date,
                purgeAfter: Date, restoredAt: Date?, payload: Data) {
        self.id = id; self.entityTypeRaw = entityTypeRaw; self.entityID = entityID
        self.deletedAt = deletedAt; self.purgeAfter = purgeAfter
        self.restoredAt = restoredAt; self.payload = payload
    }
}

// MARK: - 搜索索引（5.3）

@Model
public final class SearchDocM {
    @Attribute(.unique) public var id: UUID
    public var entityTypeRaw: String
    public var entityID: UUID
    public var planID: UUID?
    public var title: String
    public var body: String
    /// 空格分隔的 token 串：用 `#Predicate` 的 contains 做多词 AND 预筛
    public var tokenBlob: String
    public var updatedAt: Date
    public var payload: Data

    public init(id: UUID, entityTypeRaw: String, entityID: UUID, planID: UUID?, title: String,
                body: String, tokenBlob: String, updatedAt: Date, payload: Data) {
        self.id = id; self.entityTypeRaw = entityTypeRaw; self.entityID = entityID
        self.planID = planID; self.title = title; self.body = body
        self.tokenBlob = tokenBlob; self.updatedAt = updatedAt; self.payload = payload
    }
}

// MARK: - Schema 版本（5.4）

public enum MovoSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [PlanM.self, StageM.self, MetricM.self, TaskM.self, RuleM.self, OccurrenceM.self,
         ActivityM.self, MeasurementM.self, NoteM.self, CaptureM.self, BatchM.self, OperationM.self,
         EventM.self, SuggestionM.self, ReviewNoteM.self, ConflictM.self, TombstoneM.self,
         SearchDocM.self]
    }
}

/// 迁移计划：首版只有一个版本，后续版本以 `[MovoSchemaV1.self, MovoSchemaV2.self]` 追加。
public enum MovoMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [MovoSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
