import Foundation
import XCTest
import MovoKit

/// 专注计时对应的验收条目：AC06 / AC08 / AC18 / AC23 / AC24。
///
/// 这几条原本就有覆盖（`StandaloneActivityTests`、`StandaloneRecordTests`、`PlanFileTests`、
/// `PrivacyTests`），这里补的是**计时这条写入路径**上的对应验证，不新增验收编号。
///
/// 计时器本身在 App target 里、没有测试宿主，所以这里按 `AppEnvironment.finishFocus` 实际发出的
/// **领域命令序列**逐步走一遍：先写一条 `LogActivity`，再（可选）写一条 `CompleteTask`，
/// 两者分开提交。要钉住的正是「分开」这件事——记录投入不等于任务完成，
/// 以及记录一旦写下，后续的完成、重开、取消、导出都不会把它弄丢。
@MainActor
final class FocusAcceptanceTests: XCTestCase {

    private let zone = TimeZone(identifier: "Asia/Shanghai")!

    private func makeStore(_ device: String = "focus-acceptance") -> (DomainStore, TravelClock) {
        let clock = TravelClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = DomainStore(repository: InMemoryRepository(),
                                clock: clock,
                                timeZoneProvider: FixedTimeZoneProvider(identifier: zone.identifier),
                                deviceIDProvider: FixedDeviceIDProvider(device),
                                defaults: .fallback)
        return (store, clock)
    }

    @discardableResult
    private func plan(_ name: String, store: DomainStore) async throws -> UUID {
        let result = try await store.execute(CreatePlan(name: name, kind: .improvement))
        return try XCTUnwrap(result.entityID)
    }

    @discardableResult
    private func task(_ title: String, planID: UUID? = nil, store: DomainStore) async throws -> UUID {
        let result = try await store.execute(CreateTask(title: title, planID: planID))
        return try XCTUnwrap(result.entityID)
    }

    /// 开一次倒计时会话，`minutes` 分钟后按结束时的规则算出该记多少分钟。
    private func session(taskID: UUID, title: String, estimate: Int,
                         startedAt: Date) -> FocusPolicy.Session {
        let plan = FocusPolicy.plan(startAt: nil, endAt: nil, estimateMinutes: estimate,
                                    now: startedAt, timeZone: zone)
        return FocusPolicy.start(plan, taskID: taskID, taskTitle: title, at: startedAt)
    }

    /// `AppEnvironment.finishFocus` 写的第一条命令。
    @discardableResult
    private func logFocus(_ session: FocusPolicy.Session, at end: Date,
                          note: String? = nil, taskID: UUID?,
                          store: DomainStore) async throws -> Int {
        let minutes = FocusPolicy.recordedMinutes(session, at: end,
                                                  truncateAtAnchor: true, graceMinutes: 5)
        _ = try await store.execute(LogActivity(taskID: taskID,
                                                happenedAt: .precise(session.startedAt),
                                                durationMinutes: minutes,
                                                text: note, source: .manual))
        return minutes
    }

    /// 第二条命令，只有用户选了「保存并标记完成」才发。
    private func complete(_ taskID: UUID, store: DomainStore) async throws {
        let task = await store.repository.task(taskID)
        guard let task, task.status.isOpen else { return }
        _ = try await store.execute(CompleteTask(taskID: taskID, at: .precise(store.now),
                                                 baseRevision: task.revision))
    }

    // MARK: - AC06：同一任务连续多日工作，行动记录累积且不重复

    func testRepeatedFocusSessionsAccumulateWithoutDuplicating() async throws {
        let (store, clock) = makeStore()
        let taskID = try await task("准备季度汇报", store: store)

        // 连续三天，每天一次 30 分钟专注。
        for _ in 0..<3 {
            let started = store.now
            let focus = session(taskID: taskID, title: "准备季度汇报", estimate: 30, startedAt: started)
            let minutes = try await logFocus(focus, at: started.addingTimeInterval(1800),
                                             taskID: taskID, store: store)
            XCTAssertEqual(minutes, 30, "到点即结束，记满计划时长")
            clock.advance(days: 1, in: zone)
        }

        let records = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(records.count, 3, "三次投入是三条记录，不是互相覆盖的一条")
        XCTAssertEqual(records.compactMap(\.durationMinutes).reduce(0, +), 90)

        let task = await store.repository.task(taskID)
        XCTAssertEqual(task?.id, taskID, "任务 ID 不变，记录挂在同一项上")
    }

    // MARK: - AC08：取消、重开之后历史投入仍可查看

    func testFocusRecordSurvivesCompleteAndReopen() async throws {
        let (store, _) = makeStore()
        let taskID = try await task("准备季度汇报", store: store)
        let focus = session(taskID: taskID, title: "准备季度汇报", estimate: 30, startedAt: store.now)
        try await logFocus(focus, at: store.now.addingTimeInterval(1800),
                           note: "开场先讲结论", taskID: taskID, store: store)
        try await complete(taskID, store: store)

        // 重开
        let done = await store.repository.task(taskID)
        let doneRevision = try XCTUnwrap(done).revision
        _ = try await store.execute(ReopenTask(taskID: taskID, baseRevision: doneRevision))

        let records = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(records.count, 1, "重开不会动已经写下的投入")
        XCTAssertEqual(records.first?.durationMinutes, 30)
        XCTAssertEqual(records.first?.text, "开场先讲结论")
        let reopened = await store.repository.task(taskID)
        XCTAssertEqual(reopened?.status, .todo)
    }

    func testFocusRecordSurvivesCancellation() async throws {
        let (store, _) = makeStore()
        let planID = try await plan("季度工作汇报", store: store)
        let taskID = try await task("撰写汇报初稿", planID: planID, store: store)
        let focus = session(taskID: taskID, title: "撰写汇报初稿", estimate: 45, startedAt: store.now)
        try await logFocus(focus, at: store.now.addingTimeInterval(2700), taskID: taskID, store: store)

        let open = await store.repository.task(taskID)
        let openRevision = try XCTUnwrap(open).revision
        _ = try await store.execute(CancelTask(taskID: taskID, baseRevision: openRevision))

        let records = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(records.count, 1, "取消一项任务不会抹掉已经发生的投入")
        XCTAssertEqual(records.first?.planId, planID, "归属不变")
        let cancelled = await store.repository.task(taskID)
        XCTAssertEqual(cancelled?.status, .cancelled)
    }

    // MARK: - AC23：无需计划即可独立使用

    func testPlanLessTaskCanBeFocusedAndFinished() async throws {
        let (store, _) = makeStore()
        let taskID = try await task("整理书架", store: store)
        let focus = session(taskID: taskID, title: "整理书架", estimate: 25, startedAt: store.now)

        let minutes = try await logFocus(focus, at: store.now.addingTimeInterval(1500),
                                         note: "顺手整理了一层", taskID: taskID, store: store)
        XCTAssertEqual(minutes, 25)

        let records = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.planId, "任务没有计划，投入记录也没有计划")

        // 这类记录沿用回顾里已有的「未分类」，不另开一类。
        let review = await store.reviewView(weekStart: store.today.startOfWeek())
        let unclassified = review.categoryDistribution.first { $0.category == nil }
        XCTAssertEqual(unclassified?.count, 1)
    }

    // MARK: - 异常分支：任务被删除 / 已经被标记完成

    /// 计时中任务被移入最近删除：结束仍然写得下去，并且**按结束时的实际状态**写——
    /// 此时任务行还在（`DeleteTask` 写的是 Tombstone，不是立刻抹掉），
    /// 所以这条记录仍然带着任务归属，不会变成一条凭空冒出来的无主记录。
    func testSoftDeletingTheTaskDoesNotBreakTheWrite() async throws {
        let (store, _) = makeStore()
        let taskID = try await task("准备季度汇报", store: store)
        let focus = session(taskID: taskID, title: "准备季度汇报", estimate: 30, startedAt: store.now)

        let open = await store.repository.task(taskID)
        let openRevision = try XCTUnwrap(open).revision
        _ = try await store.execute(DeleteTask(taskID: taskID, baseRevision: openRevision))

        try await logFocus(focus, at: store.now.addingTimeInterval(1800),
                           note: "删了也还是做了这半小时", taskID: taskID, store: store)

        let records = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(records.count, 1, "回收期内仍然写得到这次投入")
        XCTAssertEqual(records.first?.taskId, taskID, "归属按结束时的实际状态保留")
        XCTAssertEqual(records.first?.durationMinutes, 30)
    }

    /// 任务已经被标记完成：结束计时只写记录，不重复写完成。
    func testAlreadyCompletedTaskIsNotCompletedAgain() async throws {
        let (store, _) = makeStore()
        let taskID = try await task("准备季度汇报", store: store)
        try await complete(taskID, store: store)
        let firstDone = await store.repository.task(taskID)

        let focus = session(taskID: taskID, title: "准备季度汇报", estimate: 30, startedAt: store.now)
        try await logFocus(focus, at: store.now.addingTimeInterval(1800), taskID: taskID, store: store)
        try await complete(taskID, store: store)

        let finalTask = await store.repository.task(taskID)
        let after = try XCTUnwrap(finalTask)
        let records = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(after.status, .done)
        XCTAssertEqual(after.doneAt, firstDone?.doneAt, "完成时刻没有被第二次写覆盖")
        XCTAssertEqual(after.revision, firstDone?.revision, "没有产生第二次写入")
        XCTAssertEqual(records.count, 1)
    }

    /// 任务已经不在库里时，`finishFocus` 把记录的任务归属置空，只写记录。
    /// 这是无计划、无任务的一条纯投入记录——它必须写得进去，否则这半小时就凭空丢了。
    func testRecordWithoutATaskIsStillWritten() async throws {
        let (store, _) = makeStore()
        let focus = session(taskID: UUID(), title: "准备季度汇报", estimate: 30, startedAt: store.now)

        try await logFocus(focus, at: store.now.addingTimeInterval(1800),
                           note: "任务已经清理掉了", taskID: nil, store: store)

        let orphans = await store.repository.activities(planID: nil)
        XCTAssertEqual(orphans.count, 1)
        XCTAssertNil(orphans.first?.taskId)
        XCTAssertNil(orphans.first?.planId)
        XCTAssertEqual(orphans.first?.durationMinutes, 30, "时长照常按会话算出来")
    }

    // MARK: - AC24：行动记录正文不进模型请求体

    /// 计时结束时填的那句说明属于行动记录正文，按数据边界不进入任何模型请求。
    /// 这里断言的是「它确实存在于库里，但请求体里没有」——两个方向都查，
    /// 否则一个空上下文也能让断言通过。
    func testFocusNoteNeverEntersTheModelRequestBody() async throws {
        let (store, _) = makeStore()
        let planID = try await plan("季度工作汇报", store: store)
        let taskID = try await task("准备季度汇报", planID: planID, store: store)
        let note = "客户名单还没确认完，先别往下写"
        let focus = session(taskID: taskID, title: "准备季度汇报", estimate: 30, startedAt: store.now)
        try await logFocus(focus, at: store.now.addingTimeInterval(1800),
                           note: note, taskID: taskID, store: store)

        // 说明已经写进库里。
        let stored = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(stored.first?.text, note)

        let repository = store.repository
        let plans = await repository.allPlans()
        var tasksByPlan: [UUID: [Task]] = [:]
        for task in await repository.allTasks() {
            if let plan = task.planId { tasksByPlan[plan, default: []].append(task) }
        }

        let input = AIContextBuilder.build(sendableText: "今天要做什么",
                                           today: store.today, timeZone: zone,
                                           plans: plans, tasksByPlan: tasksByPlan,
                                           stagesByPlan: [:], metricsByPlan: [:],
                                           occurrencesByTask: [:], defaults: .fallback)
        let body = input.requestBodyJSONString()

        XCTAssertFalse(body.contains(note), "行动记录正文不进请求体")
        XCTAssertFalse(body.contains("客户名单"), "连片段也不该出现")
        XCTAssertTrue(body.contains("准备季度汇报"), "任务标题仍在上下文里，断言不是空过")
    }
}
