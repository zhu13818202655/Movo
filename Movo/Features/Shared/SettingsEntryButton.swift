//
//  SettingsEntryButton.swift
//  Features/Shared
//
//  顶部栏右上角的设置入口，取代原来的 SyncStatusBadge（同步角标）。
//  依据：PRD §310「设置包含账号、同步、AI 与数据、通知和导出」，
//  UI 规范也把「同步冲突」从收件箱搬进了设置页的同步分区。
//  因此顶部只留一个入口，同步与模型厂商都从设置页进入，不再分叉出第二条路径。
//
//  同步状态不丢：齿轮上带一个小角标，只在「正在同步」和「同步失败 / 待确认冲突」时出现。
//  正常状态（未登录 / 就绪 / 已同步）不显示角标——顶部不该和设置页重复表达同一件事，
//  这也正是这次改动的目的。角标用图标而不是纯色点，并写进 VoiceOver 提示
//  （02 States F：状态不只靠颜色）。
//

import SwiftUI
import MovoKit

public struct SettingsEntryButton: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    public init() {}

    public var body: some View {
        let state = env.store.currentSyncState()

        MovoIconButton("gearshape", label: "设置") {
            // 一律打开设置页，不因为存在冲突就改跳冲突页：
            // 入口行为保持可预测（同 Router 里关于关闭按钮的约定），
            // 冲突处理入口在「设置 → 同步」分区里（见 SyncSettingsView）。
            router.present(.settings)
        }
        .overlay(alignment: .topTrailing) {
            if let attention = SyncAttention(state) {
                badge(attention)
                    .padding(.top, 2)
                    .padding(.trailing, 2)
            }
        }
        .accessibilityLabel("设置")
        .accessibilityHint("同步状态：\(state.displayText)。可在这里进入同步与模型配置。")
        .help(state.displayText)
    }

    // MARK: - 同步角标

    /// 角标只承担「有没有需要现在知道的事」，细节文案交给 VoiceOver 与 mac 上的悬停提示。
    /// 因此角标自身对辅助技术隐藏，避免顶部出现两个可聚焦元素。
    private func badge(_ attention: SyncAttention) -> some View {
        Image(systemName: symbol(attention))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(foreground(attention))
            .frame(width: 15, height: 15)
            .background(Circle().fill(background(attention)))
            .overlay(Circle().strokeBorder(MovoColor.bg, lineWidth: 1.5))
            .accessibilityHidden(true)
    }

    private func symbol(_ attention: SyncAttention) -> String {
        switch attention {
        case .activity: "arrow.triangle.2.circlepath"
        case .issue: "exclamationmark"
        }
    }

    private func background(_ attention: SyncAttention) -> Color {
        switch attention {
        case .activity: MovoColor.tint
        case .issue: MovoColor.warning
        }
    }

    private func foreground(_ attention: SyncAttention) -> Color {
        switch attention {
        case .activity: MovoColor.primary
        case .issue: MovoColor.onPrimary
        }
    }
}
