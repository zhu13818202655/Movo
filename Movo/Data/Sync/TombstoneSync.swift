//
//  TombstoneSync.swift
//  Data/Sync
//
//  9.5 Tombstone 与恢复（AC11 / AC17）。
//
//  · 删除 = 写删除事件 + Tombstone（purgeAfter = +30 天）；30 天内"最近删除"可完整恢复（含后代）。
//  · 恢复不补造历史行动。
//  · 到期永久删除时级联清理事件、索引、CK 记录。
//  · 旧设备离线期对已删对象的编辑不能复活对象（9.4 第 1 步 + 本文件的复活防护）。
//

import Foundation

// MARK: - 本地级联删除

public enum SyncLocalStore {

    /// 计划 → 计划及其全部后代；其它实体 → 自身。
    public static func cascadeIDs(type: EntityType, id: UUID,
                                 repository: any DomainRepository) async -> [UUID] {
        if type == .plan {
            return await DeletePlan.cascadeIDs(planID: id, repository: repository)
        }
        return [id]
    }

    /// 按类型删除单条实体（不写墓碑，由调用方决定是否写）。
    public static func delete(type: EntityType, id: UUID,
                              repository: any DomainRepository) async {
        do {
            switch type {
            case .plan: try await repository.deletePlan(id)
            case .stage: try await repository.deleteStage(id)
            case .metric: try await repository.deleteMetric(id)
            case .task: try await repository.deleteTask(id)
            case .rule: try await repository.deleteRule(id)
            case .occurrence: try await repository.deleteOccurrence(id)
            case .activity: try await repository.deleteActivity(id)
            case .measurement: try await repository.deleteMeasurement(id)
            case .note: try await repository.deleteNote(id)
            case .capture: try await repository.deleteCapture(id)
            case .tombstone: try await repository.deleteTombstone(id)
            // 建议 / 回顾补记 / 冲突没有删除 API：保持追加-only 语义
            case .suggestion, .reviewNote, .conflict, .batch, .operation, .event:
                break
            }
        } catch {
            // 已经不存在视为删除成功（幂等）
        }
        try? await repository.removeSearchDocuments(entityID: id)
    }

    /// 级联删除一个实体的全部后代（含实体自身）
    public static func cascadeDelete(type: EntityType, id: UUID,
                                     repository: any DomainRepository) async -> [UUID] {
        let targets = await cascadeIDs(type: type, id: id, repository: repository)
        for target in targets {
            // 只有根实体的类型已知；后代按类型逐个删除
            if target == id {
                await delete(type: type, id: target, repository: repository)
            } else {
                await deleteUnknown(id: target, repository: repository)
            }
        }
        return targets
    }

    /// 后代删除：类型未知时按已知仓储 API 依次尝试（删除是不存在的对象则无副作用）
    static func deleteUnknown(id: UUID, repository: any DomainRepository) async {
        try? await repository.deleteStage(id)
        try? await repository.deleteMetric(id)
        try? await repository.deleteTask(id)
        try? await repository.deleteRule(id)
        try? await repository.deleteOccurrence(id)
        try? await repository.deleteActivity(id)
        try? await repository.deleteMeasurement(id)
        try? await repository.deleteNote(id)
        try? await repository.removeSearchDocuments(entityID: id)
    }
}

// MARK: - 复活防护（AC11）

public enum RevivalGuard {

    /// 结论：已删对象上的旧编辑必须被丢弃，不能让对象复活。
    public enum Decision: String, Sendable, Hashable {
        /// 删除生效，本地对象随之删除
        case deletionWins
        /// 删除生效，且本地存在更新的编辑 → 该编辑被丢弃（要提示用户）
        case deletionWinsDiscardingLocalEdits
        /// 本地已经删除了这个对象：不需要再动
        case alreadyDeleted
        /// 两侧都没删
        case noDeletion
    }

    public static func decide(localDeletedAt: Date?, remoteDeletedAt: Date?,
                              localUpdatedAt: Date) -> Decision {
        switch (localDeletedAt, remoteDeletedAt) {
        case (nil, nil):
            return .noDeletion
        case (.some, nil):
            return .alreadyDeleted
        case (.some, .some):
            // 两侧都删：本地已是删除态
            return .alreadyDeleted
        case (nil, .some(let remoteDeleted)):
            // 本地在删除之后还改过 → 编辑被丢弃（不复活对象）
            return localUpdatedAt > remoteDeleted ? .deletionWinsDiscardingLocalEdits : .deletionWins
        }
    }
}

// MARK: - 到期清理（AC17）

public enum TombstoneSync {

    public struct PurgeOutcome: Sendable, Hashable {
        /// 本地已清理的实体 ID
        public var purgedIDs: [UUID]
        /// 需要远端一并清理的实体 ID
        public var remoteIDs: [UUID]
        public var summaryText: String
    }

    /// 找出已过 30 天的墓碑，做本地级联清理；返回需要远端清理的 ID 列表。
    /// 调用方负责把 `remoteIDs` 交给后端 purge（并容忍离线失败）。
    public static func purgeExpired(tombstones: [Tombstone],
                                    repository: any DomainRepository,
                                    now: Date) async -> PurgeOutcome {
        var purged: [UUID] = []
        var remote: [UUID] = []

        for tombstone in tombstones where tombstone.isActive && now >= tombstone.purgeAfter {
            let targets: [UUID]
            if tombstone.entityType == .plan {
                targets = await DeletePlan.cascadeIDs(planID: tombstone.entityId, repository: repository)
            } else {
                targets = [tombstone.entityId]
            }
            for id in targets {
                if id == tombstone.entityId {
                    await SyncLocalStore.delete(type: tombstone.entityType, id: id,
                                                repository: repository)
                } else {
                    await SyncLocalStore.deleteUnknown(id: id, repository: repository)
                }
            }
            // 墓碑自身的记录与事件一并清掉
            await SyncLocalStore.delete(type: .tombstone, id: tombstone.id, repository: repository)
            purged.append(contentsOf: targets)
            purged.append(tombstone.id)
            remote.append(contentsOf: targets)
            remote.append(tombstone.id)
        }

        let summary = purged.isEmpty
            ? "没有到期需要清理的内容。"
            : "已永久清理 \(purged.count) 项，不会补造任何历史记录。"
        return PurgeOutcome(purgedIDs: purged, remoteIDs: remote, summaryText: summary)
    }

    /// 恢复：写"恢复事件"并复活实体（不补造历史行动）。
    /// 这里只做级联判定与文案，实际写入走 `RestoreEntity` 命令。
    public static func restorableTombstones(_ tombstones: [Tombstone], now: Date) -> [Tombstone] {
        tombstones.filter { $0.isRecoverable(at: now) }
    }
}
