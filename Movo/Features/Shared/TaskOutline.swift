import SwiftUI
import MovoKit

/// 待办、计划、详情共用同一组命令；父任务只展示叶子进度，不批量勾选后代。
struct TaskOutline: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router
    let nodes: [TodoNode]
    @State private var collapsed: Set<UUID> = []
    @State private var error: String?
    @State private var deleting: TodoNode?
    @State private var deletionIDs: Set<UUID> = []
    @State private var showDelete = false
    @State private var inlineParent: UUID?
    @State private var editing: UUID?

    private struct Row: Identifiable {
        var id: UUID { node.id }
        var node: TodoNode
        var depth: Int
        var previousSibling: UUID?
        var parentTitle: String?
    }

    private var rows: [Row] {
        var result: [Row] = []
        func append(_ siblings: [TodoNode], depth: Int, parentTitle: String? = nil) {
            for (index, node) in siblings.enumerated() {
                result.append(Row(node: node, depth: depth,
                                  previousSibling: index > 0 ? siblings[index - 1].id : nil,
                                  parentTitle: parentTitle))
                if !collapsed.contains(node.id) { append(node.children, depth: depth + 1, parentTitle: node.task.title) }
            }
        }
        append(nodes, depth: 0)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error { Text(error).font(MovoFont.caption).foregroundStyle(.red).padding(MovoSpace.s) }
            ForEach(rows) { row in
                if editing == row.id {
                    InlineTaskEditor(task: row.node.task, onSaved: { _ in editing = nil },
                                     onCancel: { editing = nil })
                } else {
                    outlineRow(row)
                }
                if inlineParent == row.id {
                    InlineTaskEditor(parentID: row.id, onCancel: { inlineParent = nil })
                }
                MovoDivider()
            }
        }
        .confirmationDialog("删除待办", isPresented: $showDelete, titleVisibility: .visible) {
            Button("移到最近删除", role: .destructive) { _Concurrency.Task { await delete() } }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("将删除「\(deleting?.task.title ?? "")」及 \(max(0, deletionIDs.count - 1)) 项子任务和相关重复安排。保留期内可从最近删除恢复。")
        }
    }

    private func outlineRow(_ row: Row) -> some View {
        let node = row.node
        return HStack(spacing: MovoSpace.xs) {
            #if os(macOS)
            if row.depth > 0 { Color.clear.frame(width: CGFloat(min(row.depth, 5)) * 16, height: 1) }
            #endif
            if !node.children.isEmpty {
                Button {
                    if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                } label: {
                    Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                        .frame(width: 28, height: MovoSpace.minTouch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsed.contains(node.id) ? "展开子任务" : "折叠子任务")
            }
            if node.hasChildren {
                Image(systemName: node.isComplete ? "checkmark.circle.fill" : "square.stack")
                    .foregroundStyle(MovoColor.primary).frame(width: 28)
            } else {
                Button { _Concurrency.Task { await toggle(node) } } label: {
                    Image(systemName: node.task.isTemplate ? "arrow.triangle.2.circlepath"
                          : node.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(MovoColor.primary).frame(width: 28, height: MovoSpace.minTouch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(node.task.isTemplate ? "记录本次" : node.isComplete ? "重新打开" : "标记完成")
            }
            Button { router.push(.taskDetail(node.id)) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.task.title).font(MovoFont.bodyEmphasis)
                        .foregroundStyle(node.isContext ? MovoColor.muted : MovoColor.ink)
                        .strikethrough(node.isComplete)
                        .multilineTextAlignment(.leading)
                    Text(metadata(node, parentTitle: row.parentTitle)).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button("就地编辑") { editing = node.id; inlineParent = nil }
                if !node.task.isTemplate {
                    Button("添加子任务") {
                        inlineParent = node.id; editing = nil
                        collapsed.remove(node.id)
                    }
                    Button("移动到…") { router.present(.moveTask(node.id)) }
                    #if os(macOS)
                    if let previous = row.previousSibling {
                        Button("缩进为上一项的子任务") { _Concurrency.Task { await move(node, parentID: previous) } }
                    }
                    #endif
                    if node.task.parentId != nil {
                        Button("提升一级") { _Concurrency.Task { await outdent(node) } }
                    }
                }
                Button("设置日期、优先级等") { router.push(.taskDetail(node.id)) }
                Button("删除…", role: .destructive) {
                    _Concurrency.Task {
                        deleting = node
                        deletionIDs = Set(await DeleteTask.targets(taskID: node.id, repository: env.store.repository)
                            .filter { $0.0 == .task }.map(\.1))
                        showDelete = true
                    }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 32, height: MovoSpace.minTouch) }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("待办操作")
        }
        .padding(.horizontal, MovoSpace.s).padding(.vertical, 6)
    }

    private func metadata(_ node: TodoNode, parentTitle: String?) -> String {
        var parts = [node.planName ?? "独立待办"]
        #if !os(macOS)
        if let parentTitle { parts = ["上级：\(parentTitle)"] }
        #endif
        if node.hasChildren { parts.append("子任务 \(node.done)/\(node.total)") }
        if let start = node.task.startAt { parts.append("开始 \(start.displayString)") }
        else if node.task.endAt == nil, !node.task.isTemplate { parts.append("未安排") }
        if let end = node.task.endAt { parts.append("截止 \(end.displayString)") }
        if node.isContext { parts.append("上级待办") }
        return parts.joined(separator: " · ")
    }

    private func toggle(_ node: TodoNode) async {
        do {
            if node.isComplete {
                _ = try await env.store.execute(ReopenTask(taskID: node.id, baseRevision: node.task.revision))
            } else {
                _ = try await env.store.execute(CompleteTask(taskID: node.id, at: .precise(env.store.now),
                                                            baseRevision: node.task.revision))
            }
            env.lastBatchNotice = env.store.lastNotification
        } catch { self.error = error.localizedDescription }
    }

    private func move(_ node: TodoNode, parentID: UUID?) async {
        do {
            _ = try await env.store.execute(ReassignTask(taskID: node.id, planID: node.task.planId,
                                                        stageID: node.task.stageId, baseRevision: node.task.revision,
                                                        parentID: parentID))
            env.lastBatchNotice = env.store.lastNotification
        } catch { self.error = error.localizedDescription }
    }

    private func outdent(_ node: TodoNode) async {
        guard let parentID = node.task.parentId, let parent = await env.store.repository.task(parentID) else { return }
        await move(node, parentID: parent.parentId)
    }

    private func delete() async {
        guard let node = deleting else { return }
        do {
            _ = try await env.store.execute(DeleteTask(taskID: node.id, baseRevision: node.task.revision,
                                                      expectedTaskIDs: deletionIDs))
            env.lastBatchNotice = env.store.lastNotification
            deleting = nil
        } catch { self.error = error.localizedDescription }
    }
}
