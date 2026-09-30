//
//  AdapterTests.swift
//  MovoAdapterTests
//
//  12.1 Adapter AT：以"录制回放"夹具覆盖 8.3/8.4 适配器路径。
//  覆盖：成功、部分成功、401、429、5xx、超时、无法解析（malformed schema）、
//  未知字段容错、Claude tool_use 输入块、无 Key。
//

import Foundation
import XCTest
import MovoKit

// MARK: - URLProtocol 录制/回放桩

final class MockURLProtocol: URLProtocol {
    /// 回放响应：返回 (statusCode, body)，或抛出（模拟超时/断网）。
    nonisolated(unsafe) static var responder: (@Sendable () throws -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requestCount += 1
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
}

final class AdapterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.responder = nil
        MockURLProtocol.requestCount = 0
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

    func testDecodeFromClaudeToolInputJSONValue() throws {
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

    // MARK: - 8.3 端到端：适配器把聊天信封解码为 AIProposal

    func testOpenAIAdapterDecodesChatEnvelope() async throws {
        let envelope = try chatEnvelope(content: Self.singleCreateTaskJSON)
        MockURLProtocol.responder = { (200, envelope) }

        let adapter = OpenAIAdapter(
            keyStore: InMemoryAIKeyStore(seed: [.openai: "sk-test-0000000000000000"]),
            transport: makeTransport())

        let proposal = try await adapter.proposeOperations(Self.input)
        XCTAssertEqual(proposal.schemaVersion, 1)
        XCTAssertEqual(proposal.items.count, 1)
        XCTAssertEqual(proposal.items.first?.action, .createTask)
        XCTAssertEqual(proposal.items.first?.task?.title, "交周报")
        XCTAssertEqual(proposal.provider, "openai")
        XCTAssertEqual(proposal.promptTokens, 120)
        XCTAssertEqual(proposal.completionTokens, 48)
    }

    func testOpenAIAdapterFailsOnUnparsableEnvelope() async throws {
        MockURLProtocol.responder = { (200, Data("not-a-chat-envelope".utf8)) }
        let adapter = OpenAIAdapter(
            keyStore: InMemoryAIKeyStore(seed: [.openai: "sk-test-0000000000000000"]),
            transport: makeTransport())

        do {
            _ = try await adapter.proposeOperations(Self.input)
            XCTFail("无法解析的信封必须抛错")
        } catch let error as MovoError {
            XCTAssertEqual(error, .aiFailed(stage: .parse, cause: "openai_envelope"))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: - 8.1 无 Key / 模型目录

    func testAdapterWithoutKeyThrowsNoKey() async {
        let adapter = OpenAIAdapter(keyStore: InMemoryAIKeyStore())
        do {
            _ = try await adapter.proposeOperations(Self.input)
            XCTFail("缺少 Key 应抛错")
        } catch let error as MovoError {
            XCTAssertEqual(error, .noKey(vendor: .openai))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testAdapterExposesCatalogModels() {
        let adapter = OpenAIAdapter(keyStore: InMemoryAIKeyStore())
        XCTAssertEqual(adapter.id, .openai)
        XCTAssertFalse(adapter.availableModels().isEmpty)
        XCTAssertFalse(adapter.currentModel.isEmpty)
    }
}
