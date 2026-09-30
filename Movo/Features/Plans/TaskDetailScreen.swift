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
    @State private var childNodes: [TodoNode] = []
    @State private var childProgress = ""
    @State private var dateEditor = false
    @State private var hasSchedule = false
    @State private var scheduleDate = Date()
    @State private var hasDeadline = false
    @State private var deadlineDate = Date()
    @State private var priority = TaskPriority.normal
    @State private var formError: String?
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
        .task(id: env.store.dataVersion) { await reload() }
        .sheet(isPresented: $dateEditor) {
            VStack(alignment: .leading, spacing: MovoSpace.m) {
                Text("安排与优先级").font(MovoFont.title2)
                MovoDateField("安排日期", isOn: $hasSchedule, date: $scheduleDate,
                              timeZone: env.store.currentTimeZone)
                Toggle("硬截止", isOn: $hasDeadline)
                if hasDeadline {
                    DatePicker("截止时刻", selection: $deadlineDate)
                        .environment(\.timeZone, env.store.currentTimeZone)
                }
                Picker("优先级", selection: $priority) {
                    ForEach(TaskPriority.allCases) { value in Text(value.displayName).tag(value) }
                }
                if let formError { Text(formError).foregroundStyle(.red) }
                HStack {
                    MovoButton("保存") { _Concurrency.Task { await saveArrangement() } }
                    MovoButton("取消", kind: .quiet) { dateEditor = false }
                }
            }.padding(MovoSpace.m)
            #if os(macOS)
            .frame(minWidth: 420)
            #endif
        }
    }

    @ViewBuilder
    private func content(_ detail: TaskDetail) -> some View {
        ScreenScroll {
            ScreenChrome("任务详情", subtitle: detail.children.isEmpty ? detail.task.status.displayName : childProgress) {
                Menu {
                    if detail.children.isEmpty {
                    Button(detail.task.status == .done ? "重新打开" : "标记完成") {
                        _Concurrency.Task { await toggleDone(detail) }
                    }
                    }
                    if !detail.task.isTemplate {
                        Button("添加子任务") {
                            router.present(.newTask(planID: detail.task.planId, parentID: taskID, scheduledToday: false))
                        }
                        Button("移动到…") { router.present(.moveTask(taskID)) }
                    }
                    Button("改到明天") { _Concurrency.Task { await reschedule(detail, days: 1) } }
                    Button("安排到今天") { _Concurrency.Task { await schedule(detail, day: env.store.today) } }
                    Button("清除安排日期") { _Concurrency.Task { await clearSchedule(detail) } }
                    if detail.children.isEmpty && detail.parent == nil {
                        Button("设置/修改频率") { router.present(.recurrenceEditor(taskID: taskID)) }
                    }
                    if detail.task.hardDeadline != nil {
                        Button("清除硬截止") { _Concurrency.Task { await clearDeadline(detail) } }
                    }
                    Divider()
                    if detail.children.isEmpty {
                        Button("取消这项") { _Concurrency.Task { await cancel(detail) } }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18)).foregroundStyle(MovoColor.muted)
                        .frame(width: MovoSpace.minTouch, height: MovoSpace.minTouch)
                }
                .menuStyle(.borderlessButton)
                .frame(width: MovoSpace.minTouch)
            }

            if let parent = detail.parent {
                MovoButton("上级：\(parent.title)", systemImage: "arrow.turn.up.left", kind: .quiet) {
                    router.push(.taskDetail(parent.id))
                }
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
                            if detail.children.isEmpty {
                                StatusTag(taskStatus: detail.task.status)
                            } else {
                                MovoTag(childProgress)
                            }
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

            if !detail.task.isTemplate {
                SectionBlock("子任务", trailing: childProgress) {
                    TaskOutline(nodes: childNodes)
                    MovoButton("添加子任务", systemImage: "plus", kind: .quiet) {
                        router.present(.newTask(planID: detail.task.planId, parentID: taskID, scheduledToday: false))
                    }.padding(MovoSpace.s)
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
                if detail.children.isEmpty {
                MovoButton(detail.task.status == .done ? "重新打开" : "标记完成",
                           systemImage: detail.task.status == .done ? "arrow.counterclockwise" : "checkmark",
                           kind: .primary) { _Concurrency.Task { await toggleDone(detail) } }
                }
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
        childNodes = await env.store.todos(includeCompleted: true, parentID: taskID)
        let deleted = Set(await env.store.repository.tombstones(activeOnly: true).map(\.entityId))
        let tasks = await env.store.repository.allTasks().filter { !deleted.contains($0.id) }
        let progress = ProgressPolicy.groupRollup(parentID: taskID, tasks: tasks)
        childProgress = "已完成 \(progress.done)/\(progress.total)"
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

    private func editSchedule(_ detail: TaskDetail) async { openArrangement(detail) }

    private func editDeadline(_ detail: TaskDetail) async { openArrangement(detail) }

    private func openArrangement(_ detail: TaskDetail) {
        hasSchedule = detail.task.scheduledDate != nil
        scheduleDate = detail.task.scheduledDate?.resolved(in: env.store.currentTimeZone) ?? env.store.now
        hasDeadline = detail.task.hardDeadline != nil
        deadlineDate = detail.task.hardDeadline?.epoch ?? env.store.now
        priority = detail.task.priority ?? .normal
        formError = nil
        dateEditor = true
    }

    private func saveArrangement() async {
        guard let detail else { return }
        do {
            let patch = TaskPatch(priority: priority,
                                  scheduledDate: hasSchedule ? DateOnly(from: scheduleDate, in: env.store.currentTimeZone) : nil,
                                  clearScheduledDate: !hasSchedule)
            let update = UpdateTask(taskID: taskID, patch: patch, baseRevision: detail.task.revision)
            let deadline = SetDeadline(taskID: taskID,
                                       deadline: hasDeadline ? DateTimeTZ(deadlineDate, in: env.store.currentTimeZone) : nil)
            _ = try await env.store.executeBatch(BatchInput(commands: [update, deadline], summary: "已更新安排与优先级"))
            env.lastBatchNotice = env.store.lastNotification
            dateEditor = false
        } catch { formError = error.localizedDescription }
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
