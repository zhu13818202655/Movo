//
//  AIProposal.swift
//  Intelligence/Planning
//
//  6.5 / 附录 A.1 输出契约。模型只提议、不执行；只能引用上下文里出现过的 id。
//  解析失败或动作不在枚举 → 该片段进收件箱，绝不猜。
//

import Foundation

// MARK: - 动作

/// 模型可提议的动作。raw value 即线上契约字符串。
public enum AIAction: String, Sendable, Codable, CaseIterable {
    case completeTask = "complete_task"
    case createTask = "create_task"
    case createPlan = "create_plan"
    case logActivity = "log_activity"
    case matchOccurrence = "match_occurrence"
    case needsClarification = "needs_clarification"
    case recordMeasurement = "record_measurement"
    case saveNote = "save_note"
    case scheduleExistingTask = "schedule_existing_task"
    case setDependency = "set_dependency"
    case setRecurrence = "set_recurrence"
    case updateTask = "update_task"

    public var displayName: String {
        switch self {
        case .completeTask: "标记完成"
        case .createTask: "新增待办"
        case .createPlan: "新建计划"
        case .logActivity: "记录行动"
        case .matchOccurrence: "匹配重复项"
        case .needsClarification: "需要澄清"
        case .recordMeasurement: "记录结果"
        case .saveNote: "保存想法"
        case .scheduleExistingTask: "安排到某天"
        case .setDependency: "设置先后顺序"
        case .setRecurrence: "设置重复"
        case .updateTask: "修改任务"
        }
    }

    /// 6.4：高影响动作一律 needs_confirmation（不得自动执行）
    public var requiresConfirmationByRule: Bool {
        switch self {
        case .createPlan, .setDependency, .setRecurrence: true
        default: false
        }
    }

    /// 是否必须先在本地检索既有对象（否则无法执行）
    public var routesToLocalSearch: Bool {
        switch self {
        case .completeTask, .logActivity, .matchOccurrence, .recordMeasurement,
             .scheduleExistingTask, .setDependency, .setRecurrence, .updateTask:
            true
        case .createTask, .createPlan, .needsClarification, .saveNote:
            false
        }
    }
}

// MARK: - 数据块

/// 日期解释（相对日期必须回填，便于校验一致性）
public struct AIDateInterpretation: Sendable, Hashable, Codable {
    public var rawText: String?
    public var resolvedDate: String?
    public var granularity: String?

    public init(rawText: String? = nil, resolvedDate: String? = nil, granularity: String? = nil) {
        self.rawText = rawText; self.resolvedDate = resolvedDate; self.granularity = granularity
    }
}

/// 结果记录块
public struct AIMeasurement: Sendable, Hashable, Codable {
    public var metricId: String?
    public var value: Double?
    public var unit: String?
    public var measuredAt: String?
    public var note: String?

    public init(metricId: String? = nil, value: Double? = nil, unit: String? = nil,
                measuredAt: String? = nil, note: String? = nil) {
        self.metricId = metricId; self.value = value; self.unit = unit
        self.measuredAt = measuredAt; self.note = note
    }
}

/// 想法 / 备忘块
public struct AINote: Sendable, Hashable, Codable {
    public var kind: String?
    public var text: String?

    public init(kind: String? = nil, text: String? = nil) {
        self.kind = kind; self.text = text
    }
}

/// 步骤块（重复任务模板下挂的执行步骤，支持多级）
public struct AIProposalStep: Sendable, Hashable, Codable {
    public var ref: String?
    public var parentRef: String?
    public var title: String
    public var notes: String?
    public var steps: [AIProposalStep]

    public init(ref: String? = nil, parentRef: String? = nil,
                title: String, notes: String? = nil,
                steps: [AIProposalStep] = []) {
        self.ref = ref; self.parentRef = parentRef
        self.title = title; self.notes = notes
        self.steps = steps
    }
}

/// 阶段块（创建计划时可选带阶段）
public struct AIProposalStage: Sendable, Hashable, Codable {
    public var ref: String?
    public var name: String
    public var startAt: String?
    public var endAt: String?

    public init(ref: String? = nil, name: String, startAt: String? = nil, endAt: String? = nil) {
        self.ref = ref; self.name = name; self.startAt = startAt; self.endAt = endAt
    }
}

/// 任务相关块（create/update/schedule/complete/dependency 共用）
public struct AIProposalTask: Sendable, Hashable, Codable {
    public var ref: String?
    public var candidateTaskId: String?
    public var title: String?
    public var notes: String?
    public var planId: String?
    public var stageId: String?
    public var parentTaskId: String?
    public var stageRef: String?
    public var parentRef: String?
    /// yyyy-MM-dd（某一天）或带时区的 ISO8601（某一时刻）；没把握就不填
    public var startAt: String?
    public var endAt: String?
    public var estimateMinutes: Int?
    public var priority: String?
    public var tags: [String]
    public var dependencyIds: [String]
    public var recurrence: AIRecurrence?
    public var steps: [AIProposalStep]

    public init(ref: String? = nil, candidateTaskId: String? = nil, title: String? = nil, notes: String? = nil,
                planId: String? = nil, stageId: String? = nil, parentTaskId: String? = nil,
                stageRef: String? = nil, parentRef: String? = nil,
                startAt: String? = nil, endAt: String? = nil,
                estimateMinutes: Int? = nil, priority: String? = nil,
                tags: [String] = [], dependencyIds: [String] = [],
                recurrence: AIRecurrence? = nil, steps: [AIProposalStep] = []) {
        self.ref = ref; self.candidateTaskId = candidateTaskId; self.title = title; self.notes = notes
        self.planId = planId; self.stageId = stageId; self.parentTaskId = parentTaskId
        self.stageRef = stageRef; self.parentRef = parentRef
        self.startAt = startAt; self.endAt = endAt
        self.estimateMinutes = estimateMinutes; self.priority = priority
        self.tags = tags; self.dependencyIds = dependencyIds
        self.recurrence = recurrence; self.steps = steps
    }
}

/// 重复规则块
public struct AIRecurrence: Sendable, Hashable, Codable {
    public var pattern: String?
    public var count: Int?
    public var weekdays: [Int]
    public var effectiveFrom: String?
    /// 重复到哪一天为止（yyyy-MM-dd）。不填表示长期持续。
    /// 「从10月9号到11月9号」的结束日期必须落在这里，否则会被当成无限期重复。
    public var effectiveUntil: String?
    /// 每次执行的开始时刻（HH:mm），按实例所在日解释；不填表示全天的行动。
    public var dailyStart: String?
    /// 每次执行的结束时刻（HH:mm）。只在用户明确给出时段时才填。
    public var dailyEnd: String?

    public init(pattern: String? = nil, count: Int? = nil,
                weekdays: [Int] = [], effectiveFrom: String? = nil,
                effectiveUntil: String? = nil,
                dailyStart: String? = nil, dailyEnd: String? = nil) {
        self.pattern = pattern; self.count = count
        self.weekdays = weekdays; self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.dailyStart = dailyStart; self.dailyEnd = dailyEnd
    }

    /// 「HH:mm」或「HH:mm:ss」→ `TimeOfDay`；格式不对返回 nil（不猜测，不静默取整）。
    public static func timeOfDay(from raw: String?) -> TimeOfDay? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        let second = parts.count >= 3 ? Int(parts[2]) : 0
        guard let second else { return nil }
        let value = TimeOfDay(hour: hour, minute: minute, second: second)
        return value.isValid ? value : nil
    }

    /// 规则里显式给出的每次开始时刻
    public var resolvedDailyStart: TimeOfDay? { Self.timeOfDay(from: dailyStart) }
    /// 规则里显式给出的每次结束时刻
    public var resolvedDailyEnd: TimeOfDay? { Self.timeOfDay(from: dailyEnd) }
}

// MARK: - 单条提议

public struct AIProposalPlan: Sendable, Hashable, Codable {
    public var ref: String?
    public var name: String
    public var kind: PlanKind
    public var goal: String?
    public var startAt: String?
    public var endAt: String?
    public var stages: [AIProposalStage]
    public var tasks: [AIProposalTask]

    public init(ref: String? = nil, name: String, kind: PlanKind, goal: String? = nil,
                startAt: String? = nil, endAt: String? = nil,
                stages: [AIProposalStage] = [], tasks: [AIProposalTask] = []) {
        self.ref = ref; self.name = name; self.kind = kind; self.goal = goal
        self.startAt = startAt; self.endAt = endAt
        self.stages = stages; self.tasks = tasks
    }
}

public struct AIProposalItem: Sendable, Hashable, Codable {
    public var sourceSpan: String?
    /// 原文偏移 [start, end)（对 `AIInput.text`）
    public var span: [Int]
    public var action: AIAction
    public var task: AIProposalTask?
    public var plan: AIProposalPlan?
    public var dateInterpretation: AIDateInterpretation?
    public var recurrence: AIRecurrence?
    public var measurement: AIMeasurement?
    public var note: AINote?
    public var confidence: Double
    public var needsConfirmation: Bool
    public var reason: String?
    public var clarificationQuestion: String?

    public init(sourceSpan: String? = nil, span: [Int], action: AIAction,
                task: AIProposalTask? = nil, plan: AIProposalPlan? = nil,
                dateInterpretation: AIDateInterpretation? = nil,
                recurrence: AIRecurrence? = nil, measurement: AIMeasurement? = nil,
                note: AINote? = nil, confidence: Double = 0, needsConfirmation: Bool = true,
                reason: String? = nil, clarificationQuestion: String? = nil) {
        self.sourceSpan = sourceSpan; self.span = span; self.action = action
        self.task = task; self.plan = plan; self.dateInterpretation = dateInterpretation
        self.recurrence = recurrence; self.measurement = measurement; self.note = note
        self.confidence = confidence; self.needsConfirmation = needsConfirmation
        self.reason = reason; self.clarificationQuestion = clarificationQuestion
    }

    /// 稳定标识（用于去重、收件箱展示与列表 id）
    public var id: String {
        [action.rawValue, sourceSpan ?? span.map(String.init).joined(separator: "-"),
         task?.ref ?? task?.candidateTaskId ?? task?.title ?? plan?.name ?? "", task?.startAt ?? "",
         measurement?.metricId ?? "", measurement?.measuredAt ?? "", note?.text ?? ""].joined(separator: "|")
    }

    /// 与动作无关的数据块（V2：动作与数据块必须匹配）
    public var extraBlocks: [String] {
        let allowed = Self.allowedBlocks(for: action)
        var out: [String] = []
        if task != nil, !allowed.contains("task") { out.append("task") }
        if plan != nil, !allowed.contains("plan") { out.append("plan") }
        if measurement != nil, !allowed.contains("measurement") { out.append("measurement") }
        if note != nil, !allowed.contains("note") { out.append("note") }
        if recurrence != nil, !allowed.contains("recurrence") { out.append("recurrence") }
        return out
    }

    static func allowedBlocks(for action: AIAction) -> Set<String> {
        switch action {
        case .createPlan:
            return ["plan"]
        case .createTask:
            return ["task", "recurrence"]
        case .updateTask, .matchOccurrence, .completeTask,
             .scheduleExistingTask, .setDependency:
            return ["task"]
        case .logActivity:
            return ["task", "note"]
        case .recordMeasurement:
            return ["measurement"]
        case .saveNote:
            return ["note"]
        case .setRecurrence:
            return ["task", "recurrence"]
        case .needsClarification:
            return []
        }
    }
}

// MARK: - 提案

public struct AIProposal: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var items: [AIProposalItem]
    public var provider: String?
    public var model: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var latencyMs: Int?

    public init(schemaVersion: Int = 1, items: [AIProposalItem],
                provider: String? = nil, model: String? = nil,
                promptTokens: Int? = nil, completionTokens: Int? = nil,
                latencyMs: Int? = nil) {
        self.schemaVersion = schemaVersion; self.items = items
        self.provider = provider; self.model = model
        self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.latencyMs = latencyMs
    }

    public var isEmpty: Bool { items.isEmpty }
}

// MARK: - 结构化输出 Schema（8.4 工具调用 / JSON 模式共用）

public enum AIProposalSchema {

    /// 工具名（供支持 tool_use 的厂商未来接入；当前适配器走 JSON 模式）
    public static let toolName = "movo_organize"

    /// 与 `AIProposalItem` 严格对应的 JSON Schema
    public static var jsonSchema: [String: JSONValue] {
        let recurrenceBlock: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object(["type": .string("string"), "enum": .array([.string("daily"), .string("weekdays"), .string("weeklyCount")])]),
                "count": .object(["type": .string("integer"), "description": .string("pattern=weeklyCount 时必填，1–7")]),
                "weekdays": .object(["type": .string("array"), "items": .object(["type": .string("integer")]), "description": .string("pattern=weekdays 时必填，1=周一 … 7=周日")]),
                "effective_from": .object(["type": .string("string"), "description": .string("重复从哪一天开始生效，yyyy-MM-dd")]),
                "effective_until": .object(["type": .string("string"), "description": .string("重复到哪一天为止，yyyy-MM-dd；用户说了结束日期（如「到11月9号」）必须填这里，长期持续才留空")]),
                "daily_start": .object(["type": .string("string"), "description": .string("每次执行的开始时刻 HH:mm，如「早上6:30」填 06:30；没有明确时刻就不填")]),
                "daily_end": .object(["type": .string("string"), "description": .string("每次执行的结束时刻 HH:mm；只在用户给出时段时填")])
            ])
        ])
        let stepBlock: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "ref": .object(["type": .string("string")]),
                "parent_ref": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")]),
                "notes": .object(["type": .string("string")])
            ]),
            "required": .array([.string("title")])
        ])
        let taskBlock: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "ref": .object(["type": .string("string"), "description": .string("批内临时标识，如 task_1")]),
                "candidate_task_id": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")]),
                "notes": .object(["type": .string("string")]),
                "plan_id": .object(["type": .string("string")]),
                "stage_id": .object(["type": .string("string")]),
                "parent_task_id": .object(["type": .string("string")]),
                "stage_ref": .object(["type": .string("string"), "description": .string("批内引用的阶段 ref")]),
                "parent_ref": .object(["type": .string("string"), "description": .string("批内引用的父任务 ref")]),
                "start_at": .object(["type": .string("string"), "description": .string("开始时间：yyyy-MM-dd（某一天）或带时区的 ISO8601（某一时刻），没把握就不填")]),
                "end_at": .object(["type": .string("string"), "description": .string("结束时间：格式同 start_at，没把握就不填")]),
                "estimate_minutes": .object(["type": .string("integer")]),
                "priority": .object(["type": .string("string"), "enum": .array([.string("low"), .string("normal"), .string("high")])]),
                "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "dependency_ids": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "recurrence": recurrenceBlock,
                "steps": .object(["type": .string("array"), "items": stepBlock, "description": .string("仅重复任务可带执行步骤清单")])
            ])
        ])
        let dateInterpretation: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "raw_text": .object(["type": .string("string")]),
                "resolved_date": .object(["type": .string("string")]),
                "granularity": .object(["type": .string("string")])
            ])
        ])
        let stageBlock: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "ref": .object(["type": .string("string"), "description": .string("阶段临时标识，如 stage_1")]),
                "name": .object(["type": .string("string")]),
                "start_at": .object(["type": .string("string")]),
                "end_at": .object(["type": .string("string")])
            ]),
            "required": .array([.string("name")])
        ])
        let planBlock: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "ref": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string"), "enum": .array(PlanKind.allCases.map { .string($0.rawValue) })]),
                "goal": .object(["type": .string("string")]),
                "start_at": .object(["type": .string("string"), "description": .string("yyyy-MM-dd 或带时区的 ISO8601，仅用户明确指定时填写")]),
                "end_at": .object(["type": .string("string"), "description": .string("格式同 start_at，仅用户明确指定时填写")]),
                "stages": .object(["type": .string("array"), "items": stageBlock]),
                "tasks": .object(["type": .string("array"), "maxItems": .int(10), "items": taskBlock])
            ]),
            "required": .array([.string("name"), .string("kind")])
        ])
        let measurementBlock: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "metric_id": .object(["type": .string("string")]),
                "value": .object(["type": .string("number")]),
                "unit": .object(["type": .string("string")]),
                "measured_at": .object(["type": .string("string")]),
                "note": .object(["type": .string("string")])
            ])
        ])
        let noteBlock: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object(["type": .string("string"), "enum": .array([.string("idea"), .string("decision"), .string("memo")])]),
                "text": .object(["type": .string("string")])
            ])
        ])
        let item: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "source_span": .object(["type": .string("string")]),
                "span": .object(["type": .string("array"), "items": .object(["type": .string("integer")])]),
                "action": .object([
                    "type": .string("string"),
                    "enum": .array(AIAction.allCases.map { .string($0.rawValue) })
                ]),
                "task": taskBlock,
                "plan": planBlock,
                "date_interpretation": dateInterpretation,
                "recurrence": recurrenceBlock,
                "measurement": measurementBlock,
                "note": noteBlock,
                "needs_confirmation": .object(["type": .string("boolean")]),
                "reason": .object(["type": .string("string")]),
                "clarification_question": .object(["type": .string("string")])
            ]),
            "required": .array([.string("source_span"), .string("span"), .string("action"),
                                .string("needs_confirmation")])
        ])
        return [
            "type": .string("object"),
            "properties": .object([
                "schema_version": .object(["type": .string("integer")]),
                "items": .object(["type": .string("array"), "items": item])
            ]),
            "required": .array([.string("items")])
        ]
    }
}
