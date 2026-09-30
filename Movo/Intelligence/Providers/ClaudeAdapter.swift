//
//  ClaudeAdapter.swift
//  Intelligence/Providers
//
//  8.4 结构化输出：Messages API + `tool_use`（客户端不解析自由文本）。
//  只接受 `type == "tool_use" && name == AIProposalSchema.toolName` 的输入块。
//

import Foundation

public struct ClaudeAdapter: AIProvider {

    public let id: AIVendor = .claude
    public var displayName: String { "Claude" }
    public let currentModel: String

    private let keyStore: any AIKeyStore
    private let catalog: ModelCatalog
    private let transport: AITransport
    private let maxTokens: Int
    private let anthropicVersion: String

    public init(keyStore: any AIKeyStore,
                catalog: ModelCatalog = .fallback,
                defaults: AppDefaults = .fallback,
                model: String? = nil,
                maxTokens: Int = 4096,
                transport: AITransport? = nil) {
        self.keyStore = keyStore
        self.catalog = catalog
        self.transport = transport ?? AITransport(defaults: defaults)
        self.maxTokens = maxTokens
        self.anthropicVersion = "2023-06-01"
        self.currentModel = model ?? catalog.entry(for: .claude)?.models.first?.id ?? ""
    }

    private var entry: ModelCatalog.VendorEntry? { catalog.entry(for: .claude) }

    public func availableModels() -> [ModelInfo] {
        (entry?.models ?? []).map(ModelInfo.init(entry:))
    }

    // MARK: 8.1 测试连接

    public func testConnection() async throws {
        let key = try OpenAIAdapter.requireKey(keyStore: keyStore, vendor: .claude)
        let endpoint = entry?.testEndpoint ?? entry?.endpoint ?? "https://api.anthropic.com/v1/models"
        guard let url = URL(string: endpoint) else {
            throw MovoError.aiFailed(stage: .unknown, cause: "endpoint_invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await transport.send(request)
    }

    // MARK: 8.4 提议（tool_use）

    public func proposeOperations(_ input: AIInput) async throws -> AIProposal {
        let key = try OpenAIAdapter.requireKey(keyStore: keyStore, vendor: .claude)
        let endpoint = entry?.endpoint ?? "https://api.anthropic.com/v1/messages"
        guard let url = URL(string: endpoint) else {
            throw MovoError.aiFailed(stage: .unknown, cause: "endpoint_invalid")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.requestBody(model: currentModel, maxTokens: maxTokens, input: input)

        let response = try await transport.send(request)

        guard let root = try? JSONDecoder().decode(JSONValue.self, from: response.data),
              case .object(let object) = root,
              case .array(let blocks)? = object["content"] else {
            throw MovoError.aiFailed(stage: .parse, cause: "claude_envelope")
        }

        var toolInput: JSONValue?
        for block in blocks {
            guard case .object(let b) = block else { continue }
            if b["type"]?.stringValue == "tool_use",
               b["name"]?.stringValue == AIProposalSchema.toolName,
               let input = b["input"] {
                toolInput = input
                break
            }
        }
        // tool_use 缺失或结构不符：不解析自由文本（8.4）
        guard let toolInput, var proposal = AIProposalCoding.decode(toolInput) else {
            throw MovoError.aiFailed(stage: .parse, cause: "claude_tool_use")
        }

        proposal.provider = "claude"
        proposal.model = currentModel
        if case .object(let usage)? = object["usage"] {
            proposal.promptTokens = AIProposalCoding.intValue(usage["input_tokens"])
            proposal.completionTokens = AIProposalCoding.intValue(usage["output_tokens"])
        }
        proposal.latencyMs = response.latencyMs
        return proposal
    }

    // MARK: 私有

    static func requestBody(model: String, maxTokens: Int, input: AIInput) -> Data? {
        let tool: JSONValue = .object([
            "name": .string(AIProposalSchema.toolName),
            "description": .string("输出从用户原文整理出的结构化事项列表。只提议，不执行。"),
            "input_schema": .object(AIProposalSchema.jsonSchema)
        ])
        let payload: JSONValue = .object([
            "model": .string(model),
            "max_tokens": .int(maxTokens),
            "temperature": .int(0),
            "system": .string(AIContextBuilder.instructions),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(input.requestBodyJSONString())])
                    ])
                ])
            ]),
            "tools": .array([tool]),
            "tool_choice": .object(["type": .string("tool"),
                                    "name": .string(AIProposalSchema.toolName)])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(payload)
    }
}
