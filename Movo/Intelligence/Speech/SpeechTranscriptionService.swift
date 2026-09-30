//
//  SpeechTranscriptionService.swift
//  Intelligence/Speech
//
//  7 语音转写（本机）。SpeechAnalyzer + SpeechTranscriber，仅 on-device，
//  不满足 on-device 则不开放录音（转文字），不暗中上传（PRD 4.4 / 11.2）。
//

import Foundation
import AVFoundation
import Speech

// MARK: - 能力模型

public enum PermissionState: String, Hashable, Sendable, CaseIterable {
    case undetermined, granted, denied, restricted
    public var isGranted: Bool { self == .granted }
}

public enum SpeechResourceState: Hashable, Sendable {
    case unknown
    case unsupported
    case notInstalled
    case downloading(percent: Double)
    case installed

    public var isInstalled: Bool { self == .installed }
    public var displayName: String {
        switch self {
        case .unknown: "未知"
        case .unsupported: "不支持该语言"
        case .notInstalled: "语言资源未安装"
        case .downloading(let p): "下载中 \(Int(p * 100))%"
        case .installed: "已就绪"
        }
    }
}

public struct SpeechCapability: Hashable, Sendable {
    public var mic: PermissionState
    public var supported: Bool
    public var onDevice: Bool
    public var resources: SpeechResourceState
    /// 该 locale 上不支持时的原因（用于 02 States B）
    public var failureReason: SpeechFailReason?

    public init(mic: PermissionState, supported: Bool, onDevice: Bool,
                resources: SpeechResourceState, failureReason: SpeechFailReason? = nil) {
        self.mic = mic; self.supported = supported; self.onDevice = onDevice
        self.resources = resources; self.failureReason = failureReason
    }

    /// 7.1 固定顺序全部通过才允许录音。
    public var canRecord: Bool {
        mic.isGranted && supported && onDevice && resources.isInstalled
    }
}

// MARK: - 转写结果

public struct TranscriptUpdate: Hashable, Sendable {
    public var finals: [String]
    public var partial: String?
    public init(finals: [String], partial: String?) { self.finals = finals; self.partial = partial }

    /// 7.2：finals 追加，partial 单独渲染在末尾。
    public var displayText: String {
        var s = finals.joined()
        if let partial, !partial.isEmpty { s += partial }
        return s
    }
}

public struct TranscriptFinal: Hashable, Sendable {
    public var finals: [String]
    public var didTimeOut: Bool
    public var failureReason: SpeechFailReason?

    public init(finals: [String], didTimeOut: Bool = false,
                failureReason: SpeechFailReason? = nil) {
        self.finals = finals; self.didTimeOut = didTimeOut; self.failureReason = failureReason
    }

    public var text: String { finals.joined() }
    public var hasReliableText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 服务协议（7.2）

public protocol SpeechTranscriptionService: Sendable {
    func capability(locale: Locale) async -> SpeechCapability
    /// 安装语言资源；返回 0…1 进度。用户确认后才调用（7.1 第 4 步）。
    func ensureResources(locale: Locale) async throws -> Double
    func makeSession(locale: Locale) -> SpeechSession
}

// MARK: - 会话

/// 录音 + 转写会话。actor 化以满足 1.3 的并发边界（跨边界只传 Sendable 值）。
public actor SpeechSession {
    public nonisolated let updates: AsyncStream<TranscriptUpdate>

    private let updateContinuation: AsyncStream<TranscriptUpdate>.Continuation
    private let locale: Locale
    private let maxRecordingSeconds: Double
    private let stopTimeoutSeconds: Double

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var engine: AVAudioEngine?
    private var consumerTask: _Concurrency.Task<Void, Never>?
    private var captureTask: _Concurrency.Task<Void, Never>?
    private var finishTask: _Concurrency.Task<Void, Never>?
    private var finals: [String] = []
    private var partial: String?
    private var autoStopContinuation: CheckedContinuation<Void, Never>?
    private var isCancelled = false

    public init(locale: Locale,
                maxRecordingSeconds: Double = AppDefaults.fallback.capture.maxRecordingSeconds,
                stopTimeoutSeconds: Double = AppDefaults.fallback.capture.stopFinalSegmentTimeoutSeconds) {
        self.locale = locale
        self.maxRecordingSeconds = maxRecordingSeconds
        self.stopTimeoutSeconds = stopTimeoutSeconds
        var continuation: AsyncStream<TranscriptUpdate>.Continuation!
        self.updates = AsyncStream { continuation = $0 }
        self.updateContinuation = continuation
    }

    // MARK: 启停（7.3）

    public func start() async throws {
        guard transcriber == nil else { return }
        let transcriber = SpeechTranscriber(
            locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer

        try await analyzer.prepareToAnalyze(in: nil)

        // 结果消费
        consumerTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            await self.consumeResults(transcriber)
        }

        // 音频采集
        let (boxStream, boxContinuation) = Self.makeBufferStream()
        try await startAudioEngine(yielding: boxContinuation)

        // 采集 → 转换 → 分析
        captureTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            await self.pump(boxStream, into: analyzer)
        }

        emitUpdate()
    }

    /// stop()：等待最后 final 片段（3s 超时兜底，超时用已得 finals）。
    public func stop() async -> TranscriptFinal {
        guard let analyzer else {
            return TranscriptFinal(finals: finals, failureReason: .transcriptionFailed)
        }
        stopAudioEngine()

        let captureTask = self.captureTask
        let timeout = stopTimeoutSeconds
        // 第一个完成即继续：false = 正常收尾；true = 3s 超时兜底（7.3）
        let didTimeOut = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await captureTask?.value
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                return false
            }
            group.addTask {
                try? await _Concurrency.Task.sleep(for: .seconds(timeout))
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        await consumerTask?.value
        self.captureTask = nil
        transcriber = nil
        self.analyzer = nil
        updateContinuation.finish()

        let failure: SpeechFailReason? = finals.isEmpty ? .transcriptionFailed : nil
        return TranscriptFinal(finals: finals, didTimeOut: didTimeOut, failureReason: failure)
    }

    public func cancel() {
        isCancelled = true
        stopAudioEngine()
        consumerTask?.cancel()
        captureTask?.cancel()
        _Concurrency.Task { [analyzer] in await analyzer?.cancelAndFinishNow() }
        transcriber = nil
        analyzer = nil
        updateContinuation.finish()
    }

    // MARK: 内部

    private func emitUpdate() {
        updateContinuation.yield(TranscriptUpdate(finals: finals, partial: partial))
    }

    private func consumeResults(_ transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    if !text.isEmpty { finals.append(text) }
                    partial = nil
                } else {
                    partial = text
                }
                emitUpdate()
            }
        } catch {
            // 转写流中断：保留已捕获文字（7.3）
            partial = nil
            emitUpdate()
        }
    }

    private func pump(_ stream: AsyncStream<AudioBufferBox>, into analyzer: SpeechAnalyzer) async {
        let inputFormat = engine?.inputNode.outputFormat(forBus: 0)
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber].compactMap { $0 })
        let converter: AVAudioConverter? = {
            guard let inputFormat, let analyzerFormat else { return nil }
            return AVAudioConverter(from: inputFormat, to: analyzerFormat)
        }()

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        let analysisTask = _Concurrency.Task {
            do { _ = try await analyzer.analyzeSequence(inputStream) } catch { /* 结束或取消 */ }
        }

        for await box in stream {
            if isCancelled { break }
            guard let analyzerFormat else {
                inputContinuation.yield(AnalyzerInput(buffer: box.buffer))
                continue
            }
            if let converted = Self.convert(box.buffer, using: converter, to: analyzerFormat) {
                inputContinuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        inputContinuation.finish()
        _ = await analysisTask.value
    }

    private func startAudioEngine(yielding continuation: AsyncStream<AudioBufferBox>.Continuation) async throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            continuation.yield(AudioBufferBox(buffer: buffer))
        }
        engine.prepare()
        try engine.start()
        self.engine = engine

        // 单段上限 3 分钟：到点自动 finalizing（7.3）
        let limit = maxRecordingSeconds
        _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(limit))
            guard let self else { return }
            await self.handleAutoStop()
        }
    }

    private func handleAutoStop() {
        guard !isCancelled, engine != nil else { return }
        stopAudioEngine()
    }

    private func stopAudioEngine() {
        if let engine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    // MARK: 工具

    private static func makeBufferStream() -> (AsyncStream<AudioBufferBox>, AsyncStream<AudioBufferBox>.Continuation) {
        AsyncStream.makeStream()
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter?,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else {
            // 已是分析器格式
            guard buffer.format == format else { return nil }
            return buffer
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * max(ratio, 1)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}

/// AVAudioPCMBuffer 非 Sendable；采集回调 → actor 边界用此盒子传递。
struct AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

// MARK: - 生产实现（SpeechAnalyzer / SpeechTranscriber）

public struct AppleSpeechTranscriptionService: SpeechTranscriptionService {
    private let defaults: AppDefaults

    public init(defaults: AppDefaults = .fallback) { self.defaults = defaults }

    public func capability(locale: Locale) async -> SpeechCapability {
        // 1. 麦克风权限（7.1 第 1 步）
        let mic = await Self.microphonePermission()

        // 2. 语言支持（7.1 第 2 步）
        guard SpeechTranscriber.isAvailable else {
            return SpeechCapability(mic: mic, supported: false, onDevice: false,
                                    resources: .unsupported, failureReason: .onDeviceUnavailable)
        }
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
        guard supported else {
            return SpeechCapability(mic: mic, supported: false, onDevice: false,
                                    resources: .unsupported, failureReason: .unsupportedLocale)
        }

        // 3–4. 本机资源状态
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        let resources: SpeechResourceState
        switch status {
        case .installed: resources = .installed
        case .downloading: resources = .downloading(percent: 0)
        case .supported: resources = .notInstalled
        case .unsupported: resources = .unsupported
        @unknown default: resources = .unknown
        }

        // 定稿：不满足 on-device 则不开放录音（assets 已安装即视为本机可用）
        let onDevice = (resources == .installed)
        return SpeechCapability(mic: mic, supported: true, onDevice: onDevice, resources: resources)
    }

    public func ensureResources(locale: Locale) async throws -> Double {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return 1
        }
        try await request.downloadAndInstall()
        return Double(request.progress.fractionCompleted)
    }

    public func makeSession(locale: Locale) -> SpeechSession {
        SpeechSession(locale: locale,
                      maxRecordingSeconds: defaults.capture.maxRecordingSeconds,
                      stopTimeoutSeconds: defaults.capture.stopFinalSegmentTimeoutSeconds)
    }

    // MARK: 权限

    static func microphonePermission() async -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .granted : .denied
        @unknown default: return .denied
        }
    }
}

// MARK: - 测试/预览实现

/// 模拟服务：注入预设转写文本，无音频依赖。
public final class MockSpeechTranscriptionService: SpeechTranscriptionService, @unchecked Sendable {
    private let lock = NSLock()
    private var capabilityValue: SpeechCapability
    private let finalText: String

    public init(capability: SpeechCapability = SpeechCapability(
        mic: .granted, supported: true, onDevice: true, resources: .installed),
        finalText: String = "明天把季度汇报的数据补齐") {
        self.capabilityValue = capability
        self.finalText = finalText
    }

    public func capability(locale: Locale) async -> SpeechCapability {
        lock.withLock { capabilityValue }
    }

    public func ensureResources(locale: Locale) async throws -> Double { 1 }

    public func makeSession(locale: Locale) -> SpeechSession {
        SpeechSession(locale: locale)
    }
}
