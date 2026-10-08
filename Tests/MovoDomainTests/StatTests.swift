//
//  StatTests.swift
//  MovoDomainTests
//
//  统计、口径与可视化视图查询测试（stat.md）：
//  - 口径约束：分母为零不显示百分比、持续型不强制总进度 100%
//  - 阶段分段进度（StageProgressSegment）
//  - 回顾统计（7天行动分布与分类占比）
//  - 时间线跨度投影（PlanTimelineView）
//

import XCTest
import MovoKit

@MainActor
final class StatTests: XCTestCase {

    private let tzID = "Asia/Shanghai"
    private var tz: TimeZone { TimeZone(identifier: tzID)! }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DateOnly {
        DateOnly(y: y, m: m, d: d, sourceTZ: tzID)
    }

    private func makeStore(repository: InMemoryRepository, today: DateOnly) -> DomainStore {
        DomainStore(repository: repository, clock: TravelClock(today.noon),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: tzID),
                    deviceIDProvider: FixedDeviceIDProvider("stat-test"),
                    defaults: .fallback)
    }

    // MARK: - 口径验证

    func testDenominatorZeroDoesNotShowPercentage() {
        // 交付型：分母为 0 时 showsPercentage 为 false，fraction 为 0
        let emptyProgress = PlanProgress.delivery(done: 0, total: 0)
        XCTAssertFalse(emptyProgress.showsPercentage)
        XCTAssertEqual(emptyProgress.fraction, 0)

        // 持续型：无论完成多少都不显示总进度百分比
        let maintenanceProgress = PlanProgress.maintenance(actions: PeriodActions(done: 5, planned: 5))
        XCTAssertFalse(maintenanceProgress.showsPercentage)
        XCTAssertEqual(maintenanceProgress.fraction, 0)
    }

    func testStageProgressSegmentFraction() {
        let segZero = StageProgressSegment(name: "阶段一", done: 0, total: 0)
        XCTAssertEqual(segZero.fraction, 0)

        let segNormal = StageProgressSegment(name: "阶段二", done: 2, total: 5)
        XCTAssertEqual(segNormal.fraction, 0.4, accuracy: 0.001)
        XCTAssertEqual(segNormal.displayText, "阶段二 · 2/5")
    }

    // MARK: - 计划详情阶段分段与时间线查询

    func testPlanDetailStageSegmentsAndTimeline() async throws {
        let repo = InMemoryRepository()
        let store = makeStore(repository: repo, today: day(2026, 10, 5))

        // 创建计划
        let plan = Plan(id: UUID(), name: "年终总结", kind: .delivery, category: .work,
                        startAt: .day(day(2026, 10, 1)), endAt: .day(day(2026, 10, 31)))
        try await repo.upsert(plan)

        // 创建阶段（sortIndex 在时间与状态之后声明）
        let stage1 = Stage(id: UUID(), planId: plan.id, name: "收集材料",
                           startAt: .day(day(2026, 10, 1)), endAt: .day(day(2026, 10, 15)),
                           sortIndex: 0)
        let stage2 = Stage(id: UUID(), planId: plan.id, name: "成稿修改",
                           startAt: .day(day(2026, 10, 16)), endAt: .day(day(2026, 10, 31)),
                           sortIndex: 1)
        try await repo.upsert(stage1)
        try await repo.upsert(stage2)

        // 创建任务（阶段1：2个，完成1个；阶段2：1个未完成；未挂阶段：1个未完成）
        let t1 = Task(id: UUID(), planId: plan.id, stageId: stage1.id, title: "拉取数据", status: .done,
                      startAt: .day(day(2026, 10, 2)), endAt: .day(day(2026, 10, 5)))
        let t2 = Task(id: UUID(), planId: plan.id, stageId: stage1.id, title: "整理图表", status: .todo,
                      startAt: .day(day(2026, 10, 6)), endAt: .day(day(2026, 10, 10)))
        let t3 = Task(id: UUID(), planId: plan.id, stageId: stage2.id, title: "起草正文", status: .todo,
                      startAt: .day(day(2026, 10, 16)), endAt: .day(day(2026, 10, 25)))
        let tUnscheduled = Task(id: UUID(), planId: plan.id, stageId: nil, title: "独立待排期项", status: .todo)

        try await repo.upsert(t1)
        try await repo.upsert(t2)
        try await repo.upsert(t3)
        try await repo.upsert(tUnscheduled)

        // 验证 PlanDetail
        guard let detail = await store.planDetail(plan.id) else {
            XCTFail("应当能查到计划详情")
            return
        }

        XCTAssertEqual(detail.stageSegments.count, 3, "包含2个阶段段落和1个未挂阶段段落")
        let seg1 = detail.stageSegments.first { $0.stageId == stage1.id }
        XCTAssertEqual(seg1?.done, 1)
        XCTAssertEqual(seg1?.total, 2)

        let segUnassigned = detail.stageSegments.first { $0.stageId == nil }
        XCTAssertEqual(segUnassigned?.total, 1)

        // 验证时间线跨度视图（计划自身 + 阶段 + 排期任务）
        guard let timeline = await store.planTimelineView(plan.id) else {
            XCTFail("应当能生成时间线视图")
            return
        }

        XCTAssertEqual(timeline.spans.count, 6, "计划自身 + 2个阶段 + 3个排期任务")
        XCTAssertEqual(timeline.spans.filter { $0.kind == .task }.count, 3)
        XCTAssertFalse(timeline.spans.contains { $0.isOutRange }, "子级时间都落在父级范围内")
        XCTAssertEqual(timeline.unscheduledTasks.count, 1, "包含1个未排期任务")
        XCTAssertEqual(timeline.unscheduledTasks.first?.title, "独立待排期项")
        XCTAssertEqual(timeline.minDate, day(2026, 10, 1))
        XCTAssertEqual(timeline.maxDate, day(2026, 10, 31))
    }

    // MARK: - 回顾聚合（7天行动分布与分类占比）

    func testReviewViewDailyActionsAndCategoryDistribution() async throws {
        let repo = InMemoryRepository()
        let monday = day(2026, 10, 5) // 周一
        let store = makeStore(repository: repo, today: monday)

        // 创建不同分类的计划
        let planWork = Plan(id: UUID(), name: "工作计划", kind: .delivery, category: .work)
        let planStudy = Plan(id: UUID(), name: "学习计划", kind: .maintenance, category: .study)
        try await repo.upsert(planWork)
        try await repo.upsert(planStudy)

        // 记录行动：周一工作 2 条，周三学习 1 条
        let act1 = ActionRecord(id: UUID(), planId: planWork.id, happenedAt: .precise(monday.noon))
        let act2 = ActionRecord(id: UUID(), planId: planWork.id,
                                happenedAt: .precise(monday.noon.addingTimeInterval(3600)))
        let wednesday = monday.adding(days: 2)
        let act3 = ActionRecord(id: UUID(), planId: planStudy.id, happenedAt: .precise(wednesday.noon))

        try await repo.upsert(act1)
        try await repo.upsert(act2)
        try await repo.upsert(act3)

        let review = await store.reviewView(weekStart: monday)

        XCTAssertEqual(review.totalActionCount, 3)
        XCTAssertEqual(review.dailyActions.count, 7, "应当覆盖整周7天")

        let monStat = review.dailyActions.first { $0.date == monday }
        XCTAssertEqual(monStat?.count, 2)
        XCTAssertEqual(monStat?.weekdayName, "周一")

        let wedStat = review.dailyActions.first { $0.date == wednesday }
        XCTAssertEqual(wedStat?.count, 1)

        let sunStat = review.dailyActions.first { $0.date == monday.adding(days: 6) }
        XCTAssertEqual(sunStat?.count, 0)

        // 验证分类分布
        XCTAssertEqual(review.categoryDistribution.count, 2)
        let workShare = review.categoryDistribution.first { $0.category == .work }
        XCTAssertEqual(workShare?.count, 2)
        XCTAssertEqual(workShare?.share ?? 0, 2.0 / 3.0, accuracy: 0.001)

        let studyShare = review.categoryDistribution.first { $0.category == .study }
        XCTAssertEqual(studyShare?.count, 1)
        XCTAssertEqual(studyShare?.share ?? 0, 1.0 / 3.0, accuracy: 0.001)
    }

    // MARK: - 重复任务离散序列展示

    func testTaskDetailOccurrenceStrip() async throws {
        let repo = InMemoryRepository()
        let today = day(2026, 10, 5)
        let store = makeStore(repository: repo, today: today)

        let taskID = UUID()
        let task = Task(id: taskID, title: "晨跑", isTemplate: true)
        try await repo.upsert(task)

        let rule = RecurrenceRule(id: UUID(), taskId: taskID, pattern: .daily, effectiveFrom: day(2026, 10, 1))
        try await repo.upsert(rule)

        // 生成三次实例：昨天已完成、前天已跳过、大前天未记录
        let occ1 = RecurrenceOccurrence(
            id: UUID(), ruleId: rule.id, taskId: taskID,
            scheduledOn: day(2026, 10, 4), status: .done)
        let occ2 = RecurrenceOccurrence(
            id: UUID(), ruleId: rule.id, taskId: taskID,
            scheduledOn: day(2026, 10, 3), status: .skipped)
        let occ3 = RecurrenceOccurrence(
            id: UUID(), ruleId: rule.id, taskId: taskID,
            scheduledOn: day(2026, 10, 2), status: .pending)

        try await repo.upsert(occ1)
        try await repo.upsert(occ2)
        try await repo.upsert(occ3)

        guard let detail = await store.taskDetail(taskID) else {
            XCTFail("应当能获取任务详情")
            return
        }

        XCTAssertEqual(detail.occurrenceStrip.count, 3)
        let stripDone = detail.occurrenceStrip.first { $0.date == day(2026, 10, 4) }
        XCTAssertEqual(stripDone?.state, .done)

        let stripSkipped = detail.occurrenceStrip.first { $0.date == day(2026, 10, 3) }
        XCTAssertEqual(stripSkipped?.state, .skipped)

        let stripUnrecorded = detail.occurrenceStrip.first { $0.date == day(2026, 10, 2) }
        XCTAssertEqual(stripUnrecorded?.state, .unrecorded, "过去且待做的实例被标记为未记录")
    }
}
