import XCTest
import MovoKit

/// 重复行动的多级步骤：模板下挂步骤，每次执行记录自己的勾选状态。
@MainActor
final class RecurrenceStepTests: XCTestCase {
    private func makeStore() -> DomainStore {
        DomainStore(repository: InMemoryRepository(),
                    clock: TravelClock(Date(timeIntervalSince1970: 1_800_000_000)),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: "Asia/Shanghai"),
                    deviceIDProvider: FixedDeviceIDProvider("step-tests"), defaults: .fallback)
    }

    private func makeRecurring(_ store: DomainStore, plan: UUID? = nil) async throws -> UUID {
        let result = try await store.execute(CreateTask(
            title: "背单词", planID: plan,
            recurrence: RecurrenceDraft(pattern: .daily, effectiveFrom: store.today)))
        return try XCTUnwrap(result.entityID)
    }

    private func addStep(_ title: String, to parent: UUID, store: DomainStore) async throws -> UUID {
        let result = try await store.execute(CreateTask(title: title, parentID: parent))
        return try XCTUnwrap(result.entityID)
    }

    private func fetchTask(_ id: UUID, _ store: DomainStore) async throws -> Task {
        let value = await store.repository.task(id)
        return try XCTUnwrap(value)
    }

    private func fetchOccurrence(_ id: UUID, _ store: DomainStore) async throws -> RecurrenceOccurrence {
        let value = await store.repository.occurrence(id)
        return try XCTUnwrap(value)
    }

    private func todayOccurrence(_ store: DomainStore, template: UUID) async throws -> RecurrenceOccurrence {
        _ = await store.materializeOccurrences(in: DateOnlyRange(lower: store.today, upper: store.today))
        let all = await store.repository.occurrences(taskID: template)
        return try XCTUnwrap(all.first)
    }

    func testStepsHangUnderTemplateAndStayOutOfTodoList() async throws {
        let store = makeStore()
        let template = try await makeRecurring(store)
        let learn = try await addStep("学新词", to: template, store: store)
        let group = try await addStep("第一组 20 个", to: learn, store: store)

        let learnTask = try await fetchTask(learn, store)
        let groupTask = try await fetchTask(group, store)
        XCTAssertTrue(learnTask.isStep)
        XCTAssertTrue(groupTask.isStep)
        XCTAssertEqual(groupTask.parentId, learn)

        let todos = await store.todos(includeCompleted: true)
        XCTAssertEqual(todos.map(\.id), [template], "步骤不进入待办列表")
        XCTAssertTrue(todos.first?.children.isEmpty == true)

        let templates = await store.repository.templateTasks()
        XCTAssertEqual(templates.map(\.id), [template], "只取顶层模板")

        let loaded = await store.taskDetail(template)
        let detail = try XCTUnwrap(loaded)
        XCTAssertTrue(detail.children.isEmpty)
    }

    func testStepsInheritPlanAndRejectTimesAndRecurrence() async throws {
        let store = makeStore()
        let planResult = try await store.execute(CreatePlan(name: "英语", kind: .improvement))
        let plan = try XCTUnwrap(planResult.entityID)
        let template = try await makeRecurring(store, plan: plan)
        let step = try await addStep("复习旧词", to: template, store: store)
        let stepTask = try await fetchTask(step, store)
        XCTAssertEqual(stepTask.planId, plan)

        do {
            _ = try await store.execute(CreateTask(title: "带时间", parentID: template,
                                                   startAt: .day(store.today)))
            XCTFail("步骤不单独设置时间")
        } catch is MovoError {}

        do {
            _ = try await store.execute(CreateTask(
                title: "再重复", parentID: template,
                recurrence: RecurrenceDraft(pattern: .daily, effectiveFrom: store.today)))
            XCTFail("步骤不能再设置重复频率")
        } catch is MovoError {}
    }

    func testPlainTaskWithChildrenCannotBecomeRecurring() async throws {
        let store = makeStore()
        let parent = try await store.execute(CreateTask(title: "汇报"))
        let parentID = try XCTUnwrap(parent.entityID)
        _ = try await store.execute(CreateTask(title: "数据", parentID: parentID))
        do {
            _ = try await store.execute(CreateRecurrence(taskID: parentID, pattern: .daily,
                                                         effectiveFrom: store.today))
            XCTFail("有子任务的待办不能设为重复行动")
        } catch is MovoError {}
    }

    func testTogglingSnapshotsStepsAndDerivesParents() async throws {
        let store = makeStore()
        let template = try await makeRecurring(store)
        let learn = try await addStep("学新词", to: template, store: store)
        let first = try await addStep("第一组", to: learn, store: store)
        let second = try await addStep("第二组", to: learn, store: store)
        let review = try await addStep("复习旧词", to: template, store: store)

        let occurrence = try await todayOccurrence(store, template: template)
        XCTAssertNil(occurrence.steps, "没有勾选过时不保存快照")

        _ = try await store.execute(ToggleOccurrenceStep(occurrenceID: occurrence.id, stepID: first, isDone: true))
        var updated = try await fetchOccurrence(occurrence.id, store)
        var steps = try XCTUnwrap(updated.steps)
        XCTAssertEqual(steps.count, 4)
        let progress = RecurrenceStepPolicy.leafProgress(steps)
        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.total, 3, "上级步骤不单独计数")
        XCTAssertEqual(steps.first(where: { $0.id == learn })?.isDone, false)

        _ = try await store.execute(ToggleOccurrenceStep(occurrenceID: occurrence.id, stepID: second, isDone: true))
        updated = try await fetchOccurrence(occurrence.id, store)
        steps = try XCTUnwrap(updated.steps)
        XCTAssertEqual(steps.first(where: { $0.id == learn })?.isDone, true, "下级都完成后上级自动勾上")
        XCTAssertFalse(RecurrenceStepPolicy.isAllDone(steps))

        _ = try await store.execute(ToggleOccurrenceStep(occurrenceID: occurrence.id, stepID: review, isDone: true))
        updated = try await fetchOccurrence(occurrence.id, store)
        let finalSteps = try XCTUnwrap(updated.steps)
        XCTAssertTrue(RecurrenceStepPolicy.isAllDone(finalSteps))
        XCTAssertEqual(updated.status, .pending, "步骤全部完成不会自动完成这一次")
    }

    func testParentStepCannotBeToggledDirectly() async throws {
        let store = makeStore()
        let template = try await makeRecurring(store)
        let learn = try await addStep("学新词", to: template, store: store)
        _ = try await addStep("第一组", to: learn, store: store)
        let occurrence = try await todayOccurrence(store, template: template)
        do {
            _ = try await store.execute(ToggleOccurrenceStep(occurrenceID: occurrence.id, stepID: learn, isDone: true))
            XCTFail("上级步骤由下级汇总")
        } catch is MovoError {}
    }

    func testChangingTemplateStepsDoesNotRewriteStartedOccurrence() async throws {
        let store = makeStore()
        let template = try await makeRecurring(store)
        let review = try await addStep("复习旧词", to: template, store: store)
        let occurrence = try await todayOccurrence(store, template: template)
        _ = try await store.execute(ToggleOccurrenceStep(occurrenceID: occurrence.id, stepID: review, isDone: true))

        _ = try await addStep("新增的步骤", to: template, store: store)
        let kept = try await fetchOccurrence(occurrence.id, store)
        XCTAssertEqual(kept.steps?.map(\.title), ["复习旧词"], "已开始的这一次保持原样")

        let display = await RecurrenceStepPolicy.displaySteps(of: kept, repository: store.repository)
        XCTAssertEqual(display.count, 1)
        let live = await RecurrenceStepPolicy.liveSteps(templateID: template, repository: store.repository)
        XCTAssertEqual(live.count, 2)
    }

    func testCompletingOccurrenceKeepsTemplateAndFutureSteps() async throws {
        let store = makeStore()
        let template = try await makeRecurring(store)
        _ = try await addStep("复习旧词", to: template, store: store)
        let occurrence = try await todayOccurrence(store, template: template)
        _ = try await store.execute(CompleteOccurrence(occurrenceID: occurrence.id, at: .precise(store.now)))
        let live = await RecurrenceStepPolicy.liveSteps(templateID: template, repository: store.repository)
        XCTAssertEqual(live.count, 1)
        let templateTask = try await fetchTask(template, store)
        XCTAssertEqual(templateTask.status, .todo)
    }

    func testUndoToggleRestoresPreviousSteps() async throws {
        let store = makeStore()
        let template = try await makeRecurring(store)
        let review = try await addStep("复习旧词", to: template, store: store)
        let occurrence = try await todayOccurrence(store, template: template)
        _ = try await store.execute(ToggleOccurrenceStep(occurrenceID: occurrence.id, stepID: review, isDone: true))
        let batch = try XCTUnwrap(store.lastNotification?.batchID)
        _ = try await store.undo(batchID: batch)
        let restored = try await fetchOccurrence(occurrence.id, store)
        XCTAssertNil(restored.steps)
    }

    func testDeletingStepRemovesItsSubtreeFromTemplate() async throws {
        let store = makeStore()
        let template = try await makeRecurring(store)
        let learn = try await addStep("学新词", to: template, store: store)
        _ = try await addStep("第一组", to: learn, store: store)
        let task = try await fetchTask(learn, store)
        _ = try await store.execute(DeleteTask(taskID: learn, baseRevision: task.revision))
        let live = await RecurrenceStepPolicy.liveSteps(templateID: template, repository: store.repository)
        XCTAssertTrue(live.isEmpty)
    }
}
