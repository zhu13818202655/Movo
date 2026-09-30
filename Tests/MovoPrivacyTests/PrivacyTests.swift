//
//  PrivacyTests.swift
//  MovoPrivacyTests
//
//  12.1 Privacy PT：6.3 隐私拆分 + 6.4 请求拦截 + 8.1 Key 隔离。
//  覆盖 AC16（云请求 0 敏感泄漏）与 AC24（Key 永不离开 Keychain），
//  以及 6.2 本地确定性直执（敏感内容不发云、可撤销）。
//

import XCTest
import MovoKit

final class PrivacyTests: XCTestCase {

    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private let today = DateOnly(y: 2026, m: 9, d: 28, sourceTZ: "Asia/Shanghai")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var healthKeywords: [String] {
        ["体重", "跑步", "血压", "睡眠", "体检"]
    }

    // MARK: - 6.3 句级裁决

    func testSafeSentenceIsSendable() {
        let plan = Plan(name: "考研复习", kind: .delivery, category: .study)
        let result = PrivacySplitter.split(text: "复习英语单词。",
                                           plans: [plan],
                                           healthKeywords: healthKeywords)

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.verdict, .safe)
        XCTAssertFalse(result.hasSensitiveContent)
        XCTAssertFalse(result.shouldSkipCloudCall)
        XCTAssertEqual(result.sendableText, "复习英语单词。")
    }

    func testHealthKeywordSentenceStaysLocal() {
        let result = PrivacySplitter.split(text: "今天体重 70 公斤。",
                                           plans: [],
                                           healthKeywords: healthKeywords)

        XCTAssertEqual(result.segments.first?.verdict, .sensitive)
        XCTAssertTrue(result.hasSensitiveContent)
        XCTAssertTrue(result.shouldSkipCloudCall, "无 safe 片段 → 不调用云")
        XCTAssertTrue(result.sendableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(result.localOnlySpans.count, 1)
    }

    func testRestrictedPlanNameIsSensitive() {
        // cloudAIEnabled=false
        let plan = Plan(name: "私密项目", kind: .delivery, category: .work, cloudAIEnabled: false)
        let result = PrivacySplitter.split(text: "今天推进私密项目。",
                                           plans: [plan],
                                           healthKeywords: healthKeywords)

        XCTAssertEqual(result.segments.first?.verdict, .sensitive)
        XCTAssertEqual(result.segments.first?.matchedRestrictedPlanIds, [plan.id])
        XCTAssertTrue(result.shouldSkipCloudCall)
    }

    func testMixedSentenceSendsOnlyNonRestrictedClause() {
        // 6.3：mixed 需同时满足 hitRestricted（受限子句）与 hitOther（非受限计划信号）。
        let openPlan = Plan(name: "英语学习", kind: .delivery, category: .study,
                            contextPhrases: ["复习英语"])
        let result = PrivacySplitter.split(text: "今天体重 70 公斤，明天复习英语。",
                                           plans: [openPlan],
                                           healthKeywords: healthKeywords)

        let seg = result.segments.first
        XCTAssertEqual(seg?.verdict, .mixed)
        XCTAssertEqual(seg?.sendableSubSpans.isEmpty, false, "混合句必须给出可发送子句")
        XCTAssertFalse(result.localOnlySpans.isEmpty, "受限子句必须留本机")
        XCTAssertFalse(result.shouldSkipCloudCall)
        XCTAssertTrue(result.sendableText.contains("复习英语"))
        XCTAssertFalse(result.sendableText.contains("体重"))
    }

    /// 6.3 保守规则：仅有受限信号、其余子句未被任何「非受限计划信号」命中的句子，
    /// 不构成 hitOther → 整句按 sensitive 处理，绝不因为"不含已知关键词"就外发。
    func testRestrictedClauseWithoutOpenPlanSignalStaysSensitive() {
        let result = PrivacySplitter.split(text: "今天体重 70 公斤，明天复习英语。",
                                           plans: [],
                                           healthKeywords: healthKeywords)

        XCTAssertEqual(result.segments.first?.verdict, .sensitive)
        XCTAssertTrue(result.shouldSkipCloudCall)
        XCTAssertTrue(result.sendableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(result.segments.first?.sendableSubSpans.isEmpty ?? false)
    }

    func testEmptyTextProducesNothing() {
        let result = PrivacySplitter.split(text: "", plans: [], healthKeywords: healthKeywords)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertFalse(result.hasSensitiveContent)
        XCTAssertTrue(result.shouldSkipCloudCall)
        XCTAssertFalse(result.fellBackToLocalOnly)
    }

    // MARK: - 6.4 请求拦截：受限计划不得进入请求体（AC16）

    func testContextBuilderExcludesRestrictedPlans() {
        let restricted = Plan(name: "减脂", kind: .improvement, category: .health)
        let open = Plan(name: "考研复习", kind: .delivery, category: .study)

        let input = AIContextBuilder.build(
            sendableText: "复习英语单词",
            today: today, timeZone: tz,
            plans: [restricted, open],
            tasksByPlan: [:], stagesByPlan: [:], metricsByPlan: [:], occurrencesByTask: [:],
            defaults: .fallback)

        let body = input.requestBodyJSONString()
        XCTAssertFalse(body.contains("减脂"), "受限计划名称不得出现")
        XCTAssertFalse(body.contains(restricted.id.uuidString), "受限计划 id 不得出现")
        XCTAssertTrue(body.contains("考研复习"))
        XCTAssertTrue(input.allowedPlanIDs.contains(open.id))
        XCTAssertFalse(input.allowedPlanIDs.contains(restricted.id))

        // 发送前二次断言通过（AC16）
        let violations = AIContextBuilder.assertNoRestrictedContent(
            input: input, restrictedPlans: [restricted],
            restrictedTitles: [], restrictedKeywords: healthKeywords)
        XCTAssertTrue(violations.isEmpty)
    }

    func testAssertNoRestrictedContentDetectsLeak() {
        let restricted = Plan(name: "减脂", kind: .improvement, category: .health)
        let leaky = AIInput(locale: "zh-Hans", timezone: tz.identifier, today: "2026-09-28",
                            text: "今天给减脂计划打卡", plans: [], tasks: [],
                            instructions: "test")

        let violations = AIContextBuilder.assertNoRestrictedContent(
            input: leaky, restrictedPlans: [restricted],
            restrictedTitles: ["晨跑"], restrictedKeywords: healthKeywords)
        XCTAssertFalse(violations.isEmpty, "泄漏必须被断言捕获")
    }

    // MARK: - 6.2 本地确定直执：敏感内容不发云且可撤销

    func testLocalRouterCompletesRestrictedOccurrence() {
        let plan = Plan(name: "减脂", kind: .improvement, category: .health)
        let task = Task(planId: plan.id, title: "晨跑", isTemplate: true)
        let rule = RecurrenceRule(taskId: task.id, pattern: .daily, effectiveFrom: today)
        let occ = RecurrenceOccurrence(ruleId: rule.id, taskId: task.id, planId: plan.id,
                                       scheduledOn: today, status: .pending)

        let split = PrivacySplitResult(
            segments: [], sendableText: "", sendableSpans: [],
            localOnlySpans: [PrivacySpan(start: 0, end: 4, text: "晨跑完成")],
            hasSensitiveContent: true)

        let matches = LocalDirectRouter.route(privacy: split, plans: [plan], tasks: [task],
                                              occurrences: [occ], today: today, now: now)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.kind, .completeOccurrence)
        XCTAssertNotNil(matches.first?.command, "确定性匹配必须产出可撤销命令")
        XCTAssertEqual(matches.first?.matchedOccurrenceID, occ.id)
    }

    func testLocalRouterFallsBackToInbox() {
        let split = PrivacySplitResult(
            segments: [], sendableText: "", sendableSpans: [],
            localOnlySpans: [PrivacySpan(start: 0, end: 6, text: "随便写点什么")],
            hasSensitiveContent: true)

        let matches = LocalDirectRouter.route(privacy: split, plans: [], tasks: [],
                                              occurrences: [], today: today, now: now)

        XCTAssertEqual(matches.first?.kind, .unmatched)
        XCTAssertNil(matches.first?.command)
    }

    // MARK: - 8.1 Key 隔离（AC24）

    func testKeyMaskNeverRevealsBody() {
        let key = "sk-proj-abcdefghijklmnop1234"
        let masked = AIKeyFormat.mask(key)
        XCTAssertEqual(masked, "sk-…1234")
        XCTAssertFalse(masked.contains("abcdefghijklmnop"))
        XCTAssertTrue(AIKeyFormat.looksValid(key, vendor: .deepseek))
        XCTAssertFalse(AIKeyFormat.looksValid("short", vendor: .deepseek), "过短的 Key 一律预检不通过")
    }

    func testCustomProviderKeyValidationIsLenient() {
        // 自建服务的 Key 格式不可预知：只做长度预检，不要求前缀。
        XCTAssertTrue(AIKeyFormat.looksValid("local-token-12345678", vendor: .custom))
        XCTAssertFalse(AIKeyFormat.looksValid("abc", vendor: .custom))
        XCTAssertEqual(AIKeyFormat.mask("local-token-12345678"), "…5678")
    }

    func testKeyNeverEntersRequestBodyOrErrorLog() throws {
        let secret = "sk-proj-supersecretvalue0000"
        let store = InMemoryAIKeyStore(seed: [.deepseek: secret])
        XCTAssertEqual(store.key(vendor: .deepseek), secret, "Key 只应可由 KeyStore 读出")

        // 请求体不得含 Key
        let input = AIInput(locale: "zh-Hans", timezone: tz.identifier, today: "2026-09-28",
                            text: "复习英语", plans: [], tasks: [], instructions: "test")
        XCTAssertFalse(input.requestBodyJSONString().contains(secret))

        // 错误日志元数据不得含正文/Key（4.5）
        let error = MovoError.aiFailed(stage: .auth, cause: "http_401")
        let metadata = error.logMetadata.values.joined()
        XCTAssertFalse(metadata.contains(secret))
        XCTAssertTrue(metadata.contains("auth"))
    }
}
