//
//  ContextBuilder.swift
//  Intelligence/Privacy
//
//  6.4 云上下文构建（AIInput）。
//  禁止发送：受限计划任何内容（名称也不得出现）、测量值与行动记录正文、事件历史、Key、设备标识。
//  发送前做二次断言（PT 测试用请求抓取验证，AC16）。
//

import Foundation

/// 6.4 的 JSON 结构（内存中构造，不落日志）
public struct AIInput: Hashable, Sendable {
    public struct PlanContext: Hashable, Sendable {
        public var id: String
        public var name: String
        public var aliases: [String]
        public var goal: String?
        public var currentStage: String?
        public var kind: String
        public var recentTaskTitles: [String]
    }

    public struct TaskContext: Hashable, Sendable {
        public var id: String
        public var title: String
        public var planId: String?
        public var status: String
        public var scheduledOn: String?
    }

    public var schemaVersion: Int
    public var locale: String
    public var timezone: String
    public var today: String
    /// 仅 safe 片段拼接，span 偏移对应该文本
    public var text: String
    public var plans: [PlanContext]
    public var tasks: [TaskContext]
    public var instructions: String
    /// 本次上下文允许引用 id 的白名单（V4/V13 校验用；不进请求体）
    public var allowedPlanIDs: Set<UUID>
    public var allowedTaskIDs: Set<UUID>
    public var allowedMetricIDs: Set<UUID>
    public var allowedOccurrenceIDs: Set<UUID>

    public init(schemaVersion: Int = 1, locale: String, timezone: String, today: String, text: String,
                plans: [PlanContext], tasks: [TaskContext], instructions: String,
                allowedPlanIDs: Set<UUID> = [], allowedTaskIDs: Set<UUID> = [],
                allowedMetricIDs: Set<UUID> = [], allowedOccurrenceIDs: Set<UUID> = []) {
        self.schemaVersion = schemaVersion; self.locale = locale; self.timezone = timezone
        self.today = today; self.text = text; self.plans = plans; self.tasks = tasks
        self.instructions = instructions
        self.allowedPlanIDs = allowedPlanIDs; self.allowedTaskIDs = allowedTaskIDs
        self.allowedMetricIDs = allowedMetricIDs; self.allowedOccurrenceIDs = allowedOccurrenceIDs
    }

    /// 发往厂商的请求体（不含白名单等本地元数据）
    public func requestBodyJSON() -> [String: JSONValue] {
        var plansArray: [JSONValue] = []
        for p in plans {
            plansArray.append(.object([
                "id": .string(p.id),
                "name": .string(p.name),
                "aliases": .array(p.aliases.map { .string($0) }),
                "goal": p.goal.map { .string($0) } ?? .null,
                "current_stage": p.currentStage.map { .string($0) } ?? .null,
                "kind": .string(p.kind),
                "recent_task_titles": .array(p.recentTaskTitles.map { .string($0) })
            ]))
        }
        var tasksArray: [JSONValue] = []
        for t in tasks {
            tasksArray.append(.object([
                "id": .string(t.id),
                "title": .string(t.title),
                "plan_id": t.planId.map { .string($0) } ?? .null,
                "status": .string(t.status),
                "scheduled_on": t.scheduledOn.map { .string($0) } ?? .null
            ]))
        }
        return [
            "schema_version": .int(schemaVersion),
            "locale": .string(locale),
            "timezone": .string(timezone),
            "today": .string(today),
            "text": .string(text),
            "plans": .array(plansArray),
            "tasks": .array(tasksArray),
            "instructions": .string(instructions)
        ]
    }

    public func requestBodyJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(requestBodyJSON()),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

public enum AIContextBuilder {

    /// 固定提示词：只提议不执行；只能引用给定 id；歧义输出 needs_clarification；不得虚构 id/日期/数值
    public static let instructions = """
    你是 Movo 的整理助手。用户会给你一段文字和一份允许引用的计划/任务清单。
    规则：
    1. 只提议，不执行；你输出的是待执行的提案。
    2. 只能引用清单中出现过的 id（plan_id / candidate_task_id / metric_id）。不得虚构 id。
    3. 不得虚构日期、数值或单位。相对时间（今天/明天/周五）按给定 today 与 timezone 解析，并回填 date_interpretation。
    4. 歧义或信息不足时，action 用 needs_clarification，不要猜测归属。
    5. 单条输入最多 10 个 items。查询类意图（"有哪些""找一下"）不要输出 items。
    6. 涉及先后顺序的依赖建议，needs_confirmation 必须为 true。
    7. confidence 只供内部阈值判断，界面不展示。
    """

    /// 构建云上下文。`plans` 必须已按 cloudAIEnabled && status == active 过滤；
    /// 受限计划不得出现在结果里（含名称）。
    public static func build(sendableText: String,
                             today: DateOnly,
                             timeZone: TimeZone,
                             plans: [Plan],
                             tasksByPlan: [UUID: [Task]],
                             stagesByPlan: [UUID: [Stage]],
                             metricsByPlan: [UUID: [PlanMetric]],
                             occurrencesByTask: [UUID: [RecurrenceOccurrence]],
                             defaults: AppDefaults,
                             localeIdentifier: String = "zh-Hans") -> AIInput {

        // 仅 cloudAIEnabled && status == active（6.4）
        let allowedPlans = plans.filter { $0.cloudAIEnabled && $0.status == .active }

        var planContexts: [AIInput.PlanContext] = []
        var taskContexts: [AIInput.TaskContext] = []
        var allowedPlanIDs: Set<UUID> = []
        var allowedTaskIDs: Set<UUID> = []
        var allowedMetricIDs: Set<UUID> = []
        var allowedOccurrenceIDs: Set<UUID> = []

        for plan in allowedPlans {
            allowedPlanIDs.insert(plan.id)
            let planTasks = (tasksByPlan[plan.id] ?? [])
                .filter { $0.status != .cancelled && !$0.isTemplate }
                .sorted { $0.updatedAt > $1.updatedAt }
            let recentTitles = planTasks.prefix(defaults.ai.recentTaskTitlesLimit).map(\.title)
            let currentStage = (stagesByPlan[plan.id] ?? [])
                .first { $0.status == .inProgress || $0.status == .awaitingConfirm }?.name

            planContexts.append(AIInput.PlanContext(
                id: plan.id.uuidString,
                name: plan.name,
                aliases: plan.aliases,
                goal: plan.goalText,
                currentStage: currentStage,
                kind: plan.kind.rawValue,
                recentTaskTitles: recentTitles))

            for metric in (metricsByPlan[plan.id] ?? []) {
                allowedMetricIDs.insert(metric.id)
            }
        }

        // tasks：≤30，活跃未取消，按最近活动排序（仅允许计划的）
        let allowedTasks = allowedPlans
            .flatMap { tasksByPlan[$0.id] ?? [] }
            .filter { $0.status != .cancelled && !$0.isTemplate }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(defaults.ai.contextTasksLimit)

        for task in allowedTasks {
            allowedTaskIDs.insert(task.id)
            taskContexts.append(AIInput.TaskContext(
                id: task.id.uuidString,
                title: task.title,
                planId: task.planId?.uuidString,
                status: task.status.rawValue,
                scheduledOn: task.scheduledDate?.iso8601DateString))
            for occurrence in (occurrencesByTask[task.id] ?? []) where occurrence.status == .pending {
                allowedOccurrenceIDs.insert(occurrence.id)
            }
        }

        return AIInput(
            locale: localeIdentifier,
            timezone: timeZone.identifier,
            today: today.iso8601DateString,
            text: sendableText,
            plans: planContexts,
            tasks: taskContexts,
            instructions: instructions,
            allowedPlanIDs: allowedPlanIDs,
            allowedTaskIDs: allowedTaskIDs,
            allowedMetricIDs: allowedMetricIDs,
            allowedOccurrenceIDs: allowedOccurrenceIDs)
    }

    /// 发送前二次断言（AC16）：受限计划名称/正文、测量值、行动记录正文 0 出现。
    /// 返回违规项描述；空数组 = 通过。
    public static func assertNoRestrictedContent(input: AIInput,
                                                 restrictedPlans: [Plan],
                                                 restrictedTitles: [String],
                                                 restrictedKeywords: [String]) -> [String] {
        var violations: [String] = []
        let body = input.requestBodyJSONString()

        for plan in restrictedPlans {
            if body.contains(plan.name) { violations.append("受限计划名称出现：\(plan.name)") }
            for alias in plan.aliases where alias.count >= 2 {
                if body.contains(alias) { violations.append("受限计划别名出现：\(alias)") }
            }
            if let goal = plan.goalText, goal.count >= 4, body.contains(goal) {
                violations.append("受限计划目标正文出现")
            }
        }
        for title in restrictedTitles where title.count >= 4 {
            if body.contains(title) { violations.append("受限计划任务标题出现：\(title)") }
        }
        for keyword in restrictedKeywords where keyword.count >= 2 {
            if input.text.contains(keyword) { violations.append("可发送文本含受限关键词：\(keyword)") }
        }
        return violations
    }
}
