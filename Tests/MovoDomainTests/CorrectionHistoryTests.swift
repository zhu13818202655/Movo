import Foundation
import XCTest
import MovoKit

/// 「当前值」的过滤：更正之后列表里只留新的那条（PRD 3.4 保留旧版本）。
///
/// 更正不改写原来那条，所以库里新旧两条并存。列表/导出要回答的是「现在是多少」，
/// 因此被别的记录指向过的不再出现。分两层验证：策略本身的行为，以及接上存储之后
/// 任务详情会不会真的显示成两条。
@MainActor
final class CorrectionHistoryTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func store(_ device: String = "correction-history") -> DomainStore {
        DomainStore(repository: InMemoryRepository(),
                    clock: TravelClock(epoch),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: zone.identifier),
                    deviceIDProvider: FixedDeviceIDProvider(device), defaults: .fallback)
    }

    /// 手工造记录，只关心 id 和指向关系。
    private func record(_ id: UUID, replacing: UUID? = nil, minutes: Int? = nil) -> ActionRecord {
        ActionRecord(id: id, planId: nil, happenedAt: .precise(epoch), durationMinutes: minutes,
                     isCorrection: replacing != nil, correctedFromId: replacing)
    }

    // MARK: - 策略

    func testEmptyStaysEmpty() {
        XCTAssertTrue(CorrectionHistory.current([ActionRecord]()).isEmpty)
    }

    func testAPlainRecordIsItsOwnCurrentValue() {
        let a = record(UUID(), minutes: 25)
        XCTAssertEqual(CorrectionHistory.current([a]).map(\.id), [a.id])
    }

    func testCorrectionHidesTheVersionItReplaced() {
        let original = UUID(), fixed = UUID()
        let list = [record(original, minutes: 25), record(fixed, replacing: original, minutes: 40)]

        let current = CorrectionHistory.current(list)
        XCTAssertEqual(current.map(\.id), [fixed], "旧版本不该和新版本并排显示")
        XCTAssertEqual(current.first?.durationMinutes, 40)
    }

    func testSecondCorrectionLeavesOnlyTheLatest() {
        // A → B → C：B 既取代了 A，又被 C 取代，所以只剩 C。
        let a = UUID(), b = UUID(), c = UUID()
        let list = [record(a, minutes: 25),
                    record(b, replacing: a, minutes: 40),
                    record(c, replacing: b, minutes: 60)]

        let current = CorrectionHistory.current(list)
        XCTAssertEqual(current.map(\.id), [c])
        XCTAssertEqual(current.first?.durationMinutes, 60)
    }

    func testIndependentChainsEachKeepTheirHead() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let list = [record(a, minutes: 25), record(b, replacing: a, minutes: 40),
                    record(c, minutes: 15), record(d, replacing: c, minutes: 30)]

        XCTAssertEqual(CorrectionHistory.current(list).map(\.id), [b, d], "两条链互不影响")
    }

    func testOnlyTheCorrectedOneDisappears() {
        let kept = UUID(), original = UUID(), fixed = UUID()
        let list = [record(kept, minutes: 15),
                    record(original, minutes: 25), record(fixed, replacing: original, minutes: 40)]

        XCTAssertEqual(CorrectionHistory.current(list).map(\.id), [kept, fixed])
    }

    func testOrderIsPreserved() {
        // d 取代 c：被藏掉的只有 c，剩下的三条件仍按传入顺序排（a 与 b 谁前谁后由调用方定）。
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let list = [record(d, replacing: c, minutes: 60), record(a, minutes: 25),
                    record(c, minutes: 15), record(b, minutes: 40)]

        XCTAssertEqual(CorrectionHistory.current(list).map(\.id), [d, a, b],
                       "只过滤，不重排（排序是调用方的事）")
    }

    func testBackReferenceOutsideTheListHidesNothing() {
        // 指向的那条不在这批里（比如按天取了一次记录）时，这条只是普通记录，不能被误滤掉。
        let stray = record(UUID(), replacing: UUID(), minutes: 25)
        XCTAssertEqual(CorrectionHistory.current([stray]).map(\.id), [stray.id])
    }

    func testMeasurementUsesTheSameRule() {
        let metricID = UUID(), original = UUID(), fixed = UUID()
        let made = Date(timeIntervalSince1970: 1_800_000_000)
        let day = DateOnly(y: 2027, m: 1, d: 15, sourceTZ: zone.identifier)
        let list = [Measurement(id: original, planId: UUID(), metricId: metricID, measuredAt: day,
                                value: 3, unit: "次", recordedAt: made, revision: 1),
                    Measurement(id: fixed, planId: UUID(), metricId: metricID, measuredAt: day,
                                value: 5, unit: "次", isCorrection: true, correctedFromId: original,
                                recordedAt: made, revision: 1)]

        let current = CorrectionHistory.current(list)
        XCTAssertEqual(current.map(\.id), [fixed])
        XCTAssertEqual(current.first?.value, 5)
    }

    // MARK: - 接上存储之后

    @discardableResult
    private func task(_ title: String, store: DomainStore) async throws -> UUID {
        let result = try await store.execute(CreateTask(title: title))
        return try XCTUnwrap(result.entityID)
    }

    /// 刚记下、还没被改过的那条（XCTUnwrap 的 autoclosure 放不下 await，所以先取出来）。
    private func soleActivity(_ taskID: UUID, in store: DomainStore) async throws -> ActionRecord {
        let records = await store.repository.activities(taskID: taskID)
        return try XCTUnwrap(records.first)
    }

    func testCorrectionThenCorrectingTheCorrection() async throws {
        let store = store()
        let taskID = try await task("背单词", store: store)
        _ = try await store.execute(LogActivity(taskID: taskID, happenedAt: .precise(store.now),
                                               durationMinutes: 25))
        let logged = try await soleActivity(taskID, in: store)

        _ = try await store.execute(CorrectActivity(activityID: logged.id, newDurationMinutes: 40,
                                                    baseRevision: logged.revision))
        let afterFirst = await store.repository.activities(taskID: taskID)
        let first = try XCTUnwrap(afterFirst.first { $0.isCorrection })

        _ = try await store.execute(CorrectActivity(activityID: first.id, newDurationMinutes: 60,
                                                    baseRevision: first.revision))

        // 库里三条都在（旧版本没有丢），列表只看到最后那条。
        let stored = await store.repository.activities(taskID: taskID)
        XCTAssertEqual(stored.count, 3)
        let loaded = await store.taskDetail(taskID)
        let detail = try XCTUnwrap(loaded)
        XCTAssertEqual(detail.activities.count, 1)
        XCTAssertEqual(detail.activities.first?.durationMinutes, 60)
    }

    func testTaskDetailShowsOnlyTheCurrentValue() async throws {
        let store = store()
        let taskID = try await task("背单词", store: store)
        _ = try await store.execute(LogActivity(taskID: taskID, happenedAt: .precise(store.now),
                                               durationMinutes: 25))
        let logged = try await soleActivity(taskID, in: store)

        _ = try await store.execute(CorrectActivity(activityID: logged.id, newDurationMinutes: 40,
                                                    newText: "实际四十分钟",
                                                    baseRevision: logged.revision))

        let loaded = await store.taskDetail(taskID)
        let detail = try XCTUnwrap(loaded)
        XCTAssertEqual(detail.activities.count, 1, "改完不该看到两条")
        XCTAssertEqual(detail.activities.first?.durationMinutes, 40)
        XCTAssertEqual(detail.activities.first?.text, "实际四十分钟")
    }

    func testPlanRecordListShowsOnlyTheCurrentValue() async throws {
        let store = store()
        let planResult = try await store.execute(CreatePlan(name: "英语", kind: .improvement))
        let planID = try XCTUnwrap(planResult.entityID)
        let taskResult = try await store.execute(CreateTask(title: "背单词", planID: planID))
        let taskID = try XCTUnwrap(taskResult.entityID)
        _ = try await store.execute(LogActivity(taskID: taskID, happenedAt: .precise(store.now),
                                               durationMinutes: 30))
        let logged = try await soleActivity(taskID, in: store)

        _ = try await store.execute(CorrectActivity(activityID: logged.id, newDurationMinutes: 50,
                                                    baseRevision: logged.revision))

        // 计划详情的记录列表走的是 planID 这条查询（见 PlanDetailScreen.reload）。
        let byPlan = await store.repository.activities(planID: planID)
        let current = CorrectionHistory.current(byPlan)
        XCTAssertEqual(byPlan.count, 2, "库里两条都在")
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.durationMinutes, 50)
    }
}
