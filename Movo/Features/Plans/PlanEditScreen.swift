//
//  PlanEditScreen.swift
//  Features/Plans
//
//  M08-NewPlan 新建计划 / M08-EditPlan 编辑计划。
//  名称是唯一必填项（REQ 07）；可同时建立阶段与结果指标；
//  计划设置只保留「同步到 iCloud」；是否把内容发给模型由全局 AI 开关决定（6.3）。
//

import SwiftUI
import MovoKit

public struct PlanEditScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router
    /// 关闭本页：本页由 `.newPlan` / `.editPlan` 以浮层呈现，也可能被压入导航栈。
    /// 用 SwiftUI 的 dismiss 让两种呈现方式都能正确关闭（`Router.pop()` 只作用于导航栈）。
    @Environment(\.dismiss) private var dismiss

    let planID: UUID?

    // MARK: 草稿

    @State private var name = ""
    @State private var kind: PlanKind = .delivery
    @State private var category: PlanCategory?
    @State private var goal = ""
    @State private var startDraft = TimePointDraft()
    @State private var endDraft = TimePointDraft()
    @State private var syncEnabled = true
    @State private var aliasesText = ""
    @State private var contextPhrasesText = ""
    @State private var stages: [StageDraftRow] = []
    @State private var metrics: [MetricDraftRow] = []

    @State private var originalPlan: Plan?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var nameError: String?

    struct StageDraftRow: Identifiable, Hashable {
        var id = UUID()
        var existingID: UUID?
        var version: Int = 1
        var name = ""
        var criteria = ""
        var startDraft = TimePointDraft()
        var endDraft = TimePointDraft()
    }

    struct MetricDraftRow: Identifiable, Hashable {
        var id = UUID()
        var existingID: UUID?
        var name = ""
        var unit = ""
        var targetText = ""
        var direction: MetricDirection = .none
    }

    public init(planID: UUID?) { self.planID = planID }

    private var isEditing: Bool { planID != nil }
    private var timeZone: TimeZone { env.store.currentTimeZone }

    // MARK: - Body

    public var body: some View {
        Group {
            if isLoading {
                LoadingPlaceholder("正在准备…")
            } else {
                content
            }
        }
        .movoPageBackground()
        .task { await load() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScreenScroll {
                ScreenChrome(isEditing ? "编辑计划" : "新建计划",
                             subtitle: "只有名称是必填的，其它都可以稍后再补。")

                if let error = env.lastError {
                    MovoBanner(error: error) { _ in env.lastError = nil }
                }

                MovoFormSection("基本信息") {
                    MovoTextField("计划名称（必填）", text: $name,
                                  placeholder: "例如：Q3 汇报", errorMessage: nameError)
                    MovoFormRow("计划类型") {
                        MovoRequiredChipRow(options: PlanKind.allCases,
                                            selection: $kind,
                                            label: \.displayName)
                    }
                    MovoFormRow("分类（可选）") {
                        MovoChipRow(options: PlanCategory.allCases,
                                    selection: $category,
                                    label: \.displayName)
                    }
                    MovoTextField("一句话目标（可选）", text: $goal,
                                  placeholder: "写清想达到的样子，之后更容易判断进展。",
                                  axis: .vertical)
                }

                MovoFormSection("时间", footnote: kind.requiresEndDate
                                ? "交付型与改善型建议设定结束时间；阶段和任务的时间必须落在计划范围内。"
                                : "持续型没有结束日期，也不需要强制阶段。") {
                    MovoTimePointField("开始时间", placeholder: "未设定", draft: $startDraft, timeZone: timeZone)
                    MovoTimePointField("结束时间", placeholder: "未设定", draft: $endDraft, timeZone: timeZone)
                }

                MovoFormSection("阶段（可选）",
                                footnote: "阶段的达成只由你确认，AI 不会替你判断。") {
                    ForEach(stages.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: MovoSpace.s) {
                            MovoTextField("阶段 \(index + 1) 名称", text: $stages[index].name,
                                          placeholder: "例如：结构定稿")
                            MovoTextField("达成条件（可选）", text: $stages[index].criteria,
                                          placeholder: "例如：7 个叶子任务全部完成",
                                          axis: .vertical)
                            MovoTimePointField("阶段开始时间", placeholder: "未设定",
                                               draft: $stages[index].startDraft, timeZone: timeZone)
                            MovoTimePointField("阶段结束时间", placeholder: "未设定",
                                               draft: $stages[index].endDraft, timeZone: timeZone)
                            HStack {
                                Spacer(minLength: 0)
                                if stages[index].existingID == nil {
                                    MovoIconButton("minus.circle", label: "移除这个阶段",
                                                   tint: MovoColor.danger) {
                                        stages.remove(at: index)
                                    }
                                }
                            }
                            if index < stages.count - 1 { MovoDivider() }
                        }
                    }
                    MovoButton("添加阶段", systemImage: "plus", kind: .quiet) {
                        stages.append(StageDraftRow())
                    }
                }

                MovoFormSection("结果指标（可选）",
                                footnote: "指标只用于记录实际测量，缺测留空，不构成健康结论。") {
                    ForEach(metrics.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: MovoSpace.s) {
                            HStack(spacing: MovoSpace.s) {
                                MovoTextField("指标名称", text: $metrics[index].name,
                                              placeholder: "例如：体重")
                                MovoTextField("单位", text: $metrics[index].unit,
                                              placeholder: "kg")
                            }
                            MovoNumberField("参考目标值（可选，仅录入用）",
                                            text: $metrics[index].targetText,
                                            placeholder: "例如：68",
                                            unitText: metrics[index].unit.isEmpty
                                                ? nil : PlanMetric.unitDisplayName(for: metrics[index].unit))
                            MovoFormRow("方向（仅展示）") {
                                MovoRequiredChipRow(options: MetricDirection.allCases,
                                                    selection: $metrics[index].direction,
                                                    label: \.displayName)
                            }
                            HStack {
                                Spacer(minLength: 0)
                                if metrics[index].existingID == nil {
                                    MovoIconButton("minus.circle", label: "移除这个指标",
                                                   tint: MovoColor.danger) {
                                        metrics.remove(at: index)
                                    }
                                }
                            }
                            if index < metrics.count - 1 { MovoDivider() }
                        }
                    }
                    MovoButton("添加结果指标", systemImage: "plus", kind: .quiet) {
                        metrics.append(MetricDraftRow())
                    }
                }

                MovoFormSection("同步") {
                    Toggle(isOn: $syncEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("同步此计划到 iCloud").font(MovoFont.bodyEmphasis)
                                .foregroundStyle(MovoColor.ink)
                            Text("关闭后仅保存在此设备上。")
                                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)

                    MovoTextField("别名（用逗号分隔，可选）", text: $aliasesText,
                                  placeholder: "例如：季度汇报, Q3")
                    MovoTextField("常用表达（用逗号分隔，可选）", text: $contextPhrasesText,
                                  placeholder: "例如：汇报材料, 汇报稿")
                }

                MovoFormSection("危险操作") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("删除计划").font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                            Text("删除后有 \(env.defaults.lifecycle.tombstoneRetentionDays) 天可以恢复。")
                                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        }
                        Spacer(minLength: MovoSpace.s)
                        MovoButton("删除", kind: .destructive, isEnabled: isEditing) {
                            _Concurrency.Task { await deletePlan() }
                        }
                    }
                }
            }

            MovoActionBar {
                MovoButton(isEditing ? "保存修改" : "建立计划", kind: .primary,
                           isEnabled: canSave, isLoading: isSaving) {
                    _Concurrency.Task { await save() }
                }
                MovoButton("取消", kind: .quiet) { dismiss() }
                Spacer(minLength: 0)
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    // MARK: - 载入

    private func load() async {
        defer { isLoading = false }
        guard let planID, let plan = await env.store.repository.plan(planID) else {
            if planID != nil { env.lastError = .notFound(entityType: .plan, id: planID) }
            return
        }
        originalPlan = plan
        name = plan.name
        kind = plan.kind
        category = plan.category
        goal = plan.goalText ?? ""
        syncEnabled = plan.syncEnabled
        aliasesText = plan.aliases.joined(separator: ", ")
        contextPhrasesText = plan.contextPhrases.joined(separator: ", ")
        startDraft = TimePointDraft(plan.startAt, fallback: env.store.now)
        endDraft = TimePointDraft(plan.endAt, fallback: env.store.now)
        let existingStages = await env.store.repository.stages(planID: planID)
            .sorted { $0.sortIndex < $1.sortIndex }
        stages = existingStages.map {
            StageDraftRow(existingID: $0.id, version: $0.version,
                          name: $0.name, criteria: $0.criteriaText ?? "",
                          startDraft: TimePointDraft($0.startAt, fallback: env.store.now),
                          endDraft: TimePointDraft($0.endAt, fallback: env.store.now))
        }
        let existingMetrics = await env.store.repository.metrics(planID: planID)
        metrics = existingMetrics.map {
            MetricDraftRow(existingID: $0.id, name: $0.name, unit: $0.unit,
                           targetText: $0.targetValue.map(Self.numberText) ?? "",
                           direction: $0.targetDirection)
        }
    }

    // MARK: - 保存

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            nameError = "计划需要一个名称，例如「Q3 汇报」。"
            return
        }
        guard trimmedName.count <= 120 else {
            nameError = "名称有点长，建议控制在 120 字以内。"
            return
        }
        nameError = nil
        isSaving = true
        defer { isSaving = false }

        let start = startDraft.point(in: timeZone)
        let end = endDraft.point(in: timeZone)
        let aliases = Self.splitList(aliasesText)
        let phrases = Self.splitList(contextPhrasesText)

        do {
            if let planID, let original = originalPlan {
                var patch = PlanPatch()
                patch.name = trimmedName
                patch.kind = kind
                patch.category = category
                patch.goalText = goal
                patch.startAt = start
                patch.endAt = end
                patch.clearStartAt = start == nil
                patch.clearEndAt = end == nil
                patch.aliases = aliases
                patch.contextPhrases = phrases
                patch.syncEnabled = syncEnabled
                try await env.store.execute(UpdatePlan(planID: planID, patch: patch,
                                                       baseRevision: original.revision))
                try await saveStages(planID: planID)
                try await saveMetrics(planID: planID)
            } else {
                var drafts: [StageDraft] = []
                var metricDrafts: [MetricDraft] = []
                for row in stages where !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drafts.append(StageDraft(name: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                             criteriaText: row.criteria.isEmpty ? nil : row.criteria,
                                             startAt: row.startDraft.point(in: timeZone),
                                             endAt: row.endDraft.point(in: timeZone)))
                }
                for row in metrics where !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    metricDrafts.append(MetricDraft(
                        name: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                        unit: row.unit.isEmpty ? "count" : row.unit,
                        targetValue: Double(row.targetText),
                        targetDirection: row.direction))
                }
                try await env.store.execute(CreatePlan(
                    name: trimmedName, kind: kind, category: category,
                    goal: goal.isEmpty ? nil : goal, startAt: start, endAt: end,
                    stages: drafts, metrics: metricDrafts,
                    aliases: aliases, contextPhrases: phrases,
                    syncEnabled: syncEnabled))
            }
            env.lastBatchNotice = env.store.lastNotification
            dismiss()
        } catch let error as MovoError {
            env.lastError = error
        } catch {
            env.lastError = .invalidStructure(reason: "没有保存成功，请稍后重试。")
        }
    }

    private func saveStages(planID: UUID) async throws {
        let existing = await env.store.repository.stages(planID: planID)
        let kept = Set(stages.compactMap(\.existingID))
        for (index, row) in stages.enumerated() {
            let trimmed = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let criteria = row.criteria.isEmpty ? nil : row.criteria
            let start = row.startDraft.point(in: timeZone)
            let end = row.endDraft.point(in: timeZone)
            if let id = row.existingID {
                guard let current = existing.first(where: { $0.id == id }) else { continue }
                var patch = StagePatch()
                if current.name != trimmed { patch.name = trimmed }
                if current.criteriaText != criteria { patch.criteriaText = criteria ?? "" }
                if current.startAt != start { patch.startAt = start; patch.clearStartAt = start == nil }
                if current.endAt != end { patch.endAt = end; patch.clearEndAt = end == nil }
                if current.sortIndex != index { patch.sortIndex = index }
                guard !(patch.name == nil && patch.criteriaText == nil && patch.sortIndex == nil
                        && patch.startAt == nil && patch.endAt == nil
                        && !patch.clearStartAt && !patch.clearEndAt) else { continue }
                try await env.store.execute(UpdateStage(stageID: id, patch: patch,
                                                        baseRevision: current.revision))
            } else {
                try await env.store.execute(CreateStage(planID: planID, name: trimmed,
                                                        criteriaText: criteria, startAt: start, endAt: end,
                                                        sortIndex: index))
            }
        }
        // 被移除的阶段只做「不再出现在编辑列表中」处理，历史与记录保留
        _ = kept
    }

    private func saveMetrics(planID: UUID) async throws {
        let existing = await env.store.repository.metrics(planID: planID)
        for row in metrics {
            let trimmed = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let unit = row.unit.isEmpty ? "count" : row.unit
            let target = Double(row.targetText)
            if let id = row.existingID, let current = existing.first(where: { $0.id == id }) {
                var patch = MetricPatch()
                if current.name != trimmed { patch.name = trimmed }
                if current.unit != unit { patch.unit = unit }
                if current.targetValue != target {
                    if target == nil { patch.clearTargetValue = true } else { patch.targetValue = target }
                }
                if current.targetDirection != row.direction { patch.targetDirection = row.direction }
                guard !(patch.name == nil && patch.unit == nil
                        && patch.targetValue == nil && patch.targetDirection == nil
                        && !patch.clearTargetValue) else { continue }
                try await env.store.execute(UpdateMetric(metricID: id, patch: patch,
                                                         baseRevision: current.revision))
            } else {
                try await env.store.execute(CreateMetric(planID: planID, name: trimmed, unit: unit,
                                                         targetValue: target,
                                                         targetDirection: row.direction))
            }
        }
    }

    private func deletePlan() async {
        guard let planID, let original = originalPlan else { return }
        do {
            try await env.store.execute(DeletePlan(planID: planID, baseRevision: original.revision))
            env.lastBatchNotice = env.store.lastNotification
            dismiss()
            // 计划已经不在：下面那层「计划详情」也一起收起，不要停在一个读不到内容的页面
            if router.path(for: router.section).last == .planDetail(planID) { router.pop() }
        } catch let error as MovoError {
            env.lastError = error
        } catch { }
    }

    // MARK: - 工具

    static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func numberText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

#Preview("新建计划") {
    PlanEditScreen(planID: nil)
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
