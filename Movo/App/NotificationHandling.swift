//
//  NotificationHandling.swift
//  App
//
//  T0.12 / 10.9：通知点按 → 应用内深链。
//  · 前台也把已排期的提醒展示出来（否则用户看不到）。
//  · 点击后按 deepLink 字段还原到目标页（`movo://task/<id>` 等）。
//  · 深链解析在 MovoKit（NotificationDeepLink），这里只做路由映射。
//

import Foundation
import SwiftUI
@preconcurrency import UserNotifications
import MovoKit

// MARK: - 待处理深链

@MainActor
@Observable
public final class NotificationRouter {
    /// 待消费的目标（RootView 观察后跳转并清空）
    public var pending: NotificationDeepLink?

    public init() {}

    public func receive(_ link: NotificationDeepLink) { pending = link }
    public func clear() { pending = nil }
}

// MARK: - 深链 → 路由

public enum MovoDeepLink {

    /// 10.9 点按深链到对象：先切入口再压栈，保证返回路径一致（D07 深链一致性）。
    @MainActor
    public static func apply(_ link: NotificationDeepLink, router: Router) {
        switch link {
        case .today:
            router.select(.today)
        case .inbox:
            router.select(.inbox)
        case .review:
            router.select(.review)
        case .settings:
            router.present(.settings)
        case .plan(let id):
            router.go(to: .planDetail(id), in: .plans)
        case .task(let id):
            // 通知都是"今天要做什么"，因此回到今日入口再进详情
            router.go(to: .taskDetail(id), in: .today)
        case .focus(let id):
            // 到点提醒落在计时页而不是任务详情：用户回来是要结束这次计时，
            // 落在详情页还得再点一次「继续专注」才能看到计时。
            router.go(to: .focus(id), in: .today)
        }
    }

    /// 外部 URL（`movo://`）→ 目标。URL scheme 未注册时为 nil，不产生副作用。
    @MainActor
    public static func apply(url: URL, router: Router) {
        guard let link = NotificationDeepLink.parse(url.absoluteString) else { return }
        apply(link, router: router)
    }
}

// MARK: - 通知代理

public extension AppEnvironment {

    /// 安装通知代理（幂等）。点击通知 → 应用内深链。
    @MainActor
    func installNotificationHandling() {
        guard notificationDelegate == nil else { return }
        let router = notificationRouter
        let delegate = MovoNotificationDelegate { link in
            _Concurrency.Task { @MainActor in router.receive(link) }
        }
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }
}

/// 系统通知代理：把点击事件转成应用内深链。
final class MovoNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    private let onLink: @Sendable (NotificationDeepLink) -> Void

    init(onLink: @escaping @Sendable (NotificationDeepLink) -> Void) {
        self.onLink = onLink
    }

    /// 前台展示（锁屏隐藏详情由内容层已处理，10.9）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// 点击通知 → 解析 deepLink → 交给应用路由
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["deepLink"] as? String,
              let link = NotificationDeepLink.parse(raw) else { return }
        onLink(link)
    }
}
