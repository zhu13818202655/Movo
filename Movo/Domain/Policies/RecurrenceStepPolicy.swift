//
//  RecurrenceStepPolicy.swift
//  Domain/Policies
//
//  重复行动的多级步骤：步骤是 `isTemplate = true` 且挂在模板（或上一级步骤）下的 Task；
//  每次执行只记录这一次的勾选状态（`RecurrenceOccurrence.steps`），不为每天生成一棵任务子树。
//

import Foundation

public enum RecurrenceStepPolicy {

    /// 模板下仍有效的步骤，深度优先，同级按创建时间。已删除、已取消的不算。
    public static func liveSteps(templateID: UUID,
                                 repository: DomainRepository) async -> [(task: Task, depth: Int)] {
        let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        var out: [(task: Task, depth: Int)] = []
        var seen: Set<UUID> = [templateID]
        let roots = TaskHierarchy.ordered(await repository.children(of: templateID))
        var stack: [(task: Task, depth: Int)] = roots.reversed().map { (task: $0, depth: 0) }
        while let entry = stack.popLast() {
            let task = entry.task
            guard seen.insert(task.id).inserted, task.isTemplate, task.status != .cancelled,
                  !deleted.contains(task.id) else { continue }
            out.append(entry)
            let kids = TaskHierarchy.ordered(await repository.children(of: task.id))
            for kid in kids.reversed() { stack.append((task: kid, depth: entry.depth + 1)) }
        }
        return out
    }

    /// 从模板当前的步骤拍一份快照（全部未完成）；模板没有步骤时返回 nil。
    public static func snapshot(templateID: UUID, repository: DomainRepository) async -> [OccurrenceStep]? {
        let live = await liveSteps(templateID: templateID, repository: repository)
        guard !live.isEmpty else { return nil }
        return live.map { entry in
            OccurrenceStep(id: entry.task.id,
                           parentId: entry.task.parentId == templateID ? nil : entry.task.parentId,
                           title: entry.task.title)
        }
    }

    /// 叶子步骤的完成情况：上级步骤由下级汇总，不单独计数。
    public static func leafProgress(_ steps: [OccurrenceStep]) -> (done: Int, total: Int) {
        let parents = Set(steps.compactMap(\.parentId))
        let leaves = steps.filter { !parents.contains($0.id) }
        return (leaves.filter(\.isDone).count, leaves.count)
    }

    public static func isAllDone(_ steps: [OccurrenceStep]) -> Bool {
        let progress = leafProgress(steps)
        return progress.total > 0 && progress.done == progress.total
    }

    /// 上级步骤的勾选状态由下级叶子推出，保持清单自洽。
    public static func withDerivedParents(_ steps: [OccurrenceStep]) -> [OccurrenceStep] {
        let children = Dictionary(grouping: steps, by: \.parentId)
        func done(_ step: OccurrenceStep, visited: Set<UUID>) -> Bool {
            guard !visited.contains(step.id) else { return step.isDone }
            let kids = children[step.id] ?? []
            if kids.isEmpty { return step.isDone }
            var next = visited
            next.insert(step.id)
            return kids.allSatisfy { done($0, visited: next) }
        }
        return steps.map { step in
            var updated = step
            updated.isDone = done(step, visited: [])
            return updated
        }
    }

    /// 按层级排好的清单（深度优先，同级保持原有顺序），用于缩进展示。
    public static func indented(_ steps: [OccurrenceStep]) -> [(step: OccurrenceStep, depth: Int)] {
        let ids = Set(steps.map(\.id))
        let byParent = Dictionary(grouping: steps, by: \.parentId)
        var out: [(step: OccurrenceStep, depth: Int)] = []
        var seen: Set<UUID> = []
        func walk(_ step: OccurrenceStep, depth: Int) {
            guard seen.insert(step.id).inserted else { return }
            out.append((step, depth))
            for kid in byParent[step.id] ?? [] { walk(kid, depth: depth + 1) }
        }
        for step in steps where step.parentId == nil || !ids.contains(step.parentId!) {
            walk(step, depth: 0)
        }
        return out
    }

    /// 实例要展示的步骤：已有快照用快照，否则展示模板当前的步骤。
    public static func displaySteps(of occurrence: RecurrenceOccurrence,
                                    repository: DomainRepository) async -> [OccurrenceStep] {
        if let steps = occurrence.steps { return steps }
        return await snapshot(templateID: occurrence.taskId, repository: repository) ?? []
    }
}
