//
//  MovoApp.swift
//  App
//
//  Movo — 个人待办与长期目标。「Daily & Beyond / 渐成」
//  双端单工程：iOS 26+ / macOS 26+。
//

import SwiftUI
import MovoKit

@main
struct MovoApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(\.movoRouter, Router())
                .task { await bootstrap() }
        }
#if os(macOS)
        .defaultSize(width: 1440, height: 960)
        .commands { MovoCommands() }
#endif
    }

    /// 首次启动装载统一示例数据（仅演示用；已有内容时不覆盖），
    /// 然后启动同步（无 iCloud 环境自动降级）并写入通知排期。
    private func bootstrap() async {
        environment.installNotificationHandling()
        try? await DemoFixtures.seedIfEmpty(into: environment.store)
        await environment.activateSync()
        _ = await environment.refreshNotifications()
    }
}

#if os(macOS)
import AppKit

/// Mac 原生窗口工具栏与菜单
struct MovoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .appInfo) {
            Button("检查同步状态") { NotificationCenter.default.post(name: .movoRefresh, object: nil) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let movoRefresh = Notification.Name("movo.refresh")
}
#endif
