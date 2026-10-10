import SwiftUI
import MovoKit

/// 待办、计划、详情共用同一组命令；父任务只展示叶子进度，不批量勾选后代。
struct TaskOutline: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router
    let nodes: [TodoNode]
    /// 元信息里的时间怎么显示。今日筛选传 `.today(参考日)`，其余场景传 `.absolute`。
    /// 故意不设缺省值：每个调用点都要自己说清楚页面是哪个时间上下文。
    let timeContext: TimeDisplayContext
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

    /// 每层缩进宽度。需 ≥ 展开箭头列宽（28 + 页边距），子级的图标与标题
    /// 才能明显落在父级右侧；层级越深逐层后退。
    private var indentUnit: CGFloat {
        #if os(macOS)
        40
        #else
        32
        #endif
    }

    private func outlineRow(_ row: Row) -> some View {
        let node = row.node
        let levels = min(row.depth, 5)
        return HStack(alignment: .center, spacing: 0) {
            // 层级区：每层一个缩进格；最内层画一条浅色竖线，对齐父级展开箭头的中心，
            // 连续子行的竖线连成一片，标出「这些行都属于上面的父级」。
            ForEach(0..<levels, id: \.self) { level in
                ZStack(alignment: .leading) {
                    Color.clear
                    if level == levels - 1 {
                        Rectangle().fill(MovoColor.line)
                            .frame(width: 1)
                            .padding(.leading, MovoSpace.s + 14)
                    }
                }
                .frame(width: indentUnit)
            }
            HStack(spacing: MovoSpace.xs) {
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
                    // 父级不直接勾选（完成度由子级汇总），用进度环表达 k/n；
                    // 全部完成时与叶子的实心对勾一致，点击与标题一样进详情。
                    Button { router.push(.taskDetail(node.id)) } label: {
                        Group {
                            if node.total > 0, node.done >= node.total {
                                Image(systemName: "checkmark.circle.fill")
                            } else {
                                ZStack {
                                    Circle().stroke(MovoColor.line, lineWidth: 2)
                                    Circle().trim(from: 0, to: CGFloat(node.done) / CGFloat(max(node.total, 1)))
                                        .stroke(MovoColor.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                }
                                .frame(width: 18, height: 18)
                            }
                        }
                        .foregroundStyle(MovoColor.primary)
                        .frame(width: 28, height: MovoSpace.minTouch)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看详情，子任务 \(node.done)/\(node.total) 已完成")
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
                        // 眼睛看到的是今日上下文（「截止 14:00」），耳朵听到的仍然是绝对时间
                        // （「截止 10月8日 14:00」）。省掉日期只是省掉屏幕上重复的信息，
                        // 读出来时用户没有「整页都是今天」这个上下文可以替他补上。
                        Text(metadata(node, parentTitle: row.parentTitle, in: timeContext))
                            .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                            .multilineTextAlignment(.leading)
                            .accessibilityLabel(metadata(node, parentTitle: row.parentTitle,
                                                         in: .absolute))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                // 正在计时的这一行带一个徽标，点它回到计时页；它自己吃掉点击，
                // 不会穿透到「进入详情」。
                if let session = env.activeFocus(for: node.id) {
                    FocusRowBadge(session: session) { router.push(.focus(node.id)) }
                }
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
                    // 三项互不替代：已经在计时的这一项回到计时页，其余开始一次新的，
                    // 而「设置日期、优先级等」仍然只是进详情。行本体的点击行为一律不变。
                    // 开始之后直接进计时页：在清单上按一下却停在原地，看不出那一下生没生效。
                    if let session = env.activeFocus(for: node.id) {
                        Button(session.isPaused ? "回到计时（已暂停）" : "回到计时") {
                            router.push(.focus(node.id))
                        }
                    } else if !node.task.isTemplate {
                        Button("开始专注") {
                            if env.beginFocus(node.task) { router.push(.focus(node.id)) }
                        }
                    }
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
    }

    /// 行内元信息。`context` 只影响时刻那一段的写法：今日筛选传今日上下文，
    /// 省掉「今天」这个日期；传 `.absolute` 得到完整时间，用于无障碍标签。
    private func metadata(_ node: TodoNode, parentTitle: String?,
                          in context: TimeDisplayContext) -> String {
        var parts = [node.planName ?? "独立待办"]
        #if !os(macOS)
        if let parentTitle { parts = ["上级：\(parentTitle)"] }
        #endif
        if node.hasChildren { parts.append("子任务 \(node.done)/\(node.total)") }
        if let summary = node.recurrenceSummary {
            // 重复行动的「哪天该做」由频率决定，模板自己的 startAt/endAt 只是窗口端点。
            // 展示频率，否则会读成「这个重复行动只在某一天截止」。
            parts.append(summary)
        } else {
            // 今日筛选下参考日当天的日期是冗余的（整页都是今天），只留时刻；
            // 逾期、明天、其他日期的日期照常显示。
            if let start = node.task.startAt { parts.append("开始 \(start.displayString(in: context))") }
            else if node.task.endAt == nil { parts.append("未安排") }
            if let end = node.task.endAt { parts.append("截止 \(end.displayString(in: context))") }
        }
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
