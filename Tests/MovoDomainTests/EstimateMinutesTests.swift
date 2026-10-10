import Foundation
import XCTest
import MovoKit

/// 预计投入的取值规则。
///
/// 领域层不校验这个字段，界面层是唯一的关口，而它同时是「专注计时」推导倒计时长度的
/// 最后一个来源，所以三种输入必须分得清楚：
/// 空串是「未设置」、正整数是有效值、其余是非法输入。
/// 把非法输入并进「未设置」会让打错字变成静默清空。
final class EstimateMinutesTests: XCTestCase {
    func testEmptyMeansUnset() {
        XCTAssertEqual(EstimateMinutes.parse(""), .unset)
        XCTAssertEqual(EstimateMinutes.parse("   "), .unset)
        XCTAssertNil(EstimateMinutes.parse("").value)
        XCTAssertNil(EstimateMinutes.parse("").invalidMessage)
    }

    func testPositiveIntegerIsValid() {
        XCTAssertEqual(EstimateMinutes.parse("30"), .minutes(30))
        XCTAssertEqual(EstimateMinutes.parse(" 30 "), .minutes(30), "两端空白不该让输入作废")
        XCTAssertEqual(EstimateMinutes.parse("1"), .minutes(1))
        XCTAssertEqual(EstimateMinutes.parse("90").value, 90)
    }

    func testNonNumericIsRejected() {
        for input in ["半小时", "30m", "30.5", "1e3", "三十分钟"] {
            let parsed = EstimateMinutes.parse(input)
            XCTAssertTrue(parsed.isInvalid, "「\(input)」不是整数分钟，应当被拒绝")
            XCTAssertNil(parsed.value, "被拒绝的输入不能顺手当成未设置写进去")
            XCTAssertNotNil(parsed.invalidMessage)
        }
    }

    func testNonPositiveIsRejected() {
        for input in ["0", "-30"] {
            let parsed = EstimateMinutes.parse(input)
            XCTAssertTrue(parsed.isInvalid, "「\(input)」不是有意义的投入时长")
            XCTAssertNil(parsed.value)
        }
    }

    func testEditingTextRoundTrips() {
        XCTAssertEqual(EstimateMinutes.text(for: nil), "", "未设置时给空串，由占位符表达")
        XCTAssertEqual(EstimateMinutes.text(for: 30), "30")
        for minutes in [1, 25, 30, 90, 1440] {
            XCTAssertEqual(EstimateMinutes.parse(EstimateMinutes.text(for: minutes)), .minutes(minutes))
        }
        XCTAssertEqual(EstimateMinutes.parse(EstimateMinutes.text(for: nil)), .unset)
    }

    func testDisplayTextMatchesOtherTimeRows() {
        XCTAssertEqual(EstimateMinutes.displayText(for: nil), "未设置",
                       "与「开始时间 / 结束时间」两行的未设置写法一致")
        XCTAssertEqual(EstimateMinutes.displayText(for: 30), "30 分钟")
        XCTAssertEqual(EstimateMinutes.displayText(for: 90), "90 分钟")
    }
}
