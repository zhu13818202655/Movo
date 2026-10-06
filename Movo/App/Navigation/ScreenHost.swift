//
//  ScreenHost.swift
//  App/Navigation
//
//  Route → 页面。所有目的地与 docs/design/Movo.pen 的画板一一对应。
//

import SwiftUI
import MovoKit

public struct ScreenHost: View {
    public let route: Route

    public init(route: Route) { self.route = route }

    public var body: some View {
        switch route {
        // 顶部入口
        case .section(.today): TodayScreen()
        case .section(.inbox): OrganizeHistoryScreen()
        case .section(.plans): PlansScreen()
        case .section(.review): ReviewScreen()
        case .section(.search): SearchScreen()
        case .settings: SettingsScreen()

        // 计划
        case .planDetail(let planID): PlanDetailScreen(planID: planID)
        case .newPlan: PlanEditScreen(planID: nil)
        case .editPlan(let planID): PlanEditScreen(planID: planID)
        case .planHistory(let planID): PlanHistoryScreen(planID: planID)
        case .snapshot(let planID, let asOf): SnapshotScreen(planID: planID, asOf: asOf)
        case .recurrenceEditor(let taskID): RecurrenceEditorScreen(taskID: taskID)
        case .recurrencePreview(let taskID): RecurrencePreviewScreen(taskID: taskID)

        // 任务
        case .taskDetail(let taskID): TaskDetailScreen(taskID: taskID)
        case .newTask(let planID, let parentID, let scheduledToday):
            NewTaskSheet(planID: planID, parentID: parentID, scheduledToday: scheduledToday)
        case .moveTask(let taskID): MoveTaskSheet(taskID: taskID)

        // 记录与结果
        case .metricHistory(let metricID): MetricHistoryScreen(metricID: metricID)
        case .logMeasurement(let metricID): LogMeasurementScreen(metricID: metricID)
        case .bulkPreview(let title, let entityIDs):
            BulkPreviewScreen(title: title, entityIDs: entityIDs)

        // 采集管线
        case .quickCapture: QuickCaptureSheet(mode: .text)
        case .recording: RecordingSheet()
        case .transcript(let captureID): TranscriptSheet(captureID: captureID)
        case .processing(let captureID): ProcessingScreen(captureID: captureID)
        case .captureFailed(let captureID): CaptureFailedScreen(captureID: captureID)
        case .captureResult(let captureID): CaptureResultScreen(captureID: captureID)
        case .localOnlyCapture: LocalOnlyCaptureSheet()

        // 设置与管理
        case .settingsSection(let section): SettingsSectionScreen(section: section)
        case .recentlyDeleted: RecentlyDeletedScreen()
        case .exportPreview(let planID): ExportPreviewScreen(planID: planID)
        case .importPlan: ImportPlanScreen()
        case .conflicts: ConflictResolutionScreen()
        }
    }
}
