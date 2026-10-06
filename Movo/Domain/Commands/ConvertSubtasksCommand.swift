//
//  ConvertSubtasksCommand.swift
//  Domain/Commands
//
//  把待办下的普通子任务转成步骤，用于随后把这个待办设为重复行动。
//  · 未完成的子孙原地转成步骤（保留 id、标题与层级），开始 / 结束时间和前置关系丢弃。
//  · 已完成、已取消的子孙移到最近删除（保留期内可恢复）。
//  · 别的待办对这些子任务的前置关系一并解除。
//  · 已完成或已取消的子任务下还有未完成的子任务时拒绝，要求先处理。
//  通常与 `CreateRecurrence` 放进同一个批次，整批可撤销。
//

import Foundation

/// 转换前的预览：界面用它列出影响，命令用它决定做什么。
public struct SubtaskConversionPreview: Sendable, Equatable {
    public var convertIDs: [UUID] = []
    public var convertTitles: [String] = []
    public var discardIDs: [UUID] = []
    public var discardTitles: [String] = []
    /// 转成步骤后会丢掉时间或前置关系的子任务数
    public var droppedFieldCount = 0
    /// 会被解除前置关系的其它待办
    public var unlinkedDependentIDs: [UUID] = []
    public var unlinkedDependentTitles: [String] = []
    /// 非空时不能转换
    public var blockers: [String] = []

    public var hasSubtasks: Bool { !convertIDs.isEmpty || !discardIDs.isEmpty }
}

public struct ConvertSubtasksToSteps: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .convertSubtasksToSteps
    public var taskID: UUID
    public var entityID: UUID { taskID }
    public let entityType: EntityType = .task
    public var baseRevision: Int

    public init(operationID: UUID = UUID(), taskID: UUID, baseRevision: Int = 0) {
        self.operationID = operationID; self.taskID = taskID; self.baseRevision = baseRevision
    }

    public static func analyze(taskID: UUID, repository: DomainRepository) async -> SubtaskConversionPreview {
        var preview = SubtaskConversionPreview()
        let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        let all = await repository.allTasks().filter { !deleted.contains($0.id) }
        let descendants = TaskHierarchy.descendants(of: taskID, in: all)

        let open = descendants.filter { $0.status.isOpen && !$0.isTemplate }
        let closed = descendants.filter { !$0.status.isOpen }
        for node in closed {
            let below = TaskHierarchy.descendants(of: node.id, in: descendants)
            if below.contains(where: { $0.status.isOpen }) {
                preview.blockers.append("「\(node.title)」\(node.status.displayName)，但它下面还有未完成的子任务，请先处理。")
            }
        }
        preview.convertIDs = open.map(\.id)
        preview.convertTitles = open.map(\.title)
        preview.discardIDs = closed.map(\.id)
        preview.discardTitles = closed.map(\.title)
        preview.droppedFieldCount = open.filter {
            $0.startAt != nil || $0.endAt != nil || !$0.dependencyIDs.isEmpty
        }.count

        let affected = Set(descendants.map(\.id))
        for task in all where !affected.contains(task.id)
            && task.dependencyIDs.contains(where: { affected.contains($0) }) {
            preview.unlinkedDependentIDs.append(task.id)
            preview.unlinkedDependentTitles.append(task.title)
        }
        return preview
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let task = await context.repository.task(taskID) else {
            throw MovoError.notFound(entityType: .task, id: taskID)
        }
        try await StructurePolicy.requireWritable(id: taskID, type: .task, repository: context.repository)
        try context.assertDeclaredRevision(actual: task.revision, entityID: taskID)
        guard !task.isTemplate, task.parentId == nil else {
            throw MovoError.invalidStructure(reason: "只有顶层的普通待办可以把子任务转成步骤。")
        }
        let preview = await Self.analyze(taskID: taskID, repository: context.repository)
        if let blocker = preview.blockers.first {
            throw MovoError.invalidStructure(reason: blocker)
        }
        guard preview.hasSubtasks else {
            throw MovoError.invalidStructure(reason: "「\(task.title)」下面没有子任务。")
        }

        let gone = Set(preview.convertIDs + preview.discardIDs)
        for id in preview.unlinkedDependentIDs {
            guard let old = await context.repository.task(id) else { continue }
            var updated = old
            updated.dependencyIDs = old.dependencyIDs.filter { !gone.contains($0) }
            updated.updatedAt = context.now
            _ = try await context.write(updated, old: old)
            context.addReleasedDependencies(old.dependencyIDs.count - updated.dependencyIDs.count)
        }
        for id in preview.discardIDs {
            _ = try await context.write(Tombstone(
                entityType: .task, entityId: id, deletedAt: context.now, deviceId: context.deviceId,
                retentionDays: context.defaults.lifecycle.tombstoneRetentionDays), old: nil)
        }
        // 整棵树按已知合法的结构直接改写；结构校验在随后的 CreateRecurrence 里对整棵树统一进行。
        for id in preview.convertIDs {
            guard let old = await context.repository.task(id) else { continue }
            var step = old
            step.isTemplate = true
            step.status = .todo
            step.startAt = nil
            step.endAt = nil
            step.dependencyIDs = []
            step.updatedAt = context.now
            _ = try await context.write(step, old: old)
        }

        context.setUserMessage("已把「\(task.title)」下的 \(preview.convertIDs.count) 个子任务转成步骤"
                               + (preview.discardIDs.isEmpty ? "" : "，\(preview.discardIDs.count) 个已结束的子任务移到最近删除"))
        return CommandResult(operationID: operationID, entityID: taskID,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: task.revision)
    }
}
