//
//  ExecutionPolicy.swift
//  Intelligence/Planning
//
//  6.7 执行策略（唯一裁决点）。
//  原则：明确完成的动作不留确认；不确定的一律进收件箱；高影响动作必须确认。
//

import Foundation

// MARK: - 裁决输入

/// 一条提议的裁决依据。全部为可判定的本地事实，不含正文。
public struct ExecutionContext: Sendable, Hashable {

    /// 是否包含依赖（先后顺序）建议
    public var hasDependencySuggestion: Bool
    /// 本地检索到的候选对象数量（0 = 未命中，1 = 唯一匹配，>1 = 歧义）
    public var candidateMatchCount: Int
    /// 是否改动硬截止
    public var changesHardDeadline: Bool
    /// 结果记录缺少单位
    public var measurementUnitMissing: Bool
    /// 结果记录单位与指标不一致
    public var measurementUnitMismatched: Bool

    public init(hasDependencySuggestion: Bool = false,
                candidateMatchCount: Int = 1,
                changesHardDeadline: Bool = false,
                measurementUnitMissing: Bool = false,
                measurementUnitMismatched: Bool = false) {
        self.hasDependencySuggestion = hasDependencySuggestion
        self.candidateMatchCount = candidateMatchCount
        self.changesHardDeadline = changesHardDeadline
        self.measurementUnitMissing = measurementUnitMissing
        self.measurementUnitMismatched = measurementUnitMismatched
    }
}

// MARK: - 裁决结果

public enum ExecutionDecision: String, Sendable, Hashable, CaseIterable {
    /// 直接执行（记 event，标「自动执行，可撤销」）
    case auto
    /// 批量改动：先给影响预览，再一次确认
    case bulkPreview
    /// 需要用户确认
    case confirm
    /// 归属不确定：作为建议进收件箱
    case inboxSuggestion
    /// 无法成立：需要补充信息
    case reject

    public var displayName: String {
        switch self {
        case .auto: "自动执行"
        case .bulkPreview: "批量预览"
        case .confirm: "需要确认"
        case .inboxSuggestion: "收件箱建议"
        case .reject: "需要补充信息"
        }
    }

    /// 是否必须经用户操作才能落地
    public var requiresUserAction: Bool {
        switch self {
        case .auto: false
        case .bulkPreview, .confirm, .inboxSuggestion, .reject: true
        }
    }
}

// MARK: - 策略

public enum ExecutionPolicy {

    // MARK: 裁决

    /// 单条提议的裁决（纯函数）。
    public static func decide(for action: AIAction, context: ExecutionContext) -> ExecutionDecision {
        // 高影响动作（依赖建议 / 频率调整）一律确认
        if action.requiresConfirmationByRule { return .confirm }
        // 硬截止改动走确认预览（PRD 10.2）
        if context.changesHardDeadline { return .confirm }
        if context.hasDependencySuggestion { return .confirm }
        // 结果记录的单位缺失/不一致 → 需要确认，不自行猜测
        if context.measurementUnitMissing || context.measurementUnitMismatched { return .confirm }

        switch action {
        case .needsClarification:
            return .inboxSuggestion

        case .completeTask, .updateTask, .matchOccurrence, .scheduleExistingTask:
            if context.candidateMatchCount == 0 { return .reject }
            return .confirm

        case .recordMeasurement:
            if context.candidateMatchCount == 0 { return .reject }
            return .confirm

        case .logActivity:
            if context.candidateMatchCount == 0 { return .inboxSuggestion }
            return .confirm

        case .createTask, .saveNote, .createPlan, .setDependency, .setRecurrence:
            return .confirm
        }
    }

    // MARK: 结果文案

    /// 「已整理 4 项 · 可撤销」
    public static func autoResultMessage(appliedCount: Int) -> String {
        appliedCount == 0 ? "没有可整理的内容" : "已整理 \(appliedCount) 项 · 可撤销"
    }

    /// 「已整理 3 项，1 项需要你确认，1 项需要补充信息」
    public static func partialResultMessage(appliedCount: Int, pendingCount: Int,
                                            rejectedCount: Int) -> String {
        var parts: [String] = []
        if appliedCount > 0 { parts.append("已整理 \(appliedCount) 项") }
        if pendingCount > 0 { parts.append("\(pendingCount) 项需要你确认") }
        if rejectedCount > 0 { parts.append("\(rejectedCount) 项需要补充信息") }
        return parts.isEmpty ? "没有可整理的内容" : parts.joined(separator: "，")
    }

    /// 供影响预览与设置页展示的规则说明
    public static func ruleDescription(for action: AIAction) -> String {
        switch action {
        case .createTask: "新建待办：标题必填；没有计划或归属不确定时先保存为独立待办。"
        case .createPlan: "新建计划：先预览名称、类型与待办，一次确认后创建。"
        case .scheduleExistingTask: "安排日期：只改「哪天做」，不动硬截止。"
        case .updateTask: "修改任务：只改原文里明确写出的字段。"
        case .matchOccurrence: "匹配重复项：只有唯一候选才会自动记录。"
        case .completeTask: "标记完成：已完成的任务不会重复完成。"
        case .logActivity: "记录行动：记录投入不等于任务完成。"
        case .recordMeasurement: "记录结果：数值与单位缺一不可，缺测不补 0。"
        case .saveNote: "保存想法：只留想法，不创建任务。"
        case .setRecurrence: "调整频率：只作用于生效日及以后，需要确认。"
        case .setDependency: "先后顺序建议：需要确认后才生效。"
        case .needsClarification: "需要澄清：信息不足时不猜归属。"
        }
    }
}
