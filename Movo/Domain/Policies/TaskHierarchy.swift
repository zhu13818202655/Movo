import Foundation

/// 共享的任务树遍历；所有遍历均防环，排序在日期相同时仍保持稳定。
public enum TaskHierarchy {
    public static func ordered(_ tasks: [Task]) -> [Task] {
        tasks.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public static func descendants(of root: UUID, in tasks: [Task]) -> [Task] {
        let children = Dictionary(grouping: ordered(tasks), by: \.parentId)
        var result: [Task] = []
        var seen: Set<UUID> = [root]
        var pending = Array((children[root] ?? []).reversed())
        while let task = pending.popLast() {
            guard seen.insert(task.id).inserted else { continue }
            result.append(task)
            pending.append(contentsOf: (children[task.id] ?? []).reversed())
        }
        return result
    }
}
