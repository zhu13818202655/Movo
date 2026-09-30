//
//  CloudKitSyncBackend.swift
//  Data/Sync
//
//  T3.1：CKSyncEngine 封装 + 9.2 记录映射 + MovoMeta。
//
//  · 私有数据库、默认容器、自有 zone（SyncRecordType.zoneName）。
//  · 出站：pending record zone changes → nextRecordZoneChangeBatch → sendChanges。
//  · 入站：fetchChanges → delegate 事件 → 收件箱 → pullEntities/pullEvents。
//  · 状态序列化（游标）持久化在 UserDefaults，key 与容器无关。
//  · 未签名 / 未配置 iCloud 容器时**根本不构造后端**（`makeDefault()` 返回 nil）→
//    同步降级为 .unavailable，本机功能完全不受影响（PRD 19 / 9.1）。
//    原因：`CKContainer.defaultContainer` 在无 entitlement 时会抛 ObjC 异常，
//    且该异常在 CloudKit 内部的 dispatch_once 块中抛出，无法被任何 @try/@catch 拦截，
//    故必须完全不触碰它——以 Info.plist 的显式配置为准。
//

import Foundation
import CloudKit

public actor CloudKitSyncBackend: SyncBackend, CKSyncEngineDelegate {

    // MARK: 常量

    private static let serializationKey = "movo.sync.ck.state"

    private let zoneID = CKRecordZone.ID(zoneName: SyncRecordType.zoneName,
                                         ownerName: CKCurrentUserDefaultName)
    private let container: CKContainer
    private let defaults: UserDefaults

    // MARK: 状态

    private var engine: CKSyncEngine?
    private var prepared = false

    // 出站暂存（等待 nextRecordZoneChangeBatch 取用）
    private var outgoingEntities: [UUID: EntityRecord] = [:]
    private var outgoingEvents: [UUID: EventRecord] = [:]
    private var outgoingDeletes: Set<UUID> = []

    // 入站收件箱
    private var inboxEntities: [UUID: EntityRecord] = [:]
    private var inboxEvents: [UUID: EventRecord] = [:]
    private var inboxHardDeletions: Set<UUID> = []
    private var consumedHardDeletions: Set<UUID> = []

    private var metaRecord: MetaRecord?
    private var lastPushSaved = 0
    private var lastErrorText: String?

    // MARK: 初始化

    /// ⚠️ 必须显式传入容器，**绝不可**使用 `CKContainer.default()`：
    /// 当 entitlements 未声明 `com.apple.developer.icloud-container-identifiers` 时，
    /// 它会抛出 ObjC 异常 `CKException: containerIdentifier can not be nil`；
    /// Swift 无法捕获 ObjC 异常，进程会被直接终止（本工程无 iCloud 配置时的默认路径）。
    public init(container: CKContainer, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
    }

    /// Info.plist 配置键：本 App 的 iCloud 容器 ID。留空 = 未启用云同步。
    public static let containerIDInfoPlistKey = "MovoICloudContainerID"

    /// 已显式配置的 iCloud 容器 ID；未配置时返回 `nil`。
    public static var configuredContainerID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: containerIDInfoPlistKey) as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 当前构建是否已配置 iCloud 容器。
    public static var isContainerConfigured: Bool { configuredContainerID != nil }

    /// 仅当显式配置了 iCloud 容器时才返回后端；否则返回 `nil`，同步降级为 `.unavailable`。
    ///
    /// ⚠️ **绝不调用 `CKContainer.defaultContainer`**：
    /// 当 entitlements 未声明 `com.apple.developer.icloud-container-identifiers` 时，
    /// 它会抛出 ObjC 异常 `CKException: containerIdentifier can not be nil`；
    /// 且该异常是在 CloudKit 内部一个 `dispatch_once` 块中抛出的——libdispatch
    /// 不具备异常展开信息，**任何 `@try/@catch`（含 catch-all）都无法拦截**，
    /// unwinder 会直接调用 `std::terminate` 终止进程（已实测验证）。
    /// 因此这里以「显式配置」为唯一依据：未配置时完全不触碰 CloudKit。
    public static func makeDefault() -> CloudKitSyncBackend? {
        guard let identifier = configuredContainerID else { return nil }
        return CloudKitSyncBackend(container: CKContainer(identifier: identifier))
    }

    // MARK: - SyncBackend：账号

    public func accountState() async -> CloudAccountState {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available: return .available
            case .noAccount: return .notSignedIn
            case .restricted: return .restricted
            case .couldNotDetermine: return .unknown
            case .temporarilyUnavailable: return .temporarilyUnavailable
            @unknown default: return .unknown
            }
        } catch {
            // 缺少 iCloud entitlement、未签名构建、网络异常都落到这里
            return .unavailable
        }
    }

    // MARK: - SyncBackend：准备

    public func prepare() async throws {
        let state = await accountState()
        guard state.isReady else {
            throw SyncTransportError.accountUnavailable(state)
        }
        let engine = ensureEngine()
        if !prepared {
            // 建 zone（幂等：已存在时 CK 忽略）
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            prepared = true
        }
        try await engine.sendChanges()
    }

    // MARK: - SyncBackend：入站

    public func pullEntities() async throws -> [EntityRecord] {
        let engine = ensureEngine()
        do {
            try await engine.fetchChanges()
        } catch {
            lastErrorText = String(describing: error)
            throw Self.map(error)
        }
        let drained = inboxEntities.values.sorted { $0.updatedAt < $1.updatedAt }
        inboxEntities.removeAll()
        return drained
    }

    public func pullEvents() async throws -> [EventRecord] {
        let engine = ensureEngine()
        do {
            try await engine.fetchChanges()
        } catch {
            lastErrorText = String(describing: error)
            throw Self.map(error)
        }
        let drained = inboxEvents.values.sorted { $0.recordedAt < $1.recordedAt }
        inboxEvents.removeAll()
        return drained
    }

    public func pullHardDeletions() async throws -> [UUID] {
        let drained = inboxHardDeletions.subtracting(consumedHardDeletions)
        consumedHardDeletions.formUnion(drained)
        return drained.sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: - SyncBackend：出站

    @discardableResult
    public func push(entities: [EntityRecord], deletes: [UUID],
                     events: [EventRecord]) async throws -> Int {
        let engine = ensureEngine()

        for record in entities where record.entityType != .event {
            outgoingEntities[record.entityID] = record
            engine.state.add(pendingRecordZoneChanges: [
                .saveRecord(CKRecord.ID(recordName: record.entityID.uuidString, zoneID: zoneID))
            ])
        }
        for id in deletes {
            outgoingEntities.removeValue(forKey: id)
            outgoingDeletes.insert(id)
            engine.state.add(pendingRecordZoneChanges: [
                .deleteRecord(CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
            ])
        }
        for event in events {
            outgoingEvents[event.eventID] = event
            engine.state.add(pendingRecordZoneChanges: [
                .saveRecord(CKRecord.ID(recordName: event.eventID.uuidString, zoneID: zoneID))
            ])
        }

        lastPushSaved = 0
        do {
            try await engine.sendChanges()
        } catch {
            lastErrorText = String(describing: error)
            throw Self.map(error)
        }
        return lastPushSaved
    }

    // MARK: - SyncBackend：元数据

    public func readMeta() async throws -> MetaRecord? {
        if let metaRecord { return metaRecord }
        let engine = ensureEngine()
        do {
            let record = try await engine.database.record(
                for: CKRecord.ID(recordName: MetaRecord.recordName, zoneID: zoneID))
            let meta = Self.meta(from: record)
            metaRecord = meta
            return meta
        } catch {
            // 首次同步时还没有 meta 记录
            return nil
        }
    }

    public func writeMeta(_ meta: MetaRecord) async throws {
        metaRecord = meta
        guard let payload = try? JSONEncoder().encode(meta) else { return }
        let id = CKRecord.ID(recordName: MetaRecord.recordName, zoneID: zoneID)
        let record = CKRecord(recordType: SyncRecordType.meta, recordID: id)
        record["stateJSON"] = payload as CKRecordValue
        record["schemaVersion"] = meta.schemaVersion as CKRecordValue
        record["deviceID"] = meta.deviceID as CKRecordValue
        if let migrated = meta.lastMigratedAt { record["lastMigratedAt"] = migrated as CKRecordValue }
        if let pulled = meta.lastPulledAt { record["lastPulledAt"] = pulled as CKRecordValue }
        if let pushed = meta.lastPushedAt { record["lastPushedAt"] = pushed as CKRecordValue }
        do {
            let _: CKRecord = try await container.privateCloudDatabase.save(record)
        } catch {
            lastErrorText = String(describing: error)
            throw Self.map(error)
        }
    }

    // MARK: - SyncBackend：永久删除

    public func purge(entityIDs: [UUID]) async throws {
        guard !entityIDs.isEmpty else { return }
        let engine = ensureEngine()
        let database = engine.database

        // 1. 实体记录
        let recordIDs = entityIDs.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) }
        do {
            _ = try await database.modifyRecords(saving: [], deleting: recordIDs)
        } catch {
            lastErrorText = String(describing: error)
            throw Self.map(error)
        }

        // 2. 事件记录（按 entityID 查询；索引缺失时降级为只清实体，不阻断）
        do {
            let predicate = NSPredicate(format: "entityID IN %@",
                                        entityIDs.map(\.uuidString))
            let query = CKQuery(recordType: SyncRecordType.event, predicate: predicate)
            let (matches, _) = try await database.records(matching: query)
            let eventIDs = matches.map(\.0)
            if !eventIDs.isEmpty {
                _ = try await database.modifyRecords(saving: [], deleting: eventIDs)
            }
        } catch {
            lastErrorText = "event_purge_degraded: \(error)"
        }
    }

    // MARK: - 诊断

    public func errorText() -> String? { lastErrorText }
    public func pendingChangeCount() async -> Int {
        guard let engine else { return 0 }
        return engine.state.pendingRecordZoneChanges.count
    }

    // MARK: - CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            persist(serialization: update.stateSerialization)

        case .accountChange:
            // 账号变化由 SyncEngine 重新查询 accountState 决定；这里只清准备标记
            prepared = false

        case .fetchedRecordZoneChanges(let fetched):
            for modification in fetched.modifications {
                ingest(modification.record)
            }
            for deletion in fetched.deletions {
                if let id = deletion.recordID.recordName.recordNameUUID {
                    inboxHardDeletions.insert(id)
                }
            }

        case .sentRecordZoneChanges(let sent):
            lastPushSaved += sent.savedRecords.count
            for record in sent.savedRecords {
                let key = Self.uuid(from: record.recordID.recordName)
                if record.recordType == SyncRecordType.event {
                    outgoingEvents.removeValue(forKey: key)
                } else {
                    outgoingEntities.removeValue(forKey: key)
                }
            }
            for failed in sent.failedRecordSaves {
                lastErrorText = "save_failed: \(failed.error.code.rawValue)"
            }
            for id in sent.deletedRecordIDs {
                outgoingDeletes.remove(Self.uuid(from: id.recordName))
            }
            for (id, error) in sent.failedRecordDeletes {
                lastErrorText = "delete_failed: \(id.recordName) \(error.code.rawValue)"
            }

        case .didSendChanges, .didFetchChanges:
            break

        case .willSendChanges, .willFetchChanges,
             .fetchedDatabaseChanges, .sentDatabaseChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {

        var toSave: [CKRecord] = []
        var toDelete: [CKRecord.ID] = []

        for pending in syncEngine.state.pendingRecordZoneChanges {
            switch pending {
            case .saveRecord(let id):
                if let record = record(for: id) { toSave.append(record) }
            case .deleteRecord(let id):
                toDelete.append(id)
            @unknown default:
                break
            }
        }

        guard !toSave.isEmpty || !toDelete.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: toSave,
                                                 recordIDsToDelete: toDelete,
                                                 atomicByZone: false)
    }

    // MARK: - 引擎

    private func ensureEngine() -> CKSyncEngine {
        if let engine { return engine }
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: loadSerialization(),
            delegate: self)
        let created = CKSyncEngine(configuration)
        engine = created
        return created
    }

    private func persist(serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        defaults.set(data, forKey: Self.serializationKey)
    }

    private func loadSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = defaults.data(forKey: Self.serializationKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    // MARK: - 记录映射（9.2）

    /// 出站：值类型 → CKRecord
    private func record(for id: CKRecord.ID) -> CKRecord? {
        let key = Self.uuid(from: id.recordName)

        if let entity = outgoingEntities[key] {
            let record = CKRecord(recordType: SyncRecordType.entity, recordID: id)
            record["entityType"] = entity.entityType.rawValue as CKRecordValue
            record["entityID"] = entity.entityID.uuidString as CKRecordValue
            record["rev"] = entity.rev as CKRecordValue
            record["deviceId"] = entity.deviceId as CKRecordValue
            record["updatedAt"] = entity.updatedAt as CKRecordValue
            record["schemaV"] = entity.schemaV as CKRecordValue
            if let deletedAt = entity.deletedAt {
                record["deletedAt"] = deletedAt as CKRecordValue
            }
            if let planID = entity.planID {
                record["planID"] = planID.uuidString as CKRecordValue
            }
            if let fieldRev = try? JSONEncoder().encode(entity.fieldRev) {
                record["fieldRev"] = fieldRev as CKRecordValue
            }
            // stateJSON：≤64KB 单字段，超限拆 stateJSON_2..n
            let chunks = entity.stateChunks
            if let first = chunks.first {
                record["stateJSON"] = first as CKRecordValue
                record["stateChunkCount"] = chunks.count as CKRecordValue
                for (offset, chunk) in chunks.dropFirst().enumerated() {
                    record["stateJSON_\(offset + 2)"] = chunk as CKRecordValue
                }
            }
            return record
        }

        if let event = outgoingEvents[key] {
            let record = CKRecord(recordType: SyncRecordType.event, recordID: id)
            record["eventID"] = event.eventID.uuidString as CKRecordValue
            record["entityID"] = event.entityID.uuidString as CKRecordValue
            record["entityType"] = event.entityType.rawValue as CKRecordValue
            record["operationId"] = event.operationId.uuidString as CKRecordValue
            record["payloadJSON"] = event.payloadJSON as CKRecordValue
            record["occurredAt"] = event.occurredAt as CKRecordValue
            record["recordedAt"] = event.recordedAt as CKRecordValue
            record["deviceId"] = event.deviceId as CKRecordValue
            return record
        }

        return nil
    }

    /// 入站：CKRecord → 值类型 → 收件箱
    private func ingest(_ record: CKRecord) {
        switch record.recordType {
        case SyncRecordType.entity:
            if let entity = Self.entity(from: record) {
                inboxEntities[entity.entityID] = entity
            }
        case SyncRecordType.event:
            if let event = Self.event(from: record) {
                inboxEvents[event.eventID] = event
            }
        case SyncRecordType.meta:
            metaRecord = Self.meta(from: record)
        default:
            break
        }
    }

    private static func entity(from record: CKRecord) -> EntityRecord? {
        guard let rawType = record["entityType"] as? String,
              let entityType = EntityType(rawValue: rawType),
              let rawID = record["entityID"] as? String,
              let entityID = UUID(uuidString: rawID) else { return nil }

        let chunks = reassembleState(record)
        let fieldRev: [String: Int] = {
            guard let data = record["fieldRev"] as? Data,
                  let dict = try? JSONDecoder().decode([String: Int].self, from: data)
            else { return [:] }
            return dict
        }()

        return EntityRecord(
            entityType: entityType,
            entityID: entityID,
            rev: (record["rev"] as? Int) ?? 1,
            deviceId: (record["deviceId"] as? String) ?? "",
            updatedAt: (record["updatedAt"] as? Date) ?? Date(timeIntervalSince1970: 0),
            deletedAt: record["deletedAt"] as? Date,
            stateJSON: chunks,
            fieldRev: fieldRev,
            planID: (record["planID"] as? String).flatMap(UUID.init(uuidString:)),
            schemaV: (record["schemaV"] as? Int) ?? SyncRecordType.schemaVersion)
    }

    private static func event(from record: CKRecord) -> EventRecord? {
        guard let rawID = record["eventID"] as? String, let eventID = UUID(uuidString: rawID),
              let rawEntity = record["entityID"] as? String, let entityID = UUID(uuidString: rawEntity),
              let rawType = record["entityType"] as? String,
              let entityType = EntityType(rawValue: rawType),
              let payload = record["payloadJSON"] as? Data else { return nil }

        return EventRecord(
            eventID: eventID, entityID: entityID, entityType: entityType,
            operationId: (record["operationId"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
            payloadJSON: payload,
            occurredAt: (record["occurredAt"] as? Date) ?? Date(timeIntervalSince1970: 0),
            recordedAt: (record["recordedAt"] as? Date) ?? Date(timeIntervalSince1970: 0),
            deviceId: (record["deviceId"] as? String) ?? "")
    }

    private static func meta(from record: CKRecord) -> MetaRecord? {
        guard let data = record["stateJSON"] as? Data else { return nil }
        return try? JSONDecoder().decode(MetaRecord.self, from: data)
    }

    /// 拆分还原（映射层透明处理，9.2）
    private static func reassembleState(_ record: CKRecord) -> Data {
        guard let first = record["stateJSON"] as? Data else { return Data("{}".utf8) }
        let count = (record["stateChunkCount"] as? Int) ?? 1
        guard count > 1 else { return first }
        var chunks: [Data] = [first]
        for index in 2...count {
            if let chunk = record["stateJSON_\(index)"] as? Data { chunks.append(chunk) }
        }
        return EntityRecord.reassemble(chunks)
    }

    // MARK: - 工具

    private static func uuid(from recordName: String) -> UUID {
        UUID(uuidString: recordName) ?? UUID()
    }

    private static func map(_ error: Error) -> SyncTransportError {
        guard let ckError = error as? CKError else {
            return .failed(reason: error.localizedDescription)
        }
        switch ckError.code {
        case .notAuthenticated, .accountTemporarilyUnavailable:
            return .accountUnavailable(.notSignedIn)
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return .offline
        default:
            return .failed(reason: "ck_\(ckError.code.rawValue)")
        }
    }
}

private extension String {
    /// recordName 反解 UUID（非 UUID 记录名返回 nil）
    var recordNameUUID: UUID? { UUID(uuidString: self) }
}
