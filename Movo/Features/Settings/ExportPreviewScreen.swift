//
//  ExportPreviewScreen.swift
//  Features/Settings
//
//  M13-Export / M13-Export-Details：导出预览（T1.8 / REQ 16）。
//  · 范围：当前计划（从计划详情进入）或全部计划 + 独立待办（从设置进入）。
//  · 格式：Markdown / Movo 文件（.movo.json）；Movo 文件可由「导入」读回。
//  · 默认只导出结构和计划内容；行动记录、测量值、笔记默认不勾选，由用户自己打开。
//  · 空数据不填充虚构内容：没有内容时给出空状态，而不是造样本。
//

import SwiftUI
import MovoKit
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct ExportPreviewScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    /// nil = 导出全部计划
    let planID: UUID?

    @State private var format: ExportFormat = .json
    @State private var includeRecords = false
    @State private var includeMeasurements = false
    @State private var includeNotes = false
    @State private var bundle: ExportBundle?
    @State private var shareURL: URL?
    @State private var planName: String?
    @State private var isLoading = true
    @State private var copied = false
    @State private var isExporting = false
    @State private var savedMessage: String?

    public init(planID: UUID?) { self.planID = planID }

    // MARK: - 素材聚合（与设置页共用）

    /// 读取本地全量数据并生成导出包。纯读取，不写入任何内容。
    public static func makeBundle(env: AppEnvironment, planID: UUID?,
                                  format: ExportFormat,
                                  options: PlanFileOptions) async -> ExportBundle {
        let repository = env.store.repository
        let deleted = Set(await repository.tombstones(activeOnly: true).map(\.entityId))
        let plans = await repository.allPlans().filter { !deleted.contains($0.id) }
        let tasks = await repository.allTasks().filter { !deleted.contains($0.id) }
        let notes = await repository.allNotes().filter { !deleted.contains($0.id) }
        let activities = await repository.allActivities().filter { !deleted.contains($0.id) }
        let measurements = await repository.allMeasurements().filter { !deleted.contains($0.id) }
        let rules = await repository.rules().filter { !deleted.contains($0.id) }

        var stages: [Stage] = []
        var metrics: [PlanMetric] = []
        var occurrences: [RecurrenceOccurrence] = []
        for plan in plans {
            stages += await repository.stages(planID: plan.id).filter { !deleted.contains($0.id) }
            metrics += await repository.metrics(planID: plan.id).filter { !deleted.contains($0.id) }
            occurrences += await repository.occurrences(planID: plan.id).filter { !deleted.contains($0.id) }
        }

        let scope = ExportService.gather(
            plans: plans, stages: stages, tasks: tasks, metrics: metrics,
            measurements: measurements, activities: activities, notes: notes,
            occurrences: occurrences, rules: rules, onlyPlanID: planID)

        return ExportService.export(scope, format: format, options: options,
                                    generatedAt: env.store.now,
                                    timeZone: env.store.currentTimeZone)
    }

    private var options: PlanFileOptions {
        PlanFileOptions(includeRecords: includeRecords, includeMeasurements: includeMeasurements,
                        includeNotes: includeNotes)
    }

    // MARK: - Body

    public var body: some View {
        ScreenScroll {
            ScreenChrome(title, subtitle: subtitle) {
                #if !os(macOS)
                MovoIconButton("xmark", label: "关闭") { router.dismissSheet() }
                #endif
            }

            if isLoading {
                LoadingPlaceholder("正在汇总要导出的内容…")
            } else if let bundle, bundle.isEmpty {
                MovoEmptyState(systemImage: "tray",
                               title: "没有可导出的内容",
                               message: "这个范围内还没有计划或待办可以导出。先建一个再来。")
                optionsSection
            } else if let bundle {
                optionsSection

                MovoFormSection("这次导出会包含", footnote: bundle.summaryText) {
                    MovoInfoRow("范围", value: planID == nil ? "全部计划和独立待办" : "当前计划", systemImage: "scope")
                    MovoInfoRow("格式", value: format.displayName, systemImage: "doc.text")
                    MovoInfoRow("计划数", value: "\(bundle.includedPlanNames.count) 个",
                                systemImage: "square.stack.3d.up")
                    if planID == nil {
                        MovoInfoRow("独立待办", value: "\(bundle.standaloneTaskCount) 项",
                                    systemImage: "checklist")
                    }
                    MovoInfoRow("体积", value: bundle.byteCountText, systemImage: "internaldrive")
                    MovoInfoRow("文件名", value: bundle.fileName, systemImage: "doc")
                }

                MovoFormSection("文件内容预览", footnote: previewFootnote) {
                    HStack(spacing: MovoSpace.s) {
                        MovoButton("复制内容", systemImage: "doc.on.doc", kind: .secondary) {
                            copy(bundle.content)
                        }
                        MovoButton("存储为文件", systemImage: "square.and.arrow.down", kind: .primary) {
                            isExporting = true
                        }
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("分享", systemImage: "square.and.arrow.up")
                                    .font(MovoFont.bodyEmphasis)
                                    .frame(minHeight: MovoSpace.minTouch)
                            }
                        }
                        Spacer(minLength: 0)
                        if copied { MovoTag("已复制", systemImage: "checkmark") }
                    }
                    if let savedMessage {
                        Text(savedMessage).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                    }
                    ScrollView {
                        Text(bundle.content)
                            .font(MovoFont.mono)
                            .foregroundStyle(MovoColor.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(MovoSpace.s)
                    }
                    .frame(maxHeight: 320)
                    .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                        .fill(MovoColor.soft))
                }
            }
        }
        .movoPageBackground()
        .task(id: reloadKey) { await regenerate() }
        .onDisappear {
            if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
            shareURL = nil
        }
        .fileExporter(isPresented: $isExporting,
                      document: bundle.map { ExportFileDocument(text: $0.content) },
                      contentType: contentType,
                      defaultFilename: bundle?.fileName) { result in
            switch result {
            case .success(let url):
                savedMessage = "已存储到 \(url.lastPathComponent)。"
            case .failure:
                savedMessage = "没有存储成功，可以改用「复制内容」。"
            }
        }
    }

    // MARK: - 选项

    private var optionsSection: some View {
        MovoFormSection("导出选项",
                        footnote: "默认只导出计划、阶段、任务、重复规则、步骤和指标定义；下面三项需要时自己打开。文件不包含 API Key、音频和设备标识。") {
            MovoFormRow("格式") {
                MovoRequiredChipRow(options: ExportFormat.allCases, selection: $format,
                                    label: \.displayName)
            }
            optionToggle("包含行动记录", detail: "每条记录的时间、时长和说明。", isOn: $includeRecords)
            optionToggle("包含测量值", detail: "体重、成绩等结果指标的测量记录。", isOn: $includeMeasurements)
            optionToggle("包含笔记", detail: "想法、决定和备忘。", isOn: $includeNotes)
        }
    }

    private func optionToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                Text(detail).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: - 派生

    private var title: String {
        if planID == nil { return "导出全部计划" }
        if let planName { return "导出「\(planName)」" }
        return "导出计划"
    }

    private var subtitle: String {
        planID == nil ? "Markdown / Movo 文件 · 记录、测量值、笔记默认不导出" : "当前计划的完整档案"
    }

    private var previewFootnote: String {
        format == .json
            ? "Movo 文件（.movo.json）可在设置里「导入 Movo 文件」读回，含前置任务、重复规则和步骤。"
            : "Markdown 便于阅读与粘贴到其它工具，同样保留依赖与记录。"
    }

    private var reloadKey: String {
        "\(planID?.uuidString ?? "all")|\(format.rawValue)|\(includeRecords)|\(includeMeasurements)|\(includeNotes)"
    }

    private var contentType: UTType {
        #if canImport(UniformTypeIdentifiers)
        switch format {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .json: .json
        }
        #else
        .plainText
        #endif
    }

    // MARK: - 动作

    private func regenerate() async {
        isLoading = bundle == nil
        if let planID {
            planName = await env.store.repository.plan(planID)?.name
        }
        let generated = await Self.makeBundle(env: env, planID: planID,
                                              format: format, options: options)
        bundle = generated
        shareURL = Self.writeShareFile(generated, replacing: shareURL)
        copied = false
        savedMessage = nil
        isLoading = false
    }

    /// 系统分享需要一个真实文件：写到临时目录，重新生成时删掉上一份
    private static func writeShareFile(_ bundle: ExportBundle, replacing old: URL?) -> URL? {
        if let old { try? FileManager.default.removeItem(at: old) }
        guard !bundle.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(bundle.fileName)
        do {
            try Data(bundle.content.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        copied = true
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        #endif
    }
}

// MARK: - 文件写出

/// 把导出文本写成一个文件。双端共用（FileDocument 在 iOS 与 macOS 都可用）。
struct ExportFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        #if canImport(UniformTypeIdentifiers)
        [.plainText, .json]
        #else
        []
        #endif
    }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
