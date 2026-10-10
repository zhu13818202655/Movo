//
//  Entities.swift
//  Domain/Models
//
//  3.2 实体字段表（定稿）。全部为 Sendable 值类型，客户端生成稳定 UUID。
//

import Foundation

// MARK: - Plan

public struct Plan: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String                       // 唯一必填项（REQ 07）
    public var kind: PlanKind
    public var category: PlanCategory?
    public var goalText: String?
    /// 起止时间均可选：两者都空表示还没想好，之后再补
    public var startAt: TimePoint?
    public var endAt: TimePoint?
    public var aliases: [String]
    public var contextPhrases: [String]
    public var excludedTerms: [String]
    /// 分类默认值的记录：工作/学习/生活默认 true，健康默认 false，未分类兜底 true（PRD 11.2）。
    /// **不参与判定**：是否把内容发给模型只由全局 AI 开关决定；本字段仅随实体同步与展示。
    public var cloudAIEnabled: Bool
    /// 是否同步 iCloud，默认 true（可逐计划关闭）
    public var syncEnabled: Bool
    public var status: PlanStatus
    public var pausedAt: DateOnly?
    public var resumedAt: DateOnly?
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, category, goalText, startAt, endAt, aliases, contextPhrases, excludedTerms
        case cloudAIEnabled, syncEnabled, status, pausedAt, resumedAt, sortIndex
        case createdAt, updatedAt, revision
    }

    /// 旧版字段：只读，用于升级前保存的数据
    private enum LegacyKeys: String, CodingKey { case targetDate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(PlanKind.self, forKey: .kind)
        category = try c.decodeIfPresent(PlanCategory.self, forKey: .category)
        goalText = try c.decodeIfPresent(String.self, forKey: .goalText)
        startAt = try c.decodeIfPresent(TimePoint.self, forKey: .startAt)
        var end = try c.decodeIfPresent(TimePoint.self, forKey: .endAt)
        if end == nil {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if let day = try legacy.decodeIfPresent(DateOnly.self, forKey: .targetDate) { end = .day(day) }
        }
        endAt = end
        aliases = try c.decode([String].self, forKey: .aliases)
        contextPhrases = try c.decode([String].self, forKey: .contextPhrases)
        excludedTerms = try c.decode([String].self, forKey: .excludedTerms)
        cloudAIEnabled = try c.decode(Bool.self, forKey: .cloudAIEnabled)
        syncEnabled = try c.decode(Bool.self, forKey: .syncEnabled)
        status = try c.decode(PlanStatus.self, forKey: .status)
        pausedAt = try c.decodeIfPresent(DateOnly.self, forKey: .pausedAt)
        resumedAt = try c.decodeIfPresent(DateOnly.self, forKey: .resumedAt)
        sortIndex = try c.decode(Int.self, forKey: .sortIndex)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        revision = try c.decode(Int.self, forKey: .revision)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        kind: PlanKind,
        category: PlanCategory? = nil,
        goalText: String? = nil,
        startAt: TimePoint? = nil,
        endAt: TimePoint? = nil,
        aliases: [String] = [],
        contextPhrases: [String] = [],
        excludedTerms: [String] = [],
        cloudAIEnabled: Bool? = nil,
        syncEnabled: Bool = true,
        status: PlanStatus = .active,
        pausedAt: DateOnly? = nil,
        resumedAt: DateOnly? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int = 1
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.category = category
        self.goalText = goalText
        self.startAt = startAt
        self.endAt = endAt
        self.aliases = aliases
        self.contextPhrases = contextPhrases
        self.excludedTerms = excludedTerms
        self.cloudAIEnabled = cloudAIEnabled ?? (category?.defaultsCloudAIEnabled ?? true)
        self.syncEnabled = syncEnabled
        self.status = status
        self.pausedAt = pausedAt
        self.resumedAt = resumedAt
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }

    /// 暂停区间 [pausedAt, resumedAt)：落在区间内的日期不实例化，且不补造（AC20）
    public func isPaused(on day: DateOnly) -> Bool {
        guard let pausedAt else { return false }
        if day < pausedAt { return false }
        if let resumedAt, day >= resumedAt { return false }
        return true
    }

    /// 归类信号（6.3）：名称 + 别名 + 常用表达
    public var classificationSignals: [String] {
        ([name] + aliases + contextPhrases).map { $0.lowercased() }
    }

    /// 展示用短标签「工作 · 交付型」
    public var taxonomyLabel: String {
        guard let category else { return kind.displayName }
        return "\(category.displayName) · \(kind.displayName)"
    }
}

// MARK: - Stage

public struct Stage: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var planId: UUID
    public var name: String
    /// 可选达成条件（用户设定或手动确认，AI 不得猜测，REQ 08）
    public var criteriaText: String?
    public var startAt: TimePoint?
    public var endAt: TimePoint?
    public var status: StageStatus
    public var achievedAt: Date?
    /// 阶段结构修改保留版本
    public var version: Int
    public var sortIndex: Int
    public var createdAt: Date
    public var revision: Int

    private enum CodingKeys: String, CodingKey {
        case id, planId, name, criteriaText, startAt, endAt, status, achievedAt
        case version, sortIndex, createdAt, revision
    }

    /// 旧版字段：只读，用于升级前保存的数据
    private enum LegacyKeys: String, CodingKey { case targetDate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        planId = try c.decode(UUID.self, forKey: .planId)
        name = try c.decode(String.self, forKey: .name)
        criteriaText = try c.decodeIfPresent(String.self, forKey: .criteriaText)
        startAt = try c.decodeIfPresent(TimePoint.self, forKey: .startAt)
        var end = try c.decodeIfPresent(TimePoint.self, forKey: .endAt)
        if end == nil {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if let day = try legacy.decodeIfPresent(DateOnly.self, forKey: .targetDate) { end = .day(day) }
        }
        endAt = end
        status = try c.decode(StageStatus.self, forKey: .status)
        achievedAt = try c.decodeIfPresent(Date.self, forKey: .achievedAt)
        version = try c.decode(Int.self, forKey: .version)
        sortIndex = try c.decode(Int.self, forKey: .sortIndex)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        revision = try c.decode(Int.self, forKey: .revision)
    }

    public init(id: UUID = UUID(), planId: UUID, name: String, criteriaText: String? = nil,
                startAt: TimePoint? = nil, endAt: TimePoint? = nil,
                status: StageStatus = .notStarted, achievedAt: Date? = nil,
                version: Int = 1, sortIndex: Int = 0, createdAt: Date = Date(), revision: Int = 1) {
        self.id = id; self.planId = planId; self.name = name; self.criteriaText = criteriaText
        self.startAt = startAt; self.endAt = endAt; self.status = status; self.achievedAt = achievedAt
        self.version = version; self.sortIndex = sortIndex; self.createdAt = createdAt; self.revision = revision
    }

    /// 达成只能由用户确认（awaitingConfirm → achieved）或预设明确规则触发
    public var canAutoAchieve: Bool { false }
}

// MARK: - PlanMetric

public struct PlanMetric: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var planId: UUID
    public var name: String                        // 如"体重"
    public var unit: String                        // 如"kg"
    /// 仅录入示例意义，不构成建议目标
    public var targetValue: Double?
    public var targetDirection: MetricDirection
    public var createdAt: Date
    public var revision: Int

    public init(id: UUID = UUID(), planId: UUID, name: String, unit: String,
                targetValue: Double? = nil, targetDirection: MetricDirection = .none,
                createdAt: Date = Date(), revision: Int = 1) {
        self.id = id; self.planId = planId; self.name = name; self.unit = unit
        self.targetValue = targetValue; self.targetDirection = targetDirection
        self.createdAt = createdAt; self.revision = revision
    }

    /// 单位显示名：中文常见单位转换展示
    public var unitDisplayName: String { PlanMetric.unitDisplayName(for: unit) }

    public static func unitDisplayName(for unit: String) -> String {
        switch unit {
        case "kg": "公斤"
        case "g": "克"
        case "cm": "厘米"
        case "min": "分钟"
        case "h": "小时"
        case "count": "次"
        default: unit
        }
    }
}

// MARK: - Task

public struct Task: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var planId: UUID?
    public var stageId: UUID?
    /// 支持多级子任务；父子同计划、同阶段，父链不得成环。
    public var parentId: UUID?
    public var title: String                       // ≤ 200 字
    public var notes: String?
    /// true = 重复行动模板，必须挂 RecurrenceRule（C4）
    public var isTemplate: Bool
    public var status: TaskStatus
    /// 起止时间均可选：两者都空表示暂存的想法；只有开始是「从何时开始」，只有结束是「截止」
    public var startAt: TimePoint?
    public var endAt: TimePoint?
    public var estimateMinutes: Int?
    public var priority: TaskPriority?
    public var tags: [String]
    /// 同计划内前置任务（方向=前置），C9 校验
    public var dependencyIDs: [UUID]
    public var source: SourceKind
    public var sourceCaptureId: UUID?
    /// 被 AI 推断的字段名列表，界面标"建议"
    public var suggestedFields: [String]
    public var doneAt: Date?
    public var cancelledAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int

    private enum CodingKeys: String, CodingKey {
        case id, planId, stageId, parentId, title, notes, isTemplate, status, startAt, endAt
        case estimateMinutes, priority, tags, dependencyIDs, source, sourceCaptureId
        case suggestedFields, doneAt, cancelledAt, createdAt, updatedAt, revision
    }

    /// 旧版字段：只读，用于升级前保存的数据
    private enum LegacyKeys: String, CodingKey { case scheduledDate, hardDeadline, timeHint }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        planId = try c.decodeIfPresent(UUID.self, forKey: .planId)
        stageId = try c.decodeIfPresent(UUID.self, forKey: .stageId)
        parentId = try c.decodeIfPresent(UUID.self, forKey: .parentId)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        isTemplate = try c.decode(Bool.self, forKey: .isTemplate)
        status = try c.decode(TaskStatus.self, forKey: .status)
        var start = try c.decodeIfPresent(TimePoint.self, forKey: .startAt)
        var end = try c.decodeIfPresent(TimePoint.self, forKey: .endAt)
        if start == nil || end == nil {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if start == nil, let day = try legacy.decodeIfPresent(DateOnly.self, forKey: .scheduledDate) {
                start = .day(day)
                // 只有精确时刻才能迁移：「早上/晚上」等模糊时段丢弃，不虚构时刻
                if let hint = try legacy.decodeIfPresent(TimeOfDayHint.self, forKey: .timeHint),
                   case .exact(let hour, let minute) = hint,
                   let point = TimePoint.makeInstant(on: day, at: TimeOfDay(hour: hour, minute: minute),
                                                     in: day.timeZone) {
                    start = point
                }
            }
            if end == nil, let deadline = try legacy.decodeIfPresent(DateTimeTZ.self, forKey: .hardDeadline) {
                end = .instant(deadline)
            }
        }
        startAt = start
        endAt = end
        estimateMinutes = try c.decodeIfPresent(Int.self, forKey: .estimateMinutes)
        priority = try c.decodeIfPresent(TaskPriority.self, forKey: .priority)
        tags = try c.decode([String].self, forKey: .tags)
        dependencyIDs = try c.decode([UUID].self, forKey: .dependencyIDs)
        source = try c.decode(SourceKind.self, forKey: .source)
        sourceCaptureId = try c.decodeIfPresent(UUID.self, forKey: .sourceCaptureId)
        suggestedFields = try c.decode([String].self, forKey: .suggestedFields)
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        cancelledAt = try c.decodeIfPresent(Date.self, forKey: .cancelledAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        revision = try c.decode(Int.self, forKey: .revision)
    }

    public init(
        id: UUID = UUID(), planId: UUID? = nil, stageId: UUID? = nil, parentId: UUID? = nil,
        title: String, notes: String? = nil, isTemplate: Bool = false, status: TaskStatus = .todo,
        startAt: TimePoint? = nil, endAt: TimePoint? = nil,
        estimateMinutes: Int? = nil, priority: TaskPriority? = nil, tags: [String] = [],
        dependencyIDs: [UUID] = [], source: SourceKind = .manual, sourceCaptureId: UUID? = nil,
        suggestedFields: [String] = [], doneAt: Date? = nil, cancelledAt: Date? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date(), revision: Int = 1
    ) {
        self.id = id; self.planId = planId; self.stageId = stageId; self.parentId = parentId
        self.title = title; self.notes = notes; self.isTemplate = isTemplate; self.status = status
        self.startAt = startAt; self.endAt = endAt
        self.estimateMinutes = estimateMinutes; self.priority = priority; self.tags = tags
        self.dependencyIDs = dependencyIDs; self.source = source; self.sourceCaptureId = sourceCaptureId
        self.suggestedFields = suggestedFields; self.doneAt = doneAt; self.cancelledAt = cancelledAt
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.revision = revision
    }

    /// 标题上限（V3 / 3.2）
    public static let maxTitleLength = 200

    /// 进度分母：叶子任务、未取消、非模板（4.4 progressFor .delivery）
    public var countsTowardProgress: Bool { !isTemplate && status.countsTowardProgress }

    /// 重复行动的步骤：模板下的任务（`isTemplate` 且有父节点），每次执行展开为一份清单，不进入待办列表
    public var isStep: Bool { isTemplate && parentId != nil }

    public func isSuggested(_ field: String) -> Bool { suggestedFields.contains(field) }

    /// 开始所在日期（列表筛选、「今日」使用）
    public var startDay: DateOnly? { startAt?.dateOnly }
    /// 结束所在日期
    public var endDay: DateOnly? { endAt?.dateOnly }

    /// 界面用的起止摘要：未设置的一端不显示
    public var timeRangeSummary: String {
        switch (startAt, endAt) {
        case (nil, nil): return "未安排时间"
        case (let s?, nil): return "开始 \(s.displayString)"
        case (nil, let e?): return "截止 \(e.displayString)"
        case (let s?, let e?): return "\(s.displayString) → \(e.displayString)"
        }
    }
}

// MARK: - RecurrenceRule

public struct RecurrenceRule: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var taskId: UUID
    public var pattern: RecurrencePattern
    /// 1–7（ISO），pattern=weekdays 时必填
    public var weekdays: [Int]?
    /// 1–7，pattern=weeklyCount 时必填
    public var weeklyCount: Int?
    public var effectiveFrom: DateOnly
    public var effectiveUntil: DateOnly?
    /// 每次实例的开始/结束时刻（可选，空表示全天），按实例所在日的时区解释
    public var dailyStart: TimeOfDay?
    public var dailyEnd: TimeOfDay?
    /// 规则修改 +1；仅作用于 effectiveFrom 及以后（AC22）
    public var version: Int
    /// 暂停期间不实例化、不补造
    public var status: RuleStatus
    public var createdAt: Date
    public var revision: Int

    public init(id: UUID = UUID(), taskId: UUID, pattern: RecurrencePattern,
                weekdays: [Int]? = nil, weeklyCount: Int? = nil,
                effectiveFrom: DateOnly, effectiveUntil: DateOnly? = nil,
                dailyStart: TimeOfDay? = nil, dailyEnd: TimeOfDay? = nil,
                version: Int = 1, status: RuleStatus = .active,
                createdAt: Date = Date(), revision: Int = 1) {
        self.id = id; self.taskId = taskId; self.pattern = pattern
        self.weekdays = weekdays; self.weeklyCount = weeklyCount
        self.effectiveFrom = effectiveFrom; self.effectiveUntil = effectiveUntil
        self.dailyStart = dailyStart; self.dailyEnd = dailyEnd
        self.version = version; self.status = status
        self.createdAt = createdAt; self.revision = revision
    }

    public var isActive: Bool { status == .active }

    /// 4.4 patternMatches
    public func matches(_ day: DateOnly) -> Bool {
        guard day >= effectiveFrom else { return false }
        if let until = effectiveUntil, day > until { return false }
        switch pattern {
        case .daily:
            return true
        case .weekdays:
            let wd = day.isoWeekday
            return (weekdays ?? [1, 2, 3, 4, 5]).contains(wd)
        case .weeklyCount:
            // 每周 N 次：不固定日期，实例由用户完成/跳过时以 occurredOn 记录
            return false
        }
    }

    public var ruleDescription: String {
        switch pattern {
        case .daily: return "每天"
        case .weekdays:
            let names = ["一", "二", "三", "四", "五", "六", "日"]
            let sorted = (weekdays ?? []).sorted()
            return "每周" + sorted.map { names[max(0, min(6, $0 - 1))] }.joined(separator: "、")
        case .weeklyCount: return "每周 \(weeklyCount ?? 0) 次"
        }
    }

    /// 每天时刻的展示，如「08:00–09:00」；未设置返回 nil
    public var dailyTimeDescription: String? {
        switch (dailyStart, dailyEnd) {
        case (nil, nil): return nil
        case (let s?, nil): return "\(s.displayString) 开始"
        case (nil, let e?): return "\(e.displayString) 前"
        case (let s?, let e?): return "\(s.displayString)–\(e.displayString)"
        }
    }

    /// 一眼看懂的完整频率描述：「每天 · 06:30 开始 · 到 11月9日」。
    /// 模板行、频率编辑器与 AI 预览共用同一套文案，避免同一条规则在三处显示不一致。
    public var scheduleDescription: String {
        var parts = [ruleDescription]
        if let time = dailyTimeDescription { parts.append(time) }
        if let until = effectiveUntil { parts.append("到 \(until.displayString)") }
        return parts.joined(separator: " · ")
    }

    /// 某天实例的开始：规则带时刻时为「该日 + 时刻」，否则是这一天
    public func occurrenceStart(on day: DateOnly) -> TimePoint {
        guard let time = dailyStart,
              let point = TimePoint.makeInstant(on: day, at: time, in: day.timeZone) else { return .day(day) }
        return point
    }

    /// 某天实例的结束：只有规则带结束时刻时才有
    public func occurrenceEnd(on day: DateOnly) -> TimePoint? {
        guard let time = dailyEnd else { return nil }
        return TimePoint.makeInstant(on: day, at: time, in: day.timeZone)
    }

    /// 8.6 / V8 字段完备性
    public var isFieldComplete: Bool {
        switch pattern {
        case .daily: true
        case .weekdays: !(weekdays ?? []).isEmpty
        case .weeklyCount: (weeklyCount ?? 0) >= 1 && (weeklyCount ?? 0) <= 7
        }
    }
}

// MARK: - RecurrenceOccurrence

/// 某一次执行里的步骤。第一次勾选或这一次被完成/跳过时从模板的步骤拍一份快照，
/// 之后修改模板步骤不再影响已发生的这一次。
public struct OccurrenceStep: Hashable, Sendable, Codable, Identifiable {
    /// 模板下步骤任务的 id
    public var id: UUID
    /// 上一级步骤的 id；顶层步骤为 nil
    public var parentId: UUID?
    public var title: String
    public var isDone: Bool

    public init(id: UUID, parentId: UUID? = nil, title: String, isDone: Bool = false) {
        self.id = id; self.parentId = parentId; self.title = title; self.isDone = isDone
    }
}

public struct RecurrenceOccurrence: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var ruleId: UUID
    public var ruleVersion: Int
    public var taskId: UUID
    public var planId: UUID?
    /// 固定日期模式实例化日期；weeklyCount 模式为 null
    public var scheduledOn: DateOnly?
    /// 完成/跳过实际发生日（weeklyCount 用）
    public var occurredOn: DateOnly?
    public var status: OccurrenceStatus
    public var doneAt: Date?
    public var revision: Int
    /// 这一次的步骤清单（带勾选状态）。nil = 还没有开始勾选，展示模板当前的步骤
    public var steps: [OccurrenceStep]?

    public init(id: UUID = UUID(), ruleId: UUID, ruleVersion: Int = 1, taskId: UUID,
                planId: UUID? = nil, scheduledOn: DateOnly? = nil, occurredOn: DateOnly? = nil,
                status: OccurrenceStatus = .pending, doneAt: Date? = nil, revision: Int = 1,
                steps: [OccurrenceStep]? = nil) {
        self.id = id; self.ruleId = ruleId; self.ruleVersion = ruleVersion; self.taskId = taskId
        self.planId = planId; self.scheduledOn = scheduledOn; self.occurredOn = occurredOn
        self.status = status; self.doneAt = doneAt; self.revision = revision; self.steps = steps
    }

    /// 唯一键 (ruleId, ruleVersion, scheduledOn)，幂等 upsert
    public var uniqueKey: String {
        "\(ruleId.uuidString)|\(ruleVersion)|\(scheduledOn?.iso8601DateString ?? "-")"
    }

    /// "未记录"为派生显示，不落库（4.4）
    public func isUnrecorded(asOf today: DateOnly) -> Bool {
        guard status == .pending, let scheduledOn else { return false }
        return scheduledOn < today
    }

    public func displayDate(asOf today: DateOnly) -> DateOnly? { scheduledOn ?? occurredOn }
}

// MARK: - ActionRecord

public struct ActionRecord: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    /// 记录归属的计划。独立待办的记录没有计划，所以可空。
    /// 有计划时由 `LogActivity` 保证与任务的归属一致；无计划记录在回顾统计里归入已有的「未分类」。
    public var planId: UUID?
    public var taskId: UUID?
    public var occurrenceId: UUID?
    /// 实际发生时间或已知粒度；补记昨天 → happenedAt=昨天
    public var happenedAt: TimeValue
    public var durationMinutes: Int?
    public var text: String?
    public var source: SourceKind
    /// 更正保留旧版本（PRD 3.4）
    public var isCorrection: Bool
    public var correctedFromId: UUID?
    /// 录入时间与实际发生时间分存（REQ 15）
    public var recordedAt: Date
    public var createdAt: Date
    public var revision: Int

    public init(id: UUID = UUID(), planId: UUID?, taskId: UUID? = nil, occurrenceId: UUID? = nil,
                happenedAt: TimeValue, durationMinutes: Int? = nil, text: String? = nil,
                source: SourceKind = .manual, isCorrection: Bool = false, correctedFromId: UUID? = nil,
                recordedAt: Date = Date(), createdAt: Date = Date(), revision: Int = 1) {
        self.id = id; self.planId = planId; self.taskId = taskId; self.occurrenceId = occurrenceId
        self.happenedAt = happenedAt; self.durationMinutes = durationMinutes; self.text = text
        self.source = source; self.isCorrection = isCorrection; self.correctedFromId = correctedFromId
        self.recordedAt = recordedAt; self.createdAt = createdAt; self.revision = revision
    }

    public var durationDisplay: String? {
        guard let d = durationMinutes else { return nil }
        if d >= 60 {
            let h = d / 60, m = d % 60
            return m == 0 ? "\(h)小时" : "\(h)小时\(m)分钟"
        }
        return "\(d)分钟"
    }
}

// MARK: - Measurement

public struct Measurement: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var planId: UUID
    public var metricId: UUID
    public var measuredAt: DateOnly
    /// 只存实际测量；缺测不补 0
    public var value: Double
    /// 冗余自 metric，导出可用
    public var unit: String
    public var note: String?
    public var source: SourceKind
    public var isCorrection: Bool
    public var correctedFromId: UUID?
    public var recordedAt: Date
    public var revision: Int

    public init(id: UUID = UUID(), planId: UUID, metricId: UUID, measuredAt: DateOnly,
                value: Double, unit: String, note: String? = nil, source: SourceKind = .manual,
                isCorrection: Bool = false, correctedFromId: UUID? = nil,
                recordedAt: Date = Date(), revision: Int = 1) {
        self.id = id; self.planId = planId; self.metricId = metricId; self.measuredAt = measuredAt
        self.value = value; self.unit = unit; self.note = note; self.source = source
        self.isCorrection = isCorrection; self.correctedFromId = correctedFromId
        self.recordedAt = recordedAt; self.revision = revision
    }

    /// V9：value 必须为有限数
    public var hasValidValue: Bool { value.isFinite }
}

// MARK: - Note

public struct Note: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var text: String
    public var kind: NoteKind                        // "以后也许想学摄影"→ idea，不建任务
    public var planId: UUID?
    public var capturedAt: Date
    public var source: SourceKind
    public var captureId: UUID?
    public var revision: Int

    public init(id: UUID = UUID(), text: String, kind: NoteKind = .idea, planId: UUID? = nil,
                capturedAt: Date = Date(), source: SourceKind = .manual, captureId: UUID? = nil,
                revision: Int = 1) {
        self.id = id; self.text = text; self.kind = kind; self.planId = planId
        self.capturedAt = capturedAt; self.source = source; self.captureId = captureId
        self.revision = revision
    }

    /// 想法/决定单独保留（AC01），不产生任务
    public var createsTask: Bool { false }
}

// MARK: - Capture

/// 拆分片段与来源定位。偏移基于 rawText/editedText。
public struct SourceSpan: Hashable, Sendable, Codable {
    public var start: Int
    public var end: Int
    public var text: String
    public var intent: String?

    public init(start: Int, end: Int, text: String, intent: String? = nil) {
        self.start = start; self.end = end; self.text = text; self.intent = intent
    }

    public var range: Range<Int> { start..<max(start, end) }
}

public struct Capture: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    /// 原文，AI 失败也保留
    public var rawText: String
    public var editedText: String?
    public var inputMode: InputMode
    public var capturedAt: Date
    public var timezoneID: String
    /// 处理中断可恢复（REQ 02）
    public var state: CaptureState
    public var batchId: UUID?
    public var segments: [SourceSpan]
    /// 持久化保存的提案 JSON（供离线/重启后恢复预览）
    public var proposalJSON: String?
    /// 原始音频默认不留存；仅转写失败且用户选择保留时 ≤24h
    public var audioRetention: AudioRetention
    public var audioExpiresAt: Date?
    public var revision: Int

    public init(id: UUID = UUID(), rawText: String, editedText: String? = nil,
                inputMode: InputMode = .text, capturedAt: Date = Date(), timezoneID: String,
                state: CaptureState = .saved, batchId: UUID? = nil, segments: [SourceSpan] = [],
                proposalJSON: String? = nil,
                audioRetention: AudioRetention = .none, audioExpiresAt: Date? = nil, revision: Int = 1) {
        self.id = id; self.rawText = rawText; self.editedText = editedText
        self.inputMode = inputMode; self.capturedAt = capturedAt; self.timezoneID = timezoneID
        self.state = state; self.batchId = batchId; self.segments = segments
        self.proposalJSON = proposalJSON
        self.audioRetention = audioRetention; self.audioExpiresAt = audioExpiresAt; self.revision = revision
    }

    /// 展示/处理用文本
    public var effectiveText: String { editedText ?? rawText }

    /// 原文与任何 AI 结果都必须可用（REQ 02 / AC12）
    public var canRecover: Bool { !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 原始音频从不进同步/导出/日志（9.7）
    public var hasRetainedAudio: Bool { audioRetention == .retain24h && audioExpiresAt != nil }

    /// 到期清理判断（7.3）
    public func audioExpired(at now: Date) -> Bool {
        guard let exp = audioExpiresAt else { return false }
        return now >= exp
    }
}

// MARK: - OperationBatch / Operation

public struct OperationBatch: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var captureId: UUID?
    public var source: BatchSource
    public var createdAt: Date
    public var deviceId: String
    public var state: BatchState
    /// 用户可见文案，如"已添加 2 项"
    public var summary: String
    public var revision: Int

    public init(id: UUID = UUID(), captureId: UUID? = nil, source: BatchSource = .userManual,
                createdAt: Date = Date(), deviceId: String, state: BatchState = .applied,
                summary: String = "", revision: Int = 1) {
        self.id = id; self.captureId = captureId; self.source = source
        self.createdAt = createdAt; self.deviceId = deviceId; self.state = state; self.summary = summary
        self.revision = revision
    }

    public var isUndoable: Bool { state == .applied || state == .partial }
}

public struct Operation: Identifiable, Hashable, Sendable, Codable {
    /// 幂等键；已存在同 id 的 ChangeEvent 时不再执行
    public var id: UUID
    public var batchId: UUID
    public var kind: OperationKind
    public var entityType: EntityType
    public var entityId: UUID
    /// 字段变更内容（JSON）
    public var payload: Data
    /// 执行时读取到的版本（乐观锁与撤销校验用）
    public var baseRevision: Int
    public var status: OperationStatus
    /// 用户可见归类依据（PRD 5.2）
    public var reason: String?
    public var createdAt: Date
    /// 撤销补偿事件指向原操作
    public var undoOf: UUID?
    public var revision: Int

    public init(id: UUID = UUID(), batchId: UUID, kind: OperationKind, entityType: EntityType,
                entityId: UUID, payload: Data = Data("{}".utf8), baseRevision: Int = 1,
                status: OperationStatus = .pending, reason: String? = nil,
                createdAt: Date = Date(), undoOf: UUID? = nil, revision: Int = 1) {
        self.id = id; self.batchId = batchId; self.kind = kind; self.entityType = entityType
        self.entityId = entityId; self.payload = payload; self.baseRevision = baseRevision
        self.status = status; self.reason = reason; self.createdAt = createdAt
        self.undoOf = undoOf; self.revision = revision
    }

    public var rejectionReason: String? { status == .rejected ? reason : nil }
}

// MARK: - ChangeEvent

/// 追加-only：不改写、不删除（随实体永久删除一并清理）。
/// 快照、撤销、同步、历史时间线全部从事件重建。
public struct ChangeEvent: Identifiable, Hashable, Sendable, Codable {
    /// 同步去重键
    public var id: UUID
    public var operationId: UUID
    public var batchId: UUID
    public var entityId: UUID
    public var entityType: EntityType
    /// 本次变更字段
    public var fields: [String]
    /// 每字段 {old, new}
    public var patch: [String: FieldPatch]
    public var baseRevision: Int
    public var newRevision: Int
    /// 实际发生 vs 录入（REQ 15）
    public var occurredAt: Date
    public var recordedAt: Date
    public var deviceId: String
    /// 撤销补偿事件指向原操作
    public var undoOf: UUID?
    /// P3 用：是否已推送
    public var synced: Bool

    public init(id: UUID = UUID(), operationId: UUID, batchId: UUID, entityId: UUID,
                entityType: EntityType, fields: [String], patch: [String: FieldPatch],
                baseRevision: Int, newRevision: Int, occurredAt: Date, recordedAt: Date,
                deviceId: String, undoOf: UUID? = nil, synced: Bool = false) {
        self.id = id; self.operationId = operationId; self.batchId = batchId
        self.entityId = entityId; self.entityType = entityType; self.fields = fields
        self.patch = patch; self.baseRevision = baseRevision; self.newRevision = newRevision
        self.occurredAt = occurredAt; self.recordedAt = recordedAt
        self.deviceId = deviceId; self.undoOf = undoOf; self.synced = synced
    }

    /// 快照重建用：对给定 JSON 快照应用本事件
    public func applying(to snapshot: [String: JSONValue]) -> [String: JSONValue] {
        var out = snapshot
        for (key, p) in patch { out[key] = p.new }
        return out
    }
}

/// 每字段 {old, new}
public struct FieldPatch: Hashable, Sendable, Codable {
    public var old: JSONValue
    public var new: JSONValue
    public init(old: JSONValue, new: JSONValue) { self.old = old; self.new = new }
}

/// 轻量 JSON 值，用于事件 patch 与快照重建（不依赖 Foundation JSONSerialization 的 Any）
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "1", "yes"].contains(s.lowercased())
        default: return nil
        }
    }
    public var isNull: Bool { if case .null = self { return true }; return false }
}

// MARK: - Suggestion / ReviewNote

public struct Suggestion: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var planId: UUID?
    public var weekStart: DateOnly?
    public var kind: SuggestionKind
    public var text: String
    /// 建议必须带来源（REQ 17）
    public var sourceText: String?
    public var sourceEntityId: UUID?
    public var status: SuggestionStatus
    public var acceptedTaskId: UUID?
    public var createdAt: Date
    public var revision: Int

    public init(id: UUID = UUID(), planId: UUID? = nil, weekStart: DateOnly? = nil,
                kind: SuggestionKind = .nextAction, text: String, sourceText: String? = nil,
                sourceEntityId: UUID? = nil, status: SuggestionStatus = .pending,
                acceptedTaskId: UUID? = nil, createdAt: Date = Date(), revision: Int = 1) {
        self.id = id; self.planId = planId; self.weekStart = weekStart; self.kind = kind
        self.text = text; self.sourceText = sourceText; self.sourceEntityId = sourceEntityId
        self.status = status; self.acceptedTaskId = acceptedTaskId
        self.createdAt = createdAt; self.revision = revision
    }

    /// 未采纳不产生任何任务（REQ 17）
    public var createsTaskWhenPending: Bool { false }
    public var hasSource: Bool { !(sourceText ?? "").isEmpty || sourceEntityId != nil }
}

public struct ReviewNote: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var planId: UUID?
    public var weekStart: DateOnly?
    public var text: String
    public var createdAt: Date
    public var revision: Int

    public init(id: UUID = UUID(), planId: UUID? = nil, weekStart: DateOnly? = nil,
                text: String, createdAt: Date = Date(), revision: Int = 1) {
        self.id = id; self.planId = planId; self.weekStart = weekStart
        self.text = text; self.createdAt = createdAt; self.revision = revision
    }
}

// MARK: - SyncConflict / Tombstone

public struct SyncConflict: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var entityType: EntityType
    public var entityId: UUID
    public var field: String
    public var localValue: JSONValue
    public var localRev: Int
    public var localDeviceId: String
    public var localChangedAt: Date
    public var remoteValue: JSONValue
    public var remoteRev: Int
    public var remoteDeviceId: String
    public var remoteChangedAt: Date
    public var baseRev: Int
    public var detectedAt: Date
    public var resolution: ConflictResolution?
    public var resolvedValue: JSONValue?
    public var resolvedAt: Date?
    public var revision: Int

    public init(id: UUID = UUID(), entityType: EntityType, entityId: UUID, field: String,
                localValue: JSONValue, localRev: Int, localDeviceId: String, localChangedAt: Date,
                remoteValue: JSONValue, remoteRev: Int, remoteDeviceId: String, remoteChangedAt: Date,
                baseRev: Int, detectedAt: Date = Date(), resolution: ConflictResolution? = nil,
                resolvedValue: JSONValue? = nil, resolvedAt: Date? = nil, revision: Int = 1) {
        self.id = id; self.entityType = entityType; self.entityId = entityId; self.field = field
        self.localValue = localValue; self.localRev = localRev
        self.localDeviceId = localDeviceId; self.localChangedAt = localChangedAt
        self.remoteValue = remoteValue; self.remoteRev = remoteRev
        self.remoteDeviceId = remoteDeviceId; self.remoteChangedAt = remoteChangedAt
        self.baseRev = baseRev; self.detectedAt = detectedAt; self.resolution = resolution
        self.resolvedValue = resolvedValue; self.resolvedAt = resolvedAt; self.revision = revision
    }

    public var isResolved: Bool { resolution != nil }

    /// 冲突解决前不丢失任一版本（P3 完成条件）
    public var bothVersionsPresent: Bool { !localValue.isNull && !remoteValue.isNull }
}

public struct Tombstone: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var entityType: EntityType
    public var entityId: UUID
    public var deletedAt: Date
    public var deviceId: String
    /// = deletedAt + 30d
    public var purgeAfter: Date
    public var restoredAt: Date?
    public var revision: Int

    public init(id: UUID = UUID(), entityType: EntityType, entityId: UUID, deletedAt: Date = Date(),
                deviceId: String, retentionDays: Int = 30, restoredAt: Date? = nil, revision: Int = 1) {
        self.id = id; self.entityType = entityType; self.entityId = entityId
        self.deletedAt = deletedAt; self.deviceId = deviceId
        self.purgeAfter = deletedAt.addingTimeInterval(Double(retentionDays) * 86_400)
        self.restoredAt = restoredAt; self.revision = revision
    }

    public var isActive: Bool { restoredAt == nil }

    public func isRecoverable(at now: Date) -> Bool { isActive && now < purgeAfter }

    public func daysRemaining(at now: Date) -> Int {
        max(0, Int(ceil(purgeAfter.timeIntervalSince(now) / 86_400)))
    }
}

// MARK: - SyncState

public enum SyncState: Hashable, Sendable, Codable {
    case notSignedIn
    case idle
    case syncing(pendingCount: Int)
    case upToDate(lastSyncedAt: Date?)
    case failed(reason: String, retryAt: Date?)
    case conflictPending(count: Int)

    public var displayText: String {
        switch self {
        case .notSignedIn: return "未登录 iCloud"
        case .idle: return "就绪"
        case .syncing(let n): return "同步中 · \(n) 项待传"
        case .upToDate(let d):
            guard let d else { return "已同步" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_Hans_CN")
            f.dateFormat = "M月d日 HH:mm"
            return "已同步 · \(f.string(from: d))"
        case .failed(let r, _): return "同步失败 · \(r)"
        case .conflictPending(let n): return "待处理冲突 \(n) 项"
        }
    }

    public var pendingCount: Int { if case .syncing(let n) = self { return n }; return 0 }
    public var hasConflict: Bool { if case .conflictPending = self { return true }; return false }
}

/// 同步状态在「设置」入口（顶部齿轮）上的外显级别。
///
/// 设置是唯一入口，同步的细节都在设置页里；这一层只回答一个问题：
/// 「有没有需要用户现在就知道的事」。正常状态一律返回 nil ——
/// 顶部不该和设置页重复表达同一个状态，只有进行中与出问题两种才值得占一个角标。
///
/// 这里只做分类，图标与配色由视图层决定，因此可以脱离 UI 单测。
public enum SyncAttention: String, Sendable, Hashable, CaseIterable {
    /// 正在同步：进行中，不是问题
    case activity
    /// 同步失败或存在待确认冲突：需要用户处理
    case issue

    /// 正常状态（未登录 / 就绪 / 已同步）返回 nil。
    ///
    /// 「未登录 iCloud」也算正常：本应用本机优先，默认就不开 iCloud
    /// （见 `Movo/project.yml` 的 `MovoICloudContainerID`），
    /// 账号状态在设置页里说明即可，不必长期在顶部报警。
    public init?(_ state: SyncState) {
        switch state {
        case .syncing: self = .activity
        case .failed, .conflictPending: self = .issue
        case .notSignedIn, .idle, .upToDate: return nil
        }
    }
}

// MARK: - 删除条目 / 收件箱

public struct DeletedEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID { tombstone.entityId }
    public var tombstone: Tombstone
    public var displayName: String
    public var descendantCount: Int

    public init(tombstone: Tombstone, displayName: String, descendantCount: Int = 0) {
        self.tombstone = tombstone; self.displayName = displayName; self.descendantCount = descendantCount
    }

    public func canRestore(at now: Date) -> Bool { tombstone.isRecoverable(at: now) }
}
