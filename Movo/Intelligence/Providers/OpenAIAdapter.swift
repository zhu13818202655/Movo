//
//  OpenAIAdapter.swift
//  Intelligence/Providers
//
//  8.4 结构化输出：Chat Completions + `response_format = {"type":"json_object"}`。
//  客户端在系统提示里内嵌输出契约，并把 `choices[].message.content` 解析为 `AIProposal`。
//  同时提供 `AIProposalCoding`（OpenAI / Claude 共用的提案解码器）。
//

import Foundation

// MARK: - 提案解码（8.3 / 6.5 Schema）

public enum AIProposalCoding {

    /// 从模型返回的文本解码提案。容忍 ```json 围栏与前后多余说明。
    public static func decode(_ text: String) -> AIProposal? {
        guard let data = extractJSONData(from: text),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return decode(value)
    }

    /// 从已解析的 JSON 值解码提案（Claude tool_use 的 `input` 直接走这条路）。
    /// 任一 item 的 action 不在枚举内 → 整体解码失败（不得静默通过）。
    public static func decode(_ value: JSONValue) -> AIProposal? {
        guard case .object(let root) = value,
              case .array(let rawItems)? = root["items"] else { return nil }

        var items: [AIProposalItem] = []
        for rawItem in rawItems {
            guard case .object(let object) = rawItem,
                  let actionRaw = object["action"]?.stringValue,
                  let action = AIAction(rawValue: actionRaw) else { return nil }

            let span = (object["span"].flatMap { intArray($0) }) ?? []
            guard span.count == 2 else { return nil }

            items.append(AIProposalItem(
                sourceSpan: object["source_span"]?.stringValue,
                span: span,
                action: action,
                task: decodeTask(object["task"]),
                dateInterpretation: decodeDateInterpretation(object["date_interpretation"]),
                recurrence: decodeRecurrence(object["recurrence"]),
                measurement: decodeMeasurement(object["measurement"]),
                note: decodeNote(object["note"]),
                confidence: object["confidence"]?.doubleValue ?? 0,
                needsConfirmation: object["needs_confirmation"]?.boolValue ?? false,
                reason: object["reason"]?.stringValue,
                clarificationQuestion: object["clarification_question"]?.stringValue))
        }

        return AIProposal(schemaVersion: intValue(root["schema_version"]) ?? 1,
                          items: items,
                          provider: root["provider"]?.stringValue,
                          model: root["model"]?.stringValue,
                          promptTokens: intValue(root["prompt_tokens"]),
                          completionTokens: intValue(root["completion_tokens"]),
                          latencyMs: intValue(root["latency_ms"]))
    }

    /// `Int` 提取：兼容 `5` / `5.0` / `"7"`
    public static func intValue(_ value: JSONValue?) -> Int? {
        value?.intValue
    }

    // MARK: 私有

    static func extractJSONData(from text: String) -> Data? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let newline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: newline)...])
            }
            if let fence = cleaned.range(of: "```", options: .backwards) {
                cleaned = String(cleaned[cleaned.startIndex..<fence.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // 容忍前后说明文字：截取首个 `{` 到末个 `}`
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"),
           start <= end {
            cleaned = String(cleaned[start...end])
        }
        return cleaned.data(using: .utf8)
    }

    static func intArray(_ value: JSONValue) -> [Int]? {
        guard case .array(let values) = value else { return nil }
        var out: [Int] = []
        for item in values {
            guard let int = item.intValue else { return nil }
            out.append(int)
        }
        return out
    }

    static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { $0.stringValue }
    }

    static func decodeTask(_ value: JSONValue?) -> AIProposalTask? {
        guard case .object(let o)? = value else { return nil }
        return AIProposalTask(
            candidateTaskId: o["candidate_task_id"]?.stringValue,
            title: o["title"]?.stringValue,
            notes: o["notes"]?.stringValue,
            planId: o["plan_id"]?.stringValue,
            stageId: o["stage_id"]?.stringValue,
            parentTaskId: o["parent_task_id"]?.stringValue,
            scheduledDate: o["scheduled_date"]?.stringValue,
            hardDeadline: o["hard_deadline"]?.stringValue,
            estimateMinutes: intValue(o["estimate_minutes"]),
            priority: o["priority"]?.stringValue,
            tags: stringArray(o["tags"]),
            dependencyIds: stringArray(o["dependency_ids"]))
    }

    static func decodeDateInterpretation(_ value: JSONValue?) -> AIDateInterpretation? {
        guard case .object(let o)? = value else { return nil }
        return AIDateInterpretation(
            rawText: o["raw_text"]?.stringValue,
            resolvedDate: o["resolved_date"]?.stringValue,
            granularity: o["granularity"]?.stringValue,
            isHardDeadline: o["is_hard_deadline"]?.boolValue ?? false)
    }

    static func decodeRecurrence(_ value: JSONValue?) -> AIRecurrence? {
        guard case .object(let o)? = value else { return nil }
        let weekdays = (o["weekdays"].flatMap { intArray($0) }) ?? []
        return AIRecurrence(pattern: o["pattern"]?.stringValue,
                            count: intValue(o["count"]),
                            weekdays: weekdays,
                            effectiveFrom: o["effective_from"]?.stringValue)
    }

    static func decodeMeasurement(_ value: JSONValue?) -> AIMeasurement? {
        guard case .object(let o)? = value else { return nil }
        return AIMeasurement(metricId: o["metric_id"]?.stringValue,
                             value: o["value"]?.doubleValue,
                             unit: o["unit"]?.stringValue,
                             measuredAt: o["measured_at"]?.stringValue,
                             note: o["note"]?.stringValue)
    }

    static func decodeNote(_ value: JSONValue?) -> AINote? {
        guard case .object(let o)? = value else { return nil }
        return AINote(kind: o["kind"]?.stringValue, text: o["text"]?.stringValue)
    }
}

// MARK: - OpenAI 适配器

public struct OpenAIAdapter: AIProvider {

    public let id: AIVendor = .openai
    public var displayName: String { "OpenAI" }
    public let currentModel: String

    private let keyStore: any AIKeyStore
    private let catalog: ModelCatalog
    private let transport: AITransport

    public init(keyStore: any AIKeyStore,
                catalog: ModelCatalog = .fallback,
                defaults: AppDefaults = .fallback,
                model: String? = nil,
                transport: AITransport? = nil) {
        self.keyStore = keyStore
        self.catalog = catalog
        self.transport = transport ?? AITransport(defaults: defaults)
        self.currentModel = model ?? catalog.entry(for: .openai)?.models.first?.id ?? ""
    }

    private var entry: ModelCatalog.VendorEntry? { catalog.entry(for: .openai) }

    public func availableModels() -> [ModelInfo] {
        (entry?.models ?? []).map(ModelInfo.init(entry:))
    }

    // MARK: 8.1 测试连接

    public func testConnection() async throws {
        let key = try Self.requireKey(keyStore: keyStore, vendor: .openai)
        let endpoint = entry?.testEndpoint ?? entry?.endpoint ?? "https://api.openai.com/v1/models"
        guard let url = URL(string: endpoint) else {
            throw MovoError.aiFailed(stage: .unknown, cause: "endpoint_invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await transport.send(request)
    }

    // MARK: 8.3 提议

    public func proposeOperations(_ input: AIInput) async throws -> AIProposal {
        let key = try Self.requireKey(keyStore: keyStore, vendor: .openai)
        let endpoint = entry?.endpoint ?? "https://api.openai.com/v1/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw MovoError.aiFailed(stage: .unknown, cause: "endpoint_invalid")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.requestBody(model: currentModel, input: input)

        let response = try await transport.send(request)

        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            struct Usage: Decodable {
                let promptTokens: Int?
                let completionTokens: Int?
                enum CodingKeys: String, CodingKey {
                    case promptTokens = "prompt_tokens"
                    case completionTokens = "completion_tokens"
                }
            }
            let choices: [Choice]
            let usage: Usage?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw MovoError.aiFailed(stage: .parse, cause: "openai_envelope")
        }
        guard let content = envelope.choices.first?.message.content else {
            throw MovoError.aiFailed(stage: .parse, cause: "openai_envelope")
        }
        guard var proposal = AIProposalCoding.decode(content) else {
            throw MovoError.aiFailed(stage: .parse, cause: "openai_items")
        }

        proposal.provider = "openai"
        proposal.model = currentModel
        proposal.promptTokens = envelope.usage?.promptTokens
        proposal.completionTokens = envelope.usage?.completionTokens
        proposal.latencyMs = response.latencyMs
        return proposal
    }

    // MARK: 私有

    static func requireKey(keyStore: any AIKeyStore, vendor: AIVendor) throws -> String {
        guard let key = keyStore.key(vendor: vendor), !key.isEmpty else {
            throw MovoError.noKey(vendor: vendor)
        }
        return key
    }

    static func requestBody(model: String, input: AIInput) -> Data? {
        let payload: JSONValue = .object([
            "model": .string(model),
            "temperature": .int(0),
            "response_format": .object(["type": .string("json_object")]),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(AIContextBuilder.instructions)]),
                .object(["role": .string("user"), "content": .string(input.requestBodyJSONString())])
            ])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(payload)
    }
}
