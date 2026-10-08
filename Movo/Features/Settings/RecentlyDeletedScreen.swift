//
//  RecentlyDeletedScreen.swift
//  Features/Settings
//
//  M13-Recovery 最近删除（T1.9）。
//  删除只写 Tombstone，不物理抹除；保留期内可恢复，恢复**不补造**历史行动（9.5）。
//  到期（默认 30 天）后由 Lifecycle 清理，界面在到期前给出剩余天数。
//

import SwiftUI
import MovoKit

public struct RecentlyDeletedScreen: View {
    @Environment(AppEnvironment.self) private var env
    /// 关闭本页：本页由设置的「查看」以浮层呈现（也对应 `.recentlyDeleted` 路由），
    /// 用 dismiss 关闭当前呈现，而不是关掉另一个由 Router 管理的浮层。
    @Environment(\.dismiss) private var dismiss

    @State private var tombstones: [Tombstone] = []
    @State private var names: [UUID: String] = [:]
    @State private var descendantCounts: [UUID: Int] = [:]

    public init() {}

    public var body: some View {
        ScreenScroll {
            ScreenChrome("最近删除",
                         subtitle: "保留 \(env.defaults.lifecycle.tombstoneRetentionDays) 天，可以恢复") {
                #if !os(macOS)
                MovoIconButton("xmark", label: "关闭") { dismiss() }
                #endif
            }

            if tombstones.isEmpty {
                MovoEmptyState(systemImage: "trash.slash",
                               title: "最近删除是空的",
                               message: "被删除的计划与任务会先放到这里，保留期内随时可以找回。")
                    .frame(minHeight: 260)
            } else {
                SectionBlock("待清理", trailing: "\(tombstones.count) 项") {
                    VStack(spacing: 0) {
                        ForEach(tombstones) { tombstone in
                            HStack(alignment: .top, spacing: MovoSpace.s) {
                                Image(systemName: icon(tombstone.entityType))
                                    .font(.system(size: 14))
                                    .foregroundStyle(MovoColor.muted)
                                    .frame(width: 22, height: 22)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: MovoSpace.xs) {
                                    Text(names[tombstone.entityId] ?? tombstone.entityType.displayName)
                                        .font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: MovoSpace.xs) {
                                        MovoTag(tombstone.entityType.displayName)
                                        MovoTag("删除于 \(Self.dayText(tombstone.deletedAt, in: env.store.currentTimeZone))")
                                        MovoTag("还有 \(tombstone.daysRemaining(at: env.store.now)) 天")
                                        if let count = descendantCounts[tombstone.entityId], count > 0 {
                                            MovoTag("含 \(count) 项内容")
                                        }
                                    }
                                }

                                Spacer(minLength: MovoSpace.s)

                                MovoButton("恢复", kind: .secondary) {
                                    _Concurrency.Task { await restore(tombstone) }
                                }
                            }
                            .padding(MovoSpace.s)
                            if tombstone.id != tombstones.last?.id {
                                MovoDivider().padding(.leading, MovoSpace.m)
                            }
                        }
                    }
                }

                Text("到期后这些内容会被自动清理，无法再找回。")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }

            if let error = env.lastError {
                MovoBanner(error: error) { _ in env.lastError = nil }
            }
        }
        .movoPageBackground()
        .task { await reload() }
    }

    private func icon(_ type: EntityType) -> String {
        switch type {
        case .plan: "square.stack.3d.up"
        case .stage: "flag"
        case .task: "checklist"
        case .activity: "timer"
        case .measurement: "chart.line.uptrend.xyaxis"
        case .note: "text.bubble"
        case .metric: "ruler"
        default: "doc.text"
        }
    }

    private func restore(_ tombstone: Tombstone) async {
        do {
            try await env.store.execute(RestoreEntity(entityType: tombstone.entityType,
                                                      id: tombstone.entityId))
            env.lastBatchNotice = env.store.lastNotification
            await reload()
        } catch let error as MovoError {
            env.lastError = error
        } catch {
            env.lastError = .invalidStructure(reason: "这项内容没有恢复成功。")
        }
    }

    private func reload() async {
        tombstones = await env.store.recentlyDeleted()
        var resolved: [UUID: String] = [:]
        var counts: [UUID: Int] = [:]
        for tombstone in tombstones {
            let name = await env.store.repository.entityName(type: tombstone.entityType,
                                                             id: tombstone.entityId)
            if let name { resolved[tombstone.entityId] = name }
            // 计划的子内容数量（级联删除提示）
            if tombstone.entityType == .plan {
                counts[tombstone.entityId] = await DeletePlan.cascadeIDs(
                    planID: tombstone.entityId, repository: env.store.repository).count - 1
            }
        }
        names = resolved
        descendantCounts = counts
    }

    static func dayText(_ date: Date, in timeZone: TimeZone) -> String {
        DateOnly(from: date, in: timeZone).displayString
    }
}

#Preview("最近删除") {
    RecentlyDeletedScreen()
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
