//
//  SyncAttentionTests.swift
//  MovoDomainTests
//
//  设置入口角标的回归：顶部齿轮只在需要用户知道的时候带角标。
//
//  为什么单列一组：设置入口是 iOS 上进入「同步 / AI 与数据」的唯一入口
//  （原先的顶部同步角标已并入设置页）。合并之后最容易出的问题，
//  是把同步异常一起「合并」掉——用户看不到任何提示，也不知道要去哪里处理。
//  这一组测试锁住两件事：
//    1. 正常状态必须安静（未登录 / 就绪 / 已同步 → 无角标）；
//    2. 异常状态必须出现，尤其是冲突（PRD 要求冲突必须被发现，不能静默留待）。
//

import Foundation
import XCTest
import MovoKit

final class SyncAttentionTests: XCTestCase {

    // MARK: - 全状态映射

    /// 六种 SyncState 逐一对照，避免以后新增状态时漏配（漏配 = 顶部安静地吞掉异常）
    func testEverySyncStateMapsToExpectedAttention() {
        let expected: [(String, SyncState, SyncAttention?)] = [
            ("未登录 iCloud", .notSignedIn, nil),
            ("就绪", .idle, nil),
            ("已同步", .upToDate(lastSyncedAt: Date()), nil),
            ("已同步（无时间）", .upToDate(lastSyncedAt: nil), nil),
            ("同步中", .syncing(pendingCount: 0), .activity),
            ("同步中（有待传）", .syncing(pendingCount: 3), .activity),
            ("同步失败", .failed(reason: "网络不可用", retryAt: nil), .issue),
            ("待确认冲突", .conflictPending(count: 2), .issue)
        ]

        for (name, state, attention) in expected {
            XCTAssertEqual(SyncAttention(state), attention, "\(name) 的角标级别不对")
        }
    }

    // MARK: - 正常状态保持安静

    /// 这是本次改动的前提：顶部不再重复表达设置页里已有的正常状态。
    /// 若这里失败，说明齿轮会长期顶着角标，等于没有简化。
    func testNormalStatesStayQuiet() {
        let quiet: [SyncState] = [.notSignedIn, .idle,
                                  .upToDate(lastSyncedAt: Date()),
                                  .upToDate(lastSyncedAt: nil)]
        for state in quiet {
            XCTAssertNil(SyncAttention(state), "\(state.displayText) 不该带角标")
        }
    }

    /// 「未登录 iCloud」不是异常：本应用本机优先，默认不开 iCloud。
    /// 单独钉住这条，防止以后有人把它当成需要提醒的问题。
    func testNotSignedInIsNotAnIssue() {
        XCTAssertNil(SyncAttention(.notSignedIn))
    }

    // MARK: - 异常不许被吞掉

    /// 不变量：只要有冲突，就必须出现角标。冲突由用户决定保留哪一份，
    /// 不能因为「入口合并进设置页」就失去提示。
    func testConflictAlwaysRaisesAttention() {
        for count in [1, 2, 9] {
            let state = SyncState.conflictPending(count: count)
            XCTAssertTrue(state.hasConflict)
            XCTAssertEqual(SyncAttention(state), .issue, "\(count) 处冲突必须提示")
        }
    }

    /// 同步进行中与同步失败必须区分：前者是正常过程，后者要用户处理。
    /// 两者都用角标，但语义不同（activity 不是问题），所以不能合并成一个 case。
    func testActivityAndIssueAreDistinct() {
        XCTAssertNotEqual(SyncAttention(.syncing(pendingCount: 1)), SyncAttention(.failed(reason: "x", retryAt: nil)))
        XCTAssertEqual(SyncAttention.allCases.count, 2)
    }

    /// 角标级别与详细文案互不冲突：rawValue 用于稳定标识（日志 / 快照），
    /// 不随文案调整而变化。
    func testAttentionRawValuesAreStable() {
        XCTAssertEqual(SyncAttention.activity.rawValue, "activity")
        XCTAssertEqual(SyncAttention.issue.rawValue, "issue")
    }
}
