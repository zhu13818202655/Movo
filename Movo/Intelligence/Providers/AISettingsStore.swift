//
//  AISettingsStore.swift
//  Intelligence/Providers
//
//  8.5 AI 选择与自定义厂商配置：
//   - 内置厂商（DeepSeek）的端点与模型来自 `ModelCatalog`（随包资源）。
//   - 自定义厂商走 OpenAI 兼容协议，Base URL 与模型 ID 由用户填写并持久化到本机偏好。
//   - **Key 不经这里**：Key 只经 `AIKeyStore` 存入设备专属钥匙串（AC24）。
//
//  Base URL 与模型 ID 不是凭据，因此存放于本机 UserDefaults 即可；不进入 CloudKit、导出与日志。
//

import Foundation

// MARK: - 自定义厂商配置

/// 自定义厂商（OpenAI 兼容）的调用配置。只含非敏感字段。
public struct CustomProviderConfig: Sendable, Codable, Equatable, Hashable {

    /// 用户填写的 Base URL，例如 `https://your-server/v1`。
    public var baseURL: String
    /// 用户填写的模型 ID，例如 `my-org/my-model`。
    public var modelID: String

    public static let empty = CustomProviderConfig()

    public init(baseURL: String = "", modelID: String = "") {
        self.baseURL = baseURL
        self.modelID = modelID
    }

    /// 模型 ID（去掉首尾空白）
    public var trimmedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Base URL 是否可用（去掉尾部斜杠后是可解析的绝对 URL）
    public var hasUsableBaseURL: Bool { Self.normalizedBaseURL(baseURL) != nil }

    /// Base URL 与模型 ID 都填好了才算配置完成
    public var isComplete: Bool { hasUsableBaseURL && !trimmedModelID.isEmpty }

    /// OpenAI 兼容的 chat completions 端点。配置不完整时返回 nil。
    public func chatCompletionsURL() -> String? {
        guard let base = Self.normalizedBaseURL(baseURL) else { return nil }
        return base + "/chat/completions"
    }

    /// 归一化 Base URL：去空白、去尾部 `/`；若用户直接粘了完整端点则回退到其 Base。
    public static func normalizedBaseURL(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        let suffix = "/chat/completions"
        if value.hasSuffix(suffix) { value.removeLast(suffix.count) }
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty,
              let url = URL(string: value),
              url.scheme != nil,
              url.host()?.isEmpty == false else { return nil }
        return value
    }
}

// MARK: - 持久化的 AI 选择

/// 设置页选定的厂商、模型与自定义厂商配置。整体作为一个值持久化，便于版本演进。
public struct AISettings: Sendable, Codable, Equatable {

    public var vendor: AIVendor
    /// 内置厂商选中的模型 id；自定义厂商等于用户填写的模型 ID。
    public var model: String
    public var custom: CustomProviderConfig

    public static let `default` = AISettings()

    public init(vendor: AIVendor = .deepseek,
                model: String = "",
                custom: CustomProviderConfig = .empty) {
        self.vendor = vendor
        self.model = model
        self.custom = custom
    }
}

/// 选择持久化契约。实现只在主 actor（`AppEnvironment`）上使用，
/// 因此不要求 `Sendable`——`UserDefaults` 本身不是 Sendable 类型。
/// 测试与预览使用内存实现，避免污染真实偏好。
public protocol AISettingsStore {
    func load() -> AISettings
    func save(_ settings: AISettings)
}

/// 本机偏好实现。解码失败（例如旧版本遗留的厂商名）时回落到默认值。
public struct UserDefaultsAISettingsStore: AISettingsStore {

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "movo.ai.settings") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AISettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AISettings.self, from: data)
        else { return .default }
        return decoded
    }

    public func save(_ settings: AISettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 测试 / 预览实现（不触真实偏好）。引用类型，保证写入后能读回。
public final class InMemoryAISettingsStore: AISettingsStore {

    private let lock = NSLock()
    private var value: AISettings

    public init(_ value: AISettings = .default) { self.value = value }

    public func load() -> AISettings {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func save(_ settings: AISettings) {
        lock.lock(); defer { lock.unlock() }
        value = settings
    }
}
