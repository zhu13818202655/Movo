import SwiftUI
import MovoKit

public enum QuickCaptureMode: String, Sendable { case text, voice }

/// Mac 顶部输入与完整面板使用同一份草稿。
struct AICaptureQuickEntry: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    var body: some View {
        @Bindable var env = env
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            HStack(spacing: MovoSpace.s) {
                Label("AI 整理", systemImage: "sparkles")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.primary)
                TextField("说说接下来要做什么，可以一次记下几件事。", text: $env.captureText, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...3)
                    .onSubmit { submit() }
                    .disabled(env.isProcessing || env.isSubmittingCapture)
                    .accessibilityLabel("AI 整理输入")
                MovoIconButton("mic", label: "语音输入") { router.present(.recording) }
                MovoButton(env.isProcessing ? "查看进度" : "整理并添加",
                           isEnabled: env.isProcessing || !env.captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    if env.isProcessing { router.present(.quickCapture) } else { submit() }
                }
                MovoIconButton("arrow.up.left.and.arrow.down.right", label: "展开 AI 整理") {
                    router.present(.quickCapture)
                }
            }
            if let error = env.lastError, env.activeCaptureID == nil {
                Text(error.message).font(MovoFont.caption).foregroundStyle(.red)
            }
        }
        .padding(MovoSpace.m)
        .background(MovoColor.surface, in: RoundedRectangle(cornerRadius: MovoRadius.button))
        .onChange(of: env.captureText) { _, text in
            if !text.isEmpty, !env.isProcessing, !env.isSubmittingCapture { env.continueCapturing() }
        }
    }

    private func submit() {
        guard !env.isSubmittingCapture, !env.isProcessing else { return }
        env.continueCapturing()
        router.present(.quickCapture)
        _Concurrency.Task { await env.submitCaptureDraft() }
    }
}

public struct QuickCaptureSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router
    let mode: QuickCaptureMode
    @State private var plans: [Plan] = []
    @State private var update = TranscriptUpdate(finals: [], partial: nil)
    @State private var session: SpeechSession?
    @State private var consumeTask: _Concurrency.Task<Void, Never>?
    @State private var limitTask: _Concurrency.Task<Void, Never>?
    @State private var starting = false
    @State private var stopping = false
    @State private var recording = false
    @State private var recordingStarted = Date()
    @State private var speechError: String?
    @State private var showClear = false
    @State private var isVisible = true
    @State private var rawText = ""
    @FocusState private var textFocused: Bool

    public init(mode: QuickCaptureMode = .text) { self.mode = mode }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("AI 整理", systemImage: "sparkles").font(MovoFont.title2)
                Spacer()
                MovoButton("收起", kind: .quiet) { close() }
            }
            .padding(MovoSpace.m)
            if env.isProcessing || env.isSubmittingCapture {
                processing
            } else if let id = env.activeCaptureID {
                CaptureResultScreen(captureID: id, embedded: true)
            } else {
                composer
            }
        }
        .movoPageBackground()
        #if os(macOS)
        // minWidth 不能超过常见小窗口（macOS 的 sheet 最宽只能到宿主窗口；
        // 内容 insists 更大 minWidth 时会左右溢出被裁切）。plain 按钮在 Mac 上
        // 不随 proposal 拉伸，底部按钮行最窄 ~250 + 页边距，380 以下不再压缩。
        .frame(minWidth: 380, idealWidth: 620, minHeight: 480, idealHeight: 720)
        #endif
        .task {
            isVisible = true
            if mode == .voice, !env.isProcessing, !env.isSubmittingCapture { env.continueCapturing() }
            let deleted = Set(await env.store.repository.tombstones(activeOnly: true).map(\.entityId))
            plans = await env.store.repository.allPlans().filter { $0.status == .active && !deleted.contains($0.id) }
            if let selected = env.capturePlanID, !plans.contains(where: { $0.id == selected }) { env.capturePlanID = nil }
            if let id = env.activeCaptureID { await env.restoreCaptureResult(id) }
        }
        .onDisappear { isVisible = false; preserveRecordingAndCancel() }
        .confirmationDialog("清空当前草稿？", isPresented: $showClear, titleVisibility: .visible) {
            Button("清空草稿", role: .destructive) { env.captureText = ""; env.captureInputMode = .text }
        }
    }

    private var composer: some View {
        @Bindable var env = env
        return ScrollView {
            VStack(alignment: .leading, spacing: MovoSpace.m) {
                Text("写下来，或说出来，我来帮你整理成待办。")
                    .font(MovoFont.body).foregroundStyle(MovoColor.muted)
                ZStack(alignment: .topLeading) {
                    if env.captureText.isEmpty && !textFocused {
                        Text("例如：明天核对季度汇报的数据，回家顺便买牛奶。")
                            .foregroundStyle(MovoColor.muted).padding(.horizontal, 5).padding(.vertical, 8)
                    }
                    TextEditor(text: $env.captureText).focused($textFocused)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 200).disabled(recording || stopping)
                        .accessibilityLabel("文字与语音共用的草稿")
                }
                .font(MovoFont.body).padding(MovoSpace.s)
                .background(MovoColor.soft, in: RoundedRectangle(cornerRadius: MovoRadius.button))
                if recording || stopping {
                    TimelineView(.periodic(from: recordingStarted, by: 1)) { context in
                        Label("正在听… \(Int(max(0, context.date.timeIntervalSince(recordingStarted)))) 秒",
                              systemImage: "waveform").foregroundStyle(MovoColor.primary)
                    }
                    if !update.displayText.isEmpty {
                        Text(update.displayText).font(MovoFont.body).textSelection(.enabled)
                    }
                    HStack {
                        MovoButton("停止录音", isEnabled: !stopping, isLoading: stopping) {
                            _Concurrency.Task { await stopRecording() }
                        }
                        MovoButton("取消本次录音", kind: .quiet, isEnabled: !stopping) { cancelRecording() }
                    }
                } else {
                    HStack {
                        MovoButton(mode == .voice ? "开始录音" : "语音输入", systemImage: "mic",
                                   kind: .secondary, isLoading: starting) {
                            _Concurrency.Task { await beginRecording() }
                        }
                        MovoButton("清空草稿", kind: .quiet, isEnabled: !env.captureText.isEmpty) { showClear = true }
                    }
                }
                if let speechError {
                    MovoBanner(kind: .warning, title: "暂时无法使用语音", message: speechError,
                               actions: [("使用文字输入", { textFocused = true })])
                }
                Picker("指定计划", selection: $env.capturePlanID) {
                    Text("自动识别归属").tag(nil as UUID?)
                    ForEach(plans) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(recording)
                Text("可选计划只用于给新待办指定默认归属；是否把内容发给模型由全局 AI 开关决定。")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                if let error = env.lastError {
                    MovoBanner(error: error) { action in
                        if case .openSettings(let section) = action { router.present(.settingsSection(section)) }
                    }
                }
            }.padding(MovoSpace.m)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: MovoSpace.s) {
                MovoButton("整理并添加", isEnabled: !recording && !starting && !stopping
                           && !env.captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           isLoading: env.isSubmittingCapture) {
                    textFocused = false
                    _Concurrency.Task { await env.submitCaptureDraft() }
                }
                .frame(maxWidth: .infinity)
                Text("语音在本机转写，点击后才开始整理。")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
            .padding(MovoSpace.m).frame(maxWidth: .infinity).background(MovoColor.bg)
        }
    }

    private var processing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MovoSpace.l) {
                HStack { ProgressView(); Text("正在整理…").font(MovoFont.headline) }
                Text("原文已保存。可以先收起，稍后回来查看结果。")
                    .foregroundStyle(MovoColor.muted)
                if !rawText.isEmpty {
                    DisclosureGroup("查看原文") { Text(rawText).textSelection(.enabled) }
                }
            }.padding(MovoSpace.l)
        }
        .task(id: env.activeCaptureID) {
            if let id = env.activeCaptureID, let capture = await env.store.repository.capture(id) {
                rawText = capture.effectiveText
            }
        }
    }

    private func beginRecording() async {
        guard !starting, !recording else { return }
        starting = true
        speechError = nil
        textFocused = false
        defer { starting = false }
        let capability = await env.speech.capability(locale: Locale(identifier: "zh-Hans"))
        guard isVisible else { return }
        guard capability.canRecord else {
            speechError = capability.failureReason?.displayName ?? "本机语音暂不可用，请使用文字输入或检查权限。"
            return
        }
        let session = env.startSpeechSession()
        self.session = session
        update = TranscriptUpdate(finals: [], partial: nil)
        consumeTask = _Concurrency.Task {
            for await value in session.updates {
                guard !_Concurrency.Task.isCancelled else { return }
                update = value
            }
        }
        do {
            try await session.start()
            guard isVisible, self.session != nil else { await session.cancel(); return }
            recordingStarted = Date()
            recording = true
            limitTask = _Concurrency.Task {
                try? await _Concurrency.Task.sleep(for: .seconds(env.defaults.capture.maxRecordingSeconds))
                guard !_Concurrency.Task.isCancelled else { return }
                limitTask = nil
                await stopRecording()
            }
        } catch {
            speechError = (error as? MovoError)?.message ?? "录音没有开始，请检查麦克风权限。"
            cancelRecording()
        }
    }

    private func stopRecording() async {
        guard let session, recording, !stopping else { return }
        stopping = true
        limitTask?.cancel()
        let final = await session.stop()
        guard self.session != nil else { stopping = false; return }
        appendTranscript(final.hasReliableText ? final.text : update.displayText)
        if !final.hasReliableText { speechError = "转写未能完整结束，已保留识别到的文字，请核对后提交。" }
        consumeTask?.cancel()
        self.session = nil
        recording = false
        stopping = false
        env.endSpeechSession()
    }

    private func appendTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        env.captureText += (env.captureText.isEmpty ? "" : "\n") + text
        env.captureInputMode = .voice
    }

    private func cancelRecording() {
        let previous = session
        session = nil
        recording = false
        consumeTask?.cancel()
        limitTask?.cancel()
        update = TranscriptUpdate(finals: [], partial: nil)
        _Concurrency.Task { await previous?.cancel() }
        env.endSpeechSession()
    }

    private func preserveRecordingAndCancel() {
        if recording { appendTranscript(update.displayText) }
        cancelRecording()
    }

    private func close() {
        preserveRecordingAndCancel()
        router.dismissSheet()
    }
}

public struct RecordingSheet: View {
    public init() {}
    public var body: some View { QuickCaptureSheet(mode: .voice) }
}


// MARK: - M04-Transcript 可编辑转写

public struct TranscriptSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let captureID: UUID
    @State private var text = ""
    @State private var loaded = false
    @State private var isSubmitting = false

    public init(captureID: UUID) { self.captureID = captureID }

    public var body: some View {
        MovoSheet {
            MovoSheetHeader("核对一下转写", subtitle: "人名、数字和专有名词可以在这里改。",
                            onClose: { router.dismissSheet() })

            MovoTextField("", text: $text, placeholder: "转写内容", axis: .vertical)
                .lineLimit(4...12)

            MovoBanner(kind: .info, title: "转写在本机完成",
                       message: "只有你确认发送的这段文字会用于整理。")

            HStack(spacing: MovoSpace.s) {
                MovoButton("确认并整理", isEnabled: !trimmed.isEmpty, isLoading: isSubmitting) {
                    _Concurrency.Task { await confirm() }
                }
                MovoButton("重录", kind: .quiet) { router.present(.recording) }
                Spacer(minLength: 0)
            }
        }
        .background(MovoColor.bg)
        .task {
            guard !loaded else { return }
            loaded = true
            if let capture = await env.store.repository.capture(captureID) {
                text = capture.editedText ?? capture.rawText
            }
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func confirm() async {
        guard !trimmed.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        guard await env.updateCaptureState(captureID, state: .saved, editedText: trimmed) else { return }
        router.dismissSheet()
        router.push(.processing(captureID: captureID))
        await env.processCapture(captureID)
    }
}
