//
//  TaskDetailScreen.swift
//  Features/Plans
//
//  D07 Mac 任务详情 / M12 iPhone 任务详情。
//  开始时间与结束时间分别编辑；记录、成果与变更历史可展开。
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
    @State private var startDraft = TimePointDraft()
    @State private var endDraft = TimePointDraft()
    @State private var priority = TaskPriority.normal
    @State private var formError: String?
    @State private var rangeWarning: String?
    @State private var showHistory = false
    @State private var showRecords = true
    @State private var titleDraft = ""
    @State private var editingTitle = false
    @State private var templateSteps: [StepLine] = []
    @State private var newStepTitle = ""
    @State private var stepParentID: UUID?
    @State private var renamingStep: Task?
    @State private var renameDraft = ""
    @State private var checklistOccurrence: RecurrenceOccurrence?
    @State private var checklistSteps: [OccurrenceStep] = []
    @State private var completePrompt: RecurrenceOccurrence?

    /// 重复行动模板下的一行步骤（带缩进深度）
    private struct StepLine: Identifiable {
        let task: Task
        let depth: Int
        var id: UUID { task.id }
    }
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
        .alert("步骤改名", isPresented: Binding(get: { renamingStep != nil },
                                                       set: { if !$0 { renamingStep = nil } })) {
            TextField("步骤名称", text: $renameDraft)
            Button("保存") { _Concurrency.Task { await saveStepRename() } }
            Button("取消", role: .cancel) { renamingStep = nil }
        }
        .confirmationDialog("所有步骤都勾选了", isPresented: Binding(get: { completePrompt != nil },
                                                                set: { if !$0 { completePrompt = nil } }),
                            titleVisibility: .visible) {
            Button("标记本次完成") {
                if let occurrence = completePrompt {
                    _Concurrency.Task { await completeOccurrence(occurrence) }
                }
            }
            Button("先不标记", role: .cancel) { completePrompt = nil }
        } message: {
            Text("标记本次完成？不会影响未来的安排。")
        }        .sheet(isPresented: $dateEditor) {
            VStack(alignment: .leading, spacing: MovoSpace.m) {
                Text("时间与优先级").font(MovoFont.title2)
                MovoTimePointField("开始时间", draft: $startDraft, timeZone: env.store.currentTimeZone)
                MovoTimePointField("结束时间", draft: $endDraft, timeZone: env.store.currentTimeZone)
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
                    if !detail.task.isTemplate {
                        // 重复行动的「哪天做」由频率决定：把它「改到明天」或清掉开始时间
                        // 只会让窗口和规则脱节，所以这些动作只对普通待办开放。
                        Button("改到明天") { _Concurrency.Task { await reschedule(detail, days: 1) } }
                        Button("安排到今天") { _Concurrency.Task { await schedule(detail, day: env.store.today) } }
                        if detail.task.startAt != nil {
                            Button("清除开始时间") { _Concurrency.Task { await clearSchedule(detail) } }
                        }
                    }
                    if detail.parent == nil {
                        Button(detail.task.isTemplate ? "修改频率" : "设置/修改频率") {
                            router.present(.recurrenceEditor(taskID: taskID))
                        }
                    }
                    if !detail.task.isTemplate, detail.task.endAt != nil {
                        Button("清除结束时间") { _Concurrency.Task { await clearDeadline(detail) } }
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

            // 所属与时间（开始 / 结束分开）
            if let rangeWarning {
                MovoBanner(kind: .warning, title: "时间超出了范围", message: rangeWarning)
            }
            SectionBlock("所属与时间") {
                VStack(alignment: .leading, spacing: 0) {
                    infoRow("计划", value: detail.plan?.name ?? "未归类",
                            actionTitle: detail.plan == nil ? nil : "查看") {
                        if let plan = detail.plan { router.push(.planDetail(plan.id)) }
                    }
                    MovoDivider().padding(.leading, MovoSpace.s)
                    infoRow("阶段", value: detail.stage?.name ?? "未挂阶段", actionTitle: nil, action: {})
                    MovoDivider().padding(.leading, MovoSpace.s)
                    if detail.task.isTemplate {
                        // 重复行动没有「哪一天开始/结束」，只有规则窗口；
                        // 直接改任务时间会与规则脱节，所以这里只展示，编辑走频率页。
                        infoRow("生效日期", value: detail.task.startAt?.displayString ?? "未设置",
                                actionTitle: "改频率") { router.present(.recurrenceEditor(taskID: taskID)) }
                        MovoDivider().padding(.leading, MovoSpace.s)
                        infoRow("重复到", value: detail.task.endAt?.displayString ?? "长期持续",
                                actionTitle: "改频率") { router.present(.recurrenceEditor(taskID: taskID)) }
                    } else {
                        infoRow("开始时间", value: detail.task.startAt?.displayString ?? "未设置",
                                actionTitle: "编辑") { _Concurrency.Task { await editSchedule(detail) } }
                        MovoDivider().padding(.leading, MovoSpace.s)
                        infoRow("结束时间",
                                value: detail.task.endAt?.displayString ?? "未设置",
                                actionTitle: "编辑") { _Concurrency.Task { await editDeadline(detail) } }
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

            if detail.task.isTemplate && !detail.task.isStep {
                stepsSection(detail)
            }

            if !detail.occurrences.isEmpty {
                if !detail.occurrenceStrip.isEmpty {
                    MovoOccurrenceStrip(items: detail.occurrenceStrip)
                }

                SectionBlock("重复安排", trailing: "\(detail.occurrences.count) 次") {
                    VStack(spacing: 0) {
                        if let occurrence = checklistOccurrence, !checklistSteps.isEmpty {
                            checklist(occurrence)
                            MovoDivider()
                        }
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

    // MARK: - 重复行动的步骤

    @ViewBuilder
    private func stepsSection(_ detail: TaskDetail) -> some View {
        SectionBlock("步骤", trailing: templateSteps.isEmpty ? nil : "\(templateSteps.count) 项") {
            VStack(alignment: .leading, spacing: 0) {
                if templateSteps.isEmpty {
                    Text("还没有步骤。步骤会出现在每一次执行里，逐项勾选。")
                        .font(MovoFont.body).foregroundStyle(MovoColor.muted)
                        .padding(MovoSpace.s)
                }
                ForEach(templateSteps) { line in
                    HStack(spacing: MovoSpace.s) {
                        Image(systemName: "circle.dashed").foregroundStyle(MovoColor.muted)
                        Text(line.task.title).font(MovoFont.body).foregroundStyle(MovoColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: MovoSpace.s)
                        Menu {
                            Button("添加下级步骤") {
                                stepParentID = line.task.id
                                newStepTitle = ""
                            }
                            Button("改名") {
                                renameDraft = line.task.title
                                renamingStep = line.task
                            }
                            Button("删除", role: .destructive) {
                                _Concurrency.Task { await deleteStep(line.task) }
                            }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(MovoColor.muted)
                                .frame(width: MovoSpace.minTouch, height: MovoSpace.minTouch)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: MovoSpace.minTouch)
                        .accessibilityLabel("步骤操作")
                    }
                    .padding(.leading, MovoSpace.s + CGFloat(line.depth) * MovoSpace.m)
                    .padding(.trailing, MovoSpace.xs)
                    MovoDivider()
                }
                VStack(alignment: .leading, spacing: MovoSpace.xs) {
                    if let parentID = stepParentID,
                       let parent = templateSteps.first(where: { $0.id == parentID }) {
                        HStack {
                            Text("添加到「\(parent.task.title)」下").font(MovoFont.caption)
                                .foregroundStyle(MovoColor.muted)
                            Spacer(minLength: 0)
                            MovoButton("改为顶层", kind: .quiet) { stepParentID = nil }
                        }
                    }
                    HStack(spacing: MovoSpace.s) {
                        MovoTextField("", text: $newStepTitle, placeholder: "添加步骤")
                        MovoButton("添加", isEnabled: !newStepTitle.trimmingCharacters(in: .whitespaces).isEmpty) {
                            _Concurrency.Task { await addStep(detail) }
                        }
                    }
                }
                .padding(MovoSpace.s)
            }
        }
    }

    @ViewBuilder
    private func checklist(_ occurrence: RecurrenceOccurrence) -> some View {
        let progress = RecurrenceStepPolicy.leafProgress(checklistSteps)
        let parents = Set(checklistSteps.compactMap(\.parentId))
        VStack(alignment: .leading, spacing: MovoSpace.xs) {
            HStack {
                Text("本次步骤" + (occurrence.scheduledOn.map { " · \($0.displayString)" } ?? ""))
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                Spacer(minLength: 0)
                Text("\(progress.done)/\(progress.total)").font(MovoFont.caption)
                    .foregroundStyle(MovoColor.muted)
            }
            ForEach(RecurrenceStepPolicy.indented(checklistSteps), id: \.step.id) { line in
                let isParent = parents.contains(line.step.id)
                Button {
                    _Concurrency.Task { await toggleStep(occurrence, step: line.step) }
                } label: {
                    HStack(spacing: MovoSpace.s) {
                        Image(systemName: line.step.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(line.step.isDone ? MovoColor.primary : MovoColor.muted)
                        Text(line.step.title).font(MovoFont.body).foregroundStyle(MovoColor.ink)
                            .strikethrough(line.step.isDone)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: MovoSpace.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isParent)
                .padding(.leading, CGFloat(line.depth) * MovoSpace.m)
                .accessibilityLabel(line.step.title)
                .accessibilityValue(line.step.isDone ? "已完成" : "未完成")
            }
        }
        .padding(MovoSpace.s)
    }

    private func addStep(_ detail: TaskDetail) async {
        let title = newStepTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try await env.store.execute(CreateTask(title: title, planID: detail.task.planId,
                                                   stageID: detail.task.stageId,
                                                   parentID: stepParentID ?? taskID))
            newStepTitle = ""
            await reload()
        } catch let error as MovoError { env.lastError = error } catch { }
    }

    private func saveStepRename() async {
        guard let step = renamingStep else { return }
        renamingStep = nil
        do {
            try await env.store.execute(UpdateTask(taskID: step.id, patch: TaskPatch(title: renameDraft),
                                                   baseRevision: step.revision))
            await reload()
        } catch let error as MovoError { env.lastError = error } catch { }
    }

    private func deleteStep(_ step: Task) async {
        do {
            try await env.store.execute(DeleteTask(taskID: step.id, baseRevision: step.revision))
            env.lastBatchNotice = env.store.lastNotification
            await reload()
        } catch let error as MovoError { env.lastError = error } catch { }
    }

    private func toggleStep(_ occurrence: RecurrenceOccurrence, step: OccurrenceStep) async {
        let nowDone = !step.isDone
        do {
            try await env.store.execute(ToggleOccurrenceStep(occurrenceID: occurrence.id, stepID: step.id,
                                                             isDone: nowDone,
                                                             baseRevision: occurrence.revision))
            await reload()
            if nowDone, RecurrenceStepPolicy.isAllDone(checklistSteps) {
                completePrompt = checklistOccurrence
            }
        } catch let error as MovoError { env.lastError = error } catch { }
    }

    private func completeOccurrence(_ occurrence: RecurrenceOccurrence) async {
        completePrompt = nil
        do {
            try await env.store.execute(CompleteOccurrence(occurrenceID: occurrence.id,
                                                           at: .precise(env.store.now),
                                                           baseRevision: occurrence.revision))
            await reload()
        } catch let error as MovoError { env.lastError = error } catch { }
    }

    // MARK: - 行为

    private func reload() async {
        detail = await env.store.taskDetail(taskID)
        await reloadSteps()
        if let task = detail?.task, task.status.isOpen, !task.isTemplate {
            rangeWarning = await StructurePolicy.timeRangeViolation(for: task, repository: env.store.repository)
        } else {
            rangeWarning = nil
        }
        childNodes = await env.store.todos(includeCompleted: true, parentID: taskID)
        let deleted = Set(await env.store.repository.tombstones(activeOnly: true).map(\.entityId))
        let tasks = await env.store.repository.allTasks().filter { !deleted.contains($0.id) }
        let progress = ProgressPolicy.groupRollup(parentID: taskID, tasks: tasks)
        childProgress = "已完成 \(progress.done)/\(progress.total)"
    }

    private func reloadSteps() async {
        guard let task = detail?.task, task.isTemplate, !task.isStep else {
            templateSteps = []
            checklistOccurrence = nil
            checklistSteps = []
            return
        }
        let repository = env.store.repository
        templateSteps = await RecurrenceStepPolicy.liveSteps(templateID: taskID, repository: repository)
            .map { StepLine(task: $0.task, depth: $0.depth) }
        let today = env.store.today
        let pending = (detail?.occurrences ?? []).filter { $0.status == .pending }
            .sorted { ($0.scheduledOn ?? today) < ($1.scheduledOn ?? today) }
        let current = pending.first { ($0.scheduledOn ?? today) >= today } ?? pending.last
        checklistOccurrence = current
        if let current {
            checklistSteps = await RecurrenceStepPolicy.displaySteps(of: current, repository: repository)
        } else {
            checklistSteps = []
        }
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
        // 起止一起平移，避免只移开始导致开始晚于结束
        let base = detail.task.startAt ?? TimePoint.day(env.store.today)
        var patch = TaskPatch(startAt: base.adding(days: days))
        if let end = detail.task.endAt { patch.endAt = end.adding(days: days) }
        await run(UpdateTask(taskID: taskID, patch: patch, baseRevision: detail.task.revision))
    }

    private func schedule(_ detail: TaskDetail, day: DateOnly) async {
        await run(ScheduleTask(taskID: taskID, startAt: .day(day), baseRevision: detail.task.revision))
    }

    private func clearSchedule(_ detail: TaskDetail) async {
        var patch = TaskPatch()
        patch.clearStartAt = true
        await run(UpdateTask(taskID: taskID, patch: patch, baseRevision: detail.task.revision))
    }

    /// 执行命令：校验被拒（如超出计划范围）时把原因显示出来
    private func run(_ command: some DomainCommand) async {
        do {
            try await env.store.execute(command)
        } catch let error as MovoError {
            env.lastError = error
        } catch { }
        await reload()
    }

    private func editSchedule(_ detail: TaskDetail) async { openArrangement(detail) }

    private func editDeadline(_ detail: TaskDetail) async { openArrangement(detail) }

    private func openArrangement(_ detail: TaskDetail) {
        startDraft = TimePointDraft(detail.task.startAt, fallback: env.store.now)
        endDraft = TimePointDraft(detail.task.endAt, fallback: env.store.now)
        priority = detail.task.priority ?? .normal
        formError = nil
        dateEditor = true
    }

    private func saveArrangement() async {
        guard let detail else { return }
        do {
            let tz = env.store.currentTimeZone
            let start = startDraft.point(in: tz)
            let end = endDraft.point(in: tz)
            let patch = TaskPatch(priority: priority, startAt: start, endAt: end,
                                  clearStartAt: start == nil, clearEndAt: end == nil)
            let update = UpdateTask(taskID: taskID, patch: patch, baseRevision: detail.task.revision)
            _ = try await env.store.executeBatch(BatchInput(commands: [update], summary: "已更新时间与优先级"))
            env.lastBatchNotice = env.store.lastNotification
            dateEditor = false
        } catch { formError = error.localizedDescription }
    }

    private func clearDeadline(_ detail: TaskDetail) async {
        var patch = TaskPatch()
        patch.clearEndAt = true
        await run(UpdateTask(taskID: taskID, patch: patch, baseRevision: detail.task.revision))
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
