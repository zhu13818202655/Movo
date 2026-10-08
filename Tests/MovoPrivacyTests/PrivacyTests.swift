//
//  PrivacyTests.swift
//  MovoPrivacyTests
//
//  隐私与全局 AI 测试：
//  - 输入原文原样发送，不再按关键词拆分或拦截；
//  - 全局 AI 开关关闭时不发网络请求；
//  - Key 仅保存在 Keychain，且严格脱敏；
//  - 已归档计划不进入上下文。
//

import XCTest
import MovoKit

final class PrivacyTests: XCTestCase {

    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private let today = DateOnly(y: 2026, m: 9, d: 28, sourceTZ: "Asia/Shanghai")

    // MARK: - 原文原样发送

    func testTextIsSentAsIsWithoutKeywordFiltering() {
        let plan = Plan(name: "健身计划", kind: .improvement, category: .health)
        let raw = "最近三天需要加大运动量，体重目标是 70 公斤。"
        let input = AIContextBuilder.build(
            sendableText: raw,
            today: today,
            timeZone: tz,
            plans: [plan],
            tasksByPlan: [:],
            stagesByPlan: [:],
            metricsByPlan: [:],
            occurrencesByTask: [:],
            defaults: .fallback)

        XCTAssertEqual(input.text, raw, "输入原文必须原样发给模型，不按健康关键词拦截")
        XCTAssertTrue(input.allowedPlanIDs.contains(plan.id), "健康类计划也正常进入允许引用上下文")
    }

    // MARK: - 归档计划不进入上下文

    func testArchivedPlansAreExcludedFromContext() {
        var archived = Plan(name: "旧项目", kind: .delivery)
        archived.status = .archived
        let active = Plan(name: "当前项目", kind: .delivery)

        let input = AIContextBuilder.build(
            sendableText: "推进项目",
            today: today,
            timeZone: tz,
            plans: [archived, active],
            tasksByPlan: [:],
            stagesByPlan: [:],
            metricsByPlan: [:],
            occurrencesByTask: [:],
            defaults: .fallback)

        XCTAssertFalse(input.allowedPlanIDs.contains(archived.id), "已归档计划不得出现在允许列表中")
        XCTAssertTrue(input.allowedPlanIDs.contains(active.id))
        XCTAssertFalse(input.requestBodyJSONString().contains("旧项目"))
        XCTAssertTrue(input.requestBodyJSONString().contains("当前项目"))
    }

    // MARK: - 全局 AI 关闭时不发请求

    /// 记录 provider 被调用次数，用于证明「关闭 AI 就不会触达网络」。
    private final class CountingProposalProvider: AIProvider, @unchecked Sendable {
        let proposal: AIProposal
        private(set) var callCount = 0

        init(proposal: AIProposal) { self.proposal = proposal }

        var id: AIVendor { .deepseek }
        var displayName: String { "计数替身" }
        var currentModel: String { "deepseek-chat" }
        func availableModels() -> [ModelInfo] { [] }
        func testConnection() async throws { }

        func proposeOperations(_ input: AIInput) async throws -> AIProposal {
            callCount += 1
            return proposal
        }
    }

    @MainActor
    func testGlobalAIDisabledDoesNotSendRequest() async throws {
        let repo = InMemoryRepository()
        let store = DomainStore(repository: repo, clock: TravelClock(today.noon),
                                timeZoneProvider: FixedTimeZoneProvider(identifier: tz.identifier),
                                deviceIDProvider: FixedDeviceIDProvider("privacy-test"),
                                defaults: .fallback)
        let created = try await store.execute(ProcessCapture(rawText: "明天跑步五公里"))
        let captureID = try XCTUnwrap(created.entityID, "原文必须先落库，任何情况下都不丢")

        let provider = CountingProposalProvider(proposal: AIProposal(items: [
            AIProposalItem(span: [], action: .createTask,
                           task: AIProposalTask(title: "跑步五公里", startAt: "2026-09-29"),
                           confidence: 0.9)
        ]))
        let request = ProposalRequest(captureID: captureID, rawText: "明天跑步五公里",
                                      today: today, timeZone: tz, deviceId: "privacy-test",
                                      plans: [], globalAIEnabled: false)
        let preparation = await ProposalService(provider: provider, defaults: .fallback).prepare(request)

        XCTAssertTrue(preparation.skippedCloudCall, "全局 AI 关闭时必须跳过云调用")
        XCTAssertEqual(provider.callCount, 0, "全局 AI 关闭时不得调用任何模型服务")
        XCTAssertNotNil(preparation.error, "应记录 AI 已关闭并保留原文的提示")
        XCTAssertNil(preparation.proposal, "跳过调用时不应产出提案")

        let capture = await repo.capture(captureID)
        XCTAssertEqual(capture?.rawText, "明天跑步五公里", "原文完好保留在仓库中")
    }

    // MARK: - Key 隔离与脱敏（AC24）

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
