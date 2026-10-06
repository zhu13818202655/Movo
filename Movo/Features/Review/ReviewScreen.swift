//
//  ReviewScreen.swift
//  Features/Review
//
//  D08 / M10 周回顾。事实 / 观察 / 建议三个分区彼此分开：
//  「事实」只列本周实际发生的记录与测量；「观察」由用户自己写；
//  「建议」在采纳前不产生任何任务（REQ 17）。数据不足时显示"本周无记录"（AC15）。
//

import SwiftUI
import MovoKit

public struct ReviewScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    @State private var view: ReviewView?
    @State private var weekStart: DateOnly?
    @State private var newNote = ""
    @State private var isSavingNote = false

    public init() {}

    public var body: some View {
        Group {
            if let view {
                content(view)
            } else {
                LoadingPlaceholder("正在汇总这一周…")
            }
        }
        .movoPageBackground()
        .task(id: weekStart) { await reload() }
    }

    @ViewBuilder
    private func content(_ view: ReviewView) -> some View {
        ScreenScroll {
            ScreenChrome("回顾", subtitle: view.rangeText) {
                HStack(spacing: MovoSpace.s) {
                    MovoIconButton("chevron.left", label: "上一周") {
                        weekStart = view.weekStart.adding(days: -7)
                    }
                    MovoIconButton("chevron.right", label: "下一周") {
                        let next = view.weekStart.adding(days: 7)
                        if next <= env.store.today.startOfWeek() { weekStart = next }
                    }
                }
            }

            Text(view.summaryText)
                .font(MovoFont.body).foregroundStyle(MovoColor.muted)
                .fixedSize(horizontal: false, vertical: true)

            if !view.hasData {
                MovoEmptyState(systemImage: "chart.bar.doc.horizontal",
                               title: view.emptyStateText,
                               message: "没有记录时，我们不猜原因。可以补记一条，或者什么都不写。",
                               actionTitle: "去添加待办",
                               action: { router.select(.today) })
                    .frame(minHeight: 260)
            } else {
                MovoDayBarChart(dailyActions: view.dailyActions, totalCount: view.totalActionCount)
                if !view.categoryDistribution.isEmpty {
                    MovoCategoryDistributionBar(distribution: view.categoryDistribution, totalCount: view.totalActionCount)
                }
                factsSection(view)
            }

            gapsSection(view)
            suggestionsSection(view)
            observationSection(view)

            if let error = env.lastError {
                MovoBanner(error: error) { _ in env.lastError = nil }
            }
        }
    }

    // MARK: - 事实

    @ViewBuilder
    private func factsSection(_ view: ReviewView) -> some View {
        SectionBlock("本周事实", trailing: "\(view.facts.count) 个计划") {
            VStack(spacing: 0) {
                ForEach(view.facts) { fact in
                    VStack(alignment: .leading, spacing: MovoSpace.s) {
                        HStack(spacing: MovoSpace.s) {
                            Text(fact.planName).font(MovoFont.headline)
                                .foregroundStyle(MovoColor.ink)
                            if let category = fact.category { PlanCategoryTag(category, compact: true) }
                            if fact.isLocalOnly {
                                MovoTag("仅本机统计", systemImage: "lock")
                            }
                            Spacer(minLength: 0)
                        }

                        Text(fact.factText).font(MovoFont.body).foregroundStyle(MovoColor.muted)

                        if !fact.metricChanges.isEmpty {
                            ForEach(fact.metricChanges) { trend in
                                VStack(alignment: .leading, spacing: MovoSpace.xs) {
                                    HStack(spacing: MovoSpace.s) {
                                        Text(trend.name).font(MovoFont.captionEmphasis)
                                            .foregroundStyle(MovoColor.ink)
                                        if let latest = trend.latest {
                                            Text("\(PlanEditScreen.numberText(latest))\(trend.unitDisplayName)")
                                                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                                        }
                                        if let deltaText = trend.deltaText {
                                            MovoTag("较上次 \(deltaText)")
                                        }
                                        if trend.correctedCount > 0 {
                                            MovoTag("\(trend.correctedCount) 次更正", systemImage: "pencil")
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    MetricTrendChart(trend)
                                        .padding(.vertical, MovoSpace.xs)
                                }
                            }
                        }

                        if !fact.structuralEvents.isEmpty {
                            Text("结构调整：" + fact.structuralEvents.prefix(3).joined(separator: "；"))
                                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: MovoSpace.s) {
                            if let planId = fact.planId {
                                MovoButton("查看计划", kind: .quiet) {
                                    router.push(.planDetail(planId))
                                }
                                MovoButton("来源记录", kind: .quiet) {
                                    router.push(.planHistory(planId))
                                }
                            }
                            Spacer(minLength: 0)
                            Text(fact.sourceSummary).font(MovoFont.caption)
                                .foregroundStyle(MovoColor.muted)
                        }
                    }
                    .padding(MovoSpace.s)
                    if fact.id != view.facts.last?.id {
                        MovoDivider().padding(.leading, MovoSpace.m)
                    }
                }
            }
        }
    }

    // MARK: - 缺口

    @ViewBuilder
    private func gapsSection(_ view: ReviewView) -> some View {
        if !view.gaps.isEmpty {
            SectionBlock("没有记录的地方", trailing: "\(view.gaps.count) 个") {
                VStack(spacing: 0) {
                    ForEach(view.gaps) { gap in
                        HStack(alignment: .top, spacing: MovoSpace.s) {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(MovoColor.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(gap.planName).font(MovoFont.bodyEmphasis)
                                    .foregroundStyle(MovoColor.ink)
                                Text(gap.message).font(MovoFont.caption)
                                    .foregroundStyle(MovoColor.muted)
                            }
                            Spacer(minLength: MovoSpace.s)
                            if let planId = gap.planId {
                                MovoButton("补记", kind: .quiet) {
                                    router.push(.planDetail(planId))
                                }
                            }
                        }
                        .padding(MovoSpace.s)
                    }
                }
            }
        }
    }

    // MARK: - 建议

    @ViewBuilder
    private func suggestionsSection(_ view: ReviewView) -> some View {
        if !view.suggestions.isEmpty {
            SectionBlock("建议", trailing: "采纳后才会加入安排") {
                VStack(spacing: MovoSpace.m) {
                    ForEach(view.suggestions) { suggestion in
                        SuggestionCard(
                            title: suggestion.kind.displayName,
                            reason: suggestion.hasSource ? nil : "这条建议缺少来源，暂不建议采纳。",
                            lines: [],
                            sourceText: suggestion.sourceText,
                            primaryTitle: "采纳",
                            onPrimary: { _Concurrency.Task { await resolve(suggestion, accept: true) } },
                            onDismiss: { _Concurrency.Task { await resolve(suggestion, accept: false) } })
                    }
                }
                .padding(MovoSpace.s)
            }
        }
    }

    // MARK: - 观察

    @ViewBuilder
    private func observationSection(_ view: ReviewView) -> some View {
        SectionBlock("你的观察", trailing: "\(view.reviewNotes.count) 条") {
            VStack(alignment: .leading, spacing: MovoSpace.s) {
                ForEach(view.reviewNotes) { note in
                    HStack(alignment: .top, spacing: MovoSpace.s) {
                        Image(systemName: "text.bubble").foregroundStyle(MovoColor.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.text).font(MovoFont.body).foregroundStyle(MovoColor.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Self.timeText(note.createdAt))
                                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        }
                        Spacer(minLength: 0)
                    }
                }

                MovoTextField("写下你自己的观察", text: $newNote,
                              placeholder: "例如：这周两次都是晚上做的，白天确实挤不出时间。",
                              axis: .vertical)

                HStack(spacing: MovoSpace.s) {
                    MovoButton("记下这条观察", kind: .primary,
                               isEnabled: !newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSavingNote,
                               isLoading: isSavingNote) {
                        _Concurrency.Task { await saveNote(view) }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(MovoSpace.s)
        }
    }

    // MARK: - 行为

    private func saveNote(_ view: ReviewView) async {
        let text = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSavingNote = true
        defer { isSavingNote = false }
        do {
            try await env.store.execute(RecordReviewNote(text: text, weekStart: view.weekStart))
            newNote = ""
            await reload()
        } catch let error as MovoError {
            env.lastError = error
        } catch { }
    }

    private func resolve(_ suggestion: Suggestion, accept: Bool) async {
        do {
            if accept {
                try await env.store.execute(AcceptSuggestion(suggestionID: suggestion.id,
                                                             baseRevision: suggestion.revision))
            } else {
                try await env.store.execute(DismissSuggestion(suggestionID: suggestion.id,
                                                              baseRevision: suggestion.revision))
            }
            await reload()
        } catch let error as MovoError {
            env.lastError = error
        } catch { }
    }

    private func reload() async {
        view = await env.store.reviewView(weekStart: weekStart)
    }

    private static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh-Hans")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}

#Preview("周回顾") {
    ReviewScreen()
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
