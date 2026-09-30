//
//  InboxScreen.swift
//  Features/Inbox
//
//  D05 / M05 收件箱。AI 无法确定归属时**不替用户选边**：
//  未归类项保留原文与候选计划（≤3 且带依据文案），由用户手动归类、保持独立或编辑解析。
//  同时收纳：待确认建议、校验未过项、同步冲突。
//

import SwiftUI
import MovoKit

public struct InboxScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    @State private var view: InboxView?
    @State private var plans: [PlanSummary] = []
    @State private var partiallyAppliedCaptures: Set<UUID> = []

    public init() {}

    public var body: some View {
        Group {
            if let view {
                content(view)
            } else {
                LoadingPlaceholder("正在读取收件箱…")
            }
        }
        .movoPageBackground()
        .task(id: env.store.dataVersion) { await reload() }
    }

    @ViewBuilder
    private func content(_ view: InboxView) -> some View {
        ScreenScroll {
            ScreenChrome("收件箱", subtitle: view.isEmpty ? "都处理完了" : "\(view.totalCount) 项待处理") {
                MovoButton("AI 整理", systemImage: "sparkles", kind: .secondary) {
                    router.present(.quickCapture)
                }
            }

            if view.isEmpty {
                MovoEmptyState(systemImage: "tray",
                               title: "收件箱是空的",
                               message: "整理不确定的内容会先放到这里，等你决定归属，不会替你选。",
                               actionTitle: "记下一件事",
                               action: { router.present(.quickCapture) })
                    .frame(minHeight: 300)
            } else {
                if !view.suggestions.isEmpty {
                    SectionBlock("待确认的建议", trailing: "\(view.suggestions.count) 项") {
                        VStack(spacing: MovoSpace.m) {
                            ForEach(view.suggestions) { suggestion in
                                SuggestionCard(
                                    title: suggestion.kind.displayName,
                                    reason: suggestion.planId.flatMap { id in
                                        plans.first { $0.id == id }.map { "来自「\($0.name)」" }
                                    },
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

                if !view.unclassified.isEmpty {
                    SectionBlock("还没有归类", trailing: "\(view.unclassified.count) 项") {
                        VStack(spacing: 0) {
                            ForEach(view.unclassified) { item in
                                unclassifiedRow(item)
                                if item.id != view.unclassified.last?.id {
                                    MovoDivider().padding(.leading, MovoSpace.m)
                                }
                            }
                        }
                    }
                }

                if !view.rejectedItems.isEmpty {
                    SectionBlock("需要你再确认", trailing: "\(view.rejectedItems.count) 项") {
                        VStack(spacing: 0) {
                            ForEach(view.rejectedItems) { item in
                                VStack(alignment: .leading, spacing: MovoSpace.xs) {
                                    Text(item.sourceSpan)
                                        .font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: MovoSpace.xs) {
                                        StatusTag(text: "未应用", foreground: MovoColor.warning,
                                                  background: MovoColor.soft,
                                                  systemImage: "exclamationmark.triangle")
                                        if let action = item.suggestedAction {
                                            MovoTag("原本想做：\(action)")
                                        }
                                    }
                                }
                                .padding(MovoSpace.s)
                            }
                        }
                    }
                }

                if !view.conflicts.isEmpty {
                    SectionBlock("同步冲突", trailing: "\(view.conflicts.count) 项") {
                        VStack(spacing: MovoSpace.m) {
                            ForEach(view.conflicts) { conflict in
                                conflictCard(conflict)
                            }
                        }
                        .padding(MovoSpace.s)
                    }
                }

                if let error = env.lastError {
                    MovoBanner(error: error) { _ in env.lastError = nil }
                }
            }
        }
    }

    // MARK: - 未归类行

    @ViewBuilder
    private func unclassifiedRow(_ item: InboxUnclassified) -> some View {
        let partiallyApplied = item.captureId.map { partiallyAppliedCaptures.contains($0) } ?? false
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            Text(item.sourceText)
                .font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: MovoSpace.xs) {
                if let hint = item.kindHint { MovoTag(hint, systemImage: "square.and.pencil") }
                if let reason = item.reasonText { MovoTag(reason, systemImage: "info.circle") }
                if item.hasAmbiguity { MovoTag("有多个可能归属") }
            }

            if !item.candidatesCapped.isEmpty {
                Text("可能的归属：" + item.candidatesCapped.joined(separator: "、"))
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }

            if let captureID = item.captureId {
                MovoButton("查看整理结果 / 继续处理", systemImage: "sparkles", kind: .secondary) {
                    env.activeCaptureID = captureID
                    router.present(.quickCapture)
                }
            }

            HStack(spacing: MovoSpace.s) {
                Menu {
                    ForEach(plans) { plan in
                        Button(plan.name) { _Concurrency.Task { await classify(item, to: plan) } }
                    }
                    Divider()
                    Button("不归入任何计划") { _Concurrency.Task { await classify(item, to: nil) } }
                } label: {
                    Text("归入计划").font(MovoFont.bodyEmphasis)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 110)
                .disabled(partiallyApplied)

                MovoButton("保留为想法", kind: .quiet, isEnabled: !partiallyApplied) { _Concurrency.Task { await keepAsNote(item) } }
                MovoButton("标记已处理", kind: .quiet) { _Concurrency.Task { await markHandled(item) } }
                Spacer(minLength: 0)
            }
            if partiallyApplied {
                Text("部分事项已保存，请打开整理结果继续处理剩余内容。")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
        }
        .padding(MovoSpace.s)
    }

    // MARK: - 冲突卡（双候选都保留）

    @ViewBuilder
    private func conflictCard(_ conflict: SyncConflict) -> some View {
        MovoCard {
            VStack(alignment: .leading, spacing: MovoSpace.s) {
                HStack(spacing: MovoSpace.s) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(MovoColor.warning)
                    Text("「\(conflict.field)」有两份版本")
                        .font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                }
                Text(describeConflict(conflict))
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: MovoSpace.xs) {
                    candidateRow(title: "这台设备",
                                 value: display(conflict.localValue),
                                 time: conflict.localChangedAt,
                                 device: conflict.localDeviceId)
                    candidateRow(title: "另一台设备",
                                 value: display(conflict.remoteValue),
                                 time: conflict.remoteChangedAt,
                                 device: conflict.remoteDeviceId)
                }

                HStack(spacing: MovoSpace.s) {
                    MovoButton("保留这台设备", kind: .primary) {
                        _Concurrency.Task { await resolve(conflict, choice: .local) }
                    }
                    MovoButton("保留另一台设备", kind: .secondary) {
                        _Concurrency.Task { await resolve(conflict, choice: .remote) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func candidateRow(title: String, value: String, time: Date, device: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
            Text(title).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                .frame(width: 84, alignment: .leading)
            Text(value).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
            Spacer(minLength: MovoSpace.s)
            Text(Self.timeText(time)).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
        }
    }

    private func describeConflict(_ conflict: SyncConflict) -> String {
        "解决前两份都会保留，选一个就好。\(conflict.entityType.displayName) · 基准版本 \(conflict.baseRev)"
    }

    private func display(_ value: JSONValue) -> String {
        if value.isNull { return "（空）" }
        return value.stringValue ?? String(describing: value)
    }

    static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh-Hans")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }

    // MARK: - 行为

    private func classify(_ item: InboxUnclassified, to plan: PlanSummary?) async {
        let title = Self.firstLine(item.sourceText)
        guard !title.isEmpty else { return }
        do {
            try await env.store.execute(CreateTask(title: title, planID: plan?.id,
                                                   source: .text, captureID: item.captureId))
            env.lastBatchNotice = env.store.lastNotification
            await markHandled(item)
        } catch let error as MovoError {
            env.lastError = error
        } catch { }
    }

    private func keepAsNote(_ item: InboxUnclassified) async {
        do {
            try await env.store.execute(CreateNote(text: item.sourceText, kind: .idea,
                                                   planID: nil, source: .text,
                                                   captureID: item.captureId))
            env.lastBatchNotice = env.store.lastNotification
            await markHandled(item)
        } catch let error as MovoError {
            env.lastError = error
        } catch { }
    }

    /// 标记已处理：原文保留，只是不再出现在收件箱（REQ 02）
    private func markHandled(_ item: InboxUnclassified) async {
        guard let captureID = item.captureId else { await reload(); return }
        await env.updateCaptureState(captureID, state: .aiSucceeded)
        await reload()
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

    private func resolve(_ conflict: SyncConflict, choice: ConflictResolution) async {
        do {
            try await env.store.execute(ResolveConflict(conflictID: conflict.id, choice: choice))
            env.lastBatchNotice = env.store.lastNotification
            await reload()
        } catch let error as MovoError {
            env.lastError = error
        } catch { }
    }

    private func reload() async {
        let inbox = await env.store.inbox()
        var applied: Set<UUID> = []
        for capture in inbox.pendingCaptures {
            if let batchID = capture.batchId,
               await env.store.repository.operations(batchID: batchID).contains(where: { $0.status == .applied }) {
                applied.insert(capture.id)
            }
        }
        partiallyAppliedCaptures = applied
        view = inbox
        plans = await env.store.plans(filter: PlanFilter(categories: [], statuses: [.active, .paused]))
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\n" || $0 == "。" || $0 == "；" })
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }
}

#Preview("收件箱") {
    InboxScreen()
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
