//
//  NotificationScheduler.swift
//  Notifications
//
//  T0.12 通知投递：UNUserNotificationCenter 封装。
//  · 标识确定性：同一对象的同一次提醒重复排期会覆盖而不是叠加。
//  · 权限未授予时返回 .denied，UI 必须给出恢复入口（打开设置 / 继续用文字）。
//  · 锁屏默认隐藏详情（lockScreenHideDetails）。
//

import Foundation
@preconcurrency import UserNotifications

// MARK: - 深链

/// 通知点击后的目标（App 层映射为具体 Route）
public enum NotificationDeepLink: Hashable, Sendable {
    case today
    case inbox
    case review
    case settings
    case plan(UUID)
    case task(UUID)
    /// 专注到点：落到计时页而不是任务详情。带着正在跑的会话打开，用户回来就能点结束。
    case focus(UUID)

    /// `movo://plan/<uuid>/task/<uuid>` / `movo://task/<uuid>` / `movo://focus/<uuid>` / `movo://today` …
    public static func parse(_ string: String) -> NotificationDeepLink? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("movo://") else { return nil }
        let path = String(trimmed.dropFirst("movo://".count))
        let parts = path.split(separator: "/").map(String.init)
        guard let head = parts.first else { return nil }
        switch head {
        case "today": return .today
        case "inbox": return .inbox
        case "review": return .review
        case "settings": return .settings
        case "plan":
            if let id = parts.dropFirst().first, let uuid = UUID(uuidString: id) { return .plan(uuid) }
            return nil
        case "task":
            if let id = parts.dropFirst().first, let uuid = UUID(uuidString: id) { return .task(uuid) }
            return nil
        case "focus":
            if let id = parts.dropFirst().first, let uuid = UUID(uuidString: id) { return .focus(uuid) }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - 协议

public protocol NotificationScheduling: Sendable {
    func authorizationStatus() async -> PermissionState
    func requestAuthorization() async -> Bool
    /// 用给定集合**替换**全部待发通知（确定性标识，不做增量叠加）
    func replaceAll(with items: [PlannedNotification], hideDetails: Bool) async
    func cancelAll() async
    func pendingIdentifiers() async -> [String]
}

// MARK: - 本地实现

public actor LocalNotificationScheduler: NotificationScheduling {

    private let center: UNUserNotificationCenter

    public init() {
        self.center = UNUserNotificationCenter.current()
    }

    /// 测试/预览注入用
    public init(center: UNUserNotificationCenter) {
        self.center = center
    }

    public func authorizationStatus() async -> PermissionState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .undetermined
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        @unknown default: return .undetermined
        }
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    public func replaceAll(with items: [PlannedNotification], hideDetails: Bool) async {
        let identifiers = await pendingIdentifiers()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)

        for item in items where item.fireDate > Date() {
            let content = UNMutableNotificationContent()
            content.title = hideDetails ? item.safeTitle : item.title
            content.body = hideDetails ? item.safeBody : item.body
            content.userInfo = ["deepLink": item.deepLink, "kind": item.kind.rawValue]
            content.sound = .default

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: item.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: item.id, content: content,
                                               trigger: trigger)
            try? await center.add(request)
        }
    }

    public func cancelAll() async {
        center.removeAllPendingNotificationRequests()
    }

    public func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
}

// MARK: - 测试替身

/// 内存实现：单测里断言"排了哪些、取消了什么"，不触碰系统通知中心。
public actor InMemoryNotificationScheduler: NotificationScheduling {
    private var items: [PlannedNotification] = []
    private var requested = false
    private var status: PermissionState

    public init(status: PermissionState = .granted) { self.status = status }

    public func setStatus(_ new: PermissionState) { status = new }

    public func authorizationStatus() async -> PermissionState { status }

    public func requestAuthorization() async -> Bool {
        requested = true
        if status == .undetermined { status = .granted }
        return status == .granted
    }

    public func replaceAll(with items: [PlannedNotification], hideDetails: Bool) async {
        _ = hideDetails
        self.items = items
    }

    public func cancelAll() async { items = [] }

    public func pendingIdentifiers() async -> [String] { items.map(\.id) }

    public func scheduled() async -> [PlannedNotification] { items }

    public func didRequestAuthorization() async -> Bool { requested }
}
