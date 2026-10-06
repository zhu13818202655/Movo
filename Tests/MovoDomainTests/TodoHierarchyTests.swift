import XCTest
import MovoKit

@MainActor
final class TodoHierarchyTests: XCTestCase {
    private func makeStore() -> DomainStore {
        DomainStore(repository: InMemoryRepository(),
                    clock: TravelClock(Date(timeIntervalSince1970: 1_800_000_000)),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: "Asia/Shanghai"),
                    deviceIDProvider: FixedDeviceIDProvider("todo-tests"), defaults: .fallback)
    }

    @discardableResult
    private func add(_ title: String, to store: DomainStore, parent: UUID? = nil,
                     plan: UUID? = nil, date: DateOnly? = nil) async throws -> UUID {
        let result = try await store.execute(CreateTask(title: title, planID: plan,
                                                        parentID: parent,
                                                        startAt: date.map { TimePoint.day($0) }))
        return try XCTUnwrap(result.entityID)
    }

    private func plan(_ name: String, store: DomainStore) async throws -> UUID {
        let result = try await store.execute(CreatePlan(name: name, kind: .delivery))
        return try XCTUnwrap(result.entityID)
    }

    func testManualStandaloneCreationNeedsNoCaptureAndCanBeUndone() async throws {
        let store = makeStore()
        let id = try await add("买牛奶", to: store)
        let captures = await store.repository.allCaptures()
        let tasks = await store.todos(filter: .unscheduled)
        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(tasks.map(\.id), [id])
        XCTAssertNil(tasks.first?.task.planId)
        XCTAssertEqual(tasks.first?.task.source, .manual)
        let batch = try XCTUnwrap(store.lastNotification?.batchID)
        let undone = try await store.undo(batchID: batch)
        XCTAssertEqual(undone.undoneOperations.count, 1)
        let after = await store.todos()
        XCTAssertTrue(after.isEmpty)
    }

    func testNestedTasksAndLeafProgressAtEveryLevel() async throws {
        let store = makeStore()
        let root = try await add("汇报", to: store)
        let child = try await add("数据", to: store, parent: root)
        let leaf = try await add("销售", to: store, parent: child)
        let second = try await add("区域", to: store, parent: child)
        _ = try await store.execute(CompleteTask(taskID: leaf, at: .precise(store.now)))
        let nodes = await store.todos(includeCompleted: true)
        let first = try XCTUnwrap(nodes.first)
        XCTAssertEqual(first.id, root)
        XCTAssertEqual(first.total, 2)
        XCTAssertEqual(first.done, 1)
        XCTAssertEqual(first.children.first?.children.count, 2)
        _ = try await store.execute(CompleteTask(taskID: second, at: .precise(store.now)))
        let pending = await store.todos()
        XCTAssertTrue(pending.isEmpty, "父任务按所有后代叶子汇总，不重复计数")
    }

    func testFiltersPreserveAncestorsAndSeparateUnscheduledFromToday() async throws {
        let store = makeStore()
        let root = try await add("汇报", to: store)
        let child = try await add("数据", to: store, parent: root)
        let leaf = try await add("销售", to: store, parent: child, date: store.today.adding(days: 2))
        let daily = await store.todos(filter: .today)
        XCTAssertTrue(daily.isEmpty)
        let upcoming = await store.todos(filter: .upcoming)
        XCTAssertEqual(upcoming.first?.id, root)
        XCTAssertEqual(upcoming.first?.isContext, true)
        XCTAssertEqual(upcoming.first?.children.first?.children.first?.id, leaf)
        let unscheduled = await store.todos(filter: .unscheduled)
        XCTAssertTrue(unscheduled.first?.children.first?.children.isEmpty == true)
    }

    func testPlanTreeRetainsDeepNodesAndParentIdentity() async throws {
        let store = makeStore()
        let planID = try await plan("工作", store: store)
        let root = try await add("汇报", to: store, plan: planID)
        let child = try await add("数据", to: store, parent: root, plan: planID)
        let leaf = try await add("销售", to: store, parent: child, plan: planID)
        let tree = await store.planTree(planID, depth: 1)
        XCTAssertEqual(tree.nodes.first?.task?.id, root)
        XCTAssertEqual(tree.nodes.first?.children.first?.children.first?.task?.id, leaf)
        XCTAssertEqual(tree.leafTotal, 1)
    }

    func testMovingUnderDescendantIsRejectedWithoutChangingTree() async throws {
        let store = makeStore()
        let root = try await add("汇报", to: store)
        let child = try await add("数据", to: store, parent: root)
        let leaf = try await add("销售", to: store, parent: child)
        do {
            _ = try await store.execute(ReassignTask(taskID: root, planID: nil, parentID: leaf))
            XCTFail("必须拒绝循环嵌套")
        } catch is MovoError { }
        let unchanged = await store.repository.task(root)
        XCTAssertNil(unchanged?.parentId)
    }

    func testReparentAndOutdentPreserveDescendants() async throws {
        let store = makeStore()
        let root = try await add("汇报", to: store)
        let child = try await add("数据", to: store, parent: root)
        let leaf = try await add("销售", to: store, parent: child)
        let other = try await add("项目", to: store)
        _ = try await store.execute(ReassignTask(taskID: child, planID: nil, parentID: other))
        let moved = await store.repository.task(child)
        let kept = await store.repository.task(leaf)
        XCTAssertEqual(moved?.parentId, other)
        XCTAssertEqual(kept?.parentId, child)
        _ = try await store.execute(ReassignTask(taskID: child, planID: nil))
        let lifted = await store.repository.task(child)
        XCTAssertNil(lifted?.parentId)
    }

    func testCrossPlanMoveAndUndoRestoreWholeTreeIncludingNilParent() async throws {
        let store = makeStore()
        let first = try await plan("原计划", store: store)
        let second = try await plan("目标计划", store: store)
        let root = try await add("汇报", to: store, plan: first)
        let child = try await add("数据", to: store, parent: root, plan: first)
        let leaf = try await add("销售", to: store, parent: child, plan: first)
        let target = try await add("项目", to: store, plan: second)
        _ = try await store.execute(ReassignTask(taskID: root, planID: second, parentID: target))
        let batch = try XCTUnwrap(store.lastNotification?.batchID)
        for id in [root, child, leaf] {
            let task = await store.repository.task(id)
            XCTAssertEqual(task?.planId, second)
        }
        _ = try await store.undo(batchID: batch)
        for id in [root, child, leaf] {
            let task = await store.repository.task(id)
            XCTAssertEqual(task?.planId, first)
        }
        let restored = await store.repository.task(root)
        XCTAssertNil(restored?.parentId)
    }

    func testUndoMoveDoesNotOverwriteNewDescendantEdits() async throws {
        let store = makeStore()
        let planID = try await plan("工作", store: store)
        let root = try await add("汇报", to: store)
        let child = try await add("数据", to: store, parent: root)
        _ = try await store.execute(ReassignTask(taskID: root, planID: planID))
        let batch = try XCTUnwrap(store.lastNotification?.batchID)
        _ = try await store.execute(UpdateTask(taskID: child, patch: TaskPatch(title: "最新数据")))
        let result = try await store.undo(batchID: batch)
        XCTAssertEqual(result.unsafeOperations.count, 1)
        let task = await store.repository.task(child)
        XCTAssertEqual(task?.title, "最新数据")
        XCTAssertEqual(task?.planId, planID)
    }

    func testUndoCreateKeepsLaterAddedChildVisible() async throws {
        let store = makeStore()
        let root = try await add("汇报", to: store)
        let batch = try XCTUnwrap(store.lastNotification?.batchID)
        _ = try await add("数据", to: store, parent: root)
        let result = try await store.undo(batchID: batch)
        XCTAssertEqual(result.unsafeOperations.count, 1)
        let deleted = await store.repository.isTombstoned(root)
        XCTAssertFalse(deleted)
    }

    func testUndoMoveKeepsLaterAddedDescendantsInSamePlan() async throws {
        let store = makeStore()
        let planID = try await plan("工作", store: store)
        let root = try await add("汇报", to: store)
        _ = try await store.execute(ReassignTask(taskID: root, planID: planID))
        let batch = try XCTUnwrap(store.lastNotification?.batchID)
        let child = try await add("新增数据", to: store, parent: root, plan: planID)
        let result = try await store.undo(batchID: batch)
        XCTAssertEqual(result.unsafeOperations.count, 1)
        let parentTask = await store.repository.task(root)
        let childTask = await store.repository.task(child)
        XCTAssertEqual(parentTask?.planId, planID)
        XCTAssertEqual(childTask?.planId, planID)
    }

    func testUpdateTaskReassignmentCascadesAndCanBeUndone() async throws {
        let store = makeStore()
        let planID = try await plan("工作", store: store)
        let root = try await add("汇报", to: store)
        let child = try await add("数据", to: store, parent: root)
        _ = try await store.execute(UpdateTask(taskID: root, patch: TaskPatch(title: "季度汇报", planID: planID)))
        let batch = try XCTUnwrap(store.lastNotification?.batchID)
        let moved = await store.repository.task(child)
        XCTAssertEqual(moved?.planId, planID)
        _ = try await store.undo(batchID: batch)
        let restored = await store.repository.task(root)
        let restoredChild = await store.repository.task(child)
        XCTAssertEqual(restored?.title, "汇报")
        XCTAssertNil(restored?.planId)
        XCTAssertNil(restoredChild?.planId)
    }

    func testDeletePreviewRejectsNewChildrenAndRestoresOnlySameDeletion() async throws {
        let store = makeStore()
        let root = try await add("汇报", to: store)
        let child = try await add("数据", to: store, parent: root)
        _ = try await store.execute(DeleteTask(taskID: child))
        let later = try await add("成稿", to: store, parent: root)
        do {
            _ = try await store.execute(DeleteTask(taskID: root, expectedTaskIDs: [root]))
            XCTFail("预览之后新增了子任务，必须重新确认")
        } catch is MovoError { }
        _ = try await store.execute(DeleteTask(taskID: root, expectedTaskIDs: [root, later]))
        let empty = await store.todos(includeCompleted: true)
        XCTAssertTrue(empty.isEmpty)
        _ = try await store.execute(RestoreEntity(entityType: .task, id: root))
        let oldDeleted = await store.repository.isTombstoned(child)
        let newRestored = await store.repository.isTombstoned(later)
        XCTAssertTrue(oldDeleted)
        XCTAssertFalse(newRestored)
    }

    func testParentCannotCompleteUnfinishedChildren() async throws {
        let store = makeStore()
        let root = try await add("汇报", to: store)
        _ = try await add("数据", to: store, parent: root)
        do {
            _ = try await store.execute(CompleteTask(taskID: root, at: .precise(store.now)))
            XCTFail("父节点的完成由子任务汇总")
        } catch is MovoError { }
    }

    func testClearedOptionalFieldsAreIncludedInChangeEventsAndUndo() async throws {
        let store = makeStore()
        let date = store.today.adding(days: 3)
        let id = try await add("汇报", to: store, date: date)
        _ = try await store.execute(ScheduleTask(taskID: id, startAt: nil))
        let batch = try XCTUnwrap(store.lastNotification?.batchID)
        _ = try await store.undo(batchID: batch)
        let restored = await store.repository.task(id)
        XCTAssertEqual(restored?.startAt, TimePoint.day(date))
    }
}
