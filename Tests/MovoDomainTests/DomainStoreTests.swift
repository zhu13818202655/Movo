//
//  DomainStoreTests.swift
//  MovoDomainTests
//
//  4.1/4.2 写入路径：唯一入口、幂等（operationId）、安排日期与硬截止相互独立（AC02）、
//  补偿式撤销遇到后续编辑必须跳过（AC10）。
//

import XCTest
import MovoKit

@MainActor
final class DomainStoreTests: XCTestCase {

    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() -> DomainStore {
        DomainStore(repository: InMemoryRepository(),
                    clock: TravelClock(Self.fixedNow),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: "Asia/Shanghai"),
                    deviceIDProvider: FixedDeviceIDProvider("mac-test"),
                    defaults: .fallback)
    }

    // MARK: - AC02：安排日期与硬截止独立

    func testScheduledDateAndDeadlineAreIndependent() async throws {
        let store = makeStore()
        let tz = store.currentTimeZone
        let scheduled = DateOnly(y: 2026, m: 9, d: 28, sourceTZ: tz.identifier)
        let deadline = DateTimeTZ(Self.fixedNow.addingTimeInterval(86_400), in: tz)

        let created = try await store.execute(CreateTask(title: "体检",
                                                        scheduledDate: scheduled,
                                                        deadline: deadline))
        let id = try XCTUnwrap(created.entityID)
        let initial = await store.repository.task(id)
        let first = try XCTUnwrap(initial)
        XCTAssertEqual(first.scheduledDate, scheduled)
        XCTAssertEqual(first.hardDeadline?.epoch, deadline.epoch)

        // 只改安排日期：硬截止必须原样保留
        _ = try await store.execute(ScheduleTask(taskID: id, date: scheduled.adding(days: 3),
                                                 baseRevision: first.revision))
        let afterSchedule = await store.repository.task(id)
        let second = try XCTUnwrap(afterSchedule)
        XCTAssertEqual(second.scheduledDate, scheduled.adding(days: 3))
        XCTAssertEqual(second.hardDeadline?.epoch, deadline.epoch, "AC02：两者互不影响")

        // 只改硬截止：安排日期必须原样保留
        let newDeadline = DateTimeTZ(Self.fixedNow.addingTimeInterval(172_800), in: tz)
        _ = try await store.execute(SetDeadline(taskID: id, deadline: newDeadline,
                                                baseRevision: second.revision))
        let afterDeadline = await store.repository.task(id)
        let third = try XCTUnwrap(afterDeadline)
        XCTAssertEqual(third.scheduledDate, scheduled.adding(days: 3))
        XCTAssertEqual(third.hardDeadline?.epoch, newDeadline.epoch)
    }

    // MARK: - 幂等（同一 operationID 只生效一次）

    func testSameOperationIDIsIdempotent() async throws {
        let store = makeStore()
        let operationID = UUID()

        let first = try await store.execute(CreateTask(operationID: operationID, title: "买菜"))
        let second = try await store.execute(CreateTask(operationID: operationID, title: "买菜"))

        let tasks = await store.repository.allTasks()
        XCTAssertEqual(tasks.count, 1, "重复提交同一 operationID 不应产生第二条")
        XCTAssertEqual(first.entityID, second.entityID)
        XCTAssertEqual(tasks.first?.title, "买菜")
    }

    // MARK: - AC10：撤销不覆盖后续编辑

    func testUndoSkipsOperationsWithLaterEdits() async throws {
        let store = makeStore()
        let created = try await store.execute(CreateTask(title: "周报"))
        let id = try XCTUnwrap(created.entityID)

        // 批次 A：改标题 + 顺带新增一项（两条命令 → 生成批次元数据，可整批撤销）
        let batchA = UUID()
        _ = try await store.executeBatch(BatchInput(
            batchID: batchA,
            commands: [
                UpdateTask(taskID: id, patch: TaskPatch(title: "周报 v2"), baseRevision: 1),
                CreateTask(title: "顺带加一项")
            ],
            summary: "改标题并新增"))

        // 批次 A 之后又产生了一次编辑
        let mid = await store.repository.task(id)
        let afterBatch = try XCTUnwrap(mid)
        _ = try await store.execute(UpdateTask(taskID: id,
                                               patch: TaskPatch(title: "周报 v3"),
                                               baseRevision: afterBatch.revision))

        let result = try await store.undo(batchID: batchA)
        let final = await store.repository.task(id)
        let task = try XCTUnwrap(final)

        XCTAssertEqual(result.unsafeOperations.count, 1, "有后续编辑的操作必须跳过并说明")
        XCTAssertEqual(task.title, "周报 v3", "AC10：撤销不能覆盖后续编辑")
    }

    // MARK: - 完成 / 重开

    func testCompleteThenReopenKeepsSameIdentity() async throws {
        let store = makeStore()
        let created = try await store.execute(CreateTask(title: "整理数据"))
        let id = try XCTUnwrap(created.entityID)

        _ = try await store.execute(CompleteTask(taskID: id, at: .precise(store.now)))
        let doneTask = await store.repository.task(id)
        let completed = try XCTUnwrap(doneTask)
        XCTAssertEqual(completed.status, .done)
        XCTAssertNotNil(completed.doneAt)
        // 同一 taskId 在三处一致（AC06）：仓储里只有这一条
        let allTasks = await store.repository.allTasks()
        XCTAssertEqual(allTasks.count, 1)

        _ = try await store.execute(ReopenTask(taskID: id, baseRevision: completed.revision))
        let reopenedTask = await store.repository.task(id)
        let reopened = try XCTUnwrap(reopenedTask)
        XCTAssertEqual(reopened.status, .todo)
        XCTAssertNil(reopened.doneAt)
        XCTAssertEqual(reopened.id, id)
    }

    // MARK: - 事件链（3.4）

    func testEachWriteAppendsChangeEventAndBumpsDataVersion() async throws {
        let store = makeStore()
        let before = store.dataVersion
        let created = try await store.execute(CreateTask(title: "记一条"))
        let id = try XCTUnwrap(created.entityID)

        XCTAssertGreaterThan(store.dataVersion, before)
        let events = await store.repository.events(entityID: id)
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events[0].synced, "新事件默认未同步，等待 P3 推送")
        XCTAssertEqual(events[0].entityType, .task)
    }
}
