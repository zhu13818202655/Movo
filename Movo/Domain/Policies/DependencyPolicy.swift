//
//  DependencyPolicy.swift
//  Domain/Policies
//
//  4.4 dependencyStatus(task, planTasks)。纯函数、派生不落库；
//  忽略已取消与已删除前置；仅提示，不阻断任何操作（PRD 6.3）。
//

import Foundation

public enum DependencyPolicy {

    /// blockedBy = dependencyIDs 中 status ∉ {done, cancelled, tombstone} 的数量
    public static func status(for task: Task, planTasks: [Task], tombstoned: Set<UUID> = []) -> DependencyState {
        guard !task.dependencyIDs.isEmpty else { return .ready }
        let index = Dictionary(planTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var blocked = 0
        for id in task.dependencyIDs {
            if tombstoned.contains(id) { continue }          // 已删除 → 自动解除
            guard let dep = index[id] else { continue }       // 不在本快照内 → 视为已解除
            if dep.status.satisfiesDependency { continue }    // done / cancelled
            blocked += 1
        }
        return blocked == 0 ? .ready : .waiting(count: blocked)
    }

    /// 名称列表（任务详情"等待：A、B"）
    public static func blockerTitles(for task: Task, planTasks: [Task], tombstoned: Set<UUID> = []) -> [String] {
        let index = Dictionary(planTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return task.dependencyIDs.compactMap { id in
            if tombstoned.contains(id) { return nil }
            guard let dep = index[id], !dep.status.satisfiesDependency else { return nil }
            return dep.title
        }
    }

    /// 后继任务（谁依赖我）
    public static func dependents(of taskID: UUID, planTasks: [Task]) -> [Task] {
        planTasks.filter { $0.dependencyIDs.contains(taskID) }
    }

    /// 一跳关系图节点：> 8 节点折叠为列表（10.5）
    public struct RelationGraph: Hashable, Sendable {
        public struct Node: Identifiable, Hashable, Sendable {
            public var id: UUID
            public var title: String
            public var statusText: String
            public var isRoot: Bool
            public var isPredecessor: Bool

            public init(id: UUID, title: String, statusText: String, isRoot: Bool, isPredecessor: Bool) {
                self.id = id; self.title = title; self.statusText = statusText
                self.isRoot = isRoot; self.isPredecessor = isPredecessor
            }
        }
        public struct Edge: Hashable, Sendable, Identifiable {
            public var id: String
            public var from: UUID
            public var to: UUID
            public init(from: UUID, to: UUID) {
                self.from = from; self.to = to; self.id = "\(from.uuidString)->\(to.uuidString)"
            }
        }

        public var nodes: [Node]
        public var edges: [Edge]
        public var collapsedToEdgeList: Bool

        public init(nodes: [Node] = [], edges: [Edge] = []) {
            self.nodes = nodes; self.edges = edges
            self.collapsedToEdgeList = nodes.count > 8
        }

        /// > 8 节点折叠为列表
        public var maxNodesBeforeCollapse: Int { 8 }
    }

    public static func relationGraph(for task: Task, planTasks: [Task]) -> RelationGraph {
        let index = Dictionary(planTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var nodes: [RelationGraph.Node] = []
        var edges: [RelationGraph.Edge] = []

        nodes.append(.init(id: task.id, title: task.title, statusText: task.status.displayName,
                           isRoot: true, isPredecessor: false))

        for id in task.dependencyIDs {
            guard let dep = index[id] else { continue }
            nodes.append(.init(id: dep.id, title: dep.title, statusText: dep.status.displayName,
                               isRoot: false, isPredecessor: true))
            edges.append(.init(from: dep.id, to: task.id))
        }

        let successors = dependents(of: task.id, planTasks: planTasks)
        for s in successors {
            nodes.append(.init(id: s.id, title: s.title, statusText: s.status.displayName,
                               isRoot: false, isPredecessor: false))
            edges.append(.init(from: task.id, to: s.id))
        }

        var seen = Set<UUID>()
        let uniqueNodes = nodes.filter { seen.insert($0.id).inserted }
        return RelationGraph(nodes: uniqueNodes, edges: edges)
    }

    /// 删除/移动预览：列出将解除的依赖数量（T1.5 预览数字必须与实际一致）
    public static func previewReleases(removing taskIDs: Set<UUID>, planTasks: [Task]) -> Int {
        planTasks.reduce(into: 0) { count, task in
            guard !taskIDs.contains(task.id) else { return }
            count += task.dependencyIDs.filter { taskIDs.contains($0) }.count
        }
    }

    /// 计划树/今日的就绪等待批量计算
    public static func states(for tasks: [Task], tombstoned: Set<UUID> = []) -> [UUID: DependencyState] {
        let index = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [UUID: DependencyState] = [:]
        for task in tasks {
            guard !task.dependencyIDs.isEmpty else { out[task.id] = .ready; continue }
            var blocked = 0
            for id in task.dependencyIDs {
                if tombstoned.contains(id) { continue }
                guard let dep = index[id] else { continue }
                if dep.status.satisfiesDependency { continue }
                blocked += 1
            }
            out[task.id] = blocked == 0 ? .ready : .waiting(count: blocked)
        }
        return out
    }
}
