import SwiftUI
import MovoKit

/// 列表内添加/编辑共用，所有写入仍经过领域命令。
struct InlineTaskEditor: View {
    @Environment(AppEnvironment.self) private var env
    var parentID: UUID? = nil
    var task: MovoKit.Task? = nil
    var scheduledToday = false
    var onSaved: (UUID) -> Void = { _ in }
    var onCancel: () -> Void
    @State private var title = ""
    @State private var notes = ""
    @State private var planID: UUID?
    @State private var plans: [PlanSummary] = []
    @State private var parent: MovoKit.Task?
    @State private var hasDate = false
    @State private var date = Date()
    @State private var priority = TaskPriority.normal
    @State private var more = false
    @State private var showDate = false
    @State private var saving = false
    @State private var loaded = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            if let parent {
                Text("上级：\(parent.title) · 继承计划与阶段")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
            TextField(task == nil ? "待办标题，回车添加" : "待办标题", text: $title)
                .textFieldStyle(.plain).font(MovoFont.body).focused($focused)
                .onSubmit { _Concurrency.Task { await save() } }
                .accessibilityLabel("待办标题")
            ViewThatFits(in: .horizontal) {
                HStack { attributes; Spacer(minLength: 0); actions }
                VStack(alignment: .leading) { attributes; actions }
            }
            if more {
                TextField("备注（可选）", text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5)
            }
            if let error {
                Text(error).font(MovoFont.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MovoSpace.m)
        .background(MovoColor.surface, in: RoundedRectangle(cornerRadius: MovoRadius.button))
        .overlay(RoundedRectangle(cornerRadius: MovoRadius.button).stroke(MovoColor.primary.opacity(0.4)))
        .disabled(saving)
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focused {
                    Button("收起键盘") { focused = false }
                    Spacer()
                    Button(task == nil ? "添加" : "保存") { _Concurrency.Task { await save() } }
                        .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #endif
        .task {
            guard !loaded else { return }
            plans = await env.store.plans()
            if let parentID { parent = await env.store.repository.task(parentID) }
            title = task?.title ?? ""
            notes = task?.notes ?? ""
            planID = task?.planId
            hasDate = task?.scheduledDate != nil || (task == nil && scheduledToday)
            date = task?.scheduledDate?.noon ?? env.store.now
            priority = task?.priority ?? .normal
            loaded = true
            focused = true
        }
    }

    private var attributes: some View {
        HStack(spacing: MovoSpace.xs) {
            if parentID == nil && task == nil {
                Menu {
                    Picker("所属计划", selection: $planID) {
                        Text("独立待办").tag(nil as UUID?)
                        ForEach(plans) { Text($0.name).tag(Optional($0.id)) }
                    }
                } label: { Label(planID.flatMap { id in plans.first { $0.id == id }?.name } ?? "独立待办", systemImage: "square.stack") }
            }
            Button { showDate = true } label: {
                Label(hasDate ? DateOnly(from: date, in: env.store.currentTimeZone).displayString : "未安排", systemImage: "calendar")
            }
            .popover(isPresented: $showDate) {
                VStack(alignment: .leading, spacing: MovoSpace.m) {
                    MovoDateField("安排日期", isOn: $hasDate, date: $date, timeZone: env.store.currentTimeZone)
                    Button("完成") { showDate = false }
                }.padding().frame(minWidth: 250)
                    .presentationCompactAdaptation(.popover)
            }
            Menu {
                Picker("优先级", selection: $priority) {
                    ForEach(TaskPriority.allCases) { Text($0.displayName).tag($0) }
                }
            } label: { Label(priority.displayName, systemImage: "flag") }
            Button(more ? "收起" : "更多") { more.toggle() }
        }
        .font(MovoFont.caption).foregroundStyle(MovoColor.primary)
        .buttonStyle(.borderless)
    }

    private var actions: some View {
        HStack {
            MovoButton(task == nil ? "添加" : "保存", isEnabled: loaded && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       isLoading: saving) { _Concurrency.Task { await save() } }
            MovoButton("取消", kind: .quiet, action: onCancel)
        }
    }

    private func save() async {
        guard loaded, !saving, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            let day = hasDate ? DateOnly(from: date, in: env.store.currentTimeZone) : nil
            let id: UUID
            if let task {
                let patch = TaskPatch(title: title, notes: notes, priority: priority, scheduledDate: day,
                                      clearNotes: notes.isEmpty, clearScheduledDate: !hasDate)
                _ = try await env.store.execute(UpdateTask(taskID: task.id, patch: patch, baseRevision: task.revision))
                id = task.id
            } else {
                var currentParent: MovoKit.Task?
                if let parentID {
                    currentParent = await env.store.repository.task(parentID)
                    guard currentParent != nil else { throw MovoError.notFound(entityType: .task, id: parentID) }
                }
                let result = try await env.store.execute(CreateTask(
                    title: title, planID: parentID == nil ? planID : currentParent?.planId,
                    stageID: currentParent?.stageId, parentID: parentID, notes: notes.isEmpty ? nil : notes,
                    scheduledDate: day, priority: priority, source: .manual))
                guard let entityID = result.entityID else { throw MovoError.invalidStructure(reason: "没有添加成功，请重试。") }
                id = entityID
                title = ""; notes = ""
                focused = true
            }
            error = nil
            env.lastBatchNotice = env.store.lastNotification
            onSaved(id)
        } catch { self.error = error.localizedDescription }
    }
}
