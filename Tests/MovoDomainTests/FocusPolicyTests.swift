import Foundation
import XCTest
import MovoKit

/// 专注计时的纯逻辑。这里锁住的是三条口径，界面与持久化都只是它们的消费者：
///
/// 1. **时长以结束时刻为锚点，不以时长为锚点。** 所以「起止都填」与「只填结束」用同一套算法，
///    倒计时归零那一刻的有效已用时长就是名义长度，界面上的「计划 30 分钟」与结束时的
///    「按 30 分钟截断」也因此是同一个数。
/// 2. **暂停不计入投入。** 暂停期间已用时长冻结、剩余不推进，继续时不把暂停算回来，
///    但倒计时的真实终点会因此往后挪——排期提醒必须用挪过的终点。
/// 3. **倒计时归零不是终点。** 计时继续走，显示从「剩余」翻成「已超出」，不自动结束、
///    不自动标记完成。
///
/// 所有时间都走注入的时刻，不读系统时钟。
final class FocusPolicyTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    /// 2026-10-08，周四。
    private var day: DateOnly { DateOnly(iso8601DateString: "2026-10-08", sourceTZ: zone.identifier)! }
    private var nextDay: DateOnly { day.adding(days: 1) }

    private func instant(on day: DateOnly, _ hour: Int,
                         _ minute: Int = 0, _ second: Int = 0) throws -> TimePoint {
        try XCTUnwrap(TimePoint.makeInstant(
            on: day, at: TimeOfDay(hour: hour, minute: minute, second: second), in: zone))
    }

    /// 绝对时刻，用于当「当前时刻」。
    private func moment(on day: DateOnly, _ hour: Int,
                        _ minute: Int = 0, _ second: Int = 0) throws -> Date {
        try instant(on: day, hour, minute, second).sortEpoch
    }

    private func makePlan(startAt: TimePoint?, endAt: TimePoint?,
                          estimate: Int? = nil, at now: Date) -> FocusPolicy.Plan {
        FocusPolicy.plan(startAt: startAt, endAt: endAt, estimateMinutes: estimate,
                         now: now, timeZone: zone)
    }

    private func makeSession(startAt: TimePoint?, endAt: TimePoint?,
                             estimate: Int? = nil, at now: Date) -> FocusPolicy.Session {
        FocusPolicy.start(makePlan(startAt: startAt, endAt: endAt, estimate: estimate, at: now),
                          taskID: taskID, taskTitle: "准备季度汇报", at: now)
    }

    // MARK: - 推导：五档来源

    func testBothEndpointsUseTheGapAsLength() throws {
        let start = try instant(on: day, 14, 0)
        let end = try instant(on: day, 14, 30)
        let now = try moment(on: day, 14, 10)
        let plan = makePlan(startAt: start, endAt: end, at: now)

        XCTAssertEqual(plan.basis, .startAndEnd)
        XCTAssertEqual(plan.form, .countdown)
        XCTAssertEqual(plan.plannedSeconds, 1800)
        XCTAssertEqual(plan.plannedMinutes, 30)
        XCTAssertEqual(plan.anchor?.epoch, end.instantValue?.epoch, "锚点必须是结束时刻")
        XCTAssertEqual(plan.planLabel, "计划 30 分钟")
        XCTAssertEqual(plan.buttonTitle, "开始专注 · 30 分钟")
    }

    func testEndOnlyAnchorsToTheDeadlineEvenIfStartIsMissing() throws {
        let end = try instant(on: day, 15, 0)
        let now = try moment(on: day, 14, 0)
        let plan = makePlan(startAt: nil, endAt: end, at: now)

        XCTAssertEqual(plan.basis, .endOnly)
        XCTAssertEqual(plan.form, .countdown)
        XCTAssertEqual(plan.plannedSeconds, 3600, "长度取「离截止还有多久」")
        XCTAssertEqual(plan.anchor?.epoch, end.instantValue?.epoch)
        XCTAssertEqual(plan.planLabel, "离截止", "这里没有「计划时长」，措辞要跟着换")
        XCTAssertEqual(plan.buttonTitle, "开始专注 · 到 15:00")
    }

    func testStartOnlyFallsBackToStopwatch() throws {
        let plan = makePlan(startAt: try instant(on: day, 14, 0), endAt: nil,
                            at: try moment(on: day, 14, 10))

        XCTAssertEqual(plan.basis, .startOnly)
        XCTAssertEqual(plan.form, .stopwatch)
        XCTAssertNil(plan.anchor)
        XCTAssertNil(plan.plannedSeconds)
        XCTAssertEqual(plan.planLabel, "未设置时长，正计时")
        XCTAssertEqual(plan.buttonTitle, "开始专注 · 正计时")
    }

    func testEstimateBecomesTheCountdownLength() throws {
        let now = try moment(on: day, 14, 0)
        let plan = makePlan(startAt: nil, endAt: nil, estimate: 25, at: now)

        XCTAssertEqual(plan.basis, .estimate)
        XCTAssertEqual(plan.plannedSeconds, 1500)
        XCTAssertEqual(plan.anchor?.epoch, now.addingTimeInterval(1500), "锚点从开始那一刻往后推")
        XCTAssertEqual(plan.planLabel, "计划 25 分钟")
    }

    func testNothingMeansOpenEndedStopwatch() throws {
        let plan = makePlan(startAt: nil, endAt: nil, at: try moment(on: day, 14, 0))

        XCTAssertEqual(plan.basis, .none)
        XCTAssertEqual(plan.form, .stopwatch)
        XCTAssertNil(plan.plannedSeconds)
        XCTAssertEqual(plan.buttonTitle, "开始专注 · 正计时")
    }

    /// 「截止 今天」是某一天，没有钟点。它说明的是期限落在哪一天，不是这次要坐多久，
    /// 所以既不能当锚点，也不能把整整一天算成专注时长。
    func testDayGranularityEndpointsDoNotBecomeAnAnchor() throws {
        let plan = makePlan(startAt: .day(day), endAt: .day(day), at: try moment(on: day, 14, 0))
        XCTAssertEqual(plan.basis, .none, "只有日期时退回正计时")

        let mixed = makePlan(startAt: try instant(on: day, 14, 0), endAt: .day(day),
                             at: try moment(on: day, 14, 10))
        XCTAssertEqual(mixed.basis, .startOnly, "结束端只有日期，构不成终点")
        XCTAssertNil(mixed.anchor)
    }

    func testPastDeadlineDoesNotProduceANegativeCountdown() throws {
        let plan = makePlan(startAt: nil, endAt: try instant(on: day, 13, 0),
                            at: try moment(on: day, 14, 0))
        XCTAssertEqual(plan.basis, .none, "截止已经过去，不该开出一个负数倒计时")
        XCTAssertEqual(plan.form, .stopwatch)
    }

    // MARK: - 起止都是时刻：倒计时

    func testCountdownDerivesFromTheAnchor() throws {
        let session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30),
                                  at: try moment(on: day, 14, 0))
        let now = try moment(on: day, 14, 10)

        XCTAssertEqual(FocusPolicy.status(of: session), .running)
        XCTAssertEqual(FocusPolicy.elapsedSeconds(session, at: now), 600)
        XCTAssertEqual(FocusPolicy.remainingSeconds(session, at: now), 1200)

        let snapshot = FocusPolicy.snapshot(session, at: now, stalenessThresholdHours: 3)
        XCTAssertEqual(snapshot.primaryText, "20:00")
        XCTAssertEqual(snapshot.secondaryText, "到 14:30 结束")
        XCTAssertEqual(snapshot.barDetailText, "剩余 20:00 · 到 14:30")
        XCTAssertEqual(snapshot.planLabel, "计划 30 分钟")
        XCTAssertEqual(try XCTUnwrap(snapshot.remainingFraction), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertFalse(snapshot.isOverrun)
        XCTAssertNil(snapshot.currentPauseSeconds)
        XCTAssertNil(snapshot.pausedDurationText)
    }

    /// story 里的例子：14:30 截止的 30 分钟任务，14:01:48 时剩 28:12。
    func testCountdownUsesSecondsPrecision() throws {
        let now = try moment(on: day, 14, 1, 48)
        let session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: now)

        XCTAssertEqual(FocusPolicy.clockText(FocusPolicy.remainingSeconds(session, at: now) ?? 0), "28:12")
    }

    func testEndOnlyCountdownShowsTheDeadlineInWords() throws {
        let now = try moment(on: day, 14, 0)
        let session = makeSession(startAt: nil, endAt: try instant(on: day, 15, 0), at: now)
        let later = try moment(on: day, 14, 31, 48)

        XCTAssertEqual(FocusPolicy.remainingSeconds(session, at: later), 1692)
        let snapshot = FocusPolicy.snapshot(session, at: later, stalenessThresholdHours: 3)
        XCTAssertEqual(snapshot.primaryText, "28:12")
        XCTAssertEqual(snapshot.barDetailText, "剩余 28:12 · 到 15:00")
        XCTAssertEqual(snapshot.planLabel, "离截止")
    }

    // MARK: - 正计时

    func testStopwatchCountsUpWithNoRemaining() throws {
        let now = try moment(on: day, 14, 0)
        let session = makeSession(startAt: try instant(on: day, 14, 0), endAt: nil, at: now)
        let later = try moment(on: day, 14, 12, 40)

        XCTAssertEqual(FocusPolicy.elapsedSeconds(session, at: later), 760)
        XCTAssertNil(FocusPolicy.remainingSeconds(session, at: later))
        XCTAssertEqual(FocusPolicy.overrunSeconds(session, at: later), 0)
        XCTAssertNil(FocusPolicy.effectiveEnd(session, at: later), "正计时没有到点这回事")

        let snapshot = FocusPolicy.snapshot(session, at: later, stalenessThresholdHours: 3)
        XCTAssertEqual(snapshot.primaryText, "12:40")
        XCTAssertEqual(snapshot.secondaryText, "已专注")
        XCTAssertEqual(snapshot.barDetailText, "已专注 12:40")
        XCTAssertNil(snapshot.remainingFraction, "正计时不画进度环，改为刻度点")
        XCTAssertFalse(snapshot.isOverrun)
    }

    // MARK: - 暂停

    func testPauseFreezesElapsedAndRemaining() throws {
        let started = try moment(on: day, 14, 0)
        var session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: started)
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 10))

        XCTAssertEqual(FocusPolicy.status(of: session), .paused)

        for now in [try moment(on: day, 14, 10), try moment(on: day, 14, 25)] {
            XCTAssertEqual(FocusPolicy.elapsedSeconds(session, at: now), 600, "暂停中已用时长冻结")
            XCTAssertEqual(FocusPolicy.remainingSeconds(session, at: now), 1200, "暂停中剩余也冻结")
        }

        let at = try moment(on: day, 14, 15)
        let snapshot = FocusPolicy.snapshot(session, at: at, stalenessThresholdHours: 3)
        XCTAssertEqual(snapshot.currentPauseSeconds, 300)
        XCTAssertEqual(snapshot.pausedDurationText, "已暂停 05:00")
        XCTAssertEqual(snapshot.barDetailText, "已暂停 · 剩余 20:00")
        XCTAssertNil(FocusPolicy.effectiveEnd(session, at: at), "暂停中不排期到点提醒")

        // 暂停期间不发生到点：没有暂停时 14:30 就归零并开始超出了，
        // 现在仍停在还有 20 分钟的位置，一秒都没往前推。
        let wouldHaveExpired = try moment(on: day, 14, 30)
        XCTAssertEqual(FocusPolicy.remainingSeconds(session, at: wouldHaveExpired), 1200)
        XCTAssertEqual(FocusPolicy.overrunSeconds(session, at: wouldHaveExpired), 0)
    }

    func testPauseIsNotCountedIntoTheRecord() throws {
        var session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: try moment(on: day, 14, 0))
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 10))
        session = FocusPolicy.resume(session, at: try moment(on: day, 14, 15))

        let now = try moment(on: day, 14, 15)
        XCTAssertEqual(FocusPolicy.pausedSeconds(session, at: now), 300)
        XCTAssertEqual(FocusPolicy.elapsedSeconds(session, at: now), 600, "去趟厕所的 5 分钟不算投入")
        XCTAssertEqual(FocusPolicy.remainingSeconds(session, at: now), 1200, "继续时不把暂停算回来")
    }

    func testMultiplePausesAccumulate() throws {
        var session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: try moment(on: day, 14, 0))
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 5))
        session = FocusPolicy.resume(session, at: try moment(on: day, 14, 7))
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 10))
        session = FocusPolicy.resume(session, at: try moment(on: day, 14, 14))

        let now = try moment(on: day, 14, 20)
        XCTAssertEqual(FocusPolicy.pausedSeconds(session, at: now), 360, "2 分钟 + 4 分钟逐段累加")
        XCTAssertEqual(FocusPolicy.elapsedSeconds(session, at: now), 840)
        XCTAssertEqual(FocusPolicy.remainingSeconds(session, at: now), 960)
    }

    func testPausingTwiceDoesNotOpenTwoIntervals() throws {
        var session = makeSession(startAt: try instant(on: day, 14, 0), endAt: nil,
                                  at: try moment(on: day, 14, 0))
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 5))
        let once = session
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 6))
        XCTAssertEqual(session.pauses.count, 1)
        XCTAssertEqual(session, once, "已经在暂停中，再点一次不该叠出第二段")
    }

    func testResumingWhenNotPausedChangesNothing() throws {
        let session = makeSession(startAt: try instant(on: day, 14, 0), endAt: nil,
                                  at: try moment(on: day, 14, 0))
        XCTAssertEqual(FocusPolicy.resume(session, at: try moment(on: day, 14, 5)), session)
    }

    /// 暂停不改变名义锚点，但提醒要按挪过的终点排期，否则会提前响。
    func testEffectiveEndMovesLaterByThePausedTime() throws {
        var session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: try moment(on: day, 14, 0))
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 10))
        session = FocusPolicy.resume(session, at: try moment(on: day, 14, 15))

        let now = try moment(on: day, 14, 20)
        let effective = try XCTUnwrap(FocusPolicy.effectiveEnd(session, at: now))
        XCTAssertEqual(effective, try moment(on: day, 14, 35),
                       "暂停 5 分钟，终点就往后挪 5 分钟，提醒不能还按 14:30 排")
        XCTAssertEqual(session.anchor?.epoch, try moment(on: day, 14, 30),
                       "名义锚点不动，界面上的「到 14:30 结束」保持稳定")
    }

    // MARK: - 归零之后

    /// 刚好归零的那一瞬不算「超出」，否则数字会闪一下 `+00:00`。
    func testExactlyAtZeroStillReadsAsRemaining() throws {
        let session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: try moment(on: day, 14, 0))
        let onTheDot = try moment(on: day, 14, 30)

        XCTAssertEqual(FocusPolicy.remainingSeconds(session, at: onTheDot), 0)
        XCTAssertEqual(FocusPolicy.overrunSeconds(session, at: onTheDot), 0)
        XCTAssertNil(FocusPolicy.effectiveEnd(session, at: onTheDot), "已经到点，不必再排一次提醒")

        let snapshot = FocusPolicy.snapshot(session, at: onTheDot, stalenessThresholdHours: 3)
        XCTAssertFalse(snapshot.isOverrun)
        XCTAssertEqual(snapshot.primaryText, "00:00")
        XCTAssertEqual(snapshot.barDetailText, "剩余 00:00 · 到 14:30")
    }

    func testOverrunKeepsRunningAndFlipsToWarningText() throws {
        let session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: try moment(on: day, 14, 0))
        let now = try moment(on: day, 14, 33, 12)

        XCTAssertEqual(FocusPolicy.status(of: session), .running, "归零不是终点，也不自动结束")
        XCTAssertEqual(FocusPolicy.remainingSeconds(session, at: now), 0, "不出现负数")
        XCTAssertEqual(FocusPolicy.overrunSeconds(session, at: now), 192)

        let snapshot = FocusPolicy.snapshot(session, at: now, stalenessThresholdHours: 3)
        XCTAssertEqual(snapshot.primaryText, "+03:12")
        XCTAssertEqual(snapshot.secondaryText, "已超过计划时间")
        XCTAssertEqual(snapshot.barDetailText, "已超出 03:12")
        XCTAssertTrue(snapshot.isOverrun)
        XCTAssertEqual(try XCTUnwrap(snapshot.remainingFraction), 0)
        XCTAssertNil(FocusPolicy.effectiveEnd(session, at: now))
    }

    func testOverrunBeyondTheGraceIsTruncated() throws {
        let session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: try moment(on: day, 14, 0))

        // 差 3 分 12 秒：在 5 分钟宽限内，按实际记。
        let slightlyLate = try moment(on: day, 14, 33, 12)
        XCTAssertEqual(FocusPolicy.recordedSeconds(session, at: slightlyLate,
                                                   truncateAtAnchor: true, graceMinutes: 5), 1992)
        XCTAssertEqual(FocusPolicy.recordedMinutes(session, at: slightlyLate,
                                                   truncateAtAnchor: true, graceMinutes: 5), 33)

        // 拖了 10 分钟：截断到锚点，计划 30 分钟就记 30 分钟。
        let veryLate = try moment(on: day, 14, 40)
        XCTAssertEqual(FocusPolicy.recordedSeconds(session, at: veryLate,
                                                   truncateAtAnchor: true, graceMinutes: 5), 1800)
        XCTAssertEqual(FocusPolicy.recordedMinutes(session, at: veryLate,
                                                   truncateAtAnchor: true, graceMinutes: 5), 30)

        // 关掉截断就照实记。
        XCTAssertEqual(FocusPolicy.recordedMinutes(session, at: veryLate,
                                                   truncateAtAnchor: false, graceMinutes: 5), 40)
    }

    func testStopwatchIsNeverTruncated() throws {
        let session = makeSession(startAt: try instant(on: day, 14, 0), endAt: nil,
                                  at: try moment(on: day, 14, 0))
        let now = try moment(on: day, 16, 0)
        XCTAssertEqual(FocusPolicy.recordedMinutes(session, at: now,
                                                   truncateAtAnchor: true, graceMinutes: 5), 120)
    }

    func testVeryShortSessionStillRecordsOneMinute() throws {
        let session = makeSession(startAt: try instant(on: day, 14, 0), endAt: nil,
                                  at: try moment(on: day, 14, 0))
        let now = try moment(on: day, 14, 0, 10)
        XCTAssertEqual(FocusPolicy.recordedMinutes(session, at: now,
                                                   truncateAtAnchor: true, graceMinutes: 5), 1,
                       "不足一分钟记一分钟，避免写出 0 分钟的记录")
    }

    // MARK: - 跨天

    func testOvernightSessionCountsStraightThrough() throws {
        let start = try instant(on: day, 23, 0)
        let end = try instant(on: nextDay, 0, 30)
        let now = try moment(on: day, 23, 0)
        let session = makeSession(startAt: start, endAt: end, at: now)

        XCTAssertEqual(session.plannedMinutes, 90)
        XCTAssertEqual(session.plannedSeconds.map { FocusPolicy.clockText($0) }, "1:30:00")

        let midnight = try moment(on: nextDay, 0, 0)
        XCTAssertEqual(FocusPolicy.elapsedSeconds(session, at: midnight), 3600)
        XCTAssertEqual(FocusPolicy.remainingSeconds(session, at: midnight), 1800)

        let snapshot = FocusPolicy.snapshot(session, at: midnight, stalenessThresholdHours: 3)
        XCTAssertEqual(snapshot.primaryText, "30:00")
        XCTAssertEqual(snapshot.secondaryText, "到 00:30 结束")
        XCTAssertEqual(snapshot.planLabel, "计划 90 分钟")
    }

    // MARK: - 时钟回拨

    func testRewoundClockDoesNotProduceNegativeNumbers() throws {
        let session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: try moment(on: day, 14, 0))
        let rewound = try moment(on: day, 13, 50)

        XCTAssertEqual(FocusPolicy.elapsedSeconds(session, at: rewound), 0)
        XCTAssertEqual(FocusPolicy.pausedSeconds(session, at: rewound), 0)
        XCTAssertEqual(FocusPolicy.overrunSeconds(session, at: rewound), 0)

        let snapshot = FocusPolicy.snapshot(session, at: rewound, stalenessThresholdHours: 3)
        XCTAssertEqual(try XCTUnwrap(snapshot.remainingFraction), 1,
                       "比例封顶在 1，不允许画出一圈以外的进度")
        XCTAssertEqual(snapshot.primaryText, "40:00")
    }

    func testRewoundClockDoesNotInflateAPauseInterval() throws {
        var session = makeSession(startAt: try instant(on: day, 14, 0), endAt: nil,
                                  at: try moment(on: day, 14, 0))
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 10))
        session = FocusPolicy.resume(session, at: try moment(on: day, 14, 5))

        let last = try XCTUnwrap(session.pauses.last)
        XCTAssertEqual(last.startedAt, last.endedAt, "倒着走的区间按零长度收尾")
        XCTAssertEqual(FocusPolicy.pausedSeconds(session, at: try moment(on: day, 14, 20)), 0)
    }

    // MARK: - 久置提示

    func testStaleWhilePaused() throws {
        var session = makeSession(startAt: try instant(on: day, 14, 0), endAt: nil,
                                  at: try moment(on: day, 14, 0))
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 0))

        XCTAssertNil(FocusPolicy.staleness(session, at: try moment(on: day, 16, 59),
                                           thresholdHours: 3), "不到阈值不打扰")
        let stale = try XCTUnwrap(FocusPolicy.staleness(session, at: try moment(on: day, 17, 0),
                                                        thresholdHours: 3))
        XCTAssertEqual(stale, .paused(hours: 3))
        XCTAssertEqual(stale.message, "这次计时已经暂停 3 小时，是结束记录还是放弃？")
    }

    func testStaleAfterLongOverrun() throws {
        let session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: try moment(on: day, 14, 0))
        let snapshot = FocusPolicy.snapshot(session, at: try moment(on: day, 17, 35),
                                            stalenessThresholdHours: 3)
        XCTAssertEqual(snapshot.staleness, .overrun(hours: 3))
        XCTAssertEqual(snapshot.staleness?.message,
                       "这次计时已经超出计划时间 3 小时，是结束记录还是放弃？")
    }

    func testDisabledThresholdNeverReportsStaleness() throws {
        var session = makeSession(startAt: try instant(on: day, 14, 0), endAt: nil,
                                  at: try moment(on: day, 14, 0))
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 0))
        XCTAssertNil(FocusPolicy.staleness(session, at: try moment(on: day, 20, 0), thresholdHours: 0))
    }

    // MARK: - 文案

    func testClockTextSwitchesFormatAtOneHour() {
        XCTAssertEqual(FocusPolicy.clockText(0), "00:00")
        XCTAssertEqual(FocusPolicy.clockText(59), "00:59")
        XCTAssertEqual(FocusPolicy.clockText(760), "12:40")
        XCTAssertEqual(FocusPolicy.clockText(3600), "1:00:00")
        XCTAssertEqual(FocusPolicy.clockText(3723), "1:02:03")
        XCTAssertEqual(FocusPolicy.clockText(-30), "00:00", "负数按 0 处理")
    }

    func testDiffTagComparesAgainstThePlan() {
        XCTAssertEqual(FocusPolicy.diffTag(recordedMinutes: 30, plannedMinutes: 30), "与计划一致")
        XCTAssertEqual(FocusPolicy.diffTag(recordedMinutes: 40, plannedMinutes: 30), "比计划多 10 分钟")
        XCTAssertEqual(FocusPolicy.diffTag(recordedMinutes: 25, plannedMinutes: 30), "比计划少 5 分钟")
        XCTAssertNil(FocusPolicy.diffTag(recordedMinutes: 40, plannedMinutes: nil),
                     "正计时没有可比的一方，不出差异标签")
    }

    func testStatusWithoutASessionIsNotStarted() {
        XCTAssertEqual(FocusPolicy.status(of: nil), .notStarted)
        XCTAssertEqual(FocusPolicy.Status.notStarted.displayName, "未开始")
        XCTAssertEqual(FocusPolicy.Status.running.displayName, "计时中")
        XCTAssertEqual(FocusPolicy.Status.paused.displayName, "已暂停")
    }

    /// 会话要落本机供冷启动恢复，编解码必须无损。
    func testSessionSurvivesEncoding() throws {
        var session = makeSession(startAt: try instant(on: day, 14, 0),
                                  endAt: try instant(on: day, 14, 30), at: try moment(on: day, 14, 0))
        session = FocusPolicy.pause(session, at: try moment(on: day, 14, 10))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(FocusPolicy.Session.self,
                                          from: try encoder.encode(session))
        XCTAssertEqual(restored, session)
        XCTAssertTrue(restored.isPaused)
        XCTAssertEqual(FocusPolicy.remainingSeconds(restored, at: try moment(on: day, 14, 15)),
                       FocusPolicy.remainingSeconds(session, at: try moment(on: day, 14, 15)))
    }
}
