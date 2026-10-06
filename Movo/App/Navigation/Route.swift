//
//  Route.swift
//  App/Navigation
//
//  导航路由。与 docs/design/Movo.pen 的画板一一对应（D01–D10、M01–M14）。
//

import Foundation
import MovoKit

/// 顶部入口（Mac 侧边导航 / iPhone 底部标签）
public enum AppSection: String, Hashable, Sendable, CaseIterable, Identifiable {
    case today, inbox, plans, review, search

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: "待办"
        case .inbox: "整理记录"
        case .plans: "计划"
        case .review: "回顾"
        case .search: "搜索"
        }
    }

    public var systemImage: String {
        switch self {
        case .today: "checklist"
        case .inbox: "sparkles.rectangle.stack"
        case .plans: "square.stack.3d.up"
        case .review: "chart.bar.doc.horizontal"
        case .search: "magnifyingglass"
        }
    }

    /// Mac 侧边导航顺序：待办 / 收件箱 / 计划 / 回顾 / 搜索（设置放底部）
    public static let sidebarOrder: [AppSection] = [.today, .inbox, .plans, .review, .search]
    /// iPhone 底部标签：待办 / 计划 / 回顾（收件箱与搜索从顶部进入）
    public static let phoneOrder: [AppSection] = [.today, .plans, .review]
}

/// 全部可导航目的地
public enum Route: Hashable, Identifiable, Sendable {
    // 顶部入口
    case section(AppSection)
    case settings

    // 计划
    case planDetail(UUID)
    case newPlan
    case editPlan(UUID)
    case planHistory(UUID)
    case snapshot(planID: UUID, asOf: DateOnly)
    case recurrenceEditor(taskID: UUID)
    case recurrencePreview(taskID: UUID)

    // 任务
    case taskDetail(UUID)
    case newTask(planID: UUID?, parentID: UUID?, scheduledToday: Bool)
    case moveTask(UUID)

    // 结果与记录
    case metricHistory(metricID: UUID)
    case logMeasurement(metricID: UUID)

    // 批量影响预览（D05-BulkPreview）
    case bulkPreview(title: String, entityIDs: [UUID])

    // 采集管线（D04 / M04 系列）
    case quickCapture
    case recording
    case transcript(captureID: UUID)
    case processing(captureID: UUID)
    case captureFailed(captureID: UUID)
    case captureResult(captureID: UUID)
    case localOnlyCapture

    // 设置子页（M13 系列 / D01-Settings）
    case settingsSection(RecoveryAction.SettingsSection)
    case recentlyDeleted
    case exportPreview(planID: UUID?)
    case importPlan
    case conflicts

    public var id: String {
        switch self {
        case .section(let s): "section-\(s.rawValue)"
        case .settings: "settings"
        case .planDetail(let id): "plan-\(id.uuidString)"
        case .newPlan: "new-plan"
        case .editPlan(let id): "edit-plan-\(id.uuidString)"
        case .planHistory(let id): "plan-history-\(id.uuidString)"
        case .snapshot(let planID, let asOf): "snapshot-\(planID.uuidString)-\(asOf.iso8601DateString)"
        case .recurrenceEditor(let id): "recurrence-\(id.uuidString)"
        case .recurrencePreview(let id): "recurrence-preview-\(id.uuidString)"
        case .taskDetail(let id): "task-\(id.uuidString)"
        case .newTask: "new-task"
        case .moveTask(let id): "move-task-\(id.uuidString)"
        case .metricHistory(let id): "metric-history-\(id.uuidString)"
        case .logMeasurement(let id): "log-measurement-\(id.uuidString)"
        case .bulkPreview(let title, let ids): "bulk-\(title.hashValue)-\(ids.count)"
        case .quickCapture: "quick-capture"
        case .recording: "recording"
        case .transcript(let id): "transcript-\(id.uuidString)"
        case .processing(let id): "processing-\(id.uuidString)"
        case .captureFailed(let id): "capture-failed-\(id.uuidString)"
        case .captureResult(let id): "capture-result-\(id.uuidString)"
        case .localOnlyCapture: "local-only-capture"
        case .settingsSection(let s): "settings-\(s.rawValue)"
        case .recentlyDeleted: "recently-deleted"
        case .exportPreview(let id): "export-\(id?.uuidString ?? "all")"
        case .importPlan: "import-plan"
        case .conflicts: "conflicts"
        }
    }

    /// 画板名（便于对照设计稿与截图验收）
    public var artboardName: String {
        switch self {
        case .section(.today): "D01 / M01 待办"
        case .section(.inbox): "D05 / M05 AI 整理记录"
        case .section(.plans): "D06 / M07 我的计划"
        case .section(.review): "D08 / M10 回顾"
        case .section(.search): "D10 / M06-Search 搜索"
        case .settings: "M13 设置"
        case .planDetail: "D02 / M11 计划与执行树"
        case .newPlan: "M08-NewPlan 新建计划"
        case .editPlan: "M08-EditPlan 编辑计划"
        case .planHistory: "M11-History 计划历史"
        case .snapshot: "D09-Snapshot / M11-Snapshot 只读快照"
        case .recurrenceEditor: "M09-Frequency 编辑重复频率"
        case .recurrencePreview: "M09-FrequencyPreview 频率影响预览"
        case .taskDetail: "D07 / M12 任务详情"
        case .newTask: "D04-Manual / M04-Manual 新建待办"
        case .moveTask: "移动待办"
        case .metricHistory: "M09-ResultHistory 结果历史"
        case .logMeasurement: "M09-Result 补记结果"
        case .bulkPreview: "D05-BulkPreview 批量影响预览"
        case .quickCapture: "D04 快速输入浮层"
        case .recording: "M04-Recording 语音录入"
        case .transcript: "M04-Transcript 可编辑转写"
        case .processing: "M04-Processing 整理中"
        case .captureFailed: "M04-Failed 原文已保留"
        case .captureResult: "M02 系列 AI 整理结果"
        case .localOnlyCapture: "M04-LocalOnly 敏感计划本地录入"
        case .settingsSection: "D01-Settings / M13 分区"
        case .recentlyDeleted: "M13-Recovery 最近删除"
        case .exportPreview: "M13-Export 导出预览"
        case .importPlan: "M13-Import 导入 Movo 文件"
        case .conflicts: "M13 同步冲突（02 States B 第 6 条）"
        }
    }
}
