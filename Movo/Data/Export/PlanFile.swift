//
//  PlanFile.swift
//  Data/Export
//
//  `.movo.json` 标准文件：导出、导入与空模板共用同一份结构。
//  · 面向交换而不是备份：只含结构与内容，不含设备标识、API Key、音频。
//  · 文件内的 id 是外部标识，导入时映射为新的实体 id；不写 id 的条目也能导入。
//  · 多级子任务用 `children` 嵌套，重复行动的多级步骤用 `steps` 嵌套。
//  · 顶层任务写回所属阶段的 id（`stage`）；子任务与步骤跟随上级的阶段，不重复写。
//  · 时间：某一天写 yyyy-MM-dd，某一时刻写带时区偏移的 ISO8601。
//

import Foundation

// MARK: - 文件结构

public struct PlanFile: Codable, Sendable, Equatable {
    public static let formatID = "movo.plan-file"
    public static let currentSchemaVersion = 1
    public static let fileExtension = "movo.json"

    public var format: String
    public var schemaVersion: Int
    public var exportedAt: String?
    public var application: String?
    /// 计划（含阶段、指标、任务；记录、测量值、笔记是可选内容）
    public var plans: [FilePlan]?
    /// 不属于任何计划的独立任务；导入时选了目标计划就放进那个计划
    public var tasks: [FileTask]?
    /// 以下四项需要导入时选择目标计划，用来向已有计划补充内容
    public var stages: [FileStage]?
    public var metrics: [FileMetric]?
    public var records: [FileRecord]?
    public var measurements: [FileMeasurement]?
    /// 不属于任何计划的笔记；选了目标计划就放进那个计划
    public var notes: [FileNote]?

    public init(exportedAt: String? = nil, plans: [FilePlan]? = nil,
                tasks: [FileTask]? = nil, notes: [FileNote]? = nil,
                stages: [FileStage]? = nil, metrics: [FileMetric]? = nil,
                records: [FileRecord]? = nil, measurements: [FileMeasurement]? = nil) {
        self.format = Self.formatID
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.application = "Movo"
        self.plans = plans; self.tasks = tasks; self.notes = notes
        self.stages = stages; self.metrics = metrics
        self.records = records; self.measurements = measurements
    }
}

public struct FilePlan: Codable, Sendable, Equatable {
    public var id: String?
    public var name: String
    /// delivery / improvement / maintenance，缺省为 delivery
    public var kind: String?
    /// work / study / health / life
    public var category: String?
    public var goal: String?
    public var startAt: String?
    public var endAt: String?
    public var aliases: [String]?
    public var stages: [FileStage]?
    public var metrics: [FileMetric]?
    public var tasks: [FileTask]?
    public var records: [FileRecord]?
    public var measurements: [FileMeasurement]?
    public var notes: [FileNote]?

    public init(id: String? = nil, name: String, kind: String? = nil, category: String? = nil,
                goal: String? = nil, startAt: String? = nil, endAt: String? = nil,
                aliases: [String]? = nil, stages: [FileStage]? = nil, metrics: [FileMetric]? = nil,
                tasks: [FileTask]? = nil, records: [FileRecord]? = nil,
                measurements: [FileMeasurement]? = nil, notes: [FileNote]? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.category = category; self.goal = goal
        self.startAt = startAt; self.endAt = endAt; self.aliases = aliases; self.stages = stages
        self.metrics = metrics; self.tasks = tasks; self.records = records
        self.measurements = measurements; self.notes = notes
    }
}

public struct FileStage: Codable, Sendable, Equatable {
    public var id: String?
    public var name: String
    public var criteria: String?
    public var startAt: String?
    public var endAt: String?

    public init(id: String? = nil, name: String, criteria: String? = nil,
                startAt: String? = nil, endAt: String? = nil) {
        self.id = id; self.name = name; self.criteria = criteria
        self.startAt = startAt; self.endAt = endAt
    }
}

public struct FileMetric: Codable, Sendable, Equatable {
    public var id: String?
    public var name: String
    public var unit: String
    public var targetValue: Double?
    /// increase / decrease / none
    public var direction: String?

    public init(id: String? = nil, name: String, unit: String, targetValue: Double? = nil,
                direction: String? = nil) {
        self.id = id; self.name = name; self.unit = unit
        self.targetValue = targetValue; self.direction = direction
    }
}

public struct FileTask: Codable, Sendable, Equatable {
    public var id: String?
    public var title: String
    public var notes: String?
    /// todo / inProgress / blocked / done / cancelled，缺省为 todo；有子任务的待办由子任务汇总，不写 status
    public var status: String?
    /// 阶段的 id 或名称；子任务跟随上级的阶段
    public var stage: String?
    public var startAt: String?
    public var endAt: String?
    public var estimateMinutes: Int?
    /// low / normal / high
    public var priority: String?
    public var tags: [String]?
    /// 前置任务的 id（同一个计划内）
    public var dependsOn: [String]?
    /// 有它就是重复行动
    public var recurrence: FileRecurrence?
    /// 重复行动的多级步骤
    public var steps: [FileStep]?
    /// 多级子任务（重复行动不使用）
    public var children: [FileTask]?

    public init(id: String? = nil, title: String, notes: String? = nil, status: String? = nil,
                stage: String? = nil, startAt: String? = nil, endAt: String? = nil,
                estimateMinutes: Int? = nil, priority: String? = nil, tags: [String]? = nil,
                dependsOn: [String]? = nil, recurrence: FileRecurrence? = nil,
                steps: [FileStep]? = nil, children: [FileTask]? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.status = status
        self.stage = stage; self.startAt = startAt; self.endAt = endAt
        self.estimateMinutes = estimateMinutes; self.priority = priority; self.tags = tags
        self.dependsOn = dependsOn; self.recurrence = recurrence; self.steps = steps
        self.children = children
    }
}

public struct FileRecurrence: Codable, Sendable, Equatable {
    /// daily / weekdays / weeklyCount
    public var pattern: String
    /// 1–7（周一到周日），pattern 为 weekdays 时必填
    public var weekdays: [Int]?
    /// 1–7，pattern 为 weeklyCount 时必填
    public var weeklyCount: Int?
    /// yyyy-MM-dd，缺省为导入当天
    public var effectiveFrom: String?
    public var effectiveUntil: String?
    /// 每次的开始 / 结束时刻 HH:mm，缺省表示全天
    public var dailyStart: String?
    public var dailyEnd: String?

    public init(pattern: String, weekdays: [Int]? = nil, weeklyCount: Int? = nil,
                effectiveFrom: String? = nil, effectiveUntil: String? = nil,
                dailyStart: String? = nil, dailyEnd: String? = nil) {
        self.pattern = pattern; self.weekdays = weekdays; self.weeklyCount = weeklyCount
        self.effectiveFrom = effectiveFrom; self.effectiveUntil = effectiveUntil
        self.dailyStart = dailyStart; self.dailyEnd = dailyEnd
    }
}

public struct FileStep: Codable, Sendable, Equatable {
    public var id: String?
    public var title: String
    public var children: [FileStep]?

    public init(id: String? = nil, title: String, children: [FileStep]? = nil) {
        self.id = id; self.title = title; self.children = children
    }
}

/// 行动记录（可选内容）
public struct FileRecord: Codable, Sendable, Equatable {
    public var id: String?
    /// 关联任务的 id
    public var task: String?
    /// yyyy-MM-dd 或带时区的 ISO8601
    public var at: String
    public var minutes: Int?
    public var text: String?

    public init(id: String? = nil, task: String? = nil, at: String, minutes: Int? = nil, text: String? = nil) {
        self.id = id; self.task = task; self.at = at; self.minutes = minutes; self.text = text
    }
}

/// 测量值（可选内容）
public struct FileMeasurement: Codable, Sendable, Equatable {
    public var id: String?
    /// 指标的 id 或名称
    public var metric: String
    /// yyyy-MM-dd
    public var at: String
    public var value: Double
    public var note: String?

    public init(id: String? = nil, metric: String, at: String, value: Double, note: String? = nil) {
        self.id = id; self.metric = metric; self.at = at; self.value = value; self.note = note
    }
}

/// 笔记（可选内容）
public struct FileNote: Codable, Sendable, Equatable {
    public var id: String?
    public var text: String
    /// idea / decision / memo
    public var kind: String?

    public init(id: String? = nil, text: String, kind: String? = nil) {
        self.id = id; self.text = text; self.kind = kind
    }
}

// MARK: - 编解码

public enum PlanFileCodec {

    public static func encode(_ file: PlanFile) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(file), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 解析并检查版本。文件不合法时抛 `PlanFileError`，消息可直接展示给用户。
    public static func decode(_ data: Data) throws -> PlanFile {
        let file: PlanFile
        do {
            file = try JSONDecoder().decode(PlanFile.self, from: data)
        } catch let error as DecodingError {
            throw PlanFileError.malformed(describe(error))
        } catch {
            throw PlanFileError.malformed("文件不是有效的 JSON。")
        }
        guard file.format == PlanFile.formatID else {
            throw PlanFileError.notAPlanFile
        }
        guard file.schemaVersion >= 1 else {
            throw PlanFileError.malformed("schemaVersion 必须是大于等于 1 的整数。")
        }
        guard file.schemaVersion <= PlanFile.currentSchemaVersion else {
            throw PlanFileError.newerVersion(file.schemaVersion)
        }
        return migrate(file)
    }

    /// 旧版本文件升级到当前结构。目前只有第 1 版，保留入口给后续版本。
    static func migrate(_ file: PlanFile) -> PlanFile { file }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map { key -> String in
                key.intValue.map { "[\($0 + 1)]" } ?? key.stringValue
            }
            return parts.isEmpty ? "文件根部" : parts.joined(separator: " / ")
        }
        switch error {
        case .keyNotFound(let key, let context):
            let where_ = context.codingPath.isEmpty ? "" : "（位置：\(path(context))）"
            return "缺少必填字段「\(key.stringValue)」\(where_)。"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "字段类型不对（位置：\(path(context))）。"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "文件不是有效的 JSON。" : "字段内容不对（位置：\(path(context))）。"
        @unknown default:
            return "文件内容无法解析。"
        }
    }
}

public enum PlanFileError: Error, Sendable, Equatable {
    case notAPlanFile
    case newerVersion(Int)
    case malformed(String)

    public var message: String {
        switch self {
        case .notAPlanFile:
            return "这不是 Movo 文件（缺少 format = \"\(PlanFile.formatID)\"）。"
        case .newerVersion(let version):
            return "这个文件的版本是 \(version)，比当前 Movo 支持的版本（\(PlanFile.currentSchemaVersion)）新。请先升级 Movo 再导入。"
        case .malformed(let detail):
            return detail
        }
    }
}

// MARK: - 导出：领域数据 → 文件

public struct PlanFileOptions: Sendable, Equatable {
    /// 行动记录、测量值、笔记默认不导出，由用户自己勾选
    public var includeRecords: Bool
    public var includeMeasurements: Bool
    public var includeNotes: Bool

    public init(includeRecords: Bool = false, includeMeasurements: Bool = false, includeNotes: Bool = false) {
        self.includeRecords = includeRecords
        self.includeMeasurements = includeMeasurements
        self.includeNotes = includeNotes
    }
}

public enum PlanFileBuilder {

    /// 选择范围 → 文件。`standaloneTasks` 是没有计划的任务（含重复行动及其步骤）；
    /// `standaloneRecords` 是没有计划的行动记录，写进顶层 `records`。
    public static func build(selections: [ExportPlanSelection], standaloneTasks: [Task],
                             standaloneRules: [RecurrenceRule],
                             standaloneRecords: [ActionRecord] = [], standaloneNotes: [Note],
                             options: PlanFileOptions, exportedAt: Date) -> PlanFile {
        let stamp = ISO8601DateFormatter().string(from: exportedAt)
        let plans = selections.map { plan(from: $0, options: options) }
        let loose = taskTree(standaloneTasks, rules: standaloneRules, stages: [])
        var records: [FileRecord] = []
        if options.includeRecords {
            records = CorrectionHistory.current(standaloneRecords)
                .map { activity in
                    FileRecord(id: activity.id.uuidString, task: activity.taskId?.uuidString,
                               at: timeText(activity.happenedAt), minutes: activity.durationMinutes,
                               text: activity.text)
                }
        }
        var notes: [FileNote] = []
        if options.includeNotes {
            notes = standaloneNotes.sorted { $0.capturedAt < $1.capturedAt }
                .map { FileNote(id: $0.id.uuidString, text: $0.text, kind: $0.kind.rawValue) }
        }
        return PlanFile(exportedAt: stamp,
                        plans: plans.isEmpty ? nil : plans,
                        tasks: loose.isEmpty ? nil : loose,
                        notes: notes.isEmpty ? nil : notes,
                        records: records.isEmpty ? nil : records)
    }

    static func plan(from selection: ExportPlanSelection, options: PlanFileOptions) -> FilePlan {
        let plan = selection.plan
        let stages = selection.stages.sorted { $0.sortIndex < $1.sortIndex }
            .map { FileStage(id: $0.id.uuidString, name: $0.name, criteria: $0.criteriaText,
                             startAt: $0.startAt?.iso8601String, endAt: $0.endAt?.iso8601String) }
        let metrics = selection.metrics.sorted { $0.createdAt < $1.createdAt }
            .map { FileMetric(id: $0.id.uuidString, name: $0.name, unit: $0.unit,
                              targetValue: $0.targetValue, direction: $0.targetDirection.rawValue) }

        var records: [FileRecord] = []
        if options.includeRecords {
            records = CorrectionHistory.current(selection.activities)
                .map { activity in
                    FileRecord(id: activity.id.uuidString, task: activity.taskId?.uuidString,
                               at: timeText(activity.happenedAt), minutes: activity.durationMinutes,
                               text: activity.text)
                }
        }
        var measurements: [FileMeasurement] = []
        if options.includeMeasurements {
            measurements = CorrectionHistory.current(selection.measurements).filter { $0.value.isFinite }
                .map { FileMeasurement(id: $0.id.uuidString, metric: $0.metricId.uuidString,
                                       at: $0.measuredAt.iso8601DateString, value: $0.value, note: $0.note) }
        }
        var notes: [FileNote] = []
        if options.includeNotes {
            notes = selection.notes.map { FileNote(id: $0.id.uuidString, text: $0.text, kind: $0.kind.rawValue) }
        }

        return FilePlan(id: plan.id.uuidString, name: plan.name, kind: plan.kind.rawValue,
                        category: plan.category?.rawValue, goal: plan.goalText,
                        startAt: plan.startAt?.iso8601String, endAt: plan.endAt?.iso8601String,
                        aliases: plan.aliases.isEmpty ? nil : plan.aliases,
                        stages: stages.isEmpty ? nil : stages,
                        metrics: metrics.isEmpty ? nil : metrics,
                        tasks: nilIfEmpty(taskTree(selection.tasks, rules: selection.rules,
                                                   stages: selection.stages)),
                        records: nilIfEmpty(records), measurements: nilIfEmpty(measurements),
                        notes: nilIfEmpty(notes))
    }

    /// 平铺任务 → 嵌套树。步骤收进 `steps`，普通子任务收进 `children`；
    /// `stages` 是该计划内的阶段，用于把顶层任务的 `stageId` 写成阶段 id（与文件里
    /// 阶段条目的 `id` 一致）。子任务与步骤跟随上级的阶段，不重复写 `stage`。
    static func taskTree(_ tasks: [Task], rules: [RecurrenceRule], stages: [Stage] = []) -> [FileTask] {
        let ids = Set(tasks.map(\.id))
        let ordered = TaskHierarchy.ordered(tasks)
        let byParent = Dictionary(grouping: ordered, by: \.parentId)
        let ruleByTask = Dictionary(rules.map { ($0.taskId, $0) }, uniquingKeysWith: { first, _ in first })
        let stageIDs = Set(stages.map(\.id))

        func steps(of parent: UUID, visited: Set<UUID>) -> [FileStep] {
            (byParent[parent] ?? []).filter { $0.isStep && !visited.contains($0.id) }.map { step in
                let nested = steps(of: step.id, visited: visited.union([step.id]))
                return FileStep(id: step.id.uuidString, title: step.title,
                                children: nested.isEmpty ? nil : nested)
            }
        }

        func node(_ task: Task, visited: Set<UUID>) -> FileTask {
            let next = visited.union([task.id])
            var file = FileTask(id: task.id.uuidString, title: task.title, notes: task.notes,
                                startAt: task.startAt?.iso8601String, endAt: task.endAt?.iso8601String,
                                estimateMinutes: task.estimateMinutes,
                                priority: task.priority?.rawValue,
                                tags: task.tags.isEmpty ? nil : task.tags)
            if task.parentId == nil || !ids.contains(task.parentId!),
               let stageID = task.stageId, stageIDs.contains(stageID) {
                file.stage = stageID.uuidString
            }
            file.dependsOn = task.dependencyIDs.filter { ids.contains($0) }.map(\.uuidString)
            if file.dependsOn?.isEmpty == true { file.dependsOn = nil }
            if task.isTemplate {
                if let rule = ruleByTask[task.id] { file.recurrence = recurrence(of: rule) }
                let nested = steps(of: task.id, visited: next)
                file.steps = nested.isEmpty ? nil : nested
            } else {
                let kids = (byParent[task.id] ?? []).filter { !$0.isStep && !visited.contains($0.id) }
                    .map { node($0, visited: next) }
                file.children = kids.isEmpty ? nil : kids
                if kids.isEmpty && task.status != .todo { file.status = task.status.rawValue }
            }
            return file
        }

        let roots = ordered.filter { task in
            !task.isStep && (task.parentId == nil || !ids.contains(task.parentId!))
        }
        return roots.map { node($0, visited: []) }
    }

    static func recurrence(of rule: RecurrenceRule) -> FileRecurrence {
        FileRecurrence(pattern: rule.pattern.rawValue,
                       weekdays: rule.pattern == .weekdays ? rule.weekdays : nil,
                       weeklyCount: rule.pattern == .weeklyCount ? rule.weeklyCount : nil,
                       effectiveFrom: rule.effectiveFrom.iso8601DateString,
                       effectiveUntil: rule.effectiveUntil?.iso8601DateString,
                       dailyStart: rule.dailyStart?.displayString,
                       dailyEnd: rule.dailyEnd?.displayString)
    }

    static func timeText(_ value: TimeValue) -> String {
        switch value {
        case .precise(let date):
            return DateTimeTZ(date, in: .current).iso8601String
        case .day(let day), .month(let day):
            return day.iso8601DateString
        }
    }

    private static func nilIfEmpty<T>(_ array: [T]) -> [T]? { array.isEmpty ? nil : array }
}

// MARK: - 空模板

public enum PlanFileTemplate {

    /// 带字段说明的空模板。`_说明` 之类以下划线开头的键会被导入忽略，可以直接删掉。
    /// 交给 AI 生成内容时，把这份文件和你的需求一起发给它即可。
    public static let json: String = """
    {
      "_说明": "Movo 文件模板。以下划线开头的键只是说明，导入时忽略。除 format、schemaVersion 和各处的 name / title 外，其余字段都可以删掉。顶层的 tasks、stages、metrics、records、measurements、notes 也可以单独导入，导入时选择放进哪个已有计划。",
      "format": "movo.plan-file",
      "schemaVersion": 1,
      "_时间写法": "startAt / endAt 都可以不写。某一天写 2026-06-30；某一时刻写带时区偏移的 2026-06-30T18:00:00+08:00。子级的时间必须落在上级的范围内（任务 ⊂ 阶段 ⊂ 计划）。这份模板里没有写具体日期，需要时自己加上。",
      "plans": [
        {
          "_id": "可选。文件内的标识，用来互相引用（前置任务、阶段、记录）。Movo 导出的 id 是 UUID，导入同一份文件时用它识别重复。",
          "id": "plan-1",
          "name": "示例计划（请修改）",
          "_kind": "delivery 交付型 / improvement 改善型 / maintenance 持续型，缺省为 delivery",
          "kind": "delivery",
          "_category": "work 工作 / study 学习 / health 健康 / life 生活，可不写",
          "category": "work",
          "goal": "一句话说明想达成什么",
          "stages": [
            { "id": "s-1", "name": "准备", "criteria": "达成条件，可不写" }
          ],
          "metrics": [
            { "id": "m-1", "name": "体重", "unit": "kg", "targetValue": 70, "direction": "decrease" }
          ],
          "tasks": [
            {
              "_说明": "children 是多级子任务；子任务的计划和阶段跟随上级。",
              "id": "t-1",
              "title": "整理需求",
              "stage": "s-1",
              "priority": "high",
              "tags": ["示例"],
              "children": [
                { "id": "t-1-1", "title": "收集资料" },
                { "id": "t-1-2", "title": "写出摘要", "dependsOn": ["t-1-1"] }
              ]
            },
            {
              "_说明": "recurrence 表示重复行动；steps 是每次执行时逐项勾选的多级步骤。重复行动不使用 children。",
              "id": "t-2",
              "title": "背单词",
              "recurrence": {
                "pattern": "weekdays",
                "weekdays": [1, 2, 3, 4, 5],
                "dailyStart": "08:00",
                "dailyEnd": "08:30"
              },
              "steps": [
                { "title": "复习旧词" },
                { "title": "学新词", "children": [ { "title": "第一组 20 个" }, { "title": "第二组 20 个" } ] }
              ]
            }
          ]
        }
      ],
      "tasks": [
        { "title": "示例：不属于任何计划的独立待办" }
      ]
    }
    """
}
