//
//  PlansScreen.swift
//  Features/Plans
//
//  D06 Mac 我的计划 / M07 iPhone 我的计划。
//  分类与状态筛选；进度口径按计划类型区分，不合成结果型百分比。
//

import SwiftUI
import MovoKit

public struct PlansScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    @State private var summaries: [PlanSummary] = []
    @State private var categoryFilter: PlanCategory?
    @State private var showArchived = false
    @State private var loaded = false

    public init() {}

    public var body: some View {
        ScreenScroll {
            ScreenChrome("我的计划", subtitle: badge) {
                HStack(spacing: MovoSpace.s) {
                    SettingsEntryButton()
                    MovoButton("新建计划", systemImage: "plus", kind: .primary) {
                        router.present(.newPlan)
                    }
                }
            }

            filterRow

            if filtered.isEmpty {
                MovoEmptyState(systemImage: "square.stack.3d.up",
                               title: showArchived ? "还没有归档的计划" : "还没有计划",
                               message: "一条待办可以单独存在；想长期推进时再建计划也不迟。",
                               actionTitle: showArchived ? nil : "新建计划",
                               action: showArchived ? nil : { router.present(.newPlan) })
                    .frame(minHeight: 280)
            } else {
                ForEach(filtered) { summary in
                    SectionBlock("") {
                        PlanRow(summary) {
                            router.push(.planDetail(summary.id))
                        }
                        .padding(.horizontal, MovoSpace.s)
                    }
                }
            }

            if let error = env.lastError {
                MovoBanner(error: error) { _ in env.lastError = nil }
            }
        }
        // 新建/编辑计划是浮层，关闭后本页不会重建：跟随 dataVersion 重新读取，
        // 刚建立的计划才会立刻出现在列表里（与今日、计划详情一致）。
        .task(id: "\(showArchived)-\(env.store.dataVersion)") { await reload() }
    }

    private var badge: String {
        let active = summaries.filter { $0.status == .active }.count
        return showArchived ? "归档 \(summaries.count) 个" : "进行中 \(active) 个"
    }

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            HStack(spacing: MovoSpace.s) {
                TransparentFilterChip(title: "全部", isSelected: categoryFilter == nil) {
                    categoryFilter = nil
                }
                ForEach(PlanCategory.allCases) { category in
                    TransparentFilterChip(title: category.displayName,
                                          isSelected: categoryFilter == category) {
                        categoryFilter = category
                    }
                }
                Spacer(minLength: 0)
            }
            Toggle(isOn: $showArchived) {
                Text("显示已归档").font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var filtered: [PlanSummary] {
        guard let categoryFilter else { return summaries }
        return summaries.filter { $0.category == categoryFilter }
    }

    private func reload() async {
        let filter: PlanFilter = showArchived
            ? PlanFilter(categories: [], statuses: [.archived])
            : PlanFilter(categories: [], statuses: [.active, .paused])
        summaries = await env.store.plans(filter: filter)
        loaded = true
    }
}

/// 轻量筛选标签（不影响状态语义）
struct TransparentFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MovoFont.captionEmphasis)
                .foregroundStyle(isSelected ? MovoColor.onPrimary : MovoColor.ink)
                .padding(.horizontal, MovoSpace.s)
                .frame(minHeight: 32)
                .background(Capsule().fill(isSelected ? MovoColor.primary : MovoColor.soft))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    PlansScreen()
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
