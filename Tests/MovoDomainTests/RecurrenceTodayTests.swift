import Foundation
import XCTest
import MovoKit

/// 重复行动与「今日」的投影关系：
/// - 今天该有这一次 → 展示成独立的今日条目，但它仍然属于重复行动本身
/// - 「每周 N 次」不预排日期 → 靠派生的「今天也可以做」出现，勾选时才落库
/// - 模板不是一次待办 → 不出现在「即将」，也不按模板自己的时间展示
@MainActor
final class RecurrenceTodayTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    /// 2026-10-08 是周四（ISO weekday 4）——涉及「指定星期」的断言需要一个确定的星期。
    private var day: DateOnly { DateOnly(iso8601DateString: "2026-10-08", sourceTZ: zone.identifier)! }

    private func store(_ repository: InMemoryRepository = InMemoryRepository(),
                       clock: TravelClock? = nil) -> DomainStore {
        DomainStore(repository: repository, clock: clock ?? TravelClock(day.noon),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: zone.identifier),
                    deviceIDProvider: FixedDeviceIDProvider("recurrence-today"))
    }

    @discardableResult
    private func template(_ title: String, store: DomainStore, startAt: DateOnly? = nil) async throws -> UUID {
        let result = try await store.execute(CreateTask(title: title,
                                                        startAt: startAt.map { TimePoint.day($0) }))
        return try XCTUnwrap(result.entityID)
    }

    private func scheduled(_ view: TodayView) -> [TodayItem] {
        view.focus.filter { if case .occurrence = $0.body { return true }; return false }
    }

    private func weekOccurrences(_ store: DomainStore, around date: DateOnly) async -> [RecurrenceOccurrence] {
        await store.repository.occurrences(scheduledIn: DateOnlyRange.week(containing: date), planID: nil)
    }

    // MARK: - 固定日期模式

    func testDailyActionAppearsOnceTodayAndNotAsCandidate() async throws {
        let store = store()
        let taskID = try await template("跳绳", store: store)
        try await store.execute(CreateRecurrence(taskID: taskID, pattern: .daily, effectiveFrom: day,
                                                 dailyStart: TimeOfDay(hour: 6, minute: 30)))

        let view = await store.today(day)
        let today = scheduled(view)
        XCTAssertEqual(today.count, 1, "今天该有一次，展示成独立的今日条目")
        XCTAssertEqual(today.first?.taskId, taskID, "它仍然关联着同一条重复行动")
        XCTAssertEqual(today.first?.timeText(in: .today(day)), "06:30", "规则上的每天时刻要落到这一次上")
        XCTAssertEqual(today.first?.timeText(in: .absolute), "10月8日 06:30",
                       "今日上下文省略的只是「当天」这个日期，绝对上下文照旧完整")
        XCTAssertTrue(view.routine.isEmpty, "已经建成实例了，不该再出现候选")
        XCTAssertEqual(view.pendingCount, 1)
    }

    func testRuleWindowIncludesLastDayAndStopsAfter() async throws {
        let store = store()
        let taskID = try await template("跳绳", store: store)
        let last = day.adding(days: 1)
        try await store.execute(CreateRecurrence(taskID: taskID, pattern: .daily,
                                                 effectiveFrom: day, effectiveUntil: last))

        let onFirst = await store.today(day)
        let onLast = await store.today(last)
        let afterWindow = await store.today(day.adding(days: 2))
        XCTAssertEqual(scheduled(onFirst).count, 1)
        XCTAssertEqual(scheduled(onLast).count, 1, "结束日当天仍要有一次")
        XCTAssertTrue(scheduled(afterWindow).isEmpty, "窗口结束后不再安排")
        XCTAssertTrue(afterWindow.routine.isEmpty, "窗口结束后也不再出现候选")
    }

    func testWeekdayRuleOnlyAppearsOnSelectedDays() async throws {
        let store = store()
        let taskID = try await template("例会", store: store)
        // 只选周一、周三 → 夹具日期是周四，不该出现
        try await store.execute(CreateRecurrence(taskID: taskID, pattern: .weekdays,
                                                 weekdays: [1, 3], effectiveFrom: day))
        let view = await store.today(day)
        XCTAssertEqual(view.date.isoWeekday, 4, "夹具日期应是周四")
        XCTAssertTrue(scheduled(view).isEmpty)
        XCTAssertTrue(view.routine.isEmpty)
    }

    // MARK: - 每周 N 次（不预排日期）

    func testWeeklyCountShowsCandidateWithoutPersisting() async throws {
        let store = store()
        let taskID = try await template("跑步", store: store)
        try await store.execute(CreateRecurrence(taskID: taskID, pattern: .weeklyCount,
                                                 weeklyCount: 3, effectiveFrom: day))
        let before = await weekOccurrences(store, around: day)
        XCTAssertTrue(before.isEmpty, "每周 N 次不预排日期，事前不应有实例")

        let view = await store.today(day)
        let candidate = try XCTUnwrap(view.routine.first)
        XCTAssertEqual(candidate.taskId, taskID)
        XCTAssertEqual(candidate.section, .routine)
        XCTAssertEqual(candidate.displayStatus, "本周 0/3 次")
        XCTAssertEqual(candidate.completionTarget, .task(taskID),
                       "勾选仍走模板的完成路径，不发明第二种写库方式")
        guard case .routine(_, _, let target, let done) = candidate.body else {
            return XCTFail("应为可做候选")
        }
        XCTAssertEqual(target, 3)
        XCTAssertEqual(done, 0)
        XCTAssertEqual(view.pendingCount, 0, "候选不参与「待推进」计数")

        let after = await weekOccurrences(store, around: day)
        XCTAssertTrue(after.isEmpty, "候选只是投影，看一眼不该写库")
    }

    func testWeeklyCountCandidateLeavesOnceWeekTargetMet() async throws {
        let store = store()
        let taskID = try await template("跑步", store: store)
        try await store.execute(CreateRecurrence(taskID: taskID, pattern: .weeklyCount,
                                                 weeklyCount: 1, effectiveFrom: day))
        let before = await store.today(day)
        XCTAssertEqual(before.routine.count, 1)

        _ = try await store.execute(CompleteTask(taskID: taskID, at: .precise(store.now)))

        let view = await store.today(day)
        XCTAssertTrue(view.routine.isEmpty, "本周目标达成后不再占今天的位置")
        XCTAssertEqual(view.completed.count, 1, "这一次以已完成记录出现")
        let written = await weekOccurrences(store, around: day)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?.occurredOn, day, "每周 N 次以 occurredOn 记这一次")
        XCTAssertNil(written.first?.scheduledOn)
        XCTAssertEqual(written.first?.status, .done)
        let record = await store.repository.task(taskID)
        XCTAssertEqual(record?.status, .todo, "记录一次不把模板本身变成已完成")
    }

    func testWeeklyCountProgressReflectsThisWeekOnly() async throws {
        let clock = TravelClock(day.noon)
        let store = store(clock: clock)
        let taskID = try await template("跑步", store: store)
        try await store.execute(CreateRecurrence(taskID: taskID, pattern: .weeklyCount,
                                                 weeklyCount: 2, effectiveFrom: day))
        _ = try await store.execute(CompleteTask(taskID: taskID, at: .precise(store.now)))
        let thisWeek = await store.today(day)
        // 按整周看：还差一次就继续留着，行上的进度跟着更新（不撤走，避免"勾了没反应"）
        XCTAssertEqual(thisWeek.routine.first?.displayStatus, "本周 1/2 次")
        // 今天这一次也已经作为已完成记录出现，两份互不替代
        XCTAssertEqual(thisWeek.completed.count, 1)
        XCTAssertEqual(thisWeek.completed.first?.taskId, taskID)

        // 到了下一周的同一天：上一次不再计入本周，进度从 0 重新开始
        clock.advance(days: 7, in: zone)
        let nextWeek = await store.today(store.today)
        XCTAssertEqual(nextWeek.routine.first?.displayStatus, "本周 0/2 次")
    }

    // MARK: - 模板不是一次待办

    func testUpcomingAndTodayFiltersExcludeTemplates() async throws {
        let store = store()
        let taskID = try await template("跳绳", store: store, startAt: day.adding(days: 5))
        try await store.execute(CreateRecurrence(taskID: taskID, pattern: .daily, effectiveFrom: day))

        let upcoming = await store.todos(filter: .upcoming)
        let today = await store.todos(filter: .today)
        let unscheduled = await store.todos(filter: .unscheduled)
        XCTAssertTrue(upcoming.isEmpty, "模板的 startAt 只是窗口端点，不该在「即将」里被当成一次待办")
        XCTAssertTrue(today.isEmpty)
        XCTAssertTrue(unscheduled.isEmpty)

        // 「全部」仍是重复行动的管理入口，且展示频率而不是模板自身时间
        let all = await store.todos(filter: .all)
        XCTAssertEqual(all.map(\.id), [taskID])
        XCTAssertEqual(all.first?.recurrenceSummary, "每天")
        XCTAssertEqual(all.first?.task.isTemplate, true)
    }

    func testTemplateSummaryShowsFrequencyAndWindow() async throws {
        let store = store()
        let taskID = try await template("跳绳", store: store)
        try await store.execute(CreateRecurrence(taskID: taskID, pattern: .daily, effectiveFrom: day,
                                                 effectiveUntil: day.adding(days: 30),
                                                 dailyStart: TimeOfDay(hour: 6, minute: 30)))
        let all = await store.todos(filter: .all)
        let node = try XCTUnwrap(all.first)
        XCTAssertEqual(node.recurrenceSummary, "每天 · 06:30 开始 · 到 11月7日")
    }
}
