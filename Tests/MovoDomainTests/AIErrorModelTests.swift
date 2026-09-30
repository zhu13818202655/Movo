//
//  AIErrorModelTests.swift
//  MovoDomainTests
//
//  4.5 错误模型回归：AI 调用失败的分类、可执行解释与恢复入口。
//
//  为什么单列一组：自定义厂商（OpenAI 兼容）由用户自己填 Base URL，
//  失败原因集中在「地址 / 协议 / 证书 / 模型 ID」上。这些原因若不从
//  「网络不可用」里区分出来，用户既不知道该改什么，也会把配置问题
//  误当成整理失败（M04-Failed）。
//

import Foundation
import XCTest
import MovoKit

final class AIErrorModelTests: XCTestCase {

    // MARK: - 配置缺失 ≠ 调用失败

    func testConfigurationGapCoversNoKeyAndIncompleteVendor() {
        XCTAssertTrue(MovoError.noKey(vendor: .deepseek).isConfigurationGap)
        XCTAssertTrue(MovoError.providerNotConfigured(vendor: .custom).isConfigurationGap)

        XCTAssertFalse(MovoError.aiFailed(stage: .network,
                                          cause: AIFailureCause.atsPlainHTTP).isConfigurationGap)
        XCTAssertFalse(MovoError.aiFailed(stage: .auth, cause: "http_401").isConfigurationGap)
        XCTAssertFalse(MovoError.cancelled.isConfigurationGap)
    }

    func testProviderNotConfiguredReadsNaturallyAndOffersSettings() {
        let error = MovoError.providerNotConfigured(vendor: .custom)
        XCTAssertEqual(error.title, "还没有填完自定义厂商信息")
        XCTAssertEqual(error.recoveryActions, [.openSettings(section: .ai), .editText])
        XCTAssertNil(error.diagnosticDetail, "非 aiFailed 没有诊断细节")
        XCTAssertFalse(error.isRetryable)
    }

    func testInvalidRequestStageHasItsOwnTitle() {
        let error = MovoError.aiFailed(stage: .invalidRequest, cause: "http_404")
        XCTAssertEqual(error.title, "服务端拒绝了这次请求")
        XCTAssertEqual(error.recoveryActions, [.openSettings(section: .ai), .editText],
                       "端点或模型不对要引导改设置，重试没有意义")
    }

    // MARK: - 已知失败分类 → 可执行解释

    /// 每条解释都必须指出「下一步做什么」，不能只说「网络不可用」
    func testKnownCausesProduceActionableExplanations() {
        let expected: [(String, String)] = [
            (AIFailureCause.atsPlainHTTP, "明文 HTTP"),
            (AIFailureCause.tlsUntrusted, "证书"),
            (AIFailureCause.dnsFailure, "主机名"),
            (AIFailureCause.connectionRefused, "端口"),
            (AIFailureCause.offline, "没有网络"),
            (AIFailureCause.connectionLost, "断开"),
            ("http_400", "模型 ID"),
            ("http_422", "模型 ID"),
            ("http_404", "Base URL"),
            ("http_405", "POST"),
            ("chat_envelope", "JSON"),
            ("chat_items", "JSON"),
            ("endpoint_invalid", "Base URL")
        ]
        for (cause, keyword) in expected {
            let detail = MovoError.aiFailed(stage: .network, cause: cause).diagnosticDetail
            XCTAssertEqual(detail?.contains(keyword), true,
                           "cause=\(cause) 的解释里应提到「\(keyword)」")
        }
    }

    func testUnknownCauseFallsBackToStageCopy() {
        let error = MovoError.aiFailed(stage: .network, cause: "urlerror_-9999")
        XCTAssertNil(error.diagnosticDetail)
        XCTAssertEqual(error.message, "当前网络不可用，原文已经保存。")
    }

    func testDiagnosticDetailIsSurfacedInMessage() {
        let error = MovoError.aiFailed(stage: .network, cause: AIFailureCause.atsPlainHTTP)
        XCTAssertEqual(error.diagnosticDetail ?? "", error.message)
    }

    // MARK: - 重试策略（8.6）

    func testDeterministicCausesAreNotRetryable() {
        for cause in [AIFailureCause.atsPlainHTTP,
                      AIFailureCause.tlsUntrusted,
                      AIFailureCause.dnsFailure] {
            XCTAssertFalse(MovoError.aiFailed(stage: .network, cause: cause).isRetryable,
                           "cause=\(cause) 重试只会重复失败")
        }
        // 网络抖动仍照常重试
        XCTAssertTrue(MovoError.aiFailed(stage: .network,
                                         cause: AIFailureCause.connectionRefused).isRetryable)
        XCTAssertTrue(MovoError.aiFailed(stage: .timeout, cause: "timeout").isRetryable)
        XCTAssertTrue(MovoError.aiFailed(stage: .rateLimited, cause: "http_429").isRetryable)
        // 非网络阶段一律不重试
        XCTAssertFalse(MovoError.aiFailed(stage: .invalidRequest, cause: "http_404").isRetryable)
        XCTAssertFalse(MovoError.aiFailed(stage: .auth, cause: "http_401").isRetryable)
    }

    // MARK: - 日志脱敏（8.8）

    func testLogMetadataCarriesOnlyStageAndCause() {
        let metadata = MovoError.aiFailed(stage: .network,
                                          cause: AIFailureCause.atsPlainHTTP).logMetadata
        XCTAssertEqual(metadata["kind"], "aiFailed")
        XCTAssertEqual(metadata["stage"], "network")
        XCTAssertEqual(metadata["cause"], AIFailureCause.atsPlainHTTP)
        XCTAssertEqual(metadata.count, 3)
    }
}
