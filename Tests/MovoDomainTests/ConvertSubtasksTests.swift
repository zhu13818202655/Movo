import XCTest
import MovoKit

/// 带普通子任务的待办设为重复行动：子任务转成步骤。
@MainActor
final class ConvertSubtasksTests: XCTestCase {
    private func makeStore() -> DomainStore {
        DomainStore(repository: InMemoryRepository(),
                    clock: TravelClock(Date(timeIntervalSince1970: 1_800_000_000)),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: "Asia/Shanghai"),
                    deviceIDProvider: FixedDeviceIDProvider("convert-tests"), defaults: .fallback)
    }

    private struct Fixture {
        var plan: UUID
        var root: UUID
        var pick: UUID
        var drill: UUID
        var drillChild: UUID
        var signup: UUID
        var buy: UUID
    }

    private func create(_ store: DomainStore, _ title: String, plan: UUID, parent: UUID? = nil,
                        endAt: TimePoint? = nil) async throws -> UUID {
        let result = try await store.execute(CreateTask(title: title, planID: plan, parentID: parent, endAt: endAt))
        return try XCTUnwrap(result.entityID)
    }

    private func makeFixture(_ store: DomainStore) async throws -> Fixture {
        let planResult = try await store.execute(CreatePlan(name: "英语", kind: .improvement))
        let plan = try XCTUnwrap(planResult.entityID)
        let root = try await create(store, "备考", plan: plan)
        let pick = try await create(store, "选教材", plan: plan, parent: root, endAt: .day(store.today.adding(days: 3)))
        let drill = try await create(store, "刷题", plan: plan, parent: root)
        let drillChild = try await create(store, "第一套", plan: plan, parent: drill)
        let signup = try await create(store, "报名", plan: plan, parent: root)
        _ = try await store.execute(CompleteTask(taskID: signup, at: .precise(store.now)))
        let buy = try await create(store, "买书", plan: plan)
        _ = try await store.execute(AddDependency(taskID: buy, dependsOnID: pick))
        return Fixture(plan: plan, root: root, pick: pick, drill: drill, drillChild: drillChild,
                       signup: signup, buy: buy)
    }

    private func fetch(_ id: UUID, _ store: DomainStore) async throws -> Task {
        let value = await store.repository.task(id)
        return try XCTUnwrap(value)
    }

    private func convertAndRepeat(_ store: DomainStore, root: UUID) async throws -> BatchResult {
        try await store.executeBatch(BatchInput(
            commands: [ConvertSubtasksToSteps(taskID: root),
                       CreateRecurrence(taskID: root, pattern: .daily, effectiveFrom: store.today)],
            summary: "子任务转为步骤并设置重复"))
    }

    func testPreviewListsWhatWillChange() async throws {
        let store = makeStore()
        let f = try await makeFixture(store)
        let preview = await ConvertSubtasksToSteps.analyze(taskID: f.root, repository: store.repository)
        XCTAssertEqual(Set(preview.convertTitles), ["选教材", "刷题", "第一套"])
        XCTAssertEqual(preview.discardTitles, ["报名"])
        XCTAssertEqual(preview.droppedFieldCount, 1, "只有「选教材」带结束时间")
        XCTAssertEqual(preview.unlinkedDependentTitles, ["买书"])
        XCTAssertTrue(preview.blockers.isEmpty)
    }

    func testConvertingTurnsOpenSubtasksIntoStepsAndMovesClosedOnesToRecentlyDeleted() async throws {
        let store = makeStore()
        let f = try await makeFixture(store)
        _ = try await convertAndRepeat(store, root: f.root)

        let live = await RecurrenceStepPolicy.liveSteps(templateID: f.root, repository: store.repository)
        XCTAssertEqual(Set(live.map(\.task.title)), ["选教材", "刷题", "第一套"])
        XCTAssertEqual(live.first { $0.task.id == f.drillChild }?.depth, 1)

        let pick = try await fetch(f.pick, store)
        XCTAssertTrue(pick.isStep)
        XCTAssertNil(pick.endAt, "步骤不单独设置时间")

        let buy = try await fetch(f.buy, store)
        XCTAssertTrue(buy.dependencyIDs.isEmpty, "别的待办对被转换子任务的前置关系已解除")

        let todos = await store.todos(includeCompleted: true)
        XCTAssertEqual(Set(todos.map(\.task.title)), ["备考", "买书"], "步骤和已移走的子任务都不在待办里")

        let deleted = await store.repository.tombstones(activeOnly: true)
        XCTAssertTrue(deleted.contains { $0.entityId == f.signup })

        let rule = await store.repository.rule(forTask: f.root)
        XCTAssertNotNil(rule)
    }

    func testUndoRestoresSubtasksDependenciesAndRecentlyDeleted() async throws {
        let store = makeStore()
        let f = try await makeFixture(store)
        let result = try await convertAndRepeat(store, root: f.root)
        _ = try await store.undo(batchID: result.batchID)

        let root = try await fetch(f.root, store)
        XCTAssertFalse(root.isTemplate)
        let pick = try await fetch(f.pick, store)
        XCTAssertFalse(pick.isTemplate)
        XCTAssertEqual(pick.endAt, .day(store.today.adding(days: 3)))
        let buy = try await fetch(f.buy, store)
        XCTAssertEqual(buy.dependencyIDs, [f.pick])

        let todos = await store.todos(includeCompleted: true)
        let first = try XCTUnwrap(todos.first { $0.id == f.root })
        XCTAssertEqual(first.total, 3, "选教材、第一套、报名三个叶子")
        XCTAssertEqual(first.done, 1)
    }

    func testRefusesWhenAClosedSubtaskStillHasOpenChildren() async throws {
        let store = makeStore()
        let f = try await makeFixture(store)
        var drill = try await fetch(f.drill, store)
        drill.status = .done
        try await store.repository.upsert(drill)

        let preview = await ConvertSubtasksToSteps.analyze(taskID: f.root, repository: store.repository)
        XCTAssertEqual(preview.blockers.count, 1)
        do {
            _ = try await store.execute(ConvertSubtasksToSteps(taskID: f.root))
            XCTFail("已结束的子任务下还有未完成的子任务，应当拒绝")
        } catch is MovoError {}
    }

    func testPlainRecurrenceStillRejectsSubtasksWithoutConversion() async throws {
        let store = makeStore()
        let f = try await makeFixture(store)
        do {
            _ = try await store.execute(CreateRecurrence(taskID: f.root, pattern: .daily,
                                                         effectiveFrom: store.today))
            XCTFail("不转换就不能直接设重复")
        } catch is MovoError {}
    }
}
