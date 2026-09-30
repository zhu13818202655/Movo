//
//  SyncEngine.swift
//  Data/Sync
//
//  9.3 同步引擎。封装后端的出站/入站循环 + 本地 dirty 队列 + 防抖 + 重试。
//
//  循环（9.3）：
//   1. 出站：dirty 实体 → 按 9.4 合并（本地为基准）→ 写本地 + 推送；pending 事件批量推送。
//   2. 入站：拉取远端记录 → 逐条按 9.4 合并 → 写本地 + 更新搜索索引。
//   3. 冲突：生成 SyncConflict 并推送（冲突本身也是实体），UI 显示待处理数。
//   4. 完成后：本地应用的事件置 synced=true，更新游标。
//
//  本类型是 actor：所有状态只在内部变更，跨边界只传 Sendable 值类型（1.3）。
//

import Foundation
import Observation

public actor SyncEngine {

    // MARK: 依赖

    private let repository: any DomainRepository
    private let backend: any SyncBackend
    private let defaults: AppDefaults
    private let deviceId: String
    private let now: @Sendable () -> Date
    /// 状态变化回调（AppEnvironment 用它把 SyncState 灌进 DomainStore 供 UI 读取）
    private let onStateChange: @Sendable (SyncState) async -> Void

    // MARK: 状态

    private var currentState: SyncState = .notSignedIn
    private var meta: MetaRecord
    private var isPassRunning = false
    private var debounceTask: _Concurrency.Task<Void, Never>?
    private var lastReportValue: SyncPassReport?
    private var started = false

    /// 9.3：dirty 非空时 3s 防抖后自动触发
    public static let debounceSeconds: Double = 3

    public init(repository: any DomainRepository,
                backend: any SyncBackend,
                defaults: AppDefaults = .fallback,
                deviceId: String,
                now: @escaping @Sendable () -> Date = { Date() },
                onStateChange: @escaping @Sendable (SyncState) async -> Void = { _ in }) {
        self.repository = repository
        self.backend = backend
        self.defaults = defaults
        self.deviceId = deviceId
        self.now = now
        self.onStateChange = onStateChange
        self.meta = MetaRecord(deviceID: deviceId)
    }

    // MARK: - 对外

    public func state() -> SyncState { currentState }
    public func lastReport() -> SyncPassReport? { lastReportValue }
    public func accountState() async -> CloudAccountState { await backend.accountState() }

    /// 应用启动 / 登录成功后调用：读元数据、判断账号、跑一次。
    @discardableResult
    public func start() async -> SyncPassReport {
        if !started {
            if let stored = try? await backend.readMeta() {
                meta = stored
                meta.deviceID = deviceId
            }
            started = true
        }
        return await syncNow()
    }

    /// 触发点：进前台 / 网络变化 / dirty 非空（3s 防抖）/ 手动"立即同步"。
    /// - Parameter debounced: true 时按 9.3 的 3s 防抖合并连续触发。
    public func trigger(debounced: Bool = true) {
        guard debounced else {
            _Concurrency.Task { [weak self] in await self?.syncNow() }
            return
        }
        debounceTask?.cancel()
        debounceTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            try? await _Concurrency.Task.sleep(for: .seconds(SyncEngine.debounceSeconds))
            if _Concurrency.Task.isCancelled { return }
            await self.syncNow()
        }
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - 一次完整往返

    @discardableResult
    public func syncNow() async -> SyncPassReport {
        var report = SyncPassReport(at: now())
        guard !isPassRunning else { return report }
        isPassRunning = true
        defer { isPassRunning = false }

        defer { lastReportValue = report }

        // 9.6 账号状态
        let account = await backend.accountState()
        switch account {
        case .available:
            break
        case .notSignedIn, .unavailable, .restricted:
            await publish(.notSignedIn)
            return report
        case .unknown, .temporarilyUnavailable:
            await publish(.failed(reason: account.displayName,
                                  retryAt: now().addingTimeInterval(60)))
            return report
        }

        do {
            try await backend.prepare()
        } catch let error as SyncTransportError {
            // 离线：本机写入仍然成功，恢复后继续（9.1）
            if case .offline = error {
                await publish(.failed(reason: error.displayText,
                                      retryAt: now().addingTimeInterval(30)))
            } else {
                await publish(.notSignedIn)
            }
            return report
        } catch {
            await publish(.failed(reason: "准备同步失败", retryAt: now().addingTimeInterval(30)))
            return report
        }

        // 9.5：先做 30 天到期清理
        await purgeExpiredLocally()

        // 计划级开关（9.6）
        let plans = await repository.allPlans()
        let syncEnabledPlanIDs = Set(plans.filter(\.syncEnabled).map(\.id))
        let tasks = await repository.allTasks()
        let planIDByTask = Dictionary(tasks.map { ($0.id, $0.planId) },
                                     uniquingKeysWith: { a, _ in a })

        @Sendable func allowed(_ planID: UUID?) -> Bool {
            guard let planID else { return true }   // 无计划归属跟随账号默认（同步）
            return syncEnabledPlanIDs.contains(planID)
        }

        // 本地未同步事件 → {entityID: {field: revAtLastChange}}，入站与出站共用。
        // 9.4：base 未知时靠它判断"哪一侧真的动过这个字段"。
        let fieldRevs = await unsyncedFieldRevisions()

        // 顺序说明：必须先入站再出站（9.3 的"出站前先取远端当前记录"）。
        // 否则"旧设备编辑 + 对端已删除"会被本地盲推覆盖掉对端墓碑，对象被复活（AC11）。
        // 入站把远端删除/合并结果落到本机后，出站推的就是收敛后的值。

        // ---- 入站 ----
        do {
            let remoteEntities = try await backend.pullEntities()
            report.pulledEntities = remoteEntities.count
            for remote in remoteEntities {
                guard allowed(remote.planID ?? planIDByTask[remote.entityID] ?? nil) else { continue }
                await applyRemote(remote, fieldRevs: fieldRevs, report: &report)
            }

            let remoteEvents = try await backend.pullEvents()
            report.pulledEvents = remoteEvents.count
            await ingestRemoteEvents(remoteEvents)

            let hardDeleted = try await backend.pullHardDeletions()
            for id in hardDeleted { await purgeLocally(id) }

            meta.lastPulledAt = now()
            try? await backend.writeMeta(meta)
        } catch let error as SyncTransportError {
            await publish(.failed(reason: error.displayText,
                                  retryAt: now().addingTimeInterval(30)))
            return report
        } catch {
            await publish(.failed(reason: "拉取失败", retryAt: now().addingTimeInterval(30)))
            return report
        }

        // ---- 出站 ----
        let outgoing = await collectDirtyRecords(planIDByTask: planIDByTask, isAllowed: allowed,
                                                 fieldRevByEntity: fieldRevs)
        let unsyncedEvents = await repository.events(unsyncedOnly: true)
        let eventRecords = unsyncedEvents.map { EventRecord($0) }

        if !outgoing.records.isEmpty || !eventRecords.isEmpty {
            await publish(.syncing(pendingCount: outgoing.records.count + eventRecords.count))
            do {
                let saved = try await backend.push(entities: outgoing.records,
                                                   deletes: [],
                                                   events: eventRecords)
                report.pushedEntities = outgoing.records.count
                report.pushedEvents = eventRecords.count
                _ = saved
                if !unsyncedEvents.isEmpty {
                    try? await repository.markEventsSynced(ids: unsyncedEvents.map(\.id))
                }
                for record in outgoing.records {
                    meta.remember(revision: record.rev, of: record.entityType, id: record.entityID)
                }
                meta.lastPushedAt = now()
            } catch let error as SyncTransportError {
                await publish(.failed(reason: error.displayText,
                                      retryAt: now().addingTimeInterval(30)))
                return report
            } catch {
                await publish(.failed(reason: "上传失败", retryAt: now().addingTimeInterval(30)))
                return report
            }
        }

        // ---- 状态收口 ----
        let conflictCount = await pendingConflictCount()
        if conflictCount > 0 {
            await publish(.conflictPending(count: conflictCount))
        } else {
            await publish(.upToDate(lastSyncedAt: now()))
        }
        return report
    }

    // MARK: - 冲突裁决落地（9.4 第 3 步）

    /// 用户已裁决但还没写回目标实体的冲突：按值幂等写回，再等下一次推送。
    @discardableResult
    public func applyResolvedConflicts() async -> Int {
        var applied = 0
        let resolved = await repository.conflicts(resolved: true)
        for conflict in resolved {
            guard let value = FieldMerge.resolvedValue(for: conflict) else { continue }
            guard let box = await localEntity(type: conflict.entityType, id: conflict.entityId) else { continue }
            let fields = FieldMerge.volumeFields(of: box)
            guard FieldMerge.needsApplication(value, field: conflict.field, in: fields) else { continue }
            let merged = FieldMerge.applying(value, field: conflict.field, to: fields)
            guard let rebuilt = box.applying(mergedFields: merged,
                                             revision: box.revision + 1,
                                             updatedAt: now()) else { continue }
            try? await rebuilt.upsert(into: repository)
            try? await repository.upsertSearchDocument(rebuilt.searchDocument())
            applied += 1
        }
        return applied
    }

    public func pendingConflictCount() async -> Int {
        await repository.conflicts(resolved: false).count
    }

    // MARK: - 出站

    private struct Outgoing {
        var records: [EntityRecord] = []
    }

    /// 本地未同步事件 → 每个实体每个字段的 revAtLastChange（9.2 的 fieldRev）
    private func unsyncedFieldRevisions() async -> [UUID: [String: Int]] {
        var map: [UUID: [String: Int]] = [:]
        for event in await repository.events(unsyncedOnly: true) {
            for field in event.fields {
                var fields = map[event.entityId] ?? [:]
                fields[field] = max(fields[field] ?? 0, event.newRevision)
                map[event.entityId] = fields
            }
        }
        return map
    }

    private func collectDirtyRecords(planIDByTask: [UUID: UUID?],
                                     isAllowed: @Sendable (UUID?) -> Bool,
                                     fieldRevByEntity: [UUID: [String: Int]]) async -> Outgoing {
        var out = Outgoing()
        let boxes = await allBoxes()

        for box in boxes {
            let resolvedPlanID = box.planID ?? planIDByTask[box.id] ?? nil
            // 计划实体自身：syncEnabled=false 时整条计划内容都不出站（9.6）
            if box.entityType == .plan {
                guard isAllowed(box.id) else { continue }
            } else {
                guard isAllowed(resolvedPlanID) else { continue }
            }

            // 增量：revision 未超过"已共同同步点"就不推
            let known = meta.knownRevision(of: box.entityType, id: box.id)
            guard known < box.revision else { continue }

            guard let record = box.record(rev: box.revision, deviceId: deviceId,
                                          deletedAt: nil,
                                          fieldRev: fieldRevByEntity[box.id] ?? [:],
                                          planID: resolvedPlanID) else { continue }
            out.records.append(record)
        }

        // 墓碑（删除必须能传播，否则对端会把对象推回来）
        for tombstone in await repository.tombstones(activeOnly: true) {
            let known = meta.knownRevision(of: .tombstone, id: tombstone.id)
            guard known < tombstone.revision else { continue }
            guard let payload = try? JSONEncoder().encode(tombstone) else { continue }
            out.records.append(EntityRecord(
                entityType: tombstone.entityType,
                entityID: tombstone.entityId,
                rev: tombstone.revision,
                deviceId: deviceId,
                updatedAt: tombstone.deletedAt,
                deletedAt: tombstone.deletedAt,
                stateJSON: payload,
                fieldRev: [:],
                planID: nil))
        }

        // 待推送的冲突本身也是实体（9.3 第 3 步）
        for conflict in await repository.conflicts(resolved: false) {
            let known = meta.knownRevision(of: .conflict, id: conflict.id)
            guard known < conflict.revision else { continue }
            guard let record = SyncEntityBox.conflict(conflict)
                .record(rev: conflict.revision, deviceId: deviceId) else { continue }
            out.records.append(record)
        }

        return out
    }

    private func allBoxes() async -> [SyncEntityBox] {
        var out: [SyncEntityBox] = []
        let plans = await repository.allPlans()
        out += plans.map(SyncEntityBox.plan)

        for plan in plans {
            out += await repository.stages(planID: plan.id).map(SyncEntityBox.stage)
            out += await repository.metrics(planID: plan.id).map(SyncEntityBox.metric)
        }

        out += await repository.allTasks().map(SyncEntityBox.task)

        let rules = await repository.rules()
        out += rules.map(SyncEntityBox.rule)
        for rule in rules {
            out += await repository.occurrences(ruleID: rule.id).map(SyncEntityBox.occurrence)
        }

        out += await repository.allActivities().map(SyncEntityBox.activity)
        out += await repository.allMeasurements().map(SyncEntityBox.measurement)
        out += await repository.allNotes().map(SyncEntityBox.note)
        out += await repository.allCaptures().map(SyncEntityBox.capture)
        out += await repository.suggestions(status: nil).map(SyncEntityBox.suggestion)
        out += await repository.tombstones(activeOnly: true).map(SyncEntityBox.tombstone)

        return out
    }

    // MARK: - 入站

    private func applyRemote(_ remote: EntityRecord, fieldRevs: [UUID: [String: Int]],
                             report: inout SyncPassReport) async {
        let localBox = await localEntity(type: remote.entityType, id: remote.entityID)

        // 本地没有这条实体
        guard let localBox else {
            if remote.isDeleted { return }              // 远端删了一个本机没有的对象
            guard let incoming = SyncEntityBox.decode(remote) else { return }
            try? await incoming.upsert(into: repository)
            try? await repository.upsertSearchDocument(incoming.searchDocument())
            meta.remember(revision: remote.rev, of: remote.entityType, id: remote.entityID)
            report.appliedEntities += 1
            return
        }

        // 复活防护（AC11）：已删对象的编辑不能复活对象
        let guardDecision = RevivalGuard.decide(localDeletedAt: nil,
                                               remoteDeletedAt: remote.deletedAt,
                                               localUpdatedAt: localBox.updatedAt)
        if guardDecision == .alreadyDeleted {
            meta.remember(revision: remote.rev, of: remote.entityType, id: remote.entityID)
            return
        }

        var localRecord = localBox.record(rev: localBox.revision, deviceId: deviceId,
                                          fieldRev: fieldRevs[localBox.id] ?? [:],
                                          planID: localBox.planID) ?? EntityRecord(
            entityType: localBox.entityType, entityID: localBox.id, rev: localBox.revision,
            deviceId: deviceId, updatedAt: localBox.updatedAt,
            stateJSON: localBox.encode() ?? Data("{}".utf8),
            fieldRev: fieldRevs[localBox.id] ?? [:])

        // 冲突裁决过的字段：决议值优先于本机旧值，避免反复产生同一个冲突
        await applyResolutions(to: &localRecord)

        let outcome = FieldMerge.merge(local: localRecord, remote: remote, base: nil)

        switch outcome.deletion {
        case .none:
            break
        case .remoteWins, .both:
            await applyRemoteDeletion(remote, outcome: outcome, report: &report)
            return
        case .localWins:
            return      // 本地墓碑会在出站时传给对端
        }

        if outcome.hasConflicts {
            await recordConflicts(outcome, local: localBox, remote: remote, report: &report)
        }

        guard outcome.changedLocally || guardDecision == .deletionWinsDiscardingLocalEdits else {
            meta.remember(revision: remote.rev, of: remote.entityType, id: remote.entityID)
            return
        }

        guard let rebuilt = localBox.applying(mergedFields: outcome.mergedFields,
                                              revision: outcome.resultingRev,
                                              updatedAt: outcome.updatedAt) else { return }
        try? await rebuilt.upsert(into: repository)
        try? await repository.upsertSearchDocument(rebuilt.searchDocument())
        // 只记到"已拉取的远端 rev"：合并结果（rev+1）保持为脏，交给随后的出站推给对端，
        // 两端才会真正收敛（否则本地合并结果永远留在本机）。
        meta.remember(revision: remote.rev, of: rebuilt.entityType, id: rebuilt.id)
        report.appliedEntities += 1
    }

    /// 远端删除落地：级联删除 + 写墓碑；本地更新的编辑被丢弃（AC11）
    private func applyRemoteDeletion(_ remote: EntityRecord, outcome: MergeOutcome,
                                     report: inout SyncPassReport) async {
        if outcome.discardedLocalEdit { report.discardedRevivals += 1 }

        let targets = await SyncLocalStore.cascadeIDs(type: remote.entityType,
                                                     id: remote.entityID,
                                                     repository: repository)
        for id in targets where id != remote.entityID {
            await SyncLocalStore.deleteUnknown(id: id, repository: repository)
        }
        await SyncLocalStore.delete(type: remote.entityType, id: remote.entityID,
                                    repository: repository)

        // 写本地墓碑，保证对端不会把对象推回来
        let retention = defaults.lifecycle.tombstoneRetentionDays
        let tombstone = Tombstone(entityType: remote.entityType, entityId: remote.entityID,
                                  deletedAt: remote.deletedAt ?? now(),
                                  deviceId: deviceId, retentionDays: retention)
        try? await repository.upsert(tombstone)

        meta.remember(revision: remote.rev, of: remote.entityType, id: remote.entityID)
        meta.forget(entityType: .tombstone, id: tombstone.id)
        report.appliedEntities += 1
    }

    /// 把已裁决的冲突值写进本地记录，避免同一冲突反复产生
    private func applyResolutions(to record: inout EntityRecord) async {
        let resolved = await repository.conflicts(resolved: true)
        guard !resolved.isEmpty else { return }
        var fields = record.stateFields
        var touched = false
        for conflict in resolved where conflict.entityId == record.entityID {
            guard let value = FieldMerge.resolvedValue(for: conflict) else { continue }
            if fields[conflict.field] != value {
                fields[conflict.field] = value
                touched = true
            }
        }
        if touched, let data = FieldMerge.encode(fields: fields) {
            record.stateJSON = data
        }
    }

    /// 冲突记录本身也是实体：写库 + 等出站推送
    private func recordConflicts(_ outcome: MergeOutcome, local: SyncEntityBox,
                                 remote: EntityRecord, report: inout SyncPassReport) async {
        let existing = await repository.conflicts(resolved: false)
        var detected = 0

        for conflict in outcome.conflicts {
            // 幂等：同一实体同一字段已有未处理冲突就不重复建
            if existing.contains(where: {
                $0.entityType == outcome.entityType && $0.entityId == outcome.entityID
                    && $0.field == conflict.field
            }) { continue }

            let record = SyncConflict(
                entityType: outcome.entityType,
                entityId: outcome.entityID,
                field: conflict.field,
                localValue: conflict.localValue,
                localRev: conflict.localRev,
                localDeviceId: conflict.localDeviceId,
                localChangedAt: conflict.localChangedAt,
                remoteValue: conflict.remoteValue,
                remoteRev: conflict.remoteRev,
                remoteDeviceId: conflict.remoteDeviceId,
                remoteChangedAt: conflict.remoteChangedAt,
                baseRev: remote.rev,
                detectedAt: now())
            try? await repository.upsert(record)
            detected += 1

            // 冲突也要能到对端，否则两端会各自反复建同一条
            if let box = SyncEntityBox.conflict(record).record(rev: record.revision,
                                                              deviceId: deviceId) {
                _ = try? await backend.push(entities: [box], deletes: [], events: [])
                meta.remember(revision: box.rev, of: .conflict, id: box.entityID)
            }
        }

        _ = local
        report.detectedConflicts += detected
    }

    /// 远端事件入库（追加-only，幂等去重；入站事件标记 synced=true 防止回推）
    private func ingestRemoteEvents(_ events: [EventRecord]) async {
        guard !events.isEmpty else { return }
        var existingIDs = Set<UUID>()
        for event in events {
            if await repository.event(event.eventID) != nil {
                existingIDs.insert(event.eventID)
                continue
            }
            guard var change = event.asChangeEvent else { continue }
            change.synced = true
            try? await repository.append(change)
        }
        _ = existingIDs
    }

    // MARK: - 永久删除

    /// 30 天到期：本地级联清理 + 通知远端清理
    private func purgeExpiredLocally() async {
        let tombstones = await repository.tombstones(activeOnly: true)
        guard !tombstones.isEmpty else { return }
        let outcome = await TombstoneSync.purgeExpired(tombstones: tombstones,
                                                      repository: repository,
                                                      now: now())
        guard !outcome.remoteIDs.isEmpty else { return }
        try? await backend.purge(entityIDs: outcome.remoteIDs)
        for id in outcome.remoteIDs {
            meta.forget(entityType: .tombstone, id: id)
        }
    }

    /// 对端永久删除：本机跟随清理（AC17）
    private func purgeLocally(_ id: UUID) async {
        await SyncLocalStore.deleteUnknown(id: id, repository: repository)
        try? await repository.deleteTombstone(id)
    }

    // MARK: - 状态

    private func publish(_ state: SyncState) async {
        currentState = state
        await onStateChange(state)
    }

    // MARK: - 本地读取

    private func localEntity(type: EntityType, id: UUID) async -> SyncEntityBox? {
        await SyncEntityBox.fetch(type: type, id: id, in: repository)
    }
}
