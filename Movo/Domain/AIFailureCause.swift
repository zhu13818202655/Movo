//
//  AIFailureCause.swift
//  Domain
//
//  4.5 错误模型的补充：把 `MovoError.aiFailed` 的 cause 归一为可解释的失败分类。
//
//  为什么需要这层：自定义厂商（OpenAI 兼容）由用户自己填 Base URL，失败原因千差万别，
//  但传输层只能看到 `URLError`。若不区分，用户只会看到「网络不可用」，
//  无法判断是地址写错、明文 HTTP 被系统拦下、证书不受信，还是模型 ID 不对。
//
//  约定：
//   - cause 串是**机器标识**（英文 snake_case），会进 `RedactedLogger` 元数据，
//     因此不随文案改动；用户可见的解释集中维护在这里。
//   - 只做「标识 → 用户可执行解释」，不包含任何正文、请求或响应内容（AC24）。
//

import Foundation

/// AI 调用失败的已知分类。cause 由传输层产出（见 `AITransport`）。
public enum AIFailureCause {

    /// 明文 HTTP 被 App Transport Security 拦下（自建端点最常见的原因）
    public static let atsPlainHTTP = "ats_plain_http"
    /// TLS 握手或证书校验失败（自签名证书）
    public static let tlsUntrusted = "tls_trust"
    /// 域名或主机名解析失败
    public static let dnsFailure = "dns"
    /// 连不上主机：端口未开放、服务未启动或被防火墙挡住
    public static let connectionRefused = "connect_refused"
    /// 本机当前没有网络
    public static let offline = "offline"
    /// 连接中途断开
    public static let connectionLost = "connection_lost"

    /// 把 cause 翻译成用户可执行的解释。未知 cause 返回 nil，由调用方给出通用文案。
    public static func explanation(for cause: String) -> String? {
        switch cause {
        case atsPlainHTTP:
            "这个地址是明文 HTTP，被系统的安全策略拦住了。换成 https:// 开头，或改用本机、局域网地址。"
        case tlsUntrusted:
            "HTTPS 证书没有被这台设备信任（自签名证书常见）。换一张受信任的证书，或改用本机的 http:// 地址。"
        case dnsFailure:
            "解析不到这个主机名，检查 Base URL 是否写对了。"
        case connectionRefused:
            "连不上这个地址，检查端口、服务是否已启动，以及防火墙设置。"
        case offline:
            "这台设备当前没有网络连接。"
        case connectionLost:
            "连接中途断开，稍后重试就行。"
        default:
            httpStatusExplanation(for: cause)
        }
    }

    /// 这些原因与网络抖动无关：地址、协议或证书本身不对，重试只会重复失败。
    public static func isDeterministic(_ cause: String) -> Bool {
        cause == atsPlainHTTP || cause == tlsUntrusted || cause == dnsFailure
    }

    /// `http_<状态码>` 与其余解析类 cause 的解释。
    private static func httpStatusExplanation(for cause: String) -> String? {
        switch cause {
        case "http_400", "http_422":
            "服务端认为请求不合法：多半是模型 ID 不对，或这个服务没有实现 OpenAI 兼容的 chat/completions。"
        case "http_404":
            "服务端找不到这个端点。请求会发往「Base URL + /chat/completions」，检查 Base URL 是否少了 /v1 这类路径段。"
        case "http_405":
            "这个端点不接受 POST，确认 Base URL 指向的是对话补全接口。"
        case "http_413":
            "这次要发送的内容对服务端来说太长了。"
        case "chat_envelope", "chat_items":
            "服务端返回的内容不是预期的 JSON 结构。确认这个模型支持 response_format=json_object。"
        case "endpoint_invalid":
            "Base URL 无法组成合法的请求地址。"
        case "catalog_missing":
            "随包的模型目录里没有这个厂商的配置。"
        default:
            nil
        }
    }
}
