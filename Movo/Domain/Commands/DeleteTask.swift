import Foundation

/// 整棵任务树移入最近删除；不删除行动记录与变更历史。
public struct DeleteTask: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .deleteTask
    public var entityID: UUID
    public let entityType: EntityType = .task
    public var baseRevision: Int
    public var expectedTaskIDs: Set<UUID>?

    public init(operationID: UUID = UUID(), taskID: UUID, baseRevision: Int = 0,
                expectedTaskIDs: Set<UUID>? = nil) {
        self.operationID = operationID; self.entityID = taskID
        self.baseRevision = baseRevision; self.expectedTaskIDs = expectedTaskIDs
    }

    public static func targets(taskID: UUID, repository: DomainRepository) async -> [(EntityType, UUID)] {
        let all = await repository.allTasks()
        let ids = [taskID] + TaskHierarchy.descendants(of: taskID, in: all).map(\.id)
        let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        var targets: [(EntityType, UUID)] = []
        for id in ids where !deleted.contains(id) {
            targets.append((.task, id))
            if let rule = await repository.rule(forTask: id), !deleted.contains(rule.id) {
                targets.append((.rule, rule.id))
            }
            targets.append(contentsOf: await repository.occurrences(taskID: id)
                .filter { !deleted.contains($0.id) }.map { (.occurrence, $0.id) })
        }
        return targets
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let task = await context.repository.task(entityID) else {
            throw MovoError.notFound(entityType: .task, id: entityID)
        }
        try await StructurePolicy.requireWritable(id: entityID, type: .task, repository: context.repository)
        try context.assertDeclaredRevision(actual: task.revision, entityID: entityID)
        let targets = await Self.targets(taskID: entityID, repository: context.repository)
        let ids = Set(targets.filter { $0.0 == .task }.map(\.1))
        if let expectedTaskIDs, expectedTaskIDs != ids {
            throw MovoError.invalidStructure(reason: "子任务发生了变化，请重新查看删除范围。")
        }
        for (type, id) in targets {
            _ = try await context.write(Tombstone(
                entityType: type, entityId: id, deletedAt: context.now,
                deviceId: context.deviceId,
                retentionDays: context.defaults.lifecycle.tombstoneRetentionDays), old: nil)
        }
        context.setUserMessage("已将「\(task.title)」及 \(ids.count - 1) 项子任务移到最近删除")
        return CommandResult(operationID: operationID, entityID: entityID,
                             changedFields: context.changedFields, userMessage: context.userMessage,
                             newRevision: task.revision)
    }
}
