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

    public static func validateTaskStructure(_ task: Task, repository: DomainRepository) async throws {
        // C8
        try await requireWritable(id: task.id, type: .task, repository: repository)

        // C4：isTemplate 必须存在 RecurrenceRule
        if task.isTemplate {
            let rule = await repository.rule(forTask: task.id)
            if rule == nil {
                throw MovoError.invalidStructure(reason: "重复行动必须带有重复频率。请先设置频率再保存。")
            }
        }

        // 归属计划必须在（未删除）
        if let planID = task.planId {
            guard let plan = await repository.plan(planID) else {
                throw MovoError.notFound(entityType: .plan, id: planID)
            }
            if plan.status == .archived {
                throw MovoError.invalidStructure(reason: "「\(plan.name)」已归档，不能新增任务。")
            }
        }

        // 阶段归属
        if let stageID = task.stageId {
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

        // C1：子任务必须与父任务同计划
        if parent.planId != task.planId {
            throw MovoError.invalidStructure(reason: "子任务和父任务必须在同一个计划下。")
        }
        // C2：只允许一层
        if parent.parentId != nil {
            throw MovoError.invalidStructure(reason: "子任务只支持一层，不能再嵌套。")
        }
        // C3：父链不得成环
        try await assertNoParentCycle(startingAt: task.id, repository: repository)
    }

    /// C3：沿 parentId 链向上，不得回到起点
    static func assertNoParentCycle(startingAt taskID: UUID, repository: DomainRepository) async throws {
        var seen: Set<UUID> = [taskID]
        var cursor = taskID
        var hops = 0
        while hops < 64, let current = await repository.task(cursor), let parentID = current.parentId {
            if seen.contains(parentID) {
                throw MovoError.invalidStructure(reason: "任务的上下级关系形成了环。")
            }
            seen.insert(parentID)
            cursor = parentID
            hops += 1
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
        if parent.parentId != nil {
            throw MovoError.invalidStructure(reason: "子任务只支持一层，不能再嵌套。")
        }
        if await hasDescendant(parent.id, ancestor: child.id, repository: repository) {
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
    }
}
