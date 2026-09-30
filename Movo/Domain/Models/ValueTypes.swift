//
//  ValueTypes.swift
//  Domain/Models
//
//  3.1 值类型与枚举。DateOnly 与 DateTimeTZ 是两种独立值类型，
//  禁止用裸 Date 表达"某天"（AC02：安排日期与硬截止必须可分辨）。
//

import Foundation

// MARK: - 枚举

/// 计划类型：交付／改善／持续
public enum PlanKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case delivery, improvement, maintenance
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .delivery: "交付型"
        case .improvement: "改善型"
        case .maintenance: "持续型"
        }
    }

    /// 4.3 PlanSummary 的进度口径
    public var progressStyle: String {
        switch self {
        case .delivery: "叶子任务 x/y"
        case .improvement: "周期行动 + 指标，不合成总百分比"
        case .maintenance: "周期计数，不显示总体百分比"
        }
    }

    /// 持续型无需结束日期、无强制阶段（AC23）
    public var requiresEndDate: Bool { self != .maintenance }
    public var showsOverallPercentage: Bool { self == .delivery }
}

/// 分类（可选）
public enum PlanCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case work, study, health, life
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .work: "工作"
        case .study: "学习"
        case .health: "健康"
        case .life: "生活"
        }
    }

    /// 健康及用户标记敏感：云 AI 默认关闭（PRD 11.2）
    public var defaultsCloudAIEnabled: Bool { self != .health }
}

public enum PlanStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case active, paused, archived
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .active: "进行中"
        case .paused: "已暂停"
        case .archived: "已归档"
        }
    }
}

public enum TaskStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case todo, inProgress, blocked, done, cancelled
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .todo: "待办"
        case .inProgress: "进行中"
        case .blocked: "受阻"
        case .done: "已完成"
        case .cancelled: "已取消"
        }
    }
    /// 进度分母剔除已取消；模板任务另行剔除
    public var countsTowardProgress: Bool { self != .cancelled }
    public var isOpen: Bool { self == .todo || self == .inProgress || self == .blocked }
    /// 4.4 dependencyStatus：已完成/已取消视为不再阻塞
    public var satisfiesDependency: Bool { self == .done || self == .cancelled }
}

public enum TaskPriority: String, Codable, Sendable, CaseIterable, Identifiable {
    case low, normal, high
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .low: "低"
        case .normal: "普通"
        case .high: "高"
        }
    }
}

public enum OccurrenceStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case pending, done, skipped
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .pending: "待做"
        case .done: "已完成"
        case .skipped: "已跳过"
        }
    }
}

public enum RecurrencePattern: String, Codable, Sendable, CaseIterable, Identifiable {
    case daily, weekdays, weeklyCount
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .daily: "每天"
        case .weekdays: "工作日"
        case .weeklyCount: "每周次数"
        }
    }
}

public enum StageStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case notStarted, inProgress, awaitingConfirm, achieved, paused, cancelled
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .notStarted: "未开始"
        case .inProgress: "进行中"
        case .awaitingConfirm: "待确认"
        case .achieved: "已达成"
        case .paused: "已暂停"
        case .cancelled: "已取消"
        }
    }
    /// 阶段达成只能由用户确认或预设明确规则触发（REQ 08）
    public var isAchieved: Bool { self == .achieved }
}

public enum SourceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case manual, text, voice, ai
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .manual: "手动"
        case .text: "文字"
        case .voice: "语音"
        case .ai: "AI 整理"
        }
    }
}

public enum MetricDirection: String, Codable, Sendable, CaseIterable, Identifiable {
    case increase, decrease, none
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .increase: "越高越好"
        case .decrease: "越低越好"
        case .none: "不设定方向"
        }
    }
    /// 方向仅用于展示，不构成建议目标（REQ 21）
    public var isAdvisoryOnly: Bool { true }
}

public enum NoteKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case idea, decision, memo
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .idea: "想法"
        case .decision: "决定"
        case .memo: "备忘"
        }
    }
}

public enum InputMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case text, voice, paste
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .text: "文字"
        case .voice: "语音"
        case .paste: "粘贴"
        }
    }
}

/// Capture 处理状态：处理中断可恢复（REQ 02）
public enum CaptureState: String, Codable, Sendable, CaseIterable, Identifiable {
    case saved, processing, aiSucceeded, aiPartial, aiFailed
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .saved: "已保存原文"
        case .processing: "整理中"
        case .aiSucceeded: "已整理"
        case .aiPartial: "部分整理"
        case .aiFailed: "整理失败"
        }
    }
    public var isTerminal: Bool { self == .aiSucceeded || self == .aiPartial || self == .aiFailed }
}

public enum AudioRetention: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case retain24h
    public var id: String { rawValue }

    public static let retentionHours = 24
}

/// 重复规则状态：暂停期间不实例化、不补造
public enum RuleStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case active, paused
    public var id: String { rawValue }
    public var displayName: String { self == .active ? "生效中" : "已暂停" }
}

public enum BatchSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case userManual, ai, system
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .userManual: "手动"
        case .ai: "AI 整理"
        case .system: "系统"
        }
    }
}

public enum BatchState: String, Codable, Sendable, CaseIterable, Identifiable {
    case applied, partial, failed, undone
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .applied: "已应用"
        case .partial: "部分应用"
        case .failed: "失败"
        case .undone: "已撤销"
        }
    }
}

public enum OperationStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case pending, applied, rejected, undone
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .pending: "待执行"
        case .applied: "已执行"
        case .rejected: "已拒绝"
        case .undone: "已撤销"
        }
    }
}

public enum SuggestionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case nextAction = "next_action"
    case adjustFrequency = "adjust_frequency"
    case newStage = "new_stage"
    case other
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .nextAction: "下一步行动"
        case .adjustFrequency: "调整频率"
        case .newStage: "新阶段"
        case .other: "其他"
        }
    }
}

public enum SuggestionStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case pending, accepted, dismissed
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .pending: "未采纳"
        case .accepted: "已采纳"
        case .dismissed: "已忽略"
        }
    }
}

public enum ConflictResolution: String, Codable, Sendable, CaseIterable, Identifiable {
    case local, remote, custom
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .local: "保留这台设备的版本"
        case .remote: "保留另一台设备的版本"
        case .custom: "使用自定义值"
        }
    }
}

public enum PermissionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case microphone, speech, notification
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .microphone: "麦克风"
        case .speech: "语音识别"
        case .notification: "通知"
        }
    }
}

public enum SpeechFailReason: String, Codable, Sendable, CaseIterable, Identifiable {
    case permissionDenied, unsupportedLocale, onDeviceUnavailable, resourceMissing, transcriptionFailed, cancelled, interrupted
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .permissionDenied: "没有语音识别权限"
        case .unsupportedLocale: "此语言暂不支持本机识别"
        case .onDeviceUnavailable: "此设备不支持本机识别该语言"
        case .resourceMissing: "语言资源尚未安装"
        case .transcriptionFailed: "没有识别到可靠文字"
        case .cancelled: "已取消"
        case .interrupted: "录音被系统中断"
        }
    }
}

public enum AIStage: String, Codable, Sendable, CaseIterable, Identifiable {
    case auth, rateLimited, timeout, network, parse, invalidRequest, unknown
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .auth: "鉴权失败"
        case .rateLimited: "请求过于频繁"
        case .timeout: "请求超时"
        case .network: "网络不可用"
        case .parse: "返回内容无法解析"
        case .invalidRequest: "服务端拒绝了这次请求"
        case .unknown: "未知错误"
        }
    }
}

/// AI 提供商。仅内置厂商会读取 `ModelCatalog`；`custom` 由用户在设置页自行填写
/// Base URL / 模型 ID（协议固定为 OpenAI 兼容）。
public enum AIVendor: String, Codable, Sendable, CaseIterable, Identifiable {
    case deepseek
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .custom: "自定义"
        }
    }

    /// 内置厂商的端点与模型清单来自目录；自定义厂商来自用户配置。
    public var isBuiltin: Bool {
        switch self {
        case .deepseek: true
        case .custom: false
        }
    }

    /// 8.1 Keychain service 名
    public var keychainService: String { "Movo.AIKey.\(rawValue)" }
}

public enum EntityType: String, Codable, Sendable, CaseIterable, Identifiable {
    case plan, stage, metric, task, rule, occurrence, activity, measurement, note, capture
    case batch, operation, event, suggestion, reviewNote, conflict, tombstone
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .plan: "计划"
        case .stage: "阶段目标"
        case .metric: "结果指标"
        case .task: "任务"
        case .rule: "重复规则"
        case .occurrence: "重复实例"
        case .activity: "行动记录"
        case .measurement: "结果测量"
        case .note: "想法"
        case .capture: "输入原文"
        case .batch: "操作批"
        case .operation: "操作"
        case .event: "变更事件"
        case .suggestion: "建议"
        case .reviewNote: "回顾补记"
        case .conflict: "同步冲突"
        case .tombstone: "删除标记"
        }
    }
}

/// 4.2 命令清单 → OperationKind（语义由 ChangeEvent + OperationKind 表达，不建 30 个事件类）
public enum OperationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case createPlan, updatePlan, pausePlan, resumePlan, deletePlan, restoreEntity
    case createStage, updateStage, createMetric, updateMetric
    case createTask, updateTask, deleteTask, scheduleTask, setDeadline, completeTask, reopenTask, cancelTask
    case completeOccurrence, skipOccurrence
    case logActivity, correctActivity
    case recordMeasurement, correctMeasurement
    case createRecurrence, changeRecurrence
    case reassignTask
    case addDependency, removeDependency
    case batchOperation
    case createNote
    case addSuggestion, acceptSuggestion, dismissSuggestion
    case resolveConflict
    case processCapture
    case undoBatch
    public var id: String { rawValue }

    /// 4.4 撤销算法：不可撤销集
    public var isUndoable: Bool {
        switch self {
        case .deletePlan, .deleteTask, .resolveConflict, .restoreEntity, .undoBatch: false
        default: true
        }
    }

    public var displayName: String {
        switch self {
        case .createPlan: "建立计划"
        case .updatePlan: "修改计划"
        case .pausePlan: "暂停计划"
        case .resumePlan: "恢复计划"
        case .deletePlan: "删除计划"
        case .restoreEntity: "恢复内容"
        case .createStage: "新建阶段"
        case .updateStage: "修改阶段"
        case .createMetric: "新建指标"
        case .updateMetric: "修改指标"
        case .createTask: "新增任务"
        case .updateTask: "修改任务"
        case .deleteTask: "删除待办及子任务"
        case .scheduleTask: "安排日期"
        case .setDeadline: "设置硬截止"
        case .completeTask: "完成任务"
        case .reopenTask: "重新打开"
        case .cancelTask: "取消任务"
        case .completeOccurrence: "完成本次"
        case .skipOccurrence: "跳过本次"
        case .logActivity: "记录行动"
        case .correctActivity: "更正记录"
        case .recordMeasurement: "记录结果"
        case .correctMeasurement: "更正结果"
        case .createRecurrence: "设置重复"
        case .changeRecurrence: "调整频率"
        case .reassignTask: "调整归属"
        case .addDependency: "添加前置"
        case .removeDependency: "解除前置"
        case .batchOperation: "批量操作"
        case .createNote: "记下想法"
        case .addSuggestion: "生成建议"
        case .acceptSuggestion: "采纳建议"
        case .dismissSuggestion: "忽略建议"
        case .resolveConflict: "处理冲突"
        case .processCapture: "保存原文"
        case .undoBatch: "撤销本批"
        }
    }
}

// MARK: - 时间语义

/// 日期语义（"周五交报告"）。
/// sourceTZ 为创建时的 IANA 时区，跨时区旅行不改日期。
public struct DateOnly: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let y: Int
    public let m: Int
    public let d: Int
    public let sourceTZ: String

    public init(y: Int, m: Int, d: Int, sourceTZ: String) {
        self.y = y
        self.m = m
        self.d = d
        self.sourceTZ = sourceTZ
    }

    /// 相对日期按**输入发生时刻**的设备时区解析（3.1 / A.2）
    public init(from date: Date, in tz: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.y = c.year ?? 1970
        self.m = c.month ?? 1
        self.d = c.day ?? 1
        self.sourceTZ = tz.identifier
    }

    public var timeZone: TimeZone { TimeZone(identifier: sourceTZ) ?? .gmt }

    /// 当天 00:00 的绝对时刻（用 sourceTZ 解释）
    public func startOfDay(in tz: TimeZone? = nil) -> Date {
        let zone = tz ?? timeZone
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = 0; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    /// 展示/比较换算；sourceTZ 仅记录创建语义
    public func resolved(in tz: TimeZone) -> Date { startOfDay(in: tz) }

    /// 当天正午时刻（避免夏令时边界把日期推前/推后一天）
    public var noon: Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = 12; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days: Int, in tz: TimeZone? = nil) -> DateOnly {
        let zone = tz ?? timeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let next = cal.date(byAdding: .day, value: days, to: noon) ?? noon
        return DateOnly(from: next, in: zone)
    }

    public func adding(months: Int, in tz: TimeZone? = nil) -> DateOnly {
        let zone = tz ?? timeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let next = cal.date(byAdding: .month, value: months, to: noon) ?? noon
        return DateOnly(from: next, in: zone)
    }

    /// 两个日期相差天数（self → other）
    public func days(until other: DateOnly) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let a = cal.startOfDay(for: noon)
        let b = cal.startOfDay(for: other.noon)
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// ISO 周序号 1=周一 … 7=周日
    public var isoWeekday: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2
        let wd = cal.component(.weekday, from: noon) // 1=周日
        return wd == 1 ? 7 : wd - 1
    }

    /// 本周一
    public func startOfWeek(in tz: TimeZone? = nil) -> DateOnly {
        adding(days: -(isoWeekday - 1), in: tz)
    }

    public var isWeekend: Bool { isoWeekday >= 6 }

    /// 固定 yyyy-MM-dd（2.3）
    public var iso8601DateString: String {
        String(format: "%04d-%02d-%02d", y, m, d)
    }
    public var description: String { iso8601DateString }

    public var displayString: String { "\(m)月\(d)日" }
    public var displayStringWithWeekday: String {
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        return "\(m)月\(d)日，周\(names[max(0, min(6, isoWeekday - 1))])"
    }

    public init?(iso8601DateString s: String, sourceTZ: String) {
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(y: y, m: m, d: d, sourceTZ: sourceTZ)
    }

    public static func < (lhs: DateOnly, rhs: DateOnly) -> Bool {
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        if lhs.m != rhs.m { return lhs.m < rhs.m }
        return lhs.d < rhs.d
    }
}

/// 带时刻的安排/截止。
public struct DateTimeTZ: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let epoch: Date
    public let tzID: String

    public init(epoch: Date, tzID: String) {
        self.epoch = epoch
        self.tzID = tzID
    }

    public init(_ date: Date, in tz: TimeZone) {
        self.epoch = date
        self.tzID = tz.identifier
    }

    public var timeZone: TimeZone { TimeZone(identifier: tzID) ?? .gmt }

    public var dateOnly: DateOnly { DateOnly(from: epoch, in: timeZone) }

    public var iso8601String: String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: epoch)
    }
    public var description: String { iso8601String }

    public var displayString: String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: epoch)
    }

    public static func < (lhs: DateTimeTZ, rhs: DateTimeTZ) -> Bool { lhs.epoch < rhs.epoch }
}

/// 记录时间粒度。补记昨天 → happenedAt = 昨天（REQ 15）
public enum TimeValue: Hashable, Sendable, Codable {
    case precise(Date)
    case day(DateOnly)
    case month(DateOnly)

    /// 归一化到用于排序/比较的绝对时刻
    public var sortEpoch: Date {
        switch self {
        case .precise(let d): d
        case .day(let d): d.noon
        case .month(let d): d.noon
        }
    }

    public var dateOnly: DateOnly? {
        switch self {
        case .precise: nil
        case .day(let d), .month(let d): d
        }
    }

    public var granularityName: String {
        switch self {
        case .precise: "具体时刻"
        case .day: "某一天"
        case .month: "某个月"
        }
    }
}

/// 时段提示（如 morning/night/具体时刻）。仅展示，不产生通知。
public enum TimeOfDayHint: Hashable, Sendable, Codable {
    case morning, noon, evening, night
    case exact(hour: Int, minute: Int)

    public var displayName: String {
        switch self {
        case .morning: "早上"
        case .noon: "中午"
        case .evening: "傍晚"
        case .night: "晚上"
        case .exact(let h, let m): String(format: "%02d:%02d", h, m)
        }
    }

    /// 仅用于排序展示，不生成通知（REQ 13）
    public var sortOrder: Int {
        switch self {
        case .morning: 0
        case .noon: 1
        case .evening: 2
        case .exact(let h, let m): h * 60 + m
        case .night: 1440
        }
    }

    public var producesNotification: Bool { false }
}

// MARK: - 范围 / 过滤

public struct DateOnlyRange: Hashable, Sendable, Codable {
    public var lower: DateOnly
    public var upper: DateOnly
    public init(lower: DateOnly, upper: DateOnly) {
        self.lower = lower
        self.upper = upper
    }
    public func contains(_ d: DateOnly) -> Bool { d >= lower && d <= upper }
    public var dayCount: Int { max(0, lower.days(until: upper) + 1) }

    public static func week(containing d: DateOnly) -> DateOnlyRange {
        let start = d.startOfWeek()
        return DateOnlyRange(lower: start, upper: start.adding(days: 6))
    }
}

public struct PlanFilter: Hashable, Sendable, Codable {
    public var categories: Set<PlanCategory>
    public var statuses: Set<PlanStatus>
    public var searchText: String?

    public init(categories: Set<PlanCategory> = [], statuses: Set<PlanStatus> = [], searchText: String? = nil) {
        self.categories = categories
        self.statuses = statuses
        self.searchText = searchText
    }

    /// 默认列表：全部进行中
    public static var active: PlanFilter { PlanFilter(categories: [], statuses: [.active]) }
    public static var all: PlanFilter { PlanFilter() }
}

public struct HistoryFilter: Hashable, Sendable, Codable {
    public var includeCompleted: Bool
    public var includeAdjustments: Bool
    public var includeRecords: Bool
    public var includeCancelled: Bool

    public init(includeCompleted: Bool = true, includeAdjustments: Bool = true,
                includeRecords: Bool = true, includeCancelled: Bool = false) {
        self.includeCompleted = includeCompleted
        self.includeAdjustments = includeAdjustments
        self.includeRecords = includeRecords
        self.includeCancelled = includeCancelled
    }
    public static var all: HistoryFilter { HistoryFilter(includeCancelled: true) }
}

public enum SearchScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case all, tasks, plans, activities, notes, measurements
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .all: "全部"
        case .tasks: "任务"
        case .plans: "计划"
        case .activities: "行动记录"
        case .notes: "想法"
        case .measurements: "结果标题"
        }
    }
}

public enum SearchRecency: String, Codable, Sendable, CaseIterable, Identifiable {
    case recent, all
    public var id: String { rawValue }
    public var displayName: String { self == .recent ? "近期" : "全部" }
}
