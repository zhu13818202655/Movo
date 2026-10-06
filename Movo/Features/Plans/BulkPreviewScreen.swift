//
//  BulkPreviewScreen.swift
//  Features/Plans
//
//  D05-BulkPreview 批量影响预览。
//  先预览后确认：预览数字（含将解除的依赖数）必须与实际影响一致，
//  一次确认只提交一个 batch，之后可以整批撤销（P1 完成条件）。
//

import SwiftUI
import MovoKit

public struct BulkPreviewScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let title: String
    let entityIDs: [UUID]

    public enum Action: String, CaseIterable, Identifiable {
        case postponeOneDay, cancel

        public var id: String { rawValue }
        var displayName: String {
            switch self {
            case .postponeOneDay: "顺延一天"
            case .cancel: "取消这些任务"
            }
        }
        var systemImage: String {
            switch self {
            case .postponeOneDay: "calendar.badge.plus"
            case .cancel: "xmark.circle"
            }
        }
    }

    @State private var tasks: [Task] = []
    @State private var action: Action = .postponeOneDay
    @State private var isCommitting = false
    @State private var loaded = false

    public init(title: String, entityIDs: [UUID]) {
        self.title = title
        self.entityIDs = entityIDs
    }

    public var body: some View {
        Group {
            if loaded {
                content
            } else {
                LoadingPlaceholder("正在计算影响…")
            }
        }
        .movoPageBackground()
        .task { await load() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScreenScroll {
                ScreenChrome("批量影响预览", subtitle: title)

                if let error = env.lastError {
                    MovoBanner(error: error) { _ in env.lastError = nil }
                }

                MovoFormSection("要对这些内容做什么") {
                    MovoFormRow("操作") {
                        MovoRequiredChipRow(options: Action.allCases, selection: $action,
                                            label: \.displayName)
                    }
                    Text(actionFootnote).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                MovoFormSection("会影响哪些内容",
                                footnote: preview.undoNote) {
                    HStack(spacing: MovoSpace.s) {
                        StatusTag(text: preview.affectedCountText,
                                  foreground: MovoColor.warning, background: MovoColor.soft,
                                  systemImage: "square.stack.3d.up")
                        if preview.dependencyReleases > 0 {
                            MovoTag("会解除 \(preview.dependencyReleases) 项前置",
                                    systemImage: "arrow.triangle.branch")
                        }
                    }

                    if preview.affected.isEmpty {
                        Text("没有可以应用这项操作的内容。")
                            .font(MovoFont.body).foregroundStyle(MovoColor.muted)
                    } else {
                        ForEach(preview.affected) { line in
                            HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 11)).foregroundStyle(MovoColor.muted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.title).font(MovoFont.body).foregroundStyle(MovoColor.ink)
                                    Text(line.changeText).font(MovoFont.caption)
                                        .foregroundStyle(MovoColor.muted)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 30)
                        }
                    }
                }

                if !preview.unaffected.isEmpty {
                    MovoFormSection("不受影响") {
                        ForEach(preview.unaffected.prefix(10), id: \.self) { name in
                            HStack(spacing: MovoSpace.xs) {
                                Image(systemName: "minus.circle").font(.system(size: 11))
                                    .foregroundStyle(MovoColor.muted)
                                Text(name).font(MovoFont.body).foregroundStyle(MovoColor.muted)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 28)
                        }
                        if preview.unaffected.count > 10 {
                            Text("另有 \(preview.unaffected.count - 10) 项不变。")
                                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        }
                    }
                }
            }

            MovoActionBar {
                MovoButton("确认应用", kind: .primary,
                           isEnabled: !preview.affected.isEmpty && !isCommitting,
                           isLoading: isCommitting) {
                    _Concurrency.Task { await commit() }
                }
                MovoButton("取消", kind: .quiet) { router.pop() }
                Spacer(minLength: 0)
            }
        }
    }

    private var actionFootnote: String {
        switch action {
        case .postponeOneDay:
            return "把安排日期整体推到明天；硬截止不会跟着改变。"
        case .cancel:
            return "取消的任务不再计入进度，也不再阻断后续任务，历史记录会保留。"
        }
    }

    // MARK: - 预览

    private var preview: ImpactPreview {
        var lines: [ImpactPreview.ImpactLine] = []
        var unaffected: [String] = []
        let tomorrow = env.store.today.adding(days: 1)

        for task in tasks {
            switch action {
            case .postponeOneDay:
                guard task.status.isOpen, !task.isTemplate else {
                    unaffected.append(task.title); continue
                }
                let from = task.startAt?.displayString ?? "未安排"
                lines.append(.init(entityId: task.id, title: task.title,
                                   changeText: "开始时间 → \(tomorrow.displayString)",
                                   oldValue: from, newValue: tomorrow.displayString))
            case .cancel:
                guard task.status.isOpen else { unaffected.append(task.title); continue }
                lines.append(.init(entityId: task.id, title: task.title,
                                   changeText: "状态 待办 → 已取消",
                                   oldValue: task.status.displayName,
                                   newValue: TaskStatus.cancelled.displayName))
            }
        }

        let affectedIDs = Set(lines.map(\.entityId))
        var releases = 0
        let planIDs = Set(tasks.map(\.planId).compactMap { $0 })
        for planID in planIDs {
            releases += DependencyPolicy.previewReleases(
                removing: affectedIDs,
                planTasks: tasks.filter { $0.planId == planID })
        }

        return ImpactPreview(
            title: action.displayName,
            affected: lines,
            unaffected: unaffected,
            dependencyReleases: releases,
            undoNote: "确认后会作为一批提交，可一次撤销。",
            summaryText: "\(lines.count) 项会改变")
    }

    // MARK: - 提交

    private func commit() async {
        guard !isCommitting, !preview.affected.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }

        let affectedIDs = Set(preview.affected.map(\.entityId))
        let tomorrow = env.store.today.adding(days: 1)
        var commands: [any DomainCommand] = []

        for task in tasks where affectedIDs.contains(task.id) {
            switch action {
            case .postponeOneDay:
                commands.append(ScheduleTask(taskID: task.id, startAt: .day(tomorrow),
                                             baseRevision: task.revision))
            case .cancel:
                commands.append(CancelTask(taskID: task.id, baseRevision: task.revision,
                                           reason: action.displayName))
            }
        }

        guard !commands.isEmpty else { return }
        do {
            let result = try await env.store.executeBatch(BatchInput(
                commands: commands, summary: "\(action.displayName) \(commands.count) 项"))
            env.lastBatchNotice = env.store.lastNotification
            _ = result
            router.pop()
        } catch let error as MovoError {
            env.lastError = error
        } catch {
            env.lastError = .invalidStructure(reason: "这批操作没有完成。")
        }
    }

    private func load() async {
        tasks = await env.store.repository.tasks(ids: entityIDs)
        loaded = true
    }
}

#Preview("批量预览") {
    BulkPreviewScreen(title: "把 2 项顺延一天",
                      entityIDs: [DemoFixtures.IDs.writeDraft, DemoFixtures.IDs.reviseByFeedback])
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
