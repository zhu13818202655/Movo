//
//  RecurrencePolicy.swift
//  Domain/Policies
//
//  4.4 materializeOccurrences / weeklyProgress。
//  惰性实例化在查询与今日构建时触发；暂停区间不补造（AC20）；
//  规则版本变更只影响 effectiveFrom 及以后（AC22）。
//

import Foundation

public enum RecurrencePolicy {

    /// 实例化窗口：`[max(effectiveFrom, lower), min(effectiveUntil ?? upper, upper)]`
    public static func window(rule: RecurrenceRule, range: DateOnlyRange) -> DateOnlyRange? {
        let lower = max(rule.effectiveFrom, range.lower)
        let upper = min(rule.effectiveUntil ?? range.upper, range.upper)
        guard lower <= upper else { return nil }
        return DateOnlyRange(lower: lower, upper: upper)
    }

    /// 计算某规则在范围内**应当存在**的实例（纯函数，不落库）。
    /// 返回 (rule, day) 序列；调用方负责幂等 upsert。
    public static func plan(rule: RecurrenceRule, range: DateOnlyRange, plan: Plan?) -> [DateOnly] {
        guard rule.isActive else { return [] }
        guard let w = window(rule: rule, range: range) else { return [] }
        var days: [DateOnly] = []
        var cursor = w.lower
        var guardCount = 0
        while cursor <= w.upper && guardCount < 4000 {
            guardCount += 1
            defer { cursor = cursor.adding(days: 1) }
            // weeklyCount 模式不固定日期，实例由用户完成/跳过时以 occurredOn 记录
            guard rule.pattern != .weeklyCount else { continue }
            guard rule.matches(cursor) else { continue }
            // 计划暂停区间 [pausedAt, resumedAt)：不实例化、不补造
            if let plan, plan.isPaused(on: cursor) { continue }
            days.append(cursor)
        }
        return days
    }

    /// 幂等 upsert 输入：唯一键 (ruleId, ruleVersion, scheduledOn)
    public static func makeOccurrence(rule: RecurrenceRule, day: DateOnly, planId: UUID?) -> RecurrenceOccurrence {
        RecurrenceOccurrence(
            ruleId: rule.id,
            ruleVersion: rule.version,
            taskId: rule.taskId,
            planId: planId,
            scheduledOn: day,
            occurredOn: nil,
            status: .pending)
    }

    /// 实例的起止：由实例日期加规则每天的时刻生成（固定日期模式才有）
    public static func timeRange(of occurrence: RecurrenceOccurrence,
                                 rule: RecurrenceRule) -> (start: TimePoint, end: TimePoint?)? {
        guard let day = occurrence.scheduledOn else { return nil }
        return (rule.occurrenceStart(on: day), rule.occurrenceEnd(on: day))
    }

    /// 对已有实例集合做合并，返回需要写库的实例（新增或版本迁移）
    public static func reconcile(existing: [RecurrenceOccurrence],
                                 wanted: [RecurrenceOccurrence]) -> [RecurrenceOccurrence] {
        var byKey = Dictionary(existing.map { ($0.uniqueKey, $0) }, uniquingKeysWith: { a, _ in a })
        var toWrite: [RecurrenceOccurrence] = []
        for candidate in wanted {
            if let found = byKey[candidate.uniqueKey] {
                // 已存在：保留状态与 occurredOn，不覆盖用户操作
                var keep = found
                keep.planId = candidate.planId
                if keep != found { toWrite.append(keep) }
            } else {
                byKey[candidate.uniqueKey] = candidate
                toWrite.append(candidate)
            }
        }
        return toWrite
    }

    // MARK: - 固定日期模式的本周期进度

    public struct FixedRangeProgress: Hashable, Sendable {
        public var done: Int
        public var planned: Int
        public var skipped: Int
        public var unrecorded: Int
    }

    /// 固定日期（daily / weekdays）在给定周内的统计。
    /// 未记录 = scheduledOn < 今天 且 status == pending（派生显示，不落库）。
    public static func fixedProgress(occurrences: [RecurrenceOccurrence],
                                     in week: DateOnlyRange,
                                     today: DateOnly) -> FixedRangeProgress {
        let inWeek = occurrences.filter { o in
            guard let d = o.scheduledOn else { return false }
            return week.contains(d)
        }
        let done = inWeek.filter { $0.status == .done }.count
        let skipped = inWeek.filter { $0.status == .skipped }.count
        let unrecorded = inWeek.filter { $0.status == .pending && (($0.scheduledOn ?? today) < today) }.count
        return FixedRangeProgress(done: done, planned: inWeek.count, skipped: skipped, unrecorded: unrecorded)
    }

    /// 每周 N 次：done 超过 weeklyCount 时保留额外记录（不丢数据）
    public static func weeklyProgress(rule: RecurrenceRule,
                                      occurrences: [RecurrenceOccurrence],
                                      week: DateOnlyRange,
                                      today: DateOnly) -> PeriodActions {
        let target = max(0, min(7, rule.weeklyCount ?? 0))
        let inWeek = occurrences.filter { o in
            guard let d = o.occurredOn ?? o.scheduledOn else { return false }
            return week.contains(d)
        }
        let done = inWeek.filter { $0.status == .done }.count
        let skipped = inWeek.filter { $0.status == .skipped }.count

        let weekFinished = today > week.upper
        let unrecorded = weekFinished ? max(0, target - done - skipped) : 0
        let extra = max(0, done - target)

        return PeriodActions(done: min(done, max(target, done)), planned: target,
                             skipped: skipped, unrecorded: unrecorded, extraDone: extra)
    }

    // MARK: - 规则变更

    /// ChangeRecurrence：新版本只实例化 effectiveFrom 之后的日期；已存在实例保留
    public static func nextVersion(of rule: RecurrenceRule,
                                   pattern: RecurrencePattern,
                                   weekdays: [Int]?,
                                   weeklyCount: Int?,
                                   effectiveFrom: DateOnly,
                                   today: DateOnly,
                                   updatesDailyTimes: Bool = false,
                                   dailyStart: TimeOfDay? = nil,
                                   dailyEnd: TimeOfDay? = nil) throws -> RecurrenceRule {
        // V7：effectiveFrom < 今天 → 置为今天（静默修正并记录）
        let from = max(effectiveFrom, today)
        var updated = rule
        updated.pattern = pattern
        updated.weekdays = weekdays
        updated.weeklyCount = weeklyCount
        updated.effectiveFrom = from
        if updatesDailyTimes {
            updated.dailyStart = dailyStart
            updated.dailyEnd = dailyEnd
        }
        updated.version = rule.version + 1
        updated.revision = rule.revision + 1
        updated.status = .active
        try StructurePolicy.validateRuleFields(updated)
        return updated
    }

    /// 频率变更影响预览（M09-FrequencyPreview）：列出将被影响的未来实例
    public static func impactPreview(rule: RecurrenceRule,
                                     existing: [RecurrenceOccurrence],
                                     newPattern: RecurrencePattern,
                                     newWeekdays: [Int]?,
                                     newWeeklyCount: Int?,
                                     effectiveFrom: DateOnly,
                                     today: DateOnly) -> ImpactPreview {
        var probe = rule
        probe.pattern = newPattern
        probe.weekdays = newWeekdays
        probe.weeklyCount = newWeeklyCount

        let horizon = DateOnlyRange(lower: effectiveFrom, upper: effectiveFrom.adding(days: 55))
        let future = plan(rule: probe, range: horizon, plan: nil)
        let existingFuture = existing.filter { o in
            guard let d = o.scheduledOn else { return false }
            return d >= effectiveFrom && o.status == .pending
        }

        let removedDays = Set(existingFuture.compactMap(\.scheduledOn)).subtracting(future)
        let addedDays = Set(future).subtracting(Set(existingFuture.compactMap(\.scheduledOn)))

        var lines: [ImpactPreview.ImpactLine] = []
        for d in addedDays.sorted() {
            lines.append(.init(entityId: deterministicID("add-\(d.iso8601DateString)"),
                               title: d.displayStringWithWeekday,
                               changeText: "新增一次安排",
                               oldValue: nil, newValue: probe.ruleDescription))
        }
        for d in removedDays.sorted() {
            lines.append(.init(entityId: deterministicID("remove-\(d.iso8601DateString)"),
                               title: d.displayStringWithWeekday,
                               changeText: "不再安排",
                               oldValue: rule.ruleDescription, newValue: probe.ruleDescription))
        }

        let note = """
        从 \(effectiveFrom.displayString) 起按新频率安排。\
        已记录和跳过的历史都会保留，不会补造过去的行动记录。
        """

        return ImpactPreview(
            title: "调整频率的影响",
            affected: lines.sorted { $0.title < $1.title },
            unaffected: ["已经完成的记录", "已经跳过的记录", "\(effectiveFrom.displayString) 之前的安排"],
            dependencyReleases: 0,
            undoNote: note,
            summaryText: "\(lines.count) 项未来安排会变化")
    }

    static func deterministicID(_ seed: String) -> UUID {
        var hash = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        // 稳定派生：仅用于预览行的 Identifiable，不落库
        var bytes = [UInt8](repeating: 0, count: 16)
        let s = Array(seed.utf8)
        for (i, b) in s.enumerated() { bytes[i % 16] = bytes[i % 16] &+ b &* UInt8((i % 7) + 1) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        hash = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return hash
    }
}
