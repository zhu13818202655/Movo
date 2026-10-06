//
//  FieldMergeTests.swift
//  MovoSyncTests
//
//  T3.3：9.4 事件式三方合并（纯函数层）。
//  重点验证 P3 完成条件：**冲突解决前不丢失任一版本**。
//

import XCTest
import MovoKit

final class FieldMergeTests: XCTestCase {

    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - 工具

    private func task(id: UUID = UUID(), title: String, notes: String? = nil,
                      rev: Int = 1, updatedAt: Date? = nil) -> Task {
        Task(id: id, title: title, notes: notes,
             createdAt: base, updatedAt: updatedAt ?? base, revision: rev)
    }

    private func record(_ task: Task, rev: Int, deviceId: String,
                        fieldRev: [String: Int] = [:], deletedAt: Date? = nil,
                        updatedAt: Date? = nil) -> EntityRecord {
        var t = task
        t.revision = rev
        if let updatedAt { t.updatedAt = updatedAt }
        let box = SyncEntityBox.task(t)
        guard let rec = box.record(rev: rev, deviceId: deviceId, deletedAt: deletedAt,
                                   fieldRev: fieldRev, planID: t.planId) else {
            fatalError("无法构造记录")
        }
        return rec
    }

    // MARK: - 删除判定

    func testRemoteDeletionWinsAndDiscardsLocalEdit() {
        let id = UUID()
        let remoteDeletedAt = base.addingTimeInterval(600)
        let local = record(task(id: id, title: "旧标题", rev: 2),
                           rev: 2, deviceId: "mac",
                           updatedAt: remoteDeletedAt.addingTimeInterval(600))
        let remote = record(task(id: id, title: "旧标题", rev: 2),
                            rev: 2, deviceId: "iphone", deletedAt: remoteDeletedAt)

        let outcome = FieldMerge.merge(local: local, remote: remote, base: nil)

        XCTAssertEqual(outcome.deletion, .remoteWins)
        XCTAssertTrue(outcome.isDeleted)
        // AC11：本地在删除之后的编辑被丢弃，但必须被标记出来（用于提示用户）
        XCTAssertTrue(outcome.discardedLocalEdit)
    }

    func testBothSidesDeletedStaysDeleted() {
        let id = UUID()
        let local = record(task(id: id, title: "T", rev: 2), rev: 2, deviceId: "mac",
                           deletedAt: base.addingTimeInterval(10))
        let remote = record(task(id: id, title: "T", rev: 3), rev: 3, deviceId: "iphone",
                            deletedAt: base.addingTimeInterval(20))

        let outcome = FieldMerge.merge(local: local, remote: remote, base: nil)
        XCTAssertEqual(outcome.deletion, .both)
        XCTAssertTrue(outcome.isDeleted)
    }

    // MARK: - 逐字段合并

    func testDifferentFieldsMergeWithoutConflict() {
        let id = UUID()
        // 本机改了 notes（fieldRev=2）；对端改了 title（fieldRev=2）
        let local = record(task(id: id, title: "原题", notes: "本机备注", rev: 2),
                           rev: 2, deviceId: "mac", fieldRev: ["notes": 2])
        let remote = record(task(id: id, title: "远端标题", notes: "原备注", rev: 2),
                            rev: 2, deviceId: "iphone", fieldRev: ["title": 2])

        let outcome = FieldMerge.merge(local: local, remote: remote, base: nil)

        XCTAssertFalse(outcome.hasConflicts, "不同字段并行修改应自动合并（PRD REQ 20）")
        XCTAssertEqual(outcome.mergedFields["title"], .string("远端标题"))
        XCTAssertEqual(outcome.mergedFields["notes"], .string("本机备注"))
        XCTAssertTrue(outcome.changedLocally)
    }

    func testSameFieldBothChangedKeepsBothCandidates() throws {
        let id = UUID()
        let local = record(task(id: id, title: "本机标题", rev: 2),
                           rev: 2, deviceId: "mac", fieldRev: ["title": 2])
        let remote = record(task(id: id, title: "远端标题", rev: 2),
                            rev: 2, deviceId: "iphone", fieldRev: ["title": 2])

        let outcome = FieldMerge.merge(local: local, remote: remote, base: nil)

        XCTAssertTrue(outcome.hasConflicts)
        let conflict = try XCTUnwrap(outcome.conflicts.first)
        XCTAssertEqual(conflict.field, "title")
        // P3 完成条件：两个候选都保留
        XCTAssertEqual(conflict.localValue, .string("本机标题"))
        XCTAssertEqual(conflict.remoteValue, .string("远端标题"))
        XCTAssertTrue(conflict.bothPresent)
        XCTAssertEqual(conflict.localDeviceId, "mac")
        XCTAssertEqual(conflict.remoteDeviceId, "iphone")
    }

    func testSameFieldSameValueIsNotConflict() {
        let id = UUID()
        let local = record(task(id: id, title: "同一标题", rev: 2),
                           rev: 2, deviceId: "mac", fieldRev: ["title": 2])
        let remote = record(task(id: id, title: "同一标题", rev: 2),
                            rev: 2, deviceId: "iphone", fieldRev: ["title": 2])

        let outcome = FieldMerge.merge(local: local, remote: remote, base: nil)
        XCTAssertFalse(outcome.hasConflicts, "值相同不构成冲突（9.4）")
    }

    // MARK: - 幂等（9.4 第 4 步）

    func testRepeatedMergeIsIdempotent() {
        let id = UUID()
        let local = record(task(id: id, title: "本机标题", rev: 2),
                           rev: 2, deviceId: "mac", fieldRev: ["title": 2])
        let remote = record(task(id: id, title: "远端标题", rev: 2),
                            rev: 2, deviceId: "iphone", fieldRev: ["title": 2])

        let first = FieldMerge.merge(local: local, remote: remote, base: nil)
        let second = FieldMerge.merge(local: local, remote: remote, base: nil)

        XCTAssertEqual(first.mergedFields, second.mergedFields)
        XCTAssertEqual(first.conflicts, second.conflicts)
        XCTAssertEqual(first.resultingRev, second.resultingRev)
    }

    // MARK: - 决议落地

    func testResolvedValueFollowsChoice() {
        let conflict = SyncConflict(
            entityType: .task, entityId: UUID(), field: "title",
            localValue: .string("本机"), localRev: 2, localDeviceId: "mac", localChangedAt: base,
            remoteValue: .string("远端"), remoteRev: 2, remoteDeviceId: "iphone",
            remoteChangedAt: base, baseRev: 1, resolution: .remote)

        XCTAssertEqual(FieldMerge.resolvedValue(for: conflict), .string("远端"))
        XCTAssertTrue(FieldMerge.needsApplication(.string("远端"), field: "title",
                                                  in: ["title": .string("本机")]))
        XCTAssertFalse(FieldMerge.needsApplication(.string("本机"), field: "title",
                                                   in: ["title": .string("本机")]))
    }

    func testVolumeFieldsRoundTripThroughBox() {
        let id = UUID()
        let t = task(id: id, title: "标题", notes: "备注", rev: 3)
        let fields = FieldMerge.volumeFields(of: .task(t))

        XCTAssertEqual(fields["title"], .string("标题"))
        XCTAssertEqual(fields["notes"], .string("备注"))

        // 用合并结果重建实体（9.4 第 2 步之后的回写路径）
        var merged = fields
        merged["title"] = .string("新标题")
        let rebuilt = SyncEntityBox.task(t).applying(mergedFields: merged, revision: 4,
                                                     updatedAt: base.addingTimeInterval(60))
        guard case .task(let restored)? = rebuilt else { return XCTFail("重建失败") }
        XCTAssertEqual(restored.title, "新标题")
        XCTAssertEqual(restored.revision, 4)
    }

    // MARK: - 复活防护（AC11）

    func testRevivalGuardDecision() {
        let deleted = base.addingTimeInterval(100)

        XCTAssertEqual(RevivalGuard.decide(localDeletedAt: nil, remoteDeletedAt: nil,
                                           localUpdatedAt: base), .noDeletion)
        XCTAssertEqual(RevivalGuard.decide(localDeletedAt: deleted, remoteDeletedAt: nil,
                                           localUpdatedAt: base), .alreadyDeleted)
        // 本地在删除之后仍然改过 → 删除胜出且编辑被丢弃
        XCTAssertEqual(RevivalGuard.decide(localDeletedAt: nil, remoteDeletedAt: deleted,
                                           localUpdatedAt: deleted.addingTimeInterval(50)),
                       .deletionWinsDiscardingLocalEdits)
        // 本地没有更晚的编辑 → 单纯删除生效
        XCTAssertEqual(RevivalGuard.decide(localDeletedAt: nil, remoteDeletedAt: deleted,
                                           localUpdatedAt: deleted.addingTimeInterval(-50)),
                       .deletionWins)
    }

    // MARK: - 字段中文名与旧格式解码（time.md）

    func testFieldDisplayNames() {
        XCTAssertEqual(SyncFieldNaming.displayName(for: "title"), "标题")
        XCTAssertEqual(SyncFieldNaming.displayName(for: "scheduledDate"), "安排日期")
        XCTAssertEqual(SyncFieldNaming.displayName(for: "startAt"), "开始时间")
        XCTAssertEqual(SyncFieldNaming.displayName(for: "endAt"), "结束时间")
        XCTAssertEqual(SyncFieldNaming.text(for: .null), "（空）")
        XCTAssertEqual(SyncFieldNaming.text(for: .bool(true)), "是")
        XCTAssertEqual(SyncFieldNaming.text(for: .int(3)), "3")
    }

    func testLegacyTaskDecodesThroughSyncEntityBox() throws {
        let taskID = UUID()
        let legacyJSON = """
        {
          "id": "\(taskID.uuidString)",
          "title": "旧版任务",
          "isTemplate": false,
          "status": "todo",
          "scheduledDate": {"y": 2026, "m": 10, "d": 8, "sourceTZ": "Asia/Shanghai"},
          "timeHint": {"type": "exact", "hour": 14, "minute": 30},
          "hardDeadline": {"epoch": 1800000000, "tzID": "Asia/Shanghai"},
          "tags": [],
          "dependencyIDs": [],
          "source": "manual",
          "suggestedFields": [],
          "createdAt": "2026-09-28T10:00:00Z",
          "updatedAt": "2026-09-28T10:00:00Z",
          "revision": 1
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let box = try XCTUnwrap(SyncEntityBox.decode(type: .task, data: data))
        guard case .task(let task) = box else {
            return XCTFail("未能解出 Task")
        }
        XCTAssertEqual(task.title, "旧版任务")
        XCTAssertEqual(task.startAt?.clockText, "14:30")
        XCTAssertEqual(task.startAt?.dateOnly.iso8601DateString, "2026-10-08")
        XCTAssertEqual(task.endAt?.instantValue?.epoch, Date(timeIntervalSince1970: 1800000000))
    }

    func testLegacyPlanDecodesTargetDateThroughSyncEntityBox() throws {
        let planID = UUID()
        let legacyJSON = """
        {
          "id": "\(planID.uuidString)",
          "name": "旧版计划",
          "kind": "delivery",
          "status": "active",
          "targetDate": {"y": 2026, "m": 10, "d": 31, "sourceTZ": "Asia/Shanghai"},
          "aliases": [],
          "contextPhrases": [],
          "excludedTerms": [],
          "cloudAIEnabled": true,
          "syncEnabled": true,
          "createdAt": "2026-09-28T10:00:00Z",
          "updatedAt": "2026-09-28T10:00:00Z",
          "revision": 1
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let box = try XCTUnwrap(SyncEntityBox.decode(type: .plan, data: data))
        guard case .plan(let plan) = box else {
            return XCTFail("未能解出 Plan")
        }
        XCTAssertEqual(plan.name, "旧版计划")
        XCTAssertNil(plan.startAt)
        XCTAssertEqual(plan.endAt?.dateOnly.iso8601DateString, "2026-10-31")
    }

    func testSyncMergeWithStartAtAndEndAtFields() {
        let id = UUID()
        let initialTask = task(id: id, title: "起止时间待办", rev: 1)
        let localStart = TimePoint.day(DateOnly(y: 2026, m: 10, d: 5, sourceTZ: tz.identifier))
        let remoteEnd = TimePoint.day(DateOnly(y: 2026, m: 10, d: 20, sourceTZ: tz.identifier))

        var localTask = initialTask
        localTask.startAt = localStart
        localTask.revision = 2

        var remoteTask = initialTask
        remoteTask.endAt = remoteEnd
        remoteTask.revision = 2

        let localRecord = record(localTask, rev: 2, deviceId: "mac", fieldRev: ["startAt": 2])
        let remoteRecord = record(remoteTask, rev: 2, deviceId: "iphone", fieldRev: ["endAt": 2])

        let outcome = FieldMerge.merge(local: localRecord, remote: remoteRecord, base: nil)
        XCTAssertFalse(outcome.isDeleted)
        XCTAssertTrue(outcome.conflicts.isEmpty, "不同字段不应产生冲突")

        // 重建实体检验同时保留两端字段
        let rebuilt = SyncEntityBox.task(initialTask).applying(mergedFields: outcome.mergedFields,
                                                               revision: 3,
                                                               updatedAt: base.addingTimeInterval(300))
        guard case .task(let finalTask)? = rebuilt else { return XCTFail("重建失败") }
        XCTAssertEqual(finalTask.startAt, localStart)
        XCTAssertEqual(finalTask.endAt, remoteEnd)
    }
}
