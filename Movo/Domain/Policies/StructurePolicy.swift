//
//  StructurePolicy.swift
//  Domain/Policies
//
//  3.3 硬约束 C1–C9。保存前校验，违反则拒绝并保留原输入（AC09）。
//  C8 已 tombstone 对象拒绝一切写入（唯一例外：恢复命令）。
//

import Foundation

public enum StructurePolicy {

    // MARK: - C8 可写性

    public static func requireWritable(id: UUID, type: EntityType, repository: DomainRepository) async throws {
        if await repository.isTombstoned(id) {
            throw MovoError.invalidStructure(reason: "这条\(type.displayName)已在最近删除中，不能直接修改。可以先恢复它。")
        }
    }

    // MARK: - 计划

    /// C7：archived 计划不接收自动归类
    public static func validatePlanAcceptsAutoClassification(planID: UUID?, repository: DomainRepository) async throws {
        guard let planID else { return }
        guard let plan = await repository.plan(planID) else {
            throw MovoError.notFound(entityType: .plan, id: planID)
        }
        if plan.status == .archived {
            throw MovoError.invalidStructure(
                reason: "「\(plan.name)」已归档。可以恢复它，或把这条作为历史补记。")
        }
    }

    /// 明确指定到归档计划：拦截（PRD 5.3 / C7）
    public static func validateExplicitReassign(to planID: UUID?, repository: DomainRepository) async throws {
        guard let planID, let plan = await repository.plan(planID) else { return }
        if plan.status == .archived {
            throw MovoError.invalidStructure(
                reason: "「\(plan.name)」已归档，不能作为新内容的归属。可以先恢复它。")
        }
    }

    // MARK: - 任务结构（C1/C2/C3/C4）

    public static func validateTaskStructure(_ task: Task, repository: DomainRepository,
                                             requiresRecurrenceRule: Bool = true) async throws {
        // C8
        try await requireWritable(id: task.id, type: .task, repository: repository)
        // 顶层重复行动下只能有步骤，不能有普通子任务
        if task.isTemplate && !task.isStep {
            let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
            let children = await repository.children(of: task.id)
            if children.contains(where: { !deleted.contains($0.id) && $0.status != .cancelled && !$0.isTemplate }) {
                throw MovoError.invalidStructure(reason: "有子任务的待办不能设为重复行动。")
            }
        }

        // C4：顶层模板必须存在 RecurrenceRule（步骤不需要自己的规则）
        if task.isTemplate && !task.isStep && requiresRecurrenceRule {
            let rule = await repository.rule(forTask: task.id)
            if rule == nil {
                throw MovoError.invalidStructure(reason: "重复行动必须带有重复频率。请先设置频率再保存。")
            }
        }

        // 归属计划必须在（未删除）
        if let planID = task.planId {
            try await requireWritable(id: planID, type: .plan, repository: repository)
            guard let plan = await repository.plan(planID) else {
                throw MovoError.notFound(entityType: .plan, id: planID)
            }
            if plan.status == .archived {
                throw MovoError.invalidStructure(reason: "「\(plan.name)」已归档，不能新增任务。")
            }
        }

        // 阶段归属
        if let stageID = task.stageId {
            try await requireWritable(id: stageID, type: .stage, repository: repository)
            guard let stage = await repository.stage(stageID) else {
                throw MovoError.notFound(entityType: .stage, id: stageID)
            }
            guard stage.planId == task.planId else {
                throw MovoError.invalidStructure(reason: "阶段和任务不在同一个计划下。")
            }
        }

        guard let parentID = task.parentId else { return }

        // C3：不允许自引用
        if parentID == task.id {
            throw MovoError.invalidStructure(reason: "任务不能把自己作为父任务。")
        }
        guard let parent = await repository.task(parentID) else {
            throw MovoError.notFound(entityType: .task, id: parentID)
        }
        try await requireWritable(id: parentID, type: .task, repository: repository)
        if parent.status == .cancelled {
            throw MovoError.invalidStructure(reason: "上级待办已取消，请先重新打开。")
        }

        // C1：子任务必须与父任务同计划
        if parent.planId != task.planId {
            throw MovoError.invalidStructure(reason: "子任务和父任务必须在同一个计划下。")
        }
        if parent.stageId != task.stageId {
            throw MovoError.invalidStructure(reason: "子任务和父任务必须在同一个阶段下。")
        }
        if parent.isTemplate && !task.isTemplate {
            throw MovoError.invalidStructure(reason: "重复行动下只能添加步骤，不能添加普通待办。")
        }
        if task.isTemplate && !parent.isTemplate {
            throw MovoError.invalidStructure(reason: "重复行动不能放在其它待办下面。")
        }
        // 校验候选父链，不能从仓储中的旧 task 开始（新建时尚未落库）。
        var seen: Set<UUID> = [task.id]
        var cursor: UUID? = parentID
        while let id = cursor {
            guard seen.insert(id).inserted else {
                throw MovoError.invalidStructure(reason: "任务的上下级关系形成了环。")
            }
            cursor = await repository.task(id)?.parentId
        }
    }

    /// C3：沿 parentId 链向上，不得回到起点
    static func assertNoParentCycle(startingAt taskID: UUID, repository: DomainRepository) async throws {
        var seen: Set<UUID> = [taskID]
        var cursor = taskID
        while let current = await repository.task(cursor), let parentID = current.parentId {
            if seen.contains(parentID) {
                throw MovoError.invalidStructure(reason: "任务的上下级关系形成了环。")
            }
            seen.insert(parentID)
            cursor = parentID
        }
    }

    /// 把子任务挂到新父任务时的校验（父变更场景）
    public static func validateReparent(child: Task, to parent: Task?, repository: DomainRepository) async throws {
        guard let parent else { return }
        if parent.id == child.id {
            throw MovoError.invalidStructure(reason: "任务不能把自己作为父任务。")
        }
        if parent.planId != child.planId {
            throw MovoError.invalidStructure(reason: "子任务和父任务必须在同一个计划下。")
        }
        if await hasDescendant(child.id, ancestor: parent.id, repository: repository) {
            throw MovoError.invalidStructure(reason: "任务的上下级关系会形成环。")
        }
    }

    static func hasDescendant(_ candidate: UUID, ancestor: UUID, repository: DomainRepository) async -> Bool {
        var stack = [candidate]
        var visited: Set<UUID> = []
        while let current = stack.popLast() {
            if current == ancestor { return true }
            if !visited.insert(current).inserted { continue }
            let kids = await repository.children(of: current)
            stack.append(contentsOf: kids.map(\.id))
        }
        return false
    }

    // MARK: - C5 Measurement

    public static func validateMeasurement(_ m: Measurement, repository: DomainRepository) async throws {
        try await requireWritable(id: m.id, type: .measurement, repository: repository)
        guard m.value.isFinite else {
            throw MovoError.invalidStructure(reason: "测量值必须是有效数字，不能留空或用 0 代替缺测。")
        }
        guard let metric = await repository.metric(m.metricId) else {
            throw MovoError.notFound(entityType: .metric, id: m.metricId)
        }
        guard metric.planId == m.planId else {
            throw MovoError.invalidStructure(reason: "这条结果不属于所选的计划。")
        }
        if !m.unit.isEmpty, !metric.unit.isEmpty, m.unit != metric.unit {
            throw MovoError.invalidStructure(reason: "单位与指标设定不一致（指标单位为 \(metric.unitDisplayName)）。")
        }
    }

    // MARK: - C6 Occurrence

    public static func validateOccurrence(_ o: RecurrenceOccurrence, repository: DomainRepository) async throws {
        try await requireWritable(id: o.id, type: .occurrence, repository: repository)
        guard let rule = await repository.rule(o.ruleId) else {
            throw MovoError.notFound(entityType: .rule, id: o.ruleId)
        }
        if await repository.isTombstoned(rule.id) {
            throw MovoError.invalidStructure(reason: "这条重复规则已被删除，不能记录本次。")
        }
        if rule.taskId != o.taskId {
            throw MovoError.invalidStructure(reason: "重复实例与规则不匹配。")
        }
        // 规则版本必须是已存在的版本（新版本只实例化 effectiveFrom 之后）
        if o.ruleVersion > rule.version {
            throw MovoError.invalidStructure(reason: "规则版本尚未生效。")
        }
    }

    // MARK: - C9 依赖

    public static func validateDependency(taskID: UUID, dependsOn dependencyID: UUID,
                                          repository: DomainRepository) async throws {
        guard taskID != dependencyID else {
            throw MovoError.invalidStructure(reason: "任务不能依赖自己。")
        }
        guard let task = await repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        guard let dependency = await repository.task(dependencyID) else {
            throw MovoError.notFound(entityType: .task, id: dependencyID)
        }
        // 同计划内
        guard task.planId == dependency.planId, task.planId != nil else {
            throw MovoError.invalidStructure(reason: "只支持同一个计划内的前置关系。")
        }
        if await repository.isTombstoned(dependencyID) {
            throw MovoError.invalidStructure(reason: "这条前置任务已在最近删除中。")
        }
        // 不得成环：从 dependency 出发能否到达 task
        if await reaches(from: dependencyID, to: taskID, repository: repository) {
            throw MovoError.invalidStructure(reason: "这些前置关系会形成环。")
        }
    }

    /// DFS 校验 dependencyIDs 链
    public static func reaches(from start: UUID, to target: UUID, repository: DomainRepository) async -> Bool {
        var stack = [start]
        var visited: Set<UUID> = []
        while let current = stack.popLast() {
            if current == target { return true }
            if !visited.insert(current).inserted { continue }
            guard let node = await repository.task(current) else { continue }
            stack.append(contentsOf: node.dependencyIDs)
        }
        return false
    }

    /// 删除/移动预览用：列出将解除的依赖数（REQ 09）
    public static func dependents(of taskID: UUID, repository: DomainRepository) async -> [Task] {
        guard let task = await repository.task(taskID), let planID = task.planId else { return [] }
        let siblings = await repository.tasks(planID: planID)
        return siblings.filter { $0.dependencyIDs.contains(taskID) }
    }

    // MARK: - 输入合法性

    public static func validateTitle(_ title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw MovoError.invalidStructure(reason: "任务标题不能为空。")
        }
        if trimmed.count > Task.maxTitleLength {
            throw MovoError.invalidStructure(reason: "标题最多 \(Task.maxTitleLength) 字，当前 \(trimmed.count) 字。")
        }
    }

    public static func validatePlanName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw MovoError.invalidStructure(reason: "计划需要一个名字。")
        }
        if trimmed.count > 120 {
            throw MovoError.invalidStructure(reason: "计划名称最多 120 字。")
        }
    }

    public static func validateStageName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw MovoError.invalidStructure(reason: "阶段需要一个名称。")
        }
    }

    public static func validateMetricUnit(_ unit: String) throws {
        if unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MovoError.invalidStructure(reason: "结果指标需要一个单位，例如公斤或分钟。")
        }
    }

    public static func validateRuleFields(_ rule: RecurrenceRule) throws {
        guard rule.isFieldComplete else {
            switch rule.pattern {
            case .daily:
                throw MovoError.invalidStructure(reason: "重复频率的设置不完整。")
            case .weekdays:
                throw MovoError.invalidStructure(reason: "请至少选择一个星期几。")
            case .weeklyCount:
                throw MovoError.invalidStructure(reason: "每周次数需要在 1 到 7 之间。")
            }
        }
        if let start = rule.dailyStart, !start.isValid {
            throw MovoError.invalidStructure(reason: "每天的开始时刻不合法。")
        }
        if let end = rule.dailyEnd, !end.isValid {
            throw MovoError.invalidStructure(reason: "每天的结束时刻不合法。")
        }
        if let start = rule.dailyStart, let end = rule.dailyEnd,
           end.secondsFromMidnight < start.secondsFromMidnight {
            throw MovoError.invalidStructure(reason: "每天的结束时刻不能早于开始时刻。")
        }
    }

    // MARK: - 起止时间

    /// 结束不得早于开始；任一端为空不校验。
    public static func validateTimeOrder(startAt: TimePoint?, endAt: TimePoint?) throws {
        guard let startAt, let endAt else { return }
        if endAt.isEarlier(than: startAt) {
            throw MovoError.invalidStructure(reason: "结束时间不能早于开始时间。")
        }
    }

    static func rangeText(_ start: TimePoint?, _ end: TimePoint?) -> String {
        switch (start, end) {
        case (let s?, let e?): return "\(s.displayString) – \(e.displayString)"
        case (let s?, nil): return "\(s.displayString) 起"
        case (nil, let e?): return "至 \(e.displayString)"
        case (nil, nil): return "未设置"
        }
    }

    /// 子级必须落在父级范围内；只校验父级已设置的一端，父级为空的一端不约束。
    static func validateWithin(startAt: TimePoint?, endAt: TimePoint?,
                               parentStart: TimePoint?, parentEnd: TimePoint?,
                               child: String, parent: String) throws {
        if let reason = withinViolation(startAt: startAt, endAt: endAt,
                                        parentStart: parentStart, parentEnd: parentEnd,
                                        child: child, parent: parent) {
            throw MovoError.invalidStructure(reason: reason)
        }
    }

    /// 超出父级范围时返回原因文案，否则返回 nil。
    public static func withinViolation(startAt: TimePoint?, endAt: TimePoint?,
                                parentStart: TimePoint?, parentEnd: TimePoint?,
                                child: String, parent: String) -> String? {
        let reason = "\(child)的时间超出了\(parent)的范围，请先调整时间。"
        if let parentStart {
            if let startAt, startAt.isEarlier(than: parentStart) { return reason }
            if let endAt, endAt.isEarlier(than: parentStart) { return reason }
        }
        if let parentEnd {
            if let endAt, endAt.isLater(than: parentEnd) { return reason }
            if let startAt, startAt.isLater(than: parentEnd) { return reason }
        }
        return nil
    }

    /// 任务是否超出上级任务、阶段或计划的范围。保存校验和界面提示共用；界面只提示，不拒绝任何操作。
    public static func timeRangeViolation(for task: Task, repository: DomainRepository) async -> String? {
        guard task.startAt != nil || task.endAt != nil else { return nil }
        let child = "「\(task.title)」"
        var seen: Set<UUID> = [task.id]
        var cursor = task.parentId
        while let id = cursor, seen.insert(id).inserted, let parent = await repository.task(id) {
            if let reason = withinViolation(
                startAt: task.startAt, endAt: task.endAt,
                parentStart: parent.startAt, parentEnd: parent.endAt, child: child,
                parent: "上级待办「\(parent.title)」（\(rangeText(parent.startAt, parent.endAt))）") {
                return reason
            }
            cursor = parent.parentId
        }
        if let stageID = task.stageId, let stage = await repository.stage(stageID),
           let reason = withinViolation(
            startAt: task.startAt, endAt: task.endAt,
            parentStart: stage.startAt, parentEnd: stage.endAt, child: child,
            parent: "阶段「\(stage.name)」（\(rangeText(stage.startAt, stage.endAt))）") {
            return reason
        }
        if let planID = task.planId, let plan = await repository.plan(planID),
           let reason = withinViolation(
            startAt: task.startAt, endAt: task.endAt,
            parentStart: plan.startAt, parentEnd: plan.endAt, child: child,
            parent: "计划「\(plan.name)」（\(rangeText(plan.startAt, plan.endAt))）") {
            return reason
        }
        return nil
    }

    /// 任务起止校验：先看自身先后，再看是否落在上级任务、阶段、计划之内；
    /// 时间变小时还要确认未完成的下级不会因此越界。已有的越界数据只在这里被改动时才会被要求修正。
    public static func validateTaskTime(_ task: Task, old: Task?, repository: DomainRepository) async throws {
        try validateTimeOrder(startAt: task.startAt, endAt: task.endAt)

        let timeChanged: Bool
        let placementChanged: Bool
        if let old {
            timeChanged = old.startAt != task.startAt || old.endAt != task.endAt
            placementChanged = old.parentId != task.parentId || old.stageId != task.stageId
                || old.planId != task.planId
        } else {
            timeChanged = true
            placementChanged = true
        }

        if task.startAt != nil || task.endAt != nil, timeChanged || placementChanged,
           let reason = await timeRangeViolation(for: task, repository: repository) {
            throw MovoError.invalidStructure(reason: reason)
        }

        if old != nil, timeChanged {
            let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
            var stack = await repository.children(of: task.id)
            var visited: Set<UUID> = [task.id]
            while let child = stack.popLast() {
                guard visited.insert(child.id).inserted, !deleted.contains(child.id) else { continue }
                let grandchildren = await repository.children(of: child.id)
                stack.append(contentsOf: grandchildren)
                // 已完成、已取消的历史不拦截上级调整时间
                guard child.status != .done, child.status != .cancelled else { continue }
                try validateWithin(startAt: child.startAt, endAt: child.endAt,
                                   parentStart: task.startAt, parentEnd: task.endAt,
                                   child: "子任务「\(child.title)」",
                                   parent: "「\(task.title)」（\(rangeText(task.startAt, task.endAt))）")
            }
        }
    }

    /// 阶段起止校验：落在计划之内；时间变小时，阶段下未完成的任务和重复规则也不能越界。
    public static func validateStageTime(_ stage: Stage, old: Stage?, repository: DomainRepository) async throws {
        try validateTimeOrder(startAt: stage.startAt, endAt: stage.endAt)

        let timeChanged: Bool
        if let old {
            timeChanged = old.startAt != stage.startAt || old.endAt != stage.endAt
        } else {
            timeChanged = true
        }
        guard timeChanged else { return }

        if stage.startAt != nil || stage.endAt != nil, let plan = await repository.plan(stage.planId) {
            try validateWithin(startAt: stage.startAt, endAt: stage.endAt,
                               parentStart: plan.startAt, parentEnd: plan.endAt,
                               child: "阶段「\(stage.name)」",
                               parent: "计划「\(plan.name)」（\(rangeText(plan.startAt, plan.endAt))）")
        }
        guard old != nil else { return }
        let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        for task in await repository.tasks(planID: stage.planId)
            where task.stageId == stage.id && !deleted.contains(task.id) {
            try await validateOpenTaskFits(task, startAt: stage.startAt, endAt: stage.endAt,
                                           parent: "阶段「\(stage.name)」（\(rangeText(stage.startAt, stage.endAt))）",
                                           repository: repository)
        }
    }

    /// 计划起止校验：时间变小时，计划下未完成的阶段、任务和重复规则不能越界。
    public static func validatePlanTime(_ plan: Plan, old: Plan?, repository: DomainRepository) async throws {
        try validateTimeOrder(startAt: plan.startAt, endAt: plan.endAt)
        guard let old, old.startAt != plan.startAt || old.endAt != plan.endAt else { return }

        let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        let parent = "计划「\(plan.name)」（\(rangeText(plan.startAt, plan.endAt))）"
        for stage in await repository.stages(planID: plan.id)
            where !deleted.contains(stage.id) && stage.status != .achieved && stage.status != .cancelled {
            try validateWithin(startAt: stage.startAt, endAt: stage.endAt,
                               parentStart: plan.startAt, parentEnd: plan.endAt,
                               child: "阶段「\(stage.name)」", parent: parent)
        }
        for task in await repository.tasks(planID: plan.id) where !deleted.contains(task.id) {
            try await validateOpenTaskFits(task, startAt: plan.startAt, endAt: plan.endAt,
                                           parent: parent, repository: repository)
        }
    }

    /// 未完成的任务（或重复模板的有效期）是否落在给定范围内
    private static func validateOpenTaskFits(_ task: Task, startAt: TimePoint?, endAt: TimePoint?,
                                             parent: String, repository: DomainRepository) async throws {
        if task.isTemplate {
            guard let rule = await repository.rule(forTask: task.id) else { return }
            try validateWithin(startAt: .day(rule.effectiveFrom), endAt: rule.effectiveUntil.map { .day($0) },
                               parentStart: startAt, parentEnd: endAt,
                               child: "重复行动「\(task.title)」", parent: parent)
            return
        }
        guard task.status != .done, task.status != .cancelled else { return }
        try validateWithin(startAt: task.startAt, endAt: task.endAt,
                           parentStart: startAt, parentEnd: endAt,
                           child: "待办「\(task.title)」", parent: parent)
    }

    /// 重复规则的有效期必须落在所属计划、阶段范围内（只校验已设置的端）。
    public static func validateRuleTime(_ rule: RecurrenceRule, task: Task, repository: DomainRepository) async throws {
        let start: TimePoint = .day(rule.effectiveFrom)
        let end: TimePoint? = rule.effectiveUntil.map { .day($0) }
        let child = "重复行动「\(task.title)」"
        if let stageID = task.stageId, let stage = await repository.stage(stageID) {
            try validateWithin(startAt: start, endAt: end,
                               parentStart: stage.startAt, parentEnd: stage.endAt, child: child,
                               parent: "阶段「\(stage.name)」（\(rangeText(stage.startAt, stage.endAt))）")
        }
        if let planID = task.planId, let plan = await repository.plan(planID) {
            try validateWithin(startAt: start, endAt: end,
                               parentStart: plan.startAt, parentEnd: plan.endAt, child: child,
                               parent: "计划「\(plan.name)」（\(rangeText(plan.startAt, plan.endAt))）")
        }
    }
}
