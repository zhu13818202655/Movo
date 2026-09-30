//
//  PlanHistoryScreen.swift
//  Features/Plans
//
//  M11-History 计划历史 / D09 历史时间线。
//  只读事件时间线：完成、调整、记录、跳过、暂停、恢复、目标修改、结果纠错、AI 撤销。
//  事件不可改写、不可删除（追加-only），因此历史与今日数值必然一致。
//

import SwiftUI
import MovoKit

public struct PlanHistoryScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let planID: UUID

    @State private var plan: Plan?
    @State private var entries: [TimelineEntry] = []
    @State private var filter = HistoryFilter.all
    @State private var expandedDays: Set<String> = []

    public init(planID: UUID) { self.planID = planID }

    public var body: some View {
        Group {
            if plan == nil {
                LoadingPlaceholder("正在重建历史…")
            } else {
                content
            }
        }
        .movoPageBackground()
        .task { await reload() }
    }

    private var content: some View {
        ScreenScroll {
            ScreenChrome("计划历史", subtitle: plan?.name) {
                MovoButton("查看快照", systemImage: "clock.arrow.circlepath", kind: .secondary) {
                    router.push(.snapshot(planID: planID, asOf: env.store.today.adding(days: -14)))
                }
            }

            MovoFormSection("筛选") {
                Toggle(isOn: $filter.includeCompleted) {
                    Text("包含完成记录").font(MovoFont.body).foregroundStyle(MovoColor.ink)
                }
                .toggleStyle(.switch).controlSize(.small)
                Toggle(isOn: $filter.includeAdjustments) {
                    Text("包含调整").font(MovoFont.body).foregroundStyle(MovoColor.ink)
                }
                .toggleStyle(.switch).controlSize(.small)
                Toggle(isOn: $filter.includeRecords) {
                    Text("包含行动与结果记录").font(MovoFont.body).foregroundStyle(MovoColor.ink)
                }
                .toggleStyle(.switch).controlSize(.small)
                Toggle(isOn: $filter.includeCancelled) {
                    Text("包含已取消").font(MovoFont.body).foregroundStyle(MovoColor.ink)
                }
                .toggleStyle(.switch).controlSize(.small)
            }

            if filtered.isEmpty {
                MovoEmptyState(systemImage: "clock.arrow.circlepath",
                               title: "还没有历史记录",
                               message: "完成、调整、记录都会在这里留下痕迹，并且不会被后来改写。")
                    .frame(minHeight: 260)
            } else {
                ForEach(groupedDays, id: \.0) { day, items in
                    CollapsibleSection(dayText(day), trailing: "\(items.count) 条",
                                       isExpanded: binding(for: day)) {
                        SectionBlock("") {
                            VStack(spacing: 0) {
                                ForEach(items) { entry in
                                    ActionRecordRow(entry, planName: plan?.name)
                                        .padding(.horizontal, MovoSpace.s)
                                    if entry.id != items.last?.id {
                                        MovoDivider().padding(.leading, MovoSpace.m)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 派生

    private var filtered: [TimelineEntry] {
        entries.filter { entry in
            switch entry.kind {
            case .completed: return filter.includeCompleted
            case .cancelled: return filter.includeCancelled
            default:
                if entry.kind.isRecord { return filter.includeRecords }
                if entry.kind.isAdjustment { return filter.includeAdjustments }
                return true
            }
        }
    }

    private var groupedDays: [(String, [TimelineEntry])] {
        let tz = env.store.currentTimeZone
        var order: [String] = []
        var buckets: [String: [TimelineEntry]] = [:]
        for entry in filtered {
            let key = DateOnly(from: entry.recordedAt, in: tz).iso8601DateString
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private func dayText(_ iso: String) -> String {
        guard let day = DateOnly(iso8601DateString: iso, sourceTZ: env.store.currentTimeZone.identifier)
        else { return iso }
        return day.displayStringWithWeekday
    }

    private func binding(for day: String) -> Binding<Bool> {
        Binding(
            get: { expandedDays.contains(day) },
            set: { isOn in
                if isOn { expandedDays.insert(day) } else { expandedDays.remove(day) }
            })
    }

    private func reload() async {
        plan = await env.store.repository.plan(planID)
        entries = await env.store.planTimeline(planID)
        if expandedDays.isEmpty, let first = groupedDays.first { expandedDays.insert(first.0) }
    }
}

#Preview("计划历史") {
    PlanHistoryScreen(planID: DemoFixtures.IDs.workPlan)
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
