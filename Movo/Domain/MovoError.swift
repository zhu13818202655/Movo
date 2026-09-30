//
//  MovoError.swift
//  Domain
//
//  4.5 错误模型。每个 case 绑定固定文案与恢复动作；
//  UI 层用 ErrorBanner 统一渲染，禁止裸错误。
//

import Foundation

/// 用户可执行的恢复动作。UI 依据它渲染按钮，保证"无恢复入口的错误态"不存在。
public enum RecoveryAction: Hashable, Sendable, Codable {
    case retry
    case editText
    case openSettings(section: SettingsSection)
    case refresh
    case viewConflicts
    case viewInbox
    case dismiss
    case restoreFromRecentlyDeleted
    case choosePlan

    public var label: String {
        switch self {
        case .retry: "重试"
        case .editText: "改成文字输入"
        case .openSettings(let s): s == .ai ? "去填写 Key" : "打开设置"
        case .refresh: "刷新后重试"
        case .viewConflicts: "查看冲突"
        case .viewInbox: "去收件箱"
        case .dismiss: "知道了"
        case .restoreFromRecentlyDeleted: "去最近删除"
        case .choosePlan: "选择计划"
        }
    }

    public enum SettingsSection: String, Hashable, Sendable, Codable {
        case ai, privacy, sync, notifications, export, manage
        public var displayName: String {
            switch self {
            case .ai: "AI 与数据"
            case .privacy: "计划隐私"
            case .sync: "同步"
            case .notifications: "通知"
            case .export: "导出"
            case .manage: "管理"
            }
        }
    }
}

public enum RejectReason: Hashable, Sendable, Codable, CustomStringConvertible {
    case spanOutOfRange
    case actionNotInEnum
    case mismatchedDataBlock
    case emptyTitle
    case titleTooLong
    case unknownReference(String)
    case requiresCandidateTask
    case completedCannotComplete
    case templateNeedsOccurrence
    case unparsableDate
    case relativeDateMismatch
    case pastScheduledDate
    case deadlineNeedsTimeAndZone
    case deadlineNotAllowed
    case incompleteRecurrence
    case invalidMeasurementValue
    case unitMismatch
    case planNotCloudAIEnabled
    case planArchived
    case duplicateInBatch
    case inputTooLong
    case dependencyNeedsConfirmation
    case dependencyInvalid
    case structureViolation(String)

    public var description: String {
        switch self {
        case .spanOutOfRange: "原文片段定位超出范围"
        case .actionNotInEnum: "动作不在支持范围内"
        case .mismatchedDataBlock: "动作与数据块不匹配"
        case .emptyTitle: "标题为空"
        case .titleTooLong: "标题超过 200 字"
        case .unknownReference(let s): "引用了本次上下文中不存在的对象（\(s)）"
        case .requiresCandidateTask: "缺少要修改的任务"
        case .completedCannotComplete: "该任务已完成，不能重复完成"
        case .templateNeedsOccurrence: "重复行动请选择具体某一次"
        case .unparsableDate: "日期无法解析"
        case .relativeDateMismatch: "日期与解析说明不一致"
        case .pastScheduledDate: "安排日期早于今天"
        case .deadlineNeedsTimeAndZone: "硬截止必须包含时刻和时区"
        case .deadlineNotAllowed: "该处不允许写入硬截止"
        case .incompleteRecurrence: "重复规则字段不完整"
        case .invalidMeasurementValue: "数值无效"
        case .unitMismatch: "单位与指标不一致"
        case .planNotCloudAIEnabled: "该计划未允许云 AI 处理"
        case .planArchived: "目标计划已归档"
        case .duplicateInBatch: "同一批中有重复项"
        case .inputTooLong: "输入过长，已截断"
        case .dependencyNeedsConfirmation: "依赖建议需要你确认"
        case .dependencyInvalid: "依赖不合法（跨计划或成环）"
        case .structureViolation(let s): "结构不合法：\(s)"
        }
    }
}

public enum MovoError: LocalizedError, Hashable, Sendable {
    /// C1–C9 约束
    case invalidStructure(reason: String)
    /// baseRevision 不匹配 → UI 刷新重试
    case versionConflict(entityID: UUID?)
    case notFound(entityType: EntityType, id: UUID?)
    /// mic / speech / notification
    case permissionDenied(kind: PermissionKind)
    /// 权限拒绝 / 不支持 / 资源未装
    case speechUnavailable(reason: SpeechFailReason)
    /// 无 Key → 手动模式提示
    case noKey(vendor: AIVendor)
    /// 网络 / 超时 / 429 / 401 / 解析失败
    case aiFailed(stage: AIStage, cause: String)
    /// 校验未过项 → 收件箱
    case aiRejected([RejectReason])
    case syncFailed(reason: String, retryAt: Date?)
    case conflictPending(count: Int)
    case exportUnavailable(reason: String)
    case cancelled

    public var errorDescription: String? { title }

    public var title: String {
        switch self {
        case .invalidStructure: "这份内容还不能保存"
        case .versionConflict: "内容已在别处被修改"
        case .notFound: "找不到这条内容"
        case .permissionDenied(let k): "没有\(k.displayName)权限"
        case .speechUnavailable: "暂时无法使用语音"
        case .noKey(let v): "还没有配置 \(v.displayName) 的 Key"
        case .aiFailed(let stage, _): stage.displayName
        case .aiRejected: "部分内容需要你确认"
        case .syncFailed: "同步没有完成"
        case .conflictPending(let n): "有 \(n) 项需要你选择保留哪一份"
        case .exportUnavailable: "暂时无法导出"
        case .cancelled: "已取消"
        }
    }

    /// 用户可读的解释（不含技术细节、不含正文）
    public var message: String {
        switch self {
        case .invalidStructure(let reason): reason
        case .versionConflict: "这里的内容刚刚被更新过。刷新后你的修改会基于最新版本。"
        case .notFound(let t, _): "这条\(t.displayName)可能已经被删除。"
        case .permissionDenied(let k):
            k == .microphone ? "可以在系统设置里允许麦克风，也可以直接用文字输入。"
                             : "可以在系统设置里打开权限，也可以直接用文字输入。"
        case .speechUnavailable(let r): "\(r.displayName)。可以先改成文字输入，原文不会丢。"
        case .noKey(let v): "配置 \(v.displayName) 的 Key 后可以使用云整理；现在也可以手动整理。"
        case .aiFailed(let stage, let cause):
            switch stage {
            case .auth: "Key 可能不正确或已失效。检查后可以重试，也可以先手动整理。"
            case .rateLimited: "稍等一下再试，原文已经保存。"
            case .timeout: "网络较慢，原文已经保存，可以重试或手动整理。"
            case .network: "当前网络不可用，原文已经保存。"
            case .parse: "返回内容无法解析，原文已经保存，可以重试。"
            case .unknown: "原文已经保存。\(cause)"
            }
        case .aiRejected(let reasons):
            reasons.prefix(2).map(\.description).joined(separator: "；")
        case .syncFailed(let reason, _): reason
        case .conflictPending: "两台设备改了同一处内容，两份都保留着，选一个就好。"
        case .exportUnavailable(let reason): reason
        case .cancelled: "本次操作已取消，原文与已有内容不受影响。"
        }
    }

    /// UI 不允许出现无恢复入口的错误态
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .invalidStructure: [.dismiss]
        case .versionConflict: [.refresh]
        case .notFound: [.refresh, .dismiss]
        case .permissionDenied(let k):
            k == .notification ? [.openSettings(section: .notifications), .dismiss]
                               : [.editText, .openSettings(section: .manage)]
        case .speechUnavailable: [.retry, .editText]
        case .noKey: [.openSettings(section: .ai), .editText]
        case .aiFailed(let stage, _):
            stage == .auth ? [.openSettings(section: .ai), .editText] : [.retry, .editText]
        case .aiRejected: [.viewInbox]
        case .syncFailed: [.retry, .openSettings(section: .sync)]
        case .conflictPending: [.viewConflicts]
        case .exportUnavailable: [.dismiss]
        case .cancelled: [.dismiss]
        }
    }

    /// 是否值得自动重试（8.6：仅网络/429/5xx）
    public var isRetryable: Bool {
        switch self {
        case .aiFailed(let stage, _): stage == .network || stage == .rateLimited || stage == .timeout
        case .syncFailed: true
        default: false
        }
    }

    /// 日志用：不含任何正文
    public var logMetadata: [String: String] {
        switch self {
        case .aiFailed(let stage, let cause): ["kind": "aiFailed", "stage": stage.rawValue, "cause": cause]
        case .syncFailed(let reason, _): ["kind": "syncFailed", "reason": reason]
        case .invalidStructure(let reason): ["kind": "invalidStructure", "reason": reason]
        default: ["kind": String(String(describing: self).prefix(while: { $0 != "(" }))]
        }
    }
}
