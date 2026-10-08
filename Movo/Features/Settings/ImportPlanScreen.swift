//
//  ImportPlanScreen.swift
//  Features/Settings
//
//  M13-Import 导入 Movo 文件（.movo.json）。
//  选择文件 → 解析与预演 → 预览（将创建什么、哪些条目不合法）→ 确认后作为一个批次写入，可撤销。
//  · 校验与手动创建走同一套 StructurePolicy；不合法的条目逐条标出，不静默丢弃。
//  · 已经导入过（或原数据还在）的计划默认跳过，也可以选择另存一份。
//  · 文件里单独的内容可以放进已有计划，待办还可以放在计划里某个任务下。
//  · 双端共用同一份文件与解析逻辑。
//

import SwiftUI
import MovoKit
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public struct ImportPlanScreen: View {
    @Environment(AppEnvironment.self) private var env
    /// 关闭本页：本页从设置里被压入导航栈，也可能作为 `.importPlan` 浮层出现。
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var fileName: String?
    @State private var file: PlanFile?
    @State private var plan: PlanImportPlan?
    @State private var duplicateMode: PlanImportDuplicateMode = .skip
    @State private var plans: [Plan] = []
    @State private var targetPlanID: UUID?
    @State private var targetTaskID: UUID?
    @State private var parentCandidates: [ImportParentCandidate] = []
    @State private var loadError: String?
    @State private var isWorking = false
    @State private var resultMessage: String?

    /// 单个文件上限：计划文件是纯文本结构，远小于这个值
    private static let maxFileBytes = 5 * 1024 * 1024

    public init() {}

    public var body: some View {
        ScreenScroll {
            ScreenChrome("导入 Movo 文件", subtitle: "读取 .movo.json，先预览再写入") {
                #if !os(macOS)
                MovoIconButton("xmark", label: "关闭") { dismiss() }
                #endif
            }

            pickSection

            if let loadError {
                MovoBanner(kind: .warning, title: "这个文件不能导入", message: loadError)
            }

            if let resultMessage {
                MovoBanner(kind: .info, title: "导入完成", message: resultMessage)
            }

            if isWorking && plan == nil {
                LoadingPlaceholder("正在检查文件内容…")
            }

            if let plan {
                targetSection
                summarySection(plan)
                duplicateSection(plan)
                issueSection(plan)
                confirmSection(plan)
            }
        }
        .movoPageBackground()
        .task(id: env.pendingImportURL) {
            guard let url = env.pendingImportURL else { return }
            env.pendingImportURL = nil
            await load(url)
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: importTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { _Concurrency.Task { await load(url) } }
            case .failure:
                loadError = "没有选中文件，请重试。"
            }
        }
        .onChange(of: duplicateMode) { _, _ in
            _Concurrency.Task { await rebuild() }
        }
        .onChange(of: targetPlanID) { _, newValue in
            targetTaskID = nil
            _Concurrency.Task {
                if let newValue {
                    parentCandidates = await PlanFileImporter.parentCandidates(planID: newValue, store: env.store)
                } else {
                    parentCandidates = []
                }
                await rebuild()
            }
        }
        .onChange(of: targetTaskID) { _, _ in
            _Concurrency.Task { await rebuild() }
        }
    }

    private var importTypes: [UTType] {
        #if canImport(UniformTypeIdentifiers)
        [.json, .plainText]
        #else
        []
        #endif
    }

    // MARK: - 区块

    private var pickSection: some View {
        MovoFormSection("选择文件",
                        footnote: "文件里的 id 只用来互相引用和识别重复导入，导入时会生成新的实体 id。") {
            HStack(spacing: MovoSpace.s) {
                MovoButton(file == nil ? "选择文件" : "换一个文件", systemImage: "doc.badge.plus",
                           kind: .primary) {
                    showPicker = true
                }
                if let fileName { MovoTag(fileName, systemImage: "doc") }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var targetSection: some View {
        if let file, PlanFileImporter.hasLooseContent(file) {
            MovoFormSection("导入到",
                            footnote: PlanFileImporter.needsTargetPlan(file)
                                ? "文件里有单独的阶段、指标或记录，需要选择放进哪个已有计划。"
                                : "文件里单独的待办和笔记可以放进已有计划，也可以不属于任何计划。") {
                MovoFormRow("计划") {
                    Picker("", selection: $targetPlanID) {
                        Text("不放进计划").tag(UUID?.none)
                        ForEach(plans) { plan in Text(plan.name).tag(UUID?.some(plan.id)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                if targetPlanID != nil, !(file.tasks ?? []).isEmpty {
                    MovoFormRow("放在哪个任务下", subtitle: "文件里的待办会作为它的子任务") {
                        Picker("", selection: $targetTaskID) {
                            Text("计划下的顶层").tag(UUID?.none)
                            ForEach(parentCandidates) { candidate in
                                Text(String(repeating: "　", count: candidate.depth) + candidate.title)
                                    .tag(UUID?.some(candidate.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }
        }
    }

    private func summarySection(_ plan: PlanImportPlan) -> some View {
        let s = plan.summary
        return MovoFormSection("将会创建",
                               footnote: plan.canImport ? "确认后作为一个批次写入，结果条里可以撤销。" : "没有可以导入的内容。") {
            MovoInfoRow("计划", value: "\(s.plans) 个", systemImage: "square.stack.3d.up")
            MovoInfoRow("阶段", value: "\(s.stages) 个", systemImage: "flag")
            MovoInfoRow("待办", value: "\(s.tasks) 项", systemImage: "checklist")
            MovoInfoRow("重复行动", value: "\(s.recurring) 项（步骤 \(s.steps) 个）",
                        systemImage: "arrow.triangle.2.circlepath")
            MovoInfoRow("结果指标", value: "\(s.metrics) 个", systemImage: "chart.line.uptrend.xyaxis")
            if s.records + s.measurements + s.notes > 0 {
                MovoInfoRow("记录与笔记",
                            value: "行动记录 \(s.records)、测量值 \(s.measurements)、笔记 \(s.notes)",
                            systemImage: "note.text")
            }
        }
    }

    @ViewBuilder
    private func duplicateSection(_ plan: PlanImportPlan) -> some View {
        if !plan.summary.skippedDuplicates.isEmpty || duplicateMode == .saveCopy {
            MovoFormSection("重复导入",
                            footnote: "文件里的 id 与已有数据相同，说明这份内容已经导入过，或者原数据还在（也可能在最近删除里）。") {
                if !plan.summary.skippedDuplicates.isEmpty {
                    ForEach(plan.summary.skippedDuplicates, id: \.self) { name in
                        Text("已跳过：\(name)").font(MovoFont.body).foregroundStyle(MovoColor.muted)
                    }
                }
                MovoFormRow("处理方式") {
                    MovoRequiredChipRow(options: PlanImportDuplicateMode.allCases, selection: $duplicateMode,
                                        label: \.displayName)
                }
            }
        } else {
            MovoFormSection("重复导入", footnote: "默认跳过已经导入过的内容；想再要一份时选「另存一份」。") {
                MovoFormRow("处理方式") {
                    MovoRequiredChipRow(options: PlanImportDuplicateMode.allCases, selection: $duplicateMode,
                                        label: \.displayName)
                }
            }
        }
    }

    @ViewBuilder
    private func issueSection(_ plan: PlanImportPlan) -> some View {
        if !plan.issues.isEmpty {
            SectionBlock("需要注意", trailing: "\(plan.errorCount) 个错误 · \(plan.warningCount) 个提示") {
                VStack(spacing: 0) {
                    ForEach(plan.issues) { issue in
                        HStack(alignment: .top, spacing: MovoSpace.s) {
                            Image(systemName: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                .foregroundStyle(issue.severity == .error ? MovoColor.danger : MovoColor.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.path).font(MovoFont.captionEmphasis).foregroundStyle(MovoColor.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(issue.message).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(MovoSpace.s)
                        MovoDivider().padding(.leading, MovoSpace.m)
                    }
                }
            }
            if plan.errorCount > 0 {
                Text("有错误的条目不会导入，其余通过检查的内容仍然可以导入。")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
        }
    }

    private func confirmSection(_ plan: PlanImportPlan) -> some View {
        HStack(spacing: MovoSpace.s) {
            MovoButton("确认导入", systemImage: "checkmark", kind: .primary,
                       isEnabled: plan.canImport, isLoading: isWorking) {
                _Concurrency.Task { await apply(plan) }
            }
            MovoButton("取消", kind: .quiet) {
                self.plan = nil; file = nil; fileName = nil; loadError = nil
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 动作

    private func load(_ url: URL) async {
        loadError = nil
        resultMessage = nil
        plan = nil
        isWorking = true
        defer { isWorking = false }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxFileBytes else {
                loadError = "文件太大了（超过 5 MB），请拆分后再导入。"
                return
            }
            let data = try Data(contentsOf: url)
            let parsed = try PlanFileImporter.load(data)
            file = parsed
            fileName = url.lastPathComponent
            targetPlanID = nil
            targetTaskID = nil
            parentCandidates = []
            let deleted = Set(await env.store.repository.tombstones(activeOnly: true).map(\.entityId))
            plans = await env.store.repository.allPlans()
                .filter { $0.status != .archived && !deleted.contains($0.id) }
                .sorted { $0.updatedAt > $1.updatedAt }
            plan = await PlanFileImporter.makePlan(file: parsed, store: env.store,
                                                   duplicateMode: duplicateMode)
        } catch let error as PlanFileError {
            file = nil
            loadError = error.message
        } catch {
            file = nil
            loadError = "没有读到这个文件，请确认它在本机或 iCloud 里可以打开。"
        }
    }

    private func rebuild() async {
        guard let file else { return }
        plan = await PlanFileImporter.makePlan(file: file, store: env.store, duplicateMode: duplicateMode,
                                               targetPlanID: targetPlanID, targetTaskID: targetTaskID)
    }

    private func apply(_ plan: PlanImportPlan) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await PlanFileImporter.apply(plan, store: env.store)
            env.lastBatchNotice = env.store.lastNotification
            resultMessage = result.rejected.isEmpty
                ? "\(result.summary)"
                : "\(result.summary)。有 \(result.rejected.count) 项写入时没有通过，已保持原样。"
            self.plan = nil
            file = nil
            fileName = nil
        } catch let error as MovoError {
            env.lastError = error
        } catch {
            loadError = "导入没有成功，请重试。"
        }
    }
}
