//
//  CaptureStatusScreens.swift
//  Features/Capture
//
//  M04-Processing 整理中（隐私分流 → 整理中 → 可重试）/
//  M04-Failed 原文已保留 / M02 系列 AI 整理结果（成功 4 项、部分成功）。
//

import SwiftUI
import MovoKit

// MARK: - M04-Processing

public struct ProcessingScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let captureID: UUID
    @State private var elapsed: Double = 0
    @State private var timer: _Concurrency.Task<Void, Never>?

    public init(captureID: UUID) { self.captureID = captureID }

    public var body: some View {
        ScreenScroll {
            ScreenChrome("正在整理", subtitle: "原文已经保存好了。")

            VStack(alignment: .leading, spacing: MovoSpace.m) {
                step("隐私分流", done: true, current: false)
                step("整理中", done: env.lastPreparation != nil, current: env.isProcessing)
                step("可以重试 / 手动整理", done: false, current: false)
            }

            if elapsed >= env.defaults.ai.progressMustShowAfterSeconds {
                MovoBanner(kind: .info, title: "还在处理",
                           message: "网络较慢时可以继续等，也可以先手动整理，原文不会丢。")
            }

            HStack(spacing: MovoSpace.s) {
                MovoButton("取消", kind: .quiet) { finish() }
                MovoButton("手动整理", kind: .secondary) {
                    env.clearNotice()
                    router.push(.section(.inbox))
                }
                Spacer(minLength: 0)
            }
        }
        .task {
            timer = _Concurrency.Task {
                while !_Concurrency.Task.isCancelled, elapsed < 300 {
                    try? await _Concurrency.Task.sleep(for: .seconds(1))
                    elapsed += 1
                }
            }
            // 管线已由触发方启动；此处只等待结果
            while env.isProcessing {
                try? await _Concurrency.Task.sleep(for: .milliseconds(120))
            }
            timer?.cancel()
            finish()
        }
    }

    private var stepRow: some View { EmptyView() }

    @ViewBuilder
    private func step(_ title: String, done: Bool, current: Bool) -> some View {
        HStack(spacing: MovoSpace.s) {
            Image(systemName: done ? "checkmark.circle.fill" : (current ? "circle.dotted" : "circle"))
                .foregroundStyle(done ? MovoColor.done : MovoColor.muted)
            Text(title).font(MovoFont.body).foregroundStyle(MovoColor.ink)
            if current {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: MovoSpace.minTouch)
    }

    private func finish() {
        timer?.cancel()
        let preparation = env.lastPreparation
        if let error = preparation?.error {
            // 无 Key 或失败：原文已保存（M04-Failed）
            if case .noKey = error {
                router.push(.captureResult(captureID: captureID))
            } else {
                router.push(.captureFailed(captureID: captureID))
            }
        } else {
            router.push(.captureResult(captureID: captureID))
        }
        // 跳过 Processing 自身
        if case .processing = router.path(for: router.section).last { router.pop() }
    }
}

// MARK: - M04-Failed

public struct CaptureFailedScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let captureID: UUID
    @State private var rawText = ""
    @State private var retrying = false

    public init(captureID: UUID) { self.captureID = captureID }

    public var body: some View {
        ScreenScroll {
            ScreenChrome("整理没能完成", subtitle: "原文已经保留，可以重试或手动整理。")

            if let error = env.lastError {
                MovoBanner(error: error) { action in
                    handle(action)
                }
            }

            if !rawText.isEmpty {
                SectionBlock("原文") {
                    Text(rawText)
                        .font(MovoFont.body)
                        .foregroundStyle(MovoColor.ink)
                        .padding(MovoSpace.s)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: MovoSpace.s) {
                MovoButton("重试整理", isLoading: retrying) { _Concurrency.Task { await retry() } }
                MovoButton("改成文字输入", kind: .quiet) { router.present(.quickCapture) }
                Spacer(minLength: 0)
            }
        }
        .task {
            if let capture = await env.store.repository.capture(captureID) {
                rawText = capture.editedText ?? capture.rawText
            }
        }
    }

    private func handle(_ action: RecoveryAction) {
        switch action {
        case .retry: _Concurrency.Task { await retry() }
        case .editText: router.present(.quickCapture)
        case .openSettings(let section): router.present(.settingsSection(section))
        case .viewInbox: router.go(to: .section(.inbox), in: .inbox)
        case .dismiss: env.lastError = nil
        default: env.lastError = nil
        }
    }

    private func retry() async {
        retrying = true
        defer { retrying = false }
        await env.processCapture(captureID)
        router.push(.captureResult(captureID: captureID))
    }
}

// MARK: - M02 系列 AI 整理结果

public struct CaptureResultScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let captureID: UUID
    @State private var rawText = ""
    @State private var showRaw = false

    public init(captureID: UUID) { self.captureID = captureID }

    private var preparation: ProposalPreparation? { env.lastPreparation }

    public var body: some View {
        ScreenScroll {
            let applied = preparation?.autoCommands.count ?? 0
            let local = preparation?.deterministicLocalMatches.count ?? 0
            let pending = preparation?.pendingProposals ?? []
            let rejected = preparation?.rejectedIssues ?? []

            ScreenChrome(headline(applied + local, pending: pending.count, rejected: rejected.count),
                         subtitle: subtitle)

            if let error = preparation?.error {
                MovoBanner(error: error) { action in
                    switch action {
                    case .openSettings(let section): router.present(.settingsSection(section))
                    case .editText: router.present(.quickCapture)
                    case .retry: _Concurrency.Task { await env.processCapture(captureID) }
                    case .viewInbox: router.go(to: .section(.inbox), in: .inbox)
                    default: env.lastError = nil
                    }
                }
            }

            if let preparation, !preparation.deterministicLocalMatches.isEmpty {
                SectionBlock("在本机完成", trailing: "\(preparation.deterministicLocalMatches.count) 项") {
                    resultList(preparation.deterministicLocalMatches.map {
                        ($0.kind.displayName, $0.matchedTitle ?? $0.sourceText, $0.reason, false)
                    })
                }
            }

            if let preparation, !preparation.autoCommands.isEmpty {
                SectionBlock("已整理", trailing: "\(preparation.autoCommands.count) 项") {
                    resultList(preparation.autoCommands.map {
                        ($0.kind.displayName, kindTitle($0.kind), "自动执行，可撤销", false)
                    })
                }
            }

            if !pending.isEmpty {
                SectionBlock("需要你确认", trailing: "\(pending.count) 项") {
                    VStack(alignment: .leading, spacing: MovoSpace.s) {
                        ForEach(pending) { item in
                            SuggestionCard(
                                title: item.item.sourceSpan ?? item.kind.displayName,
                                reason: item.item.reason ?? item.kind.displayName,
                                lines: item.changeSummary,
                                sourceText: nil,
                                primaryTitle: "采纳",
                                onPrimary: {
                                    _Concurrency.Task {
                                        await env.acceptPendingProposals([item], captureID: captureID)
                                        router.push(.section(.today))
                                    }
                                },
                                onDismiss: nil)
                        }
                    }
                    .padding(MovoSpace.s)
                }
            }

            if !rejected.isEmpty {
                SectionBlock("需要补充信息", trailing: "\(rejected.count) 项") {
                    resultList(rejected.map {
                        ($0.sourceSpan ?? "未识别", $0.reasons.map(\.description).joined(separator: "；"),
                         $0.suggestedAction ?? "去收件箱处理", true)
                    })
                }
            }

            SectionBlock("原文") {
                VStack(alignment: .leading, spacing: MovoSpace.s) {
                    if showRaw {
                        Text(rawText).font(MovoFont.body).foregroundStyle(MovoColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    MovoButton(showRaw ? "收起原文" : "查看原文", kind: .quiet) {
                        showRaw.toggle()
                    }
                }
                .padding(MovoSpace.s)
            }

            HStack(spacing: MovoSpace.s) {
                MovoButton("返回待办", kind: .primary) {
                    router.go(to: .section(.today), in: .today)
                }
                if let batchID = env.lastBatchNotice?.batchID, env.lastBatchNotice?.canUndo == true {
                    MovoButton("撤销", kind: .secondary) {
                        _Concurrency.Task { await env.undoLastBatch() }
                    }
                    .id(batchID)
                }
                Spacer(minLength: 0)
            }
        }
        .task {
            if let capture = await env.store.repository.capture(captureID) {
                rawText = capture.editedText ?? capture.rawText
            }
        }
    }

    private var subtitle: String {
        if let preparation {
            return preparation.resultMessage + "。已完成的处理不需要逐项确认。"
        }
        return "原文已经保存。"
    }

    private func headline(_ applied: Int, pending: Int, rejected: Int) -> String {
        if applied == 0 && pending == 0 && rejected == 0 { return "没有可整理的内容" }
        if pending > 0 || rejected > 0 { return "已整理 \(applied) 项" }
        return "已整理 \(applied) 项"
    }

    private func kindTitle(_ kind: OperationKind) -> String {
        switch kind {
        case .createTask: "新增待办"
        case .scheduleTask: "安排日期"
        case .completeTask: "标记完成"
        case .completeOccurrence: "完成这一次"
        case .skipOccurrence: "跳过这一次"
        case .logActivity: "记录一次行动"
        case .recordMeasurement: "记录结果"
        case .createNote: "保存想法"
        case .createRecurrence, .changeRecurrence: "设置重复"
        case .addDependency: "建议先后顺序"
        case .createPlan: "新建计划"
        case .createStage: "新建阶段"
        case .createMetric: "新增结果指标"
        default: kind.displayName
        }
    }

    @ViewBuilder
    private func resultList(_ rows: [(String, String, String, Bool)]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(alignment: .top, spacing: MovoSpace.s) {
                    Image(systemName: row.3 ? "exclamationmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(row.3 ? MovoColor.warning : MovoColor.done)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: MovoSpace.xs) {
                        Text(row.1).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: MovoSpace.xs) {
                            MovoTag(row.0)
                            Text(row.2).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(MovoSpace.s)
                if index < rows.count - 1 { MovoDivider().padding(.leading, MovoSpace.m) }
            }
        }
    }
}
