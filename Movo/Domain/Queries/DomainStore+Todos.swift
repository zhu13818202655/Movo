import Foundation

public enum TodoFilter: String, CaseIterable, Identifiable, Sendable {
    case all, today, upcoming, unscheduled
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "全部"
        case .today: "今日"
        case .upcoming: "即将"
        case .unscheduled: "未安排"
        }
    }
}

public struct TodoNode: Identifiable, Hashable, Sendable {
    public var id: UUID { task.id }
    public var task: Task
    public var planName: String?
    public var children: [TodoNode]
    public var done: Int
    public var total: Int
    public var hasChildren: Bool
    public var isContext: Bool
    public var isComplete: Bool { hasChildren ? total > 0 && done == total : task.status == .done }
}

public extension DomainStore {
    /// 日期筛选保留命中项的祖先作为上下文，不复制任务，也不要求任务属于计划。
    func todos(filter: TodoFilter = .all, includeCompleted: Bool = false,
               planID: UUID? = nil, parentID: UUID? = nil) async -> [TodoNode] {
        let plans = await repository.allPlans()
        let planIndex = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        let all = await repository.allTasks()
        let index = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = TaskHierarchy.ordered(all.filter { task in
            guard !task.isStep, !deleted.contains(task.id), task.status != .cancelled,
                  task.planId.map({ deleted.contains($0) || planIndex[$0]?.status == .archived }) != true
            else { return false }
            var cursor = task.parentId
            var seen: Set<UUID> = [task.id]
            while let id = cursor {
                guard seen.insert(id).inserted, !deleted.contains(id) else { return false }
                guard let parent = index[id] else { break }
                if parent.status == .cancelled { return false }
                cursor = parent.parentId
            }
            return planID == nil || task.planId == planID
        })
        let children = Dictionary(grouping: live, by: \.parentId)
        let liveIDs = Set(live.map(\.id))
        func build(_ task: Task, visited: Set<UUID>) -> TodoNode? {
            guard !visited.contains(task.id) else { return nil }
            var next = visited
            next.insert(task.id)
            let kids = children[task.id] ?? []
            let rollup = ProgressPolicy.groupRollup(parentID: task.id, tasks: live)
            let complete = kids.isEmpty ? task.status == .done : rollup.total > 0 && rollup.done == rollup.total
            let dateMatches: Bool
            switch filter {
            case .all: dateMatches = true
            case .today:
                dateMatches = !task.isTemplate && (task.startAt.map { $0.dateOnly <= today } == true
                    || task.endAt.map { $0.dateOnly <= today } == true
                    || task.status == .inProgress || task.status == .blocked
                    || task.doneAt.map { sameDay($0, today) } == true)
            case .upcoming:
                dateMatches = task.startAt.map { $0.dateOnly > today } == true
                    || task.endAt.map { $0.dateOnly > today } == true
            case .unscheduled: dateMatches = task.startAt == nil && task.endAt == nil && !task.isTemplate
            }
            let matches = dateMatches && (includeCompleted || !complete)
            let nodes = kids.compactMap { build($0, visited: next) }
            guard matches || !nodes.isEmpty else { return nil }
            return TodoNode(task: task, planName: task.planId.flatMap { planIndex[$0]?.name },
                            children: nodes, done: rollup.done, total: rollup.total,
                            hasChildren: !kids.isEmpty, isContext: !matches)
        }
        let roots = live.filter { task in
            if let parentID { return task.parentId == parentID }
            return task.parentId == nil || !liveIDs.contains(task.parentId!)
        }
        return roots.compactMap { build($0, visited: []) }
    }
}
