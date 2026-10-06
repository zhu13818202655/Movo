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
    @State private var adding = false
    @State private var savedOutsideFilter: UUID?
    @State private var loaded = false
    @State private var error: String?

    public init() {}

    public var body: some View {
        ScreenScroll {
            ScreenChrome("待办", subtitle: env.store.today.displayStringWithWeekday) {
                HStack(spacing: MovoSpace.s) {
                    SyncStatusBadge()
                    MovoIconButton("sparkles.rectangle.stack", label: "整理记录") { router.select(.inbox) }
                    MovoIconButton("magnifyingglass", label: "搜索") { router.select(.search) }
                }
            }
            #if os(macOS)
            AICaptureQuickEntry()
            #endif

            Picker("待办范围", selection: $filter) {
                ForEach(TodoFilter.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            if adding {
                InlineTaskEditor(scheduledToday: filter == .today, onSaved: { id in
                    _Concurrency.Task { await checkSavedTask(id) }
                }, onCancel: { adding = false })
            } else {
                MovoButton("添加待办", systemImage: "plus", kind: .quiet) { adding = true }
            }
            if let id = savedOutsideFilter {
                MovoBanner(kind: .info, title: "待办已添加", message: "这项待办不在当前筛选内。",
                           actions: [("查看待办", { router.push(.taskDetail(id)) })])
            }
            if let error { Text(error).font(MovoFont.caption).foregroundStyle(.red) }
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
                        adding = true
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
                adding = true
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

    private func checkSavedTask(_ id: UUID) async {
        let current = await env.store.todos(filter: filter, includeCompleted: showCompleted)
        func contains(_ nodes: [TodoNode]) -> Bool {
            nodes.contains { $0.id == id || contains($0.children) }
        }
        savedOutsideFilter = contains(current) ? nil : id
        await reload()
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
