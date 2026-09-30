//
//  AIProviderResolver.swift
//  Intelligence/Providers
//
//  8.5 把「厂商 + 选择 + 自定义配置」解析为可直接调用的端点与模型。
//  内置厂商读 `ModelCatalog`；自定义厂商读用户配置。解析失败抛 MovoError，
//  由调用方决定降级（无 Key / 未填完 → 本地整理）。
//

import Foundation

/// 解析结果：一次调用所需的全部非敏感信息。Key 不在此处，只经 `AIKeyStore` 读取。
public struct ResolvedAIProvider: Sendable, Equatable {

    public var vendor: AIVendor
    public var displayName: String
    public var model: String
    public var models: [ModelInfo]
    public var chatCompletionsURL: String

    public init(vendor: AIVendor,
                displayName: String,
                model: String,
                models: [ModelInfo],
                chatCompletionsURL: String) {
        self.vendor = vendor
        self.displayName = displayName
        self.model = model
        self.models = models
        self.chatCompletionsURL = chatCompletionsURL
    }
}

public enum AIProviderResolver {

    /// 该厂商在「未指定模型」时使用的默认模型 id。
    public static func defaultModel(vendor: AIVendor,
                                    catalog: ModelCatalog,
                                    custom: CustomProviderConfig) -> String {
        switch vendor {
        case .deepseek:
            return catalog.entry(for: .deepseek)?.models.first?.id ?? ""
        case .custom:
            return custom.trimmedModelID
        }
    }

    /// 解析调用配置。`model` 为 nil 时使用该厂商的默认模型。
    public static func resolve(vendor: AIVendor,
                               catalog: ModelCatalog,
                               custom: CustomProviderConfig = .empty,
                               model: String? = nil) throws -> ResolvedAIProvider {
        switch vendor {
        case .deepseek:
            guard let entry = catalog.entry(for: .deepseek), !entry.models.isEmpty else {
                throw MovoError.aiFailed(stage: .unknown, cause: "catalog_missing")
            }
            let models = entry.models.map(ModelInfo.init(entry:))
            let requested = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let chosen = models.contains { $0.id == requested } ? requested : (models.first?.id ?? "")
            return ResolvedAIProvider(vendor: .deepseek,
                                      displayName: entry.displayName,
                                      model: chosen,
                                      models: models,
                                      chatCompletionsURL: entry.endpoint)

        case .custom:
            guard let url = custom.chatCompletionsURL(), !custom.trimmedModelID.isEmpty else {
                throw MovoError.providerNotConfigured(vendor: .custom)
            }
            let id = custom.trimmedModelID
            return ResolvedAIProvider(vendor: .custom,
                                      displayName: AIVendor.custom.displayName,
                                      model: id,
                                      models: [ModelInfo(id: id, displayName: id)],
                                      chatCompletionsURL: url)
        }
    }
}
