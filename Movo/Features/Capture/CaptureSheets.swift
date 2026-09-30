//
//  CaptureSheets.swift
//  Features/Capture
//
//  D04 Mac 快速输入浮层 / M04-Recording 语音录入 / M04-Transcript 可编辑转写 /
//  M04-LocalOnly 敏感计划本地录入。
//

import SwiftUI
import MovoKit

public enum QuickCaptureMode: String, Sendable { case text, voice }

// MARK: - D04 快速输入

public struct QuickCaptureSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let mode: QuickCaptureMode
    @State private var text: String = ""
    @State private var isSubmitting = false

    public init(mode: QuickCaptureMode = .text) { self.mode = mode }

    public var body: some View {
        MovoSheet {
            MovoSheetHeader("记下一件事", subtitle: "可以是一句待办，也可以是随口一提的想法。",
                            onClose: { router.dismissSheet() })

            MovoTextField("", text: $text,
                          placeholder: mode == .voice ? "刚才说的话会出现在这里" : "例如：明天把季度汇报的数据补齐",
                          axis: .vertical)
                .lineLimit(2...8)

            Text("整理只发生在你确认之后；健康与敏感计划的内容不会发送到云端。")
                .font(MovoFont.caption)
                .foregroundStyle(MovoColor.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: MovoSpace.s) {
                MovoButton("开始整理", isEnabled: !trimmed.isEmpty, isLoading: isSubmitting) {
                    _Concurrency.Task { await submit() }
                }
                MovoButton("先用语音", kind: .quiet) { router.present(.recording) }
                Spacer(minLength: 0)
            }
        }
        .background(MovoColor.bg)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() async {
        guard !trimmed.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        guard let captureID = await env.submitCapture(text: trimmed, inputMode: .text) else { return }
        router.dismissSheet()
        router.push(.processing(captureID: captureID))
        await env.processCapture(captureID)
    }
}

// MARK: - M04-Recording 语音录入

public struct RecordingSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    @State private var capability: SpeechCapability?
    @State private var update = TranscriptUpdate(finals: [], partial: nil)
    @State private var isRecording = false
    @State private var session: SpeechSession?
    @State private var consumeTask: _Concurrency.Task<Void, Never>?

    public init() {}

    public var body: some View {
        MovoSheet {
            MovoSheetHeader("语音记下一件事", subtitle: "转写在本机完成，音频不会上传。",
                            onClose: close)

            if let capability, !capability.canRecord {
                unavailable(capability)
            } else {
                HStack(spacing: MovoSpace.s) {
                    Image(systemName: "waveform")
                        .font(.system(size: 22))
                        .foregroundStyle(isRecording ? MovoColor.primary : MovoColor.muted)
                    Text(isRecording ? "正在听…" : "准备好了")
                        .font(MovoFont.bodyEmphasis)
                        .foregroundStyle(MovoColor.ink)
                    Spacer(minLength: 0)
                    if isRecording {
                        Text("上限 3 分钟")
                            .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                    }
                }

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                        .fill(MovoColor.soft)
                    Text(displayText.isEmpty ? "开始说话后会在这里出现文字" : displayText)
                        .font(MovoFont.body)
                        .foregroundStyle(displayText.isEmpty ? MovoColor.muted : MovoColor.ink)
                        .padding(MovoSpace.s)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 120, alignment: .topLeading)

                HStack(spacing: MovoSpace.s) {
                    if isRecording {
                        MovoButton("停止并整理", kind: .primary) { _Concurrency.Task { await stopAndContinue() } }
                    } else {
                        MovoButton("开始录音", kind: .primary) { _Concurrency.Task { await begin() } }
                    }
                    MovoButton("改成文字输入", kind: .quiet) {
                        router.present(.quickCapture)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .background(MovoColor.bg)
        .task { capability = await env.speech.capability(locale: Locale(identifier: "zh-Hans")) }
        .onDisappear { cancel() }
    }

    private var displayText: String { update.displayText }

    @ViewBuilder
    private func unavailable(_ capability: SpeechCapability) -> some View {
        MovoBanner(kind: .warning, title: "暂时无法使用语音",
                   message: capability.failureReason?.displayName ?? "可以先改成文字输入，原文不会丢。",
                   actions: [("改成文字输入", { router.present(.quickCapture) })])
    }

    // MARK: 会话

    private func begin() async {
        let session = env.startSpeechSession()
        self.session = session
        consumeTask = _Concurrency.Task {
            for await value in session.updates { update = value }
        }
        do {
            try await session.start()
            isRecording = true
        } catch let error as MovoError {
            env.lastError = error
        } catch {
            env.lastError = .speechUnavailable(reason: .transcriptionFailed)
        }
    }

    private func stopAndContinue() async {
        guard let session else { return }
        isRecording = false
        let final = await session.stop()
        env.lastTranscript = final
        consumeTask?.cancel()
        env.endSpeechSession()

        guard final.hasReliableText else {
            env.lastError = .speechUnavailable(reason: final.failureReason ?? .transcriptionFailed)
            return
        }
        guard let captureID = await env.submitCapture(text: final.text, inputMode: .voice) else { return }
        router.dismissSheet()
        router.push(.transcript(captureID: captureID))
    }

    private func close() {
        cancel()
        router.dismissSheet()
    }

    private func cancel() {
        session?.cancel()
        consumeTask?.cancel()
        env.endSpeechSession()
        isRecording = false
    }
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
        await env.updateCaptureState(captureID, state: .saved)
        router.dismissSheet()
        router.push(.processing(captureID: captureID))
        await env.processCapture(captureID)
    }
}

// MARK: - M04-LocalOnly 敏感计划本地录入

public struct LocalOnlyCaptureSheet: View {
    @Environment(\.movoRouter) private var router

    public init() {}

    public var body: some View {
        MovoSheet {
            MovoSheetHeader("这段内容留在本机", subtitle: "涉及健康或你标记为敏感的计划。",
                            onClose: { router.dismissSheet() })

            MovoBanner(kind: .info, title: "不会发送到云端",
                       message: "Movo 只在本机做匹配：能对上的安排直接记录，其余放进收件箱等你归类。")

            HStack(spacing: MovoSpace.s) {
                MovoButton("我知道了", kind: .primary) { router.dismissSheet() }
                MovoButton("去收件箱", kind: .quiet) { router.go(to: .section(.inbox), in: .inbox) }
                Spacer(minLength: 0)
            }
        }
        .background(MovoColor.bg)
    }
}
