//
//  RedactedLogger.swift
//  Intelligence/Support
//
//  8.8 日志脱敏。AI 链路只输出
//  { provider, model, status, latencyMs, tokens, itemCount, rejectedCount }；
//  禁止输出请求/响应正文、Key、设备 ID。
//

import Foundation
import os

public struct RedactedLogger: Sendable {
    public typealias Sink = @Sendable (String) -> Void

    private static let logger = os.Logger(subsystem: "com.example.movo", category: "ai")

    private let sink: Sink

    public init(sink: @escaping Sink = RedactedLogger.defaultSink) { self.sink = sink }

    public static func defaultSink(_ line: String) {
        logger.info("\(line, privacy: .public)")
    }

    /// 8.7 + 8.8：一次调用的脱敏记录。
    public func logAICall(provider: String, model: String, status: String, latencyMs: Int,
                          promptTokens: Int, completionTokens: Int,
                          itemCount: Int, rejectedCount: Int) {
        let line = [
            "ai_call",
            "provider=\(provider)",
            "model=\(model)",
            "status=\(status)",
            "latency_ms=\(latencyMs)",
            "prompt_tokens=\(promptTokens)",
            "completion_tokens=\(completionTokens)",
            "item_count=\(itemCount)",
            "rejected_count=\(rejectedCount)"
        ].joined(separator: " ")
        sink(line)
    }

    /// 校验拒绝项的脱敏记录（只记数量与原因枚举，不记正文）。
    public func logValidation(rejectedCount: Int, mergedDuplicates: Int, correctionCount: Int) {
        sink("ai_validation rejected_count=\(rejectedCount) merged=\(mergedDuplicates) corrections=\(correctionCount)")
    }

    // MARK: - CI 扫描（PT：日志不得出现任务标题 / Capture 原文 / 测量值）

    /// 在给定 forbidden 词表中查找违规项（样例文本，CI 用）。返回命中的词。
    public static func scan(_ line: String, forbidden: [String]) -> [String] {
        forbidden.filter { !$0.isEmpty && line.contains($0) }
    }
}
