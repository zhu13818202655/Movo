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
        "task":{"title":"买牛奶","start_at":"2026-10-01"}}]}
        """))
        let validated = validate(proposal, text: "明天买牛奶")
        XCTAssertEqual(validated.needsConfirmation.count, 1)
        XCTAssertTrue(validated.issues.isEmpty)
        let commands = ProposalValidator.materializeBatch(validated.needsConfirmation, timeZone: zone, today: day, source: .ai, captureID: nil)
        XCTAssertEqual(commands.count, 1)
        let repository = InMemoryRepository()
        let store = store(repository)
        let batch = try await store.executeBatchAllowingPartial(BatchInput(commands: commands))
        XCTAssertEqual(batch.appliedCount, 1)
        let tasks = await store.repository.allTasks()
        let task = try XCTUnwrap(tasks.first)
        XCTAssertNil(task.planId)
        XCTAssertNil(task.endAt)
        XCTAssertEqual(task.startAt?.dateOnly.iso8601DateString, "2026-10-01")
        XCTAssertEqual(task.startAt?.isInstant, false)
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

    func testExactSourceRepairsWrongOrMissingChineseOffsets() throws {
        for span in ["[0,99]", "[]"] {
            let proposal = try XCTUnwrap(AIProposalCoding.decode("""
            {"items":[{"action":"create_task","source_span":"买牛奶🥛","span":\(span),"task":{"title":"买牛奶"}}]}
            """))
            let result = validate(proposal, text: "明天买牛奶🥛")
            XCTAssertEqual(result.needsConfirmation.count, 1)
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
        // 计划级开关按分类默认（无分类 → 允许），AI 不额外改写；是否发云调用只由全局 AI 开关决定。
        XCTAssertEqual(plan?.cloudAIEnabled, true)
        XCTAssertEqual(plan?.syncEnabled, true)
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
        var result = ProposalPreparation(validated: ValidatedProposal(commands: commands))
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
        let service = ProposalService(provider: SavedProposalProvider(proposal: AIProposal(items: [])))
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

    // MARK: - 阶段归属与批内父子引用物化

    func testPlanWithStagesAndTasksWithBatchRefsMaterializesCorrectly() async throws {
        let json = """
        {
          "schema_version": 1,
          "items": [
            {
              "action": "create_plan",
              "source_span": "建立考研计划",
              "span": [0, 6],
              "plan": {
                "ref": "p1",
                "name": "考研复习",
                "kind": "delivery",
                "stages": [
                  {"ref": "s1", "name": "基础阶段", "start_at": "2026-10-01", "end_at": "2026-12-31"}
                ],
                "tasks": [
                  {"ref": "t1", "title": "背单词", "stage_ref": "s1", "start_at": "2026-10-01"},
                  {"ref": "t2", "title": "复习核心词汇", "parent_ref": "t1", "start_at": "2026-10-02"}
                ]
              },
              "needs_confirmation": true
            }
          ]
        }
        """
        let proposal = try XCTUnwrap(AIProposalCoding.decode(json))
        let validated = validate(proposal, text: "建立考研计划")
        XCTAssertEqual(validated.needsConfirmation.count, 1)
        XCTAssertTrue(validated.issues.isEmpty)

        let commands = ProposalValidator.materializeBatch(
            validated.needsConfirmation, timeZone: zone, today: day, source: .ai, captureID: nil)
        XCTAssertEqual(commands.count, 4, "应生成 1 个 CreatePlan、1 个 CreateStage、2 个 CreateTask")

        let store = store()
        let batch = try await store.executeBatchAllowingPartial(BatchInput(commands: commands))
        XCTAssertEqual(batch.appliedCount, 4)

        let plans = await store.repository.allPlans()
        let plan = try XCTUnwrap(plans.first(where: { $0.name == "考研复习" }))
        let stages = await store.repository.stages(planID: plan.id)
        XCTAssertEqual(stages.count, 1)
        let stage = try XCTUnwrap(stages.first)
        XCTAssertEqual(stage.name, "基础阶段")

        let tasks = await store.repository.tasks(planID: plan.id)
        XCTAssertEqual(tasks.count, 2)
        let parentTask = try XCTUnwrap(tasks.first(where: { $0.title == "背单词" }))
        let childTask = try XCTUnwrap(tasks.first(where: { $0.title == "复习核心词汇" }))
        XCTAssertEqual(parentTask.stageId, stage.id)
        XCTAssertEqual(childTask.parentId, parentTask.id)
    }

    // MARK: - 批内引用校验：重复、悬空与循环

    func testBatchReferenceValidationRejectsDuplicatesDanglingAndCycles() throws {
        // 1. 重复 ref
        let dupJSON = """
        {
          "schema_version": 1,
          "items": [
            {
              "action": "create_task", "source_span": "任务一", "span": [0, 3],
              "task": {"ref": "same_ref", "title": "任务一"}
            },
            {
              "action": "create_task", "source_span": "任务二", "span": [4, 7],
              "task": {"ref": "same_ref", "title": "任务二"}
            }
          ]
        }
        """
        let dupProposal = try XCTUnwrap(AIProposalCoding.decode(dupJSON))
        let dupResult = validate(dupProposal, text: "任务一 任务二")
        XCTAssertTrue(dupResult.issues.contains(where: { $0.reasons.contains(where: { r in
            if case .structureViolation(let msg) = r { return msg.contains("重复") }
            return false
        })}))

        // 2. 悬空引用
        let danglingJSON = """
        {
          "schema_version": 1,
          "items": [
            {
              "action": "create_task", "source_span": "子任务", "span": [0, 3],
              "task": {"ref": "child", "title": "子任务", "parent_ref": "not_exist_ref"}
            }
          ]
        }
        """
        let danglingProposal = try XCTUnwrap(AIProposalCoding.decode(danglingJSON))
        let danglingResult = validate(danglingProposal, text: "子任务")
        XCTAssertTrue(danglingResult.issues.contains(where: { $0.reasons.contains(where: { r in
            if case .unknownReference(let ref) = r { return ref == "not_exist_ref" }
            return false
        })}))

        // 3. 循环引用
        let cycleJSON = """
        {
          "schema_version": 1,
          "items": [
            {
              "action": "create_task", "source_span": "任务A", "span": [0, 3],
              "task": {"ref": "tA", "title": "任务A", "parent_ref": "tB"}
            },
            {
              "action": "create_task", "source_span": "任务B", "span": [4, 7],
              "task": {"ref": "tB", "title": "任务B", "parent_ref": "tA"}
            }
          ]
        }
        """
        let cycleProposal = try XCTUnwrap(AIProposalCoding.decode(cycleJSON))
        let cycleResult = validate(cycleProposal, text: "任务A 任务B")
        XCTAssertTrue(cycleResult.issues.contains(where: { $0.reasons.contains(where: { r in
            if case .structureViolation(let msg) = r { return msg.contains("循环") }
            return false
        })}))
    }

    // MARK: - 重复任务规则校验：仅允许步骤，拒绝作为子任务

    func testCreateTaskWithRecurrenceRejectsParentOrSubtaskAndAcceptsSteps() async throws {
        // 1. 重复任务带有父节点 -> 拒绝
        let recAsChildJSON = """
        {
          "schema_version": 1,
          "items": [
            {
              "action": "create_task", "source_span": "每日晨跑", "span": [0, 4],
              "task": {
                "title": "晨跑",
                "parent_task_id": "11111111-1111-1111-1111-111111111111",
                "recurrence": {"pattern": "daily"}
              }
            }
          ]
        }
        """
        let recChildProposal = try XCTUnwrap(AIProposalCoding.decode(recAsChildJSON))
        let childResult = validate(recChildProposal, text: "每日晨跑")
        XCTAssertTrue(childResult.issues.contains(where: { $0.reasons.contains(where: { r in
            if case .structureViolation(let msg) = r { return msg.contains("重复任务") }
            return false
        })}))

        // 2. 重复任务带有步骤 -> 成功物化为模板与步骤
        let recWithStepsJSON = """
        {
          "schema_version": 1,
          "items": [
            {
              "action": "create_task", "source_span": "背单词", "span": [0, 3],
              "task": {
                "ref": "rec_word",
                "title": "背单词",
                "recurrence": {"pattern": "daily"},
                "steps": [
                  {"title": "复习旧词"},
                  {"title": "学习新词"}
                ]
              }
            }
          ]
        }
        """
        let recStepsProposal = try XCTUnwrap(AIProposalCoding.decode(recWithStepsJSON))
        let stepsResult = validate(recStepsProposal, text: "背单词")
        XCTAssertTrue(stepsResult.issues.isEmpty)
        XCTAssertEqual(stepsResult.needsConfirmation.count, 1)

        let commands = ProposalValidator.materializeBatch(
            stepsResult.needsConfirmation, timeZone: zone, today: day, source: .ai, captureID: nil)
        let store = store()
        let batch = try await store.executeBatchAllowingPartial(BatchInput(commands: commands))
        XCTAssertEqual(batch.appliedCount, 3, "1 个模板待办 + 2 个步骤待办")

        let allTasks = await store.repository.allTasks()
        let template = try XCTUnwrap(allTasks.first(where: { $0.title == "背单词" }))
        XCTAssertTrue(template.isTemplate)
        XCTAssertNil(template.parentId)

        let steps = allTasks.filter { $0.parentId == template.id }
        XCTAssertEqual(steps.count, 2)
        XCTAssertTrue(steps.allSatisfy { $0.isTemplate })
    }

    // MARK: - 回退步数限制（Defaults.json undo_steps，默认 5 步）

    func testUndoStepsLimitedToDefaultsN() async throws {
        let store = store()
        var batchIDs: [UUID] = []

        // 连续执行 7 个独立批次
        for i in 1...7 {
            let cmd = CreateTask(title: "待办 \(i)")
            let batch = try await store.executeBatchAllowingPartial(BatchInput(commands: [cmd]))
            batchIDs.append(batch.batchID)
        }

        // 第 7 个批次（最近第 1 步）应该可以撤销
        let latestID = try XCTUnwrap(batchIDs.last)
        let undoResult = try await store.undo(batchID: latestID)
        XCTAssertEqual(undoResult.undoneOperations.count, 1)

        // 第 1 个批次已经超过了最近 5 步（属于第 6 步或更早）-> 必须被拒绝抛错
        let oldestID = try XCTUnwrap(batchIDs.first)
        do {
            _ = try await store.undo(batchID: oldestID)
            XCTFail("超出步数限制的批次撤销必须抛错拒绝")
        } catch let error as MovoError {
            if case .invalidStructure(let reason) = error {
                XCTAssertTrue(reason.contains("限制"))
            } else {
                XCTFail("错误的错误类型：\(error)")
            }
        }
    }

    // MARK: - 空启动无演示数据

    func testStoreStartsEmptyWithoutDemoSeed() async {
        let repository = InMemoryRepository()
        let store = DomainStore(repository: repository, clock: TravelClock(day.noon),
                                timeZoneProvider: FixedTimeZoneProvider(identifier: zone.identifier),
                                deviceIDProvider: FixedDeviceIDProvider("empty-test"))
        let plans = await store.repository.allPlans()
        let tasks = await store.repository.allTasks()
        XCTAssertTrue(plans.isEmpty, "初始计划必须为空")
        XCTAssertTrue(tasks.isEmpty, "初始任务必须为空")
    }
}
