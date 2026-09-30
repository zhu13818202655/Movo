//
//  SyncStatusBadge.swift
//  Features/Shared
//
//  T3.2 今日顶部同步角标：把 SyncState 直接映射成一处可点的状态位。
//  点按：有冲突 → 冲突处理页；否则 → 设置·同步分区。
//  状态不只靠颜色（02 States F）：图标 + 文案 + VoiceOver 标签同时表达。
//

import SwiftUI
import MovoKit

public struct SyncStatusBadge: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    private let compact: Bool

    public init(compact: Bool = true) { self.compact = compact }

    public var body: some View {
        let state = env.store.currentSyncState()
        Button { open(state) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon(state)).font(.system(size: 12, weight: .medium))
                if !compact || showsText(state) {
                    Text(shortText(state)).font(MovoFont.caption).lineLimit(1)
                }
            }
            .padding(.horizontal, MovoSpace.s)
            .padding(.vertical, 3)
            .background(Capsule().fill(background(state)))
            .foregroundStyle(foreground(state))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("同步状态：\(state.displayText)")
        .accessibilityHint(state.hasConflict ? "查看需要确认的冲突" : "打开同步设置")
        .help(state.displayText)
    }

    // MARK: - 表现

    private func icon(_ state: SyncState) -> String {
        switch state {
        case .notSignedIn: "icloud.slash"
        case .idle: "icloud"
        case .syncing: "arrow.triangle.2.circlepath"
        case .upToDate: "checkmark.icloud"
        case .failed: "exclamationmark.icloud"
        case .conflictPending: "exclamationmark.triangle"
        }
    }

    private func shortText(_ state: SyncState) -> String {
        switch state {
        case .notSignedIn: "仅本机"
        case .idle: "同步就绪"
        case .syncing(let n): n > 0 ? "同步中 \(n)" : "同步中"
        case .upToDate: "已同步"
        case .failed: "同步异常"
        case .conflictPending(let n): "待确认 \(n)"
        }
    }

    /// 平时只留图标，异常与冲突必须带文案（02 States F：状态不只靠颜色）
    private func showsText(_ state: SyncState) -> Bool {
        switch state {
        case .failed, .conflictPending, .syncing: true
        case .notSignedIn, .idle, .upToDate: false
        }
    }

    private func background(_ state: SyncState) -> Color {
        switch state {
        case .failed, .conflictPending: MovoCategoryColorConflict.background
        case .syncing: MovoColor.tint
        case .upToDate: MovoColor.tint
        case .idle, .notSignedIn: MovoColor.soft
        }
    }

    private func foreground(_ state: SyncState) -> Color {
        switch state {
        case .failed, .conflictPending: MovoColor.warning
        case .syncing, .upToDate: MovoColor.primary
        case .idle, .notSignedIn: MovoColor.muted
        }
    }

    // MARK: - 导航

    private func open(_ state: SyncState) {
        if state.hasConflict {
            router.push(.conflicts)
        } else {
            router.present(.settingsSection(.sync))
        }
    }
}

/// 冲突态的浅底（与警告同色系，避免引入新语义色）
private enum MovoCategoryColorConflict {
    static var background: Color { Color.movoAdaptive(light: "#FBF0E4", dark: "#3A2F22") }
}
