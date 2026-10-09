//
//  DomainStore+Queries.swift
//  Domain/Queries
//
//  4.3 查询视图（只读）。查询前按需惰性实例化重复实例（4.4 materializeOccurrences）。
//

import Foundation

public extension DomainStore {

    // MARK: - 惰性实例化（查询/今日构建时触发）

    /// 为给定范围补全重复实例（幂等）。计划暂停区间不实例化、不补造。
    @discardableResult
    func materializeOccurrences(in range: DateOnlyRange) async -> Int {
        let stamp = now
        let tz = currentTimeZone
        let today = DateOnly(from: stamp, in: tz)
        let rules = await repository.rules()
        var written = 0

        for rule in rules where rule.isActive {
            guard let task = await repository.task(rule.taskId) else { continue }
            var planObj: Plan?
            if let pid = task.planId { planObj = await repository.plan(pid) }
            let days = RecurrencePolicy.plan(rule: rule, range: range, plan: planObj)
            guard !days.isEmpty else { continue }
            let existing = await repository.occurrences(ruleID: rule.id)
            let wanted = days.map { RecurrencePolicy.makeOccurrence(rule: rule, day: $0, planId: task.planId) }
            let toWrite = RecurrencePolicy.reconcile(existing: existing, wanted: wanted)
            for occurrence in toWrite {
                try? await repository.upsert(occurrence)
                written += 1
            }
        }
        // 计划暂停/恢复区间内的待做实例不删除（历史保留），只是不再新增
        _ = today
        return written
    }

    /// 今日查询所需的自然窗口（今日前后各 45 天），保证跨月与周视图一致
    func defaultMaterializeRange(around day: DateOnly? = nil) -> DateOnlyRange {
        let anchor = day ?? today
        return DateOnlyRange(lower: anchor.adding(days: -45), upper: anchor.adding(days: 45))
    }

    // MARK: - 今日

    func today(_ date: DateOnly) async -> TodayView {
        await materializeOccurrences(in: defaultMaterializeRange(around: date))

        let allPlans = await repository.allPlans()
        let planIndex = Dictionary(allPlans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tombstones = Set(await repository.tombstones(activeOnly: true).map(\.entityId))

        var planTasksCache: [UUID: [Task]] = [:]
        func tasks(in planID: UUID?) async -> [Task] {
            guard let planID else { return [] }
            if let cached = planTasksCache[planID] { return cached }
            let t = await repository.tasks(planID: planID)
            planTasksCache[planID] = t
            return t
        }

        func dependencyState(for task: Task) async -> DependencyState {
            guard !task.dependencyIDs.isEmpty else { return .ready }
            let siblings = await tasks(in: task.planId)
            return DependencyPolicy.status(for: task, planTasks: siblings, tombstoned: tombstones)
        }

        var focus: [TodayItem] = []
        var later: [TodayItem] = []
        var completed: [TodayItem] = []
        var routine: [TodayItem] = []
        var seen: Set<String> = []

        // 1. 今天的 Occurrence（重复行动当次）
        let scheduledToday = await repository.occurrences(scheduledIn: DateOnlyRange(lower: date, upper: date),
                                                          planID: nil)
        for occurrence in scheduledToday {
            let task = await repository.task(occurrence.taskId)
            guard let task, !tombstones.contains(occurrence.id), !tombstones.contains(task.id),
                  !tombstones.contains(occurrence.ruleId), task.status != .cancelled,
                  task.planId.map({ tombstones.contains($0) || planIndex[$0]?.status == .archived }) != true
            else { continue }
            let planName = occurrence.planId.flatMap { planIndex[$0]?.name }
            let rule = await repository.rule(occurrence.ruleId)
            let range = rule.flatMap { RecurrencePolicy.timeRange(of: occurrence, rule: $0) }
            let item = TodayItem(id: "occ-\(occurrence.id.uuidString)",
                                 body: .occurrence(occurrence: occurrence, task: task),
                                 section: occurrence.status == .done ? .completed : .focus,
                                 planName: planName,
                                 dependency: .ready,
                                 startAt: range?.start, endAt: range?.end,
                                 isCompletedToday: occurrence.status == .done)
            guard seen.insert(item.id).inserted else { continue }
            if occurrence.status == .done { completed.append(item) } else { focus.append(item) }
        }

        // 2. 今天的行动记录（周内记录不计入今日列表，仅用于计数）

        let allTasks = await repository.allTasks()
        let visible = allTasks

        for task in visible {
            if task.isTemplate { continue }
            if tombstones.contains(task.id) { continue }
            let plan = task.planId.flatMap { planIndex[$0] }
            if plan?.status == .archived { continue }

            let isDoneToday = task.status == .done && task.doneAt.map { sameDay($0, date) } ?? false
            let startDay = task.startAt?.dateOnly
            let endDay = task.endAt?.dateOnly
            let deadlineToday = endDay.map { $0 <= date } ?? false

            if isDoneToday {
                let item = TodayItem(id: "task-\(task.id.uuidString)", body: .scheduled(task: task),
                                     section: .completed, planName: plan?.name,
                                     dependency: await dependencyState(for: task),
                                     startAt: task.startAt, endAt: task.endAt, isCompletedToday: true)
                if seen.insert(item.id).inserted { completed.append(item) }
                continue
            }

            guard task.status.isOpen else { continue }
            let state = await dependencyState(for: task)

            // 重点：今天到期的结束时间、今天开始或起止范围覆盖今天的任务、进行中的任务
            if deadlineToday {
                let item = TodayItem(id: "task-\(task.id.uuidString)", body: .deadline(task: task),
                                     section: .focus, planName: plan?.name, dependency: state,
                                     startAt: task.startAt, endAt: task.endAt)
                if seen.insert(item.id).inserted { focus.append(item) }
            } else if startDay?.isSameDay(as: date) == true {
                let item = TodayItem(id: "task-\(task.id.uuidString)", body: .scheduled(task: task),
                                     section: .focus, planName: plan?.name, dependency: state,
                                     startAt: task.startAt, endAt: task.endAt)
                if seen.insert(item.id).inserted { focus.append(item) }
            } else if task.status == .inProgress || task.status == .blocked {
                let item = TodayItem(id: "task-\(task.id.uuidString)", body: .inProgress(task: task),
                                     section: .focus, planName: plan?.name, dependency: state,
                                     startAt: task.startAt, endAt: task.endAt)
                if seen.insert(item.id).inserted { focus.append(item) }
            } else if let s = startDay, s < date {
                if endDay != nil {
                    // 已开始且结束还在后面：起止范围覆盖今天
                    let item = TodayItem(id: "task-\(task.id.uuidString)", body: .scheduled(task: task),
                                         section: .focus, planName: plan?.name, dependency: state,
                                         startAt: task.startAt, endAt: task.endAt)
                    if seen.insert(item.id).inserted { focus.append(item) }
                } else {
                    // 逾期 → 稍后再做（提供补做/改期/取消）
                    let item = TodayItem(id: "task-\(task.id.uuidString)",
                                         body: .overdue(task: task, daysLate: s.days(until: date)),
                                         section: .later, planName: plan?.name, dependency: state,
                                         startAt: task.startAt, endAt: task.endAt)
                    if seen.insert(item.id).inserted { later.append(item) }
                }
            }
        }

        // 3. 今天可以做的重复行动（**派生投影，不落库**）
        //    出现条件：规则今天该有这一次、但今天还没有任何实例。
        //    - daily / weekdays 正常情况下由 materializeOccurrences 建好今天的实例，
        //      所以这一支对它们是兜底；真正的常客是 weeklyCount——它不预排日期，
        //      实例只在勾选时以 occurredOn 落库，不补这一支就会在今日里结构性隐形。
        //    勾选走 CompleteTask（模板 → completeTemplateOccurrence），与其它入口同一条写库路径。
        let templateIndex = Dictionary(allTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 候选只需要两件事：今天是否已记录、本周已做几次——两者都落在当前这一周里。
        // 按周取实例（而不是 ±45 天），避免规则多时每次都拉一大片数据。
        let week = DateOnlyRange.week(containing: date)
        let windowOccurrences = await repository.occurrences(scheduledIn: week, planID: nil)
        let occurrencesByRule = Dictionary(grouping: windowOccurrences, by: \.ruleId)

        for rule in await repository.rules() where rule.isActive {
            // 今天落在规则的生效窗口内
            guard rule.effectiveFrom <= date,
                  rule.effectiveUntil.map({ date <= $0 }) ?? true else { continue }
            // 今天本来就该有一次（weeklyCount 不匹配日期，按「本周还差几次」判）
            guard rule.pattern == .weeklyCount || rule.matches(date) else { continue }
            guard let task = templateIndex[rule.taskId], task.isTemplate, task.status.isOpen else { continue }
            let plan = task.planId.flatMap { planIndex[$0] }
            if plan?.status == .archived { continue }
            if let plan, plan.isPaused(on: date) { continue }

            let occurrences = occurrencesByRule[rule.id] ?? []

            var weeklyTarget: Int?
            var weeklyDone = 0
            if rule.pattern == .weeklyCount {
                let target = max(0, min(7, rule.weeklyCount ?? 0))
                let progress = RecurrencePolicy.weeklyProgress(rule: rule, occurrences: occurrences,
                                                               week: week, today: date)
                weeklyTarget = target
                weeklyDone = progress.done
                // 按整周看：没做够就留着，方便补足剩余次数（今天做过也不撤走，行上的
                // 「本周 x/y 次」会跟着更新）；做够了才离开当天的位置。
                guard progress.done + progress.skipped < target else { continue }
            } else {
                // 固定日期一天一次：今天已经有实例（含已跳过）就交给上面第 1 支，不重复出现。
                guard !occurrences.contains(where: { $0.scheduledOn == date || $0.occurredOn == date })
                else { continue }
            }

            let item = TodayItem(id: "routine-\(rule.id.uuidString)",
                                 body: .routine(rule: rule, task: task,
                                                weeklyTarget: weeklyTarget, weeklyDone: weeklyDone),
                                 section: .routine, planName: plan?.name, dependency: .ready,
                                 startAt: rule.occurrenceStart(on: date),
                                 endAt: rule.occurrenceEnd(on: date))
            if seen.insert(item.id).inserted { routine.append(item) }
        }

        focus.sort { sortKey($0) < sortKey($1) }
        later.sort { sortKey($0) < sortKey($1) }
        completed.sort { sortKey($0) < sortKey($1) }
        routine.sort { sortKey($0) < sortKey($1) }

        return TodayView(date: date, focus: focus, later: later, completed: completed, routine: routine)
    }

    /// 同一个 taskId 在今日、计划树、详情中恒等于同一对象（AC06）
    func sortKey(_ item: TodayItem) -> (Int, Int, String) {
        let hint = item.startAt?.secondsOfDayForSorting ?? 86_500
        let priority: Int = {
            switch item.body {
            case .deadline: 0
            case .occurrence: 1
            case .scheduled: 2
            case .inProgress: 3
            case .overdue: 4
            case .floating: 5
            // 候选排在所有「今天必须做」之后：它是可选的机会，不是承诺。
            case .routine: 6
            }
        }()
        return (priority, hint, item.title)
    }

    func sameDay(_ date: Date, _ day: DateOnly) -> Bool {
        let local = DateOnly(from: date, in: currentTimeZone)
        return local.y == day.y && local.m == day.m && local.d == day.d
    }

    // MARK: - 计划

    func plans(filter: PlanFilter = .active) async -> [PlanSummary] {
        let all = await repository.allPlans()
        let tombstones = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        let week = DateOnlyRange.week(containing: today)
        var out: [PlanSummary] = []

        for plan in all {
            if tombstones.contains(plan.id) { continue }
            if !filter.statuses.isEmpty, !filter.statuses.contains(plan.status) { continue }
            if !filter.categories.isEmpty {
                guard let category = plan.category, filter.categories.contains(category) else { continue }
            }
            if let text = filter.searchText, !text.isEmpty {
                let haystack = ([plan.name, plan.goalText ?? ""] + plan.aliases).joined(separator: " ")
                if !haystack.localizedCaseInsensitiveContains(text) { continue }
            }

            let tasks = await repository.tasks(planID: plan.id).filter { !tombstones.contains($0.id) }
            let metrics = await repository.metrics(planID: plan.id)
            let measurements = await repository.measurements(planID: plan.id)
            let rules = await repository.rules().filter { r in tasks.contains { $0.id == r.taskId } }
            let occurrences = await repository.occurrences(planID: plan.id).filter { !tombstones.contains($0.id) }

            let progress = ProgressPolicy.progressFor(plan: plan, tasks: tasks, rules: rules,
                                                      occurrences: occurrences, metrics: metrics,
                                                      measurements: measurements, week: week, today: today)
            let stages = await repository.stages(planID: plan.id).sorted { $0.sortIndex < $1.sortIndex }
            let currentStage = stages.first { $0.status == .inProgress || $0.status == .awaitingConfirm }
                ?? stages.first { $0.status == .notStarted }

            let nextTask = tasks
                .filter { $0.status.isOpen && !$0.isTemplate }
                .sorted { (sortDay(of: $0) ?? today.adding(days: 999)) < (sortDay(of: $1) ?? today.adding(days: 999)) }
                .first

            let activityRank = (tasks.map(\.updatedAt) + [plan.updatedAt]).max() ?? plan.updatedAt

            out.append(PlanSummary(
                id: plan.id, name: plan.name, kind: plan.kind, category: plan.category,
                status: plan.status, progress: progress,
                currentStageName: currentStage?.name,
                nextActionText: nextTask.map { nextActionText(for: $0) },
                targetDateText: planTimeText(plan),
                goalText: plan.goalText,
                cloudAIEnabled: plan.cloudAIEnabled, syncEnabled: plan.syncEnabled,
                activityRank: activityRank))
        }
        return out.sorted { $0.activityRank > $1.activityRank }
    }

    /// 计划列表里的起止摘要：有结束显示「截止」，只有开始显示「开始」
    func planTimeText(_ plan: Plan) -> String? {
        if let end = plan.endAt { return "\(end.displayString)截止" }
        if let start = plan.startAt { return "\(start.displayString)开始" }
        return nil
    }

    /// 任务在列表里的排序日：优先开始日期，其次结束日期
    func sortDay(of task: Task) -> DateOnly? {
        task.startAt?.dateOnly ?? task.endAt?.dateOnly
    }

    func nextActionText(for task: Task) -> String {
        if let d = task.startAt?.dateOnly {
            if d.isSameDay(as: today) { return "\(task.title) · 今天" }
            return "\(task.title) · \(d.displayString)"
        }
        if let end = task.endAt {
            return "\(task.title) · \(end.displayString)截止"
        }
        return "\(task.title) · 待安排"
    }

    func planProgress(_ planID: UUID) async -> PlanProgress {
        guard let plan = await repository.plan(planID) else {
            return .empty(reason: "找不到这个计划")
        }
        let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        let tasks = await repository.tasks(planID: planID).filter { !deleted.contains($0.id) }
        let metrics = await repository.metrics(planID: planID)
        let measurements = await repository.measurements(planID: planID)
        let rules = await repository.rules().filter { r in tasks.contains { $0.id == r.taskId } }
        let occurrences = await repository.occurrences(planID: planID).filter { !deleted.contains($0.id) }
        return ProgressPolicy.progressFor(plan: plan, tasks: tasks, rules: rules,
                                          occurrences: occurrences, metrics: metrics,
                                          measurements: measurements,
                                          week: DateOnlyRange.week(containing: today), today: today)
    }

    /// 惰性展开：depth 0 = 阶段 + 顶层任务
    func planTree(_ planID: UUID, depth: Int) async -> PlanTreeView {
        await materializeOccurrences(in: defaultMaterializeRange())
        guard let plan = await repository.plan(planID) else {
            return PlanTreeView(planId: planID, planName: "", depth: depth, nodes: [])
        }
        let tasks = await repository.tasks(planID: planID)
        let tombstones = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        let liveTasks = tasks.filter { !tombstones.contains($0.id) }
        let stages = await repository.stages(planID: planID).sorted { $0.sortIndex < $1.sortIndex }
        let rules = await repository.rules()
        let occurrences = await repository.occurrences(planID: planID)
        let week = DateOnlyRange.week(containing: today)

        let visible = liveTasks.filter { $0.parentId == nil && $0.status != .cancelled && !$0.isStep }
        let cancelled = liveTasks.filter { $0.status == .cancelled }

        func dependencyStates() -> [UUID: DependencyState] {
            DependencyPolicy.states(for: liveTasks, tombstoned: tombstones)
        }
        let depStates = dependencyStates()

        func occurrenceInfo(for task: Task) -> (current: [RecurrenceOccurrence], historical: Int) {
            guard task.isTemplate else { return ([], 0) }
            guard let rule = rules.first(where: { $0.taskId == task.id }) else { return ([], 0) }
            let scoped = occurrences.filter { $0.ruleId == rule.id }
            let current = scoped.filter { o in
                guard let d = o.scheduledOn ?? o.occurredOn else { return false }
                return week.contains(d)
            }
            let historical = scoped.count - current.count
            return (current.sorted { ($0.scheduledOn ?? today) < ($1.scheduledOn ?? today) }, historical)
        }

        func buildTaskNode(_ task: Task, level: Int, visited: Set<UUID> = []) -> PlanTreeNode {
            let info = occurrenceInfo(for: task)
            var next = visited
            next.insert(task.id)
            let kids = TaskHierarchy.ordered(liveTasks.filter {
                $0.parentId == task.id && $0.status != .cancelled && !$0.isStep && !next.contains($0.id)
            })
            return PlanTreeNode(
                id: task.id.uuidString, kind: .task(task),
                children: kids.map { buildTaskNode($0, level: level + 1, visited: next) },
                dependency: depStates[task.id] ?? .ready,
                currentOccurrences: info.current, historicalOccurrenceCount: info.historical,
                isCancelled: task.status == .cancelled)
        }

        var nodes: [PlanTreeNode] = []
        for stage in stages {
            let rollup = ProgressPolicy.stageRollup(stageID: stage.id, tasks: liveTasks)
            let children = TaskHierarchy.ordered(visible.filter { $0.stageId == stage.id })
                .map { buildTaskNode($0, level: 1) }
            nodes.append(PlanTreeNode(id: stage.id.uuidString,
                                     kind: .stage(stage, done: rollup.done, total: rollup.total),
                                     children: children))
        }
        nodes.append(contentsOf: TaskHierarchy.ordered(visible.filter { $0.stageId == nil })
            .map { buildTaskNode($0, level: 0) })

        // 已取消事项默认隐藏，但可从历史筛选中查找
        if !cancelled.isEmpty {
            nodes.append(PlanTreeNode(
                id: "cancelled-\(planID.uuidString)",
                kind: .group(title: "已取消事项", done: 0, total: cancelled.count,
                             children: cancelled.map { buildTaskNode($0, level: 1) }),
                children: [],
                hasHiddenChildren: true,
                hiddenChildCount: cancelled.count,
                isCancelled: true))
        }

        let rollup = ProgressPolicy.deliveryLeaves(in: liveTasks)
        return PlanTreeView(planId: planID, planName: plan.name, depth: depth, nodes: nodes,
                            leafDone: rollup.done, leafTotal: rollup.total)
    }

    /// 任务详情用：一跳依赖关系
    func dependencyGraph(taskID: UUID) async -> DependencyPolicy.RelationGraph {
        guard let task = await repository.task(taskID), let planID = task.planId else {
            return DependencyPolicy.RelationGraph()
        }
        let siblings = await repository.tasks(planID: planID)
        return DependencyPolicy.relationGraph(for: task, planTasks: siblings)
    }

    func dependencyBlockerTitles(taskID: UUID) async -> [String] {
        guard let task = await repository.task(taskID), let planID = task.planId else { return [] }
        let siblings = await repository.tasks(planID: planID)
        let tombstoned = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        return DependencyPolicy.blockerTitles(for: task, planTasks: siblings, tombstoned: tombstoned)
    }

    func getOrganizeHistory() async -> [OrganizeRecord] {
        await organizeHistory()
    }
}
