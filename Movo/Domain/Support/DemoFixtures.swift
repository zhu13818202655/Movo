//
//  DemoFixtures.swift
//  Domain/Support
//
//  12.2 固定 fixture 数据。与 docs/UI-Prompt.md「统一示例数据」逐字一致：
//  日期固定 2026-09-28（周一）；工作计划 3/7 完成；健康散步 0/3 与体重 68.7 分开。
//

import Foundation

@MainActor
public enum DemoFixtures {

    // MARK: - 基准时间

    public static let referenceTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    public static let today = DateOnly(y: 2026, m: 9, d: 28, sourceTZ: "Asia/Shanghai")
    public static let tomorrow = DateOnly(y: 2026, m: 9, d: 29, sourceTZ: "Asia/Shanghai")

    /// 2026-09-28 09:00（Asia/Shanghai）
    public static var referenceDate: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 28
        comps.hour = 9; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = referenceTimeZone
        return cal.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    private static func day(_ m: Int, _ d: Int) -> DateOnly {
        DateOnly(y: 2026, m: m, d: d, sourceTZ: "Asia/Shanghai")
    }

    private static func at(_ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = m; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = referenceTimeZone
        return cal.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: - 稳定 ID（同一任务跨页面身份一致）

    public enum IDs {
        public static let workPlan = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        public static let healthPlan = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        public static let studyPlan = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        public static let readingPlan = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!

        public static let stagePrepare = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
        public static let stageDraft = UUID(uuidString: "00000000-0000-4000-8000-000000000012")!
        public static let stageFinal = UUID(uuidString: "00000000-0000-4000-8000-000000000013")!

        public static let collectSalesData = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
        public static let verifyMetrics = UUID(uuidString: "00000000-0000-4000-8000-000000000022")!
        public static let analysisGroup = UUID(uuidString: "00000000-0000-4000-8000-000000000023")!
        public static let growthTrend = UUID(uuidString: "00000000-0000-4000-8000-000000000024")!
        public static let regionalDiff = UUID(uuidString: "00000000-0000-4000-8000-000000000025")!
        public static let writeDraft = UUID(uuidString: "00000000-0000-4000-8000-000000000026")!
        public static let reviseByFeedback = UUID(uuidString: "00000000-0000-4000-8000-000000000027")!
        public static let submitFinal = UUID(uuidString: "00000000-0000-4000-8000-000000000028")!
        public static let cancelledCover = UUID(uuidString: "00000000-0000-4000-8000-000000000029")!

        public static let walkTemplate = UUID(uuidString: "00000000-0000-4000-8000-000000000031")!
        public static let walkRule = UUID(uuidString: "00000000-0000-4000-8000-000000000032")!
        public static let weightMetric = UUID(uuidString: "00000000-0000-4000-8000-000000000033")!

        public static let studyTemplate = UUID(uuidString: "00000000-0000-4000-8000-000000000041")!
        public static let studyRule = UUID(uuidString: "00000000-0000-4000-8000-000000000042")!

        public static let readingTemplate = UUID(uuidString: "00000000-0000-4000-8000-000000000051")!
        public static let readingRule = UUID(uuidString: "00000000-0000-4000-8000-000000000052")!

        public static let buyMilk = UUID(uuidString: "00000000-0000-4000-8000-000000000061")!
    }

    // MARK: - 装载

    /// 把统一示例数据写入仓库。幂等：重复调用会覆盖同 ID 实体。
    public static func seed(into store: DomainStore) async throws {
        let now = referenceDate

        try await seedWorkPlan(into: store, now: now)
        try await seedHealthPlan(into: store, now: now)
        try await seedStudyPlan(into: store, now: now)
        try await seedReadingPlan(into: store, now: now)

        // 独立生活待办「买牛奶」：今天，不属于任何长期计划
        try await store.repository.upsert(Task(
            id: IDs.buyMilk, planId: nil, title: "买牛奶", status: .todo,
            scheduledDate: today, source: .manual,
            createdAt: now, updatedAt: now))
    }

    public static func seedIfEmpty(into store: DomainStore) async throws {
        let existing = await store.repository.allPlans()
        guard existing.isEmpty else { return }
        try await seed(into: store)
    }

    // MARK: - 季度工作汇报

    private static func seedWorkPlan(into store: DomainStore, now: Date) async throws {
        let plan = Plan(id: IDs.workPlan, name: "季度工作汇报", kind: .delivery,
                        category: .work,
                        goalText: "把这一季度的进展讲清楚，并给出下一步计划",
                        targetDate: day(10, 9),
                        aliases: ["季度汇报", "工作汇报"],
                        cloudAIEnabled: true, status: .active,
                        createdAt: at(8, 31, 10, 0), updatedAt: now)
        try await store.repository.upsert(plan)

        // 阶段
        try await store.repository.upsert(Stage(
            id: IDs.stagePrepare, planId: plan.id, name: "资料准备",
            criteriaText: "销售数据与口径核对完成", targetDate: day(9, 14),
            status: .achieved, achievedAt: at(9, 14, 18, 0), sortIndex: 0,
            createdAt: at(8, 31, 10, 5)))
        try await store.repository.upsert(Stage(
            id: IDs.stageDraft, planId: plan.id, name: "形成初稿",
            criteriaText: "初稿覆盖全部业务线", targetDate: day(9, 30),
            status: .inProgress, sortIndex: 1,
            createdAt: at(8, 31, 10, 6)))
        try await store.repository.upsert(Stage(
            id: IDs.stageFinal, planId: plan.id, name: "确认定稿",
            status: .notStarted, sortIndex: 2,
            createdAt: at(8, 31, 10, 7)))

        func task(_ id: UUID, _ stage: UUID?, _ parent: UUID?, _ title: String,
                  _ status: TaskStatus, scheduled: DateOnly? = nil,
                  createdAt: Date, doneAt: Date? = nil, cancelledAt: Date? = nil) -> Task {
            Task(id: id, planId: plan.id, stageId: stage, parentId: parent, title: title,
                 status: status, scheduledDate: scheduled, tags: ["汇报"],
                 source: .manual, doneAt: doneAt, cancelledAt: cancelledAt,
                 createdAt: createdAt, updatedAt: doneAt ?? cancelledAt ?? now)
        }

        // 阶段 资料准备（2/2 完成）
        try await store.repository.upsert(task(IDs.collectSalesData, IDs.stagePrepare, nil,
            "收集销售数据", .done, createdAt: at(8, 31, 10, 10), doneAt: at(9, 7, 17, 0)))
        try await store.repository.upsert(task(IDs.verifyMetrics, IDs.stagePrepare, nil,
            "核对指标口径", .done, createdAt: at(8, 31, 10, 11), doneAt: at(9, 14, 16, 30)))

        // 阶段 形成初稿（1/3 完成）——分组「整理分析」含两个子任务
        try await store.repository.upsert(task(IDs.analysisGroup, IDs.stageDraft, nil,
            "整理分析", .inProgress, createdAt: at(9, 14, 19, 0)))
        try await store.repository.upsert(task(IDs.growthTrend, IDs.stageDraft, IDs.analysisGroup,
            "梳理增长变化", .done, createdAt: at(9, 15, 9, 0), doneAt: at(9, 18, 20, 0)))
        try await store.repository.upsert(task(IDs.regionalDiff, IDs.stageDraft, IDs.analysisGroup,
            "汇总区域差异", .inProgress, scheduled: today,
            createdAt: at(9, 19, 9, 0)))
        try await store.repository.upsert(task(IDs.writeDraft, IDs.stageDraft, nil,
            "撰写汇报初稿", .todo, scheduled: tomorrow, createdAt: at(9, 21, 9, 0)))

        // 阶段 确认定稿（0/2 完成）
        try await store.repository.upsert(task(IDs.reviseByFeedback, IDs.stageFinal, nil,
            "根据反馈修订", .todo, createdAt: at(8, 31, 10, 20)))
        try await store.repository.upsert(task(IDs.submitFinal, IDs.stageFinal, nil,
            "提交最终汇报", .todo, createdAt: at(8, 31, 10, 21)))

        // 历史任务：9 月 21 日取消（默认隐藏，不参与计数）
        try await store.repository.upsert(task(IDs.cancelledCover, IDs.stageDraft, nil,
            "设计独立封面", .cancelled, createdAt: at(9, 1, 9, 0),
            cancelledAt: at(9, 21, 15, 0)))

        // 9 月 25 日为「汇总区域差异」追加 20 分钟记录
        try await store.repository.upsert(ActionRecord(
            planId: plan.id, taskId: IDs.regionalDiff,
            happenedAt: .precise(at(9, 25, 15, 20)), durationMinutes: 20,
            text: "已整理上海数据，待核对其他区域", source: .manual,
            recordedAt: at(9, 25, 17, 0), createdAt: at(9, 25, 17, 0)))
    }

    // MARK: - 减重与生活习惯

    private static func seedHealthPlan(into store: DomainStore, now: Date) async throws {
        let plan = Plan(id: IDs.healthPlan, name: "减重与生活习惯", kind: .improvement,
                        category: .health,
                        goalText: "规律作息与适度运动，先把习惯保持住",
                        aliases: ["减重", "生活习惯"],
                        cloudAIEnabled: false, syncEnabled: true, status: .active,
                        createdAt: at(8, 31, 10, 30), updatedAt: now)
        try await store.repository.upsert(plan)

        // 重复行动：每周 3 次散步
        try await store.repository.upsert(Task(
            id: IDs.walkTemplate, planId: plan.id, title: "晚饭后散步",
            isTemplate: true, status: .todo, timeHint: .evening, tags: ["运动"],
            source: .manual, createdAt: at(8, 31, 10, 35), updatedAt: now))
        try await store.repository.upsert(RecurrenceRule(
            id: IDs.walkRule, taskId: IDs.walkTemplate, pattern: .weeklyCount, weeklyCount: 3,
            effectiveFrom: today.startOfWeek(), version: 1, status: .active,
            createdAt: at(8, 31, 10, 35)))

        // 结果指标：体重（无目标值、无方向，不产生健康结论）
        try await store.repository.upsert(PlanMetric(
            id: IDs.weightMetric, planId: plan.id, name: "体重", unit: "kg",
            targetValue: nil, targetDirection: .none,
            createdAt: at(8, 31, 10, 40)))

        // 4 次测量：保留一次回升，不补缺失
        let samples: [(Int, Int, Double)] = [(9, 8, 69.4), (9, 15, 69.0), (9, 22, 69.2), (9, 28, 68.7)]
        for (m, d, value) in samples {
            try await store.repository.upsert(Measurement(
                planId: plan.id, metricId: IDs.weightMetric, measuredAt: day(m, d),
                value: value, unit: "kg", note: nil, source: .manual,
                recordedAt: at(m, d, 7, 30)))
        }
    }

    // MARK: - 英语备考

    private static func seedStudyPlan(into store: DomainStore, now: Date) async throws {
        let plan = Plan(id: IDs.studyPlan, name: "英语备考", kind: .improvement,
                        category: .study, goalText: "工作日稳定复习",
                        aliases: ["英语", "备考"], cloudAIEnabled: true, status: .active,
                        createdAt: at(9, 1, 9, 0), updatedAt: now)
        try await store.repository.upsert(plan)

        try await store.repository.upsert(Task(
            id: IDs.studyTemplate, planId: plan.id, title: "英语复习",
            isTemplate: true, status: .todo, tags: ["学习"],
            source: .manual, createdAt: at(9, 1, 9, 5), updatedAt: now))
        try await store.repository.upsert(RecurrenceRule(
            id: IDs.studyRule, taskId: IDs.studyTemplate, pattern: .weekdays,
            weekdays: [1, 2, 3, 4, 5], effectiveFrom: today.startOfWeek(),
            version: 1, status: .active, createdAt: at(9, 1, 9, 5)))

        // 今天已记录 30 分钟（行动记录，不等于长期目标达成）
        try await store.repository.upsert(ActionRecord(
            planId: plan.id, taskId: IDs.studyTemplate,
            happenedAt: .precise(at(9, 28, 8, 0)), durationMinutes: 30,
            text: "完成一套听力", source: .manual,
            recordedAt: at(9, 28, 8, 40), createdAt: at(9, 28, 8, 40)))
    }

    // MARK: - 保持阅读

    private static func seedReadingPlan(into store: DomainStore, now: Date) async throws {
        let plan = Plan(id: IDs.readingPlan, name: "保持阅读", kind: .maintenance,
                        category: .life, goalText: "每周读三次，不设结束日期",
                        aliases: ["阅读"], cloudAIEnabled: true, status: .active,
                        createdAt: at(9, 1, 9, 10), updatedAt: now)
        try await store.repository.upsert(plan)

        try await store.repository.upsert(Task(
            id: IDs.readingTemplate, planId: plan.id, title: "阅读",
            isTemplate: true, status: .todo, tags: ["生活"],
            source: .manual, createdAt: at(9, 1, 9, 15), updatedAt: now))
        try await store.repository.upsert(RecurrenceRule(
            id: IDs.readingRule, taskId: IDs.readingTemplate, pattern: .weeklyCount, weeklyCount: 3,
            effectiveFrom: today.startOfWeek(), version: 1, status: .active,
            createdAt: at(9, 1, 9, 15)))

        // 本周已记录 1 次
        try await store.repository.upsert(ActionRecord(
            planId: plan.id, taskId: IDs.readingTemplate,
            happenedAt: .precise(at(9, 28, 21, 0)), durationMinutes: 15,
            text: nil, source: .manual,
            recordedAt: at(9, 28, 21, 20), createdAt: at(9, 28, 21, 20)))
    }
}
