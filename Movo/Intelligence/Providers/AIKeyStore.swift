//
//  AIKeyStore.swift
//  Intelligence/Providers
//
//  8.1 Key 隔离（AC24）：
//   - service = "Movo.AIKey.<vendor>"（per-vendor 独立条目）
//   - accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly（设备专属）
//   - 不启用 iCloud Keychain 同步（synchronizable = false）
//   - 只写入 Keychain；不写入 SwiftData / CloudKit / 日志 / 导出 / 剪贴板之外的任何存储
//  Mac 与 iPhone 分别配置（ThisDeviceOnly 天然满足）。
//
//  Key 永不进入请求体与错误日志；界面与日志只使用脱敏形式。
//

import Foundation
import Security

// MARK: - 脱敏与本地格式预检（8.2 / AC24）

/// Key 的展示与格式判定。**永不返回可用 Key 的正文**。
public enum AIKeyFormat {

    /// 已知内置厂商前缀。长前缀优先，避免被更短的前缀截断。
    static let vendorPrefixes = ["sk-"]

    /// 脱敏：保留已知厂商前缀与末 4 位，中间一律省略。
    /// `sk-proj-abcdefghijklmnop1234` → `sk-…1234`
    /// `local-token-abcdefghijklmnop` → `…mnop`
    public static func mask(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count > 4 else { return "…" }
        let prefix = vendorPrefixes.first { trimmed.hasPrefix($0) } ?? ""
        return "\(prefix)…\(String(trimmed.suffix(4)))"
    }

    /// 本地格式预检（不联网）：判断 Key 是否形如该厂商的 Key。
    /// 仅作参考提示，不阻止保存——自定义厂商的 Key 格式由用户自行决定。
    public static func looksValid(_ key: String, vendor: AIVendor) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        switch vendor {
        case .deepseek:
            return trimmed.hasPrefix("sk-")
        case .custom:
            // 自建服务的 Key 格式不可预知，只做长度预检。
            return true
        }
    }
}

// MARK: - 契约

/// Keychain 读写契约。Key 只经此存取，不出现在其他任何存储或日志中。
public protocol AIKeyStore: Sendable {
    func key(vendor: AIVendor) -> String?
    func save(_ key: String, vendor: AIVendor) throws
    func delete(vendor: AIVendor) throws
}

/// 内部错误：不进入用户可见文案（避免泄漏 Key 长度等元信息）。
enum AIKeyStoreError: Error {
    case emptyKey
    case unexpectedStatus(OSStatus)
}

// MARK: - Keychain 实现

/// 系统钥匙串实现。每台设备独立（`ThisDeviceOnly`），不随 iCloud 同步。
public struct KeychainAIKeyStore: AIKeyStore {

    private let account: String

    public init(account: String = "default") {
        self.account = account
    }

    private func baseQuery(vendor: AIVendor) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vendor.keychainService,
            kSecAttrAccount as String: account
        ]
    }

    public func key(vendor: AIVendor) -> String? {
        var query = baseQuery(vendor: vendor)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String, vendor: AIVendor) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw AIKeyStoreError.emptyKey
        }
        // 先删后写，保证 accessible / synchronizable 属性落对
        SecItemDelete(baseQuery(vendor: vendor) as CFDictionary)

        var attributes = baseQuery(vendor: vendor)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw AIKeyStoreError.unexpectedStatus(status) }
    }

    public func delete(vendor: AIVendor) throws {
        let status = SecItemDelete(baseQuery(vendor: vendor) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIKeyStoreError.unexpectedStatus(status)
        }
    }
}

// MARK: - 测试 / 预览实现（不触真实 Keychain）

public final class InMemoryAIKeyStore: AIKeyStore, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [AIVendor: String]

    public init(seed: [AIVendor: String] = [:]) {
        self.storage = seed
    }

    public func key(vendor: AIVendor) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[vendor]
    }

    public func save(_ key: String, vendor: AIVendor) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.data(using: .utf8) != nil else {
            throw AIKeyStoreError.emptyKey
        }
        lock.lock(); defer { lock.unlock() }
        storage[vendor] = trimmed
    }

    public func delete(vendor: AIVendor) throws {
        lock.lock(); defer { lock.unlock() }
        storage[vendor] = nil
    }
}
