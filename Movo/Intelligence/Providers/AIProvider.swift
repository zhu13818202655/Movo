//
//  AIProvider.swift
//  Intelligence/Providers
//
//  8.3 / 8.4 厂商适配契约。传输层可注入，便于 fixture 测试（AT 用例不触网）。
//  统一业务协议：适配器只负责「请求构造 + 响应解析」，业务（校验/策略）在 Planning 层。
//

import Foundation

// MARK: - 厂商适配契约

public protocol AIProvider: Sendable {
    var id: AIVendor { get }
    var displayName: String { get }
    /// 当前选中的模型 id
    var currentModel: String { get }
    func availableModels() -> [ModelInfo]
    /// 8.1 设置页「测试连接」：校验 Key 与模型可用
    func testConnection() async throws
    /// 6.5 结构化输出：把最小上下文整理为提案
    func proposeOperations(_ input: AIInput) async throws -> AIProposal
}

// MARK: - 用量（8.8：只记录元数据，不含任何正文）

public struct AIUsageRecord: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: String
    public var model: String
    public var promptTokens: Int
    public var completionTokens: Int
    public var latencyMs: Int
    /// 用户可读状态（如「成功」/「鉴权失败」）
    public var status: String
    public var date: Date

    public var totalTokens: Int { promptTokens + completionTokens }

    public init(id: UUID = UUID(), provider: String, model: String,
                promptTokens: Int, completionTokens: Int, latencyMs: Int,
                status: String, date: Date) {
        self.id = id; self.provider = provider; self.model = model
        self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.latencyMs = latencyMs; self.status = status; self.date = date
    }

    /// 成功状态文案（SettingsSections 以「成功」判定为绿色）
    public static let successStatus = "成功"
}

// MARK: - 模型清单条目

public struct ModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let contextHint: String?

    public init(id: String, displayName: String, contextHint: String? = nil) {
        self.id = id; self.displayName = displayName; self.contextHint = contextHint
    }

    public init(entry: ModelCatalog.Entry) {
        self.id = entry.id
        self.displayName = entry.displayName
        self.contextHint = entry.contextHint
    }
}
