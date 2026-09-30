//
//  TodayScreen.swift
//  Features/Today
//
//  D01 Mac 今日 / M01 iPhone 今日。
//  今天的重点 / 稍后再做 / 可折叠已完成；输入入口支持文字与语音。
//

import SwiftUI
import MovoKit

public struct TodayScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    @State private var today: TodayView?
    @State private var isCompletedExpanded = true

    public init() {}

    public var body: some View {
        Group {
            if let today {
                content(today)
            } else {
                LoadingPlaceholder("正在读取今天…")
            }
        }
        .movoPageBackground()
        .task { await reload() }
        .overlay(alignment: .bottom) {
            if let notice = env.lastBatchNotice, notice.canUndo {
                UndoBar(message: notice.summary) {
                    _Concurrency.Task { await env.undoLastBatch() }
                } onDismiss: {
                    env.clearNotice()
                }
                .padding(.bottom, MovoSpace.s)
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(_ view: TodayView) -> some View {
        ScreenScroll {
            ScreenChrome("今日", subtitle: view.date.displayStringWithWeekday) {
                HStack(spacing: MovoSpace.s) {
                    SyncStatusBadge()
                    MovoIconButton("tray", label: "收件箱") { router.select(.inbox) }
                    MovoIconButton("magnifyingglass", label: "搜索") { router.select(.search) }
                }
            }

            QuickCaptureEntry(
                onText: { router.present(.quickCapture) },
                onVoice: { router.present(.recording) })

            if !view.isEmpty {
                Text(view.badgeText)
                    .font(MovoFont.bodyEmphasis)
                    .foregroundStyle(MovoColor.muted)
            }

            if view.isEmpty {
                MovoEmptyState(
                    systemImage: "sun.max",
                    title: "今天还没有安排",
                    message: "想到什么，先记下来。可以是一个待办，也可以是一句想法。",
                    actionTitle: "记下一件事",
                    action: { router.present(.quickCapture) })
                    .frame(minHeight: 320)
            } else {
                if !view.focus.isEmpty {
                    SectionBlock("今天的重点", trailing: "\(view.focus.count) 项") {
                        itemList(view.focus)
                    }
                }
                if !view.later.isEmpty {
                    SectionBlock("稍后再做", trailing: "\(view.later.count) 项") {
                        itemList(view.later)
                    }
                }
                if !view.completed.isEmpty {
                    CollapsibleSection("已完成", trailing: "\(view.completed.count) 项",
                                       isExpanded: $isCompletedExpanded) {
                        SectionBlock("") {
                            itemList(view.completed)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemList(_ items: [TodayItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                TaskRow(item: item,
                        onToggle: { _Concurrency.Task { await env.toggleCompletion(of: item) } },
                        onTap: { open(item) })
                .padding(.horizontal, MovoSpace.s)
                if index < items.count - 1 {
                    MovoDivider().padding(.leading, MovoSpace.m)
                }
            }
        }
    }

    // MARK: - 行为

    private func open(_ item: TodayItem) {
        if let taskID = item.taskId {
            router.push(.taskDetail(taskID))
        }
    }

    private func reload() async {
        let view = await env.store.today(env.store.today)
        today = view
    }
}

#Preview("今日") {
    let env = AppEnvironment.preview(today: DemoFixtures.referenceDate)
    return TodayScreen().environment(env).environment(\.movoRouter, Router())
}
