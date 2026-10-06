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
            while env.isProcessing || env.captureResults[captureID] == nil {
                guard !_Concurrency.Task.isCancelled else { return }
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
        let preparation = env.captureResults[captureID]
        if case .processing = router.path(for: router.section).last { router.pop() }
        if let error = preparation?.error {
            // 「还没配置好」（无 Key / 自定义厂商没填完）不是整理失败：原文已保存，
            // 本地分流结果照常展示，由结果页的横幅给出「去设置页补全」的恢复入口（M02）。
            // 其余错误才是 M04-Failed。
            if error.isConfigurationGap {
                router.push(.captureResult(captureID: captureID))
            } else {
                router.push(.captureFailed(captureID: captureID))
            }
        } else {
            router.push(.captureResult(captureID: captureID))
        }
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
    let embedded: Bool
    @State private var rawText = ""
    @State private var rows: [AppliedRow] = []
    @State private var canUndo = false
    @State private var localError: String?
    @State private var deselectedIDs: Set<String> = []
    @State private var isCommitting = false

    public init(captureID: UUID, embedded: Bool = false) {
        self.captureID = captureID; self.embedded = embedded
    }

    private struct AppliedRow: Identifiable {
        var id: UUID
        var title: String
        var detail: String
        var action: String
    }

    private var preparation: ProposalPreparation? { env.captureResults[captureID] }
    private var batchID: UUID { CaptureCommand.batchID(for: captureID) }

    public var body: some View {
        ScreenScroll {
            if let preparation {
                ScreenChrome(headline(preparation), subtitle: preparation.resultMessage)
                if let error = preparation.error {
                    MovoBanner(error: error, onAction: recover)
                }
                if let localError {
                    MovoBanner(kind: .warning, title: "操作未完成", message: localError)
                }
                if !rows.isEmpty {
                    SectionBlock("已完成", trailing: "\(rows.count) 项") {
                        ForEach(rows) { row in
                            HStack(alignment: .top, spacing: MovoSpace.s) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(MovoColor.done)
                                VStack(alignment: .leading, spacing: MovoSpace.xs) {
                                    Text(row.title).font(MovoFont.bodyEmphasis)
                                    Text(row.action + (row.detail.isEmpty ? "" : " · " + row.detail))
                                        .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                                }
                                Spacer(minLength: 0)
                            }.padding(MovoSpace.s)
                        }
                    }
                }
                if preparation.undoSummary == nil && !preparation.pendingProposals.isEmpty {
                    SectionBlock("预览与确认", trailing: "\(activeSelectedCount) 项待写入") {
                        VStack(alignment: .leading, spacing: MovoSpace.m) {
                            ForEach(preparation.pendingProposals) { item in
                                let isCascadeDisabled = isAncestorDeselected(item, in: preparation.pendingProposals)
                                let isSelected = !isCascadeDisabled && !deselectedIDs.contains(item.id)

                                VStack(alignment: .leading, spacing: MovoSpace.s) {
                                    HStack {
                                        Toggle(isOn: Binding(
                                            get: { isSelected },
                                            set: { checked in
                                                if isCascadeDisabled { return }
                                                if checked {
                                                    deselectedIDs.remove(item.id)
                                                } else {
                                                    deselectedIDs.insert(item.id)
                                                }
                                            })) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.affectedSummary).font(MovoFont.bodyEmphasis)
                                                    .foregroundStyle(isCascadeDisabled ? MovoColor.muted : MovoColor.ink)
                                                if isCascadeDisabled {
                                                    Text("因上级项被取消而排除").font(MovoFont.caption).foregroundStyle(MovoColor.warning)
                                                } else {
                                                    Text(item.item.reason ?? item.kind.displayName).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                                                }
                                            }
                                        }
                                        .disabled(isCascadeDisabled)
                                        .toggleStyle(.switch)
                                    }

                                    if !item.changeSummary.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(item.changeSummary, id: \.entityId) { line in
                                                HStack(alignment: .firstTextBaseline, spacing: MovoSpace.xs) {
                                                    Text(line.title).font(MovoFont.captionEmphasis).foregroundStyle(MovoColor.muted)
                                                    Text(line.changeText).font(MovoFont.caption).foregroundStyle(MovoColor.ink)
                                                }
                                            }
                                        }
                                        .padding(.leading, MovoSpace.m)
                                    }
                                }
                                .padding(MovoSpace.s)
                                .background(RoundedRectangle(cornerRadius: MovoRadius.card).fill(MovoColor.surface))
                            }

                            MovoButton("确认写入已选（\(activeSelectedCount) 项）", kind: .primary,
                                       isEnabled: activeSelectedCount > 0 && !isCommitting) {
                                _Concurrency.Task { await commitSelectedProposals() }
                            }
                        }.padding(MovoSpace.s)
                    }
                }
                if !preparation.rejectedIssues.isEmpty || !preparation.commitRejections.isEmpty {
                    SectionBlock("尚未应用") {
                        VStack(alignment: .leading, spacing: MovoSpace.s) {
                            ForEach(preparation.rejectedIssues) { item in
                                Text(item.sourceSpan ?? "未识别的内容").font(MovoFont.bodyEmphasis)
                                Text(item.reasons.map(\.description).joined(separator: "；"))
                                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                            }
                            ForEach(preparation.commitRejections, id: \.operationID) { item in
                                Text(item.reason).font(MovoFont.body)
                            }
                        }.padding(MovoSpace.s)
                    }
                }
                if !preparation.validated.corrections.isEmpty {
                    Text(preparation.validated.corrections.joined(separator: "\n"))
                        .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
                if let notice = preparation.validated.truncationNotice {
                    MovoBanner(kind: .warning, title: "还有内容待整理", message: notice)
                }
                DisclosureGroup("查看原文") { Text(rawText).textSelection(.enabled) }
                VStack(alignment: .leading, spacing: MovoSpace.s) {
                    if preparation.undoSummary == nil && (preparation.error != nil || !preparation.commitRejections.isEmpty) {
                        MovoButton("重试未完成的整理", isEnabled: !env.isProcessing) {
                            _Concurrency.Task { await env.processCapture(captureID) }
                        }
                    }
                    if preparation.isPartial {
                        MovoButton("编辑未完成内容", kind: .secondary) { recover(.editText) }
                        MovoButton("查看整理记录", kind: .secondary) {
                            router.dismissSheet()
                            router.select(.inbox)
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { resultActions }
                        VStack(alignment: .leading) { resultActions }
                    }
                }
            } else {
                LoadingPlaceholder("正在恢复整理结果…")
            }
        }
        .disabled(env.isProcessing)
        .task {
            await env.restoreCaptureResult(captureID)
            await reload()
        }
        .task(id: env.store.dataVersion) { await reload() }
    }

    private var activeSelectedCount: Int {
        guard let preparation else { return 0 }
        return preparation.pendingProposals.filter { !isAncestorDeselected($0, in: preparation.pendingProposals) && !deselectedIDs.contains($0.id) }.count
    }

    private func isAncestorDeselected(_ item: PendingProposal, in items: [PendingProposal]) -> Bool {
        if let pRef = item.item.task?.parentRef {
            if items.contains(where: { ($0.item.task?.ref == pRef || $0.item.plan?.ref == pRef) && (deselectedIDs.contains($0.id) || isAncestorDeselected($0, in: items)) }) {
                return true
            }
        }
        if let sRef = item.item.task?.stageRef {
            if items.contains(where: { ($0.item.plan?.stages.contains(where: { $0.ref == sRef }) ?? false) && (deselectedIDs.contains($0.id) || isAncestorDeselected($0, in: items)) }) {
                return true
            }
        }
        return false
    }

    private func commitSelectedProposals() async {
        guard let preparation, !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }
        let selected = preparation.pendingProposals.filter {
            !isAncestorDeselected($0, in: preparation.pendingProposals) && !deselectedIDs.contains($0.id)
        }
        await env.acceptPendingProposals(selected, captureID: captureID)
        await reload()
    }

    @ViewBuilder
    private var resultActions: some View {
        MovoButton("查看待办") { router.dismissSheet(); router.select(.today) }
        if let plan = preparation?.appliedOperations.first(where: { $0.kind == .createPlan }) {
            MovoButton("查看计划", kind: .secondary) {
                router.dismissSheet()
                router.go(to: .planDetail(plan.entityId), in: .plans)
            }
        }
        MovoButton("继续记录", kind: .secondary) {
            env.continueCapturing()
            if !embedded { router.present(.quickCapture) }
        }
        if canUndo {
            MovoButton("撤销本次", kind: .quiet) {
                _Concurrency.Task {
                    do {
                        let result = try await env.store.undo(batchID: batchID)
                        if !result.unsafeOperations.isEmpty || !result.nonUndoableOperations.isEmpty {
                            localError = result.summaryText
                        }
                        if env.lastBatchNotice?.batchID == batchID { env.clearNotice() }
                        _ = await env.updateCaptureState(captureID, state: .saved)
                        await reload()
                    } catch { localError = error.localizedDescription }
                }
            }
        }
    }

    private func headline(_ result: ProposalPreparation) -> String {
        if result.undoSummary != nil { return "本次整理已撤销" }
        let operations = result.appliedOperations
        if operations.isEmpty {
            if !result.pendingProposals.isEmpty { return "等待你确认" }
            return result.error == nil ? "原文已保留，尚未创建事项" : "整理未完成"
        }
        let created = operations.filter { $0.kind == .createTask }.count
        if created == operations.count { return "已添加 \(created) 项待办" }
        return "已处理 \(operations.count) 项"
    }

    private func recover(_ action: RecoveryAction) {
        switch action {
        case .openSettings(let section): router.present(.settingsSection(section))
        case .retry: _Concurrency.Task { await env.processCapture(captureID) }
        case .viewInbox: router.dismissSheet(); router.select(.inbox)
        case .editText:
            let hasApplied = !(preparation?.appliedOperations.isEmpty ?? true)
            env.continueCapturing()
            env.captureText = hasApplied ? remainingSourceText : rawText
            if !embedded { router.present(.quickCapture) }
        default: break
        }
    }

    private var remainingSourceText: String {
        guard let preparation else { return rawText }
        let applied = Set(preparation.appliedOperations.map(\.id))
        var sources: [String] = []
        sources += preparation.rejectedIssues.compactMap(\.sourceSpan)
        for item in preparation.proposal?.items ?? [] {
            let confirmed = CaptureCommand.stableID(captureID: captureID, key: "confirm|\(item.id)|0")
            let prefix = "\(item.action.rawValue)|\(item.id)|"
            let keys = preparation.validated.commandKeys.values.filter { $0.hasPrefix(prefix) }
            let savedAutomatically = !keys.isEmpty && keys.allSatisfy {
                applied.contains(CaptureCommand.stableID(captureID: captureID, key: "auto|\($0)"))
            }
            if !applied.contains(confirmed), !savedAutomatically, let source = item.sourceSpan { sources.append(source) }
        }
        var seen: Set<String> = []
        return sources.filter { seen.insert($0).inserted }.joined(separator: "\n")
    }

    private func reload() async {
        if let capture = await env.store.repository.capture(captureID) { rawText = capture.effectiveText }
        let operations = await env.store.repository.operations(batchID: batchID).filter { $0.status == .applied }
        var result: [AppliedRow] = []
        for operation in operations {
            var title = operation.reason ?? operation.kind.displayName
            var detail = ""
            if operation.entityType == .task, let task = await env.store.repository.task(operation.entityId) {
                title = task.title
                detail = task.startAt.map { "开始 \($0.displayString)" } ?? "未安排"
                if let planID = task.planId, let plan = await env.store.repository.plan(planID) {
                    detail += " · " + plan.name
                } else { detail += " · 独立待办" }
                if let end = task.endAt { detail += " · 截止 \(end.displayString)" }
            } else if operation.entityType == .plan, let plan = await env.store.repository.plan(operation.entityId) {
                title = plan.name; detail = plan.kind.displayName
            }
            result.append(AppliedRow(id: operation.id, title: title, detail: detail, action: operation.kind.displayName))
        }
        rows = result
        let batch = await env.store.repository.batch(batchID)
        canUndo = batch?.isUndoable == true && !operations.isEmpty
        if var preparation = env.captureResults[captureID] {
            preparation.appliedOperations = operations
            preparation.undoSummary = batch?.state == .undone ? batch?.summary : nil
            env.captureResults[captureID] = preparation
        }
    }
}
