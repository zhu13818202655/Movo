import SwiftUI
import MovoKit

/// .today 路由保留以兼容现有深链；今日是待办的一个筛选。
public struct TodayScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router
    @State private var filter: TodoFilter = .all
    @State private var showCompleted = false
    @State private var nodes: [TodoNode] = []
    @State private var today: TodayView?
    @State private var title = ""
    @State private var saving = false
    @State private var loaded = false
    @State private var error: String?

    public init() {}

    public var body: some View {
        ScreenScroll {
            ScreenChrome("待办", subtitle: env.store.today.displayStringWithWeekday) {
                HStack(spacing: MovoSpace.s) {
                    SyncStatusBadge()
                    MovoIconButton("tray", label: "收件箱") { router.select(.inbox) }
                    MovoIconButton("magnifyingglass", label: "搜索") { router.select(.search) }
                }
            }
            VStack(alignment: .leading, spacing: MovoSpace.s) {
                HStack {
                    TextField("添加待办…", text: $title)
                        .textFieldStyle(.plain).font(MovoFont.body)
                        .onSubmit { _Concurrency.Task { await add() } }
                        .accessibilityLabel("待办标题")
                    MovoButton("添加", isEnabled: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               isLoading: saving) { _Concurrency.Task { await add() } }
                }
                HStack(spacing: MovoSpace.m) {
                    MovoButton("详细创建", systemImage: "plus", kind: .quiet) {
                        router.present(.newTask(planID: nil, parentID: nil, scheduledToday: filter == .today))
                    }
                    MovoButton("AI 整理", systemImage: "sparkles", kind: .quiet) { router.present(.quickCapture) }
                    MovoIconButton("mic", label: "语音整理") { router.present(.recording) }
                    Spacer(minLength: 0)
                }
                if let error { Text(error).font(MovoFont.caption).foregroundStyle(.red) }
            }
            .padding(MovoSpace.m)
            .background(MovoColor.surface, in: RoundedRectangle(cornerRadius: MovoRadius.card))

            Picker("待办范围", selection: $filter) {
                ForEach(TodoFilter.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            Toggle("显示已完成", isOn: $showCompleted)
                .toggleStyle(.switch).font(MovoFont.caption)

            if !loaded {
                LoadingPlaceholder("正在读取待办…")
            } else if filter == .today, let today {
                todayContent(today)
            } else {
                if nodes.isEmpty {
                    MovoEmptyState(systemImage: "checklist", title: "这里还没有待办",
                                   message: emptyMessage, actionTitle: "新建待办", action: {
                        router.present(.newTask(planID: nil, parentID: nil, scheduledToday: false))
                    })
                    .frame(minHeight: 220)
                } else {
                    SectionBlock(filter.title) { TaskOutline(nodes: nodes) }
                }
            }
        }
        .movoPageBackground()
        .task(id: "\(filter.rawValue)-\(showCompleted)-\(env.store.dataVersion)") { await reload() }
        .safeAreaInset(edge: .bottom) {
            if let notice = env.lastBatchNotice, notice.canUndo {
                UndoBar(message: notice.summary) {
                    _Concurrency.Task { await env.undoLastBatch() }
                } onDismiss: { env.clearNotice() }
            }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all: "输入标题即可保存，也可以通过 AI 整理一段文字。"
        case .today: "今天没有安排，其他待办可以在全部中查看。"
        case .upcoming: "安排日期或截止日期在今天之后的待办会显示在这里。"
        case .unscheduled: "尚未设置安排日期的待办会显示在这里。"
        }
    }

    @ViewBuilder
    private func todayContent(_ view: TodayView) -> some View {
        let recurring = (view.focus + view.later + (showCompleted ? view.completed : [])).filter {
            if case .occurrence = $0.body { return true }; return false
        }
        if nodes.isEmpty && recurring.isEmpty {
            MovoEmptyState(systemImage: "sun.max", title: "今天还没有安排", message: emptyMessage,
                           actionTitle: "安排一项待办", action: {
                router.present(.newTask(planID: nil, parentID: nil, scheduledToday: true))
            })
        }
        if !nodes.isEmpty { SectionBlock("今天的待办", trailing: "含逾期与进行中") { TaskOutline(nodes: nodes) } }
        if !recurring.isEmpty { SectionBlock("今天的重复行动") { todayRows(recurring) } }
    }

    private func todayRows(_ items: [TodayItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                TaskRow(item: item, onToggle: {
                    _Concurrency.Task {
                        await env.toggleCompletion(of: item)
                        error = env.lastError?.localizedDescription
                    }
                }, onTap: {
                    if let id = item.taskId { router.push(.taskDetail(id)) }
                })
                .padding(.horizontal, MovoSpace.s)
            }
        }
    }

    private func add() async {
        guard !saving, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        defer { saving = false }
        let draft = title
        if await env.quickAddTask(title: draft, scheduledToday: filter == .today) != nil {
            if title == draft { title = "" }
            error = nil
            if filter == .upcoming { filter = .unscheduled }
        } else { error = env.lastError?.localizedDescription ?? "没有添加成功，请重试。" }
    }

    private func reload() async {
        let selected = filter
        let list = await env.store.todos(filter: selected, includeCompleted: showCompleted)
        let daily = selected == .today ? await env.store.today(env.store.today) : nil
        guard !_Concurrency.Task.isCancelled else { return }
        nodes = list
        today = daily
        loaded = true
    }
}
