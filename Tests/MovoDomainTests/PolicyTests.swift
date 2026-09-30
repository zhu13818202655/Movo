//
//  PolicyTests.swift
//  MovoDomainTests
//
//  4.4 策略算法的纯函数单测：进度口径（AC07/AC19）、重复（AC13/AC20/AC22）、
//  依赖就绪派生（AC09 / REQ 09）、中文分词（5.3）。
//

import XCTest
import MovoKit

final class PolicyTests: XCTestCase {

    private let tzID = "Asia/Shanghai"

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DateOnly {
        DateOnly(y: y, m: m, d: d, sourceTZ: tzID)
    }

    private func task(_ id: UUID = UUID(), title: String, status: TaskStatus = .todo,
                      parentId: UUID? = nil, stageId: UUID? = nil, isTemplate: Bool = false,
                      dependencies: [UUID] = []) -> Task {
        Task(id: id, stageId: stageId, parentId: parentId, title: title,
             isTemplate: isTemplate, status: status, dependencyIDs: dependencies)
    }

    // MARK: - 交付型进度（AC07）

    func testDeliveryProgressCountsLeavesOnly() {
        let parent = UUID()
        // 父任务 + 3 个叶子，其中 2 个完成 → 2/3（父任务不进分母）
        let tasks = [
            task(parent, title: "季度汇报"),
            task(title: "收集数据", status: .done, parentId: parent),
            task(title: "写提纲", status: .done, parentId: parent),
            task(title: "成稿", parentId: parent)
        ]
        let (done, total) = ProgressPolicy.deliveryLeaves(in: tasks)
        XCTAssertEqual(done, 2)
        XCTAssertEqual(total, 3)
    }

    func testCancelledAndTemplateTasksAreExcluded() {
        let parent = UUID()
        let tasks = [
            task(parent, title: "父"),
            task(title: "完成项", status: .done, parentId: parent),
            task(title: "取消项", status: .cancelled, parentId: parent),
            task(title: "重复模板", parentId: parent, isTemplate: true)
        ]
        let (done, total) = ProgressPolicy.deliveryLeaves(in: tasks)
        XCTAssertEqual(done, 1)
        XCTAssertEqual(total, 1, "已取消与模板任务不进分母")
    }

    func testParentBecomesLeafWhenAllChildrenCancelled() {
        let parent = UUID()
        let tasks = [
            task(parent, title: "父"),
            task(title: "取消项", status: .cancelled, parentId: parent)
        ]
        let (_, total) = ProgressPolicy.deliveryLeaves(in: tasks)
        XCTAssertEqual(total, 1, "全部子任务被取消时父任务重新成为叶子")
    }

    // MARK: - 重复实例（AC13 / AC22）

    func testDailyRuleMaterializesEveryDayInRange() {
        let rule = RecurrenceRule(taskId: UUID(), pattern: .daily, effectiveFrom: day(2026, 9, 28))
        let days = RecurrencePolicy.plan(rule: rule,
                                        range: DateOnlyRange(lower: day(2026, 9, 28),
                                                             upper: day(2026, 10, 4)),
                                        plan: nil)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first, day(2026, 9, 28))
        XCTAssertEqual(days.last, day(2026, 10, 4))
    }

    func testRuleOnlyAppliesFromEffectiveFrom() {
        // AC22：频率调整只作用于生效日及之后
        let rule = RecurrenceRule(taskId: UUID(), pattern: .daily, effectiveFrom: day(2026, 10, 1))
        let days = RecurrencePolicy.plan(rule: rule,
                                        range: DateOnlyRange(lower: day(2026, 9, 28),
                                                             upper: day(2026, 10, 3)),
                                        plan: nil)
        XCTAssertEqual(days, [day(2026, 10, 1), day(2026, 10, 2), day(2026, 10, 3)],
                       "生效日之前的日期不实例化")
    }

    func testWeeklyCountProgressTreatsSkipsAsConsumed() {
        let rule = RecurrenceRule(taskId: UUID(), pattern: .weeklyCount, weeklyCount: 3,
                                  effectiveFrom: day(2026, 9, 21))
        let week = DateOnlyRange(lower: day(2026, 9, 21), upper: day(2026, 9, 27))
        let occurrences = [
            RecurrenceOccurrence(ruleId: rule.id, taskId: rule.taskId,
                                 occurredOn: day(2026, 9, 21), status: .done),
            RecurrenceOccurrence(ruleId: rule.id, taskId: rule.taskId,
                                 occurredOn: day(2026, 9, 23), status: .skipped)
        ]
        let progress = RecurrencePolicy.weeklyProgress(rule: rule, occurrences: occurrences,
                                                       week: week, today: day(2026, 9, 27))
        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.skipped, 1)
        XCTAssertEqual(progress.planned, 3)
        XCTAssertEqual(progress.unrecorded, 0, "周未结束不判未记录")
    }

    func testWeeklyCountExtraCompletionsAreKept() {
        let rule = RecurrenceRule(taskId: UUID(), pattern: .weeklyCount, weeklyCount: 2,
                                  effectiveFrom: day(2026, 9, 21))
        let week = DateOnlyRange(lower: day(2026, 9, 21), upper: day(2026, 9, 27))
        let occurrences = (21...24).map { d in
            RecurrenceOccurrence(ruleId: rule.id, taskId: rule.taskId,
                                 occurredOn: day(2026, 9, d), status: .done)
        }
        let progress = RecurrencePolicy.weeklyProgress(rule: rule, occurrences: occurrences,
                                                       week: week, today: day(2026, 9, 27))
        XCTAssertEqual(progress.done, 4, "超额完成保留记录，不丢数据")
        XCTAssertEqual(progress.extraDone, 2)
    }

    // MARK: - 依赖（AC09 / REQ 09）

    func testDependencyStateIsDerivedNotStored() {
        let blocker = UUID()
        let follower = UUID()
        let tasks = [
            task(blocker, title: "先做"),
            task(follower, title: "后做", dependencies: [blocker])
        ]
        guard case .waiting(let count) = DependencyPolicy.status(for: tasks[1], planTasks: tasks) else {
            return XCTFail("未完成前置应派生为 waiting")
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(DependencyPolicy.blockerTitles(for: tasks[1], planTasks: tasks), ["先做"])
        // 仅提示，不阻断（PRD 6.3）
        XCTAssertFalse(DependencyState.waiting(count: 1).blocksActions)
    }

    func testDependencyReadyWhenBlockerDoneOrTombstoned() {
        let blocker = UUID()
        let follower = UUID()
        let done = task(blocker, title: "已完成", status: .done)
        let followerTask = task(follower, title: "后做", dependencies: [blocker])

        XCTAssertTrue(DependencyPolicy.status(for: followerTask, planTasks: [done, followerTask]).isReady)
        // 前置被删除 → 自动解除
        XCTAssertTrue(DependencyPolicy.status(for: followerTask, planTasks: [followerTask],
                                             tombstoned: [blocker]).isReady)
    }

    // MARK: - 分词（5.3）

    func testChineseBigramsAndFullRun() {
        let tokens = Set(SearchTokenizer.tokens(for: "季度汇报"))
        XCTAssertTrue(tokens.contains("季度"))
        XCTAssertTrue(tokens.contains("度汇"))
        XCTAssertTrue(tokens.contains("汇报"))
        XCTAssertTrue(tokens.contains("季度汇报"), "连续中文片段整体也作为词")
    }

    func testLatinAndMixedTokensAreLowercasedAndSplit() {
        let tokens = Set(SearchTokenizer.tokens(for: "Q3 Report 体重"))
        XCTAssertTrue(tokens.contains("q3"))
        XCTAssertTrue(tokens.contains("report"))
        XCTAssertTrue(tokens.contains("体重"))
    }

    func testPunctuationSeparatesTokens() {
        let tokens = Set(SearchTokenizer.tokens(for: "散步，牛奶"))
        XCTAssertTrue(tokens.contains("散步"))
        XCTAssertTrue(tokens.contains("牛奶"))
        XCTAssertFalse(tokens.contains("散步，牛奶"))
    }
}
