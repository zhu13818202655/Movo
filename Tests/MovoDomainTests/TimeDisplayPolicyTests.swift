import Foundation
import XCTest
import MovoKit

/// 时间点的展示上下文。同一条时间在不同页面上要表达的信息量不一样：
/// 「今日」筛选里整页都是今天，再显示一遍日期是冗余；计划树、任务详情里则必须给完整日期。
///
/// 原则（本文件就是这条原则的回归网）：
/// **只省略参考日当天的日期，任何仍然有信息量的日期照常显示。**
/// 逾期项不写「昨天」而直接写日期——用户需要知道它拖了多久，而不是「它不是今天」。
final class TimeDisplayPolicyTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!

    /// 2026-10-08，周四。
    private var today: DateOnly { DateOnly(iso8601DateString: "2026-10-08", sourceTZ: zone.identifier)! }
    private var tomorrow: DateOnly { today.adding(days: 1) }
    private var yesterday: DateOnly { today.adding(days: -1) }
    /// 一周后：超出「今天 / 明天 / 昨天」能覆盖的范围。
    private var laterDay: DateOnly { today.adding(days: 7) }

    private func instant(_ day: DateOnly, _ hour: Int, _ minute: Int = 0) throws -> TimePoint {
        try XCTUnwrap(TimePoint.makeInstant(on: day, at: TimeOfDay(hour: hour, minute: minute), in: zone))
    }

    private func item(start: TimePoint?, end: TimePoint?) -> TodayItem {
        let task = MovoKit.Task(title: "写周报", startAt: start, endAt: end)
        return TodayItem(id: "floating-\(task.id)", body: .floating(task: task), section: .focus,
                         startAt: start, endAt: end)
    }

    // MARK: - 绝对上下文（缺省）：完整日期，一个字都不省

    func testAbsoluteKeepsFullDate() throws {
        XCTAssertEqual(TimePoint.day(today).displayString(in: .absolute), "10月8日")
        XCTAssertEqual(try instant(today, 14, 0).displayString(in: .absolute), "10月8日 14:00")
        XCTAssertEqual(try instant(tomorrow, 9, 30).displayString(in: .absolute), "10月9日 09:30")
        XCTAssertEqual(try instant(laterDay, 9, 0).displayString(in: .absolute), "10月15日 09:00")
    }

    // MARK: - 今日上下文：只省略「今天」这个日期

    func testTodayContextDropsOnlyTheReferenceDay() throws {
        let context = TimeDisplayContext.today(today)
        XCTAssertEqual(try instant(today, 14, 0).displayString(in: context), "14:00",
                       "整页都是今天，时刻才是用户要看的")
        XCTAssertEqual(try instant(today, 8, 0).displayString(in: context), "08:00")
    }

    func testTodayContextKeepsOtherDates() throws {
        let context = TimeDisplayContext.today(today)
        XCTAssertEqual(try instant(tomorrow, 9, 30).displayString(in: context), "明天 09:30")
        XCTAssertEqual(try instant(laterDay, 9, 0).displayString(in: context), "10月15日 09:00")
    }

    func testOverdueShowsDateNotYesterday() throws {
        let context = TimeDisplayContext.today(today)
        XCTAssertEqual(try instant(yesterday, 17, 0).displayString(in: context), "10月7日 17:00",
                       "逾期项要说清楚拖到了哪一天，「昨天」会把信息量压掉")
    }

    func testDayGranularityStillSaysToday() {
        XCTAssertEqual(TimePoint.day(today).displayString(in: .today(today)), "今天",
                       "只有日期没有时刻时，省略日期就什么都不剩了，所以保留措辞")
        XCTAssertEqual(TimePoint.day(tomorrow).displayString(in: .today(today)), "明天")
    }

    /// 参考日是参数而不是「今天」，所以同一条时间在不同参考日下说法不同。
    func testTodayContextIsRelativeToItsReferenceDay() throws {
        XCTAssertEqual(try instant(today, 14, 0).displayString(in: .today(today)), "14:00")
        XCTAssertEqual(try instant(today, 14, 0).displayString(in: .today(tomorrow)), "10月8日 14:00")
        XCTAssertEqual(try instant(today, 14, 0).displayString(in: .today(yesterday)), "明天 14:00")
    }

    // MARK: - 邻近上下文：一周内的列表用「今天 / 明天 / 昨天」，但不省略日期

    func testNearbyContextUsesWordsButKeepsTheDate() throws {
        let context = TimeDisplayContext.nearby(today)
        XCTAssertEqual(try instant(today, 14, 0).displayString(in: context), "今天 14:00",
                       "「今天」和日期不是一回事：这里不锁定当天，仍要说明是哪天")
        XCTAssertEqual(try instant(tomorrow, 9, 30).displayString(in: context), "明天 09:30")
        XCTAssertEqual(try instant(yesterday, 17, 0).displayString(in: context), "昨天 17:00")
        XCTAssertEqual(try instant(laterDay, 9, 0).displayString(in: context), "10月15日 09:00",
                       "超出前后一天的都用绝对日期")
    }

    // MARK: - 行内时刻标签：只显示有时刻的那一端

    func testItemTimeTextShowsOnlyEndpointsWithClock() throws {
        let context = TimeDisplayContext.today(today)
        XCTAssertEqual(item(start: try instant(today, 8, 0), end: try instant(today, 9, 0))
            .timeText(in: context), "08:00–09:00")
        XCTAssertEqual(item(start: try instant(today, 8, 0), end: nil)
            .timeText(in: context), "08:00")
        XCTAssertEqual(item(start: nil, end: try instant(today, 9, 0))
            .timeText(in: context), "09:00 前", "只有截止时刻时读成「前」，不假装有开始")
        XCTAssertNil(item(start: nil, end: nil).timeText(in: context))
    }

    func testItemTimeTextKeepsDateOutsideToday() throws {
        XCTAssertEqual(item(start: try instant(today, 14, 0), end: nil).timeText(in: .absolute),
                       "10月8日 14:00")
        XCTAssertEqual(item(start: try instant(tomorrow, 9, 0), end: try instant(tomorrow, 10, 0))
            .timeText(in: .today(today)), "明天 09:00–10:00",
                       "两端同属明天，日期只出现一次")
    }

    /// 前缀跟着「较早且有时刻的那一端」走，否则跨天会出现「今天 → 明天」这种读不通的标签。
    func testItemTimeTextPrefixFollowsTheStartEndpoint() throws {
        XCTAssertEqual(item(start: try instant(today, 22, 0), end: try instant(tomorrow, 1, 0))
            .timeText(in: .today(today)), "22:00–01:00",
                       "起点在今天，前缀就该省掉，而不是被终点的「明天」拽走")
        XCTAssertEqual(item(start: try instant(tomorrow, 22, 0), end: try instant(laterDay, 1, 0))
            .timeText(in: .today(today)), "明天 22:00–01:00")
    }

    func testDayOnlyEndpointsProduceNoClockLabel() {
        let context = TimeDisplayContext.today(today)
        XCTAssertNil(item(start: .day(today), end: .day(today)).timeText(in: context),
                     "只有日期没有时刻时不产出行内时刻标签，避免和元信息里的日期重复")
        XCTAssertEqual(item(start: .day(today), end: try? instant(tomorrow, 9, 0))
            .timeText(in: context), "明天 09:00 前")
    }
}
