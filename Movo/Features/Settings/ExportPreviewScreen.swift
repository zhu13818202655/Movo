//
//  ExportPreviewScreen.swift
//  Features/Settings
//
//  M13-Export / M13-Export-Details：导出预览（T1.8 / REQ 16）。
//  · 范围：当前计划（从计划详情进入）或全部计划（从设置进入）。
//  · 格式：Markdown / JSON；JSON 含依赖关系字段（AC18），导出后可被重新解析。
//  · 敏感默认排除：未允许云 AI 的计划不进入默认导出集（AC16 本地部分），
//    必须由用户显式打开「包含未允许云 AI 的计划」才会包含。
//  · 空数据不填充虚构内容：没有计划时给出空状态，而不是造样本。
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

    @State private var format: ExportFormat = .markdown
    @State private var includeSensitive = false
    @State private var bundle: ExportBundle?
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
                                  includeSensitive: Bool) async -> ExportBundle {
        let repository = env.store.repository
        let plans = await repository.allPlans()
        let tasks = await repository.allTasks()
        let notes = await repository.allNotes()
        let activities = await repository.allActivities()
        let measurements = await repository.allMeasurements()
        let rules = await repository.rules()

        var stages: [Stage] = []
        var metrics: [PlanMetric] = []
        var occurrences: [RecurrenceOccurrence] = []
        for plan in plans {
            stages += await repository.stages(planID: plan.id)
            metrics += await repository.metrics(planID: plan.id)
            occurrences += await repository.occurrences(planID: plan.id)
        }

        let selections = ExportService.gather(
            plans: plans, stages: stages, tasks: tasks, metrics: metrics,
            measurements: measurements, activities: activities, notes: notes,
            occurrences: occurrences, rules: rules, onlyPlanID: planID)

        return ExportService.export(selections, format: format,
                                    includeSensitive: includeSensitive,
                                    generatedAt: env.store.now,
                                    timeZone: env.store.currentTimeZone)
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
            } else if let bundle, bundle.includedPlanNames.isEmpty {
                MovoEmptyState(systemImage: "tray",
                               title: "没有可导出的计划",
                               message: sensitiveExcludedOnly
                                   ? "当前范围内的计划都还没有允许云 AI。打开下面的开关才会包含它们。"
                                   : "这个范围内还没有计划可以导出。先建一个计划再来。")
                optionsSection
            } else if let bundle {
                if !bundle.excludedPlanNames.isEmpty {
                    MovoBanner(kind: .info,
                               title: "已默认排除 \(bundle.excludedPlanNames.count) 个敏感计划",
                               message: "这些计划还没有允许云 AI（\(bundle.excludedPlanNames.joined(separator: "、"))）。"
                                   + "如确需导出，请打开「包含未允许云 AI 的计划」。")
                }

                optionsSection

                MovoFormSection("这次导出会包含", footnote: bundle.summaryText) {
                    MovoInfoRow("范围", value: planID == nil ? "全部计划" : "当前计划", systemImage: "scope")
                    MovoInfoRow("格式", value: format.displayName, systemImage: "doc.text")
                    MovoInfoRow("计划数", value: "\(bundle.includedPlanNames.count) 个",
                                systemImage: "square.stack.3d.up")
                    MovoInfoRow("排除", value: bundle.excludedPlanNames.isEmpty
                                ? "无"
                                : "\(bundle.excludedPlanNames.count) 个敏感计划",
                                systemImage: "eye.slash")
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
                        footnote: "JSON 导出含稳定 ID、依赖关系、重复模板与实例、记录与结果，可被重新解析。") {
            MovoFormRow("格式") {
                MovoRequiredChipRow(options: ExportFormat.allCases, selection: $format,
                                    label: \.displayName)
            }
            Toggle(isOn: $includeSensitive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("包含未允许云 AI 的计划").font(MovoFont.bodyEmphasis)
                        .foregroundStyle(MovoColor.ink)
                    Text("默认排除。健康等敏感计划只有你明确选择才会进入导出文件。")
                        .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: - 派生

    private var title: String {
        if planID == nil { return "导出全部计划" }
        if let planName { return "导出「\(planName)」" }
        return "导出计划"
    }

    private var subtitle: String {
        planID == nil ? "Markdown / JSON · 敏感计划默认排除" : "当前计划的完整档案"
    }

    private var previewFootnote: String {
        format == .json
            ? "JSON 结构可直接被重新解析后再导入，含前置任务字段。"
            : "Markdown 便于阅读与粘贴到其它工具，同样保留依赖与记录。"
    }

    private var sensitiveExcludedOnly: Bool {
        bundle?.excludedPlanNames.isEmpty == false
    }

    private var reloadKey: String {
        "\(planID?.uuidString ?? "all")|\(format.rawValue)|\(includeSensitive)"
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
                                              format: format, includeSensitive: includeSensitive)
        bundle = generated
        copied = false
        savedMessage = nil
        isLoading = false
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
