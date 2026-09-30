//
//  SyncRecords.swift
//  Data/Sync
//
//  9.2 CloudKit 记录 Schema（私有数据库，默认 zone）。
//  RecordType：MovoEntity / MovoEvent / MovoMeta。
//  本文件是纯值类型层，不 import CloudKit —— CKRecord ↔ 值类型的换算留在后端实现里，
//  这样合并算法与引擎可以脱离网络单测（1.3：跨边界只传 Sendable 值类型）。
//

import Foundation

// MARK: - 记录类型

public enum SyncRecordType {
    public static let entity = "MovoEntity"
    public static let event = "MovoEvent"
    public static let meta = "MovoMeta"
    /// 实体记录统一落在自有 zone，便于按 zone 拉取与清理
    public static let zoneName = "MovoZone"
    /// 9.2：stateJSON 控制 ≤64KB，超限拆分 stateJSON_1..n
    public static let maxStateBytes = 64 * 1024
    public static let schemaVersion = 1
    /// 9.2：事件量大时按 500 条/批推送
    public static let eventBatchSize = 500
}

// MARK: - 账号状态（9.6 状态机映射）

public enum CloudAccountState: String, Sendable, Hashable, Codable {
    /// 尚未查询
    case unknown
    /// iCloud 可用且已登录
    case available
    /// 用户未登录 iCloud
    case notSignedIn
    /// 被家长控制等限制
    case restricted
    /// 临时不可用（网络/服务）
    case temporarilyUnavailable
    /// 缺少 iCloud entitlement（未签名或未配置容器）
    case unavailable

    /// 就绪 = 可以开始同步（9.6：notSignedIn → requesting → signedIn）
    public var isReady: Bool { self == .available }

    public var displayName: String {
        switch self {
        case .unknown: "正在检查 iCloud"
        case .available: "已登录 iCloud"
        case .notSignedIn: "未登录 iCloud"
        case .restricted: "iCloud 被限制"
        case .temporarilyUnavailable: "iCloud 暂时不可用"
        case .unavailable: "这台设备上没有启用 iCloud"
        }
    }

    /// 9.6：登录/退出流程中的用户可见提示
    public var recoveryHint: String? {
        switch self {
        case .notSignedIn: "在系统设置里登录 iCloud 后回来打开同步。"
        case .restricted: "当前账号权限受限，同步已停用；本机记录不受影响。"
        case .temporarilyUnavailable: "网络恢复后会自动继续，不需要手动重试。"
        case .unavailable: "同步需要在签名构建里配置 iCloud 容器；本机功能完全可用。"
        case .available, .unknown: nil
        }
    }
}

// MARK: - 实体记录（RecordType: MovoEntity）

/// 每个业务实体一条。`recordName == entityID.uuidString`（9.2 主键）。
public struct EntityRecord: Sendable, Hashable, Codable {
    public var entityType: EntityType
    public var entityID: UUID
    /// 实体 revision（乐观锁与合并序）
    public var rev: Int
    /// 最后写入设备（冲突 UI 显示 "Mac / iPhone"）
    public var deviceId: String
    public var updatedAt: Date
    /// 空 = 未删；非空 = 已删除（9.5）
    public var deletedAt: Date?
    /// 实体全量 JSON
    public var stateJSON: Data
    /// {field: revAtLastChange}，用于 9.4 判断"哪一侧动过这个字段"
    public var fieldRev: [String: Int]
    /// 根计划，供按计划过滤（9.6 的 syncEnabled）
    public var planID: UUID?
    public var schemaV: Int
    /// CKRecord.systemFields（保留变更标签，用于一致性写）；内存后端为 nil
    public var systemFields: Data?

    public init(entityType: EntityType, entityID: UUID, rev: Int, deviceId: String,
                updatedAt: Date, deletedAt: Date? = nil, stateJSON: Data,
                fieldRev: [String: Int] = [:], planID: UUID? = nil,
                schemaV: Int = SyncRecordType.schemaVersion, systemFields: Data? = nil) {
        self.entityType = entityType; self.entityID = entityID; self.rev = rev
        self.deviceId = deviceId; self.updatedAt = updatedAt; self.deletedAt = deletedAt
        self.stateJSON = stateJSON; self.fieldRev = fieldRev; self.planID = planID
        self.schemaV = schemaV; self.systemFields = systemFields
    }

    public var isDeleted: Bool { deletedAt != nil }

    /// 记录占用字节数（含多段拆分）
    public var stateByteCount: Int { stateJSON.count }

    /// 9.2：stateJSON 超限时切成 stateJSON_1..n，映射层透明处理
    public var stateChunks: [Data] {
        guard stateJSON.count > SyncRecordType.maxStateBytes else { return [stateJSON] }
        var chunks: [Data] = []
        var index = stateJSON.startIndex
        while index < stateJSON.endIndex {
            let next = stateJSON.index(index, offsetBy: SyncRecordType.maxStateBytes,
                                      limitedBy: stateJSON.endIndex) ?? stateJSON.endIndex
            chunks.append(stateJSON[index..<next])
            index = next
        }
        return chunks
    }

    /// 从拆分结果还原（映射层透明处理）
    public static func reassemble(_ chunks: [Data]) -> Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }

    /// 按字段还原状态字典；解析失败返回空（不吞掉实体本身）
    public var stateFields: [String: JSONValue] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: stateJSON),
              case .object(let dict) = value else { return [:] }
        return dict
    }
}

// MARK: - 事件记录（RecordType: MovoEvent）

/// ChangeEvent 追加同步（幂等去重：recordName == eventID）
public struct EventRecord: Sendable, Hashable, Codable {
    public var eventID: UUID
    public var entityID: UUID
    public var entityType: EntityType
    public var operationId: UUID
    public var payloadJSON: Data
    public var occurredAt: Date
    public var recordedAt: Date
    public var deviceId: String
    public var systemFields: Data?

    public init(eventID: UUID, entityID: UUID, entityType: EntityType, operationId: UUID,
                payloadJSON: Data, occurredAt: Date, recordedAt: Date, deviceId: String,
                systemFields: Data? = nil) {
        self.eventID = eventID; self.entityID = entityID; self.entityType = entityType
        self.operationId = operationId; self.payloadJSON = payloadJSON
        self.occurredAt = occurredAt; self.recordedAt = recordedAt
        self.deviceId = deviceId; self.systemFields = systemFields
    }

    public init(_ event: ChangeEvent) {
        self.init(eventID: event.id, entityID: event.entityId, entityType: event.entityType,
                  operationId: event.operationId,
                  payloadJSON: (try? JSONEncoder().encode(event)) ?? Data("{}".utf8),
                  occurredAt: event.occurredAt, recordedAt: event.recordedAt,
                  deviceId: event.deviceId)
    }

    public var asChangeEvent: ChangeEvent? {
        try? JSONDecoder().decode(ChangeEvent.self, from: payloadJSON)
    }
}

// MARK: - 元数据（RecordType: MovoMeta）

/// 单例记录，recordName 固定为 "MovoMeta"。
public struct MetaRecord: Sendable, Hashable, Codable {
    public static let recordName = "MovoMeta"

    public var schemaVersion: Int
    public var deviceID: String
    public var lastMigratedAt: Date?
    /// 上次共同同步点游标（9.4 的 S_base 判据：本地已知的最高 rev per entity）
    public var knownRevisions: [String: Int]
    /// 拉取游标（CKSyncEngine 状态序列化，后端自己持久化，这里只记录时间用于展示）
    public var lastPulledAt: Date?
    public var lastPushedAt: Date?

    public init(schemaVersion: Int = SyncRecordType.schemaVersion, deviceID: String,
                lastMigratedAt: Date? = nil, knownRevisions: [String: Int] = [:],
                lastPulledAt: Date? = nil, lastPushedAt: Date? = nil) {
        self.schemaVersion = schemaVersion; self.deviceID = deviceID
        self.lastMigratedAt = lastMigratedAt; self.knownRevisions = knownRevisions
        self.lastPulledAt = lastPulledAt; self.lastPushedAt = lastPushedAt
    }

    public static func key(entityType: EntityType, id: UUID) -> String {
        "\(entityType.rawValue):\(id.uuidString)"
    }

    public func knownRevision(of entityType: EntityType, id: UUID) -> Int {
        knownRevisions[Self.key(entityType: entityType, id: id)] ?? 0
    }

    public mutating func remember(revision: Int, of entityType: EntityType, id: UUID) {
        let k = Self.key(entityType: entityType, id: id)
        knownRevisions[k] = max(revision, knownRevisions[k] ?? 0)
    }

    /// 永久删除实体后清掉游标，避免无界增长
    public mutating func forget(entityType: EntityType, id: UUID) {
        knownRevisions.removeValue(forKey: Self.key(entityType: entityType, id: id))
    }
}

// MARK: - 拉取/推送结果

/// 一次同步往返的收据，用于 SyncState 与 UI 文案。
public struct SyncPassReport: Sendable, Hashable {
    public var pushedEntities: Int
    public var pushedEvents: Int
    public var pulledEntities: Int
    public var pulledEvents: Int
    /// 本地被远端覆盖的实体（含新增）
    public var appliedEntities: Int
    /// 检测到并挂起的冲突数
    public var detectedConflicts: Int
    /// 因旧设备后补编辑而被丢弃的变更（AC11）
    public var discardedRevivals: Int
    public var at: Date

    public init(pushedEntities: Int = 0, pushedEvents: Int = 0, pulledEntities: Int = 0,
                pulledEvents: Int = 0, appliedEntities: Int = 0, detectedConflicts: Int = 0,
                discardedRevivals: Int = 0, at: Date = Date()) {
        self.pushedEntities = pushedEntities; self.pushedEvents = pushedEvents
        self.pulledEntities = pulledEntities; self.pulledEvents = pulledEvents
        self.appliedEntities = appliedEntities; self.detectedConflicts = detectedConflicts
        self.discardedRevivals = discardedRevivals; self.at = at
    }

    public var summaryText: String {
        var parts: [String] = []
        if pushedEntities + pushedEvents > 0 { parts.append("上传 \(pushedEntities + pushedEvents) 项") }
        if appliedEntities > 0 { parts.append("应用 \(appliedEntities) 项") }
        if detectedConflicts > 0 { parts.append("待确认 \(detectedConflicts) 处") }
        if discardedRevivals > 0 { parts.append("丢弃 \(discardedRevivals) 条过期编辑") }
        return parts.isEmpty ? "已是最新" : parts.joined(separator: " · ")
    }
}
