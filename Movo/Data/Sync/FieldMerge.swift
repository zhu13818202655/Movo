//
//  FieldMerge.swift
//  Data/Sync
//
//  9.4 事件式三方合并算法（fieldMerge）。纯函数，可脱离网络与 CloudKit 单测。
//
//  前提：两端共享"上次共同同步点"的历史（共享状态 S_base）；
//  本地未同步变更 = 本地 synced=false 的 ChangeEvent 集 E_l；
//  远端新变更 = 远端事件中 rev > 本地已知 rev 的集 E_r。
//
//  规则：
//   1. 删除判定：任一侧存在删除事件（deletedAt）且对侧无更新的非删除事件 → 实体删除（tombstone）。
//      旧设备后补的编辑：删除胜出；编辑被丢弃（AC11）。
//   2. 逐字段：与 base 相同的一侧视为"没动过"，取另一侧；两侧都动且值不同 → 冲突，
//      其余字段照常合并，实体状态 = 合并结果 + 该字段挂起冲突。
//   3. 决议：用户选择 local / remote / custom → 写决议事件（新 rev），两端再同步。
//   4. 幂等：所有步骤以 eventID / operationID 去重；重复推送无副作用。
//   5. 完成后：本地应用的事件置 synced=true，更新 lastSyncedCursor。
//

import Foundation

// MARK: - 冲突候选

/// 同字段被两侧各改一次且值不同。两个候选都保留（P3 完成条件）。
public struct MergeConflict: Sendable, Hashable, Codable {
    public var field: String
    public var baseValue: JSONValue
    public var localValue: JSONValue
    public var remoteValue: JSONValue
    public var localRev: Int
    public var remoteRev: Int
    public var localDeviceId: String
    public var remoteDeviceId: String
    public var localChangedAt: Date
    public var remoteChangedAt: Date

    public init(field: String, baseValue: JSONValue, localValue: JSONValue, remoteValue: JSONValue,
                localRev: Int, remoteRev: Int, localDeviceId: String, remoteDeviceId: String,
                localChangedAt: Date, remoteChangedAt: Date) {
        self.field = field; self.baseValue = baseValue
        self.localValue = localValue; self.remoteValue = remoteValue
        self.localRev = localRev; self.remoteRev = remoteRev
        self.localDeviceId = localDeviceId; self.remoteDeviceId = remoteDeviceId
        self.localChangedAt = localChangedAt; self.remoteChangedAt = remoteChangedAt
    }

    /// 两侧值都不是空 —— 冲突必须满足"不丢失任一版本"
    public var bothPresent: Bool { !localValue.isNull && !remoteValue.isNull }
}

// MARK: - 删除判定

public enum DeletionOutcome: String, Sendable, Hashable, Codable {
    /// 两侧都没删
    case none
    /// 本地删除胜出（含远端旧编辑被丢弃）
    case localWins
    /// 远端删除胜出（含本地旧编辑被丢弃，AC11）
    case remoteWins
    /// 两侧都删
    case both
}

// MARK: - 合并结果

public struct MergeOutcome: Sendable {
    public var entityType: EntityType
    public var entityID: UUID
    /// 合并后的实体字段（可直接回填 stateJSON）
    public var mergedFields: [String: JSONValue]
    public var conflicts: [MergeConflict]
    public var deletion: DeletionOutcome
    /// 本地旧编辑被丢弃（对象已被对端删除）——AC11 提示用
    public var discardedLocalEdit: Bool
    /// 远端旧编辑被丢弃
    public var discardedRemoteEdit: Bool
    /// 合并后的 revision
    public var resultingRev: Int
    public var updatedAt: Date
    /// 合并结果由哪台设备写入（决定 deviceId 归属）
    public var deviceId: String
    /// 合并结果是否与本地现状不同（决定要不要回写本机）
    public var changedLocally: Bool

    public init(entityType: EntityType, entityID: UUID, mergedFields: [String: JSONValue],
                conflicts: [MergeConflict] = [], deletion: DeletionOutcome = .none,
                discardedLocalEdit: Bool = false, discardedRemoteEdit: Bool = false,
                resultingRev: Int, updatedAt: Date, deviceId: String, changedLocally: Bool) {
        self.entityType = entityType; self.entityID = entityID; self.mergedFields = mergedFields
        self.conflicts = conflicts; self.deletion = deletion
        self.discardedLocalEdit = discardedLocalEdit; self.discardedRemoteEdit = discardedRemoteEdit
        self.resultingRev = resultingRev; self.updatedAt = updatedAt
        self.deviceId = deviceId; self.changedLocally = changedLocally
    }

    public var isDeleted: Bool { deletion != .none }
    public var hasConflicts: Bool { !conflicts.isEmpty }
}

// MARK: - 算法

public enum FieldMerge {

    /// 主入口：以 `base`（上次共同同步点）为基准合并两侧记录。
    /// `base == nil` 时退化为按 fieldRev / rev 判断"谁动过这个字段"。
    public static func merge(local: EntityRecord, remote: EntityRecord,
                             base: EntityRecord? = nil) -> MergeOutcome {
        let entityType = local.entityType
        let now = max(local.updatedAt, remote.updatedAt)

        // ---- 1. 删除判定 ----
        let deletion: DeletionOutcome
        var discardedLocal = false
        var discardedRemote = false

        switch (local.deletedAt, remote.deletedAt) {
        case (nil, nil):
            deletion = .none
        case (let l?, nil):
            // 本地删除胜出；远端在删除之后还改过 → 该编辑被丢弃
            if remote.updatedAt > l { discardedRemote = true }
            deletion = .localWins
        case (nil, let r?):
            // 远端删除胜出；本地旧设备后补的编辑被丢弃（AC11）
            if local.updatedAt > r { discardedLocal = true }
            deletion = .remoteWins
        case (.some, .some):
            // 两侧都删：取远端设备的墓碑（两端再同步时一致）
            deletion = .both
        }

        if deletion != .none {
            // 删除胜出：状态取删除侧/合并侧的空壳，不复活对象
            let winner = (deletion == .localWins) ? local : remote
            let rev = max(local.rev, remote.rev) + (discardedLocal || discardedRemote ? 1 : 0)
            return MergeOutcome(
                entityType: entityType, entityID: local.entityID,
                mergedFields: winner.stateFields,
                conflicts: [], deletion: deletion,
                discardedLocalEdit: discardedLocal, discardedRemoteEdit: discardedRemote,
                resultingRev: rev, updatedAt: now, deviceId: winner.deviceId,
                changedLocally: deletion == .remoteWins)
        }

        // ---- 2. 逐字段合并 ----
        let localFields = local.stateFields
        let remoteFields = remote.stateFields
        let baseFields = base?.stateFields ?? [:]

        var merged: [String: JSONValue] = [:]
        var conflicts: [MergeConflict] = []

        var names = Set(localFields.keys)
        names.formUnion(remoteFields.keys)
        names.formUnion(baseFields.keys)

        for name in names.sorted() {
            let lb = localFields[name] ?? .null
            let rb = remoteFields[name] ?? .null
            let bb = baseFields[name] ?? .null

            if lb == rb {
                // 两侧一致（含都没动）→ 直接取该值
                if !lb.isNull { merged[name] = lb }
                continue
            }

            if base != nil {
                // 与 base 相同的一侧 = 没动过
                if lb == bb {
                    if !rb.isNull { merged[name] = rb }
                    continue
                }
                if rb == bb {
                    if !lb.isNull { merged[name] = lb }
                    continue
                }
            } else {
                // base 未知：用 fieldRev 判断谁动过这个字段
                let localFieldRev = local.fieldRev[name] ?? 0
                let remoteFieldRev = remote.fieldRev[name] ?? 0
                if localFieldRev > remoteFieldRev {
                    if !lb.isNull { merged[name] = lb }
                    continue
                }
                if remoteFieldRev > localFieldRev {
                    if !rb.isNull { merged[name] = rb }
                    continue
                }
                // fieldRev 也无法区分：若一侧为空说明只有一侧写入过
                if bb.isNull {
                    if lb.isNull { merged[name] = rb; continue }
                    if rb.isNull { merged[name] = lb; continue }
                }
            }

            // 两侧都动过且值不同 → 冲突；其余字段照常合并，该字段挂起
            merged[name] = lb
            conflicts.append(MergeConflict(
                field: name, baseValue: bb, localValue: lb, remoteValue: rb,
                localRev: local.rev, remoteRev: remote.rev,
                localDeviceId: local.deviceId, remoteDeviceId: remote.deviceId,
                localChangedAt: local.updatedAt, remoteChangedAt: remote.updatedAt))
        }

        // ---- 3. 结果 ----
        let localFieldsApplied = merged != localFields
        let rev = max(local.rev, remote.rev) + (localFieldsApplied ? 1 : 0)
        let device = localFieldsApplied ? "" : remote.deviceId

        return MergeOutcome(
            entityType: entityType, entityID: local.entityID,
            mergedFields: merged, conflicts: conflicts, deletion: .none,
            discardedLocalEdit: false, discardedRemoteEdit: false,
            resultingRev: rev, updatedAt: now,
            deviceId: device.isEmpty ? local.deviceId : device,
            changedLocally: localFieldsApplied)
    }

    /// 决议落地：把用户选择转成写回目标实体的字段值。
    public static func resolvedValue(for conflict: SyncConflict) -> JSONValue? {
        guard let resolution = conflict.resolution else { return nil }
        switch resolution {
        case .local: return conflict.localValue
        case .remote: return conflict.remoteValue
        case .custom: return conflict.resolvedValue ?? conflict.localValue
        }
    }

    /// 把决议值合并进实体字段（不覆盖其它字段）
    public static func applying(_ value: JSONValue, field: String,
                                to fields: [String: JSONValue]) -> [String: JSONValue] {
        var out = fields
        out[field] = value
        return out
    }

    /// 幂等判据：值相同就不需要再写一次（重复推送无副作用，9.4 第 4 步）
    public static func needsApplication(_ value: JSONValue, field: String,
                                        in fields: [String: JSONValue]) -> Bool {
        fields[field] != value
    }

    /// 把合并后的字段包回 stateJSON；失败返回 nil（调用方跳过该实体，不写坏数据）
    public static func encode(fields: [String: JSONValue]) -> Data? {
        try? JSONEncoder().encode(JSONValue.object(fields))
    }

    /// 取实体盒子的全量字段字典（用于冲突决议的幂等写回）。
    /// 空盒子（编码失败/不参与同步）返回 `[:]`，调用方据此跳过。
    public static func volumeFields(of box: SyncEntityBox) -> [String: JSONValue] {
        guard let data = box.encode(),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let dict) = value else { return [:] }
        return dict
    }
}

// MARK: - 冲突字段的中文名（冲突 UI 与时间线共用）

public enum SyncFieldNaming {
    public static func displayName(for field: String) -> String {
        switch field {
        case "name": "名称"
        case "title": "标题"
        case "goalText": "目标"
        case "criteriaText": "达成条件"
        case "aliases": "别名"
        case "contextPhrases": "常用说法"
        case "excludedTerms": "排除词"
        case "status": "状态"
        case "kind": "类型"
        case "category": "分类"
        case "targetDate": "目标日期"
        case "targetValue": "参考目标值"
        case "targetDirection": "目标方向"
        case "unit": "单位"
        case "scheduledDate": "安排日期"
        case "hardDeadline": "硬截止"
        case "timeHint": "时段"
        case "estimateMinutes": "预计时长"
        case "priority": "优先级"
        case "tags": "标签"
        case "dependencyIDs": "前置任务"
        case "notes": "备注"
        case "text": "内容"
        case "note": "说明"
        case "value": "数值"
        case "measuredAt": "测量日期"
        case "durationMinutes": "时长"
        case "happenedAt": "发生时间"
        case "pattern": "重复方式"
        case "weekdays": "星期"
        case "weeklyCount": "每周次数"
        case "effectiveFrom": "生效日期"
        case "effectiveUntil": "结束日期"
        case "cloudAIEnabled": "允许云端 AI"
        case "syncEnabled": "云同步"
        case "pausedAt": "暂停日期"
        case "resumedAt": "恢复日期"
        case "sortIndex": "排序"
        case "doneAt": "完成时间"
        case "cancelledAt": "取消时间"
        case "achievedAt": "达成时间"
        case "resolution": "处理方式"
        default: field
        }
    }

    /// JSONValue → 可直接展示的文本（冲突双候选用）
    public static func text(for value: JSONValue) -> String {
        switch value {
        case .null: return "（空）"
        case .bool(let b): return b ? "是" : "否"
        case .int(let i): return String(i)
        case .double(let d): return d.rounded() == d ? String(Int(d)) : String(format: "%.2f", d)
        case .string(let s): return s.isEmpty ? "（空）" : s
        case .array(let items):
            if items.isEmpty { return "（空）" }
            return items.map { text(for: $0) }.joined(separator: "、")
        case .object:
            return "（多项内容）"
        }
    }
}
