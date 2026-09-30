//
//  ExportService.swift
//  Data/Export
//
//  T1.8 / REQ 16：计划档案与导出（Markdown / JSON）+ 预览。
//  · 导出包含依赖关系字段，跨月计划导出后可被解析且与源一致（AC18）。
//  · 敏感默认排除：cloudAIEnabled == false 的计划不进入默认导出集（AC16 本地部分）。
//  · 原始音频从不进同步/导出/日志（9.7）——该字段不参与任何导出结构。
//

import Foundation

// MARK: - 格式

public enum ExportFormat: String, Sendable, CaseIterable, Identifiable {
    case markdown
    case json

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .json: "JSON"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .json: "json"
        }
    }
}

// MARK: - 单计划导出素材

public struct ExportPlanSelection: Sendable, Hashable {
    public var plan: Plan
    public var stages: [Stage]
    public var tasks: [Task]
    public var metrics: [PlanMetric]
    public var measurements: [Measurement]
    public var activities: [ActionRecord]
    public var notes: [Note]
    public var occurrences: [RecurrenceOccurrence]
    public var rules: [RecurrenceRule]

    public init(plan: Plan, stages: [Stage] = [], tasks: [Task] = [], metrics: [PlanMetric] = [],
                measurements: [Measurement] = [], activities: [ActionRecord] = [],
                notes: [Note] = [], occurrences: [RecurrenceOccurrence] = [],
                rules: [RecurrenceRule] = []) {
        self.plan = plan; self.stages = stages; self.tasks = tasks; self.metrics = metrics
        self.measurements = measurements; self.activities = activities; self.notes = notes
        self.occurrences = occurrences; self.rules = rules
    }

    /// 敏感计划（未允许云 AI）默认不导出
    public var isSensitive: Bool { !plan.cloudAIEnabled }

    /// 依赖关系摘要（AC18：导出必须能还原依赖）
    public var hasDependencies: Bool {
        tasks.contains { !$0.dependencyIDs.isEmpty }
    }
}

// MARK: - 产出

public struct ExportBundle: Sendable {
    public var fileName: String
    public var content: String
    public var format: ExportFormat
    public var includedPlanNames: [String]
    public var excludedPlanNames: [String]
    public var generatedAt: Date

    public init(fileName: String, content: String, format: ExportFormat,
                includedPlanNames: [String], excludedPlanNames: [String], generatedAt: Date) {
        self.fileName = fileName; self.content = content; self.format = format
        self.includedPlanNames = includedPlanNames; self.excludedPlanNames = excludedPlanNames
        self.generatedAt = generatedAt
    }

    public var byteCount: Int { content.lengthOfBytes(using: .utf8) }

    public var byteCountText: String {
        if byteCount < 1024 { return "\(byteCount) 字节" }
        return String(format: "%.1f KB", Double(byteCount) / 1024.0)
    }

    public var summaryText: String {
        var parts = ["包含 \(includedPlanNames.count) 个计划"]
        if !excludedPlanNames.isEmpty { parts.append("默认排除 \(excludedPlanNames.count) 个敏感计划") }
        parts.append(byteCountText)
        return parts.joined(separator: " · ")
    }
}

// MARK: - 导出服务

public enum ExportService {

    /// 按计划聚合素材。`onlyPlanID` 非空时只导出该计划。
    public static func gather(plans: [Plan], stages: [Stage], tasks: [Task], metrics: [PlanMetric],
                              measurements: [Measurement], activities: [ActionRecord], notes: [Note],
                              occurrences: [RecurrenceOccurrence], rules: [RecurrenceRule],
                              onlyPlanID: UUID? = nil) -> [ExportPlanSelection] {
        let scoped = plans
            .filter { onlyPlanID == nil || $0.id == onlyPlanID }
            .filter { $0.status != .archived || onlyPlanID != nil }
            .sorted { $0.updatedAt > $1.updatedAt }

        return scoped.map { plan in
            let planTasks = tasks.filter { $0.planId == plan.id }
            let taskIDs = Set(planTasks.map(\.id))
            return ExportPlanSelection(
                plan: plan,
                stages: stages.filter { $0.planId == plan.id }.sorted { $0.sortIndex < $1.sortIndex },
                tasks: planTasks.sorted { ($0.createdAt) < ($1.createdAt) },
                metrics: metrics.filter { $0.planId == plan.id },
                measurements: measurements.filter { $0.planId == plan.id }
                    .sorted { $0.measuredAt < $1.measuredAt },
                activities: activities.filter { $0.planId == plan.id }
                    .sorted { $0.happenedAt.sortEpoch < $1.happenedAt.sortEpoch },
                notes: notes.filter { $0.planId == plan.id }.sorted { $0.capturedAt < $1.capturedAt },
                occurrences: occurrences.filter { $0.planId == plan.id },
                rules: rules.filter { taskIDs.contains($0.taskId) })
        }
    }

    public static func export(_ selections: [ExportPlanSelection],
                              format: ExportFormat,
                              includeSensitive: Bool,
                              generatedAt: Date,
                              timeZone: TimeZone) -> ExportBundle {
        let included = includeSensitive ? selections : selections.filter { !$0.isSensitive }
        let excluded = includeSensitive ? [] : selections.filter(\.isSensitive).map(\.plan.name)

        let content: String
        switch format {
        case .markdown:
            content = markdown(included, generatedAt: generatedAt, timeZone: timeZone,
                               excluded: excluded)
        case .json:
            content = json(included, generatedAt: generatedAt, excluded: excluded)
        }

        let stamp = DateOnly(from: generatedAt, in: timeZone).iso8601DateString
        return ExportBundle(
            fileName: "movo-export-\(stamp).\(format.fileExtension)",
            content: content, format: format,
            includedPlanNames: included.map(\.plan.name),
            excludedPlanNames: excluded,
            generatedAt: generatedAt)
    }

    // MARK: Markdown

    static func markdown(_ selections: [ExportPlanSelection], generatedAt: Date,
                         timeZone: TimeZone, excluded: [String]) -> String {
        var lines: [String] = []
        lines.append("# 渐成 · 计划导出")
        lines.append("")
        lines.append("- 导出时间：\(stamp(generatedAt, in: timeZone))")
        lines.append("- 计划数量：\(selections.count)")
        if !excluded.isEmpty {
            lines.append("- 已排除（未允许云 AI，默认不导出）：\(excluded.joined(separator: "、"))")
        }
        lines.append("")

        for selection in selections {
            let plan = selection.plan
            lines.append("## \(plan.name)")
            lines.append("")
            lines.append("- 类型：\(plan.taxonomyLabel)")
            if let goal = plan.goalText, !goal.isEmpty { lines.append("- 目标：\(goal)") }
            if let target = plan.targetDate { lines.append("- 目标日期：\(target.iso8601DateString)") }
            lines.append("- 状态：\(plan.status.displayName)")
            lines.append("- 允许云 AI：\(plan.cloudAIEnabled ? "是" : "否")")
            lines.append("- 云同步：\(plan.syncEnabled ? "是" : "否")")
            if !plan.aliases.isEmpty {
                lines.append("- 别名：\(plan.aliases.joined(separator: "、"))")
            }
            let leaves = ProgressPolicy.deliveryLeaves(in: selection.tasks)
            lines.append("- 叶子任务完成：\(leaves.done)/\(leaves.total)")
            lines.append("")

            if !selection.stages.isEmpty {
                lines.append("### 阶段")
                lines.append("")
                for stage in selection.stages {
                    let achieved = stage.achievedAt.map { "（达成于 \(stamp($0, in: timeZone))）" } ?? ""
                    let criteria = stage.criteriaText.map { "；达成条件：\($0)" } ?? ""
                    lines.append("- [\(stage.status.displayName)] \(stage.name)\(achieved)\(criteria)")
                }
                lines.append("")
            }

            if !selection.tasks.isEmpty {
                lines.append("### 任务")
                lines.append("")
                let titleByID = Dictionary(selection.tasks.map { ($0.id, $0.title) },
                                           uniquingKeysWith: { a, _ in a })
                for task in selection.tasks {
                    let mark = task.status == .done ? "x" : " "
                    var detail: [String] = ["状态：\(task.status.displayName)"]
                    if let stageID = task.stageId,
                       let stage = selection.stages.first(where: { $0.id == stageID }) {
                        detail.append("阶段：\(stage.name)")
                    }
                    if let parentID = task.parentId, let parent = titleByID[parentID] {
                        detail.append("上级：\(parent)")
                    }
                    detail.append("安排日期：\(task.scheduledDate?.iso8601DateString ?? "未安排")")
                    detail.append("硬截止：\(task.hardDeadline?.displayString ?? "未设置")")
                    if let hint = task.timeHint { detail.append("时段：\(hint.displayName)") }
                    if let estimate = task.estimateMinutes { detail.append("预计：\(estimate) 分钟") }
                    if let priority = task.priority { detail.append("优先级：\(priority.displayName)") }
                    if !task.tags.isEmpty { detail.append("标签：\(task.tags.joined(separator: "、"))") }
                    if task.isTemplate { detail.append("重复模板：是") }
                    if !task.dependencyIDs.isEmpty {
                        let names = task.dependencyIDs.map { titleByID[$0] ?? $0.uuidString }
                        detail.append("前置：\(names.joined(separator: "、"))")
                    }
                    lines.append("- [\(mark)] \(task.title)（\(detail.joined(separator: "；"))）")
                }
                lines.append("")
            }

            if !selection.rules.isEmpty {
                lines.append("### 重复安排")
                lines.append("")
                for rule in selection.rules {
                    let taskTitle = selection.tasks.first { $0.id == rule.taskId }?.title ?? "重复行动"
                    let until = rule.effectiveUntil.map { "，至 \($0.iso8601DateString)" } ?? ""
                    lines.append("- \(taskTitle)：\(rule.ruleDescription)（生效自 \(rule.effectiveFrom.iso8601DateString)\(until)，第 \(rule.version) 版，\(rule.status.displayName)）")
                }
                lines.append("")
            }

            if !selection.activities.isEmpty {
                lines.append("### 行动记录")
                lines.append("")
                lines.append("| 日期 | 关联任务 | 时长（分钟） | 说明 | 更正 |")
                lines.append("| --- | --- | --- | --- | --- |")
                let titleByID = Dictionary(selection.tasks.map { ($0.id, $0.title) },
                                           uniquingKeysWith: { a, _ in a })
                for activity in selection.activities {
                    let day = DateOnly(from: activity.happenedAt.sortEpoch, in: timeZone).iso8601DateString
                    let task = activity.taskId.flatMap { titleByID[$0] } ?? "—"
                    let duration = activity.durationMinutes.map(String.init) ?? "—"
                    let text = (activity.text ?? "—").replacingOccurrences(of: "|", with: "／")
                    lines.append("| \(day) | \(task) | \(duration) | \(text) | \(activity.isCorrection ? "是" : "否") |")
                }
                lines.append("")
            }

            if !selection.metrics.isEmpty {
                lines.append("### 结果指标")
                lines.append("")
                for metric in selection.metrics {
                    let target = metric.targetValue.map { value -> String in
                        let text = value.rounded() == value
                            ? String(Int(value)) : String(format: "%.1f", value)
                        return "，参考目标 \(text)\(metric.unitDisplayName)"
                    } ?? ""
                    lines.append("- \(metric.name)（\(metric.unitDisplayName)，\(metric.targetDirection.displayName)\(target)）")
                    let points = selection.measurements.filter { $0.metricId == metric.id }
                    if points.isEmpty {
                        lines.append("  - 还没有测量记录（缺测不补 0）")
                    } else {
                        for point in points {
                            let value = point.value.rounded() == point.value
                                ? String(Int(point.value)) : String(format: "%.1f", point.value)
                            let note = point.note.map { "｜\($0)" } ?? ""
                            let corrected = point.isCorrection ? "｜更正" : ""
                            lines.append("  - \(point.measuredAt.iso8601DateString)：\(value)\(metric.unitDisplayName)\(corrected)\(note)")
                        }
                    }
                }
                lines.append("")
            }

            if !selection.notes.isEmpty {
                lines.append("### 想法与备忘")
                lines.append("")
                for note in selection.notes {
                    lines.append("- [\(note.kind.displayName)] \(note.text)")
                }
                lines.append("")
            }

            if !selection.occurrences.isEmpty {
                lines.append("### 重复实例")
                lines.append("")
                let titleByID = Dictionary(selection.tasks.map { ($0.id, $0.title) },
                                           uniquingKeysWith: { a, _ in a })
                for occurrence in selection.occurrences.sorted(by: {
                    ($0.scheduledOn ?? $0.occurredOn ?? DateOnly(y: 1, m: 1, d: 1, sourceTZ: "UTC"))
                        < ($1.scheduledOn ?? $1.occurredOn ?? DateOnly(y: 1, m: 1, d: 1, sourceTZ: "UTC"))
                }) {
                    let day = (occurrence.scheduledOn ?? occurrence.occurredOn)?.iso8601DateString ?? "—"
                    let title = titleByID[occurrence.taskId] ?? "重复行动"
                    lines.append("- \(day)｜\(title)｜\(occurrence.status.displayName)")
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: JSON

    /// 导出文档结构。字段与领域实体一一对应，含 dependencyIDs（AC18）。
    struct Document: Encodable {
        struct PlanBlock: Encodable {
            var plan: Plan
            var stages: [Stage]
            var tasks: [Task]
            var metrics: [PlanMetric]
            var measurements: [Measurement]
            var activities: [ActionRecord]
            var notes: [Note]
            var rules: [RecurrenceRule]
            var occurrences: [RecurrenceOccurrence]
        }
        var schemaVersion: Int
        var application: String
        var generatedAt: Date
        var excludedPlanNames: [String]
        var plans: [PlanBlock]
    }

    static func json(_ selections: [ExportPlanSelection], generatedAt: Date,
                     excluded: [String]) -> String {
        let document = Document(
            schemaVersion: 1,
            application: "Movo / 渐成",
            generatedAt: generatedAt,
            excludedPlanNames: excluded,
            plans: selections.map {
                Document.PlanBlock(plan: $0.plan, stages: $0.stages, tasks: $0.tasks,
                                   metrics: $0.metrics, measurements: $0.measurements,
                                   activities: $0.activities, notes: $0.notes,
                                   rules: $0.rules, occurrences: $0.occurrences)
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: 工具

    static func stamp(_ date: Date, in timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
