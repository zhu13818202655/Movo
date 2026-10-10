import Foundation
import XCTest
import MovoKit

/// 专注到点提醒：从会话到系统排期的这一段。
///
/// 这里锁住的是三件事：
///
/// 1. **排期时刻取有效终点，不取名义锚点。** 暂停 10 分钟后继续，终点就往后挪 10 分钟；
///    沿用名义锚点会让提醒提前 10 分钟响，而那正是用户明确说了不要的行为。
/// 2. **撤销与重排不加新机制。** `replaceAll` 是整份替换，暂停后算出来的排期里没有这条提醒，
///    于是它被撤销；继续后按新终点算回来。断言因此落在「排期里有没有这一条」上。
/// 3. **到点提醒不走安静时段顺延、不进聚合窗口。** 它是用户刚刚亲手设下的一个闹钟，
///    推到早上 7 点或并进「有 N 项要看一下」都不再是他要的那一次提醒。
///
/// 时间全部注入，不读系统时钟。
final class FocusReminderTests: XCTestCase {

    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private let taskID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private var today: DateOnly {
        DateOnly(iso8601DateString: "2026-10-08", sourceTZ: zone.identifier)!
    }

    private func moment(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        TimePoint.makeInstant(on: today,
                              at: TimeOfDay(hour: hour, minute: minute, second: second),
                              in: zone)!.sortEpoch
    }

    private func instant(_ hour: Int, _ minute: Int = 0) -> TimePoint {
        TimePoint.makeInstant(on: today, at: TimeOfDay(hour: hour, minute: minute), in: zone)!
    }

    /// 默认关掉合并、把任务提醒的提前量归零，让「排期里有几条、在什么时刻」可以直接数。
    private func makeDefaults(quietStart: Int = 22, quietEnd: Int = 7,
                              aggregationMinutes: Int = 0,
                              remindAtEnd: Bool = true) -> AppDefaults {
        var d = AppDefaults.fallback
        d.notifications.quietHoursStart = quietStart
        d.notifications.quietHoursEnd = quietEnd
        d.notifications.aggregationWindowMinutes = aggregationMinutes
        d.notifications.timedTaskLeadMinutes = 0
        d.focus.remindAtEnd = remindAtEnd
        return d
    }

    /// 14:00 开始、14:30 到点的一次倒计时。
    private func makeCountdown(at start: Date) -> FocusPolicy.Session {
        let plan = FocusPolicy.plan(startAt: nil, endAt: instant(14, 30),
                                    estimateMinutes: nil, now: start, timeZone: zone)
        return FocusPolicy.start(plan, taskID: taskID, taskTitle: "准备季度汇报", at: start)
    }

    private func plan(_ defaults: AppDefaults, now: Date,
                      focus: FocusPolicy.Session?,
                      tasks: [Task] = []) -> [PlannedNotification] {
        NotificationPlanner.plan(tasks: tasks, plans: [], rules: [], occurrences: [],
                                 defaults: defaults, now: now, timeZone: zone, today: today,
                                 focus: focus)
    }

    // MARK: - 计时中会产生一条到点提醒

    func testRunningCountdownSchedulesOneReminderAtTheAnchor() {
        let now = moment(14, 0)
        let session = makeCountdown(at: now)

        let planned = plan(makeDefaults(), now: now, focus: session)

        let focusItems = planned.filter { $0.kind == .focusEnd }
        XCTAssertEqual(focusItems.count, 1)
        let item = focusItems[0]
        XCTAssertEqual(item.fireDate, moment(14, 30), "14:00 开始、剩余 30 分钟 → 14:30")
        XCTAssertEqual(item.id, "movo.focus.\(session.id.uuidString)")
        XCTAssertEqual(item.entityID, taskID)
        XCTAssertEqual(item.deepLink, "movo://focus/\(taskID.uuidString)")
        XCTAssertTrue(item.body.contains("准备季度汇报"))
        XCTAssertEqual(item.mergedCount, 0)
    }

    /// 提醒要能直接把人送回计时页，而不是任务详情——用户回来是要结束这次计时。
    func testReminderDeepLinkParsesBackToTheFocusScreen() {
        let link = NotificationDeepLink.parse("movo://focus/\(taskID.uuidString)")
        XCTAssertEqual(link, .focus(taskID))
        XCTAssertNil(NotificationDeepLink.parse("movo://focus/not-a-uuid"))
        XCTAssertNil(NotificationDeepLink.parse("movo://focus"))
    }

    // MARK: - 不该排期的四种情形

    /// 暂停期间不该有提醒：计时已经停了，锚点也不再是真正的终点。
    func testPausedSessionSchedulesNothing() {
        let now = moment(14, 0)
        let paused = FocusPolicy.pause(makeCountdown(at: now), at: moment(14, 10))

        let planned = plan(makeDefaults(), now: moment(14, 10), focus: paused)
        XCTAssertTrue(planned.filter { $0.kind == .focusEnd }.isEmpty)
    }

    /// 倒计时已经归零就没什么可提醒的了，界面此时显示的是「已超出」。
    func testAlreadyOverrunSessionSchedulesNothing() {
        let session = makeCountdown(at: moment(14, 0))

        let planned = plan(makeDefaults(), now: moment(14, 45), focus: session)
        XCTAssertTrue(planned.filter { $0.kind == .focusEnd }.isEmpty)
    }

    /// 正计时没有终点，没有「到点」这回事。
    func testStopwatchSchedulesNothing() {
        let now = moment(14, 0)
        let openEnded = FocusPolicy.plan(startAt: instant(14, 0), endAt: nil,
                                         estimateMinutes: nil, now: now, timeZone: zone)
        let session = FocusPolicy.start(openEnded, taskID: taskID,
                                        taskTitle: "整理会议记录", at: now)

        let planned = plan(makeDefaults(), now: now, focus: session)
        XCTAssertTrue(planned.filter { $0.kind == .focusEnd }.isEmpty)
    }

    /// 关掉开关只影响提醒，计时照常走。
    func testReminderSwitchOffSchedulesNothing() {
        let now = moment(14, 0)
        let session = makeCountdown(at: now)

        let planned = plan(makeDefaults(remindAtEnd: false), now: now, focus: session)
        XCTAssertTrue(planned.filter { $0.kind == .focusEnd }.isEmpty)
    }

    /// 没有会话时排期里当然没有这一条——正常排期路径不受影响。
    func testNoSessionSchedulesNothing() {
        let planned = plan(makeDefaults(), now: moment(14, 0), focus: nil)
        XCTAssertTrue(planned.filter { $0.kind == .focusEnd }.isEmpty)
    }

    // MARK: - 排期时刻跟着有效终点走

    /// 暂停 10 分钟、继续之后，终点从 14:30 挪到 14:40。
    /// 沿用名义锚点的话提醒会在 14:30 响，比用户真正该被提醒的时刻早 10 分钟。
    func testEffectiveEndMovesLaterByThePausedTime() throws {
        let start = moment(14, 0)
        let running = makeCountdown(at: start)
        let paused = FocusPolicy.pause(running, at: start)
        let resumed = FocusPolicy.resume(paused, at: moment(14, 10))

        let planned = plan(makeDefaults(), now: moment(14, 10), focus: resumed)

        let item = try XCTUnwrap(planned.first { $0.kind == .focusEnd })
        XCTAssertEqual(item.fireDate, moment(14, 40))
        XCTAssertNotEqual(item.fireDate, moment(14, 30), "不能退回名义锚点")
    }

    /// 同一个会话反复重排，标识不变——继续时是覆盖同一条，不是再叠一条。
    func testIdentifierIsStableAcrossRescheduling() throws {
        let start = moment(14, 0)
        let running = makeCountdown(at: start)
        let resumed = FocusPolicy.resume(FocusPolicy.pause(running, at: start), at: moment(14, 10))

        let before = try XCTUnwrap(plan(makeDefaults(), now: start, focus: running)
            .first { $0.kind == .focusEnd })
        let after = try XCTUnwrap(plan(makeDefaults(), now: moment(14, 10), focus: resumed)
            .first { $0.kind == .focusEnd })

        XCTAssertEqual(before.id, after.id)
        XCTAssertNotEqual(before.fireDate, after.fireDate, "时刻变了，标识不变")
    }

    // MARK: - 不参与顺延与聚合

    /// 到点落在安静时段（22:00–07:00）里也照常在那一刻响。
    /// 这是用户按下开始时就答应他的那一次提醒，顺延到早上 7 点等于没提醒。
    func testReminderIsNotDeferredByQuietHours() throws {
        let defaults = makeDefaults()

        // 22:00 开始、23:00 到点，正好落在安静时段内。
        let start = moment(22, 0)
        let nightly = FocusPolicy.plan(startAt: nil, endAt: instant(23, 0),
                                       estimateMinutes: nil, now: start, timeZone: zone)
        let session = FocusPolicy.start(nightly, taskID: taskID,
                                        taskTitle: "夜里的收尾", at: start)

        let planned = plan(defaults, now: start, focus: session)

        let item = try XCTUnwrap(planned.first { $0.kind == .focusEnd })
        XCTAssertEqual(item.fireDate, moment(23, 0), "安静时段不顺延到 07:00")
    }

    /// 同一窗口里还有别的提醒时，到点提醒仍然是独立的一条，
    /// 标题与正文都不被聚合成「有 N 项要看一下」。
    func testReminderStaysItsOwnItemWhenOtherNotificationsShareTheWindow() throws {
        let now = moment(14, 0)
        let session = makeCountdown(at: now)
        // 15:00 的任务，提前量 0 → 15:00 有一条 timedTask，与 14:30 到点同在一个 60 分钟窗口内。
        let other = Task(title: "站会", startAt: instant(15, 0))

        let planned = plan(makeDefaults(aggregationMinutes: 60), now: now,
                           focus: session, tasks: [other])

        XCTAssertEqual(planned.filter { $0.kind == .focusEnd }.count, 1)
        let item = try XCTUnwrap(planned.first { $0.kind == .focusEnd })
        XCTAssertEqual(item.title, "专注到点了")
        XCTAssertEqual(item.mergedCount, 0, "不被并进聚合条")
        XCTAssertTrue(item.body.contains("准备季度汇报"))
    }

    /// 整个排期仍然按时刻升序，到点提醒插在它该在的位置上。
    func testResultStaysSortedByFireDate() {
        let now = moment(14, 0)
        let session = makeCountdown(at: now)
        let tasks = [Task(title: "站会", startAt: instant(15, 0)),
                     Task(title: "回邮件", startAt: instant(14, 10))]

        let planned = plan(makeDefaults(), now: now, focus: session, tasks: tasks)

        let dates = planned.map(\.fireDate)
        XCTAssertEqual(dates, dates.sorted())

        // 周期回顾是另一条固定排期，这里只看今天这三条谁先谁后。
        let ordered = planned.filter { $0.kind == .timedTask || $0.kind == .focusEnd }
        XCTAssertEqual(ordered.map(\.fireDate),
                       [moment(14, 10), moment(14, 30), moment(15, 0)],
                       "到点提醒落在两条任务提醒之间")
    }

    // MARK: - 服务层：撤销与重排靠整份替换完成

    /// 走一遍真实的服务层：开始有提醒 → 暂停撤销 → 继续按新终点回来。
    /// 用 `InMemoryNotificationScheduler` 断言实际写进系统的内容。
    func testServiceRefreshWritesThenRevokesThenRestoresTheReminder() async throws {
        let scheduler = InMemoryNotificationScheduler()
        let repository = InMemoryRepository()
        let service = NotificationCenterService(repository: repository,
                                                scheduler: scheduler,
                                                defaults: makeDefaults())

        let start = moment(14, 0)
        let running = makeCountdown(at: start)

        // 1. 开始：排期里有一条到点提醒，并且真的写进了「系统」。
        let first = await service.refresh(now: start, timeZone: zone, today: today,
                                         hideDetails: false, focus: running)
        XCTAssertEqual(first.filter { $0.kind == .focusEnd }.count, 1)
        var scheduled = await scheduler.scheduled()
        XCTAssertEqual(scheduled.filter { $0.kind == .focusEnd }.count, 1, "写进系统通知中心")

        // 2. 暂停：重算出来的排期里没有它，整份替换因此等于撤销。
        let paused = FocusPolicy.pause(running, at: start)
        _ = await service.refresh(now: start, timeZone: zone, today: today,
                                  hideDetails: false, focus: paused)
        scheduled = await scheduler.scheduled()
        XCTAssertTrue(scheduled.filter { $0.kind == .focusEnd }.isEmpty, "暂停时撤销")

        // 3. 继续：按挪过的有效终点回来，标识与暂停前相同。
        let resumeAt = moment(14, 10)
        let resumed = FocusPolicy.resume(paused, at: resumeAt)
        let third = await service.refresh(now: resumeAt, timeZone: zone, today: today,
                                          hideDetails: false, focus: resumed)
        let item = try XCTUnwrap(third.first { $0.kind == .focusEnd })
        XCTAssertEqual(item.fireDate, moment(14, 40), "14:30 的锚点被 10 分钟暂停推到 14:40")
        XCTAssertEqual(item.id, "movo.focus.\(running.id.uuidString)")

        scheduled = await scheduler.scheduled()
        XCTAssertEqual(scheduled.filter { $0.kind == .focusEnd }.count, 1, "覆盖同一条，不叠第二条")

        // 4. 结束：会话消失，提醒也跟着消失。
        _ = await service.refresh(now: resumeAt, timeZone: zone, today: today,
                                  hideDetails: false, focus: nil)
        scheduled = await scheduler.scheduled()
        XCTAssertTrue(scheduled.filter { $0.kind == .focusEnd }.isEmpty, "结束后不再提醒")
    }

    /// 到点提醒与普通安排共用同一次「替换」，两者互不挤掉对方。
    func testServiceKeepsScheduledTasksAlongsideTheFocusReminder() async throws {
        let scheduler = InMemoryNotificationScheduler()
        let repository = InMemoryRepository()
        await repository.seedTasks([Task(title: "站会", startAt: instant(15, 0))])
        let service = NotificationCenterService(repository: repository,
                                                scheduler: scheduler,
                                                defaults: makeDefaults())

        let now = moment(14, 0)
        _ = await service.refresh(now: now, timeZone: zone, today: today,
                                  hideDetails: false, focus: makeCountdown(at: now))

        let scheduled = await scheduler.scheduled()
        XCTAssertTrue(scheduled.contains { $0.kind == .focusEnd })
        XCTAssertTrue(scheduled.contains { $0.kind == .timedTask }, "任务提醒没有被专注挤掉")
    }
}
