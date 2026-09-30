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
        case .setDependency, .setRecurrence: true
        default: false
        }
    }

    /// 是否必须先在本地检索既有对象（否则无法执行）
    public var routesToLocalSearch: Bool {
        switch self {
        case .completeTask, .logActivity, .matchOccurrence, .recordMeasurement,
             .scheduleExistingTask, .setDependency, .setRecurrence, .updateTask:
            true
        case .createTask, .needsClarification, .saveNote:
            false
        }
    }
}

// MARK: - 数据块

/// 日期解释（相对日期必须回填，便于校验一致性）
public struct AIDateInterpretation: Sendable, Hashable {
    public var rawText: String?
    public var resolvedDate: String?
    public var granularity: String?
    public var isHardDeadline: Bool

    public init(rawText: String? = nil, resolvedDate: String? = nil,
                granularity: String? = nil, isHardDeadline: Bool = false) {
        self.rawText = rawText; self.resolvedDate = resolvedDate
        self.granularity = granularity; self.isHardDeadline = isHardDeadline
    }
}

/// 结果记录块
public struct AIMeasurement: Sendable, Hashable {
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
public struct AINote: Sendable, Hashable {
    public var kind: String?
    public var text: String?

    public init(kind: String? = nil, text: String? = nil) {
        self.kind = kind; self.text = text
    }
}

/// 任务相关块（create/update/schedule/complete/dependency 共用）
public struct AIProposalTask: Sendable, Hashable {
    public var candidateTaskId: String?
    public var title: String?
    public var notes: String?
    public var planId: String?
    public var stageId: String?
    public var parentTaskId: String?
    public var scheduledDate: String?
    public var hardDeadline: String?
    public var estimateMinutes: Int?
    public var priority: String?
    public var tags: [String]
    public var dependencyIds: [String]

    public init(candidateTaskId: String? = nil, title: String? = nil, notes: String? = nil,
                planId: String? = nil, stageId: String? = nil, parentTaskId: String? = nil,
                scheduledDate: String? = nil, hardDeadline: String? = nil,
                estimateMinutes: Int? = nil, priority: String? = nil,
                tags: [String] = [], dependencyIds: [String] = []) {
        self.candidateTaskId = candidateTaskId; self.title = title; self.notes = notes
        self.planId = planId; self.stageId = stageId; self.parentTaskId = parentTaskId
        self.scheduledDate = scheduledDate; self.hardDeadline = hardDeadline
        self.estimateMinutes = estimateMinutes; self.priority = priority
        self.tags = tags; self.dependencyIds = dependencyIds
    }
}

/// 重复规则块
public struct AIRecurrence: Sendable, Hashable {
    public var pattern: String?
    public var count: Int?
    public var weekdays: [Int]
    public var effectiveFrom: String?

    public init(pattern: String? = nil, count: Int? = nil,
                weekdays: [Int] = [], effectiveFrom: String? = nil) {
        self.pattern = pattern; self.count = count
        self.weekdays = weekdays; self.effectiveFrom = effectiveFrom
    }
}

// MARK: - 单条提议

public struct AIProposalItem: Sendable, Hashable {
    public var sourceSpan: String?
    /// 原文偏移 [start, end)（对 `AIInput.text`）
    public var span: [Int]
    public var action: AIAction
    public var task: AIProposalTask?
    public var dateInterpretation: AIDateInterpretation?
    public var recurrence: AIRecurrence?
    public var measurement: AIMeasurement?
    public var note: AINote?
    public var confidence: Double
    public var needsConfirmation: Bool
    public var reason: String?
    public var clarificationQuestion: String?

    public init(sourceSpan: String? = nil, span: [Int], action: AIAction,
                task: AIProposalTask? = nil, dateInterpretation: AIDateInterpretation? = nil,
                recurrence: AIRecurrence? = nil, measurement: AIMeasurement? = nil,
                note: AINote? = nil, confidence: Double = 0, needsConfirmation: Bool = false,
                reason: String? = nil, clarificationQuestion: String? = nil) {
        self.sourceSpan = sourceSpan; self.span = span; self.action = action
        self.task = task; self.dateInterpretation = dateInterpretation
        self.recurrence = recurrence; self.measurement = measurement; self.note = note
        self.confidence = confidence; self.needsConfirmation = needsConfirmation
        self.reason = reason; self.clarificationQuestion = clarificationQuestion
    }

    /// 稳定标识（用于去重、收件箱展示与列表 id）
    public var id: String {
        if let sourceSpan, !sourceSpan.isEmpty { return sourceSpan }
        if span.count == 2 { return "\(action.rawValue)#\(span[0])-\(span[1])" }
        return action.rawValue
    }

    /// 与动作无关的数据块（V2：动作与数据块必须匹配）
    public var extraBlocks: [String] {
        let allowed = Self.allowedBlocks(for: action)
        var out: [String] = []
        if task != nil, !allowed.contains("task") { out.append("task") }
        if measurement != nil, !allowed.contains("measurement") { out.append("measurement") }
        if note != nil, !allowed.contains("note") { out.append("note") }
        if recurrence != nil, !allowed.contains("recurrence") { out.append("recurrence") }
        return out
    }

    static func allowedBlocks(for action: AIAction) -> Set<String> {
        switch action {
        case .createTask, .updateTask, .matchOccurrence, .completeTask,
             .scheduleExistingTask, .setDependency:
            return ["task"]
        case .logActivity:
            return ["task", "note"]
        case .recordMeasurement:
            return ["measurement"]
        case .saveNote:
            return ["note"]
        case .setRecurrence:
            return ["recurrence"]
        case .needsClarification:
            return []
        }
    }
}

// MARK: - 提案

public struct AIProposal: Sendable, Hashable {
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

    /// 工具名（Claude tool_use 用）
    public static let toolName = "movo_organize"

    /// 与 `AIProposalItem` 严格对应的 JSON Schema
    public static var jsonSchema: [String: JSONValue] {
        let taskBlock: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "candidate_task_id": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")]),
                "notes": .object(["type": .string("string")]),
                "plan_id": .object(["type": .string("string")]),
                "stage_id": .object(["type": .string("string")]),
                "parent_task_id": .object(["type": .string("string")]),
                "scheduled_date": .object(["type": .string("string"), "description": .string("yyyy-MM-dd")]),
                "hard_deadline": .object(["type": .string("string"), "description": .string("含时刻与时区的 ISO8601")]),
                "estimate_minutes": .object(["type": .string("integer")]),
                "priority": .object(["type": .string("string"), "enum": .array([.string("low"), .string("normal"), .string("high")])]),
                "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "dependency_ids": .object(["type": .string("array"), "items": .object(["type": .string("string")])])
            ])
        ])
        let dateInterpretation: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "raw_text": .object(["type": .string("string")]),
                "resolved_date": .object(["type": .string("string")]),
                "granularity": .object(["type": .string("string")]),
                "is_hard_deadline": .object(["type": .string("boolean")])
            ])
        ])
        let recurrenceBlock: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object(["type": .string("string"), "enum": .array([.string("daily"), .string("weekdays"), .string("weeklyCount")])]),
                "count": .object(["type": .string("integer")]),
                "weekdays": .object(["type": .string("array"), "items": .object(["type": .string("integer")])]),
                "effective_from": .object(["type": .string("string")])
            ])
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
                "date_interpretation": dateInterpretation,
                "recurrence": recurrenceBlock,
                "measurement": measurementBlock,
                "note": noteBlock,
                "confidence": .object(["type": .string("number")]),
                "needs_confirmation": .object(["type": .string("boolean")]),
                "reason": .object(["type": .string("string")]),
                "clarification_question": .object(["type": .string("string")])
            ]),
            "required": .array([.string("span"), .string("action")])
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
