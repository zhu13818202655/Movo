import SwiftUI
import MovoKit

struct NewTaskSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router
    let planID: UUID?
    let parentID: UUID?
    let scheduledToday: Bool
    @State private var title = ""
    @State private var notes = ""
    @State private var selectedPlan: UUID?
    @State private var plans: [PlanSummary] = []
    @State private var parent: MovoKit.Task?
    @State private var startDraft = TimePointDraft()
    @State private var endDraft = TimePointDraft()
    @State private var priority = TaskPriority.normal
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MovoSpace.m) {
                MovoSheetHeader(parentID == nil ? "新建待办" : "添加子任务",
                                subtitle: parent.map { "上级：\($0.title)" },
                                onClose: { router.dismissSheet() })
                TextField("待办标题", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit { _Concurrency.Task { await save() } }
                    .accessibilityLabel("待办标题")
                if parentID == nil {
                    Picker("所属计划", selection: $selectedPlan) {
                        Text("独立待办").tag(nil as UUID?)
                        ForEach(plans) { plan in Text(plan.name).tag(Optional(plan.id)) }
                    }
                } else {
                    Text("继承父任务的计划与阶段")
                        .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
                MovoTimePointField("开始时间", placeholder: "未设置，可以稍后再定",
                                   draft: $startDraft, timeZone: env.store.currentTimeZone)
                MovoTimePointField("结束时间", placeholder: "未设置，可以稍后再定",
                                   draft: $endDraft, timeZone: env.store.currentTimeZone)
                Picker("优先级", selection: $priority) {
                    ForEach(TaskPriority.allCases) { value in Text(value.displayName).tag(value) }
                }
                TextField("备注（可选）", text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5)
                if let error { Text(error).foregroundStyle(.red).font(MovoFont.caption) }
                MovoButton("添加", isEnabled: loaded && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           isLoading: saving) { _Concurrency.Task { await save() } }
            }
            .padding(MovoSpace.m)
        }
        .movoPageBackground()
        .task {
            guard !loaded else { return }
            selectedPlan = planID
            startDraft = TimePointDraft(scheduledToday ? TimePoint.day(env.store.today) : nil,
                                        fallback: env.store.now)
            endDraft = TimePointDraft(nil, fallback: env.store.now)
            plans = await env.store.plans()
            if let parentID { parent = await env.store.repository.task(parentID) }
            loaded = true
            titleFocused = true
        }
    }

    private func save() async {
        guard loaded, !saving, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            var currentParent: MovoKit.Task?
            if let parentID {
                currentParent = await env.store.repository.task(parentID)
                guard currentParent != nil else { throw MovoError.notFound(entityType: .task, id: parentID) }
            }
            _ = try await env.store.execute(CreateTask(
                title: title, planID: currentParent == nil ? selectedPlan : currentParent?.planId,
                stageID: currentParent?.stageId, parentID: parentID,
                notes: notes.isEmpty ? nil : notes,
                startAt: startDraft.point(in: env.store.currentTimeZone),
                endAt: endDraft.point(in: env.store.currentTimeZone),
                priority: priority, source: .manual))
            env.lastBatchNotice = env.store.lastNotification
            router.dismissSheet()
        } catch { self.error = error.localizedDescription }
    }
}

struct MoveTaskSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router
    let taskID: UUID
    @State private var task: MovoKit.Task?
    @State private var tasks: [MovoKit.Task] = []
    @State private var plans: [PlanSummary] = []
    @State private var planID: UUID?
    @State private var parentID: UUID?
    @State private var childCount = 0
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MovoSpace.m) {
                MovoSheetHeader("移动待办", subtitle: task?.title, onClose: { router.dismissSheet() })
                Text("将一起移动 \(childCount) 项子任务。跨计划的外部前置关系会解除，历史行动记录保留原归属。")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                Picker("目标计划", selection: $planID) {
                    Text("独立待办").tag(nil as UUID?)
                    ForEach(plans) { plan in Text(plan.name).tag(Optional(plan.id)) }
                }
                .onChange(of: planID) { _, _ in parentID = nil }
                Picker("上级待办", selection: $parentID) {
                    Text("顶层待办").tag(nil as UUID?)
                    ForEach(tasks.filter { $0.planId == planID }) { candidate in
                        Text(candidateLabel(candidate)).tag(Optional(candidate.id))
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(MovoFont.caption) }
                MovoButton("确认移动", isEnabled: task != nil, isLoading: saving) {
                    _Concurrency.Task { await move() }
                }
            }
            .padding(MovoSpace.m)
        }
        .task {
            task = await env.store.repository.task(taskID)
            planID = task?.planId
            plans = await env.store.plans()
            let all = await env.store.repository.allTasks()
            let descendants = TaskHierarchy.descendants(of: taskID, in: all)
            let excluded = Set([taskID] + descendants.map(\.id))
            let deleted = Set(await env.store.repository.tombstones(activeOnly: true).map(\.entityId))
            childCount = descendants.filter { !deleted.contains($0.id) }.count
            tasks = TaskHierarchy.ordered(all.filter {
                !excluded.contains($0.id) && !deleted.contains($0.id) && !$0.isTemplate && $0.status.isOpen
            })
        }
    }

    private func candidateLabel(_ candidate: MovoKit.Task) -> String {
        var titles = [candidate.title]
        var cursor = candidate.parentId
        var seen: Set<UUID> = [candidate.id]
        while let id = cursor, seen.insert(id).inserted, let parent = tasks.first(where: { $0.id == id }) {
            titles.insert(parent.title, at: 0)
            cursor = parent.parentId
        }
        return titles.joined(separator: " / ")
    }

    private func move() async {
        guard let task, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await env.store.execute(ReassignTask(taskID: taskID, planID: planID,
                                                        baseRevision: task.revision, parentID: parentID))
            env.lastBatchNotice = env.store.lastNotification
            router.dismissSheet()
        } catch { self.error = error.localizedDescription }
    }
}
