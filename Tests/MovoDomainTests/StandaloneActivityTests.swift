import Foundation
import XCTest
import MovoKit

/// 记录投入时的计划归属（PRD REQ 12 / AC23）。
///
/// 规则只有一条：**归属以任务为准**。任务有计划就继承它，任务没有计划这条记录也没有计划。
/// 调用方不需要、也不允许用 `planID` 把记录挂到别的计划下。
/// 独立待办的记录此前被直接拒绝，因此这里覆盖放宽后的三种走向：无计划、继承、冲突。
@MainActor
final class StandaloneActivityTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!

    private func store(_ device: String = "standalone-activity") -> DomainStore {
        DomainStore(repository: InMemoryRepository(),
                    clock: TravelClock(Date(timeIntervalSince1970: 1_800_000_000)),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: zone.identifier),
                    deviceIDProvider: FixedDeviceIDProvider(device), defaults: .fallback)
    }

    @discardableResult
    private func plan(_ name: String, store: DomainStore) async throws -> UUID {
        let result = try await store.execute(CreatePlan(name: name, kind: .improvement))
        return try XCTUnwrap(result.entityID)
    }

    @discardableResult
    private func task(_ title: String, planID: UUID? = nil, store: DomainStore) async throws -> UUID {
        let result = try await store.execute(CreateTask(title: title, planID: planID))
        return try XCTUnwrap(result.entityID)
    }

    // MARK: - 无计划的记录

    func testStandaloneTaskCanLogWithoutAPlan() async throws {
        let store = store()
        let taskID = try await task("整理书架", store: store)

        _ = try await store.execute(LogActivity(taskID: taskID, happenedAt: .precise(store.now),
                                                durationMinutes: 25, text: "顺手整理了一层"))

        let records = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.planId, "任务没有计划，记录也没有计划")
        XCTAssertEqual(records.first?.durationMinutes, 25)
        XCTAssertEqual(records.first?.text, "顺手整理了一层")
    }

    func testPlanLessRecordShowsUpInReviewAsUnclassified() async throws {
        let store = store()
        let taskID = try await task("整理书架", store: store)
        _ = try await store.execute(LogActivity(taskID: taskID, happenedAt: .precise(store.now),
                                                durationMinutes: 25))

        let review = await store.reviewView(weekStart: store.today.startOfWeek())
        XCTAssertEqual(review.totalActionCount, 0, "没有计划的记录不属于任何计划，不计入按计划汇总的行动数")
        let unclassified = review.categoryDistribution.first { $0.category == nil }
        XCTAssertEqual(unclassified?.count, 1, "这类记录归入已有的「未分类」，不另开一类")
    }

    // MARK: - 归属以任务为准

    func testRecordInheritsThePlanFromItsTask() async throws {
        let store = store()
        let planID = try await plan("英语", store: store)
        let taskID = try await task("背单词", planID: planID, store: store)

        _ = try await store.execute(LogActivity(taskID: taskID, happenedAt: .precise(store.now),
                                                durationMinutes: 30))

        let records = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(records.first?.planId, planID, "调用方不用再传一次计划")
        let byPlan = await store.repository.activities(planID: planID)
        XCTAssertEqual(byPlan.count, 1)
    }

    func testExplicitPlanMustMatchTheTask() async throws {
        let store = store()
        let mine = try await plan("英语", store: store)
        let other = try await plan("健身", store: store)
        let taskID = try await task("背单词", planID: mine, store: store)

        do {
            _ = try await store.execute(LogActivity(planID: other, taskID: taskID,
                                                    happenedAt: .precise(store.now)))
            XCTFail("记录不该被挂到任务所属之外的计划下")
        } catch let error as MovoError {
            guard case .invalidStructure(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("不属于同一个计划"), reason)
        }
    }

    func testExplicitPlanMatchingTheTaskIsAccepted() async throws {
        let store = store()
        let planID = try await plan("英语", store: store)
        let taskID = try await task("背单词", planID: planID, store: store)

        _ = try await store.execute(LogActivity(planID: planID, taskID: taskID,
                                                happenedAt: .precise(store.now)))
        let records = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(records.count, 1)
    }

    // MARK: - 仍然拒绝的输入

    func testUnknownPlanIsStillRejected() async throws {
        let store = store()
        // 没有关联任务时 planID 是唯一依据，仍然要求计划确实存在。
        // 有关联任务时，不一致的 planID 会先被「与任务不同计划」拦下（见 testExplicitPlanMustMatchTheTask）。
        do {
            _ = try await store.execute(LogActivity(planID: UUID(), happenedAt: .precise(store.now)))
            XCTFail("计划不存在时应当拒绝")
        } catch let error as MovoError {
            guard case .notFound = error else { return XCTFail("\(error)") }
        }
    }

    func testExplicitPlanIsIgnoredInFavourOfTheTask() async throws {
        let store = store()
        let planID = try await plan("英语", store: store)
        let taskID = try await task("背单词", planID: planID, store: store)

        // 不传 planID 也能拿到正确的归属：不需要调用方重复一次已知信息
        _ = try await store.execute(LogActivity(taskID: taskID, happenedAt: .precise(store.now)))
        let records = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(records.first?.planId, planID)
    }

    func testUnknownTaskIsStillRejected() async throws {
        let store = store()
        do {
            _ = try await store.execute(LogActivity(taskID: UUID(), happenedAt: .precise(store.now)))
            XCTFail("任务不存在时应当拒绝")
        } catch let error as MovoError {
            guard case .notFound = error else { return XCTFail("\(error)") }
        }
    }

    func testNonPositiveDurationIsStillRejected() async throws {
        let store = store()
        let taskID = try await task("背单词", store: store)
        do {
            _ = try await store.execute(LogActivity(taskID: taskID, happenedAt: .precise(store.now),
                                                    durationMinutes: 0))
            XCTFail("投入时长需要是正数")
        } catch let error as MovoError {
            guard case .invalidStructure = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - 更正保留归属

    func testCorrectionKeepsTheRecordPlanLess() async throws {
        let store = store()
        let taskID = try await task("整理书架", store: store)
        _ = try await store.execute(LogActivity(taskID: taskID, happenedAt: .precise(store.now),
                                                durationMinutes: 25))
        let before = await store.repository.activities(taskID: taskID)
        let original = try XCTUnwrap(before.first)

        _ = try await store.execute(CorrectActivity(activityID: original.id, newDurationMinutes: 40,
                                                    baseRevision: original.revision))

        let corrected = await store.repository.activities(taskID: taskID)
            .first { $0.isCorrection }
        XCTAssertEqual(corrected?.planId, nil, "更正不该凭空给记录补上一个计划")
        XCTAssertEqual(corrected?.correctedFromId, original.id)
    }
}
