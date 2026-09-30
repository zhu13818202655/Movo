//
//  SearchScreen.swift
//  Features/Search
//
//  D10 / D10-Empty / M06-Search 搜索。
//  中文按二元组 + 拉丁词做 AND 匹配；结果按类型分组，点按回链到原对象。
//  查询为空时给出空状态而不是"最近搜索"（不保存查询历史）。
//

import SwiftUI
import MovoKit

public struct SearchScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    @State private var query = ""
    @State private var scope: SearchScope = .all
    @State private var recency: SearchRecency = .all
    @State private var results: SearchResultsView?

    public init() {}

    public var body: some View {
        ScreenScroll {
            ScreenChrome("搜索", subtitle: subtitle)

            MovoFormSection("") {
                MovoTextField("", text: $query, placeholder: "搜索计划、任务、行动记录、想法或结果")
                    .onSubmit { _Concurrency.Task { await search() } }
                MovoFormRow("范围") {
                    MovoRequiredChipRow(options: SearchScope.allCases, selection: $scope,
                                        label: \.displayName)
                }
                MovoFormRow("时间") {
                    MovoRequiredChipRow(options: SearchRecency.allCases, selection: $recency,
                                        label: \.displayName)
                }
                HStack(spacing: MovoSpace.s) {
                    MovoButton("搜索", systemImage: "magnifyingglass", kind: .primary) {
                        _Concurrency.Task { await search() }
                    }
                    if !query.isEmpty {
                        MovoButton("清空", kind: .quiet) {
                            query = ""
                            results = nil
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            if let results {
                if results.isEmpty {
                    MovoEmptyState(systemImage: "magnifyingglass",
                                   title: "没有找到匹配的内容",
                                   message: "可以换一个更短的关键词，或者去掉范围限制再试一次。")
                        .frame(minHeight: 240)
                } else {
                    ForEach(results.grouped, id: \.0) { pair in
                        SectionBlock(pair.0.displayName, trailing: "\(pair.1.count) 条") {
                            VStack(spacing: 0) {
                                ForEach(pair.1) { item in
                                    resultRow(item)
                                    if item.id != pair.1.last?.id {
                                        MovoDivider().padding(.leading, MovoSpace.m)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                if !query.isEmpty {
                    Text("按回车或点「搜索」开始查找。")
                        .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
            }
        }
        .movoPageBackground()
        .task(id: scope) {
            if results != nil { await search() }
        }
    }

    private var subtitle: String {
        guard let results, !results.isEmpty else { return "在全部内容里查找" }
        return "找到 \(results.totalCount) 条"
    }

    @ViewBuilder
    private func resultRow(_ item: SearchResult) -> some View {
        Button {
            open(item)
        } label: {
            HStack(alignment: .top, spacing: MovoSpace.s) {
                Image(systemName: icon(item.entityType))
                    .font(.system(size: 14))
                    .foregroundStyle(MovoColor.primary)
                    .frame(width: 22, height: 22)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: MovoSpace.xs) {
                    Text(item.title)
                        .font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let snippet = item.snippet, !snippet.isEmpty {
                        Text(snippet).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                            .lineLimit(2)
                    }
                    HStack(spacing: MovoSpace.xs) {
                        MovoTag(item.pathText, systemImage: "folder")
                        if let dateText = item.dateText { MovoTag(dateText, systemImage: "calendar") }
                        if let statusText = item.statusText { MovoTag(statusText) }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MovoColor.muted)
                    .padding(.top, 6)
            }
            .padding(.vertical, MovoSpace.s)
            .padding(.horizontal, MovoSpace.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(_ type: EntityType) -> String {
        switch type {
        case .plan, .stage: "square.stack.3d.up"
        case .task: "checklist"
        case .activity: "timer"
        case .measurement, .metric: "chart.line.uptrend.xyaxis"
        case .note: "text.bubble"
        case .capture: "tray.full"
        default: "doc.text"
        }
    }

    private func open(_ item: SearchResult) {
        switch item.entityType {
        case .task:
            router.push(.taskDetail(item.entityId))
        case .plan, .stage:
            router.push(.planDetail(item.planId ?? item.entityId))
        case .activity, .measurement, .metric, .note:
            if let planId = item.planId { router.push(.planDetail(planId)) }
        default:
            break
        }
    }

    private func search() async {
        results = await env.store.search(query: query, scope: scope, recency: recency)
    }
}

#Preview("搜索") {
    SearchScreen()
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
