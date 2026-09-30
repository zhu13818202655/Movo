//
//  SyncBackend.swift
//  Data/Sync
//
//  同步后端抽象 + 内存实现。
//
//  为什么要有这层：9.3 的循环（出站/入站/游标/防抖/重试）与 9.4 的合并算法
//  都不应该依赖真实网络。SyncBackend 只暴露"拉取/推送/元数据/账号状态"四件事，
//  于是 CloudKit 接入（T3.1）与引擎行为（T3.2–T3.4）可以分别实现、分别测试。
//

import Foundation

// MARK: - 传输错误

public enum SyncTransportError: Error, Sendable, Hashable {
    /// 离线：本机写入仍然成功，网络恢复后继续（9.1）
    case offline
    case accountUnavailable(CloudAccountState)
    case failed(reason: String)

    public var displayText: String {
        switch self {
        case .offline: "当前离线，改动已保存在本机"
        case .accountUnavailable(let state): state.displayName
        case .failed(let reason): "同步失败：\(reason)"
        }
    }
}

// MARK: - 后端协议

public protocol SyncBackend: Sendable {

    // MARK: 账号

    /// 9.6 iCloud 账号状态
    func accountState() async -> CloudAccountState

    /// 首次准备（建 zone、首次全量）。幂等。
    func prepare() async throws

    // MARK: 入站

    /// 拉取远端实体记录（增量；游标由实现内部维护）
    func pullEntities() async throws -> [EntityRecord]

    /// 拉取远端事件（增量）
    func pullEvents() async throws -> [EventRecord]

    /// 云端已永久删除的实体 ID（30 天到期后由任一设备清理，另一侧跟随，AC17）
    func pullHardDeletions() async throws -> [UUID]

    // MARK: 出站

    /// 推送实体（含删除墓碑）与事件；返回成功写入的记录数。幂等：重复推送无副作用。
    @discardableResult
    func push(entities: [EntityRecord], deletes: [UUID], events: [EventRecord]) async throws -> Int

    // MARK: 元数据

    func readMeta() async throws -> MetaRecord?
    func writeMeta(_ meta: MetaRecord) async throws

    // MARK: 永久删除（9.5 / AC17）

    /// 30 天到期后级联清理远端记录与事件
    func purge(entityIDs: [UUID]) async throws
}

public extension SyncBackend {
    /// 默认没有硬删除（内存后端与无云后端）；CloudKit 后端覆盖它
    func pullHardDeletions() async throws -> [UUID] { [] }
}

// MARK: - 本地无云实现

/// 没有 iCloud entitlement 或用户未开启同步时的实现：一切保持"未登录"，
/// 本机功能完全不受影响（PRD 19）。
public struct NullSyncBackend: SyncBackend {
    public init() {}
    public func accountState() async -> CloudAccountState { .unavailable }
    public func prepare() async throws { throw SyncTransportError.accountUnavailable(.unavailable) }
    public func pullEntities() async throws -> [EntityRecord] { [] }
    public func pullEvents() async throws -> [EventRecord] { [] }
    public func push(entities: [EntityRecord], deletes: [UUID],
                     events: [EventRecord]) async throws -> Int { 0 }
    public func readMeta() async throws -> MetaRecord? { nil }
    public func writeMeta(_ meta: MetaRecord) async throws { }
    public func purge(entityIDs: [UUID]) async throws { }
}

// MARK: - 内存实现（测试与预览）

/// 模拟"另一台设备"的云端。测试里先用 `simulateRemoteUpsert` 造出对端变更，
/// 再跑一次 `SyncEngine` 往返即可验证合并、冲突与幂等。
public actor InMemorySyncBackend: SyncBackend {

    private var entities: [UUID: EntityRecord] = [:]
    private var events: [UUID: EventRecord] = [:]
    private var meta: MetaRecord?
    /// 已推送到"云端"的事件游标
    private var eventLog: [UUID] = []

    private var _accountState: CloudAccountState
    /// 永久删除过的实体（AC17 对端跟随清理）
    private var purgedIDs: Set<UUID> = []
    private var consumedPurgedIDs: Set<UUID> = []
    /// 离线开关：置 true 后 push/pull 抛 offline（用于验证"离线仍写本机"）
    private var _isOffline = false
    /// 下一次推送强制失败（用于验证重试与 failed 状态）
    private var _failNextPush = false
    /// 统计推送次数（幂等验证）
    private var pushCount = 0

    public init(accountState: CloudAccountState = .available) {
        self._accountState = accountState
    }

    // MARK: 测试钩子

    public func setAccountState(_ state: CloudAccountState) { _accountState = state }
    public func setOffline(_ offline: Bool) { _isOffline = offline }
    public func setFailNextPush(_ fail: Bool) { _failNextPush = fail }
    public func pushInvocationCount() -> Int { pushCount }

    /// 模拟对端设备写入/更新一条实体记录
    public func simulateRemoteUpsert(_ record: EntityRecord) {
        entities[record.entityID] = record
    }

    /// 模拟对端设备删除（写墓碑记录）
    public func simulateRemoteDelete(_ id: UUID, entityType: EntityType,
                                     at date: Date, deviceId: String) {
        guard var existing = entities[id] else {
            entities[id] = EntityRecord(entityType: entityType, entityID: id, rev: 1,
                                        deviceId: deviceId, updatedAt: date,
                                        deletedAt: date, stateJSON: Data("{}".utf8))
            return
        }
        existing.deletedAt = date
        existing.updatedAt = date
        existing.deviceId = deviceId
        existing.rev += 1
        entities[id] = existing
    }

    /// 模拟对端推送事件
    public func simulateRemoteEvent(_ event: EventRecord) { events[event.eventID] = event }

    public func remoteEntityCount() -> Int { entities.count }
    public func remoteEventCount() -> Int { events.count }
    public func remoteEntity(_ id: UUID) -> EntityRecord? { entities[id] }
    public func remoteMeta() -> MetaRecord? { meta }

    // MARK: SyncBackend

    public func accountState() async -> CloudAccountState { _accountState }

    public func prepare() async throws {
        try ensureOnline()
    }

    public func pullEntities() async throws -> [EntityRecord] {
        try ensureOnline()
        return entities.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    public func pullEvents() async throws -> [EventRecord] {
        try ensureOnline()
        return eventLog.compactMap { events[$0] }
    }

    /// 已被永久删除的实体（已在事件里保留过一次，供对端跟随清理）
    public func pullHardDeletions() async throws -> [UUID] {
        try ensureOnline()
        let drained = purgedIDs.subtracting(consumedPurgedIDs).sorted { $0.uuidString < $1.uuidString }
        consumedPurgedIDs.formUnion(drained)
        return drained
    }

    @discardableResult
    public func push(entities newEntities: [EntityRecord], deletes: [UUID],
                     events newEvents: [EventRecord]) async throws -> Int {
        try ensureOnline()
        pushCount += 1
        if _failNextPush {
            _failNextPush = false
            throw SyncTransportError.failed(reason: "injected_failure")
        }

        var written = 0
        for record in newEntities {
            // 幂等：revision 不前进就跳过写入
            if let existing = entities[record.entityID],
               existing.rev >= record.rev, existing.deletedAt == record.deletedAt {
                continue
            }
            entities[record.entityID] = record
            written += 1
        }
        for id in deletes {
            if entities.removeValue(forKey: id) != nil { written += 1 }
        }
        for event in newEvents {
            if events[event.eventID] == nil {
                events[event.eventID] = event
                eventLog.append(event.eventID)
                written += 1
            }
        }
        return written
    }

    public func readMeta() async throws -> MetaRecord? { meta }

    public func writeMeta(_ meta: MetaRecord) async throws { self.meta = meta }

    public func purge(entityIDs: [UUID]) async throws {
        try ensureOnline()
        for id in entityIDs { entities.removeValue(forKey: id) }
        purgedIDs.formUnion(entityIDs)
        // 事件按实体级联清理
        let doomedEvents = events.filter { entityIDs.contains($0.value.entityID) }.map(\.key)
        for id in doomedEvents { events.removeValue(forKey: id) }
        eventLog.removeAll { doomedEvents.contains($0) }
    }

    private func ensureOnline() throws {
        if _isOffline { throw SyncTransportError.offline }
        guard _accountState.isReady else {
            throw SyncTransportError.accountUnavailable(_accountState)
        }
    }
}
