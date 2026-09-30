//
//  ProgressPolicy.swift
//  Domain/Policies
//
//  4.4 progressFor(plan)。按计划类型给出不同口径；
//  交付型只计叶子任务（剔除已取消与模板任务）；持续型不显示总体 100%（AC07/AC19）。
//

import Foundation

public enum ProgressPolicy {

    /// 交付型分母：计划内**叶子任务** − 已取消 − 模板任务（重复例行不进分母）
    /// 判定"叶子"时同样剔除已取消/模板子任务：全部子任务被取消时父任务重新成为叶子。
    public static func deliveryLeaves(in tasks: [Task]) -> (done: Int, total: Int) {
        let presentParents = Set(
            tasks.filter { $0.countsTowardProgress }
                 .compactMap(\.parentId))
        let leaves = tasks.filter { $0.countsTowardProgress && !presentParents.contains($0.id) }
        let done = leaves.filter { $0.status == .done }.count
        return (done, leaves.count)
    }

    /// 阶段/分组的汇总：分母是"该阶段下的叶子任务"
    public static func stageRollup(stageID: UUID, tasks: [Task]) -> (done: Int, total: Int) {
        let scoped = tasks.filter { $0.stageId == stageID }
        return deliveryLeaves(in: scoped)
    }

    /// 分组汇总（父任务）——与阶段确认是不同状态
    public static func groupRollup(parentID: UUID, tasks: [Task]) -> (done: Int, total: Int) {
        let scoped = TaskHierarchy.descendants(of: parentID, in: tasks)
        return deliveryLeaves(in: scoped)
    }

    // MARK: - 主入口

    public static func progressFor(
        plan: Plan,
        tasks: [Task],
        rules: [RecurrenceRule],
        occurrences: [RecurrenceOccurrence],
        metrics: [PlanMetric],
        measurements: [Measurement],
        week: DateOnlyRange,
        today: DateOnly
    ) -> PlanProgress {
        switch plan.kind {
        case .delivery:
            let (done, total) = deliveryLeaves(in: tasks)
            if total == 0 {
                return .empty(reason: "这个计划还没有需要计数的任务")
            }
            return .delivery(done: done, total: total)

        case .improvement:
            let actions = periodActions(plan: plan, rules: rules, occurrences: occurrences,
                                        tasks: tasks, week: week, today: today)
            let trends = metrics.map { trend(for: $0, measurements: measurements) }
            return .improvement(actions: actions, metrics: trends)

        case .maintenance:
            let actions = periodActions(plan: plan, rules: rules, occurrences: occurrences,
                                        tasks: tasks, week: week, today: today)
            return .maintenance(actions: actions)
        }
    }

    /// 周期行动计数：同计划内所有重复规则的合计
    public static func periodActions(plan: Plan, rules: [RecurrenceRule],
                                     occurrences: [RecurrenceOccurrence],
                                     tasks: [Task],
                                     week: DateOnlyRange,
                                     today: DateOnly) -> PeriodActions {
        let planRules = rules.filter { rule in tasks.contains { $0.id == rule.taskId } }
        guard !planRules.isEmpty else { return PeriodActions(done: 0, planned: 0) }

        var done = 0, planned = 0, skipped = 0, unrecorded = 0, extra = 0
        for rule in planRules {
            let scoped = occurrences.filter { $0.ruleId == rule.id }
            switch rule.pattern {
            case .weeklyCount:
                let p = RecurrencePolicy.weeklyProgress(rule: rule, occurrences: scoped, week: week, today: today)
                done += p.done; planned += p.planned; skipped += p.skipped
                unrecorded += p.unrecorded; extra += p.extraDone
            case .daily, .weekdays:
                let p = RecurrencePolicy.fixedProgress(occurrences: scoped, in: week, today: today)
                done += p.done; planned += p.planned; skipped += p.skipped; unrecorded += p.unrecorded
            }
        }
        return PeriodActions(done: done, planned: planned, skipped: skipped,
                             unrecorded: unrecorded, extraDone: extra)
    }

    // MARK: - 指标趋势

    /// 只连接实际测量，缺测留空，不预测（REQ 21 / AC19）
    public static func trend(for metric: PlanMetric, measurements: [Measurement]) -> MetricTrend {
        let scoped = measurements
            .filter { $0.metricId == metric.id && $0.value.isFinite }
            .sorted { $0.measuredAt < $1.measuredAt }

        var points: [MetricPoint] = []
        var corrected = 0
        for m in scoped {
            if m.isCorrection { corrected += 1 }
            points.append(MetricPoint(id: m.id, date: m.measuredAt, value: m.value,
                                      isCorrection: m.isCorrection, isGap: false, isRevised: m.isCorrection))
        }

        // 相邻两点之间的日期不填 0，只标记"该日无测量"
        var withGaps: [MetricPoint] = []
        for (idx, p) in points.enumerated() {
            withGaps.append(p)
            guard idx + 1 < points.count else { continue }
            let gapDays = p.date.days(until: points[idx + 1].date)
            if gapDays > 1 {
                withGaps.append(MetricPoint(id: deterministicID("gap-\(metric.id)-\(p.date)"),
                                            date: p.date.adding(days: 1),
                                            value: Double.nan, isGap: true))
            }
        }

        let latest = points.last?.value
        let delta: Double? = {
            guard points.count >= 2, let l = points.last?.value else { return nil }
            return l - points[points.count - 2].value
        }()

        return MetricTrend(metricId: metric.id, name: metric.name, unit: metric.unit,
                           points: withGaps, latest: latest, delta: delta,
                           hasGap: withGaps.contains { $0.isGap }, correctedCount: corrected)
    }

    /// 结果记录与行动完成**分区显示**，不产生达标率（AC19）
    public static func separatesActionsFromResults(plan: Plan) -> Bool { true }

    /// 最新测量（M03 摘要）
    public static func latestMeasurement(metricID: UUID, measurements: [Measurement]) -> Measurement? {
        measurements.filter { $0.metricId == metricID && $0.value.isFinite }
            .max { $0.measuredAt < $1.measuredAt }
    }

    /// 计划内是否存在某日的实际测量（缺测提示：不自动补 0）
    public static func hasMeasurement(metricID: UUID, on day: DateOnly, measurements: [Measurement]) -> Bool {
        measurements.contains { $0.metricId == metricID && $0.measuredAt == day && $0.value.isFinite }
    }

    static func deterministicID(_ seed: String) -> UUID {
        RecurrencePolicy.deterministicID(seed)
    }
}
