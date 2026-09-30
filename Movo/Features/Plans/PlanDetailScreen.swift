//
//  PlanDetailScreen.swift
//  Features/Plans
//
//  D02 Mac 工作计划与执行树 / M03 iPhone 健康计划 / M11 iPhone 工作计划树。
//  行动（执行树）／记录（行动记录）／成果（结果指标）三视图分开，不混淆。
//

import SwiftUI
import MovoKit

public struct PlanDetailScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let planID: UUID

    @State private var detail: PlanDetail?
    @State private var expanded: Set<String> = []
    @State private var tab: Tab = .actions
    @State private var activities: [ActionRecord] = []
    @State private var showHistory = false

    public enum Tab: String, CaseIterable, Hashable { case actions, records, results }

    public init(planID: UUID) { self.planID = planID }

    public var body: some View {
        Group {
            if let detail {
                content(detail)
            } else {
                LoadingPlaceholder("正在读取计划…")
            }
        }
        .movoPageBackground()
        .task { await reload() }
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(_ detail: PlanDetail) -> some View {
        ScreenScroll {
            ScreenChrome(detail.plan.name, subtitle: subtitle(detail)) {
                HStack(spacing: MovoSpace.s) {
                    Menu {
                        Button("编辑计划") { router.present(.editPlan(planID)) }
                        Button("查看历史") { router.push(.planHistory(planID)) }
                        if detail.plan.status == .active {
                            Button("暂停计划") { _Concurrency.Task { await pause(detail) } }
                        } else if detail.plan.status == .paused {
                            Button("恢复计划") { _Concurrency.Task { await resume(detail) } }
                        }
                        Button("归档计划") { _Concurrency.Task { await archive(detail) } }
                        Button("导出当前计划") { router.present(.exportPreview(planID: planID)) }
                        Divider()
                        Button(detail.plan.cloudAIEnabled ? "关闭云端 AI 处理" : "允许云端 AI 处理") {
                            _Concurrency.Task { await toggleCloudAI(detail) }
                        }
                        Button("删除计划", role: .destructive) { _Concurrency.Task { await delete(detail) } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(MovoColor.muted)
                            .frame(width: MovoSpace.minTouch, height: MovoSpace.minTouch)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: MovoSpace.minTouch)
                }
            }

            header(detail)

            if detail.plan.status != .active {
                MovoBanner(kind: .warning,
                           title: detail.plan.status == .paused ? "计划已暂停" : "计划已归档",
                           message: detail.plan.status == .paused
                               ? "暂停期间不实例化重复行动；恢复后会从当天继续。"
                               : "归档后不再出现在今日，历史与记录都保留。")
            }

            MovoSegmented(options: [
                (Tab.actions, "行动"), (Tab.records, "记录"), (Tab.results, "成果")
            ], selection: $tab)

            switch tab {
            case .actions: actionsTab(detail)
            case .records: recordsTab(detail)
            case .results: resultsTab(detail)
            }
        }
    }

    private func subtitle(_ detail: PlanDetail) -> String {
        var parts = [detail.plan.kind.displayName]
        if let category = detail.plan.category { parts.append(category.displayName) }
        parts.append(detail.progress.shortText)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func header(_ detail: PlanDetail) -> some View {
        SectionBlock("") {
            VStack(alignment: .leading, spacing: MovoSpace.s) {
                if let goal = detail.plan.goalText, !goal.isEmpty {
                    Text(goal).font(MovoFont.body).foregroundStyle(MovoColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: MovoSpace.s) {
                    PlanCategoryTag(detail.plan.category)
                    StatusTag(planStatus: detail.plan.status)
                    if let target = detail.plan.targetDate {
                        MovoTag("截止 \(target.displayString)", systemImage: "calendar")
                    }
                    if !detail.plan.cloudAIEnabled {
                        MovoTag("云端 AI 已关闭", systemImage: "lock")
                    }
                }
                if detail.progress.showsPercentage {
                    MovoProgressBar(fraction: detail.progress.fraction,
                                    caption: detail.progress.snapshotText)
                } else {
                    Text(detail.progress.snapshotText)
                        .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
                if let stage = detail.currentStage {
                    HStack(spacing: MovoSpace.xs) {
                        Image(systemName: "flag.fill").font(.system(size: 11))
                            .foregroundStyle(MovoColor.primary)
                        Text("当前阶段：\(stage.name)").font(MovoFont.captionEmphasis)
                            .foregroundStyle(MovoColor.ink)
                    }
                }
            }
            .padding(MovoSpace.s)
        }
    }

    // MARK: - 行动

    @ViewBuilder
    private func actionsTab(_ detail: PlanDetail) -> some View {
        HStack(spacing: MovoSpace.s) {
            MovoButton("记一次行动", systemImage: "plus", kind: .secondary) {
                _Concurrency.Task { await logActivity(detail) }
            }
            MovoButton("查看历史", systemImage: "clock.arrow.circlepath", kind: .quiet) {
                router.push(.planHistory(planID))
            }
            Spacer(minLength: 0)
        }

        if !detail.occurrences.isEmpty {
            SectionBlock("本周行动", trailing: "\(detail.weekActions.displayText)") {
                VStack(spacing: 0) {
                    ForEach(detail.occurrences) { summary in
                        HStack(spacing: MovoSpace.s) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(MovoColor.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.title).font(MovoFont.bodyEmphasis)
                                    .foregroundStyle(MovoColor.ink)
                                Text("\(summary.unitText) · 本周 \(summary.doneThisWeek)/\(summary.plannedThisWeek) 次")
                                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                            }
                            Spacer(minLength: MovoSpace.s)
                            if summary.pendingToday {
                                MovoTag("今天一次待进行", systemImage: "clock")
                            }
                            MovoButton("记录", kind: .quiet) {
                                _Concurrency.Task { await logActivity(detail) }
                            }
                        }
                        .padding(MovoSpace.s)
                    }
                }
            }
        }

        if detail.tree.nodes.isEmpty {
            SectionBlock("执行树") {
                Text("还没有任务。可以先加一条最小的下一步。")
                    .font(MovoFont.body).foregroundStyle(MovoColor.muted)
                    .padding(MovoSpace.s)
            }
        } else {
            SectionBlock("执行树", trailing: detail.tree.progressText) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(detail.tree.nodes) { node in
                        treeNode(node, depth: 0, detail: detail)
                    }
                }
                .padding(.vertical, MovoSpace.xs)
            }
        }
    }

    @ViewBuilder
    private func treeNode(_ node: PlanTreeNode, depth: Int, detail: PlanDetail) -> some View {
        let isExpanded = expanded.contains(node.id)
        StageTreeNodeRow(
            node: node, depth: depth, isExpanded: isExpanded,
            isSelected: false,
            onToggleExpand: {
                if isExpanded { expanded.remove(node.id) } else { expanded.insert(node.id) }
            },
            onTap: { open(node) })

        if isExpanded {
            ForEach(node.children) { child in
                // 递归调用经 AnyView 擦除，避免 opaque 返回类型自引用
                AnyView(treeNode(child, depth: depth + 1, detail: detail))
            }
            if node.kind.isTemplateNode {
                ForEach(node.currentOccurrences) { occurrence in
                    OccurrenceRow(occurrence: occurrence,
                                  taskTitle: node.title,
                                  periodText: nil,
                                  onToggle: { _Concurrency.Task { await toggleOccurrence(occurrence) } },
                                  onSkip: { _Concurrency.Task { await skipOccurrence(occurrence) } })
                        .padding(.leading, CGFloat(depth + 2) * MovoSpace.m)
                }
            }
        }
    }

    private func open(_ node: PlanTreeNode) {
        if let task = node.task { router.push(.taskDetail(task.id)) }
    }

    // MARK: - 记录

    @ViewBuilder
    private func recordsTab(_ detail: PlanDetail) -> some View {
        SectionBlock("最近记录", trailing: "\(activities.count) 条") {
            if activities.isEmpty {
                Text("这一周还没有记录。记录投入不等于任务已完成。")
                    .font(MovoFont.body).foregroundStyle(MovoColor.muted)
                    .padding(MovoSpace.s)
            } else {
                VStack(spacing: 0) {
                    ForEach(activities) { activity in
                        HStack(alignment: .top, spacing: MovoSpace.s) {
                            Image(systemName: "timer").foregroundStyle(MovoColor.primary)
                            VStack(alignment: .leading, spacing: MovoSpace.xs) {
                                Text(activityTitle(activity, detail: detail))
                                    .font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                                HStack(spacing: MovoSpace.xs) {
                                    MovoTag(timeText(activity.happenedAt.sortEpoch))
                                    if let minutes = activity.durationMinutes {
                                        MovoTag("\(minutes) 分钟")
                                    }
                                    if activity.isCorrection { MovoTag("已更正") }
                                    if activity.source == .ai { MovoTag("AI 整理", systemImage: "sparkles") }
                                }
                                if let text = activity.text, !text.isEmpty {
                                    Text(text).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(MovoSpace.s)
                    }
                }
            }
        }
    }

    private func activityTitle(_ activity: ActionRecord, detail: PlanDetail) -> String {
        if let taskID = activity.taskId,
           let task = detail.tree.nodes.first(where: { $0.task?.id == taskID })?.task {
            return task.title
        }
        return activity.text ?? "行动记录"
    }

    // MARK: - 成果

    @ViewBuilder
    private func resultsTab(_ detail: PlanDetail) -> some View {
        if detail.metrics.isEmpty {
            SectionBlock("结果指标") {
                Text("这个计划还没有结果指标。指标只用于记录，不构成健康结论。")
                    .font(MovoFont.body).foregroundStyle(MovoColor.muted)
                    .padding(MovoSpace.s)
            }
        } else {
            ForEach(detail.metrics) { metric in
                SectionBlock("") {
                    VStack(alignment: .leading, spacing: MovoSpace.s) {
                        if let trend = detail.trends.first(where: { $0.metricId == metric.id }) {
                            MetricTrendChart(trend)
                        } else {
                            Text(metric.name).font(MovoFont.headline).foregroundStyle(MovoColor.ink)
                        }
                        HStack(spacing: MovoSpace.s) {
                            MovoButton("记录一次", kind: .secondary) {
                                router.present(.logMeasurement(metricID: metric.id))
                            }
                            MovoButton("查看历史", kind: .quiet) {
                                router.push(.metricHistory(metricID: metric.id))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(MovoSpace.s)
                }
            }
        }
    }

    // MARK: - 行为

    private func toggleOccurrence(_ occurrence: RecurrenceOccurrence) async {
        do {
            if occurrence.status == .done {
                try await env.store.execute(SkipOccurrence(occurrenceID: occurrence.id,
                                                           at: .precise(env.store.now),
                                                           baseRevision: occurrence.revision))
            } else {
                try await env.store.execute(CompleteOccurrence(occurrenceID: occurrence.id,
                                                               at: .precise(env.store.now),
                                                               baseRevision: occurrence.revision))
            }
            env.lastBatchNotice = env.store.lastNotification
            await reload()
        } catch let error as MovoError { env.lastError = error } catch { }
    }

    private func skipOccurrence(_ occurrence: RecurrenceOccurrence) async {
        _ = try? await env.store.execute(SkipOccurrence(occurrenceID: occurrence.id,
                                                    at: .precise(env.store.now),
                                                    baseRevision: occurrence.revision))
        await reload()
    }

    private func logActivity(_ detail: PlanDetail) async {
        do {
            try await env.store.execute(LogActivity(
                planID: planID, happenedAt: .precise(env.store.now),
                durationMinutes: nil, text: nil, source: .manual))
            env.lastBatchNotice = env.store.lastNotification
            await reload()
        } catch let error as MovoError { env.lastError = error } catch { }
    }

    private func pause(_ detail: PlanDetail) async {
        _ = try? await env.store.execute(PausePlan(planID: planID, from: env.store.today,
                                               baseRevision: detail.plan.revision))
        await reload()
    }

    private func resume(_ detail: PlanDetail) async {
        _ = try? await env.store.execute(ResumePlan(planID: planID, from: env.store.today,
                                                baseRevision: detail.plan.revision))
        await reload()
    }

    private func archive(_ detail: PlanDetail) async {
        var patch = PlanPatch()
        patch.status = .archived
        _ = try? await env.store.execute(UpdatePlan(planID: planID, patch: patch,
                                                baseRevision: detail.plan.revision))
        await reload()
    }

    private func toggleCloudAI(_ detail: PlanDetail) async {
        var patch = PlanPatch()
        patch.cloudAIEnabled = !detail.plan.cloudAIEnabled
        _ = try? await env.store.execute(UpdatePlan(planID: planID, patch: patch,
                                                baseRevision: detail.plan.revision))
        await reload()
    }

    private func delete(_ detail: PlanDetail) async {
        _ = try? await env.store.execute(DeletePlan(planID: planID, baseRevision: detail.plan.revision))
        router.pop()
    }

    private func reload() async {
        detail = await env.store.planDetail(planID)
        activities = (await env.store.repository.activities(planID: planID))
            .sorted { $0.happenedAt.sortEpoch > $1.happenedAt.sortEpoch }
        // 默认展开当前阶段
        if expanded.isEmpty, let stage = detail?.currentStage { expanded.insert(stage.id.uuidString) }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

extension PlanTreeNode.Kind {
    var isTemplateNode: Bool {
        if case .task(let task) = self { return task.isTemplate }
        return false
    }
}
