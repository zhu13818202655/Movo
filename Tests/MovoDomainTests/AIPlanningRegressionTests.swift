import Foundation
import XCTest
import MovoKit

@MainActor
final class AIPlanningRegressionTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private var day: DateOnly { DateOnly(iso8601DateString: "2026-09-30", sourceTZ: zone.identifier)! }

    private func store(_ repository: InMemoryRepository = InMemoryRepository()) -> DomainStore {
        DomainStore(repository: repository, clock: TravelClock(day.noon),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: zone.identifier),
                    deviceIDProvider: FixedDeviceIDProvider("ai-regression"))
    }

    private func input(_ text: String, plans: [Plan] = []) -> AIInput {
        AIContextBuilder.build(sendableText: text, today: day, timeZone: zone, plans: plans,
                               tasksByPlan: [:], stagesByPlan: [:], metricsByPlan: [:],
                               occurrencesByTask: [:], defaults: .fallback)
    }

    private func validate(_ proposal: AIProposal, text: String, plans: [Plan] = []) -> ValidatedProposal {
        ProposalValidator.validate(proposal: proposal, input: input(text, plans: plans), plans: plans,
                                   tasks: [:], metrics: [:], occurrences: [:], today: day, timeZone: zone,
                                   defaults: .fallback, deviceId: "ai-regression", captureID: nil, source: .ai)
    }

    func testStandaloneTaskIsCreatedWithoutPlanAndCanBeUndone() async throws {
        let proposal = try XCTUnwrap(AIProposalCoding.decode("""
        {"items":[{"action":"create_task","source_span":"明天买牛奶","span":[0,5],
        "task":{"title":"买牛奶","scheduled_date":"2026-10-01"},"confidence":0.95}]}
        """))
        let validated = validate(proposal, text: "明天买牛奶")
        XCTAssertTrue(validated.needsConfirmation.isEmpty)
        XCTAssertTrue(validated.issues.isEmpty)
        XCTAssertEqual(validated.commands.count, 1)
        let repository = InMemoryRepository()
        let store = store(repository)
        let batch = try await store.executeBatchAllowingPartial(BatchInput(commands: validated.commands))
        XCTAssertEqual(batch.appliedCount, 1)
        let tasks = await store.repository.allTasks()
        let task = try XCTUnwrap(tasks.first)
        XCTAssertNil(task.planId)
        XCTAssertNil(task.hardDeadline)
        XCTAssertEqual(task.scheduledDate?.iso8601DateString, "2026-10-01")
        _ = try await store.undo(batchID: batch.batchID)
        let visible = await store.todos()
        XCTAssertTrue(visible.isEmpty)
        let operations = await store.repository.operations(batchID: batch.batchID)
        XCTAssertTrue(operations.allSatisfy { $0.status == .undone })
        let restarted = self.store(repository)
        let replay = try await restarted.executeBatchAllowingPartial(BatchInput(batchID: batch.batchID, commands: validated.commands))
        XCTAssertEqual(replay.state, .undone)
        let replayedVisible = await restarted.todos()
        XCTAssertTrue(replayedVisible.isEmpty)
    }

    func testLowConfidenceClassificationStillSavesIndependentTask() throws {
        let plan = Plan(name: "工作", kind: .delivery, cloudAIEnabled: true)
        let item = AIProposalItem(sourceSpan: "买牛奶", span: [0,3], action: .createTask,
                                  task: AIProposalTask(title: "买牛奶", planId: plan.id.uuidString), confidence: 0.2)
        let result = validate(AIProposal(items: [item]), text: "买牛奶", plans: [plan])
        let command = try XCTUnwrap(result.commands.first as? CreateTask)
        XCTAssertNil(command.planID)
        XCTAssertTrue(result.needsConfirmation.isEmpty)
        XCTAssertFalse(result.corrections.isEmpty)
    }

    func testExactSourceRepairsWrongOrMissingChineseOffsets() throws {
        for span in ["[0,99]", "[]"] {
            let proposal = try XCTUnwrap(AIProposalCoding.decode("""
            {"items":[{"action":"create_task","source_span":"买牛奶🥛","span":\(span),"task":{"title":"买牛奶"}}]}
            """))
            let result = validate(proposal, text: "明天买牛奶🥛")
            XCTAssertEqual(result.commands.count, 1)
            XCTAssertTrue(result.issues.isEmpty)
        }
    }

    func testAmbiguousSourceDoesNotRepairInvalidOffsetByGuessing() {
        let item = AIProposalItem(sourceSpan: "买牛奶", span: [99,102], action: .createTask,
                                  task: AIProposalTask(title: "买牛奶"))
        let result = validate(AIProposal(items: [item]), text: "买牛奶，买牛奶")
        XCTAssertTrue(result.commands.isEmpty)
        XCTAssertEqual(result.issues.first?.reasons, [.spanOutOfRange])
    }

    func testPlanRequiresPreviewAndConfirmationThenCreatesTasksAtomically() async throws {
        let text = "帮我建立搬家计划，整理物品和预约搬家公司"
        let item = AIProposalItem(sourceSpan: text, span: [0,text.count], action: .createPlan,
                                  plan: AIProposalPlan(name: "搬家", kind: .delivery, tasks: [
                                    AIProposalTask(title: "整理物品"), AIProposalTask(title: "预约搬家公司")
                                  ]), confidence: 1, needsConfirmation: false)
        let result = validate(AIProposal(items: [item]), text: text)
        XCTAssertTrue(result.commands.isEmpty, "模型不得关闭新计划的确认规则")
        let pending = try XCTUnwrap(result.needsConfirmation.first)
        XCTAssertEqual(pending.kind, .planCreation)
        let captureID = UUID()
        let planID = CaptureCommand.stableID(captureID: captureID, key: "plan")
        func commands() -> [any DomainCommand] {
            ProposalValidator.materialize(pending, tasks: [:], metrics: [:], timeZone: zone,
                                          today: day, source: .ai, captureID: captureID, planID: planID)
                .enumerated().map { CaptureCommand($0.element, captureID: captureID, key: "confirm|\($0.offset)") }
        }
        let repository = InMemoryRepository()
        let first = store(repository)
        _ = try await first.executeBatch(BatchInput(batchID: captureID, captureId: captureID, commands: commands()))
        let plan = await repository.plan(planID)
        XCTAssertEqual(plan?.name, "搬家")
        XCTAssertEqual(plan?.cloudAIEnabled, false)
        XCTAssertEqual(plan?.syncEnabled, false)
        let tasks = await repository.allTasks()
        XCTAssertEqual(tasks.count, 2)
        XCTAssertTrue(tasks.allSatisfy { $0.planId == planID })
        // 模拟重启，清掉内存幂等缓存；同批确认不再创建新计划或待办。
        let restarted = store(repository)
        _ = try await restarted.executeBatch(BatchInput(batchID: captureID, captureId: captureID, commands: commands()))
        let repeatedPlans = await repository.allPlans()
        let repeatedTasks = await repository.allTasks()
        XCTAssertEqual(repeatedPlans.count, 1)
        XCTAssertEqual(repeatedTasks.count, 2)
    }

    func testPlanRejectsInventedReferencesBeforeConfirmation() {
        let item = AIProposalItem(sourceSpan: "建搬家计划", span: [0,5], action: .createPlan,
                                  plan: AIProposalPlan(name: "搬家", kind: .delivery, tasks: [
                                    AIProposalTask(title: "整理", parentTaskId: UUID().uuidString)
                                  ]))
        let result = validate(AIProposal(items: [item]), text: "建搬家计划")
        XCTAssertTrue(result.commands.isEmpty)
        XCTAssertTrue(result.needsConfirmation.isEmpty)
        XCTAssertFalse(result.issues.isEmpty)
    }

    func testFailedPlanBatchDoesNotLeavePartialPlan() async throws {
        let store = store()
        let planID = UUID()
        do {
            _ = try await store.executeBatch(BatchInput(commands: [
                CreatePlan(id: planID, name: "搬家", kind: .delivery),
                CreateTask(title: "", planID: planID)
            ]))
            XCTFail("空标题必须导致整批回滚")
        } catch { }
        let plan = await store.repository.plan(planID)
        let tasks = await store.repository.allTasks()
        XCTAssertNil(plan)
        XCTAssertTrue(tasks.isEmpty)
    }

    func testUndoPreservesPlanContainingTaskEditedAfterCreation() async throws {
        let store = store()
        let planID = UUID(), taskID = UUID(), batchID = UUID()
        _ = try await store.executeBatch(BatchInput(batchID: batchID, commands: [
            CreatePlan(id: planID, name: "搬家", kind: .delivery),
            CreateTask(id: taskID, title: "整理物品", planID: planID)
        ]))
        let original = await store.repository.task(taskID)
        let revision = try XCTUnwrap(original).revision
        _ = try await store.execute(UpdateTask(taskID: taskID, patch: TaskPatch(title: "整理书籍"), baseRevision: revision))
        let undo = try await store.undo(batchID: batchID)
        XCTAssertEqual(undo.unsafeOperations.count, 2)
        let deleted = Set(await store.repository.tombstones(activeOnly: true).map(\.entityId))
        XCTAssertFalse(deleted.contains(planID))
        XCTAssertFalse(deleted.contains(taskID))
        let saved = await store.repository.task(taskID)
        XCTAssertEqual(saved?.title, "整理书籍")
    }

    func testOnlyCommittedOperationsAppearInResultCount() async throws {
        let store = store()
        let batchID = UUID()
        let commands: [any DomainCommand] = [CreateTask(title: "买牛奶"), CreateTask(title: "")]
        let batch = try await store.executeBatchAllowingPartial(BatchInput(batchID: batchID, commands: commands))
        var result = ProposalPreparation(privacy: PrivacySplitter.split(text: "买牛奶", plans: [], healthKeywords: []),
                                         validated: ValidatedProposal(commands: commands))
        XCTAssertFalse(result.resultMessage.contains("已整理 2"), "计划执行数不能当作写入成功数")
        result.appliedOperations = await store.repository.operations(batchID: batchID).filter { $0.status == .applied }
        result.commitRejections = batch.rejected
        XCTAssertEqual(result.appliedOperations.count, 1)
        XCTAssertEqual(result.commitRejections.count, 1)
        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(result.resultMessage.contains("已整理 1"))
    }

    func testReplayOfStandaloneCreationDoesNotDuplicateAfterRestart() async throws {
        let repository = InMemoryRepository()
        let captureID = UUID()
        let first = CaptureCommand(CreateTask(title: "买牛奶"), captureID: captureID, key: "same-item")
        _ = try await store(repository).executeBatchAllowingPartial(BatchInput(batchID: captureID, commands: [first]))
        let second = CaptureCommand(CreateTask(title: "买牛奶"), captureID: captureID, key: "same-item")
        XCTAssertEqual(first.operationID, second.operationID)
        _ = try await store(repository).executeBatchAllowingPartial(BatchInput(batchID: captureID, commands: [second]))
        let tasks = await repository.allTasks()
        XCTAssertEqual(tasks.count, 1)
    }

    func testSavedProposalRoundTripPreservesPlanAndSource() throws {
        let proposal = AIProposal(items: [AIProposalItem(sourceSpan: "建立阅读计划", span: [0,6], action: .createPlan,
                                                        plan: AIProposalPlan(name: "阅读", kind: .maintenance))])
        let data = try JSONEncoder().encode(proposal)
        XCTAssertEqual(try JSONDecoder().decode(AIProposal.self, from: data), proposal)
    }

    func testEmptyModelOutputShowsAnErrorAndKeepsInputForRecovery() async {
        let service = ProposalService(provider: SavedProposalProvider(proposal: AIProposal(items: [])), healthKeywords: [])
        let result = await service.prepare(ProposalRequest(rawText: "明天买牛奶", today: day,
                                                           timeZone: zone, deviceId: "ai-regression", plans: []))
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(result.autoCommands.isEmpty)
        XCTAssertNil(result.proposal, "空提案不能成为后续重试的固定回放结果")
        XCTAssertEqual(result.input?.text, "明天买牛奶")
    }

    func testTranscriptEditKeepsOriginalCaptureAndOriginalTime() async throws {
        let store = store()
        let captureID = UUID()
        _ = try await store.execute(ProcessCapture(id: captureID, rawText: "卖牛奶", inputMode: .voice))
        let original = await store.repository.capture(captureID)
        _ = try await store.execute(ProcessCapture(id: captureID, rawText: "不应覆盖的原文",
                                                   editedText: "买牛奶", inputMode: .voice, state: .processing))
        let updated = await store.repository.capture(captureID)
        XCTAssertEqual(updated?.rawText, "卖牛奶")
        XCTAssertEqual(updated?.effectiveText, "买牛奶")
        XCTAssertEqual(updated?.capturedAt, original?.capturedAt)
    }
}
