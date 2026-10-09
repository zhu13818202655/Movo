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

// MARK: - 常量

/// 语音相关常量。能力检查、资源安装与录音会话必须共用同一份首选语言，
/// 不能再各处各自硬编码：`zh-Hans` 会被系统归一化成 `zh_CN`，
/// 两处写法不一致时，资源判定与会话实际使用的语言会错位。
public enum SpeechDefaults {
    /// 首选转写语言。
    public static let preferredLocale = Locale(identifier: "zh-Hans")
}

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
    /// 尚未安装、可以走 `ensureResources` 下载。
    public var needsDownload: Bool { self == .notInstalled }
    /// 正在下载中。
    public var isInstalling: Bool {
        if case .downloading = self { return true }
        return false
    }
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
    ///
    /// 资源安装状态**不**参与放行：`AssetInventory.status` 对 `zh-Hans` 长期返回
    /// `.supported`（而非 `.installed`），但系统会在首次分析时自行准备模型，
    /// 转写本身可用。把它当作放行条件会把可用能力误判成不可用（原缺陷）。
    /// 资源未就绪只用于提示下载，见 `needsResourceDownload`。
    public var canRecord: Bool {
        mic.isGranted && supported && onDevice
    }

    /// 资源尚未就绪或正在下载：界面可以提示并提供下载入口（7.1 第 4 步）。
    public var needsResourceDownload: Bool {
        resources.needsDownload || resources.isInstalling
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
    /// 本次采集是否收到过非静音音频（仅幅度元数据，不保存也不记录音频内容）。
    /// 用来区分"麦克风没进来音频"和"有音频但没识别出文字"。
    public var didCaptureAudio: Bool
    public var failureReason: SpeechFailReason?

    public init(finals: [String], didTimeOut: Bool = false,
                didCaptureAudio: Bool = true,
                failureReason: SpeechFailReason? = nil) {
        self.finals = finals; self.didTimeOut = didTimeOut
        self.didCaptureAudio = didCaptureAudio; self.failureReason = failureReason
    }

    public var text: String { finals.joined() }
    public var hasReliableText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 服务协议（7.2）

public protocol SpeechTranscriptionService: Sendable {
    func capability(locale: Locale) async -> SpeechCapability
    /// 安装语言资源；通过 `onProgress` 报告 0…1 进度。用户确认后才调用（7.1 第 4 步）。
    func ensureResources(locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws
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
    /// 采集缓冲流。必须持有：`stopAudioEngine()` 要靠它结束流，
    /// 否则 `pump` 的 `for await` 永不退出，`stop()` 会跟着挂死（原缺陷）。
    private var boxContinuation: AsyncStream<AudioBufferBox>.Continuation?
    private var consumerTask: _Concurrency.Task<Void, Never>?
    private var captureTask: _Concurrency.Task<Void, Never>?
    /// 分析任务由 `stop()` 统一等待，`pump` 自己不等它（否则与 `stop()` 互相等待）。
    private var analysisTask: _Concurrency.Task<Void, Never>?
    private var finals: [String] = []
    private var partial: String?
    private var isCancelled = false
    private let levelMeter = PeakMeter()

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
        // iOS 必须先切到录音类别并激活会话，否则 inputNode 会给出 0Hz/0 通道格式。
        try Self.activateAudioSession()
        levelMeter.reset()
        do {
            // 与 capability() 用同一套归一化结果，避免"检查用 zh_CN、录音用 zh-Hans"。
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
            let transcriber = SpeechTranscriber(
                locale: resolved, preset: .progressiveTranscription)
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
            self.boxContinuation = boxContinuation
            try startAudioEngine()

            // 采集 → 转换 → 分析
            captureTask = _Concurrency.Task { [weak self] in
                guard let self else { return }
                await self.pump(boxStream, into: analyzer)
            }

            emitUpdate()
        } catch {
            // 失败时不留半启动状态：引擎、任务与分析器一起收回。
            resetAfterStartFailure()
            throw Self.mapStartFailure(error)
        }
    }

    /// stop()：等待最后 final 片段（3s 超时兜底，超时用已得 finals）。
    ///
    /// 三步各有上限，任何一步超时都继续往下走，`stop()` 一定会返回：
    /// 1. 采集收尾；2. 显式通知分析器结束输入；3. 等分析/结果流退出。
    /// 不能用 `withTaskGroup` 做竞速——作用域退出时会隐式等待所有子任务，
    /// 只要有一个永不结束，`stop()` 就再也回不来（原缺陷）。
    public func stop() async -> TranscriptFinal {
        guard let analyzer else {
            return TranscriptFinal(finals: finals,
                                   didCaptureAudio: levelMeter.didCaptureAudio,
                                   failureReason: .transcriptionFailed)
        }
        stopAudioEngine()

        let captureTask = self.captureTask
        let analysisTask = self.analysisTask
        let consumerTask = self.consumerTask
        let timeout = stopTimeoutSeconds

        var didTimeOut = false
        if let captureTask {
            didTimeOut = await !Self.raceToFinish(captureTask, timeout: timeout)
        }
        // 只有这一步会真正让 analyzeSequence 返回（见 pump 注释）。
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        if let analysisTask {
            _ = await Self.raceToFinish(analysisTask, timeout: timeout)
        }
        if let consumerTask {
            _ = await Self.raceToFinish(consumerTask, timeout: timeout)
        }

        self.captureTask = nil
        self.analysisTask = nil
        transcriber = nil
        self.analyzer = nil
        updateContinuation.finish()

        let failure: SpeechFailReason? = finals.isEmpty ? .transcriptionFailed : nil
        return TranscriptFinal(finals: finals, didTimeOut: didTimeOut,
                               didCaptureAudio: levelMeter.didCaptureAudio,
                               failureReason: failure)
    }

    public func cancel() {
        isCancelled = true
        stopAudioEngine()
        consumerTask?.cancel()
        captureTask?.cancel()
        analysisTask?.cancel()
        _Concurrency.Task { [analyzer] in await analyzer?.cancelAndFinishNow() }
        consumerTask = nil
        captureTask = nil
        analysisTask = nil
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

        // analyzeSequence 不会因为音频流结束而返回，要等 finalizeAndFinishThroughEndOfInput()。
        // 因此这里**不能**等它：否则 stop() 里「先等 pump、再 finalize」会死锁。
        // 分析任务交给 stop() 统一收尾。
        analysisTask = _Concurrency.Task {
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
        // 采集结束即封口，分析器才能进入收尾。
        inputContinuation.finish()
    }

    private func startAudioEngine() throws {
        guard let continuation = boxContinuation else {
            throw MovoError.speechUnavailable(reason: .transcriptionFailed)
        }
        let meter = levelMeter
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // ⚠️ installTap 传入的 buffer 只在回调期间有效，而消费端（actor 上的 pump）
            // 落后于实时：CoreAudio 会复用/覆盖同一块内存。跨隔离边界前必须深拷贝，
            // 否则分析器拿到的是被改写的音频，表现为"录音正常、永远转不出文字"。
            guard let copy = Self.detachedCopy(of: buffer) else { return }
            meter.observe(buffer)
            continuation.yield(AudioBufferBox(buffer: copy))
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

    /// 深拷贝 tap 回调里的音频缓冲，使其可以安全地跨隔离边界传递。
    private static func detachedCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                          frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        copy.frameLength = AVAudioFrameCount(frames)
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
        } else {
            return nil
        }
        return copy
    }

    private func handleAutoStop() {
        guard !isCancelled, engine != nil else { return }
        stopAudioEngine()
    }

    /// 结束采集。**必须** finish 掉缓冲流，否则 `pump` 的 `for await` 永不退出，
    /// 采集任务永不完成，`stop()` 会一直卡在等它。
    private func stopAudioEngine() {
        if let engine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        boxContinuation?.finish()
        boxContinuation = nil
        Self.deactivateAudioSession()
    }

    /// 启动失败时收回半启动状态；不 finish `updates`，交给调用方的 `cancel()`。
    private func resetAfterStartFailure() {
        consumerTask?.cancel()
        captureTask?.cancel()
        analysisTask?.cancel()
        consumerTask = nil
        captureTask = nil
        analysisTask = nil
        if let engine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        boxContinuation?.finish()
        boxContinuation = nil
        transcriber = nil
        analyzer = nil
        Self.deactivateAudioSession()
    }

    private static func mapStartFailure(_ error: Error) -> MovoError {
        if let movo = error as? MovoError { return movo }
        return .speechUnavailable(reason: .transcriptionFailed)
    }

    // MARK: 音频会话（仅 iOS）

    /// iOS 不配置会话时，`inputNode` 会给出 0 采样率格式，`installTap`/`engine.start()` 直接失败。
    /// 失败不静默降级，按 `MovoError` 抛出（PRD 4.4：不暗中改用云端）。
    private static func activateAudioSession() throws {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            throw MovoError.speechUnavailable(reason: .interrupted)
        }
        #endif
    }

    private static func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    // MARK: 有界等待

    /// 等待任务完成；超时返回 false 并放行。
    /// 刻意不用 `withTaskGroup`：作用域退出时会隐式等待全部子任务，
    /// 一旦被等待的任务永不结束，调用方就再也不能返回。
    private static func raceToFinish(_ task: _Concurrency.Task<Void, Never>,
                                     timeout: Double) async -> Bool {
        let gate = OnceGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            _Concurrency.Task {
                await task.value
                if gate.claim() { continuation.resume(returning: true) }
            }
            _Concurrency.Task {
                try? await _Concurrency.Task.sleep(for: .seconds(timeout))
                if gate.claim() { continuation.resume(returning: false) }
            }
        }
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

/// 只能被认领一次的闸门：用于竞速等待，保证 continuation 恰好恢复一次。
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }

    var isClaimed: Bool {
        lock.lock(); defer { lock.unlock() }
        return claimed
    }
}

/// 采集幅度计。只保留峰值这一项元数据，不保存、不记录、不导出任何音频内容。
/// 用途是把「麦克风没进来音频」与「有音频但没识别出文字」分开，便于用户直接对症处理。
final class PeakMeter: @unchecked Sendable {
    /// 低于此峰值视为全程静音（麦克风未授权或被系统喂静音时恰好为 0）。
    static let silenceThreshold: Float = 0.0005

    private let lock = NSLock()
    private var peak: Float = 0

    func observe(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        var local: Float = 0
        if let data = buffer.floatChannelData {
            for ch in 0..<channels {
                let samples = data[ch]
                for i in 0..<frames { local = max(local, abs(samples[i])) }
            }
        } else if let data = buffer.int16ChannelData {
            for ch in 0..<channels {
                let samples = data[ch]
                for i in 0..<frames { local = max(local, abs(Float(samples[i]) / 32768)) }
            }
        } else if let data = buffer.int32ChannelData {
            for ch in 0..<channels {
                let samples = data[ch]
                for i in 0..<frames { local = max(local, abs(Float(samples[i]) / 2147483648)) }
            }
        } else {
            return
        }
        lock.lock()
        peak = max(peak, local)
        lock.unlock()
    }

    func reset() {
        lock.lock(); peak = 0; lock.unlock()
    }

    var observedPeak: Float {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    var didCaptureAudio: Bool { observedPeak > Self.silenceThreshold }
}

// MARK: - 生产实现（SpeechAnalyzer / SpeechTranscriber）

public struct AppleSpeechTranscriptionService: SpeechTranscriptionService {
    private let defaults: AppDefaults

    public init(defaults: AppDefaults = .fallback) { self.defaults = defaults }

    public func capability(locale: Locale) async -> SpeechCapability {
        // 1. 麦克风权限（7.1 第 1 步）
        let mic = await Self.microphonePermission()

        // 2. 端侧能力与语言支持（7.1 第 2 步）
        guard SpeechTranscriber.isAvailable else {
            return SpeechCapability(mic: mic, supported: false, onDevice: false,
                                    resources: .unsupported, failureReason: .onDeviceUnavailable)
        }
        // 归一化 locale：AssetInventory 按规范化结果记账（zh-Hans → zh_CN）。
        // 直接拿 zh-Hans 查询会长期返回 .supported，把可用能力误判为不可用。
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return SpeechCapability(mic: mic, supported: false, onDevice: false,
                                    resources: .unsupported, failureReason: .unsupportedLocale)
        }

        // 3. 本机资源状态：只决定是否需要提示下载（7.1 第 4 步），不参与放行
        let transcriber = SpeechTranscriber(locale: resolved, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        let resources: SpeechResourceState
        switch status {
        case .installed: resources = .installed
        case .downloading: resources = .downloading(percent: 0)
        case .supported: resources = .notInstalled
        case .unsupported: resources = .unsupported
        @unknown default: resources = .unknown
        }
        guard resources != .unsupported else {
            return SpeechCapability(mic: mic, supported: false, onDevice: false,
                                    resources: .unsupported, failureReason: .unsupportedLocale)
        }

        // isAvailable 为真且 locale 受支持 → 端侧转写能力可用；
        // 资源未安装只影响是否需要先下载。
        return SpeechCapability(mic: mic, supported: true, onDevice: true, resources: resources)
    }

    public func ensureResources(locale: Locale,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(locale: resolved, preset: .progressiveTranscription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            // 没有安装请求 = 资源已就绪
            onProgress(1)
            return
        }

        // AssetInstallationRequest 是 Sendable，可以丢进子任务下载，同时轮询进度。
        let gate = OnceGate()
        let install = _Concurrency.Task {
            defer { _ = gate.claim() }
            try await request.downloadAndInstall()
        }

        var waited = 0.0
        while !gate.isClaimed, waited < 900 {
            onProgress(Double(request.progress.fractionCompleted))
            try? await _Concurrency.Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        onProgress(Double(request.progress.fractionCompleted))

        do { try await install.value }
        catch { throw MovoError.speechUnavailable(reason: .resourceMissing) }
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

    public func ensureResources(locale: Locale,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        onProgress(1)
    }

    public func makeSession(locale: Locale) -> SpeechSession {
        SpeechSession(locale: locale)
    }
}
