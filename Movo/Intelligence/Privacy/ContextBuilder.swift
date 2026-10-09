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
    public struct StageContext: Hashable, Sendable {
        public var id: String
        public var name: String
        public var status: String
        public var startAt: String?
        public var endAt: String?

        public init(id: String, name: String, status: String,
                    startAt: String? = nil, endAt: String? = nil) {
            self.id = id; self.name = name; self.status = status
            self.startAt = startAt; self.endAt = endAt
        }
    }

    public struct PlanContext: Hashable, Sendable {
        public var id: String
        public var name: String
        public var aliases: [String]
        public var goal: String?
        public var currentStage: String?
        public var kind: String
        public var recentTaskTitles: [String]
        /// 计划的起止范围（yyyy-MM-dd 或 ISO8601）；子级时间必须落在范围内
        public var startAt: String?
        public var endAt: String?
        public var stages: [StageContext]

        public init(id: String, name: String, aliases: [String], goal: String? = nil,
                    currentStage: String? = nil, kind: String, recentTaskTitles: [String],
                    startAt: String? = nil, endAt: String? = nil, stages: [StageContext] = []) {
            self.id = id; self.name = name; self.aliases = aliases; self.goal = goal
            self.currentStage = currentStage; self.kind = kind; self.recentTaskTitles = recentTaskTitles
            self.startAt = startAt; self.endAt = endAt; self.stages = stages
        }
    }

    public struct TaskContext: Hashable, Sendable {
        public var id: String
        public var title: String
        public var planId: String?
        public var stageId: String?
        public var parentId: String?
        public var status: String
        public var startAt: String?
        public var endAt: String?

        public init(id: String, title: String, planId: String? = nil,
                    stageId: String? = nil, parentId: String? = nil,
                    status: String, startAt: String? = nil, endAt: String? = nil) {
            self.id = id; self.title = title; self.planId = planId
            self.stageId = stageId; self.parentId = parentId
            self.status = status; self.startAt = startAt; self.endAt = endAt
        }
    }

    public struct RecurrenceContext: Hashable, Sendable {
        public var taskId: String
        public var title: String
        public var pattern: String
        public var planId: String?
        public var stepTitles: [String]

        public init(taskId: String, title: String, pattern: String,
                    planId: String? = nil, stepTitles: [String] = []) {
            self.taskId = taskId; self.title = title; self.pattern = pattern
            self.planId = planId; self.stepTitles = stepTitles
        }
    }

    public var schemaVersion: Int
    public var locale: String
    public var timezone: String
    public var today: String
    /// 输入文本，span 偏移对应该文本
    public var text: String
    public var plans: [PlanContext]
    public var tasks: [TaskContext]
    public var recurrences: [RecurrenceContext]
    public var instructions: String
    /// 本次上下文允许引用 id 的白名单（V4/V13 校验用；不进请求体）
    public var allowedPlanIDs: Set<UUID>
    public var allowedStageIDs: Set<UUID>
    public var allowedTaskIDs: Set<UUID>
    public var allowedMetricIDs: Set<UUID>
    public var allowedOccurrenceIDs: Set<UUID>

    public init(schemaVersion: Int = 1, locale: String, timezone: String, today: String, text: String,
                plans: [PlanContext], tasks: [TaskContext], recurrences: [RecurrenceContext] = [],
                instructions: String,
                allowedPlanIDs: Set<UUID> = [], allowedStageIDs: Set<UUID> = [],
                allowedTaskIDs: Set<UUID> = [], allowedMetricIDs: Set<UUID> = [],
                allowedOccurrenceIDs: Set<UUID> = []) {
        self.schemaVersion = schemaVersion; self.locale = locale; self.timezone = timezone
        self.today = today; self.text = text; self.plans = plans; self.tasks = tasks
        self.recurrences = recurrences; self.instructions = instructions
        self.allowedPlanIDs = allowedPlanIDs; self.allowedStageIDs = allowedStageIDs
        self.allowedTaskIDs = allowedTaskIDs; self.allowedMetricIDs = allowedMetricIDs
        self.allowedOccurrenceIDs = allowedOccurrenceIDs
    }

    /// 发往厂商的请求体（不含白名单等本地元数据）
    public func requestBodyJSON() -> [String: JSONValue] {
        var plansArray: [JSONValue] = []
        for p in plans {
            var stagesArray: [JSONValue] = []
            for s in p.stages {
                stagesArray.append(.object([
                    "id": .string(s.id),
                    "name": .string(s.name),
                    "status": .string(s.status),
                    "start_at": s.startAt.map { .string($0) } ?? .null,
                    "end_at": s.endAt.map { .string($0) } ?? .null
                ]))
            }
            plansArray.append(.object([
                "id": .string(p.id),
                "name": .string(p.name),
                "aliases": .array(p.aliases.map { .string($0) }),
                "goal": p.goal.map { .string($0) } ?? .null,
                "current_stage": p.currentStage.map { .string($0) } ?? .null,
                "kind": .string(p.kind),
                "recent_task_titles": .array(p.recentTaskTitles.map { .string($0) }),
                "start_at": p.startAt.map { .string($0) } ?? .null,
                "end_at": p.endAt.map { .string($0) } ?? .null,
                "stages": .array(stagesArray)
            ]))
        }
        var tasksArray: [JSONValue] = []
        for t in tasks {
            tasksArray.append(.object([
                "id": .string(t.id),
                "title": .string(t.title),
                "plan_id": t.planId.map { .string($0) } ?? .null,
                "stage_id": t.stageId.map { .string($0) } ?? .null,
                "parent_id": t.parentId.map { .string($0) } ?? .null,
                "status": .string(t.status),
                "start_at": t.startAt.map { .string($0) } ?? .null,
                "end_at": t.endAt.map { .string($0) } ?? .null
            ]))
        }
        var recurrencesArray: [JSONValue] = []
        for r in recurrences {
            recurrencesArray.append(.object([
                "task_id": .string(r.taskId),
                "title": .string(r.title),
                "pattern": .string(r.pattern),
                "plan_id": r.planId.map { .string($0) } ?? .null,
                "step_titles": .array(r.stepTitles.map { .string($0) })
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
            "recurrences": .array(recurrencesArray),
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

    /// 固定提示词：只提议不执行；只能引用给定真实 id 或使用批内临时引用 ref；歧义输出 needs_clarification
    public static let instructions = """
    你是 Movo 的整理助手。用户会给你一段文字和一份允许引用的计划、阶段、任务与重复规则清单。
    规则：
    1. 只提议，不执行；你输出的是待执行的提案，将交给用户在界面预览并确认。
    2. 只能引用清单中出现过的真实 id（plan_id / candidate_task_id / stage_id / metric_id）。不得虚构不存在的真实 id。
    3. 在同一次提案中新建对象并互相引用时，必须使用以 "ref" 为前缀的批内临时引用：
       - create_plan 中定义 plan.ref（如 "plan_1"），plan.stages 中的 stage.ref（如 "stage_1"），以及 plan.tasks 中的 task.ref（如 "task_1"）；
       - 任务通过 stage_ref 引用同计划内的阶段，通过 parent_ref 引用上级任务；
       - create_task 也可以使用 ref、stage_ref、parent_ref，或引用已存在的 plan_id、stage_id、parent_task_id。
       - 批内引用不得循环，不得悬空引用不存在的 ref。
    4. 不得虚构日期、数值或单位。相对时间（今天/明天/周五）按给定 today 与 timezone 解析，并回填 date_interpretation。
    5. 明确要做的事情用 create_task。没有计划也能创建，省略 plan_id；不确定归属时创建独立待办，不要阻止记录。动作本身不明确才用 needs_clarification。
    6. 重复任务规则：
       - 周期性重复执行的事项，使用 create_task 并在 recurrence 中指定重复规则（daily/weekdays/weeklyCount 等）；
       - 用户说出重复的结束日期时（「从10月9号到11月9号」「持续一个月」），必须把它填进 recurrence.effective_until（yyyy-MM-dd）。不要只在任务 end_at 里体现，也不要省略——省略会变成无限期重复；
       - 用户说出每次执行的时刻时（「每天早上6:30」），必须把它填进 recurrence.daily_start（HH:mm）。任务 start_at 只表示这个习惯整体的起点，不能替代每天时刻；
       - 只说了开始日期就用 effective_from，只说了「每天/每周」而没说起止时，两者都留空，由应用按今天处理；
       - 任务 start_at / end_at 表示这个重复安排整体的起止，应与 effective_from / effective_until 保持一致；用户只说重复频率、没有具体日期时，start_at / end_at 都不填；
       - 重复任务模板不能放在其他待办下面（不能指定 parent_task_id 或 parent_ref）；
       - 重复任务模板如果包含子项，子项只能作为执行步骤（使用 steps 列表表达），不能使用普通子任务；
       - 对于已有带普通子任务的任务，不要擅自将其设为重复。
    7. 单条输入最多 10 个 items。查询类意图（"有哪些""找一下"）不要输出 items。
    8. 用户明确要求建立计划时用 create_plan，plan 包含 name、kind（delivery/improvement/maintenance）、可选 goal、start_at、end_at，以及可选的 stages 和 tasks。
    9. source_span 必须逐字引用 text 的片段。span 为该片段在 text 中按字符计数的 [起点,终点)，不按 UTF-8 字节计数。
    10. 计划、阶段、任务都可以有起止时间 start_at / end_at，两者都是可选的：只填 start_at 表示从何时开始，只填 end_at 表示截止。只知道哪一天时填 yyyy-MM-dd；有明确时刻时填带时区的 ISO8601。用户说的时间模糊时，由你自行判断填什么合适，没把握就不填，不要虚构。任务的时间必须落在所属计划或阶段的起止范围内。
    """

    /// 构建上下文：所有未归档计划及其全部阶段、任务带父子关系与阶段、重复模板摘要。
    public static func build(sendableText: String,
                             today: DateOnly,
                             timeZone: TimeZone,
                             plans: [Plan],
                             tasksByPlan: [UUID: [Task]],
                             stagesByPlan: [UUID: [Stage]],
                             metricsByPlan: [UUID: [PlanMetric]],
                             occurrencesByTask: [UUID: [RecurrenceOccurrence]],
                             rules: [RecurrenceRule] = [],
                             defaults: AppDefaults,
                             localeIdentifier: String = "zh-Hans") -> AIInput {

        let allowedPlans = plans.filter { $0.status != .archived }

        var planContexts: [AIInput.PlanContext] = []
        var allowedPlanIDs: Set<UUID> = []
        var allowedStageIDs: Set<UUID> = []
        var allowedTaskIDs: Set<UUID> = []
        var allowedMetricIDs: Set<UUID> = []
        var allowedOccurrenceIDs: Set<UUID> = []

        for plan in allowedPlans {
            allowedPlanIDs.insert(plan.id)
            let planTasks = (tasksByPlan[plan.id] ?? [])
                .filter { $0.status != .cancelled && !$0.isTemplate }
                .sorted { $0.updatedAt > $1.updatedAt }
            let recentTitles = planTasks.prefix(defaults.ai.recentTaskTitlesLimit).map(\.title)
            let planStages = (stagesByPlan[plan.id] ?? []).sorted { $0.sortIndex < $1.sortIndex }
            let currentStage = planStages.first { $0.status == .inProgress || $0.status == .awaitingConfirm }?.name

            var stageContexts: [AIInput.StageContext] = []
            for stage in planStages {
                allowedStageIDs.insert(stage.id)
                stageContexts.append(AIInput.StageContext(
                    id: stage.id.uuidString,
                    name: stage.name,
                    status: stage.status.rawValue,
                    startAt: stage.startAt?.iso8601String,
                    endAt: stage.endAt?.iso8601String))
            }

            planContexts.append(AIInput.PlanContext(
                id: plan.id.uuidString,
                name: plan.name,
                aliases: plan.aliases,
                goal: plan.goalText,
                currentStage: currentStage,
                kind: plan.kind.rawValue,
                recentTaskTitles: recentTitles,
                startAt: plan.startAt?.iso8601String,
                endAt: plan.endAt?.iso8601String,
                stages: stageContexts))

            for metric in (metricsByPlan[plan.id] ?? []) {
                allowedMetricIDs.insert(metric.id)
            }
        }

        // 收集所有候选普通任务，截断时保证祖先不被截断
        let allRegularTasks = allowedPlans
            .flatMap { tasksByPlan[$0.id] ?? [] }
            .filter { $0.status != .cancelled && !$0.isTemplate }
        let allTasksByID = Dictionary(allRegularTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var selectedTaskIDs: [UUID] = []
        var selectedSet: Set<UUID> = []

        func addWithAncestors(_ task: Task) {
            var chain: [Task] = []
            var curr: Task? = task
            while let c = curr {
                if !selectedSet.contains(c.id) { chain.append(c) }
                curr = c.parentId.flatMap { allTasksByID[$0] }
            }
            for ancestor in chain.reversed() {
                if selectedSet.insert(ancestor.id).inserted {
                    selectedTaskIDs.append(ancestor.id)
                }
            }
        }

        for task in allRegularTasks.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if selectedSet.contains(task.id) { continue }
            addWithAncestors(task)
            if selectedTaskIDs.count >= defaults.ai.contextTasksLimit {
                break
            }
        }

        let finalTaskIDs = Array(selectedTaskIDs.prefix(defaults.ai.contextTasksLimit))
        var taskContexts: [AIInput.TaskContext] = []
        for id in finalTaskIDs {
            guard let task = allTasksByID[id] else { continue }
            allowedTaskIDs.insert(task.id)
            taskContexts.append(AIInput.TaskContext(
                id: task.id.uuidString,
                title: task.title,
                planId: task.planId?.uuidString,
                stageId: task.stageId?.uuidString,
                parentId: task.parentId?.uuidString,
                status: task.status.rawValue,
                startAt: task.startAt?.iso8601String,
                endAt: task.endAt?.iso8601String))
            for occurrence in (occurrencesByTask[task.id] ?? []) where occurrence.status == .pending {
                allowedOccurrenceIDs.insert(occurrence.id)
            }
        }

        // 重复模板摘要
        var recurrences: [AIInput.RecurrenceContext] = []
        let allPlanTasks = allowedPlans.flatMap { tasksByPlan[$0.id] ?? [] }
        let templateTasks = allPlanTasks.filter { $0.isTemplate && $0.parentId == nil && $0.status != .cancelled }
        let stepsByParent = Dictionary(grouping: allPlanTasks.filter { $0.isTemplate && $0.parentId != nil },
                                       by: { $0.parentId! })
        let rulesByTask = Dictionary(rules.map { ($0.taskId, $0) }, uniquingKeysWith: { a, _ in a })

        for template in templateTasks {
            let pattern = rulesByTask[template.id]?.pattern.rawValue ?? "custom"
            let stepTitles = (stepsByParent[template.id] ?? []).prefix(5).map(\.title)
            recurrences.append(AIInput.RecurrenceContext(
                taskId: template.id.uuidString,
                title: template.title,
                pattern: pattern,
                planId: template.planId?.uuidString,
                stepTitles: stepTitles))
        }

        return AIInput(
            locale: localeIdentifier,
            timezone: timeZone.identifier,
            today: today.iso8601DateString,
            text: sendableText,
            plans: planContexts,
            tasks: taskContexts,
            recurrences: recurrences,
            instructions: instructions,
            allowedPlanIDs: allowedPlanIDs,
            allowedStageIDs: allowedStageIDs,
            allowedTaskIDs: allowedTaskIDs,
            allowedMetricIDs: allowedMetricIDs,
            allowedOccurrenceIDs: allowedOccurrenceIDs)
    }
}
