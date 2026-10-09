//
//  SpeechCapabilityTests.swift
//  MovoPrivacyTests
//
//  语音能力门禁回归：7.1 的固定顺序是「麦克风权限 → 语言支持 → 端侧能力」，
//  语言资源是否已安装只决定要不要提示下载，**不能**当作放行条件。
//
//  背景（实测）：AssetInventory.status 对 Locale("zh-Hans") 长期返回 .supported
//  而非 .installed（规范化的 zh_CN 才是已安装态），但同一个 transcriber 对中文
//  音频转写本身是成功的。旧实现要求 resources == .installed 才放行，
//  于是 mac 与 iOS 两端点录音都会被判为「语言资源未安装」而直接拒绝。
//

import XCTest
import MovoKit

final class SpeechCapabilityTests: XCTestCase {

    // MARK: - 放行条件

    func testResourceNotInstalledDoesNotBlockRecording() {
        let capability = SpeechCapability(
            mic: .granted, supported: true, onDevice: true, resources: .notInstalled)

        XCTAssertTrue(capability.canRecord,
                      "资源未安装不能阻断录音：系统会在首次分析时自行准备模型")
        XCTAssertTrue(capability.needsResourceDownload,
                      "资源未安装应当提示可下载")
    }

    func testDownloadingResourceDoesNotBlockRecording() {
        let capability = SpeechCapability(
            mic: .granted, supported: true, onDevice: true, resources: .downloading(percent: 0.4))

        XCTAssertTrue(capability.canRecord, "下载中不应阻断录音")
        XCTAssertTrue(capability.needsResourceDownload, "下载中仍应展示进度")
    }

    func testInstalledAndUnknownResourceNeedNoDownload() {
        let installed = SpeechCapability(
            mic: .granted, supported: true, onDevice: true, resources: .installed)
        XCTAssertTrue(installed.canRecord)
        XCTAssertFalse(installed.needsResourceDownload)

        let unknown = SpeechCapability(
            mic: .granted, supported: true, onDevice: true, resources: .unknown)
        XCTAssertTrue(unknown.canRecord, "资源状态未知时不能把功能判死")
        XCTAssertFalse(unknown.needsResourceDownload)
    }

    func testDeniedMicrophoneBlocksRecording() {
        for mic in [PermissionState.denied, .restricted, .undetermined] {
            let capability = SpeechCapability(
                mic: mic, supported: true, onDevice: true, resources: .installed)
            XCTAssertFalse(capability.canRecord, "\(mic.rawValue) 状态不应放行录音")
        }
    }

    func testUnsupportedLocaleBlocksRecording() {
        let capability = SpeechCapability(
            mic: .granted, supported: false, onDevice: false,
            resources: .unsupported, failureReason: .unsupportedLocale)

        XCTAssertFalse(capability.canRecord)
        XCTAssertFalse(capability.needsResourceDownload, "不支持的语言没有可下载的资源")
    }

    func testOnDeviceUnavailableBlocksRecording() {
        let capability = SpeechCapability(
            mic: .granted, supported: false, onDevice: false,
            resources: .unsupported, failureReason: .onDeviceUnavailable)

        XCTAssertFalse(capability.canRecord, "设备不支持本机识别时不应放行")
    }

    // MARK: - 服务替身

    func testMockServicePassesThroughInjectedCapability() async {
        let injected = SpeechCapability(
            mic: .denied, supported: true, onDevice: true, resources: .installed)
        let service = MockSpeechTranscriptionService(capability: injected)

        let capability = await service.capability(locale: SpeechDefaults.preferredLocale)
        XCTAssertEqual(capability, injected)
    }

    func testEnsureResourcesReportsCompletion() async throws {
        let service = MockSpeechTranscriptionService()
        let recorder = ProgressRecorder()

        try await service.ensureResources(locale: SpeechDefaults.preferredLocale) {
            recorder.record($0)
        }

        XCTAssertEqual(recorder.recorded, [1], "安装结束必须报告 1.0，界面据此收起进度")
    }

    // MARK: - 首选语言

    func testPreferredLocaleIsSimplifiedChinese() {
        XCTAssertEqual(SpeechDefaults.preferredLocale.identifier, "zh-Hans",
                       "首选语言是简中；系统会把它归一化成 zh_CN 后再查资源")
    }
}

/// 收集进度回调：回调是 @Sendable，不能直接写外部变量。
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }

    var recorded: [Double] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
