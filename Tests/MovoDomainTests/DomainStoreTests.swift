//
//  DomainStoreTests.swift
//  MovoDomainTests
//
//  4.1/4.2 写入路径：唯一入口、幂等（operationId）、开始时间与结束时间相互独立、
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

    // MARK: - 开始时间与结束时间独立

    func testStartAndEndAreIndependent() async throws {
        let store = makeStore()
        let tz = store.currentTimeZone
        let scheduled = DateOnly(y: 2026, m: 9, d: 28, sourceTZ: tz.identifier)
        let start = TimePoint.day(scheduled)
        let deadline = DateTimeTZ(Self.fixedNow.addingTimeInterval(86_400), in: tz)
        let end = TimePoint.instant(deadline)

        let created = try await store.execute(CreateTask(title: "体检", startAt: start, endAt: end))
        let id = try XCTUnwrap(created.entityID)
        let initial = await store.repository.task(id)
        let first = try XCTUnwrap(initial)
        XCTAssertEqual(first.startAt, start)
        XCTAssertEqual(first.endAt, end)

        // 只改开始时间：结束时间必须原样保留
        let moved = TimePoint.day(scheduled.adding(days: 3))
        _ = try await store.execute(ScheduleTask(taskID: id, startAt: moved, baseRevision: first.revision))
        let afterSchedule = await store.repository.task(id)
        let second = try XCTUnwrap(afterSchedule)
        XCTAssertEqual(second.startAt, moved)
        XCTAssertEqual(second.endAt, end, "两端互不影响")

        // 只改结束时间：开始时间必须原样保留
        let newEnd = TimePoint.instant(DateTimeTZ(Self.fixedNow.addingTimeInterval(172_800), in: tz))
        _ = try await store.execute(SetDeadline(taskID: id, endAt: newEnd, baseRevision: second.revision))
        let afterDeadline = await store.repository.task(id)
        let third = try XCTUnwrap(afterDeadline)
        XCTAssertEqual(third.startAt, moved)
        XCTAssertEqual(third.endAt, newEnd)
    }

    // MARK: - 起止时间校验

    private func assertRejected(_ command: some DomainCommand, file: StaticString = #filePath,
                                line: UInt = #line, on store: DomainStore) async {
        do {
            _ = try await store.execute(command)
            XCTFail("应被校验拒绝", file: file, line: line)
        } catch is MovoError { }
        catch { XCTFail("错误类型不符：\(error)", file: file, line: line) }
    }

    func testEndBeforeStartIsRejected() async {
        let store = makeStore()
        let tz = store.currentTimeZone.identifier
        let day = DateOnly(y: 2026, m: 10, d: 10, sourceTZ: tz)
        await assertRejected(CreateTask(title: "倒着的时间", startAt: .day(day),
                                        endAt: .day(day.adding(days: -1))), on: store)
        let tasks = await store.repository.allTasks()
        XCTAssertTrue(tasks.isEmpty)
    }

    func testChildTimeMustStayInsidePlanRange() async throws {
        let store = makeStore()
        let tz = store.currentTimeZone.identifier
        let planStart = DateOnly(y: 2026, m: 10, d: 1, sourceTZ: tz)
        let planEnd = DateOnly(y: 2026, m: 10, d: 31, sourceTZ: tz)
        let plan = try await store.execute(CreatePlan(name: "十月", kind: .delivery,
                                                      startAt: .day(planStart), endAt: .day(planEnd)))
        let planID = try XCTUnwrap(plan.entityID)

        await assertRejected(CreateTask(title: "超出范围", planID: planID,
                                        startAt: .day(planEnd.adding(days: 2))), on: store)
        let inside = try await store.execute(CreateTask(title: "范围内", planID: planID,
                                                        startAt: .day(planStart.adding(days: 5)),
                                                        endAt: .day(planStart.adding(days: 6))))
        XCTAssertNotNil(inside.entityID)
    }

    func testPlanWithoutEndDoesNotConstrainChildren() async throws {
        let store = makeStore()
        let tz = store.currentTimeZone.identifier
        let planStart = DateOnly(y: 2026, m: 10, d: 1, sourceTZ: tz)
        let plan = try await store.execute(CreatePlan(name: "只有开始", kind: .delivery,
                                                      startAt: .day(planStart)))
        let planID = try XCTUnwrap(plan.entityID)
        let task = try await store.execute(CreateTask(title: "很晚的事", planID: planID,
                                                      startAt: .day(planStart.adding(days: 400))))
        XCTAssertNotNil(task.entityID)
    }

    func testShrinkingPlanBelowOpenChildIsRejected() async throws {
        let store = makeStore()
        let tz = store.currentTimeZone.identifier
        let planStart = DateOnly(y: 2026, m: 10, d: 1, sourceTZ: tz)
        let planEnd = DateOnly(y: 2026, m: 10, d: 31, sourceTZ: tz)
        let plan = try await store.execute(CreatePlan(name: "十月", kind: .delivery,
                                                      startAt: .day(planStart), endAt: .day(planEnd)))
        let planID = try XCTUnwrap(plan.entityID)
        _ = try await store.execute(CreateTask(title: "月末任务", planID: planID,
                                               endAt: .day(planEnd.adding(days: -1))))
        let stored = await store.repository.plan(planID)
        let current = try XCTUnwrap(stored)

        var patch = PlanPatch()
        patch.endAt = .day(planStart.adding(days: 10))
        await assertRejected(UpdatePlan(planID: planID, patch: patch, baseRevision: current.revision), on: store)
    }

    func testRecurrenceDailyTimesProduceInstantRange() throws {
        let tz = "Asia/Shanghai"
        let rule = RecurrenceRule(taskId: UUID(), pattern: .daily,
                                  effectiveFrom: DateOnly(y: 2026, m: 10, d: 1, sourceTZ: tz),
                                  dailyStart: TimeOfDay(hour: 8, minute: 0),
                                  dailyEnd: TimeOfDay(hour: 8, minute: 30))
        let day = DateOnly(y: 2026, m: 10, d: 2, sourceTZ: tz)
        let start = try XCTUnwrap(rule.occurrenceStart(on: day).instantValue)
        let end = try XCTUnwrap(rule.occurrenceEnd(on: day)?.instantValue)
        XCTAssertEqual(end.epoch.timeIntervalSince(start.epoch), 1_800)
        XCTAssertEqual(rule.occurrenceStart(on: day).clockText, "08:00")

        let allDay = RecurrenceRule(taskId: UUID(), pattern: .daily,
                                    effectiveFrom: DateOnly(y: 2026, m: 10, d: 1, sourceTZ: tz))
        XCTAssertFalse(allDay.occurrenceStart(on: day).isInstant)
        XCTAssertNil(allDay.occurrenceEnd(on: day))
    }

    func testLegacyTaskPayloadMapsToStartAndEnd() throws {
        let legacy = """
        {"id":"00000000-0000-4000-8000-0000000000A1","title":"旧任务","isTemplate":false,
         "status":"todo","tags":[],"dependencyIDs":[],"source":"manual","suggestedFields":[],
         "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","revision":1,
         "scheduledDate":{"y":2026,"m":9,"d":28,"sourceTZ":"Asia/Shanghai"},
         "timeHint":{"exact":{"hour":9,"minute":30}},
         "hardDeadline":{"epoch":"2026-09-29T07:00:00Z","tzID":"Asia/Shanghai"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(Task.self, from: Data(legacy.utf8))
        XCTAssertEqual(task.startAt?.clockText, "09:30")
        XCTAssertEqual(task.startAt?.dateOnly.iso8601DateString, "2026-09-28")
        XCTAssertEqual(task.endAt?.instantValue?.tzID, "Asia/Shanghai")

        let vague = legacy.replacingOccurrences(of: "{\"exact\":{\"hour\":9,\"minute\":30}}",
                                                with: "{\"morning\":{}}")
        let migrated = try decoder.decode(Task.self, from: Data(vague.utf8))
        XCTAssertEqual(migrated.startAt?.isInstant, false, "模糊时段不虚构时刻")
    }

    func testLegacyPlanTargetDateBecomesEnd() throws {
        let legacy = """
        {"id":"00000000-0000-4000-8000-0000000000B1","name":"旧计划","kind":"delivery",
         "aliases":[],"contextPhrases":[],"excludedTerms":[],"cloudAIEnabled":true,"syncEnabled":true,
         "status":"active","sortIndex":0,
         "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","revision":1,
         "targetDate":{"y":2026,"m":10,"d":9,"sourceTZ":"Asia/Shanghai"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plan = try decoder.decode(Plan.self, from: Data(legacy.utf8))
        XCTAssertNil(plan.startAt)
        XCTAssertEqual(plan.endAt?.dateOnly.iso8601DateString, "2026-10-09")
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
