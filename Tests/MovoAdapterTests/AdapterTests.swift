//
//  AdapterTests.swift
//  MovoAdapterTests
//
//  12.1 Adapter AT：以"录制回放"夹具覆盖 8.3/8.4 适配器路径。
//  覆盖：成功、部分成功、401、429、5xx、超时、无法解析（malformed schema）、
//  未知字段容错、JSONValue 解码路径、无 Key、内置/自定义厂商解析。
//

import Foundation
import XCTest
import MovoKit

// MARK: - URLProtocol 录制/回放桩

final class MockURLProtocol: URLProtocol {
    /// 回放响应：返回 (statusCode, body)，或抛出（模拟超时/断网）。
    nonisolated(unsafe) static var responder: (@Sendable () throws -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0
    /// 最近一次收到的请求（用于断言端点与鉴权头）
    nonisolated(unsafe) static var lastRequest: URLRequest?
    /// 最近一次收到的请求体。URLSession 会把 `httpBody` 转成流交给 URLProtocol，
    /// 所以必须在 `startLoading()` 里读，之后 `request.httpBody` 已是 nil。
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requestCount += 1
        MockURLProtocol.lastRequest = request
        MockURLProtocol.lastRequestBody = request.httpBody ?? Self.read(request.httpBodyStream)
        guard let responder = MockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try responder()
            let url = request.url ?? URL(string: "https://example.com")!
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

final class AdapterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.responder = nil
        MockURLProtocol.requestCount = 0
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastRequestBody = nil
    }

    // MARK: - 夹具

    /// OpenAI 成功：单条 create_task（含日期解释、硬截止、标签）
    static let singleCreateTaskJSON = """
    {
      "schema_version": 1,
      "items": [
        {
          "source_span": "明天下午三点前交周报",
          "span": [0, 10],
          "action": "create_task",
          "task": {
            "title": "交周报",
            "notes": null,
            "plan_id": null,
            "stage_id": null,
            "parent_task_id": null,
            "scheduled_date": "2026-09-30",
            "hard_deadline": "2026-09-30T07:00:00Z",
            "estimate_minutes": 90,
            "priority": "high",
            "tags": ["工作"],
            "dependency_ids": []
          },
          "date_interpretation": {
            "raw_text": "明天下午三点前",
            "resolved_date": "2026-09-30",
            "granularity": "precise",
            "is_hard_deadline": true
          },
          "confidence": 0.95,
          "needs_confirmation": false
        }
      ]
    }
    """

    /// 部分成功：结果记录 + 想法 + 需要确认，三条混排
    static let multiItemJSON = """
    {
      "schema_version": 1,
      "items": [
        {
          "source_span": "体重 70 公斤",
          "span": [0, 4],
          "action": "record_measurement",
          "measurement": {
            "metric_id": "11111111-1111-1111-1111-111111111111",
            "value": 70,
            "unit": "kg",
            "measured_at": "2026-09-28",
            "note": null
          },
          "confidence": 0.9,
          "needs_confirmation": false
        },
        {
          "source_span": "以后也许想学摄影",
          "span": [5, 15],
          "action": "save_note",
          "note": { "kind": "idea", "text": "以后也许想学摄影" },
          "confidence": 0.8,
          "needs_confirmation": false
        },
        {
          "source_span": "那个事情",
          "span": [16, 22],
          "action": "needs_clarification",
          "confidence": 0.3,
          "needs_confirmation": true,
          "clarification_question": "指的是哪件事？"
        }
      ]
    }
    """

    static let input = AIInput(locale: "zh-Hans", timezone: "Asia/Shanghai", today: "2026-09-28",
                               text: "明天下午三点前交周报", plans: [], tasks: [],
                               instructions: "test")

    // MARK: - 工具

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTransport(retryCount: Int = 0) -> AITransport {
        AITransport(session: makeSession(), retryCount: retryCount,
                    backoffSeconds: Array(repeating: 0, count: max(1, retryCount)))
    }

    /// 以内置 DeepSeek（OpenAI 兼容）构造适配器
    private func makeDeepSeekAdapter(keyStore: any AIKeyStore = InMemoryAIKeyStore(),
                                     transport: AITransport? = nil) throws -> OpenAICompatibleAdapter {
        let resolved = try AIProviderResolver.resolve(vendor: .deepseek, catalog: .fallback)
        return OpenAICompatibleAdapter(resolved: resolved, keyStore: keyStore, transport: transport)
    }

    /// 以自定义厂商（OpenAI 兼容）构造适配器
    private func makeCustomAdapter(keyStore: any AIKeyStore,
                                   baseURL: String,
                                   model: String) throws -> OpenAICompatibleAdapter {
        let resolved = try AIProviderResolver.resolve(
            vendor: .custom, catalog: .fallback,
            custom: CustomProviderConfig(baseURL: baseURL, modelID: model))
        return OpenAICompatibleAdapter(resolved: resolved, keyStore: keyStore, transport: makeTransport())
    }

    private static func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/probe")!)
        request.httpMethod = "POST"
        return request
    }

    private func chatEnvelope(content: String, promptTokens: Int = 120,
                              completionTokens: Int = 48) throws -> Data {
        let envelope: [String: JSONValue] = [
            "choices": .array([.object(["message": .object(["content": .string(content)])])]),
            "usage": .object(["prompt_tokens": .int(promptTokens),
                              "completion_tokens": .int(completionTokens)])
        ]
        return try JSONEncoder().encode(envelope)
    }

    // MARK: - 解码夹具（8.3 / 6.5 Schema）

    func testDecodeSingleCreateTask() throws {
        let proposal = try XCTUnwrap(AIProposalCoding.decode(Self.singleCreateTaskJSON))
        XCTAssertEqual(proposal.schemaVersion, 1)
        XCTAssertEqual(proposal.items.count, 1)

        let item = try XCTUnwrap(proposal.items.first)
        XCTAssertEqual(item.action, .createTask)
        XCTAssertEqual(item.span, [0, 10])
        XCTAssertEqual(item.task?.title, "交周报")
        XCTAssertEqual(item.task?.scheduledDate, "2026-09-30")
        XCTAssertEqual(item.task?.hardDeadline, "2026-09-30T07:00:00Z")
        XCTAssertEqual(item.task?.estimateMinutes, 90)
        XCTAssertEqual(item.task?.priority, "high")
        XCTAssertEqual(item.task?.tags, ["工作"])
        XCTAssertEqual(item.dateInterpretation?.isHardDeadline, true)
        XCTAssertEqual(item.needsConfirmation, false)
        XCTAssertTrue(item.extraBlocks.isEmpty, "action 与数据块必须匹配（V2）")
        XCTAssertFalse(item.id.isEmpty)
    }

    func testDecodeStripsMarkdownFence() throws {
        let fenced = "```json\n" + Self.singleCreateTaskJSON + "\n```"
        let proposal = try XCTUnwrap(AIProposalCoding.decode(fenced))
        XCTAssertEqual(proposal.items.first?.task?.title, "交周报")
    }

    func testDecodePartialMultipleItems() throws {
        let proposal = try XCTUnwrap(AIProposalCoding.decode(Self.multiItemJSON))
        XCTAssertEqual(proposal.items.count, 3)
        XCTAssertEqual(proposal.items.map(\.action),
                       [.recordMeasurement, .saveNote, .needsClarification])
        XCTAssertEqual(proposal.items[0].measurement?.value, 70)
        XCTAssertEqual(proposal.items[0].measurement?.unit, "kg")
        XCTAssertEqual(proposal.items[1].note?.kind, "idea")
        XCTAssertEqual(proposal.items[2].clarificationQuestion, "指的是哪件事？")
    }

    func testDecodeMalformedReturnsNil() {
        XCTAssertNil(AIProposalCoding.decode("not json at all"))
        XCTAssertNil(AIProposalCoding.decode("{}"), "缺少 items 视为不可解析")
        XCTAssertNil(AIProposalCoding.decode(
            #"{"schema_version":1,"items":[{"action":"explode","span":[0,1],"confidence":1,"needs_confirmation":false}]}"#),
            "未知 action 必须解码失败（不得静默通过）")
    }

    func testDecodeToleratesUnknownFields() throws {
        let json = #"""
        {"schema_version":1,"extra_top_level":true,
         "items":[{"action":"needs_clarification","span":[0,1],"source_span":"x",
                   "confidence":0.2,"needs_confirmation":true,"future_field":{"a":1}}]}
        """#
        let proposal = try XCTUnwrap(AIProposalCoding.decode(json))
        XCTAssertEqual(proposal.items.first?.action, .needsClarification)
    }

    func testDecodeFromJSONValue() throws {
        let value: JSONValue = .object([
            "schema_version": .int(1),
            "items": .array([
                .object([
                    "action": .string("save_note"),
                    "span": .array([.int(0), .int(4)]),
                    "source_span": .string("记个想法"),
                    "note": .object(["kind": .string("idea"), "text": .string("记个想法")]),
                    "confidence": .double(0.7),
                    "needs_confirmation": .bool(false)
                ])
            ])
        ])
        let proposal = try XCTUnwrap(AIProposalCoding.decode(value))
        XCTAssertEqual(proposal.items.first?.action, .saveNote)
        XCTAssertEqual(proposal.items.first?.note?.text, "记个想法")
    }

    func testIntValueHelper() {
        XCTAssertEqual(AIProposalCoding.intValue(.int(5)), 5)
        XCTAssertEqual(AIProposalCoding.intValue(.double(5.0)), 5)
        XCTAssertEqual(AIProposalCoding.intValue(.string("7")), 7)
        XCTAssertNil(AIProposalCoding.intValue(.null))
        XCTAssertNil(AIProposalCoding.intValue(nil))
    }

    // MARK: - 8.6 传输层：状态码与重试策略

    func testTransportSucceedsOn200() async throws {
        let payload = Data("{\"ok\":true}".utf8)
        MockURLProtocol.responder = { (200, payload) }
        let transport = makeTransport()

        let response = try await transport.send(Self.request())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.data, payload)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testTransportMaps401ToAuthWithoutRetry() async {
        MockURLProtocol.responder = { (401, Data()) }
        let transport = makeTransport(retryCount: 3)

        do {
            _ = try await transport.send(Self.request())
            XCTFail("应抛出鉴权错误")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .auth, cause: "http_401"))
            XCTAssertFalse(error.isRetryable, "鉴权失败不自动重试")
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "401 不重试")
    }

    func testTransportRetries429ThenFails() async {
        MockURLProtocol.responder = { (429, Data()) }
        let transport = makeTransport(retryCount: 2)

        do {
            _ = try await transport.send(Self.request())
            XCTFail("应抛出限流错误")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .rateLimited, cause: "http_429"))
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 3, "429 按退避重试后仍失败")
    }

    func testTransportMaps5xxToRetryable() async {
        MockURLProtocol.responder = { (503, Data()) }
        let transport = makeTransport(retryCount: 1)

        do {
            _ = try await transport.send(Self.request())
            XCTFail("应抛出限流/服务端错误")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .rateLimited, cause: "http_503"))
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testTransportMapsTimeoutWithoutRetry() async {
        MockURLProtocol.responder = { throw URLError(.timedOut) }
        let transport = makeTransport()

        do {
            _ = try await transport.send(Self.request())
            XCTFail("应抛出超时错误")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .timeout, cause: "timeout"))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: - 8.6 失败分类：自建端点必须能诊断出原因
    //
    // 背景：自定义厂商指向用户自建的 OpenAI 兼容服务时，明文 HTTP 被系统安全策略
    // 拦下、证书不受信、主机名解析失败都会表现为「连不上」。若统一退化成
    // 「网络不可用」，用户无从判断该改地址、换协议还是换证书。

    /// 明文 HTTP 被 ATS 拦下：要能单独识别，且不做无意义的重试
    func testTransportMapsATSBlockToDiagnosableCause() async {
        MockURLProtocol.responder = { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        let transport = makeTransport(retryCount: 3)

        do {
            _ = try await transport.send(Self.request())
            XCTFail("应抛出错误")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .network, cause: AIFailureCause.atsPlainHTTP))
            XCTAssertFalse(error.isRetryable, "地址与协议不对是确定性失败，重试只是白等")
            XCTAssertEqual(error.diagnosticDetail?.contains("明文 HTTP"), true)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "确定性失败不自动重试")
    }

    func testTransportMapsTLSCertificateFailureToDiagnosableCause() async {
        MockURLProtocol.responder = { throw URLError(.serverCertificateUntrusted) }
        let transport = makeTransport(retryCount: 2)

        do {
            _ = try await transport.send(Self.request())
            XCTFail("应抛出错误")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .network, cause: AIFailureCause.tlsUntrusted))
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(error.diagnosticDetail?.contains("证书"), true)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testTransportMapsDNSFailureToDiagnosableCause() async {
        MockURLProtocol.responder = { throw URLError(.cannotFindHost) }
        let transport = makeTransport(retryCount: 2)

        do {
            _ = try await transport.send(Self.request())
            XCTFail("应抛出错误")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .network, cause: AIFailureCause.dnsFailure))
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    /// 连接被拒仍按网络抖动处理（服务可能正在重启），保留自动重试
    func testTransportKeepsConnectionRefusedRetryable() async {
        MockURLProtocol.responder = { throw URLError(.cannotConnectToHost) }
        let transport = makeTransport(retryCount: 1)

        do {
            _ = try await transport.send(Self.request())
            XCTFail("应抛出错误")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .network, cause: AIFailureCause.connectionRefused))
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    /// 其余 4xx 单独成阶段：否则会渲染成「未知错误」，看不出是 Base URL 写错
    func testTransportMaps404ToInvalidRequestWithoutRetry() async {
        MockURLProtocol.responder = { (404, Data()) }
        let transport = makeTransport(retryCount: 3)

        do {
            _ = try await transport.send(Self.request())
            XCTFail("应抛出错误")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .invalidRequest, cause: "http_404"))
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(error.diagnosticDetail?.contains("Base URL"), true)
            XCTAssertEqual(error.recoveryActions, [.openSettings(section: .ai), .editText],
                           "端点不对要引导改设置，重试没有意义")
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    /// 端到端：自定义厂商指向局域网明文地址时，「测试连接」要给出可执行的失败原因
    func testCustomAdapterTestConnectionSurfacesDiagnosableFailure() async throws {
        MockURLProtocol.responder = { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        let adapter = try makeCustomAdapter(
            keyStore: InMemoryAIKeyStore(seed: [.custom: "local-token-12345678"]),
            baseURL: "http://192.168.1.9:8000/v1",
            model: "qwen3-32b")

        do {
            try await adapter.testConnection()
            XCTFail("应抛出错误")
        } catch let error as MovoError {
            XCTAssertEqual(error.diagnosticDetail?.contains("明文 HTTP"), true)
        }

        // 探测请求是最小 POST；不带 response_format，自建服务未实现时可读的失败才会出现
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.9:8000/v1/chat/completions")
        let body = String(decoding: try XCTUnwrap(MockURLProtocol.lastRequestBody), as: UTF8.self)
        XCTAssertFalse(body.contains("response_format"))
        XCTAssertTrue(body.contains("max_tokens"))
    }

    // MARK: - 8.3 端到端：适配器把聊天信封解码为 AIProposal

    func testDeepSeekAdapterDecodesChatEnvelope() async throws {
        let envelope = try chatEnvelope(content: Self.singleCreateTaskJSON)
        MockURLProtocol.responder = { (200, envelope) }

        let adapter = try makeDeepSeekAdapter(
            keyStore: InMemoryAIKeyStore(seed: [.deepseek: "sk-test-0000000000000000"]),
            transport: makeTransport())

        let proposal = try await adapter.proposeOperations(Self.input)
        XCTAssertEqual(proposal.schemaVersion, 1)
        XCTAssertEqual(proposal.items.count, 1)
        XCTAssertEqual(proposal.items.first?.action, .createTask)
        XCTAssertEqual(proposal.items.first?.task?.title, "交周报")
        XCTAssertEqual(proposal.provider, "deepseek")
        XCTAssertEqual(proposal.promptTokens, 120)
        XCTAssertEqual(proposal.completionTokens, 48)

        // 端点来自内置目录，鉴权头为 Bearer
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString,
                       ModelCatalog.fallback.entry(for: .deepseek)?.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-0000000000000000")
    }

    func testCustomAdapterUsesUserEndpointAndModel() async throws {
        let envelope = try chatEnvelope(content: Self.singleCreateTaskJSON)
        MockURLProtocol.responder = { (200, envelope) }

        let adapter = try makeCustomAdapter(
            keyStore: InMemoryAIKeyStore(seed: [.custom: "local-token-12345678"]),
            baseURL: "https://llm.internal.example/v1/",
            model: "qwen3-32b")

        XCTAssertEqual(adapter.id, .custom)
        XCTAssertEqual(adapter.currentModel, "qwen3-32b")

        let proposal = try await adapter.proposeOperations(Self.input)
        XCTAssertEqual(proposal.provider, "custom")
        XCTAssertEqual(proposal.model, "qwen3-32b")

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://llm.internal.example/v1/chat/completions",
                       "尾斜杠应被归一化，路径拼接不多不少")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-token-12345678")
    }

    func testAdapterFailsOnUnparsableEnvelope() async throws {
        MockURLProtocol.responder = { (200, Data("not-a-chat-envelope".utf8)) }
        let adapter = try makeDeepSeekAdapter(
            keyStore: InMemoryAIKeyStore(seed: [.deepseek: "sk-test-0000000000000000"]),
            transport: makeTransport())

        do {
            _ = try await adapter.proposeOperations(Self.input)
            XCTFail("无法解析的信封必须抛错")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .parse, cause: "chat_envelope"))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: - 8.1 无 Key / 模型目录 / 厂商解析

    func testAdapterWithoutKeyThrowsNoKey() async throws {
        let adapter = try makeDeepSeekAdapter()
        do {
            _ = try await adapter.proposeOperations(Self.input)
            XCTFail("缺少 Key 应抛错")
        } catch let error as MovoError {
            XCTAssertEqual(error, .noKey(vendor: .deepseek))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testAdapterExposesCatalogModels() throws {
        let adapter = try makeDeepSeekAdapter()
        XCTAssertEqual(adapter.id, .deepseek)
        XCTAssertFalse(adapter.availableModels().isEmpty)
        XCTAssertFalse(adapter.currentModel.isEmpty)
    }

    func testCatalogOnlyContainsBuiltinVendors() {
        XCTAssertNotNil(ModelCatalog.fallback.entry(for: .deepseek))
        XCTAssertNil(ModelCatalog.fallback.entry(for: .custom), "自定义厂商不进目录")
        XCTAssertFalse(ModelCatalog.fallback.entry(for: .deepseek)?.models.isEmpty ?? true)
    }

    func testResolverFallsBackToDefaultModelForUnknownSelection() throws {
        let resolved = try AIProviderResolver.resolve(vendor: .deepseek, catalog: .fallback,
                                                      model: "not-in-catalog")
        XCTAssertEqual(resolved.model, "deepseek-v4-pro")
    }

    func testResolverRejectsIncompleteCustomProvider() {
        XCTAssertThrowsError(try AIProviderResolver.resolve(vendor: .custom, catalog: .fallback,
                                                           custom: .empty, model: nil)) { error in
            XCTAssertEqual(error as? MovoError, .providerNotConfigured(vendor: .custom))
        }
    }

    func testResolverBuildsCustomProvider() throws {
        let resolved = try AIProviderResolver.resolve(
            vendor: .custom, catalog: .fallback,
            custom: CustomProviderConfig(baseURL: "https://llm.internal/v1", modelID: "qwen3-32b"))
        XCTAssertEqual(resolved.vendor, .custom)
        XCTAssertEqual(resolved.displayName, "自定义")
        XCTAssertEqual(resolved.model, "qwen3-32b")
        XCTAssertEqual(resolved.chatCompletionsURL, "https://llm.internal/v1/chat/completions")
        XCTAssertEqual(resolved.models.map(\.id), ["qwen3-32b"])
    }

    // MARK: - 自定义厂商 Base URL 归一化

    func testCustomProviderNormalizesBaseURL() {
        // 尾斜杠
        XCTAssertEqual(CustomProviderConfig(baseURL: "https://a.example/v1/", modelID: "m")
            .chatCompletionsURL(), "https://a.example/v1/chat/completions")
        // 首尾空白
        XCTAssertEqual(CustomProviderConfig(baseURL: "  https://a.example/v1  ", modelID: "m")
            .chatCompletionsURL(), "https://a.example/v1/chat/completions")
        // 用户直接粘了完整端点：不重复拼接
        XCTAssertEqual(CustomProviderConfig(baseURL: "https://a.example/v1/chat/completions", modelID: "m")
            .chatCompletionsURL(), "https://a.example/v1/chat/completions")
        // 缺 scheme
        XCTAssertNil(CustomProviderConfig(baseURL: "api.example/v1", modelID: "m").chatCompletionsURL())
        XCTAssertFalse(CustomProviderConfig(baseURL: "api.example/v1", modelID: "m").isComplete)
    }

    func testCustomProviderRequiresBothFields() {
        XCTAssertFalse(CustomProviderConfig(baseURL: "https://a.example/v1", modelID: " ")
            .isComplete, "模型 ID 为空白视为未填")
        XCTAssertFalse(CustomProviderConfig(baseURL: "", modelID: "m").isComplete)
        XCTAssertTrue(CustomProviderConfig(baseURL: "https://a.example/v1", modelID: "m").isComplete)
    }
}
