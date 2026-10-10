//
//  NotificationCenterService.swift
//  Notifications
//
//  T0.12 / 10.9：把领域数据算成通知排期并写入系统通知中心。
//  · 排期是纯计算（NotificationPlanner），本类只负责取数与写系统。
//  · 确定性标识：同一对象同一次提醒重复写入会覆盖，不会叠加打扰。
//  · 数据变更后重算一次（幂等），任一端完成/跳过在下次同步后取消对端待发（10.9）。
//  · 专注会话由调用方传入：计时状态不落领域库，取数层看不到它（见 refresh(focus:)）。
//

import Foundation

/// 通知服务：领域仓库 → 排期 → 系统通知中心。
/// actor 隔离：跨边界只传 Sendable 值类型（1.3）。
public actor NotificationCenterService {

    private let repository: any DomainRepository
    private let scheduler: any NotificationScheduling
    private let defaults: AppDefaults

    public init(repository: any DomainRepository,
                scheduler: any NotificationScheduling,
                defaults: AppDefaults) {
        self.repository = repository
        self.scheduler = scheduler
        self.defaults = defaults
    }

    // MARK: - 权限

    public func authorizationStatus() async -> PermissionState {
        await scheduler.authorizationStatus()
    }

    public func requestAuthorization() async -> Bool {
        await scheduler.requestAuthorization()
    }

    // MARK: - 排期

    /// 只计算不写入（预览用，10.9「接下来的提醒」）。
    /// `focus` 传当前进行中的专注会话，让它与安排一起排；不传则只排安排。
    public func plan(now: Date, timeZone: TimeZone, today: DateOnly,
                     horizonDays: Int = 14,
                     focus: FocusPolicy.Session? = nil) async -> [PlannedNotification] {
        let tasks = await repository.allTasks()
        let plans = await repository.allPlans()
        let rules = await repository.rules()
        var occurrences: [RecurrenceOccurrence] = []
        for rule in rules {
            occurrences += await repository.occurrences(ruleID: rule.id)
        }
        return NotificationPlanner.plan(tasks: tasks, plans: plans, rules: rules,
                                        occurrences: occurrences, defaults: defaults,
                                        now: now, timeZone: timeZone, today: today,
                                        horizonDays: horizonDays, focus: focus)
    }

    /// 计算并**替换**全部待发通知（幂等覆盖）。返回本次写入的排期。
    ///
    /// 「替换」在这里是暂停联动能成立的原因：暂停后重算出来的排期里不含到点提醒，
    /// 于是它被一并撤销；继续后按新的有效终点重新算，又回到排期里。
    /// `hideDetails == nil` 时用默认配置（10.9 锁屏默认隐藏详情）。
    @discardableResult
    public func refresh(now: Date, timeZone: TimeZone, today: DateOnly,
                        hideDetails: Bool? = nil, horizonDays: Int = 14,
                        focus: FocusPolicy.Session? = nil) async -> [PlannedNotification] {
        let planned = await plan(now: now, timeZone: timeZone, today: today,
                                 horizonDays: horizonDays, focus: focus)
        let hide = hideDetails ?? defaults.notifications.lockScreenHideDetails
        await scheduler.replaceAll(with: planned, hideDetails: hide)
        return planned
    }

    public func cancelAll() async {
        await scheduler.cancelAll()
    }

    public func pendingCount() async -> Int {
        await scheduler.pendingIdentifiers().count
    }
}
