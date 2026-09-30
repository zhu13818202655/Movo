//
//  DependencyCommands.swift
//  Domain/Commands
//
//  AddDependency / RemoveDependency（C9：同计划内、不得自引用、不得成环）
//  AI 的先后顺序建议一律 needs_confirmation=true，采纳后写入（REQ 09）。
//

import Foundation

public struct AddDependency: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .addDependency
    public var taskID: UUID
    public var entityID: UUID { taskID }
    public let entityType: EntityType = .task
    public var baseRevision: Int
    /// 前置任务
    public var dependsOnID: UUID

    public init(operationID: UUID = UUID(), taskID: UUID, dependsOnID: UUID, baseRevision: Int = 0) {
        self.operationID = operationID; self.taskID = taskID; self.dependsOnID = dependsOnID
        self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        try await StructurePolicy.requireWritable(id: taskID, type: .task, repository: context.repository)
        try context.assertDeclaredRevision(actual: old.revision, entityID: taskID)
        guard !old.dependencyIDs.contains(dependsOnID) else {
            return CommandResult(operationID: operationID, entityID: taskID,
                                 userMessage: "这项前置已经存在。", newRevision: old.revision)
        }
        try await StructurePolicy.validateDependency(taskID: taskID, dependsOn: dependsOnID,
                                                     repository: context.repository)

        var updated = old
        updated.dependencyIDs = old.dependencyIDs + [dependsOnID]
        updated.updatedAt = context.now
        let saved = try await context.write(updated, old: old)

        let dependency = await context.repository.task(dependsOnID)
        context.setUserMessage("已添加前置「\(dependency?.title ?? "")」")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct RemoveDependency: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .removeDependency
    public var taskID: UUID
    public var entityID: UUID { taskID }
    public let entityType: EntityType = .task
    public var baseRevision: Int
    public var dependsOnID: UUID

    public init(operationID: UUID = UUID(), taskID: UUID, dependsOnID: UUID, baseRevision: Int = 0) {
        self.operationID = operationID; self.taskID = taskID; self.dependsOnID = dependsOnID
        self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        try await StructurePolicy.requireWritable(id: taskID, type: .task, repository: context.repository)
        try context.assertDeclaredRevision(actual: old.revision, entityID: taskID)

        var updated = old
        updated.dependencyIDs = old.dependencyIDs.filter { $0 != dependsOnID }
        updated.updatedAt = context.now
        let saved = try await context.write(updated, old: old)
        context.setUserMessage("已解除这项前置。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}
