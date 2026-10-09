import Foundation
import XCTest
import MovoKit

/// AI 整理路径上的重复块：结束日期与每天时刻必须走到规则上。
/// 「从 10 月 9 号到 11 月 9 号每天早上 6:30 跳绳」这条输入曾经只剩频率——
/// 结束日期被写进任务 end_at 却丢了规则窗口，于是显示成「没有截止时间、无限期重复」。
@MainActor
final class AIRecurrenceWindowTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private var day: DateOnly { DateOnly(iso8601DateString: "2026-10-08", sourceTZ: zone.identifier)! }

    private func store(_ repository: InMemoryRepository = InMemoryRepository()) -> DomainStore {
        DomainStore(repository: repository, clock: TravelClock(day.noon),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: zone.identifier),
                    deviceIDProvider: FixedDeviceIDProvider("ai-recurrence"))
    }

    private func input(_ text: String) -> AIInput {
        AIContextBuilder.build(sendableText: text, today: day, timeZone: zone, plans: [],
                               tasksByPlan: [:], stagesByPlan: [:], metricsByPlan: [:],
                               occurrencesByTask: [:], defaults: .fallback)
    }

    private func validate(_ proposal: AIProposal, text: String) -> ValidatedProposal {
        ProposalValidator.validate(proposal: proposal, input: input(text), plans: [],
                                   tasks: [:], metrics: [:], occurrences: [:], today: day, timeZone: zone,
                                   defaults: .fallback, deviceId: "ai-recurrence", captureID: nil, source: .ai)
    }

    // MARK: - 原文 → 预览 → 落库

    func testWindowAndDailyTimeSurviveTheWholeAIPath() async throws {
        let text = "从10月9号到十一月9号每天早上6:30跳绳 30分钟"
        let proposal = try XCTUnwrap(AIProposalCoding.decode("""
        {"items":[{"action":"create_task","source_span":"\(text)","span":[0,\(text.count)],
        "task":{"title":"跳绳","start_at":"2026-10-09","end_at":"2026-11-09",
        "recurrence":{"pattern":"daily","effective_from":"2026-10-09",
        "effective_until":"2026-11-09","daily_start":"06:30"}}}]}
        """))

        let validated = validate(proposal, text: text)
        XCTAssertTrue(validated.issues.isEmpty, "\(validated.issues.map(\.reasons))")
        let pending = try XCTUnwrap(validated.needsConfirmation.first)
        // 预览要让人看见「到哪一天为止、每天几点」，而不是一行裸 pattern
        let line = try XCTUnwrap(pending.changeSummary.first { $0.title == "重复" })
        XCTAssertEqual(line.changeText, "每天 · 06:30 · 10月9日–11月9日")

        let commands = ProposalValidator.materializeBatch(validated.needsConfirmation, timeZone: zone,
                                                          today: day, source: .ai, captureID: nil)
        let create = try XCTUnwrap(commands.compactMap { $0 as? CreateTask }.first)
        XCTAssertEqual(create.recurrence?.pattern, .daily)
        XCTAssertEqual(create.recurrence?.effectiveFrom.iso8601DateString, "2026-10-09")
        XCTAssertEqual(create.recurrence?.effectiveUntil?.iso8601DateString, "2026-11-09",
                       "结束日期必须落在规则上，否则会变成无限期重复")
        XCTAssertEqual(create.recurrence?.dailyStart?.displayString, "06:30")
        XCTAssertEqual(create.startAt?.dateOnly.iso8601DateString, "2026-10-09")
        XCTAssertEqual(create.endAt?.dateOnly.iso8601DateString, "2026-11-09",
                       "模板窗口与规则窗口保持同一天，不再出现「规则重复到某天、任务却没有截止时间」")

        // 落库后：窗口内每天有一次，窗口后不再有
        let repository = InMemoryRepository()
        let store = self.store(repository)
        let batch = try await store.executeBatchAllowingPartial(BatchInput(commands: commands))
        XCTAssertEqual(batch.appliedCount, commands.count)
        let taskID = try XCTUnwrap(create.entityID)
        let lastDay = DateOnly(iso8601DateString: "2026-11-09", sourceTZ: zone.identifier)!
        let nextDay = DateOnly(iso8601DateString: "2026-11-10", sourceTZ: zone.identifier)!
        let inWindow = await store.today(lastDay)
        let afterWindow = await store.today(nextDay)
        XCTAssertEqual(inWindow.focus.count, 1, "结束日当天仍有一次")
        XCTAssertTrue(afterWindow.routine.isEmpty)
        XCTAssertTrue(afterWindow.focus.isEmpty, "结束日之后不再重复")
        let rule = await store.repository.rule(forTask: taskID)
        XCTAssertEqual(rule?.effectiveUntil?.iso8601DateString, "2026-11-09")
    }

    func testDailyTimeFallsBackToTaskStartAtWhenRuleOmitsIt() async throws {
        // 模型常把「早上 6:30」只写进 start_at —— 兜底仍要落到规则的每天时刻上
        let text = "每天早上6:30读半小时书"
        let proposal = try XCTUnwrap(AIProposalCoding.decode("""
        {"items":[{"action":"create_task","source_span":"\(text)","span":[0,\(text.count)],
        "task":{"title":"读书","start_at":"2026-10-08T06:30:00+08:00",
        "recurrence":{"pattern":"daily","effective_from":"2026-10-08"}}}]}
        """))

        let validated = validate(proposal, text: text)
        XCTAssertTrue(validated.issues.isEmpty, "\(validated.issues.map(\.reasons))")
        let commands = ProposalValidator.materializeBatch(validated.needsConfirmation, timeZone: zone,
                                                          today: day, source: .ai, captureID: nil)
        let create = try XCTUnwrap(commands.compactMap { $0 as? CreateTask }.first)
        XCTAssertEqual(create.recurrence?.dailyStart?.displayString, "06:30")
    }

    // MARK: - 写不全的重复块进收件箱，不静默降级

    func testUnparsableWindowGoesToInboxInsteadOfBecomingEndless() async throws {
        let text = "每天跳绳到11月9日"
        let proposal = try XCTUnwrap(AIProposalCoding.decode("""
        {"items":[{"action":"create_task","source_span":"\(text)","span":[0,\(text.count)],
        "task":{"title":"跳绳","recurrence":{"pattern":"daily","effective_from":"2026-10-08",
        "effective_until":"11月9日"}}}]}
        """))
        let result = validate(proposal, text: text)
        XCTAssertTrue(result.needsConfirmation.isEmpty, "结束日期认不出来时不能当成无限期重复悄悄存下")
        XCTAssertEqual(result.issues.first?.reasons,
                       [.structureViolation("重复的结束日期无法识别，请确认后重试。")])
    }

    func testReversedWindowGoesToInbox() async throws {
        let text = "从11月9日到10月9日每天跳绳"
        let proposal = try XCTUnwrap(AIProposalCoding.decode("""
        {"items":[{"action":"create_task","source_span":"\(text)","span":[0,\(text.count)],
        "task":{"title":"跳绳","recurrence":{"pattern":"daily","effective_from":"2026-11-09",
        "effective_until":"2026-10-09"}}}]}
        """))
        let result = validate(proposal, text: text)
        XCTAssertTrue(result.needsConfirmation.isEmpty)
        XCTAssertEqual(result.issues.first?.reasons,
                       [.structureViolation("重复的结束日期早于开始日期。")])
    }

    func testUnparsableDailyTimeGoesToInbox() async throws {
        let text = "每天早上六点半跳绳"
        let proposal = try XCTUnwrap(AIProposalCoding.decode("""
        {"items":[{"action":"create_task","source_span":"\(text)","span":[0,\(text.count)],
        "task":{"title":"跳绳","recurrence":{"pattern":"daily","effective_from":"2026-10-08",
        "daily_start":"六点半"}}}]}
        """))
        let result = validate(proposal, text: text)
        XCTAssertTrue(result.needsConfirmation.isEmpty)
        XCTAssertEqual(result.issues.first?.reasons,
                       [.structureViolation("重复的每次开始时刻无法识别，请确认后重试。")])
    }

    // MARK: - 调整已有重复行动

    func testSetRecurrenceCarriesWindowAndDailyTime() async throws {
        let store = store()
        let created = try await store.execute(CreateTask(title: "跑步"))
        let taskID = try XCTUnwrap(created.entityID)
        try await store.execute(CreateRecurrence(taskID: taskID, pattern: .daily, effectiveFrom: day))
        let loaded = await store.repository.rule(forTask: taskID)
        let rule = try XCTUnwrap(loaded)

        let item = AIProposalItem(
            sourceSpan: "改成每周三次", span: [0, 6], action: .setRecurrence,
            task: AIProposalTask(candidateTaskId: taskID.uuidString),
            recurrence: AIRecurrence(pattern: "weeklyCount", count: 3,
                                     effectiveFrom: "2026-10-08", effectiveUntil: "2026-11-09",
                                     dailyStart: "07:15"))
        let pending = PendingProposal(id: item.id, item: item,
                                      affectedSummary: "跑步", kind: .recurrenceChange)
        let commands = ProposalValidator.materializeBatch([pending], rules: [taskID: rule],
                                                          timeZone: zone, today: day, source: .ai, captureID: nil)
        let change = try XCTUnwrap(commands.compactMap { $0 as? ChangeRecurrence }.first)
        XCTAssertEqual(change.pattern, .weeklyCount)
        XCTAssertEqual(change.weeklyCount, 3)
        XCTAssertTrue(change.updatesEffectiveUntil, "用户明确给了结束日期，要覆盖原来的窗口")
        XCTAssertEqual(change.effectiveUntil?.iso8601DateString, "2026-11-09")
        XCTAssertTrue(change.updatesDailyTimes)
        XCTAssertEqual(change.dailyStart?.displayString, "07:15")
    }

    func testSetRecurrenceWithoutWindowKeepsExistingEndDate() async throws {
        let store = store()
        let created = try await store.execute(CreateTask(title: "跑步"))
        let taskID = try XCTUnwrap(created.entityID)
        try await store.execute(CreateRecurrence(taskID: taskID, pattern: .daily, effectiveFrom: day,
                                                 effectiveUntil: day.adding(days: 30)))
        let loaded = await store.repository.rule(forTask: taskID)
        let rule = try XCTUnwrap(loaded)

        let item = AIProposalItem(
            sourceSpan: "改成每周三次", span: [0, 6], action: .setRecurrence,
            task: AIProposalTask(candidateTaskId: taskID.uuidString),
            recurrence: AIRecurrence(pattern: "weeklyCount", count: 3, effectiveFrom: "2026-10-08"))
        let pending = PendingProposal(id: item.id, item: item,
                                      affectedSummary: "跑步", kind: .recurrenceChange)
        let commands = ProposalValidator.materializeBatch([pending], rules: [taskID: rule],
                                                          timeZone: zone, today: day, source: .ai, captureID: nil)
        let change = try XCTUnwrap(commands.compactMap { $0 as? ChangeRecurrence }.first)
        XCTAssertFalse(change.updatesEffectiveUntil, "没提到结束日期时不能顺手清掉")
        XCTAssertFalse(change.updatesDailyTimes, "没提到时刻时不能顺手清掉")
    }
}
