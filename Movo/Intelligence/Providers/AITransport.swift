//
//  AITransport.swift
//  Intelligence/Providers
//
//  8.6 超时/重试/取消。连接 10s、总 30s；仅网络/429/5xx 自动重试；
//  4xx 鉴权与解析失败不自动重试；取消传播到 URLSession。
//

import Foundation

/// 一次 HTTP 往返的原始结果。
public struct AIHTTPResponse: Hashable, Sendable {
    public let data: Data
    public let statusCode: Int
    public let latencyMs: Int

    public init(data: Data, statusCode: Int, latencyMs: Int) {
        self.data = data; self.statusCode = statusCode; self.latencyMs = latencyMs
    }
}

/// 共享传输层：负责超时、指数退避重试与错误映射（8.3/8.4 同款策略）。
public struct AITransport: Sendable {
    private let session: URLSession
    private let retryCount: Int
    private let backoffSeconds: [Double]

    public init(defaults: AppDefaults, session: URLSession? = nil) {
        self.session = session ?? AITransport.makeDefaultSession(defaults: defaults)
        self.retryCount = max(0, defaults.ai.autoRetryCount)
        self.backoffSeconds = defaults.ai.autoRetryBackoffSeconds.isEmpty
            ? [1, 2] : defaults.ai.autoRetryBackoffSeconds
    }

    public init(session: URLSession, retryCount: Int, backoffSeconds: [Double]) {
        self.session = session
        self.retryCount = max(0, retryCount)
        self.backoffSeconds = backoffSeconds.isEmpty ? [1] : backoffSeconds
    }

    /// 8.6 默认会话：连接超时 10s、资源超时 30s、不等待网络。
    public static func makeDefaultSession(defaults: AppDefaults) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = defaults.ai.connectTimeoutSeconds
        config.timeoutIntervalForResource = defaults.ai.totalTimeoutSeconds
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// 发送请求。成功返回 2xx 响应；否则按 8.6 映射为 MovoError。
    public func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        var lastError: MovoError = .aiFailed(stage: .network, cause: "no_attempt")
        let maxAttempts = retryCount + 1
        var attempt = 0

        while attempt < maxAttempts {
            try _Concurrency.Task.checkCancellation()
            do {
                let start = Date()
                let (data, response) = try await session.data(for: request)
                let latency = Int(Date().timeIntervalSince(start) * 1000)
                guard let http = response as? HTTPURLResponse else {
                    throw MovoError.aiFailed(stage: .unknown, cause: "non_http_response")
                }
                switch http.statusCode {
                case 200...299:
                    return AIHTTPResponse(data: data, statusCode: http.statusCode, latencyMs: latency)
                case 401, 403:
                    // 鉴权失败：不重试（8.3）。
                    throw MovoError.aiFailed(stage: .auth, cause: "http_\(http.statusCode)")
                case 429:
                    lastError = .aiFailed(stage: .rateLimited, cause: "http_429")
                case 500...599:
                    lastError = .aiFailed(stage: .rateLimited, cause: "http_\(http.statusCode)")
                case 400...499:
                    // 其余 4xx 是请求本身的问题（端点路径或模型 ID 不对）：
                    // 不重试，并单独成阶段，避免被渲染成「未知错误」。
                    throw MovoError.aiFailed(stage: .invalidRequest, cause: "http_\(http.statusCode)")
                default:
                    throw MovoError.aiFailed(stage: .unknown, cause: "http_\(http.statusCode)")
                }
            } catch let error as MovoError {
                if !error.isRetryable { throw error }
                lastError = error
            } catch is CancellationError {
                throw MovoError.cancelled
            } catch let urlError as URLError {
                if urlError.code == .cancelled { throw MovoError.cancelled }
                let failure = MovoError.aiFailed(stage: Self.stage(for: urlError.code),
                                                 cause: Self.cause(for: urlError.code))
                // 地址／协议／证书本身不对是确定性失败，重试不会变好
                if !failure.isRetryable { throw failure }
                lastError = failure
            } catch {
                throw MovoError.aiFailed(stage: .unknown, cause: "transport")
            }

            attempt += 1
            if attempt < maxAttempts {
                let delay = backoffSeconds[min(attempt - 1, backoffSeconds.count - 1)]
                try await _Concurrency.Task.sleep(for: .seconds(delay))
            }
        }
        throw lastError
    }

    // MARK: - URLError 分类（8.6 的补充：让失败原因可诊断）

    /// 只有超时单独成阶段；其余都归入网络阶段，具体原因由 `cause(for:)` 区分。
    static func stage(for code: URLError.Code) -> AIStage {
        code == .timedOut ? .timeout : .network
    }

    /// 把 `URLError` 归一为可诊断的 cause。
    /// 自建端点最常见的两类失败——明文 HTTP 被 ATS 拦下、自签名证书不受信——
    /// 必须与普通断网区分开，否则用户只会看到「网络不可用」而无从下手。
    static func cause(for code: URLError.Code) -> String {
        switch code {
        case .timedOut:
            "timeout"
        case .appTransportSecurityRequiresSecureConnection:
            AIFailureCause.atsPlainHTTP
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            AIFailureCause.tlsUntrusted
        case .cannotFindHost, .dnsLookupFailed:
            AIFailureCause.dnsFailure
        case .cannotConnectToHost:
            AIFailureCause.connectionRefused
        case .notConnectedToInternet:
            AIFailureCause.offline
        case .networkConnectionLost:
            AIFailureCause.connectionLost
        default:
            "urlerror_\(code.rawValue)"
        }
    }
}
