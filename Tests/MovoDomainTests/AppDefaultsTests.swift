import Foundation
import XCTest
import MovoKit

/// `Config/Defaults.json` 是「开工时固定」的产品参数唯一来源，`AppDefaults.fallback` 是资源缺失时的兜底。
/// 两者必须一致，否则同一份构建会因为「有没有读到资源」而表现不同。
///
/// 这里也要守住一件外面看不出来的事：资源读不到、或 JSON 里的键名写错时，
/// `ConfigLoader.loadDefaults()` 都会静默退回 `.fallback`，不报任何错。
/// 所以本文件不用「加载器返回了什么」自证，而是直接解码捆绑文件，让解码失败就是测试失败。
final class AppDefaultsTests: XCTestCase {
    private func bundledDefaultsData() throws -> Data {
        let url = try XCTUnwrap(ConfigLoader.resourceURL(named: "Defaults", extension: "json",
                                                         in: .movoResources),
                                "Config/Defaults.json 应当跟着 MovoKit 一起打包")
        return try Data(contentsOf: url)
    }

    private func bundledObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try bundledDefaultsData()) as? [String: Any])
    }

    /// 加载器找不到文件就会退回兜底，表现得和「配置没生效」一模一样。先钉住它找得到。
    func testLoaderResolvesTheBundledResources() {
        XCTAssertNotNil(ConfigLoader.resourceURL(named: "Defaults", extension: "json", in: .movoResources),
                        "加载器要能找到 Config/Defaults.json，否则改了 JSON 也不生效")
        XCTAssertNotNil(ConfigLoader.resourceURL(named: "ModelsCatalog", extension: "json", in: .movoResources))
    }

    func testBundledDefaultsMatchTheBuiltInFallback() throws {
        let decoded = try JSONDecoder().decode(AppDefaults.self, from: try bundledDefaultsData())
        XCTAssertEqual(decoded, AppDefaults.fallback,
                       "JSON 与内置兜底要一致：不一致说明要么键名写错，要么兜底值忘了同步")
    }

    func testFocusSectionCarriesTheExpectedValues() throws {
        let decoded = try JSONDecoder().decode(AppDefaults.self, from: try bundledDefaultsData())
        XCTAssertTrue(decoded.focus.remindAtEnd)
        XCTAssertTrue(decoded.focus.truncateDurationAtAnchor)
        XCTAssertEqual(decoded.focus.truncateGraceMinutes, 5)
        XCTAssertEqual(decoded.focus.staleSessionHours, 3)
    }

    /// 旧配置里没有 `focus` 段时退回默认值即可，不该把用户调好的其他段一起丢掉。
    func testMissingFocusSectionKeepsTheRestOfTheConfig() throws {
        var object = try bundledObject()
        object.removeValue(forKey: "focus")
        object["undo_steps"] = 9
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppDefaults.self, from: data)
        XCTAssertEqual(decoded.focus, AppDefaults.Focus(), "缺段时用内置默认")
        XCTAssertEqual(decoded.undoSteps, 9, "少一段不该让整份配置退到兜底")
    }
}
