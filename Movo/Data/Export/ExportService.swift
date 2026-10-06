//
//  ExportService.swift
//  Data/Export
//
//  T1.8 / REQ 16：计划档案与导出（Markdown / Movo 文件）+ 预览。
//  · Movo 文件（`.movo.json`）是标准交换格式，结构见 PlanFile.swift，可被「导入」读回。
//  · 默认只导出结构和计划内容；行动记录、测量值、笔记由用户勾选（PlanFileOptions）。
//  · 不再按 cloudAIEnabled 过滤：导出由用户主动发起，范围与内容由用户选择。
//  · 原始音频、API Key、设备标识从不进入导出结构（9.7）。
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
        case .json: "Movo 文件"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .json: PlanFile.fileExtension
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

    /// 依赖关系摘要（AC18：导出必须能还原依赖）
    public var hasDependencies: Bool {
        tasks.contains { !$0.dependencyIDs.isEmpty }
    }

    /// 按选项去掉默认不导出的内容（行动记录、测量值、笔记）
    func applying(_ options: PlanFileOptions) -> ExportPlanSelection {
        var copy = self
        if !options.includeRecords { copy.activities = [] }
        if !options.includeMeasurements { copy.measurements = [] }
        if !options.includeNotes { copy.notes = [] }
        return copy
    }
}

/// 不属于任何计划的任务与笔记
public struct ExportStandalone: Sendable, Hashable {
    public var tasks: [Task]
    public var rules: [RecurrenceRule]
    public var notes: [Note]

    public init(tasks: [Task] = [], rules: [RecurrenceRule] = [], notes: [Note] = []) {
        self.tasks = tasks; self.rules = rules; self.notes = notes
    }
}

/// 一次导出的范围：若干计划 + 独立任务
public struct ExportScope: Sendable, Hashable {
    public var selections: [ExportPlanSelection]
    public var standalone: ExportStandalone

    public init(selections: [ExportPlanSelection], standalone: ExportStandalone = ExportStandalone()) {
        self.selections = selections; self.standalone = standalone
    }
}

// MARK: - 产出

public struct ExportBundle: Sendable {
    public var fileName: String
    public var content: String
    public var format: ExportFormat
    public var includedPlanNames: [String]
    public var standaloneTaskCount: Int
    public var generatedAt: Date

    public init(fileName: String, content: String, format: ExportFormat,
                includedPlanNames: [String], standaloneTaskCount: Int = 0, generatedAt: Date) {
        self.fileName = fileName; self.content = content; self.format = format
        self.includedPlanNames = includedPlanNames; self.standaloneTaskCount = standaloneTaskCount
        self.generatedAt = generatedAt
    }

    public var isEmpty: Bool { includedPlanNames.isEmpty && standaloneTaskCount == 0 }

    public var byteCount: Int { content.lengthOfBytes(using: .utf8) }

    public var byteCountText: String {
        if byteCount < 1024 { return "\(byteCount) 字节" }
        return String(format: "%.1f KB", Double(byteCount) / 1024.0)
    }

    public var summaryText: String {
        var parts = ["包含 \(includedPlanNames.count) 个计划"]
        if standaloneTaskCount > 0 { parts.append("\(standaloneTaskCount) 项独立待办") }
        parts.append(byteCountText)
        return parts.joined(separator: " · ")
    }
}

// MARK: - 导出服务

public enum ExportService {

    /// 按计划聚合素材。`onlyPlanID` 非空时只导出该计划；为空时一并带上独立任务。
    /// 调用方负责先去掉已删除（墓碑）的实体。
    public static func gather(plans: [Plan], stages: [Stage], tasks: [Task], metrics: [PlanMetric],
                              measurements: [Measurement], activities: [ActionRecord], notes: [Note],
                              occurrences: [RecurrenceOccurrence], rules: [RecurrenceRule],
                              onlyPlanID: UUID? = nil) -> ExportScope {
        let scoped = plans
            .filter { onlyPlanID == nil || $0.id == onlyPlanID }
            .filter { $0.status != .archived || onlyPlanID != nil }
            .sorted { $0.updatedAt > $1.updatedAt }

        let selections: [ExportPlanSelection] = scoped.map { plan in
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

        guard onlyPlanID == nil else { return ExportScope(selections: selections) }
        let looseTasks = tasks.filter { $0.planId == nil }.sorted { $0.createdAt < $1.createdAt }
        let looseIDs = Set(looseTasks.map(\.id))
        let standalone = ExportStandalone(
            tasks: looseTasks,
            rules: rules.filter { looseIDs.contains($0.taskId) },
            notes: notes.filter { $0.planId == nil }.sorted { $0.capturedAt < $1.capturedAt })
        return ExportScope(selections: selections, standalone: standalone)
    }

    public static func export(_ scope: ExportScope,
                              format: ExportFormat,
                              options: PlanFileOptions = PlanFileOptions(),
                              generatedAt: Date,
                              timeZone: TimeZone) -> ExportBundle {
        let selections = scope.selections.map { $0.applying(options) }
        var standalone = scope.standalone
        if !options.includeNotes { standalone.notes = [] }

        let content: String
        switch format {
        case .markdown:
            content = markdown(selections, standalone: standalone, generatedAt: generatedAt,
                               timeZone: timeZone)
        case .json:
            content = PlanFileCodec.encode(PlanFileBuilder.build(
                selections: selections, standaloneTasks: standalone.tasks,
                standaloneRules: standalone.rules, standaloneNotes: standalone.notes,
                options: options, exportedAt: generatedAt))
        }

        let stamp = DateOnly(from: generatedAt, in: timeZone).iso8601DateString
        return ExportBundle(
            fileName: "movo-export-\(stamp).\(format.fileExtension)",
            content: content, format: format,
            includedPlanNames: selections.map(\.plan.name),
            standaloneTaskCount: standalone.tasks.filter { !$0.isStep }.count,
            generatedAt: generatedAt)
    }

    // MARK: Markdown

    static func markdown(_ selections: [ExportPlanSelection], standalone: ExportStandalone,
                         generatedAt: Date, timeZone: TimeZone) -> String {
        var lines: [String] = []
        lines.append("# 渐成 · 计划导出")
        lines.append("")
        lines.append("- 导出时间：\(stamp(generatedAt, in: timeZone))")
        lines.append("- 计划数量：\(selections.count)")
        lines.append("")

        for selection in selections {
            let plan = selection.plan
            lines.append("## \(plan.name)")
            lines.append("")
            lines.append("- 类型：\(plan.taxonomyLabel)")
            if let goal = plan.goalText, !goal.isEmpty { lines.append("- 目标：\(goal)") }
            if let start = plan.startAt { lines.append("- 开始时间：\(start.iso8601String)") }
            if let end = plan.endAt { lines.append("- 结束时间：\(end.iso8601String)") }
            lines.append("- 状态：\(plan.status.displayName)")
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
                    var times = ""
                    if let start = stage.startAt { times += "；开始：\(start.iso8601String)" }
                    if let end = stage.endAt { times += "；结束：\(end.iso8601String)" }
                    lines.append("- [\(stage.status.displayName)] \(stage.name)\(achieved)\(criteria)\(times)")
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
                    if let start = task.startAt { detail.append("开始：\(start.iso8601String)") }
                    if let end = task.endAt { detail.append("结束：\(end.iso8601String)") }
                    if let estimate = task.estimateMinutes { detail.append("预计：\(estimate) 分钟") }
                    if let priority = task.priority { detail.append("优先级：\(priority.displayName)") }
                    if !task.tags.isEmpty { detail.append("标签：\(task.tags.joined(separator: "、"))") }
                    if task.isStep { detail.append("重复行动的步骤") }
                    else if task.isTemplate { detail.append("重复模板：是") }
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
                    let daily = rule.dailyTimeDescription.map { "，每天 \($0)" } ?? ""
                    lines.append("- \(taskTitle)：\(rule.ruleDescription)（生效自 \(rule.effectiveFrom.iso8601DateString)\(until)\(daily)，第 \(rule.version) 版，\(rule.status.displayName)）")
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

        let looseTasks = standalone.tasks.filter { !$0.isStep }
        if !looseTasks.isEmpty {
            lines.append("## 独立待办")
            lines.append("")
            let titleByID = Dictionary(standalone.tasks.map { ($0.id, $0.title) },
                                       uniquingKeysWith: { a, _ in a })
            for task in looseTasks {
                var detail: [String] = ["状态：\(task.status.displayName)"]
                if let parentID = task.parentId, let parent = titleByID[parentID] {
                    detail.append("上级：\(parent)")
                }
                if let start = task.startAt { detail.append("开始：\(start.iso8601String)") }
                if let end = task.endAt { detail.append("结束：\(end.iso8601String)") }
                if task.isTemplate,
                   let rule = standalone.rules.first(where: { $0.taskId == task.id }) {
                    detail.append("重复：\(rule.ruleDescription)")
                    let steps = standalone.tasks.filter { $0.isStep && $0.parentId == task.id }
                    if !steps.isEmpty {
                        detail.append("步骤：\(steps.map(\.title).joined(separator: "、"))")
                    }
                }
                lines.append("- [\(task.status == .done ? "x" : " ")] \(task.title)（\(detail.joined(separator: "；"))）")
            }
            lines.append("")
        }

        if !standalone.notes.isEmpty {
            lines.append("## 独立笔记")
            lines.append("")
            for note in standalone.notes {
                lines.append("- [\(note.kind.displayName)] \(note.text)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
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
