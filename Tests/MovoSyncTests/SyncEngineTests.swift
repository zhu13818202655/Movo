//
//  SyncEngineTests.swift
//  MovoSyncTests
//
//  T3.2 / T3.4 / T3.5：用 InMemorySyncBackend 模拟"另一台设备"，跑真实的
//  入站→合并→出站循环（不触碰网络）。
//
//  注意：`await` 不能出现在 XCTest 断言的 autoclosure 里，故所有异步取值先落成局部变量。
//

import XCTest
import MovoKit

final class SyncEngineTests: XCTestCase {

    /// 固定"现在"：让时间可预测（12.1 时间旅行）
    private static let nowValue = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEngine(_ repo: InMemoryRepository, _ backend: InMemorySyncBackend,
                            device: String = "mac") -> SyncEngine {
        SyncEngine(repository: repo, backend: backend, defaults: .fallback,
                   deviceId: device, now: { SyncEngineTests.nowValue })
    }

    private func localTask(_ id: UUID, title: String, notes: String? = nil,
                           rev: Int = 1) -> Task {
        Task(id: id, title: title, notes: notes,
             createdAt: SyncEngineTests.nowValue, updatedAt: SyncEngineTests.nowValue,
             revision: rev)
    }

    private func remoteRecord(_ task: Task, rev: Int, device: String,
                              fieldRev: [String: Int]) throws -> EntityRecord {
        try XCTUnwrap(SyncEntityBox.task(task).record(rev: rev, deviceId: device,
                                                     fieldRev: fieldRev,
                                                     planID: task.planId))
    }

    // MARK: - 幂等（9.4 第 4 步）

    func testPushIsIdempotentAcrossRuns() async throws {
        let repo = InMemoryRepository()
        let backend = InMemorySyncBackend()
        try await repo.upsert(localTask(UUID(), title: "写周报"))

        let engine = makeEngine(repo, backend)
        let first = await engine.start()
        let remoteAfterFirst = await backend.remoteEntityCount()
        XCTAssertEqual(first.pushedEntities, 1)
        XCTAssertEqual(remoteAfterFirst, 1)

        let second = await engine.syncNow()
        let remoteAfterSecond = await backend.remoteEntityCount()
        let openConflicts = await repo.conflicts(resolved: false).count
        XCTAssertEqual(second.pushedEntities, 0, "没有新变更就不应重复推送")
        XCTAssertEqual(second.appliedEntities, 0, "远端没有新内容就不应回写本机")
        XCTAssertEqual(remoteAfterSecond, 1)
        XCTAssertEqual(openConflicts, 0)
    }

    // MARK: - 离线仍可本机写入（9.1）

    func testOfflineKeepsLocalWritesAndDegradesToFailed() async throws {
        let repo = InMemoryRepository()
        let backend = InMemorySyncBackend()
        await backend.setOffline(true)

        let engine = makeEngine(repo, backend)
        _ = await engine.start()

        let state = await engine.state()
        guard case .failed = state else {
            return XCTFail("离线应进入 failed 状态而不是崩溃或静默，实际：\(state)")
        }

        // 离线时本机写入照常成功，且没有任何内容被推上去
        try await repo.upsert(localTask(UUID(), title: "离线新增"))
        let taskCount = await repo.allTasks().count
        let remoteCount = await backend.remoteEntityCount()
        XCTAssertEqual(taskCount, 1)
        XCTAssertEqual(remoteCount, 0)
    }

    // MARK: - 账号状态（9.6）

    func testNotSignedInDoesNothing() async throws {
        let repo = InMemoryRepository()
        let backend = InMemorySyncBackend(accountState: .notSignedIn)
        try await repo.upsert(localTask(UUID(), title: "本地任务"))

        let engine = makeEngine(repo, backend)
        let report = await engine.start()
        let remoteCount = await backend.remoteEntityCount()
        let state = await engine.state()

        XCTAssertEqual(report.pushedEntities, 0)
        XCTAssertEqual(remoteCount, 0)
        XCTAssertEqual(state, .notSignedIn)
    }

    // MARK: - 同字段并发修改 → 双候选（P3 完成条件）

    func testSameFieldConflictKeepsBothVersions() async throws {
        let repo = InMemoryRepository()
        let backend = InMemorySyncBackend()
        let id = UUID()

        // 本机把 title 改成"本机标题"（带未同步事件 → 出站 fieldRev["title"]=2）
        try await repo.upsert(localTask(id, title: "本机标题", rev: 2))
        try await repo.append(ChangeEvent(
            operationId: UUID(), batchId: UUID(), entityId: id, entityType: .task,
            fields: ["title"],
            patch: ["title": FieldPatch(old: .string("原题"), new: .string("本机标题"))],
            baseRevision: 1, newRevision: 2,
            occurredAt: Self.nowValue, recordedAt: Self.nowValue, deviceId: "mac"))

        // 对端把同一字段改成了另一个值
        let remote = try remoteRecord(localTask(id, title: "远端标题", rev: 2),
                                      rev: 2, device: "iphone", fieldRev: ["title": 2])
        await backend.simulateRemoteUpsert(remote)

        let engine = makeEngine(repo, backend)
        let report = await engine.start()
        let conflicts = await repo.conflicts(resolved: false)

        XCTAssertEqual(report.detectedConflicts, 1)
        XCTAssertEqual(conflicts.count, 1)
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflict.field, "title")
        // 冲突解决前不丢失任一版本
        XCTAssertEqual(conflict.localValue, .string("本机标题"))
        XCTAssertEqual(conflict.remoteValue, .string("远端标题"))
        XCTAssertTrue(conflict.bothVersionsPresent)
        XCTAssertEqual(conflict.localDeviceId, "mac")
        XCTAssertEqual(conflict.remoteDeviceId, "iphone")
    }

    // MARK: - 不同字段并行修改 → 自动合并（PRD REQ 20）

    func testDifferentFieldEditsAutoMergeAndConverge() async throws {
        let repo = InMemoryRepository()
        let backend = InMemorySyncBackend()
        let id = UUID()

        // 本机改了 notes
        try await repo.upsert(localTask(id, title: "原题", notes: "本机备注", rev: 2))
        try await repo.append(ChangeEvent(
            operationId: UUID(), batchId: UUID(), entityId: id, entityType: .task,
            fields: ["notes"],
            patch: ["notes": FieldPatch(old: .string("原备注"), new: .string("本机备注"))],
            baseRevision: 1, newRevision: 2,
            occurredAt: Self.nowValue, recordedAt: Self.nowValue, deviceId: "mac"))

        // 对端改了 title
        let remoteTask = localTask(id, title: "远端标题", notes: "原备注", rev: 2)
        let uploaded = try remoteRecord(remoteTask, rev: 2, device: "iphone",
                                        fieldRev: ["title": 2])
        await backend.simulateRemoteUpsert(uploaded)

        let engine = makeEngine(repo, backend)
        let report = await engine.start()

        XCTAssertEqual(report.detectedConflicts, 0, "不同字段并行修改不应产生冲突")

        let localAfterMerge = await repo.task(id)
        let merged = try XCTUnwrap(localAfterMerge)
        XCTAssertEqual(merged.title, "远端标题")
        XCTAssertEqual(merged.notes, "本机备注")

        // 合并结果必须出站，两端才收敛
        let remoteAfter = await backend.remoteEntity(id)
        let converged = try XCTUnwrap(remoteAfter)
        XCTAssertEqual(converged.stateFields["title"], .string("远端标题"))
        XCTAssertEqual(converged.stateFields["notes"], .string("本机备注"))
    }

    // MARK: - 计划级开关（9.6 / P3 完成条件）

    func testSyncDisabledPlanIsNeitherPushedNorPulled() async throws {
        let repo = InMemoryRepository()
        let backend = InMemorySyncBackend()
        let healthPlanID = UUID()
        let workPlanID = UUID()

        try await repo.upsert(Plan(id: healthPlanID, name: "健康", kind: .improvement,
                                  category: .health, syncEnabled: false))
        try await repo.upsert(Task(planId: healthPlanID, title: "散步",
                                   createdAt: Self.nowValue, updatedAt: Self.nowValue))
        // 对照组：开启同步的计划
        try await repo.upsert(Plan(id: workPlanID, name: "季度汇报", kind: .delivery,
                                  category: .work, syncEnabled: true))
        try await repo.upsert(Task(planId: workPlanID, title: "整理数据",
                                   createdAt: Self.nowValue, updatedAt: Self.nowValue))

        let engine = makeEngine(repo, backend)
        let report = await engine.start()
        let healthMirror = await backend.remoteEntity(healthPlanID)
        let workMirror = await backend.remoteEntity(workPlanID)

        // 关闭同步的计划及其任务都不出站；开启的照常
        XCTAssertEqual(report.pushedEntities, 2)
        XCTAssertNil(healthMirror)
        XCTAssertNotNil(workMirror)
    }

    // MARK: - 删除传播与复活防护（AC11）

    func testRemoteDeletionWinsAndIsNotResurrected() async throws {
        let repo = InMemoryRepository()
        let backend = InMemorySyncBackend()
        let id = UUID()
        try await repo.upsert(localTask(id, title: "要删的任务"))

        let engine = makeEngine(repo, backend)
        _ = await engine.start()
        let afterFirstSync = await repo.task(id)
        XCTAssertNotNil(afterFirstSync)

        // 对端删除
        let deletedAt = Self.nowValue.addingTimeInterval(60)
        await backend.simulateRemoteDelete(id, entityType: .task, at: deletedAt, deviceId: "iphone")

        // 旧设备在删除之后又改了一次（必须被丢弃，不能复活对象）
        var stale = try XCTUnwrap(afterFirstSync)
        stale.title = "旧设备的编辑"
        stale.revision = 5
        stale.updatedAt = deletedAt.addingTimeInterval(3600)
        try await repo.upsert(stale)

        let report = await engine.syncNow()
        let afterSync = await repo.task(id)
        let tombstones = await repo.tombstones(activeOnly: true)

        XCTAssertNil(afterSync, "已删对象不能被旧设备的编辑复活")
        XCTAssertGreaterThanOrEqual(report.discardedRevivals, 1)
        // 本地写入墓碑，防止对端把对象推回来
        XCTAssertTrue(tombstones.contains { $0.entityId == id })
    }

    // MARK: - 永久删除传播（AC17）

    func testHardDeletionPropagatesToOtherDevice() async throws {
        let repo = InMemoryRepository()
        let backend = InMemorySyncBackend()
        let id = UUID()
        try await repo.upsert(localTask(id, title: "已过期对象"))

        let engine = makeEngine(repo, backend)
        _ = await engine.start()
        let mirrored = await backend.remoteEntity(id)
        XCTAssertNotNil(mirrored)

        // 对端完成永久删除（30 天到期后的级联清理）
        try await backend.purge(entityIDs: [id])
        let afterPurge = await backend.remoteEntity(id)
        XCTAssertNil(afterPurge)

        _ = await engine.syncNow()
        let localAfter = await repo.task(id)
        XCTAssertNil(localAfter, "对端永久删除后本机应跟随清理")
    }
}
