//
//  NotificationPlannerTests.swift
//  MovoDomainTests
//
//  本地通知排期计算单测（time.md / REQ 10.9）：
//  - 某一时刻 startAt：按提前量准点提醒（timedTask）
//  - 某一天 startAt：当天默认时刻提醒（dateOnlyTask）
//  - endAt 截止：提前 N 天 + 当天截止时刻提醒（hardDeadline）
//  - 重复规则带 dailyStart：按实例日期 + 每天时刻准时提醒
//  - weeklyCount / 无每天时刻：不产生定点定时提醒
//  - 模板任务与已结束任务不产生直接提醒
//  - 安静时段顺延与跨时区 TravelClock 计算
//

import XCTest
import MovoKit

final class NotificationPlannerTests: XCTestCase {

    private let tzID = "Asia/Shanghai"
    private var tz: TimeZone { TimeZone(identifier: tzID)! }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DateOnly {
        DateOnly(y: y, m: m, d: d, sourceTZ: tzID)
    }

    private func makeDate(y: Int, m: Int, d: Int, h: Int, min: Int, in timeZone: TimeZone? = nil) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h; comps.minute = min; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone ?? tz
        return cal.date(from: comps)!
    }

    private func makeDefaults(leadMinutes: Int = 15, quietStart: Int = 22, quietEnd: Int = 7) -> AppDefaults {
        var d = AppDefaults.fallback
        d.notifications.timedTaskLeadMinutes = leadMinutes
        d.notifications.dateOnlyTaskHour = 9
        d.notifications.dateOnlyTaskMinute = 0
        d.notifications.hardDeadlineLeadDays = 1
        d.notifications.hardDeadlineSameDayHour = 9
        d.notifications.hardDeadlineSameDayMinute = 0
        d.notifications.quietHoursStart = quietStart
        d.notifications.quietHoursEnd = quietEnd
        d.notifications.aggregationWindowMinutes = 0 // 禁用合并以便独立校验条数
        return d
    }

    // MARK: - 某一时刻任务按提前量提醒

    func testTimedTaskProducesAdvanceReminder() {
        let today = day(2026, 10, 8)
        let now = makeDate(y: 2026, m: 10, d: 8, h: 8, min: 0) // 上午 08:00
        let targetEpoch = makeDate(y: 2026, m: 10, d: 8, h: 15, min: 30) // 15:30
        let instant = DateTimeTZ(epoch: targetEpoch, tzID: tzID)
        let task = Task(title: "季度开会", startAt: .instant(instant))

        let defaults = makeDefaults(leadMinutes: 15)
        let planned = NotificationPlanner.plan(tasks: [task], plans: [], rules: [], occurrences: [],
                                              defaults: defaults, now: now, timeZone: tz, today: today)

        let timed = planned.filter { $0.kind == .timedTask }
        XCTAssertEqual(timed.count, 1)
        let item = timed[0]
        XCTAssertEqual(item.title, "快到时间了")
        XCTAssertTrue(item.body.contains("季度开会"))
        // 15:30 提前 15 分钟 -> 15:15
        let expectedFire = makeDate(y: 2026, m: 10, d: 8, h: 15, min: 15)
        XCTAssertEqual(item.fireDate, expectedFire)
        XCTAssertEqual(item.id, "movo.task.\(task.id.uuidString).timed")
    }

    // MARK: - 某一天任务默认早间提醒

    func testDateOnlyTaskProducesMorningReminder() {
        let today = day(2026, 10, 8)
        let now = makeDate(y: 2026, m: 10, d: 8, h: 7, min: 30)
        let taskToday = Task(title: "给花浇水", startAt: .day(today))
        let tomorrow = today.adding(days: 1)
        let taskTomorrow = Task(title: "买火车票", startAt: .day(tomorrow))

        let defaults = makeDefaults()
        let planned = NotificationPlanner.plan(tasks: [taskToday, taskTomorrow], plans: [], rules: [],
                                              occurrences: [], defaults: defaults, now: now, timeZone: tz,
                                              today: today)

        let dateItems = planned.filter { $0.kind == .dateOnlyTask }
        XCTAssertEqual(dateItems.count, 2)

        let todayItem = dateItems.first { $0.entityID == taskToday.id }
        XCTAssertNotNil(todayItem)
        XCTAssertEqual(todayItem?.title, "今天安排")
        XCTAssertEqual(todayItem?.fireDate, makeDate(y: 2026, m: 10, d: 8, h: 9, min: 0))

        let tomorrowItem = dateItems.first { $0.entityID == taskTomorrow.id }
        XCTAssertNotNil(tomorrowItem)
        XCTAssertEqual(tomorrowItem?.fireDate, makeDate(y: 2026, m: 10, d: 9, h: 9, min: 0))
    }

    // MARK: - 截止时间生成提前与当天提醒

    func testEndAtProducesLeadAndSameDayReminders() {
        let today = day(2026, 10, 8)
        let now = makeDate(y: 2026, m: 10, d: 8, h: 8, min: 0)
        let deadline = day(2026, 10, 10)
        let task = Task(title: "提交报销单", endAt: .day(deadline))

        let defaults = makeDefaults() // leadDays = 1, sameDayHour = 9
        let planned = NotificationPlanner.plan(tasks: [task], plans: [], rules: [], occurrences: [],
                                              defaults: defaults, now: now, timeZone: tz, today: today)

        let deadlineReminders = planned.filter { $0.kind == .hardDeadline }
        XCTAssertEqual(deadlineReminders.count, 2)

        let lead = deadlineReminders.first { $0.id.contains("lead") }
        XCTAssertNotNil(lead)
        XCTAssertEqual(lead?.title, "还有 1 天到截止")
        XCTAssertEqual(lead?.fireDate, makeDate(y: 2026, m: 10, d: 9, h: 9, min: 0))

        let sameDay = deadlineReminders.first { $0.id.contains("today") }
        XCTAssertNotNil(sameDay)
        XCTAssertEqual(sameDay?.title, "今天是最晚完成时间")
        XCTAssertEqual(sameDay?.fireDate, makeDate(y: 2026, m: 10, d: 10, h: 9, min: 0))
    }

    // MARK: - 重复规则带时刻与 weeklyCount 对比

    func testRecurrenceRuleWithDailyStartSchedulesOccurrenceReminder() {
        let today = day(2026, 10, 8)
        let now = makeDate(y: 2026, m: 10, d: 8, h: 7, min: 0)
        let templateTask = Task(title: "晨间跑步", isTemplate: true)
        let rule = RecurrenceRule(id: UUID(), taskId: templateTask.id, pattern: .daily,
                                  dailyStart: TimeOfDay(hour: 7, minute: 30),
                                  dailyEnd: TimeOfDay(hour: 8, minute: 0),
                                  effectiveFrom: today)

        let occurrence = RecurrenceOccurrence(ruleId: rule.id, taskId: templateTask.id,
                                              scheduledOn: today, status: .pending)

        let defaults = makeDefaults(leadMinutes: 10)
        let planned = NotificationPlanner.plan(tasks: [templateTask], plans: [], rules: [rule],
                                              occurrences: [occurrence], defaults: defaults,
                                              now: now, timeZone: tz, today: today)

        // 模板本身不发任务提醒
        XCTAssertFalse(planned.contains(where: { $0.id == "movo.task.\(templateTask.id.uuidString).day" }))

        // occurrence 按 7:30 提前 10 分钟 -> 7:20 提醒
        let occurrenceReminders = planned.filter { $0.id.contains(occurrence.id.uuidString) }
        XCTAssertEqual(occurrenceReminders.count, 1)
        XCTAssertEqual(occurrenceReminders.first?.fireDate, makeDate(y: 2026, m: 10, d: 8, h: 7, min: 20))
    }

    func testWeeklyCountRuleDoesNotProduceTimedOccurrenceReminders() {
        let today = day(2026, 10, 8)
        let now = makeDate(y: 2026, m: 10, d: 8, h: 7, min: 0)
        let templateTask = Task(title: "力量训练", isTemplate: true)
        let rule = RecurrenceRule(id: UUID(), taskId: templateTask.id, pattern: .weeklyCount,
                                  weeklyCount: 3, effectiveFrom: today) // 无 dailyStart
        let occurrence = RecurrenceOccurrence(ruleId: rule.id, taskId: templateTask.id,
                                              scheduledOn: today, status: .pending)

        let defaults = makeDefaults()
        let planned = NotificationPlanner.plan(tasks: [templateTask], plans: [], rules: [rule],
                                              occurrences: [occurrence], defaults: defaults,
                                              now: now, timeZone: tz, today: today)

        let occurrenceReminders = planned.filter { $0.id.contains(occurrence.id.uuidString) }
        XCTAssertTrue(occurrenceReminders.isEmpty, "weeklyCount 且无每天时刻时不产生定点定时提醒")
    }

    // MARK: - 模板与已结束任务排除

    func testCompletedOrCancelledOrArchivedTasksAreExcluded() {
        let today = day(2026, 10, 8)
        let now = makeDate(y: 2026, m: 10, d: 8, h: 8, min: 0)
        let planID = UUID()
        let archivedPlan = Plan(id: planID, name: "旧计划", kind: .delivery, status: .archived)

        let doneTask = Task(title: "已完成", status: .done, startAt: .day(today))
        let cancelledTask = Task(title: "已取消", status: .cancelled, startAt: .day(today))
        let archivedPlanTask = Task(title: "归档计划里的任务", planId: planID, status: .todo, startAt: .day(today))

        let defaults = makeDefaults()
        let planned = NotificationPlanner.plan(tasks: [doneTask, cancelledTask, archivedPlanTask],
                                              plans: [archivedPlan], rules: [], occurrences: [],
                                              defaults: defaults, now: now, timeZone: tz, today: today)

        XCTAssertTrue(planned.filter({ $0.kind == .dateOnlyTask }).isEmpty)
    }

    // MARK: - 安静时段顺延

    func testQuietHoursShiftsNotificationToEndOfQuietPeriod() {
        let today = day(2026, 10, 8)
        let now = makeDate(y: 2026, m: 10, d: 8, h: 20, min: 0)
        // 任务设定在夜间 23:00（安静时段 22:00 ~ 07:00）
        let lateEpoch = makeDate(y: 2026, m: 10, d: 8, h: 23, min: 0)
        let task = Task(title: "夜间备份", startAt: .instant(DateTimeTZ(epoch: lateEpoch, tzID: tzID)))

        let defaults = makeDefaults(leadMinutes: 0, quietStart: 22, quietEnd: 7)
        let planned = NotificationPlanner.plan(tasks: [task], plans: [], rules: [], occurrences: [],
                                              defaults: defaults, now: now, timeZone: tz, today: today)

        let timed = planned.first { $0.entityID == task.id }
        XCTAssertNotNil(timed)
        // 落在 23:00 的通知顺延至次日 07:00
        let expectedShifted = makeDate(y: 2026, m: 10, d: 9, h: 7, min: 0)
        XCTAssertEqual(timed?.fireDate, expectedShifted)
    }

    // MARK: - 跨时区场景

    func testCrossTimeZonePlanningProducesCorrectInstant() {
        let nyTZ = TimeZone(identifier: "America/New_York")!
        let nyDay = DateOnly(y: 2026, m: 10, d: 8, sourceTZ: nyTZ.identifier)
        let now = makeDate(y: 2026, m: 10, d: 8, h: 8, min: 0, in: nyTZ)

        // 纽约时间 14:00
        let meetingEpoch = makeDate(y: 2026, m: 10, d: 8, h: 14, min: 0, in: nyTZ)
        let instant = DateTimeTZ(epoch: meetingEpoch, tzID: nyTZ.identifier)
        let task = Task(title: "跨国沟通", startAt: .instant(instant))

        let defaults = makeDefaults(leadMinutes: 30)
        let planned = NotificationPlanner.plan(tasks: [task], plans: [], rules: [], occurrences: [],
                                              defaults: defaults, now: now, timeZone: nyTZ, today: nyDay)

        let item = planned.first { $0.entityID == task.id }
        XCTAssertNotNil(item)
        // 提前 30 分钟 -> 纽约时间 13:30
        let expectedFire = makeDate(y: 2026, m: 10, d: 8, h: 13, min: 30, in: nyTZ)
        XCTAssertEqual(item?.fireDate, expectedFire)
    }
}
