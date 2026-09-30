//
//  NotificationPlanner.swift
//  Notifications
//
//  10.9 本地通知排期（纯计算，可单测）。
//  · 五类：具体时刻任务、仅日期任务、硬截止、周期回顾、受阻复查。
//  · 聚合窗口内的多条合并为一条；落在安静时段内的顺延到安静时段结束。
//  · 通知标识确定性（同一对象重复排期覆盖同一条，不会重复打扰）。
//  · 锁屏默认不显示正文（lockScreenHideDetails）。
//

import Foundation

// MARK: - 计划项

public struct PlannedNotification: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case timedTask
        case dateOnlyTask
        case hardDeadline
        case weeklyReview
        case blockedReview

        public var displayName: String {
            switch self {
            case .timedTask: "按时的任务"
            case .dateOnlyTask: "当天任务"
            case .hardDeadline: "硬截止提醒"
            case .weeklyReview: "周期回顾"
            case .blockedReview: "受阻复查"
            }
        }
    }

    /// 确定性标识：同一对象 + 同一类型 + 同一时间点 → 同一条
    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
    public var fireDate: Date
    public var entityID: UUID?
    public var deepLink: String
    /// 聚合进来的其它提醒（合并后主体仍是一条）
    public var mergedCount: Int

    public init(id: String, kind: Kind, title: String, body: String, fireDate: Date,
                entityID: UUID? = nil, deepLink: String, mergedCount: Int = 0) {
        self.id = id; self.kind = kind; self.title = title; self.body = body
        self.fireDate = fireDate; self.entityID = entityID; self.deepLink = deepLink
        self.mergedCount = mergedCount
    }

    /// 锁屏隐藏详情时的安全文案
    public var safeTitle: String { mergedCount > 0 ? "有 \(mergedCount + 1) 项待推进" : title }
    public var safeBody: String { mergedCount > 0 ? "打开渐成查看今天要做什么。" : body }
}

// MARK: - 排期

public enum NotificationPlanner {

    /// 生成未来窗口内的通知。窗口默认 14 天，覆盖跨周安排。
    public static func plan(tasks: [Task],
                            plans: [Plan],
                            rules: [RecurrenceRule],
                            occurrences: [RecurrenceOccurrence],
                            defaults: AppDefaults,
                            now: Date,
                            timeZone: TimeZone,
                            today: DateOnly,
                            horizonDays: Int = 14) -> [PlannedNotification] {
        let config = defaults.notifications
        let horizon = today.adding(days: max(1, horizonDays))
        let planIndex = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [PlannedNotification] = []

        for task in tasks {
            guard task.status.isOpen else { continue }
            if let planID = task.planId, planIndex[planID]?.status == .archived { continue }

            // 1. 硬截止：提前 N 天 + 截止当天各一次
            if let deadline = task.hardDeadline {
                let deadlineDay = deadline.dateOnly
                if deadlineDay <= horizon, deadline.epoch > now {
                    let leadDay = deadlineDay.adding(days: -config.hardDeadlineLeadDays)
                    if let lead = date(at: config.hardDeadlineSameDayHour,
                                       minute: config.hardDeadlineSameDayMinute,
                                       on: leadDay, in: timeZone), lead > now {
                        out.append(planned(.hardDeadline, task: task, title: "还有 \(config.hardDeadlineLeadDays) 天到硬截止",
                                           body: task.title, fireDate: lead,
                                           identifier: "movo.deadline.\(task.id.uuidString).lead"))
                    }
                    if let sameDay = date(at: config.hardDeadlineSameDayHour,
                                          minute: config.hardDeadlineSameDayMinute,
                                          on: deadlineDay, in: timeZone), sameDay > now {
                        out.append(planned(.hardDeadline, task: task, title: "今天是最晚完成时间",
                                           body: task.title, fireDate: sameDay,
                                           identifier: "movo.deadline.\(task.id.uuidString).today"))
                    }
                }
            }
            // 2/3. 安排日期：具体时刻走"准时提醒"，仅日期走"当天默认时刻"
            if let scheduled = task.scheduledDate, scheduled <= horizon, !task.isTemplate {
                var handled = false
                if let hint = task.timeHint, case .exact(let hour, let minute) = hint,
                   let fire = date(at: hour, minute: minute, on: scheduled, in: timeZone) {
                    let shifted = fire.addingTimeInterval(-Double(config.timedTaskLeadMinutes) * 60)
                    if shifted > now {
                        out.append(planned(.timedTask, task: task, title: "快到时间了",
                                           body: "\(task.title) · \(scheduled.displayString)",
                                           fireDate: shifted,
                                           identifier: "movo.task.\(task.id.uuidString).timed"))
                    }
                    handled = true
                }
                if !handled,
                   let fire = date(at: config.dateOnlyTaskHour, minute: config.dateOnlyTaskMinute,
                                   on: scheduled, in: timeZone), fire > now {
                    out.append(planned(.dateOnlyTask, task: task,
                                       title: scheduled == today ? "今天安排" : scheduled.displayStringWithWeekday,
                                       body: task.title, fireDate: fire,
                                       identifier: "movo.task.\(task.id.uuidString).day"))
                }
            }

            // 5. 受阻复查
            if task.status == .blocked, config.blockedReminderEnabled {
                let threshold = task.updatedAt
                    .addingTimeInterval(Double(config.blockedRescheduleThreshold) * 86_400)
                if threshold > now, threshold < horizon.noon {
                    out.append(planned(.blockedReview, task: task,
                                       title: "这一项卡了 \(config.blockedRescheduleThreshold) 天",
                                       body: "要不要改期或先做别的？\(task.title)",
                                       fireDate: threshold,
                                       identifier: "movo.blocked.\(task.id.uuidString)"))
                }
            }
        }

        // 4. 周期回顾
        if let fire = nextWeeklyReview(config: config, now: now, timeZone: timeZone) {
            out.append(PlannedNotification(
                id: "movo.review.\(DateOnly(from: fire, in: timeZone).iso8601DateString)",
                kind: .weeklyReview,
                title: "看看这一周",
                body: "回顾这一周发生的行动与记录，不需要写总结。",
                fireDate: fire, entityID: nil, deepLink: "movo://review"))
        }

        // 安静时段顺延 + 聚合窗口合并 + 排序
        let shifted = out.map { applyQuietHours($0, config: config, timeZone: timeZone) }
        return aggregate(shifted, windowMinutes: config.aggregationWindowMinutes)
            .sorted { $0.fireDate < $1.fireDate }
    }

    // MARK: - 内部

    static func planned(_ kind: PlannedNotification.Kind, task: Task,
                        title: String, body: String, fireDate: Date,
                        identifier: String) -> PlannedNotification {
        PlannedNotification(
            id: identifier, kind: kind, title: title, body: body, fireDate: fireDate,
            entityID: task.id,
            deepLink: task.planId.map { "movo://plan/\($0.uuidString)/task/\(task.id.uuidString)" }
                ?? "movo://task/\(task.id.uuidString)")
    }

    static func date(at hour: Int, minute: Int, on day: DateOnly, in timeZone: TimeZone) -> Date? {
        var comps = DateComponents()
        comps.year = day.y; comps.month = day.m; comps.day = day.d
        comps.hour = hour; comps.minute = minute; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: comps)
    }

    static func nextWeeklyReview(config: AppDefaults.Notifications, now: Date,
                                 timeZone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2
        guard let next = cal.nextDate(after: now,
                                      matching: DateComponents(hour: config.weeklyReviewHour,
                                                               minute: config.weeklyReviewMinute),
                                      matchingPolicy: .nextTime) else { return nil }
        // 只在设定的星期触发：向后找最近一个 ISO weekday 匹配的日期
        let target = config.weeklyReviewWeekday // 1=周一 … 7=周日（ISO）
        for offset in 0..<8 {
            let candidate = cal.date(byAdding: .day, value: offset, to: next) ?? next
            let weekdayComponent = cal.component(.weekday, from: candidate) // 1=周日
            let iso = weekdayComponent == 1 ? 7 : weekdayComponent - 1
            if iso == target, candidate > now { return candidate }
        }
        return next
    }

    /// 落在安静时段内的通知顺延到安静时段结束
    static func applyQuietHours(_ item: PlannedNotification,
                                config: AppDefaults.Notifications,
                                timeZone: TimeZone) -> PlannedNotification {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hour = cal.component(.hour, from: item.fireDate)
        let start = config.quietHoursStart
        let end = config.quietHoursEnd
        guard start != end else { return item }

        let inQuiet: Bool = start < end
            ? (hour >= start && hour < end)
            : (hour >= start || hour < end)
        guard inQuiet else { return item }

        // 顺延到今天或明天的 quietHoursEnd
        var target = cal.startOfDay(for: item.fireDate)
        if start > end, hour >= start {
            target = cal.date(byAdding: .day, value: 1, to: target) ?? target
        }
        guard let shifted = cal.date(bySettingHour: end, minute: 0, second: 0, of: target) else {
            return item
        }
        var updated = item
        updated.fireDate = shifted
        return updated
    }

    /// 聚合窗口：同一窗口内同类型且同一计划的通知合并为一条
    static func aggregate(_ items: [PlannedNotification], windowMinutes: Int) -> [PlannedNotification] {
        guard windowMinutes > 0 else { return items }
        let sorted = items.sorted { $0.fireDate < $1.fireDate }
        var result: [PlannedNotification] = []
        var bucket: [PlannedNotification] = []

        func flush() {
            guard let first = bucket.first else { return }
            if bucket.count == 1 {
                result.append(first)
            } else {
                var merged = first
                merged.mergedCount = bucket.count - 1
                merged.title = "有 \(bucket.count) 项要看一下"
                merged.body = bucket.prefix(3).map(\.body).joined(separator: "；")
                result.append(merged)
            }
            bucket.removeAll()
        }

        for item in sorted {
            if let last = bucket.last {
                let gap = item.fireDate.timeIntervalSince(last.fireDate) / 60
                if gap <= Double(windowMinutes), item.kind == last.kind {
                    bucket.append(item)
                    continue
                }
            }
            flush()
            bucket.append(item)
        }
        flush()
        return result
    }
}
