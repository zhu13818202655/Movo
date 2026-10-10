import Foundation
import XCTest
import MovoKit

/// 进行中专注会话的本地持久化。
///
/// 这一层要保证的事只有一件：**App 被系统回收或退出后重新打开，计时接着走**。
/// 所有显示都由会话字段与当前时刻推导（见 `FocusPolicy`），所以「恢复」不需要
/// 单独的状态机——把字段原样读回来就够。这里锁住的是：
/// · 字段一个不少地往返，含暂停区间与锚点时区；
/// · 换一个实例读同一份偏好就能拿到（这就是冷启动）；
/// · 读坏了按「没有进行中的计时」处理，不抛错、不卡启动。
final class FocusSessionStoreTests: XCTestCase {

    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private let taskID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private var createdSuites: [String] = []

    /// 2026-10-08，周四。
    private var day: DateOnly { DateOnly(iso8601DateString: "2026-10-08", sourceTZ: zone.identifier)! }

    override func tearDown() {
        for name in createdSuites { UserDefaults.standard.removePersistentDomain(forName: name) }
        createdSuites = []
        super.tearDown()
    }

    private func instant(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) throws -> TimePoint {
        try XCTUnwrap(TimePoint.makeInstant(
            on: day, at: TimeOfDay(hour: hour, minute: minute, second: second), in: zone))
    }

    private func moment(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) throws -> Date {
        try instant(hour, minute, second).sortEpoch
    }

    /// 每个用例一块独立的偏好域，互不影响，也不碰真实偏好。
    private func makeStore() -> (store: UserDefaultsFocusSessionStore, defaults: UserDefaults) {
        let name = "movo.tests.focus.\(UUID().uuidString)"
        createdSuites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        return (UserDefaultsFocusSessionStore(defaults: defaults), defaults)
    }

    private func makeSession(startHour: Int = 14, startMinute: Int = 0) throws -> FocusPolicy.Session {
        let startAt = try instant(startHour, startMinute)
        let endAt = try instant(14, 30)
        let start = try moment(startHour, startMinute)
        let plan = FocusPolicy.plan(startAt: startAt, endAt: endAt, estimateMinutes: nil,
                                    now: start, timeZone: zone)
        return FocusPolicy.start(plan, taskID: taskID, taskTitle: "准备季度汇报", at: start)
    }

    // MARK: - 基本读写

    func testEmptyStoreHasNoSession() {
        let (store, _) = makeStore()
        XCTAssertNil(store.load(), "没开始过计时就不该凭空读出一条会话")
    }

    func testRoundTripKeepsEveryField() throws {
        var session = try makeSession()
        session = FocusPolicy.pause(session, at: try moment(14, 10))
        session = FocusPolicy.resume(session, at: try moment(14, 15))

        let (store, _) = makeStore()
        store.save(session)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded, session)
        XCTAssertEqual(loaded.id, session.id)
        XCTAssertEqual(loaded.taskID, taskID)
        XCTAssertEqual(loaded.taskTitle, "准备季度汇报", "冷启动时计时条要能立刻渲染标题")
        XCTAssertEqual(loaded.basis, .startAndEnd)
        XCTAssertEqual(loaded.plannedSeconds, 1800)
        XCTAssertEqual(loaded.anchor?.epoch, session.anchor?.epoch)
        XCTAssertEqual(loaded.anchor?.tzID, session.anchor?.tzID, "锚点自带时区，钟点文本要按它换算")
        XCTAssertEqual(loaded.pauses, session.pauses, "暂停区间逐段保留，不做近似")
        XCTAssertFalse(loaded.isPaused)
    }

    /// 用一个新实例读同一份偏好，就是冷启动的实际路径。
    func testFreshInstanceSeesWhatWasSaved() throws {
        let (first, defaults) = makeStore()
        let session = try makeSession()
        first.save(session)

        let second = UserDefaultsFocusSessionStore(defaults: defaults)
        XCTAssertEqual(second.load(), session)
    }

    func testSavingNilClearsTheSession() throws {
        let (store, defaults) = makeStore()
        store.save(try makeSession())
        XCTAssertNotNil(store.load())

        store.save(nil)
        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: UserDefaultsFocusSessionStore.defaultKey),
                     "放弃/结束后不该留一条读不出来的空壳记录")
    }

    func testOnlyTheLatestSessionIsKept() throws {
        let (store, _) = makeStore()
        let first = try makeSession()
        store.save(first)

        let second = FocusPolicy.start(FocusPolicy.plan(startAt: nil, endAt: nil, estimateMinutes: 25,
                                                        now: try moment(15, 0), timeZone: zone),
                                       taskID: UUID(), taskTitle: "写周报", at: try moment(15, 0))
        store.save(second)

        XCTAssertEqual(store.load(), second, "同一时刻只保留一次计时")
    }

    // MARK: - 冷启动之后计时接着走

    func testPausedSessionStaysFrozenAcrossARelaunch() throws {
        let (store, defaults) = makeStore()
        var session = try makeSession()
        session = FocusPolicy.pause(session, at: try moment(14, 10))
        store.save(session)

        // 半小时后 App 被重新打开。
        let relaunched = try XCTUnwrap(UserDefaultsFocusSessionStore(defaults: defaults).load())
        let reopenedAt = try moment(14, 40)

        XCTAssertTrue(relaunched.isPaused, "暂停状态也要一起活下来")
        XCTAssertEqual(FocusPolicy.status(of: relaunched), .paused)
        XCTAssertEqual(FocusPolicy.elapsedSeconds(relaunched, at: reopenedAt), 600,
                       "暂停期间不计入投入，重新打开也一样")
        XCTAssertEqual(FocusPolicy.remainingSeconds(relaunched, at: reopenedAt), 1200,
                       "暂停期间倒计时不推进，重新打开也一样")
        XCTAssertEqual(FocusPolicy.currentPauseSeconds(relaunched, at: reopenedAt), 1800,
                       "暂停了 30 分钟，久置提示据此判断")
    }

    func testResumedSessionKeepsCountingAfterARelaunch() throws {
        let (store, defaults) = makeStore()
        var session = try makeSession()
        session = FocusPolicy.pause(session, at: try moment(14, 10))
        store.save(session)

        // 重新打开 → 继续 → 再保存。
        let relaunched = try XCTUnwrap(UserDefaultsFocusSessionStore(defaults: defaults).load())
        let resumed = FocusPolicy.resume(relaunched, at: try moment(14, 30))
        store.save(resumed)

        let third = try XCTUnwrap(UserDefaultsFocusSessionStore(defaults: defaults).load())
        let later = try moment(14, 40)
        XCTAssertEqual(FocusPolicy.elapsedSeconds(third, at: later), 1200,
                       "有效已用 = 40 分钟 − 暂停的 20 分钟")
        XCTAssertEqual(FocusPolicy.remainingSeconds(third, at: later), 600,
                       "继续时不把暂停的时长算回来")
        XCTAssertEqual(FocusPolicy.overrunSeconds(third, at: later), 0)
    }

    func testRestoredSessionCanBeFinishedWithTheSameRules() throws {
        let (store, defaults) = makeStore()
        store.save(try makeSession())

        let restored = try XCTUnwrap(UserDefaultsFocusSessionStore(defaults: defaults).load())
        // 到点后拖了 10 分钟才回来结束：默认截断到锚点。
        let late = try moment(14, 40)
        XCTAssertEqual(FocusPolicy.recordedMinutes(restored, at: late,
                                                   truncateAtAnchor: true, graceMinutes: 5), 30)
        XCTAssertEqual(FocusPolicy.diffTag(recordedMinutes: 30, plannedMinutes: restored.plannedMinutes),
                       "与计划一致")
    }

    // MARK: - 读不回来时的降级

    func testCorruptPayloadReadsAsNoSession() {
        let (store, defaults) = makeStore()
        for payload in [Data("not a session".utf8), Data("{\"v\":1}".utf8), Data()] {
            defaults.set(payload, forKey: UserDefaultsFocusSessionStore.defaultKey)
            XCTAssertNil(store.load(), "一条写坏的记录不该卡住启动")
        }
    }

    func testCorruptPayloadDoesNotBlockTheNextSession() throws {
        let (store, defaults) = makeStore()
        defaults.set(Data("not a session".utf8), forKey: UserDefaultsFocusSessionStore.defaultKey)

        let session = try makeSession()
        store.save(session)
        XCTAssertEqual(store.load(), session, "坏记录被覆盖后应恢复正常")
    }

    // MARK: - 精度

    /// 会话里的时刻带亚秒，写得进去也读得回来：
    /// 结束流程要用 `max(now, pauseStart)` 之类的比较，取整会带来最多一秒的漂移。
    func testSubSecondPrecisionSurvives() throws {
        let (store, _) = makeStore()
        let odd = Date(timeIntervalSince1970: 1_790_000_000.25)
        let session = FocusPolicy.Session(taskID: taskID, taskTitle: "写周报", basis: .startOnly,
                                          startedAt: odd)
        store.save(session)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.startedAt, odd)
    }

    // MARK: - 内存替身

    func testInMemoryStoreMirrorsTheContract() throws {
        let store = InMemoryFocusSessionStore()
        XCTAssertNil(store.load())

        let session = try makeSession()
        store.save(session)
        XCTAssertEqual(store.load(), session)

        store.save(nil)
        XCTAssertNil(store.load())
    }

    func testInMemoryStoreCanBeSeeded() throws {
        let session = try makeSession()
        XCTAssertEqual(InMemoryFocusSessionStore(session).load(), session,
                       "预览环境要能直接给一条进行中的会话")
    }
}
