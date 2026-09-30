//
//  TaskDetailScreen.swift
//  Features/Plans
//
//  D07 Mac 任务详情 / M12 iPhone 任务详情。
//  安排日期与硬截止分别编辑（AC02）；记录、成果与变更历史可展开。
//

import SwiftUI
import MovoKit

public struct TaskDetailScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let taskID: UUID

    @State private var detail: TaskDetail?
    @State private var showHistory = false
    @State private var showRecords = true
    @State private var titleDraft = ""
    @State private var editingTitle = false

    public init(taskID: UUID) { self.taskID = taskID }

    public var body: some View {
        Group {
            if let detail {
                content(detail)
            } else {
                LoadingPlaceholder("正在读取任务…")
            }
        }
        .movoPageBackground()
        .task { await reload() }
    }

    @ViewBuilder
    private func content(_ detail: TaskDetail) -> some View {
        ScreenScroll {
            ScreenChrome("任务详情", subtitle: detail.task.status.displayName) {
                Menu {
                    Button(detail.task.status == .done ? "重新打开" : "标记完成") {
                        _Concurrency.Task { await toggleDone(detail) }
                    }
                    Button("改到明天") { _Concurrency.Task { await reschedule(detail, days: 1) } }
                    Button("安排到今天") { _Concurrency.Task { await schedule(detail, day: env.store.today) } }
                    Button("清除安排日期") { _Concurrency.Task { await clearSchedule(detail) } }
                    Button("设置/修改频率") { router.present(.recurrenceEditor(taskID: taskID)) }
                    if detail.task.hardDeadline != nil {
                        Button("清除硬截止") { _Concurrency.Task { await clearDeadline(detail) } }
                    }
                    Divider()
                    Button("取消这项") { _Concurrency.Task { await cancel(detail) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18)).foregroundStyle(MovoColor.muted)
                        .frame(width: MovoSpace.minTouch, height: MovoSpace.minTouch)
                }
                .menuStyle(.borderlessButton)
                .frame(width: MovoSpace.minTouch)
            }

            // 标题
            SectionBlock("") {
                VStack(alignment: .leading, spacing: MovoSpace.s) {
                    if editingTitle {
                        MovoTextField("", text: $titleDraft)
                        HStack(spacing: MovoSpace.s) {
                            MovoButton("保存") { _Concurrency.Task { await saveTitle(detail) } }
                            MovoButton("取消", kind: .quiet) { editingTitle = false }
                        }
                    } else {
                        Text(detail.task.title)
                            .font(MovoFont.title2).foregroundStyle(MovoColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: MovoSpace.s) {
                            StatusTag(taskStatus: detail.task.status)
                            if !detail.dependency.isReady {
                                MovoTag(detail.dependency.badgeText, systemImage: "arrow.triangle.branch")
                            }
                            if detail.task.isTemplate {
                                MovoTag("重复行动", systemImage: "arrow.triangle.2.circlepath")
                            }
                            MovoButton("改标题", kind: .quiet) {
                                titleDraft = detail.task.title
                                editingTitle = true
                            }
                        }
                    }
                }
                .padding(MovoSpace.s)
            }

            // 所属与安排（安排日期 / 硬截止分开）
            SectionBlock("所属与安排") {
                VStack(alignment: .leading, spacing: 0) {
                    infoRow("计划", value: detail.plan?.name ?? "未归类",
                            actionTitle: detail.plan == nil ? nil : "查看") {
                        if let plan = detail.plan { router.push(.planDetail(plan.id)) }
                    }
                    MovoDivider().padding(.leading, MovoSpace.s)
                    infoRow("阶段", value: detail.stage?.name ?? "未挂阶段", actionTitle: nil, action: {})
                    MovoDivider().padding(.leading, MovoSpace.s)
                    infoRow("安排日期", value: detail.task.scheduledDate?.displayString ?? "未安排",
                            actionTitle: "编辑") { _Concurrency.Task { await editSchedule(detail) } }
                    MovoDivider().padding(.leading, MovoSpace.s)
                    infoRow("硬截止",
                            value: detail.task.hardDeadline?.displayString ?? "未设置硬截止",
                            actionTitle: "编辑") { _Concurrency.Task { await editDeadline(detail) } }
                    if let hint = detail.task.timeHint {
                        MovoDivider().padding(.leading, MovoSpace.s)
                        infoRow("时间提示", value: hint.displayName + "（仅展示，不产生通知）",
                                actionTitle: nil, action: {})
                    }
                    if let estimate = detail.task.estimateMinutes {
                        MovoDivider().padding(.leading, MovoSpace.s)
                        infoRow("预计投入", value: "\(estimate) 分钟", actionTitle: nil, action: {})
                    }
                }
            }

            if !detail.children.isEmpty {
                SectionBlock("子任务", trailing: "\(detail.children.count) 项") {
                    VStack(spacing: 0) {
                        ForEach(detail.children) { child in
                            TaskRow(config: TaskRowConfig(
                                title: child.title, status: child.status,
                                isCompletedToday: child.status == .done),
                                showsCheckbox: false,
                                onTap: { router.push(.taskDetail(child.id)) })
                                .padding(.horizontal, MovoSpace.s)
                        }
                    }
                }
            }

            if !detail.occurrences.isEmpty {
                SectionBlock("重复安排", trailing: "\(detail.occurrences.count) 次") {
                    VStack(spacing: 0) {
                        ForEach(detail.occurrences.prefix(8)) { occurrence in
                            OccurrenceRow(occurrence: occurrence, taskTitle: detail.task.title,
                                          periodText: nil,
                                          onToggle: { _Concurrency.Task { await toggleOccurrence(occurrence) } },
                                          onSkip: { _Concurrency.Task { await skipOccurrence(occurrence) } })
                                .padding(.horizontal, MovoSpace.s)
                        }
                    }
                }
            }

            if !detail.blockerTitles.isEmpty {
                SectionBlock("先后顺序") {
                    VStack(alignment: .leading, spacing: MovoSpace.xs) {
                        Text("需要先完成：").font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        ForEach(detail.blockerTitles, id: \.self) { title in
                            Text("· \(title)").font(MovoFont.body).foregroundStyle(MovoColor.ink)
                        }
                    }
                    .padding(MovoSpace.s)
                }
            }

            CollapsibleSection("行动记录", trailing: "\(detail.activities.count) 条",
                               isExpanded: $showRecords) {
                SectionBlock("") {
                    if detail.activities.isEmpty {
                        Text("还没有记录。记录投入不等于任务已完成。")
                            .font(MovoFont.body).foregroundStyle(MovoColor.muted)
                            .padding(MovoSpace.s)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(detail.activities) { activity in
                                HStack(alignment: .top, spacing: MovoSpace.s) {
                                    Image(systemName: "timer").foregroundStyle(MovoColor.primary)
                                    VStack(alignment: .leading, spacing: MovoSpace.xs) {
                                        HStack(spacing: MovoSpace.xs) {
                                            MovoTag(timeText(activity.happenedAt.sortEpoch))
                                            if let minutes = activity.durationMinutes {
                                                MovoTag("\(minutes) 分钟")
                                            }
                                            if activity.isCorrection { MovoTag("已更正") }
                                        }
                                        if let text = activity.text, !text.isEmpty {
                                            Text(text).font(MovoFont.caption)
                                                .foregroundStyle(MovoColor.muted)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(MovoSpace.s)
                            }
                        }
                    }
                }
            }

            CollapsibleSection("变更历史", trailing: "\(detail.timeline.count) 条",
                               isExpanded: $showHistory) {
                SectionBlock("") {
                    if detail.timeline.isEmpty {
                        Text("还没有变更记录。").font(MovoFont.body)
                            .foregroundStyle(MovoColor.muted).padding(MovoSpace.s)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(detail.timeline.prefix(20)) { entry in
                                ActionRecordRow(entry, planName: detail.plan?.name)
                                    .padding(.horizontal, MovoSpace.s)
                                MovoDivider().padding(.leading, MovoSpace.m)
                            }
                        }
                    }
                }
            }

            HStack(spacing: MovoSpace.s) {
                MovoButton(detail.task.status == .done ? "重新打开" : "标记完成",
                           systemImage: detail.task.status == .done ? "arrow.counterclockwise" : "checkmark",
                           kind: .primary) { _Concurrency.Task { await toggleDone(detail) } }
                MovoButton("记录一次行动", kind: .secondary) { _Concurrency.Task { await logActivity(detail) } }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String, actionTitle: String?,
                         action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
            Text(label).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                .frame(width: 76, alignment: .leading)
            Text(value).font(MovoFont.body).foregroundStyle(MovoColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: MovoSpace.s)
            if let actionTitle {
                MovoButton(actionTitle, kind: .quiet, action: action)
            }
        }
        .padding(MovoSpace.s)
    }

    // MARK: - 行为

    private func reload() async {
        detail = await env.store.taskDetail(taskID)
    }

    private func toggleDone(_ detail: TaskDetail) async {
        do {
            if detail.task.status == .done {
                try await env.store.execute(ReopenTask(taskID: taskID,
                                                       baseRevision: detail.task.revision))
            } else {
                try await env.store.execute(CompleteTask(taskID: taskID, at: .precise(env.store.now),
                                                         baseRevision: detail.task.revision))
            }
            env.lastBatchNotice = env.store.lastNotification
            await reload()
        } catch let error as MovoError { env.lastError = error } catch { }
    }

    private func toggleOccurrence(_ occurrence: RecurrenceOccurrence) async {
        do {
            if occurrence.status == .done {
                try await env.store.execute(SkipOccurrence(occurrenceID: occurrence.id,
                                                           at: .precise(env.store.now),
                                                           baseRevision: occurrence.revision))
            } else {
                try await env.store.execute(CompleteOccurrence(occurrenceID: occurrence.id,
                                                               at: .precise(env.store.now),
                                                               baseRevision: occurrence.revision))
            }
            await reload()
        } catch let error as MovoError { env.lastError = error } catch { }
    }

    private func skipOccurrence(_ occurrence: RecurrenceOccurrence) async {
        _ = try? await env.store.execute(SkipOccurrence(occurrenceID: occurrence.id,
                                                    at: .precise(env.store.now),
                                                    baseRevision: occurrence.revision))
        await reload()
    }

    private func reschedule(_ detail: TaskDetail, days: Int) async {
        let base = detail.task.scheduledDate ?? env.store.today
        await schedule(detail, day: base.adding(days: days))
    }

    private func schedule(_ detail: TaskDetail, day: DateOnly) async {
        _ = try? await env.store.execute(ScheduleTask(taskID: taskID, date: day,
                                                  baseRevision: detail.task.revision))
        await reload()
    }

    private func clearSchedule(_ detail: TaskDetail) async {
        var patch = TaskPatch()
        patch.clearScheduledDate = true
        _ = try? await env.store.execute(UpdateTask(taskID: taskID, patch: patch,
                                               baseRevision: detail.task.revision))
        await reload()
    }

    private func editSchedule(_ detail: TaskDetail) async {
        // 次日 / 今天 / 下周一的轻量选择
        await schedule(detail, day: env.store.today.adding(days: 1))
    }

    private func editDeadline(_ detail: TaskDetail) async {
        var comps = DateComponents()
        comps.year = env.store.today.y; comps.month = env.store.today.m
        comps.day = env.store.today.d; comps.hour = 18; comps.minute = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = env.store.currentTimeZone
        let date = cal.date(from: comps) ?? env.store.now
        _ = try? await env.store.execute(SetDeadline(taskID: taskID,
                                                 deadline: DateTimeTZ(date, in: env.store.currentTimeZone),
                                                 baseRevision: detail.task.revision,
                                                 reason: "手动设置"))
        await reload()
    }

    private func clearDeadline(_ detail: TaskDetail) async {
        _ = try? await env.store.execute(SetDeadline(taskID: taskID, deadline: nil,
                                                 baseRevision: detail.task.revision))
        await reload()
    }

    private func cancel(_ detail: TaskDetail) async {
        _ = try? await env.store.execute(CancelTask(taskID: taskID,
                                                baseRevision: detail.task.revision,
                                                reason: nil))
        await reload()
    }

    private func saveTitle(_ detail: TaskDetail) async {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var patch = TaskPatch()
        patch.title = trimmed
        _ = try? await env.store.execute(UpdateTask(taskID: taskID, patch: patch,
                                               baseRevision: detail.task.revision))
        editingTitle = false
        await reload()
    }

    private func logActivity(_ detail: TaskDetail) async {
        guard let planID = detail.task.planId else {
            env.lastError = .invalidStructure(reason: "这条记录需要先挂到一个计划下。")
            return
        }
        _ = try? await env.store.execute(LogActivity(planID: planID, taskID: taskID,
                                                 happenedAt: .precise(env.store.now),
                                                 durationMinutes: nil, text: nil, source: .manual))
        env.lastBatchNotice = env.store.lastNotification
        await reload()
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
