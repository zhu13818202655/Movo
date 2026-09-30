//
//  SettingsScreen.swift
//  Features/Settings
//
//  M13 设置 / D01-Settings。分区：AI 与数据 / 计划隐私 / 同步 / 通知 / 导出 / 管理。
//  两个开关彼此独立：「允许云端 AI」只影响整理，「云同步」只影响是否上云（P3 完成条件）。
//  iPhone 从今日右上角进入，Mac 从侧边导航底部进入。
//

import SwiftUI
import MovoKit

/// 设置分区顺序（RecoveryAction.SettingsSection 未声明 CaseIterable，这里显式列出）
public let movoSettingsOrder: [RecoveryAction.SettingsSection] =
    [.ai, .privacy, .sync, .notifications, .export, .manage]

public struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    @State private var expanded: Set<RecoveryAction.SettingsSection> = [.ai]

    public init() {}

    public var body: some View {
        ScreenScroll {
            ScreenChrome("设置", subtitle: "渐成 · 本机优先") {
                #if !os(macOS)
                MovoIconButton("xmark", label: "关闭设置") { router.dismissSheet() }
                #endif
            }

            if let error = env.lastError {
                MovoBanner(error: error) { _ in env.lastError = nil }
            }

            ForEach(movoSettingsOrder, id: \.self) { section in
                CollapsibleSection(section.displayName,
                                   trailing: SettingsSummary.text(for: section, env: env),
                                   isExpanded: binding(for: section)) {
                    SettingsSectionContent(section: section)
                }
            }

            Text("AI Key 只保存在本机钥匙串，不进入 iCloud、导出或日志。原始音频默认不留存。")
                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, MovoSpace.s)
        }
        .movoPageBackground()
    }

    private func binding(for section: RecoveryAction.SettingsSection) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(section) },
            set: { isOn in
                if isOn { expanded.insert(section) } else { expanded.remove(section) }
            })
    }
}

/// 折叠状态下的摘要（一眼看出里面有什么）
enum SettingsSummary {
    @MainActor
    static func text(for section: RecoveryAction.SettingsSection, env: AppEnvironment) -> String {
        switch section {
        case .ai:
            guard env.isConfigured() else { return env.configurationError().title }
            return "\(env.vendor.displayName) · \(env.maskedKey() ?? "已配置")"
        case .privacy:
            return "云端 AI 开关"
        case .sync:
            return env.store.currentSyncState().displayText
        case .notifications:
            return "\(env.defaults.notifications.dateOnlyTaskHour):00 提醒 · 安静 \(env.defaults.notifications.quietHoursStart)–\(env.defaults.notifications.quietHoursEnd) 时"
        case .export:
            return "Markdown / JSON"
        case .manage:
            return "最近删除 · 演示数据"
        }
    }
}

public struct SettingsSectionScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let section: RecoveryAction.SettingsSection

    public init(section: RecoveryAction.SettingsSection) { self.section = section }

    public var body: some View {
        ScreenScroll {
            ScreenChrome(section.displayName, subtitle: "渐成 · 设置") {
                #if !os(macOS)
                MovoIconButton("xmark", label: "关闭") { router.dismissSheet() }
                #endif
            }
            SettingsSectionContent(section: section)
            if let error = env.lastError {
                MovoBanner(error: error) { _ in env.lastError = nil }
            }
        }
        .movoPageBackground()
    }
}

// MARK: - 分区内容路由

public struct SettingsSectionContent: View {
    let section: RecoveryAction.SettingsSection

    public init(section: RecoveryAction.SettingsSection) { self.section = section }

    public var body: some View {
        switch section {
        case .ai: AISettingsView()
        case .privacy: PrivacySettingsView()
        case .sync: SyncSettingsView()
        case .notifications: NotificationSettingsView()
        case .export: ExportSettingsView()
        case .manage: ManageSettingsView()
        }
    }
}
