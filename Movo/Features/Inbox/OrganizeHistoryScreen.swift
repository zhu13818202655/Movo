//
//  OrganizeHistoryScreen.swift
//  Features/Inbox
//
//  AI 整理记录。按时间列出每次输入：
//  - 原文、AI 做了什么、状态（已应用 / 待确认 / 失败 / 已撤销）；
//  - 失败可重试或改文字，待确认项可重新打开预览，窗口内可撤销；
//  - 没有 Key 或关闭 AI 时，原文照常保存并提示去设置。
//

import SwiftUI
import MovoKit

public struct OrganizeHistoryScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    @State private var records: [OrganizeRecord] = []
    @State private var isLoading = true
    @State private var editingRecord: OrganizeRecord?
    @State private var editText: String = ""

    public init() {}

    public var body: some View {
        ScreenScroll {
            ScreenChrome("AI 整理记录", subtitle: records.isEmpty ? "还没有记录" : "共 \(records.count) 次记录") {
                MovoButton("新的整理", systemImage: "sparkles", kind: .secondary) {
                    router.present(.quickCapture)
                }
            }

            if isLoading && records.isEmpty {
                LoadingPlaceholder("正在读取记录…")
            } else if records.isEmpty {
                MovoEmptyState(systemImage: "sparkles.rectangle.stack",
                               title: "暂无整理记录",
                               message: "你可以使用语音或文字输入，AI 整理后会保留记录在这里。",
                               actionTitle: "立即输入",
                               action: { router.present(.quickCapture) })
                    .frame(minHeight: 300)
            } else {
                LazyVStack(spacing: MovoSpace.m) {
                    ForEach(records) { record in
                        recordCard(record)
                    }
                }
            }
        }
        .movoPageBackground()
        .task(id: env.store.dataVersion) { await reload() }
        .sheet(item: $editingRecord) { record in
            editSheet(record)
        }
    }

    // MARK: - 卡片展示

    @ViewBuilder
    private func recordCard(_ record: OrganizeRecord) -> some View {
        MovoCard {
            VStack(alignment: .leading, spacing: MovoSpace.s) {
                HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
                    statusTag(for: record.state)
                    Text(timeText(record.capturedAt))
                        .font(MovoFont.caption)
                        .foregroundStyle(MovoColor.muted)
                    Spacer(minLength: 0)
                }

                Text(record.rawText)
                    .font(MovoFont.bodyEmphasis)
                    .foregroundStyle(MovoColor.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(record.summary)
                    .font(MovoFont.caption)
                    .foregroundStyle(MovoColor.muted)

                Divider()

                HStack(spacing: MovoSpace.s) {
                    if record.canPreview {
                        MovoButton("查看预览与确认", kind: .primary) {
                            router.push(.captureResult(captureID: record.id))
                        }
                    }

                    if record.canUndo {
                        MovoButton("撤销此批次", kind: .quiet) {
                            _Concurrency.Task { await undoRecord(record) }
                        }
                    }

                    if record.canRetry {
                        MovoButton("重试整理", kind: .secondary) {
                            _Concurrency.Task { await retryRecord(record) }
                        }
                        MovoButton("编辑文字", kind: .quiet) {
                            editText = record.rawText
                            editingRecord = record
                        }
                    }

                    if !env.globalAIEnabled || !env.isConfigured(for: env.vendor) {
                        MovoButton("去配置 AI", kind: .quiet) {
                            router.push(.settings)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(MovoSpace.s)
        }
    }

    @ViewBuilder
    private func statusTag(for state: CaptureState) -> some View {
        switch state {
        case .aiSucceeded:
            StatusTag(text: "已应用", foreground: MovoColor.done, background: MovoColor.soft, systemImage: "checkmark.circle.fill")
        case .aiPartial:
            StatusTag(text: "已应用（部分）", foreground: MovoColor.done, background: MovoColor.soft, systemImage: "checkmark.circle")
        case .pendingConfirmation:
            StatusTag(text: "待确认", foreground: MovoColor.inProgress, background: MovoColor.soft, systemImage: "clock.badge.checkmark")
        case .processing:
            StatusTag(text: "整理中", foreground: MovoColor.warning, background: MovoColor.soft, systemImage: "circle.dotted")
        case .aiFailed:
            StatusTag(text: "整理失败", foreground: MovoColor.warning, background: MovoColor.soft, systemImage: "exclamationmark.circle")
        case .undone:
            StatusTag(text: "已撤销", foreground: MovoColor.muted, background: MovoColor.soft, systemImage: "arrow.uturn.backward")
        case .saved:
            StatusTag(text: "已保存原文", foreground: MovoColor.muted, background: MovoColor.soft, systemImage: "tray")
        }
    }

    // MARK: - 编辑弹窗

    @ViewBuilder
    private func editSheet(_ record: OrganizeRecord) -> some View {
        NavigationStack {
            ScreenScroll {
                ScreenChrome("修改输入文字", subtitle: "修改后将重新请求 AI 整理")
                MovoTextField("输入内容", text: $editText, axis: .vertical)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editingRecord = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("重新整理") {
                        let text = editText
                        editingRecord = nil
                        _Concurrency.Task {
                            await reprocessWithEditedText(record.id, text: text)
                        }
                    }
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - 行为

    private func reload() async {
        isLoading = true
        records = await env.store.getOrganizeHistory()
        isLoading = false
    }

    private func retryRecord(_ record: OrganizeRecord) async {
        await env.processCapture(record.id)
        router.push(.captureResult(captureID: record.id))
        await reload()
    }

    private func reprocessWithEditedText(_ id: UUID, text: String) async {
        _ = await env.updateCaptureState(id, state: .processing, editedText: text)
        await env.processCapture(id)
        router.push(.captureResult(captureID: id))
        await reload()
    }

    private func undoRecord(_ record: OrganizeRecord) async {
        guard let batchID = record.batchID else { return }
        do {
            let result = try await env.store.undo(batchID: batchID)
            _ = await env.updateCaptureState(record.id, state: .undone)
            if !result.unsafeOperations.isEmpty || !result.nonUndoableOperations.isEmpty {
                env.lastError = .invalidStructure(reason: result.summaryText)
            }
            await reload()
        } catch let error as MovoError {
            env.lastError = error
        } catch {}
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh-Hans")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}
