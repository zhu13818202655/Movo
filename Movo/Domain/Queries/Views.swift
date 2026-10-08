//
//  Views.swift
//  Domain/Queries
//
//  4.3 查询视图（只读值类型）。页面只读这些值，不直接触碰持久实体。
//

import Foundation

// MARK: - 进度

/// 按计划类型的进度口径（4.4 progressFor）。不同类型不共用百分比环。
public enum PlanProgress: Hashable, Sendable {
    case empty(reason: String)
    case delivery(done: Int, total: Int)
    case improvement(actions: PeriodActions, metrics: [MetricTrend])
    case maintenance(actions: PeriodActions)

    /// 交付型完成比例；分母为 0 时为 0（不显示百分比）
    public var fraction: Double {
        if case .delivery(let d, let t) = self { return t == 0 ? 0 : Double(d) / Double(t) }
        return 0
    }

    /// 交付型：`3/7`；分母为 0 不显示百分比
    public var shortText: String {
        switch self {
        case .empty: return "—"
        case .delivery(let d, let t):
            return t == 0 ? "还没有计数的任务" : "\(d)/\(t)"
        case .improvement(let a, let metrics):
            var parts = ["本周 \(a.done)/\(a.planned)"]
            if let m = metrics.first, let latest = m.latest {
                parts.append("最新 \(formatValue(latest))\(m.unitDisplayName)")
            }
            return parts.joined(separator: " · ")
        case .maintenance(let a):
            return "本周 \(a.done)/\(a.planned)"
        }
    }

    private func formatValue(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// 只有交付型显示总体百分比（持续型不显示总体 100%）
    public var showsPercentage: Bool {
        if case .delivery(let d, let t) = self { return t > 0 && d <= t }
        return false
    }

    public var doneCount: Int {
        switch self {
        case .delivery(let d, _): d
        case .improvement(let a, _), .maintenance(let a): a.done
        case .empty: 0
        }
    }
    public var totalCount: Int {
        switch self {
        case .delivery(_, let t): t
        case .improvement(let a, _), .maintenance(let a): a.planned
        case .empty: 0
        }
    }

    /// 交付型用于快照与导出的文本
    public var snapshotText: String {
        switch self {
        case .delivery(let d, let t): "\(d)/\(t) 项完成"
        default: shortText
        }
    }
}

/// 阶段分段进度（交付型使用）
public struct StageProgressSegment: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var stageId: UUID?
    public var name: String
    public var done: Int
    public var total: Int
    public var status: StageStatus?

    public init(id: UUID = UUID(), stageId: UUID? = nil, name: String, done: Int, total: Int, status: StageStatus? = nil) {
        self.id = id; self.stageId = stageId; self.name = name; self.done = done; self.total = total; self.status = status
    }

    public var fraction: Double {
        total == 0 ? 0 : min(max(Double(done) / Double(total), 0), 1)
    }

    public var displayText: String {
        "\(name) · \(done)/\(total)"
    }
}

/// 周期行动计数（改善型/持续型共用）
public struct PeriodActions: Hashable, Sendable {
    public var done: Int
    public var planned: Int
    public var skipped: Int
    public var unrecorded: Int
    /// done 超过 planned 时保留的额外记录（不丢数据）
    public var extraDone: Int

    public init(done: Int = 0, planned: Int = 0, skipped: Int = 0, unrecorded: Int = 0, extraDone: Int = 0) {
        self.done = done; self.planned = planned; self.skipped = skipped
        self.unrecorded = unrecorded; self.extraDone = extraDone
    }

    public var displayText: String {
        var s = "本周 \(done)/\(planned)"
        if skipped > 0 { s += " · 已跳过 \(skipped)" }
        if unrecorded > 0 { s += " · 未记录 \(unrecorded)" }
        if extraDone > 0 { s += " · 另有 \(extraDone) 次记录" }
        return s
    }

    /// 分母为 0 不显示百分比
    public var showsPercentage: Bool { planned > 0 }
}

/// 指标趋势：只连接实际测量，缺测留空，不预测
public struct MetricTrend: Hashable, Sendable, Identifiable {
    public var metricId: UUID
    public var name: String
    public var unit: String
    public var points: [MetricPoint]
    public var latest: Double?
    public var delta: Double?
    public var hasGap: Bool
    public var correctedCount: Int

    public var id: UUID { metricId }
    public var unitDisplayName: String { PlanMetric.unitDisplayName(for: unit) }

    public init(metricId: UUID, name: String, unit: String, points: [MetricPoint],
                latest: Double? = nil, delta: Double? = nil, hasGap: Bool = false, correctedCount: Int = 0) {
        self.metricId = metricId; self.name = name; self.unit = unit; self.points = points
        self.latest = latest; self.delta = delta; self.hasGap = hasGap; self.correctedCount = correctedCount
    }

    public var deltaText: String? {
        guard let delta else { return nil }
        let sign = delta > 0 ? "+" : ""
        let num = String(format: "%.1f", delta)
        return unit.isEmpty ? "\(sign)\(num)" : "\(sign)\(num)\(unit)"
    }

    /// 不生成健康结论（AC19）
    public var producesConclusion: Bool { false }
}

public struct MetricPoint: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: DateOnly
    public var value: Double
    public var isCorrection: Bool
    /// 缺测标记（该日期无测量），图表留空
    public var isGap: Bool
    /// 更正标记（趋势显示"已更正"）
    public var isRevised: Bool

    public init(id: UUID = UUID(), date: DateOnly, value: Double,
                isCorrection: Bool = false, isGap: Bool = false, isRevised: Bool = false) {
        self.id = id; self.date = date; self.value = value
        self.isCorrection = isCorrection; self.isGap = isGap; self.isRevised = isRevised
    }
}

// MARK: - 今日

public enum TodaySection: String, Sendable, CaseIterable, Identifiable {
    case focus, later, completed
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .focus: "今天的重点"
        case .later: "稍后再做"
        case .completed: "已完成"
        }
    }
}

/// 今日行。同一 taskId 与计划树同源（AC06）。
public struct TodayItem: Identifiable, Hashable, Sendable {
    public enum Body: Hashable, Sendable {
        /// 今天到期的硬截止
        case deadline(task: Task)
        /// 今天的 Occurrence
        case occurrence(occurrence: RecurrenceOccurrence, task: Task?)
        /// 开始日期是今天，或起止范围覆盖今天
        case scheduled(task: Task)
        /// 进行中的任务
        case inProgress(task: Task)
        /// 无日期 / 逾期
        case floating(task: Task)
        /// 逾期
        case overdue(task: Task, daysLate: Int)
    }

    public var id: String
    public var body: Body
    public var section: TodaySection
    public var planName: String?
    public var dependency: DependencyState
    /// 当天的起止（重复实例由规则每天的时刻生成）
    public var startAt: TimePoint?
    public var endAt: TimePoint?
    public var isCompletedToday: Bool

    public init(id: String, body: Body, section: TodaySection, planName: String? = nil,
                dependency: DependencyState = .ready, startAt: TimePoint? = nil, endAt: TimePoint? = nil,
                isCompletedToday: Bool = false) {
        self.id = id; self.body = body; self.section = section; self.planName = planName
        self.dependency = dependency; self.startAt = startAt; self.endAt = endAt
        self.isCompletedToday = isCompletedToday
    }

    /// 行内展示的时刻文本：只显示精确到时刻的那一端，例如 "08:00" 或 "08:00–09:00"
    public var timeText: String? {
        switch (startAt?.clockText, endAt?.clockText) {
        case (let s?, let e?): return "\(s)–\(e)"
        case (let s?, nil): return s
        case (nil, let e?): return "\(e) 前"
        case (nil, nil): return nil
        }
    }

    public var taskId: UUID? {
        switch body {
        case .deadline(let t), .scheduled(let t), .inProgress(let t), .floating(let t), .overdue(let t, _): t.id
        case .occurrence(_, let t): t?.id
        }
    }

    public var title: String {
        switch body {
        case .deadline(let t), .scheduled(let t), .inProgress(let t), .floating(let t), .overdue(let t, _): t.title
        case .occurrence(_, let t): t?.title ?? "重复行动"
        }
    }

    public var occurrenceId: UUID? {
        if case .occurrence(let o, _) = body { return o.id }
        return nil
    }

    /// 完成开关的语义区分：一次性任务完成 vs Occurrence 当次完成（事件不同）
    public var completionTarget: CompletionTarget {
        if case .occurrence(let o, _) = body { return .occurrence(o.id) }
        return .task(taskId ?? UUID())
    }

    public var displayStatus: String {
        switch body {
        case .deadline: "今天到期"
        case .occurrence(let o, _): o.status.displayName
        case .scheduled: "今天安排"
        case .inProgress: "进行中"
        case .floating: "未安排"
        case .overdue(_, let n): "逾期 \(n) 天"
        }
    }
}

public enum CompletionTarget: Hashable, Sendable {
    case task(UUID)
    case occurrence(UUID)
}

public struct TodayView: Hashable, Sendable {
    public var date: DateOnly
    public var focus: [TodayItem]
    public var later: [TodayItem]
    public var completed: [TodayItem]

    public init(date: DateOnly, focus: [TodayItem] = [], later: [TodayItem] = [], completed: [TodayItem] = []) {
        self.date = date; self.focus = focus; self.later = later; self.completed = completed
    }

    public var pendingCount: Int { focus.count + later.count }
    public var completedCount: Int { completed.count }

    /// "3项待推进 · 2项已完成"
    public var badgeText: String { "\(pendingCount)项待推进 · \(completedCount)项已完成" }

    public var isEmpty: Bool { focus.isEmpty && later.isEmpty && completed.isEmpty }

    public func items(in section: TodaySection) -> [TodayItem] {
        switch section {
        case .focus: focus
        case .later: later
        case .completed: completed
        }
    }
}

// MARK: - 依赖

public enum DependencyState: Hashable, Sendable {
    case ready
    case waiting(count: Int)

    public var isReady: Bool { self == .ready }
    public var blockedCount: Int { if case .waiting(let n) = self { return n }; return 0 }

    /// 任务行徽标：等待 n / 就绪
    public var badgeText: String {
        switch self {
        case .ready: "就绪"
        case .waiting(let n): "等待前置 \(n)"
        }
    }

    /// 仅提示，不阻断（PRD 6.3）
    public var blocksActions: Bool { false }
}

// MARK: - 计划摘要 / 树

public struct PlanSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: PlanKind
    public var category: PlanCategory?
    public var status: PlanStatus
    public var progress: PlanProgress
    public var currentStageName: String?
    public var nextActionText: String?
    public var targetDateText: String?
    public var goalText: String?
    public var cloudAIEnabled: Bool
    public var syncEnabled: Bool
    public var activityRank: Date

    public init(id: UUID, name: String, kind: PlanKind, category: PlanCategory?, status: PlanStatus,
                progress: PlanProgress, currentStageName: String? = nil, nextActionText: String? = nil,
                targetDateText: String? = nil, goalText: String? = nil,
                cloudAIEnabled: Bool = true, syncEnabled: Bool = true, activityRank: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.category = category; self.status = status
        self.progress = progress; self.currentStageName = currentStageName
        self.nextActionText = nextActionText; self.targetDateText = targetDateText
        self.goalText = goalText; self.cloudAIEnabled = cloudAIEnabled; self.syncEnabled = syncEnabled
        self.activityRank = activityRank
    }

    public var taxonomyLabel: String {
        guard let category else { return kind.displayName }
        return "\(category.displayName) · \(kind.displayName)"
    }
}

/// 树节点：阶段 / 任务 / 子任务分组
public struct PlanTreeNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case stage(Stage, done: Int, total: Int)
        case task(Task)
        case group(title: String, done: Int, total: Int, children: [PlanTreeNode])
    }

    public var id: String
    public var kind: Kind
    public var children: [PlanTreeNode]
    public var hasHiddenChildren: Bool
    public var hiddenChildCount: Int
    public var dependency: DependencyState
    /// 当前周期实例（历史实例折叠，显示计数）
    public var currentOccurrences: [RecurrenceOccurrence]
    public var historicalOccurrenceCount: Int
    public var isCancelled: Bool

    public init(id: String, kind: Kind, children: [PlanTreeNode] = [], hasHiddenChildren: Bool = false,
                hiddenChildCount: Int = 0, dependency: DependencyState = .ready,
                currentOccurrences: [RecurrenceOccurrence] = [], historicalOccurrenceCount: Int = 0,
                isCancelled: Bool = false) {
        self.id = id; self.kind = kind; self.children = children; self.hasHiddenChildren = hasHiddenChildren
        self.hiddenChildCount = hiddenChildCount; self.dependency = dependency
        self.currentOccurrences = currentOccurrences; self.historicalOccurrenceCount = historicalOccurrenceCount
        self.isCancelled = isCancelled
    }

    public var title: String {
        switch kind {
        case .stage(let s, _, _): s.name
        case .task(let t): t.title
        case .group(let title, _, _, _): title
        }
    }

    public var task: Task? {
        if case .task(let t) = kind { return t }
        return nil
    }

    public var childProgress: (done: Int, total: Int)? {
        guard let task, !children.isEmpty else { return nil }
        var tasks = [task]
        var pending = children
        while let node = pending.popLast() {
            if let child = node.task { tasks.append(child) }
            pending.append(contentsOf: node.children)
        }
        return ProgressPolicy.groupRollup(parentID: task.id, tasks: tasks)
    }
}

public struct PlanTreeView: Hashable, Sendable {
    public var planId: UUID
    public var planName: String
    public var depth: Int
    public var nodes: [PlanTreeNode]
    /// 阶段与任务分组不计入任务数
    public var leafDone: Int
    public var leafTotal: Int

    public init(planId: UUID, planName: String, depth: Int, nodes: [PlanTreeNode],
                leafDone: Int = 0, leafTotal: Int = 0) {
        self.planId = planId; self.planName = planName; self.depth = depth; self.nodes = nodes
        self.leafDone = leafDone; self.leafTotal = leafTotal
    }

    public var progressText: String { "已完成 \(leafDone)/\(leafTotal) 项" }
}

// MARK: - 时间线 / 历史

public struct TimelineEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case created, completed, adjustment, record, skipped, paused, resumed, cancelled, reopened
        case recurrenceChanged, goalChanged, measurementCorrected, aiUndone, structural, deleted, restored

        public var displayName: String {
            switch self {
            case .created: "建立"
            case .completed: "完成"
            case .adjustment: "调整"
            case .record: "记录"
            case .skipped: "跳过"
            case .paused: "暂停"
            case .resumed: "恢复"
            case .cancelled: "取消"
            case .reopened: "重新打开"
            case .recurrenceChanged: "频率调整"
            case .goalChanged: "目标修改"
            case .measurementCorrected: "结果纠错"
            case .aiUndone: "AI 撤销"
            case .structural: "结构调整"
            case .deleted: "删除"
            case .restored: "恢复内容"
            }
        }

        public var isAdjustment: Bool {
            switch self {
            case .adjustment, .recurrenceChanged, .goalChanged, .structural: true
            default: false
            }
        }
        public var isRecord: Bool {
            switch self {
            case .record, .measurementCorrected: true
            default: false
            }
        }
        public var isCompletion: Bool { self == .completed }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String?
    /// 实际发生时间
    public var occurredAt: Date
    /// 录入时间
    public var recordedAt: Date
    /// 具体时刻是否已记录（历史事件可能只有日期）
    public var hasPreciseTime: Bool
    public var oldValue: String?
    public var newValue: String?
    public var userReason: String?
    public var entityId: UUID?
    public var entityType: EntityType?
    public var actorDeviceId: String?
    public var isUndone: Bool

    public init(id: String, kind: Kind, title: String, detail: String? = nil, occurredAt: Date,
                recordedAt: Date? = nil, hasPreciseTime: Bool = true, oldValue: String? = nil,
                newValue: String? = nil, userReason: String? = nil, entityId: UUID? = nil,
                entityType: EntityType? = nil, actorDeviceId: String? = nil, isUndone: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
        self.occurredAt = occurredAt; self.recordedAt = recordedAt ?? occurredAt
        self.hasPreciseTime = hasPreciseTime; self.oldValue = oldValue; self.newValue = newValue
        self.userReason = userReason; self.entityId = entityId; self.entityType = entityType
        self.actorDeviceId = actorDeviceId; self.isUndone = isUndone
    }

    public var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = hasPreciseTime ? "M月d日 HH:mm" : "M月d日"
        return f.string(from: occurredAt)
    }
}

// MARK: - 快照

/// 截至 asOf 的事件重建，**只读**（AC14/AC22）
public struct PlanSnapshot: Hashable, Sendable {
    public var planId: UUID
    public var planName: String
    public var asOf: DateOnly
    public var goalText: String?
    public var targetDate: DateOnly?
    public var leafDone: Int
    public var leafTotal: Int
    public var stages: [SnapshotStage]
    public var metrics: [SnapshotMetric]
    public var restoredFromEventCount: Int

    public init(planId: UUID, planName: String, asOf: DateOnly, goalText: String? = nil,
                targetDate: DateOnly? = nil, leafDone: Int = 0, leafTotal: Int = 0,
                stages: [SnapshotStage] = [], metrics: [SnapshotMetric] = [], restoredFromEventCount: Int = 0) {
        self.planId = planId; self.planName = planName; self.asOf = asOf; self.goalText = goalText
        self.targetDate = targetDate; self.leafDone = leafDone; self.leafTotal = leafTotal
        self.stages = stages; self.metrics = metrics; self.restoredFromEventCount = restoredFromEventCount
    }

    /// 只读提示（历史截图不展示当前编辑按钮）
    public var isReadOnly: Bool { true }
    public var bannerText: String {
        "查看 \(asOf.displayString) 记录，只读"
    }
    public var progressText: String { "\(leafDone)/\(leafTotal) 项完成" }
}

public struct SnapshotStage: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var statusText: String
    public var done: Int
    public var total: Int
    public var achievedAt: Date?

    public init(id: UUID, name: String, statusText: String, done: Int, total: Int, achievedAt: Date? = nil) {
        self.id = id; self.name = name; self.statusText = statusText
        self.done = done; self.total = total; self.achievedAt = achievedAt
    }
}

public struct SnapshotMetric: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var unit: String
    public var latestAt: DateOnly?
    public var latestValue: Double?

    public init(id: UUID, name: String, unit: String, latestAt: DateOnly? = nil, latestValue: Double? = nil) {
        self.id = id; self.name = name; self.unit = unit
        self.latestAt = latestAt; self.latestValue = latestValue
    }
}

// MARK: - 回顾

/// 周内某天的行动记录统计（7 天分布）
public struct DayActionStat: Identifiable, Hashable, Sendable {
    public var id: DateOnly { date }
    public var date: DateOnly
    public var weekdayName: String
    public var count: Int

    public init(date: DateOnly, weekdayName: String, count: Int) {
        self.date = date; self.weekdayName = weekdayName; self.count = count
    }
}

/// 周内按计划分类（工作/学习/健康/生活/未分类）的投入占比
public struct CategoryShareStat: Identifiable, Hashable, Sendable {
    public var id: String { category?.rawValue ?? "none" }
    public var category: PlanCategory?
    public var displayName: String {
        category?.displayName ?? "未分类"
    }
    public var count: Int
    public var share: Double

    public init(category: PlanCategory?, count: Int, share: Double) {
        self.category = category; self.count = count; self.share = share
    }
}

public struct ReviewView: Hashable, Sendable {
    public var weekStart: DateOnly
    public var weekRange: DateOnlyRange
    public var facts: [ReviewFact]
    public var gaps: [ReviewGap]
    public var suggestions: [Suggestion]
    public var reviewNotes: [ReviewNote]
    public var totalActionCount: Int
    public var cloudAIExcludedPlanNames: [String]
    public var cloudAIIncludedPlanNames: [String]
    public var dailyActions: [DayActionStat]
    public var categoryDistribution: [CategoryShareStat]

    public init(weekStart: DateOnly, weekRange: DateOnlyRange, facts: [ReviewFact] = [],
                gaps: [ReviewGap] = [], suggestions: [Suggestion] = [], reviewNotes: [ReviewNote] = [],
                totalActionCount: Int = 0, cloudAIExcludedPlanNames: [String] = [],
                cloudAIIncludedPlanNames: [String] = [],
                dailyActions: [DayActionStat] = [],
                categoryDistribution: [CategoryShareStat] = []) {
        self.weekStart = weekStart; self.weekRange = weekRange; self.facts = facts; self.gaps = gaps
        self.suggestions = suggestions; self.reviewNotes = reviewNotes
        self.totalActionCount = totalActionCount
        self.cloudAIExcludedPlanNames = cloudAIExcludedPlanNames
        self.cloudAIIncludedPlanNames = cloudAIIncludedPlanNames
        self.dailyActions = dailyActions
        self.categoryDistribution = categoryDistribution
    }

    public var rangeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        return "\(weekRange.lower.y)年\(weekRange.lower.m)月\(weekRange.lower.d)日至\(weekRange.upper.m)月\(weekRange.upper.d)日"
    }

    /// 共 8 条行动记录，不等于 8 个长期目标达成
    public var summaryText: String {
        totalActionCount == 0
            ? "本周还没有记录。"
            : "共\(totalActionCount)条行动记录，不等于\(totalActionCount)个长期目标达成。"
    }

    public var hasData: Bool { totalActionCount > 0 || !facts.isEmpty }

    /// 数据不足显示"本周无记录"（AC15）
    public var emptyStateText: String { "本周无记录" }
}

public struct ReviewFact: Identifiable, Hashable, Sendable {
    public var id: UUID { planId ?? UUID() }
    public var planId: UUID?
    public var planName: String
    public var category: PlanCategory?
    public var actionCount: Int
    public var typicalDurationMinutes: Int?
    public var skippedCount: Int
    public var unrecordedCount: Int
    public var plannedCount: Int?
    public var metricChanges: [MetricTrend]
    public var structuralEvents: [String]
    public var sourceSummary: String
    public var activityIDs: [UUID]

    public init(planId: UUID?, planName: String, category: PlanCategory? = nil, actionCount: Int = 0,
                typicalDurationMinutes: Int? = nil, skippedCount: Int = 0, unrecordedCount: Int = 0,
                plannedCount: Int? = nil, metricChanges: [MetricTrend] = [], structuralEvents: [String] = [],
                sourceSummary: String = "", activityIDs: [UUID] = []) {
        self.planId = planId; self.planName = planName; self.category = category
        self.actionCount = actionCount; self.typicalDurationMinutes = typicalDurationMinutes
        self.skippedCount = skippedCount; self.unrecordedCount = unrecordedCount
        self.plannedCount = plannedCount; self.metricChanges = metricChanges
        self.structuralEvents = structuralEvents
        self.sourceSummary = sourceSummary; self.activityIDs = activityIDs
    }

    public var factText: String {
        var s = "\(actionCount)次行动记录"
        if let d = typicalDurationMinutes { s += " · 每次\(d)分钟" }
        if skippedCount > 0 { s += " · 跳过\(skippedCount)次" }
        if unrecordedCount > 0 { s += " · 未记录\(unrecordedCount)次" }
        return s
    }
}

public struct ReviewGap: Identifiable, Hashable, Sendable {
    public var id: UUID { planId ?? UUID() }
    public var planId: UUID?
    public var planName: String
    public var message: String

    public init(planId: UUID?, planName: String, message: String) {
        self.planId = planId; self.planName = planName; self.message = message
    }

    /// 没有原因记录时显示"未记录原因"，不自动编造解释
    public static func noRecord(planId: UUID?, planName: String) -> ReviewGap {
        ReviewGap(planId: planId, planName: planName, message: "本周无记录")
    }
}

// MARK: - AI 整理记录

public struct OrganizeRecord: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var rawText: String
    public var summary: String
    public var state: CaptureState
    public var capturedAt: Date
    public var batchID: UUID?
    public var canPreview: Bool
    public var canUndo: Bool
    public var canRetry: Bool

    public init(id: UUID, rawText: String, summary: String, state: CaptureState,
                capturedAt: Date, batchID: UUID? = nil,
                canPreview: Bool = false, canUndo: Bool = false, canRetry: Bool = false) {
        self.id = id
        self.rawText = rawText
        self.summary = summary
        self.state = state
        self.capturedAt = capturedAt
        self.batchID = batchID
        self.canPreview = canPreview
        self.canUndo = canUndo
        self.canRetry = canRetry
    }
}

// MARK: - 收件箱

public struct InboxView: Hashable, Sendable {
    public var unclassified: [InboxUnclassified]
    public var pendingCaptures: [Capture]
    public var rejectedItems: [InboxRejected]
    public var conflicts: [SyncConflict]
    public var suggestions: [Suggestion]

    public init(unclassified: [InboxUnclassified] = [], pendingCaptures: [Capture] = [],
                rejectedItems: [InboxRejected] = [], conflicts: [SyncConflict] = [],
                suggestions: [Suggestion] = []) {
        self.unclassified = unclassified; self.pendingCaptures = pendingCaptures
        self.rejectedItems = rejectedItems; self.conflicts = conflicts; self.suggestions = suggestions
    }

    public var totalCount: Int {
        unclassified.count + pendingCaptures.count + rejectedItems.count + conflicts.count + suggestions.count
    }
    public var isEmpty: Bool { totalCount == 0 }
}

public struct InboxUnclassified: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceText: String
    public var candidatePlanIds: [UUID]
    public var candidatePlanNames: [String]
    public var reasonText: String?
    public var capturedAt: Date
    public var captureId: UUID?
    public var kindHint: String?

    public init(id: UUID = UUID(), sourceText: String, candidatePlanIds: [UUID] = [],
                candidatePlanNames: [String] = [], reasonText: String? = nil,
                capturedAt: Date = Date(), captureId: UUID? = nil, kindHint: String? = nil) {
        self.id = id; self.sourceText = sourceText; self.candidatePlanIds = candidatePlanIds
        self.candidatePlanNames = candidatePlanNames; self.reasonText = reasonText
        self.capturedAt = capturedAt; self.captureId = captureId; self.kindHint = kindHint
    }

    /// 候选 ≤3（PRD 5.2）
    public var candidatesCapped: [String] { Array(candidatePlanNames.prefix(3)) }
    public var hasAmbiguity: Bool { candidatePlanIds.count > 1 }
}

public struct InboxRejected: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceSpan: String
    public var reasons: [RejectReason]
    public var captureId: UUID?
    public var suggestedAction: String?

    public init(id: UUID = UUID(), sourceSpan: String, reasons: [RejectReason],
                captureId: UUID? = nil, suggestedAction: String? = nil) {
        self.id = id; self.sourceSpan = sourceSpan; self.reasons = reasons
        self.captureId = captureId; self.suggestedAction = suggestedAction
    }
}

// MARK: - 搜索

public struct SearchResult: Identifiable, Hashable, Sendable {
    public var id: UUID { entityId }
    public var entityType: EntityType
    public var entityId: UUID
    public var title: String
    public var pathText: String
    public var snippet: String?
    public var dateText: String?
    public var statusText: String?
    public var planId: UUID?
    public var updatedAt: Date

    public init(entityType: EntityType, entityId: UUID, title: String, pathText: String = "",
                snippet: String? = nil, dateText: String? = nil, statusText: String? = nil,
                planId: UUID? = nil, updatedAt: Date = Date()) {
        self.entityType = entityType; self.entityId = entityId; self.title = title
        self.pathText = pathText; self.snippet = snippet; self.dateText = dateText
        self.statusText = statusText; self.planId = planId; self.updatedAt = updatedAt
    }
}

public struct SearchResultsView: Hashable, Sendable {
    public var query: String
    public var scope: SearchScope
    public var results: [SearchResult]

    public init(query: String, scope: SearchScope = .all, results: [SearchResult] = []) {
        self.query = query; self.scope = scope; self.results = results
    }

    public var isEmpty: Bool { results.isEmpty }
    public var totalCount: Int { results.count }

    /// 按类型分组（任务 / 计划 / 行动记录 / 想法 / 成果标题）
    public var grouped: [(EntityType, [SearchResult])] {
        let order: [EntityType] = [.plan, .task, .activity, .note, .measurement, .stage]
        return order.compactMap { type in
            let items = results.filter { $0.entityType == type }
            return items.isEmpty ? nil : (type, items)
        }
    }
}

// MARK: - 撤销 / 批量

public struct UndoResult: Hashable, Sendable {
    public var batchId: UUID
    public var undoneOperations: [UUID]
    /// (operation, 原因)：有后续编辑→列出冲突说明，跳过
    public var unsafeOperations: [(UUID, String)]
    public var nonUndoableOperations: [(UUID, OperationKind)]

    public init(batchId: UUID, undoneOperations: [UUID] = [],
                unsafeOperations: [(UUID, String)] = [],
                nonUndoableOperations: [(UUID, OperationKind)] = []) {
        self.batchId = batchId; self.undoneOperations = undoneOperations
        self.unsafeOperations = unsafeOperations; self.nonUndoableOperations = nonUndoableOperations
    }

    public static func == (lhs: UndoResult, rhs: UndoResult) -> Bool {
        lhs.batchId == rhs.batchId && lhs.undoneOperations == rhs.undoneOperations
            && lhs.unsafeOperations.map(\.0) == rhs.unsafeOperations.map(\.0)
            && lhs.nonUndoableOperations.map(\.0) == rhs.nonUndoableOperations.map(\.0)
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(batchId) }

    public var summaryText: String {
        if undoneOperations.isEmpty && unsafeOperations.isEmpty && nonUndoableOperations.isEmpty {
            return "没有可撤销的更改。"
        }
        var parts: [String] = []
        if !undoneOperations.isEmpty { parts.append("已撤销 \(undoneOperations.count) 项") }
        if !unsafeOperations.isEmpty { parts.append("\(unsafeOperations.count) 项因后续编辑未撤销") }
        if !nonUndoableOperations.isEmpty { parts.append("\(nonUndoableOperations.count) 项不可撤销") }
        return parts.joined(separator: " · ")
    }
}

/// 批量影响预览（D05-BulkPreview）
public struct ImpactPreview: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var affected: [ImpactLine]
    public var unaffected: [String]
    public var dependencyReleases: Int
    public var undoNote: String
    public var summaryText: String

    public init(id: UUID = UUID(), title: String, affected: [ImpactLine] = [], unaffected: [String] = [],
                dependencyReleases: Int = 0, undoNote: String = "确认后会作为一批提交，可一次撤销。",
                summaryText: String = "") {
        self.id = id; self.title = title; self.affected = affected; self.unaffected = unaffected
        self.dependencyReleases = dependencyReleases; self.undoNote = undoNote; self.summaryText = summaryText
    }

    public struct ImpactLine: Identifiable, Hashable, Sendable {
        public var id: UUID { entityId }
        public var entityId: UUID
        public var title: String
        public var changeText: String
        public var oldValue: String?
        public var newValue: String?

        public init(entityId: UUID, title: String, changeText: String,
                    oldValue: String? = nil, newValue: String? = nil) {
            self.entityId = entityId; self.title = title; self.changeText = changeText
            self.oldValue = oldValue; self.newValue = newValue
        }
    }

    /// 预览数字与实际影响一致
    public var affectedCountText: String { "\(affected.count) 项会改变" }
}

// MARK: - 档案 / 导出

public struct PlanArchive: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var planName: String
    public var archivedAt: Date
    public var leafDone: Int
    public var leafTotal: Int
    public var actionRecordCount: Int
    public var measurementCount: Int
    public var timelineEntries: [TimelineEntry]

    public init(id: UUID, planName: String, archivedAt: Date, leafDone: Int, leafTotal: Int,
                actionRecordCount: Int, measurementCount: Int, timelineEntries: [TimelineEntry] = []) {
        self.id = id; self.planName = planName; self.archivedAt = archivedAt
        self.leafDone = leafDone; self.leafTotal = leafTotal
        self.actionRecordCount = actionRecordCount; self.measurementCount = measurementCount
        self.timelineEntries = timelineEntries
    }

    public var summaryText: String {
        "\(leafTotal) 项任务 · 完成 \(leafDone) · \(actionRecordCount) 条行动记录 · \(measurementCount) 条结果"
    }
}

// MARK: - 可视化与统计条目

/// 重复行动单次实例的离散展示状态
public struct OccurrenceStatusItem: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case done, skipped, unrecorded, pending

        public var displayName: String {
            switch self {
            case .done: "已完成"
            case .skipped: "已跳过"
            case .unrecorded: "未记录"
            case .pending: "待做"
            }
        }
    }

    public var id: UUID
    public var date: DateOnly?
    public var state: State
    public var displayDateText: String

    public init(id: UUID = UUID(), date: DateOnly?, state: State, displayDateText: String) {
        self.id = id; self.date = date; self.state = state; self.displayDateText = displayDateText
    }
}

/// 时间线跨度项（计划、阶段或任务）
public struct TimelineSpanItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case plan, stage, task
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var startAt: TimePoint?
    public var endAt: TimePoint?
    public var isCompleted: Bool
    public var isOutRange: Bool
    public var depth: Int
    public var parentId: UUID?
    public var stageId: UUID?

    public init(id: UUID, kind: Kind, title: String, startAt: TimePoint?, endAt: TimePoint?,
                isCompleted: Bool = false, isOutRange: Bool = false, depth: Int = 0,
                parentId: UUID? = nil, stageId: UUID? = nil) {
        self.id = id; self.kind = kind; self.title = title
        self.startAt = startAt; self.endAt = endAt
        self.isCompleted = isCompleted; self.isOutRange = isOutRange
        self.depth = depth; self.parentId = parentId; self.stageId = stageId
    }

    public var startDateOnly: DateOnly? { startAt?.dateOnly }
    public var endDateOnly: DateOnly? { endAt?.dateOnly }
}

public struct PlanTimelineView: Hashable, Sendable {
    public var planId: UUID
    public var planName: String
    public var planStart: TimePoint?
    public var planEnd: TimePoint?
    public var spans: [TimelineSpanItem]
    public var unscheduledTasks: [Task]
    public var minDate: DateOnly?
    public var maxDate: DateOnly?

    public init(planId: UUID, planName: String, planStart: TimePoint?, planEnd: TimePoint?,
                spans: [TimelineSpanItem] = [], unscheduledTasks: [Task] = [],
                minDate: DateOnly? = nil, maxDate: DateOnly? = nil) {
        self.planId = planId; self.planName = planName; self.planStart = planStart; self.planEnd = planEnd
        self.spans = spans; self.unscheduledTasks = unscheduledTasks
        self.minDate = minDate; self.maxDate = maxDate
    }
}
