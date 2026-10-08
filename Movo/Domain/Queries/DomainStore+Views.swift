//
//  DomainStore+Views.swift
//  Domain/Queries
//
//  4.3 查询视图（补充）：计划详情、任务详情、时间线与历史、回顾、收件箱、
//  搜索、快照、归档。全部只读、纯组合，不产生写入。
//

import Foundation

// MARK: - 计划详情

/// 周期行动摘要（按模板任务聚合）
public struct OccurrenceSummary: Identifiable, Hashable, Sendable {
    public var id: UUID { taskId }
    public var taskId: UUID
    public var title: String
    public var unitText: String
    public var pendingToday: Bool
    public var doneThisWeek: Int
    public var plannedThisWeek: Int

    public init(taskId: UUID, title: String, unitText: String, pendingToday: Bool,
                doneThisWeek: Int, plannedThisWeek: Int) {
        self.taskId = taskId; self.title = title; self.unitText = unitText
        self.pendingToday = pendingToday; self.doneThisWeek = doneThisWeek
        self.plannedThisWeek = plannedThisWeek
    }
}

public struct PlanDetail: Hashable, Sendable {
    public var plan: Plan
    public var progress: PlanProgress
    public var stages: [Stage]
    public var currentStage: Stage?
    public var tree: PlanTreeView
    public var metrics: [PlanMetric]
    public var trends: [MetricTrend]
    public var weekActions: PeriodActions
    public var occurrences: [OccurrenceSummary]
    public var ruleCount: Int
    public var stageSegments: [StageProgressSegment]

    public init(plan: Plan, progress: PlanProgress, stages: [Stage], currentStage: Stage?,
                tree: PlanTreeView, metrics: [PlanMetric], trends: [MetricTrend],
                weekActions: PeriodActions, occurrences: [OccurrenceSummary],
                ruleCount: Int, stageSegments: [StageProgressSegment] = []) {
        self.plan = plan; self.progress = progress; self.stages = stages
        self.currentStage = currentStage; self.tree = tree; self.metrics = metrics
        self.trends = trends; self.weekActions = weekActions; self.occurrences = occurrences
        self.ruleCount = ruleCount; self.stageSegments = stageSegments
    }
}

// MARK: - 任务详情

public struct TaskDetail: Hashable, Sendable {
    public var task: Task
    public var plan: Plan?
    public var stage: Stage?
    public var parent: Task?
    public var children: [Task]
    public var dependency: DependencyState
    public var blockerTitles: [String]
    public var relationGraph: DependencyPolicy.RelationGraph
    public var rule: RecurrenceRule?
    public var occurrences: [RecurrenceOccurrence]
    public var activities: [ActionRecord]
    public var notes: [Note]
    public var timeline: [TimelineEntry]
    public var occurrenceStrip: [OccurrenceStatusItem]

    public init(task: Task, plan: Plan?, stage: Stage?, parent: Task?,
                children: [Task], dependency: DependencyState, blockerTitles: [String],
                relationGraph: DependencyPolicy.RelationGraph, rule: RecurrenceRule?,
                occurrences: [RecurrenceOccurrence], activities: [ActionRecord],
                notes: [Note], timeline: [TimelineEntry],
                occurrenceStrip: [OccurrenceStatusItem] = []) {
        self.task = task; self.plan = plan; self.stage = stage; self.parent = parent
        self.children = children; self.dependency = dependency; self.blockerTitles = blockerTitles
        self.relationGraph = relationGraph; self.rule = rule; self.occurrences = occurrences
        self.activities = activities; self.notes = notes; self.timeline = timeline
        self.occurrenceStrip = occurrenceStrip
    }
}

// MARK: - 历史条目（计划级）

public struct PlanHistoryEntry: Identifiable, Hashable, Sendable {
    /// 以当日 ISO 日期为稳定标识：按天分组，天然唯一。
    public var id: String
    public var asOf: DateOnly
    public var summaryText: String
    public var detail: String?
    public var kind: TimelineEntry.Kind

    public init(id: String, asOf: DateOnly, summaryText: String, detail: String? = nil,
                kind: TimelineEntry.Kind = .adjustment) {
        self.id = id; self.asOf = asOf; self.summaryText = summaryText
        self.detail = detail; self.kind = kind
    }
}

// MARK: - 查询实现

public extension DomainStore {

    // MARK: 计划详情

    func planDetail(_ planID: UUID) async -> PlanDetail? {
        guard let plan = await repository.plan(planID) else { return nil }
        let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        let tasks = await repository.tasks(planID: planID).filter { !deleted.contains($0.id) }
        let stages = (await repository.stages(planID: planID)).sorted { $0.sortIndex < $1.sortIndex }
        let metrics = await repository.metrics(planID: planID)
        let measurements = await repository.measurements(planID: planID)
        let rules = (await repository.rules()).filter { r in tasks.contains { $0.id == r.taskId } }
        let occurrences = await repository.occurrences(planID: planID).filter { !deleted.contains($0.id) }
        let week = DateOnlyRange.week(containing: today)

        let progress = ProgressPolicy.progressFor(
            plan: plan, tasks: tasks, rules: rules, occurrences: occurrences,
            metrics: metrics, measurements: measurements, week: week, today: today)

        let tree = await planTree(planID, depth: 1)
        let trends = metrics.map { ProgressPolicy.trend(for: $0, measurements: measurements) }
        let weekActions = ProgressPolicy.periodActions(plan: plan, rules: rules,
                                                       occurrences: occurrences, tasks: tasks,
                                                       week: week, today: today)

        let summaries = rules.map { rule -> OccurrenceSummary in
            let task = tasks.first { $0.id == rule.taskId }
            let scoped = occurrences.filter { $0.ruleId == rule.id }
            let fixed = RecurrencePolicy.fixedProgress(occurrences: scoped, in: week, today: today)
            let pendingToday = occurrences.contains {
                $0.ruleId == rule.id && $0.status == .pending && $0.scheduledOn == today
            }
            return OccurrenceSummary(
                taskId: rule.taskId, title: task?.title ?? "重复行动",
                unitText: Self.ruleUnitText(rule),
                pendingToday: pendingToday,
                doneThisWeek: fixed.done, plannedThisWeek: fixed.planned)
        }

        var segments: [StageProgressSegment] = []
        if plan.kind == .delivery {
            for stage in stages {
                let (done, total) = ProgressPolicy.stageRollup(stageID: stage.id, tasks: tasks)
                if total > 0 {
                    segments.append(StageProgressSegment(
                        stageId: stage.id,
                        name: stage.name,
                        done: done,
                        total: total,
                        status: stage.status))
                }
            }
            let unassignedTasks = tasks.filter { $0.stageId == nil }
            let (unassignedDone, unassignedTotal) = ProgressPolicy.deliveryLeaves(in: unassignedTasks)
            if unassignedTotal > 0 {
                segments.append(StageProgressSegment(
                    stageId: nil,
                    name: stages.isEmpty ? "待办" : "其他任务",
                    done: unassignedDone,
                    total: unassignedTotal,
                    status: nil))
            }
        }

        return PlanDetail(plan: plan, progress: progress, stages: stages,
                          currentStage: stages.first { $0.status == .inProgress || $0.status == .awaitingConfirm },
                          tree: tree, metrics: metrics, trends: trends, weekActions: weekActions,
                          occurrences: summaries, ruleCount: rules.count, stageSegments: segments)
    }

    // MARK: 任务详情

    func taskDetail(_ taskID: UUID) async -> TaskDetail? {
        guard let task = await repository.task(taskID) else { return nil }
        // Optional 的 flatMap/map 只接受同步闭包，因此这里显式展开（1.3：跨边界只传值类型）
        var plan: Plan?
        if let planID = task.planId { plan = await repository.plan(planID) }
        var stage: Stage?
        if let stageID = task.stageId { stage = await repository.stage(stageID) }
        var parent: Task?
        if let parentID = task.parentId { parent = await repository.task(parentID) }
        let deletedChildren = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        let children = TaskHierarchy.ordered(await repository.children(of: taskID).filter {
            !deletedChildren.contains($0.id) && $0.status != .cancelled && !$0.isStep
        })
        var siblings: [Task] = []
        if let planID = task.planId { siblings = await repository.tasks(planID: planID) }
        let tombstoned = Set(await repository.tombstones(activeOnly: true).map(\.entityId))

        let dependency = DependencyPolicy.status(for: task, planTasks: siblings, tombstoned: tombstoned)
        let blockers = DependencyPolicy.blockerTitles(for: task, planTasks: siblings, tombstoned: tombstoned)
        let graph = DependencyPolicy.relationGraph(for: task, planTasks: siblings)
        let rule = await repository.rule(forTask: taskID)
        let epoch = DateOnly(y: 1, m: 1, d: 1, sourceTZ: "UTC")
        let occurrences = (await repository.occurrences(taskID: taskID))
            .sorted { ($0.scheduledOn ?? epoch) > ($1.scheduledOn ?? epoch) }
        let activities = (await repository.activities(taskID: taskID))
            .sorted { $0.happenedAt.sortEpoch > $1.happenedAt.sortEpoch }
        let notes = await repository.notes(planID: task.planId)
        let timeline = await timeline(entityID: taskID, title: task.title, entityType: .task)

        let recentPrefix = Array(occurrences.prefix(30)).reversed()
        let strip = recentPrefix.map { occ -> OccurrenceStatusItem in
            let date = occ.displayDate(asOf: today)
            let state: OccurrenceStatusItem.State
            switch occ.status {
            case .done: state = .done
            case .skipped: state = .skipped
            case .pending:
                state = occ.isUnrecorded(asOf: today) ? .unrecorded : .pending
            }
            let dateText = date?.displayString ?? "未定日期"
            return OccurrenceStatusItem(id: occ.id, date: date, state: state, displayDateText: dateText)
        }

        return TaskDetail(task: task, plan: plan, stage: stage, parent: parent, children: children,
                          dependency: dependency, blockerTitles: blockers, relationGraph: graph,
                          rule: rule, occurrences: occurrences, activities: activities,
                          notes: notes, timeline: timeline, occurrenceStrip: strip)
    }

    // MARK: 时间线

    /// 单个实体的变更历史（含撤销补偿），倒序。
    func timeline(entityID: UUID, title: String, entityType: EntityType) async -> [TimelineEntry] {
        let events = await repository.events(entityID: entityID)
        return events
            .sorted { $0.recordedAt > $1.recordedAt }
            .map { Self.timelineEntry(from: $0, title: title, entityType: entityType) }
    }

    /// 计划级时间线：计划自身 + 阶段 + 任务 + 记录 + 结果。
    func planTimeline(_ planID: UUID) async -> [TimelineEntry] {
        let plan = await repository.plan(planID)
        let tasks = await repository.tasks(planID: planID)
        let stages = await repository.stages(planID: planID)
        let activities = await repository.activities(planID: planID)
        let measurements = await repository.measurements(planID: planID)

        var out: [TimelineEntry] = []
        if let plan {
            out += await timeline(entityID: plan.id, title: plan.name, entityType: .plan)
        }
        for stage in stages {
            out += await timeline(entityID: stage.id, title: stage.name, entityType: .stage)
        }
        for task in tasks {
            out += await timeline(entityID: task.id, title: task.title, entityType: .task)
        }
        for activity in activities {
            let title = tasks.first { $0.id == activity.taskId }?.title ?? "行动记录"
            out += await timeline(entityID: activity.id, title: title, entityType: .activity)
        }
        for measurement in measurements {
            let metric = await repository.metric(measurement.metricId)
            out += await timeline(entityID: measurement.id,
                                  title: metric?.name ?? "结果记录", entityType: .measurement)
        }
        return out.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// 计划的历史调整条目（D09 / M11-History）
    func planHistory(_ planID: UUID) async -> [PlanHistoryEntry] {
        let entries = await planTimeline(planID)
        let grouped = Dictionary(grouping: entries) { entry in
            DateOnly(from: entry.recordedAt, in: currentTimeZone)
        }
        return grouped
            .map { day, items -> PlanHistoryEntry in
                let adjustments = items.filter { $0.kind.isAdjustment }
                let records = items.filter { $0.kind.isRecord }
                let pick = adjustments.first ?? records.first ?? items[0]
                return PlanHistoryEntry(
                    id: day.iso8601DateString, asOf: day,
                    summaryText: pick.title,
                    detail: [pick.detail, pick.userReason].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                    kind: pick.kind)
            }
            .sorted { $0.asOf > $1.asOf }
    }

    // MARK: 快照

    /// 只读历史快照（D09-Snapshot / M11-Snapshot）。由事件回放至 asOf 当日结束。
    func snapshot(planID: UUID, asOf: DateOnly) async -> PlanSnapshot? {
        guard let plan = await repository.plan(planID) else { return nil }
        let tasks = await repository.tasks(planID: planID)
        let stages = await repository.stages(planID: planID)
        let metrics = await repository.metrics(planID: planID)
        let measurements = await repository.measurements(planID: planID)

        // 回放到 asOf：任务截止/目标日期取当日之前的最后事件值
        var eventCount = 0
        var snapshotTasks: [Task] = []
        for task in tasks {
            let events = (await repository.events(entityID: task.id))
                .filter { $0.recordedAt < Self.endOfDayDate(asOf, in: currentTimeZone) }
            eventCount += events.count
            var replayed = task
            if let last = events.max(by: { $0.recordedAt < $1.recordedAt }) {
                if let raw = last.patch["status"]?.new.stringValue,
                   let status = TaskStatus(rawValue: raw) {
                    replayed.status = status
                }
                if let raw = last.patch["title"]?.new.stringValue { replayed.title = raw }
            }
            snapshotTasks.append(replayed)
        }

        let leaves = ProgressPolicy.deliveryLeaves(in: snapshotTasks)
        let snapshotStages = stages.map { stage -> SnapshotStage in
            let rollup = ProgressPolicy.stageRollup(stageID: stage.id, tasks: snapshotTasks)
            let achievedBefore = stage.achievedAt.map { $0 < Self.endOfDayDate(asOf, in: currentTimeZone) } ?? false
            return SnapshotStage(id: stage.id, name: stage.name,
                                 statusText: achievedBefore ? StageStatus.achieved.displayName
                                                            : StageStatus.notStarted.displayName,
                                 done: rollup.done, total: rollup.total,
                                 achievedAt: achievedBefore ? stage.achievedAt : nil)
        }

        let snapshotMetrics = metrics.map { metric -> SnapshotMetric in
            let before = measurements.filter {
                $0.metricId == metric.id && $0.measuredAt <= asOf
            }.max { $0.measuredAt < $1.measuredAt }
            return SnapshotMetric(id: metric.id, name: metric.name, unit: metric.unit,
                                  latestAt: before?.measuredAt, latestValue: before?.value)
        }

        return PlanSnapshot(planId: planID, planName: plan.name, asOf: asOf,
                            goalText: plan.goalText, targetDate: plan.endAt?.dateOnly,
                            leafDone: leaves.done, leafTotal: leaves.total,
                            stages: snapshotStages, metrics: snapshotMetrics,
                            restoredFromEventCount: eventCount)
    }

    // MARK: 回顾

    func reviewView(weekStart: DateOnly? = nil) async -> ReviewView {
        let start = weekStart ?? today.startOfWeek()
        let week = DateOnlyRange.week(containing: start)
        let plans = await repository.allPlans()
        let tasks = await repository.allTasks()
        let rules = await repository.rules()
        let occurrences = await repository.occurrences(planID: nil)
        let activities = await repository.allActivities()
        let measurements = await repository.allMeasurements()
        let suggestions = await repository.suggestions(status: .pending)
        let notes = await repository.reviewNotes(weekStart: start)

        var facts: [ReviewFact] = []
        var gaps: [ReviewGap] = []
        var totalActions = 0

        for plan in plans where plan.status != .archived {
            let planTasks = tasks.filter { $0.planId == plan.id }
            let planMetrics = await repository.metrics(planID: plan.id)
            let planMeasurements = measurements.filter { $0.planId == plan.id }
            let planActivities = activities.filter { activity in
                activity.planId == plan.id
                    && week.contains(DateOnly(from: activity.happenedAt.sortEpoch, in: currentTimeZone))
            }
            let planRules = rules.filter { r in planTasks.contains { $0.id == r.taskId } }
            let planOccurrences = occurrences.filter { $0.planId == plan.id }
            let period = ProgressPolicy.periodActions(plan: plan, rules: planRules,
                                                      occurrences: planOccurrences, tasks: planTasks,
                                                      week: week, today: today)

            totalActions += planActivities.count
            let durations = planActivities.compactMap(\.durationMinutes)
            let typical = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count
            let trends = planMetrics.map { ProgressPolicy.trend(for: $0, measurements: planMeasurements) }
                .filter { !$0.points.isEmpty }
            let structured = await timelineKinds(planID: plan.id, in: week)

            if planActivities.isEmpty && period.done == 0 && trends.isEmpty && structured.isEmpty {
                gaps.append(ReviewGap(planId: plan.id, planName: plan.name,
                                      message: "这一周没有记录，可以补记或调整安排。"))
                continue
            }

            facts.append(ReviewFact(
                planId: plan.id, planName: plan.name, category: plan.category,
                actionCount: planActivities.count, typicalDurationMinutes: typical,
                skippedCount: period.skipped, unrecordedCount: period.unrecorded,
                plannedCount: period.planned > 0 ? period.planned : nil,
                metricChanges: trends, structuralEvents: structured,
                sourceSummary: "来自这一周的行动记录与结果",
                activityIDs: planActivities.map(\.id)))
        }

        let included = facts.map(\.planName)
        let excluded: [String] = []

        // 统计当周每日行动
        let weekdayLabels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        var dailyActions: [DayActionStat] = []
        let weekActivities = activities.filter { activity in
            week.contains(DateOnly(from: activity.happenedAt.sortEpoch, in: currentTimeZone))
        }
        for offset in 0..<7 {
            let day = start.adding(days: offset)
            let count = weekActivities.filter {
                DateOnly(from: $0.happenedAt.sortEpoch, in: currentTimeZone) == day
            }.count
            let labelIndex = max(0, min(6, day.isoWeekday - 1))
            dailyActions.append(DayActionStat(date: day, weekdayName: weekdayLabels[labelIndex], count: count))
        }

        // 统计分类投入占比
        var categoryCounts: [PlanCategory?: Int] = [:]
        let planById = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for activity in weekActivities {
            let cat = planById[activity.planId]?.category
            categoryCounts[cat, default: 0] += 1
        }
        let totalCount = weekActivities.count
        var distribution: [CategoryShareStat] = []
        let orderedCategories: [PlanCategory?] = [.work, .study, .health, .life, nil]
        for cat in orderedCategories {
            if let c = categoryCounts[cat], c > 0 {
                let share = totalCount > 0 ? Double(c) / Double(totalCount) : 0
                distribution.append(CategoryShareStat(category: cat, count: c, share: share))
            }
        }

        return ReviewView(weekStart: start, weekRange: week, facts: facts, gaps: gaps,
                          suggestions: suggestions, reviewNotes: notes,
                          totalActionCount: totalActions,
                          cloudAIExcludedPlanNames: excluded,
                          cloudAIIncludedPlanNames: included,
                          dailyActions: dailyActions,
                          categoryDistribution: distribution)
    }

    // MARK: - 时间线跨度视图

    func planTimelineView(_ planID: UUID) async -> PlanTimelineView? {
        guard let plan = await repository.plan(planID) else { return nil }
        let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        let allTasks = await repository.tasks(planID: planID).filter { !deleted.contains($0.id) && !$0.isStep }
        let stages = (await repository.stages(planID: planID)).sorted { $0.sortIndex < $1.sortIndex }

        var spans: [TimelineSpanItem] = []
        var unscheduled: [Task] = []

        // 1. 计划自身
        if plan.startAt != nil || plan.endAt != nil {
            spans.append(TimelineSpanItem(
                id: plan.id,
                kind: .plan,
                title: plan.name,
                startAt: plan.startAt,
                endAt: plan.endAt,
                isCompleted: plan.status == .archived,
                isOutRange: false,
                depth: 0))
        }

        // 2. 阶段跨度
        for stage in stages {
            if stage.startAt != nil || stage.endAt != nil {
                let out = StructurePolicy.withinViolation(
                    startAt: stage.startAt, endAt: stage.endAt,
                    parentStart: plan.startAt, parentEnd: plan.endAt,
                    child: stage.name, parent: plan.name) != nil
                spans.append(TimelineSpanItem(
                    id: stage.id,
                    kind: .stage,
                    title: stage.name,
                    startAt: stage.startAt,
                    endAt: stage.endAt,
                    isCompleted: stage.status == .achieved,
                    isOutRange: out,
                    depth: 1))
            }
        }

        // 3. 任务跨度与未排期
        let tasksById = Dictionary(allTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for task in allTasks {
            if task.startAt == nil && task.endAt == nil {
                unscheduled.append(task)
            } else {
                var depth = 1
                if task.stageId != nil { depth = 2 }
                var curr = task
                while let pId = curr.parentId, let p = tasksById[pId] {
                    depth += 1
                    curr = p
                }

                let out = await StructurePolicy.timeRangeViolation(for: task, repository: repository) != nil

                spans.append(TimelineSpanItem(
                    id: task.id,
                    kind: .task,
                    title: task.title,
                    startAt: task.startAt,
                    endAt: task.endAt,
                    isCompleted: task.status == .done,
                    isOutRange: out,
                    depth: depth,
                    parentId: task.parentId,
                    stageId: task.stageId))
            }
        }

        // 计算 minDate 和 maxDate
        var dates: [DateOnly] = []
        for s in spans {
            if let d = s.startDateOnly { dates.append(d) }
            if let d = s.endDateOnly { dates.append(d) }
        }
        dates.append(today)
        let minDate = dates.min()
        let maxDate = dates.max()

        return PlanTimelineView(
            planId: plan.id,
            planName: plan.name,
            planStart: plan.startAt,
            planEnd: plan.endAt,
            spans: spans,
            unscheduledTasks: unscheduled,
            minDate: minDate,
            maxDate: maxDate)
    }

    // MARK: - AI 整理记录

    func organizeHistory() async -> [OrganizeRecord] {
        let captures = await repository.allCaptures()
        let allowedSteps = defaults.undoSteps > 0 ? defaults.undoSteps : 5
        let recentBatches = (await repository.recentBatches(limit: 50)).filter { $0.state == .applied }
        let eligibleBatchIDs = Set(recentBatches.prefix(allowedSteps).map(\.id))

        var records: [OrganizeRecord] = []
        for c in captures {
            let batch = c.batchId != nil ? await repository.batch(c.batchId!) : nil
            let hasApplied = batch?.state == .applied
            let isUndone = batch?.state == .undone || c.state == .undone
            let canUndo = c.batchId != nil && hasApplied && eligibleBatchIDs.contains(c.batchId!)
            let canPreview = c.state == .pendingConfirmation || c.proposalJSON != nil
            let canRetry = c.state == .aiFailed || c.state == .saved

            var summary = c.state.displayName
            if let batch, !batch.summary.isEmpty {
                summary = batch.summary
            } else if c.state == .aiFailed {
                summary = "整理失败，可重试"
            } else if c.state == .saved {
                summary = "已保存原文"
            }

            records.append(OrganizeRecord(
                id: c.id,
                rawText: c.effectiveText,
                summary: summary,
                state: isUndone ? .undone : c.state,
                capturedAt: c.capturedAt,
                batchID: c.batchId,
                canPreview: canPreview,
                canUndo: canUndo,
                canRetry: canRetry))
        }
        return records.sorted { $0.capturedAt > $1.capturedAt }
    }

    // MARK: 收件箱

    func inbox() async -> InboxView {
        let captures = await repository.captures(pendingOnly: true)
        let conflicts = await repository.conflicts(resolved: false)
        let suggestions = await repository.suggestions(status: .pending)
        let operations = await repository.pendingOperations()

        var rejected: [InboxRejected] = []
        for operation in operations where operation.status == .rejected {
            rejected.append(InboxRejected(id: operation.id,
                                          sourceSpan: operation.reason ?? operation.kind.displayName,
                                          reasons: [],
                                          captureId: nil,
                                          suggestedAction: operation.kind.displayName))
        }

        let unclassified = captures
            .filter { $0.state == .saved || $0.state == .aiPartial || $0.state == .aiFailed }
            .map { capture -> InboxUnclassified in
                InboxUnclassified(sourceText: capture.editedText ?? capture.rawText,
                                  candidatePlanIds: [], candidatePlanNames: [],
                                  reasonText: capture.state == .aiFailed
                                      ? "整理失败，原文已保留" : "还没有归类",
                                  capturedAt: capture.capturedAt,
                                  captureId: capture.id,
                                  kindHint: capture.inputMode.displayName)
            }

        return InboxView(unclassified: unclassified, pendingCaptures: captures,
                         rejectedItems: rejected, conflicts: conflicts, suggestions: suggestions)
    }

    // MARK: 搜索

    func search(query: String, scope: SearchScope = .all,
                recency: SearchRecency = .all) async -> SearchResultsView {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchResultsView(query: query, scope: scope, results: [])
        }
        let tokens = SearchTokenizer.tokens(for: trimmed)
        guard !tokens.isEmpty else {
            return SearchResultsView(query: query, scope: scope, results: [])
        }

        var documents = await repository.searchDocuments()
        if recency == .recent {
            let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
            documents = documents.filter { $0.updatedAt >= cutoff }
        }
        if scope != .all {
            let allowed = Self.entityTypes(for: scope)
            documents = documents.filter { allowed.contains($0.entityType) }
        }

        // 中文 bigram + 拉丁词：AND 匹配（全部 token 命中）
        // 重复行动的步骤不进入搜索
        let stepIDs = Set(await repository.allTasks().filter(\.isStep).map(\.id))
        let matches = documents.filter { doc in
            guard !stepIDs.contains(doc.entityId) else { return false }
            let haystack = Set(doc.tokens)
            return tokens.allSatisfy { haystack.contains($0) }
        }

        let plans = await repository.allPlans()
        let planNames = Dictionary(plans.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        let results = matches
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { doc -> SearchResult in
                SearchResult(entityType: doc.entityType, entityId: doc.entityId,
                             title: doc.title,
                             pathText: doc.planID.flatMap { planNames[$0] } ?? "未归类",
                             snippet: Self.snippet(doc.body, around: tokens),
                             dateText: nil,
                             statusText: nil,
                             planId: doc.planID,
                             updatedAt: doc.updatedAt)
            }
        return SearchResultsView(query: query, scope: scope, results: results)
    }

    // MARK: 归档与删除

    func archivedPlans() async -> [PlanArchive] {
        let all = await repository.allPlans()
        var out: [PlanArchive] = []
        for plan in all where plan.status == .archived {
            let tasks = await repository.tasks(planID: plan.id)
            let leaves = ProgressPolicy.deliveryLeaves(in: tasks)
            let activities = await repository.activities(planID: plan.id)
            let measurements = await repository.measurements(planID: plan.id)
            let timeline = await planTimeline(plan.id)
            out.append(PlanArchive(id: plan.id, planName: plan.name,
                                   archivedAt: plan.updatedAt,
                                   leafDone: leaves.done, leafTotal: leaves.total,
                                   actionRecordCount: activities.count,
                                   measurementCount: measurements.count,
                                   timelineEntries: timeline))
        }
        return out.sorted { $0.archivedAt > $1.archivedAt }
    }

    /// 最近删除（M13-Recovery）：可恢复期内
    func recentlyDeleted() async -> [Tombstone] {
        let tombstones = await repository.tombstones(activeOnly: true)
        let stamp = now
        return tombstones
            .filter { $0.isRecoverable(at: stamp) }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    // MARK: 内部工具

    func timelineKinds(planID: UUID, in range: DateOnlyRange) async -> [String] {
        let timeline = await planTimeline(planID)
        return timeline
            .filter { range.contains(DateOnly(from: $0.recordedAt, in: currentTimeZone)) }
            .filter { $0.kind.isAdjustment || $0.kind == .structural }
            .map { "\($0.kind.displayName)：\($0.title)" }
    }

    static func ruleUnitText(_ rule: RecurrenceRule) -> String {
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        switch rule.pattern {
        case .daily: return "每天"
        case .weekdays:
            let picked = (rule.weekdays ?? []).sorted().map { names[max(0, min(6, $0 - 1))] }
            return picked.joined(separator: "、")
        case .weeklyCount: return "每周 \(rule.weeklyCount ?? 0) 次"
        }
    }

    static func endOfDayDate(_ day: DateOnly, in tz: TimeZone) -> Date {
        day.adding(days: 1).startOfDay(in: tz)
    }

    static func entityTypes(for scope: SearchScope) -> Set<EntityType> {
        switch scope {
        case .all: Set(EntityType.allCases)
        case .tasks: [.task]
        case .plans: [.plan, .stage]
        case .activities: [.activity]
        case .notes: [.note]
        case .measurements: [.measurement]
        }
    }

    static func snippet(_ body: String, around tokens: [String]) -> String? {
        guard !body.isEmpty else { return nil }
        guard let first = tokens.first, let range = body.range(of: first, options: .caseInsensitive) else {
            return String(body.prefix(60))
        }
        let lower = body.index(range.lowerBound, offsetBy: -20, limitedBy: body.startIndex) ?? body.startIndex
        let upper = body.index(range.upperBound, offsetBy: 40, limitedBy: body.endIndex) ?? body.endIndex
        return "…" + String(body[lower..<upper]) + "…"
    }

    // MARK: ChangeEvent → TimelineEntry

    static func timelineEntry(from event: ChangeEvent, title: String,
                              entityType: EntityType) -> TimelineEntry {
        let kind = eventKind(event, entityType: entityType)
        let detailKeys = event.fields.filter { !["status", "revision"].contains($0) }
        let detail = detailKeys.isEmpty ? nil : "改动：\(detailKeys.joined(separator: "、"))"
        let oldValue = event.patch.values.compactMap { $0.old.stringValue }.first
        let newValue = event.patch.values.compactMap { $0.new.stringValue }.first
        return TimelineEntry(
            id: event.id.uuidString, kind: kind, title: title, detail: detail,
            occurredAt: event.occurredAt, recordedAt: event.recordedAt,
            hasPreciseTime: Calendar.current.component(.hour, from: event.occurredAt) != 0
                || Calendar.current.component(.minute, from: event.occurredAt) != 0,
            oldValue: oldValue, newValue: newValue, userReason: nil,
            entityId: event.entityId, entityType: entityType,
            actorDeviceId: event.deviceId, isUndone: event.undoOf != nil)
    }

    static func eventKind(_ event: ChangeEvent, entityType: EntityType) -> TimelineEntry.Kind {
        if event.undoOf != nil { return .aiUndone }
        if let statusRaw = event.patch["status"]?.new.stringValue {
            switch statusRaw {
            case TaskStatus.done.rawValue: return .completed
            case TaskStatus.cancelled.rawValue: return .cancelled
            case RuleStatus.paused.rawValue: return .paused
            case RuleStatus.active.rawValue: return .resumed
            case TaskStatus.todo.rawValue where event.baseRevision > 1: return .reopened
            case PlanStatus.paused.rawValue: return .paused
            case PlanStatus.active.rawValue where event.baseRevision > 1: return .resumed
            default: break
            }
        }
        if event.patch["value"] != nil, entityType == .measurement { return .measurementCorrected }
        // 旧版事件里的字段名也要认得
        let timeKeys = ["startAt", "endAt", "scheduledDate", "hardDeadline", "targetDate"]
        if timeKeys.contains(where: { event.patch[$0] != nil }) {
            return entityType == .task ? .adjustment : .goalChanged
        }
        if event.patch["pattern"] != nil || event.patch["weeklyCount"] != nil
            || event.patch["weekdays"] != nil { return .recurrenceChanged }
        if event.patch["goalText"] != nil { return .goalChanged }
        switch entityType {
        case .activity: return .record
        case .note, .capture: return .created
        case .measurement: return event.baseRevision > 1 ? .measurementCorrected : .created
        case .stage, .plan, .task: return event.baseRevision > 1 ? .structural : .created
        default: return .structural
        }
    }
}
