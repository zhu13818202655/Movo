//
//  DomainStore.swift
//  Domain/Commands
//
//  4.1 DomainStore：唯一写串行化门面。
//
//  并发说明（对应 1.3）：本类型为 @MainActor 隔离的最终类，即"主 actor 上的唯一写入者"。
//  事务体因此固定执行在主 ModelContext 内（SwiftData 主上下文），跨边界只传 Sendable 值类型，
//  @Model 对象不离开事务体；事务外的校验与实例化规划为纯计算。
//

import Foundation
import Observation

/// 写入完成后广播的变更信息（UI 订阅以刷新）
public struct ChangeNotification: Sendable, Hashable {
    public var batchID: UUID
    public var entityIDs: [UUID]
    public var kinds: [OperationKind]
    public var summary: String
    public var canUndo: Bool
    public var at: Date

    public init(batchID: UUID, entityIDs: [UUID], kinds: [OperationKind], summary: String,
                canUndo: Bool, at: Date) {
        self.batchID = batchID; self.entityIDs = entityIDs; self.kinds = kinds
        self.summary = summary; self.canUndo = canUndo; self.at = at
    }
}

@MainActor
@Observable
public final class DomainStore {

    public let repository: DomainRepository
    public let clock: MovoClock
    public let timeZoneProvider: TimeZoneProvider
    public let deviceIDProvider: DeviceIDProvider
    public let defaults: AppDefaults

    /// 每次成功写入后自增；视图用 `.task(id: store.dataVersion)` 触发重查。
    public private(set) var dataVersion: Int = 0
    /// 最近一次批量结果（结果条"已添加 n 项 · 可撤销"）
    public private(set) var lastBatch: BatchResult?
    public private(set) var lastNotification: ChangeNotification?

    private var idempotencyCache: [UUID: CommandResult] = [:]
    private var notifications: [ChangeNotification] = []
    private var syncState: SyncState = .idle

    public init(repository: DomainRepository,
                clock: MovoClock = SystemClock(),
                timeZoneProvider: TimeZoneProvider = SystemTimeZoneProvider(),
                deviceIDProvider: DeviceIDProvider = StoredDeviceIDProvider(),
                defaults: AppDefaults = .fallback) {
        self.repository = repository
        self.clock = clock
        self.timeZoneProvider = timeZoneProvider
        self.deviceIDProvider = deviceIDProvider
        self.defaults = defaults
    }

    // MARK: - 环境

    public var now: Date { clock.now() }
    public var currentTimeZone: TimeZone { timeZoneProvider.current() }
    public var today: DateOnly { DateOnly(from: clock.now(), in: timeZoneProvider.current()) }
    public var deviceId: String { deviceIDProvider.deviceID() }

    // MARK: - 单命令

    @discardableResult
    public func execute(_ command: some DomainCommand) async throws -> CommandResult {
        try await run([command]).first ?? CommandResult(operationID: UUID(), userMessage: "")
    }

    /// 批量/幂等（batchId）；先影响预览，确认后才作为单 batch 提交
    public func executeBatch(_ input: BatchInput) async throws -> BatchResult {
        let batchID = input.batchID
        let results = try await run(input.commands, batchID: batchID,
                                    captureID: input.captureId, source: input.source,
                                    summary: input.summary)
        let applied = results.map(\.operationID)
        let summary: String
        if results.isEmpty {
            summary = "没有需要执行的更改。"
        } else if results.count == 1 {
            summary = results[0].userMessage
        } else {
            summary = "已整理 \(results.count) 项 · 可撤销"
        }
        let result = BatchResult(batchID: batchID, applied: applied, rejected: [],
                                 needsConfirmation: [], state: .applied, summary: summary)
        lastBatch = result
        return result
    }

    /// 逐条校验、部分失败的批量执行（AI 提案落地路径）。
    /// 单条失败不阻断其余；失败项进入收件箱（6.2 C8）。
    public func executeBatchAllowingPartial(_ input: BatchInput) async throws -> BatchResult {
        let batchID = input.batchID
        var applied: [UUID] = []
        var rejected: [BatchRejection] = []
        let stamp = clock.now()
        let tz = timeZoneProvider.current()
        let today = DateOnly(from: stamp, in: tz)

        for command in input.commands {
            if idempotencyCache[command.operationID] != nil { continue }
            try await repository.beginTransaction()
            do {
                let ctx = CommandContext(repository: repository, now: stamp, today: today,
                                         timeZone: tz, defaults: defaults, deviceId: deviceId,
                                         operationID: command.operationID, batchID: batchID,
                                         declaredBaseRevision: command.baseRevision)
                let result = try await command.execute(in: ctx)
                let payload = (try? JSONEncoder().encode(ctx.patch)) ?? Data("{}".utf8)
                let operation = Operation(id: command.operationID, batchId: batchID, kind: command.kind,
                                          entityType: command.entityType,
                                          entityId: result.entityID ?? command.entityID,
                                          payload: payload, baseRevision: command.baseRevision,
                                          status: .applied, reason: ctx.recordedReason ?? result.userMessage,
                                          createdAt: stamp)
                _ = try await ctx.write(operation, old: nil)
                try await repository.commitTransaction()
                idempotencyCache[command.operationID] = result
                applied.append(command.operationID)
            } catch let error as MovoError {
                try? await repository.rollbackTransaction()
                rejected.append(BatchRejection(operationID: command.operationID,
                                               entityID: command.entityID,
                                               reason: error.message))
            } catch {
                try? await repository.rollbackTransaction()
                rejected.append(BatchRejection(operationID: command.operationID,
                                               entityID: command.entityID,
                                               reason: error.localizedDescription))
            }
        }

        // 批元数据（部分成功也留批，便于整批撤销）
        if applied.count + rejected.count > 1 || input.captureId != nil {
            let state: BatchState = rejected.isEmpty ? .applied : (applied.isEmpty ? .failed : .partial)
            let batch = OperationBatch(id: batchID, captureId: input.captureId, source: input.source,
                                       createdAt: stamp, deviceId: deviceId, state: state,
                                       summary: input.summary)
            let existing = await repository.batch(batchID)
            _ = try? await ctxWrite(batch, old: existing, stamp: stamp, today: today,
                                    tz: tz, batchID: batchID)
        }

        let state: BatchState = rejected.isEmpty ? .applied : (applied.isEmpty ? .failed : .partial)
        let summary: String = {
            if rejected.isEmpty { return "已整理 \(applied.count) 项 · 可撤销" }
            if applied.isEmpty { return "没有内容被应用，原文已保留。" }
            return "\(applied.count)项已处理，\(rejected.count)项需要你确认"
        }()
        let result = BatchResult(batchID: batchID, applied: applied, rejected: rejected,
                                 needsConfirmation: [], state: state, summary: summary)
        lastBatch = result

        if !applied.isEmpty {
            dataVersion &+= 1
            let notification = ChangeNotification(batchID: batchID,
                                                 entityIDs: input.commands.map(\.entityID),
                                                 kinds: input.commands.map(\.kind),
                                                 summary: summary, canUndo: true, at: stamp)
            notifications.append(notification)
            if notifications.count > 50 { notifications.removeFirst(notifications.count - 50) }
            lastNotification = notification
        }
        return result
    }

    // MARK: - 撤销（补偿式）

    /// 4.4 undo(batch)：逆序补偿；遇到后续编辑（revision > baseRevision）跳过并列出冲突说明。
    public func undo(batchID: UUID) async throws -> UndoResult {
        guard let batch = await repository.batch(batchID) else {
            throw MovoError.notFound(entityType: .batch, id: batchID)
        }
        let operations = await repository.operations(batchID: batchID)
        let stamp = clock.now()
        let tz = timeZoneProvider.current()
        let today = DateOnly(from: stamp, in: tz)

        var undone: [UUID] = []
        var unsafe: [(UUID, String)] = []
        var nonUndoable: [(UUID, OperationKind)] = []
        var skipped: Set<UUID> = []

        // 先前置扫描：不可撤销集与"有后续编辑"的 op 都不执行
        for op in operations.reversed() {
            guard op.status == .applied else { continue }
            guard op.kind.isUndoable else {
                nonUndoable.append((op.id, op.kind)); skipped.insert(op.id); continue
            }
            let events = await repository.events(entityID: op.entityId)
            let newer = events.filter { $0.newRevision > max(op.baseRevision, 1) && $0.operationId != op.id }
            if !newer.isEmpty {
                unsafe.append((op.id, "「\(op.kind.displayName)」之后又有了 \(newer.count) 次修改，撤销会覆盖它们，已跳过。"))
                skipped.insert(op.id)
            }
        }

        try await repository.beginTransaction()
        do {
            for op in operations.reversed() {
                guard op.status == .applied, op.kind.isUndoable, !skipped.contains(op.id) else { continue }
                let ctx = CommandContext(repository: repository, now: stamp, today: today, timeZone: tz,
                                         defaults: defaults, deviceId: deviceId,
                                         operationID: UUID(), batchID: batchID)
                try await Self.applyInverse(op: op, in: ctx)
                undone.append(op.id)
            }
            var updatedBatch = batch
            updatedBatch.state = .undone
            updatedBatch.summary = "已撤销 \(undone.count) 项" + (skipped.isEmpty ? "" : "（\(skipped.count) 项保留）")
            let existing = await repository.batch(batchID)
            _ = try await ctxWrite(updatedBatch, old: existing, stamp: stamp, today: today,
                                   tz: tz, batchID: batchID)
            try await repository.commitTransaction()
        } catch {
            try? await repository.rollbackTransaction()
            throw error
        }

        dataVersion &+= 1
        return UndoResult(batchId: batchID, undoneOperations: undone,
                          unsafeOperations: unsafe, nonUndoableOperations: nonUndoable)
    }

    private func ctxWrite<T: RevisionedEntity & Encodable>(_ entity: T, old: T?, stamp: Date,
                                                           today: DateOnly, tz: TimeZone,
                                                           batchID: UUID) async throws -> T {
        let ctx = CommandContext(repository: repository, now: stamp, today: today, timeZone: tz,
                                 defaults: defaults, deviceId: deviceId,
                                 operationID: UUID(), batchID: batchID)
        return try await ctx.write(entity, old: old)
    }

    /// 反向映射（4.4）
    @MainActor
    static func applyInverse(op: Operation, in ctx: CommandContext) async throws {
        let repo = ctx.repository
        switch op.kind {
        case .createPlan, .createTask, .createStage, .createMetric, .createNote, .logActivity,
             .recordMeasurement, .createRecurrence:
            // create* → 删除新建对象（30 天内可经最近删除找回）
            let retention = ctx.defaults.lifecycle.tombstoneRetentionDays
            let tombstone = Tombstone(entityType: op.entityType, entityId: op.entityId,
                                      deletedAt: ctx.now, deviceId: ctx.deviceId,
                                      retentionDays: retention)
            _ = try await ctx.write(tombstone, old: nil)
        case .completeTask:
            if let task = await repo.task(op.entityId) {
                var t = task
                t.status = .todo
                t.doneAt = nil
                t.updatedAt = ctx.now
                _ = try await ctx.write(t, old: task)
            }
        case .completeOccurrence, .skipOccurrence:
            if let occurrence = await repo.occurrence(op.entityId) {
                var o = occurrence
                o.status = .pending
                o.doneAt = nil
                _ = try await ctx.write(o, old: occurrence)
            }
        case .cancelTask:
            if let task = await repo.task(op.entityId) {
                var t = task
                t.status = .todo
                t.cancelledAt = nil
                t.updatedAt = ctx.now
                _ = try await ctx.write(t, old: task)
            }
        case .reopenTask:
            if let task = await repo.task(op.entityId) {
                var t = task
                t.status = .done
                t.updatedAt = ctx.now
                _ = try await ctx.write(t, old: task)
            }
        case .scheduleTask, .setDeadline, .updateTask, .updatePlan, .updateStage, .updateMetric,
             .reassignTask, .changeRecurrence, .addDependency, .removeDependency,
             .pausePlan, .resumePlan:
            // 恢复 patch.old
            try await restoreOldValues(op: op, in: ctx)
        case .correctActivity, .correctMeasurement:
            // 更正记录 → 标记删除（保留事件链）
            let retention = ctx.defaults.lifecycle.tombstoneRetentionDays
            let tombstone = Tombstone(entityType: op.entityType, entityId: op.entityId,
                                      deletedAt: ctx.now, deviceId: ctx.deviceId,
                                      retentionDays: retention)
            _ = try await ctx.write(tombstone, old: nil)
        case .acceptSuggestion, .dismissSuggestion:
            if let s = await repo.suggestion(op.entityId) {
                var ss = s
                ss.status = .pending
                ss.acceptedTaskId = nil
                _ = try await ctx.write(ss, old: s)
            }
        case .deletePlan, .restoreEntity, .resolveConflict, .undoBatch, .batchOperation,
             .processCapture, .addSuggestion:
            break
        }
    }

    /// schedule/deadline/update → 恢复 patch.old
    @MainActor
    static func restoreOldValues(op: Operation, in ctx: CommandContext) async throws {
        let payload: [String: FieldPatch]
        do {
            payload = try JSONDecoder().decode([String: FieldPatch].self, from: op.payload)
        } catch {
            return
        }
        switch op.entityType {
        case .plan:
            guard let existing = await ctx.repository.plan(op.entityId) else { return }
            var plan = existing
            if let v = payload["name"]?.old.stringValue { plan.name = v }
            if let v = payload["goalText"]?.old.stringValue { plan.goalText = v }
            if let v = payload["cloudAIEnabled"]?.old.boolValue { plan.cloudAIEnabled = v }
            if let v = payload["syncEnabled"]?.old.boolValue { plan.syncEnabled = v }
            if let v = payload["status"]?.old.stringValue, let s = PlanStatus(rawValue: v) { plan.status = s }
            plan.updatedAt = ctx.now
            _ = try await ctx.write(plan, old: existing)
        case .task:
            guard let existing = await ctx.repository.task(op.entityId) else { return }
            var task = existing
            if let patch = payload["scheduledDate"] {
                task.scheduledDate = patch.old.isNull
                    ? nil
                    : DateOnly(iso8601DateString: patch.old.stringValue ?? "", sourceTZ: ctx.timeZone.identifier)
            }
            if let patch = payload["hardDeadline"] {
                task.hardDeadline = patch.old.isNull ? nil : patch.old.objectDate()
            }
            if let v = payload["title"]?.old.stringValue { task.title = v }
            if let v = payload["status"]?.old.stringValue, let s = TaskStatus(rawValue: v) { task.status = s }
            if let v = payload["dependencyIDs"]?.old.arrayUUIDs() { task.dependencyIDs = v }
            task.updatedAt = ctx.now
            _ = try await ctx.write(task, old: existing)
        case .stage:
            guard let existing = await ctx.repository.stage(op.entityId) else { return }
            var stage = existing
            if let v = payload["status"]?.old.stringValue, let s = StageStatus(rawValue: v) { stage.status = s }
            if let v = payload["name"]?.old.stringValue { stage.name = v }
            _ = try await ctx.write(stage, old: existing)
        case .metric:
            guard let existing = await ctx.repository.metric(op.entityId) else { return }
            var metric = existing
            if let v = payload["name"]?.old.stringValue { metric.name = v }
            if let v = payload["unit"]?.old.stringValue { metric.unit = v }
            if let v = payload["targetDirection"]?.old.stringValue,
               let d = MetricDirection(rawValue: v) { metric.targetDirection = d }
            _ = try await ctx.write(metric, old: existing)
        case .rule:
            guard let existing = await ctx.repository.rule(op.entityId) else { return }
            var reverted = existing
            if let v = payload["pattern"]?.old.stringValue, let p = RecurrencePattern(rawValue: v) {
                reverted.pattern = p
            }
            if let v = payload["weekdays"]?.old, case .array(let items) = v {
                reverted.weekdays = items.compactMap(\.intValue)
            }
            if let v = payload["weeklyCount"]?.old.intValue { reverted.weeklyCount = v }
            _ = try await ctx.write(reverted, old: existing)
        default:
            break
        }
    }

    // MARK: - 私有：执行

    private func run(_ commands: [any DomainCommand],
                     batchID: UUID? = nil,
                     captureID: UUID? = nil,
                     source: BatchSource = .userManual,
                     summary: String = "") async throws -> [CommandResult] {
        let bid = batchID ?? UUID()
        let stamp = clock.now()
        let tz = timeZoneProvider.current()
        let today = DateOnly(from: stamp, in: tz)

        var results: [CommandResult] = []
        try await repository.beginTransaction()
        do {
            for command in commands {
                if let cached = idempotencyCache[command.operationID] {
                    results.append(cached)
                    continue
                }
                if let existing = await repository.operation(command.operationID),
                   existing.status == .applied {
                    let replay = CommandResult(operationID: command.operationID,
                                               entityID: existing.entityId,
                                               userMessage: existing.reason ?? "这项更改已经保存过了。",
                                               newRevision: existing.baseRevision)
                    idempotencyCache[command.operationID] = replay
                    results.append(replay)
                    continue
                }
                let ctx = CommandContext(repository: repository, now: stamp, today: today,
                                         timeZone: tz, defaults: defaults, deviceId: deviceId,
                                         operationID: command.operationID, batchID: bid,
                                         declaredBaseRevision: command.baseRevision)
                let result = try await command.execute(in: ctx)

                // 记录操作（幂等键 + 撤销校验）与批元数据
                let payload: Data
                do { payload = try JSONEncoder().encode(ctx.patch) } catch { payload = Data("{}".utf8) }
                let operation = Operation(id: command.operationID, batchId: bid, kind: command.kind,
                                          entityType: command.entityType,
                                          entityId: result.entityID ?? command.entityID,
                                          payload: payload, baseRevision: command.baseRevision,
                                          status: .applied,
                                          reason: ctx.recordedReason ?? result.userMessage,
                                          createdAt: stamp)
                _ = try await ctx.write(operation, old: nil)
                results.append(result)
                idempotencyCache[command.operationID] = result
            }

            // 批量记录
            if commands.count > 1 || captureID != nil {
                let batch = OperationBatch(id: bid, captureId: captureID, source: source,
                                           createdAt: stamp, deviceId: deviceId, state: .applied,
                                           summary: summary.isEmpty
                                            ? "已应用 \(results.count) 项" : summary)
                let existing = await repository.batch(bid)
                _ = try await ctxWrite(batch, old: existing, stamp: stamp, today: today, tz: tz, batchID: bid)
            }

            try await repository.commitTransaction()
        } catch {
            try? await repository.rollbackTransaction()
            throw error
        }

        if !results.isEmpty {
            dataVersion &+= 1
            let kinds = commands.map(\.kind)
            let notification = ChangeNotification(
                batchID: bid, entityIDs: results.compactMap(\.entityID), kinds: kinds,
                summary: results.count == 1 ? (results[0].userMessage)
                                            : (summary.isEmpty ? "已整理 \(results.count) 项 · 可撤销" : summary),
                canUndo: true, at: stamp)
            notifications.append(notification)
            if notifications.count > 50 { notifications.removeFirst(notifications.count - 50) }
            lastNotification = notification
        }
        return results
    }

    // MARK: - 同步状态（P3 由 SyncEngine 注入）

    public func updateSyncState(_ state: SyncState) { syncState = state }
    public func currentSyncState() -> SyncState { syncState }
}

public extension JSONValue {
    func objectDate() -> DateTimeTZ? {
        guard case .object(let dict) = self else { return nil }
        guard let epoch = dict["epoch"]?.doubleValue, let tz = dict["tzID"]?.stringValue else { return nil }
        return DateTimeTZ(epoch: Date(timeIntervalSince1970: epoch), tzID: tz)
    }

    func arrayUUIDs() -> [UUID]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap { UUID(uuidString: $0.stringValue ?? "") }
    }
}
