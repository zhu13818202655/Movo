//
//  SwiftDataRepositoryTests.swift
//  MovoDataTests
//
//  12.1 Data DT：SwiftData 5.2 事务与写入路径。
//  覆盖：值类型 round-trip（含 AC02 安排/截止独立）、事务提交可见、回滚无半更新、
//  事件追加幂等与置位、搜索索引、级联永久删除、物理清空、实体名映射。
//

import XCTest
import MovoKit

@MainActor
final class SwiftDataRepositoryTests: XCTestCase {

    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRepo() throws -> SwiftDataRepository {
        try SwiftDataRepository.inMemory()
    }

    private func makeEvent(entityId: UUID, entityType: EntityType = .task,
                           field: String = "title", old: String = "a",
                           new: String = "b") -> ChangeEvent {
        ChangeEvent(operationId: UUID(), batchId: UUID(), entityId: entityId,
                    entityType: entityType, fields: [field],
                    patch: [field: FieldPatch(old: .string(old), new: .string(new))],
                    baseRevision: 1, newRevision: 2,
                    occurredAt: base, recordedAt: base, deviceId: "mac-test")
    }

    // MARK: - 5.2 事务：提交后可见

    func testCommitPersistsPlan() async throws {
        let repo = try makeRepo()
        try await repo.beginTransaction()
        let plan = Plan(name: "减脂计划", kind: .improvement, category: .health,
                        goalText: "三个月减 5 公斤", aliases: ["减脂"])
        try await repo.upsert(plan)
        try await repo.commitTransaction()

        let loaded = await repo.plan(plan.id)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.name, "减脂计划")
        XCTAssertEqual(stored.kind, .improvement)
        XCTAssertEqual(stored.category, .health)
        XCTAssertEqual(stored.goalText, "三个月减 5 公斤")
        XCTAssertEqual(stored.aliases, ["减脂"])
        // 健康分类默认关闭云 AI（PRD 11.2）
        XCTAssertFalse(stored.cloudAIEnabled)
    }

    // MARK: - 5.2 事务：回滚无半更新

    func testRollbackDiscardsUncommittedWrites() async throws {
        let repo = try makeRepo()
        try await repo.beginTransaction()
        try await repo.upsert(Plan(name: "临时计划", kind: .delivery))

        let during = await repo.allPlans()
        XCTAssertEqual(during.count, 1, "事务内立即可读")

        try await repo.rollbackTransaction()
        let after = await repo.allPlans()
        XCTAssertTrue(after.isEmpty, "回滚后不应残留半更新")
    }

    // MARK: - Task round-trip（AC02：安排日期与硬截止独立）

    func testTaskRoundTripPreservesScheduleAndDeadline() async throws {
        let repo = try makeRepo()
        let scheduled = DateOnly(y: 2026, m: 9, d: 28, sourceTZ: tz.identifier)
        let deadline = DateTimeTZ(base, in: tz)
        let task = Task(title: "体检", notes: "空腹前往", scheduledDate: scheduled,
                        hardDeadline: deadline, estimateMinutes: 60,
                        priority: .high, tags: ["健康", "体检"])

        try await repo.upsert(task)
        try await repo.commitTransaction()

        let loaded = await repo.task(task.id)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.title, "体检")
        XCTAssertEqual(stored.notes, "空腹前往")
        XCTAssertEqual(stored.scheduledDate, scheduled)
        XCTAssertEqual(stored.hardDeadline?.epoch, deadline.epoch)
        XCTAssertEqual(stored.hardDeadline?.tzID, tz.identifier)
        XCTAssertEqual(stored.estimateMinutes, 60)
        XCTAssertEqual(stored.priority, .high)
        XCTAssertEqual(stored.tags, ["健康", "体检"])
        // 安排日期与硬截止可分辨（AC02）
        XCTAssertNotNil(stored.scheduleVsDeadlineSummary)
    }

    // MARK: - 条件查询

    func testScheduledOnAndChildrenAndTemplates() async throws {
        let repo = try makeRepo()
        let day = DateOnly(y: 2026, m: 9, d: 28, sourceTZ: tz.identifier)
        let parent = Task(title: "准备答辩", scheduledDate: day)
        let child = Task(parentId: parent.id, title: "打印讲稿")
        let template = Task(title: "晨跑", isTemplate: true)
        let otherDay = Task(title: "下周的事", scheduledDate: day.adding(days: 7, in: tz))

        for t in [parent, child, template, otherDay] { try await repo.upsert(t) }
        try await repo.commitTransaction()

        let onDay = await repo.tasks(scheduledOn: day)
        let onDayIDs = Set(onDay.map(\.id))
        XCTAssertEqual(onDayIDs, [parent.id])

        let children = await repo.children(of: parent.id)
        XCTAssertEqual(children.map(\.id), [child.id])

        let templates = await repo.templateTasks()
        XCTAssertEqual(templates.map(\.id), [template.id])
    }

    // MARK: - 事件：幂等追加 + 置位

    func testAppendEventIsIdempotent() async throws {
        let repo = try makeRepo()
        let event = makeEvent(entityId: UUID())

        try await repo.append(event)
        try await repo.append(event) // 同 id 去重
        try await repo.commitTransaction()

        let count = await repo.eventCount()
        XCTAssertEqual(count, 1)
    }

    func testMarkEventsSyncedFlipsFlag() async throws {
        let repo = try makeRepo()
        let event = makeEvent(entityId: UUID())
        try await repo.append(event)
        try await repo.commitTransaction()

        let before = await repo.events(unsyncedOnly: true)
        XCTAssertEqual(before.count, 1, "新事件默认未同步")

        try await repo.markEventsSynced(ids: [event.id])
        try await repo.commitTransaction()

        let after = await repo.events(unsyncedOnly: true)
        XCTAssertTrue(after.isEmpty)

        let all = await repo.events(entityID: event.entityId)
        XCTAssertEqual(all.first?.synced, true)
    }

    // MARK: - 搜索索引

    func testSearchDocumentRoundTripAndRemoval() async throws {
        let repo = try makeRepo()
        let entityId = UUID()
        let doc = SearchDocument(id: entityId, entityType: .task, entityId: entityId,
                                 title: "周报", body: "本周进展", tokens: ["周报", "进展"],
                                 updatedAt: base)
        try await repo.upsertSearchDocument(doc)
        try await repo.commitTransaction()

        var docs = await repo.searchDocuments()
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs.first?.title, "周报")
        XCTAssertEqual(docs.first?.tokens, ["周报", "进展"])

        try await repo.removeSearchDocuments(entityID: entityId)
        try await repo.commitTransaction()

        docs = await repo.searchDocuments()
        XCTAssertTrue(docs.isEmpty)
    }

    // MARK: - 级联永久删除（T1.9 / T3.4）

    func testPurgeExpiredTombstoneCascades() async throws {
        let repo = try makeRepo()
        let task = Task(title: "过期任务")
        try await repo.upsert(task)
        try await repo.append(makeEvent(entityId: task.id))
        let tombstone = Tombstone(entityType: .task, entityId: task.id, deletedAt: base,
                                  deviceId: "mac-test", retentionDays: 30)
        try await repo.upsert(tombstone)
        try await repo.commitTransaction()

        // 未到期：不清理
        try await repo.purgeExpiredTombstones(now: base)
        let stillThere = await repo.task(task.id)
        XCTAssertNotNil(stillThere, "保留期内不应清理")

        // 到期：级联清理实体 + 事件 + 墓碑
        try await repo.purgeExpiredTombstones(now: base.addingTimeInterval(31 * 86_400))
        let gone = await repo.task(task.id)
        XCTAssertNil(gone)
        let events = await repo.events(entityID: task.id)
        XCTAssertTrue(events.isEmpty)
        let all = await repo.tombstones(activeOnly: false)
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - 物理清空 / 实体名

    func testPurgeAllClearsEverything() async throws {
        let repo = try makeRepo()
        try await repo.upsert(Plan(name: "计划 A", kind: .delivery))
        try await repo.upsert(Task(title: "记一条"))
        try await repo.commitTransaction()

        try await repo.purgeAll()

        let plans = await repo.allPlans()
        let tasks = await repo.allTasks()
        XCTAssertTrue(plans.isEmpty)
        XCTAssertTrue(tasks.isEmpty)
    }

    func testEntityNameLookup() async throws {
        let repo = try makeRepo()
        let task = Task(title: "买牛奶")
        try await repo.upsert(task)
        try await repo.commitTransaction()

        let name = await repo.entityName(type: .task, id: task.id)
        XCTAssertEqual(name, "买牛奶")

        let missing = await repo.entityName(type: .task, id: UUID())
        XCTAssertNil(missing)
    }

    // MARK: - 存储占用估算

    func testStoreSizeGrowsWithEvents() async throws {
        let repo = try makeRepo()
        let before = repo.storeSizeBytes()
        try await repo.append(makeEvent(entityId: UUID()))
        try await repo.commitTransaction()
        XCTAssertGreaterThan(repo.storeSizeBytes(), before)
    }
}
