//
//  ConflictResolutionScreen.swift
//  Features/Settings
//
//  T3.3 冲突处理（02 States B 第 6 条）：
//  双候选值 + 各自时间与设备（"Mac / iPhone"），选择后写决议事件，两端再同步。
//  冲突解决前**不丢失任一版本**（P3 完成条件）——两个候选始终并排可读。
//

import SwiftUI
import MovoKit

public struct ConflictResolutionScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    @State private var conflicts: [SyncConflict] = []
    @State private var titles: [UUID: String] = [:]
    @State private var customs: [UUID: String] = [:]
    @State private var busy = false

    public init() {}

    public var body: some View {
        ScreenScroll {
            ScreenChrome("同步冲突", subtitle: "两份都保留，由你选择") {
                #if !os(macOS)
                MovoIconButton("xmark", label: "关闭") { router.dismissSheet() }
                #endif
            }

            if let report = env.lastSyncReport, report.detectedConflicts > 0 {
                Text("最近一次同步检出 \(report.detectedConflicts) 处冲突。")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }

            if conflicts.isEmpty {
                MovoEmptyState(
                    systemImage: "checkmark.circle",
                    title: "没有待处理的冲突",
                    message: "同一字段在两台设备上被分别修改时，两个版本都会出现在这里等你选择。")
                .frame(minHeight: 260)
            } else {
                Text("有 \(conflicts.count) 处需要你确认")
                    .font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.muted)
                ForEach(conflicts) { conflict in
                    card(conflict)
                }
            }
        }
        .movoPageBackground()
        .task { await reload() }
    }

    // MARK: - 单条冲突

    @ViewBuilder
    private func card(_ conflict: SyncConflict) -> some View {
        MovoCard {
            VStack(alignment: .leading, spacing: MovoSpace.s) {
                HStack(spacing: MovoSpace.s) {
                    Text(titles[conflict.entityId] ?? conflict.entityType.displayName)
                        .font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                    MovoTag(conflict.entityType.displayName)
                    Spacer(minLength: 0)
                    MovoTag(SyncFieldNaming.displayName(for: conflict.field),
                            systemImage: "arrow.triangle.branch")
                }

                Text("这个字段在两台设备上改成了不同的值，先选一个：")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)

                candidate(label: "本机", value: conflict.localValue,
                          deviceId: conflict.localDeviceId, changedAt: conflict.localChangedAt,
                          isThisDevice: true)

                candidate(label: "云端", value: conflict.remoteValue,
                          deviceId: conflict.remoteDeviceId, changedAt: conflict.remoteChangedAt,
                          isThisDevice: false)

                if isTextLike(conflict) {
                    HStack(spacing: MovoSpace.s) {
                        MovoTextField("也可以自己写一个版本",
                                      text: Binding(
                                        get: { customs[conflict.id] ?? "" },
                                        set: { customs[conflict.id] = $0 }),
                                      placeholder: "输入新的值")
                        MovoButton("用这个", kind: .secondary,
                                   isEnabled: !(customs[conflict.id] ?? "")
                                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            _Concurrency.Task {
                                let text = (customs[conflict.id] ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                await resolve(conflict, choice: .custom,
                                              custom: parseCustom(text, like: conflict.localValue))
                            }
                        }
                    }
                }

                HStack(spacing: MovoSpace.s) {
                    MovoButton("保留本机版本", kind: .primary) {
                        _Concurrency.Task { await resolve(conflict, choice: .local) }
                    }
                    MovoButton("保留云端版本", kind: .secondary) {
                        _Concurrency.Task { await resolve(conflict, choice: .remote) }
                    }
                    Spacer(minLength: 0)
                }
                .disabled(busy)
                .opacity(busy ? 0.6 : 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func candidate(label: String, value: JSONValue, deviceId: String,
                           changedAt: Date, isThisDevice: Bool) -> some View {
        VStack(alignment: .leading, spacing: MovoSpace.xs) {
            HStack(spacing: MovoSpace.s) {
                Text(label).font(MovoFont.captionEmphasis)
                    .foregroundStyle(isThisDevice ? MovoColor.primary : MovoColor.muted)
                MovoTag(deviceLabel(deviceId), systemImage: isThisDevice ? "laptopcomputer" : "iphone")
                MovoTag(stamp(changedAt))
                Spacer(minLength: 0)
            }
            Text(SyncFieldNaming.text(for: value))
                .font(MovoFont.body).foregroundStyle(MovoColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MovoSpace.s)
                .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                    .fill(MovoColor.soft))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(SyncFieldNaming.text(for: value))，"
                            + "\(deviceLabel(deviceId))，\(stamp(changedAt))")
    }

    // MARK: - 行为

    private func resolve(_ conflict: SyncConflict, choice: ConflictResolution,
                         custom: JSONValue? = nil) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await env.store.execute(
                ResolveConflict(conflictID: conflict.id, choice: choice, customValue: custom))
            await env.applyResolvedConflicts()
        } catch let error as MovoError {
            env.lastError = error
        } catch {
            env.lastError = .invalidStructure(reason: "这次选择没有保存。")
        }
        await reload()
    }

    private func reload() async {
        let open = await env.store.repository.conflicts(resolved: false)
            .sorted { $0.detectedAt > $1.detectedAt }
        var map: [UUID: String] = [:]
        for conflict in open where map[conflict.entityId] == nil {
            let box = await SyncEntityBox.fetch(type: conflict.entityType,
                                                id: conflict.entityId,
                                                in: env.store.repository)
            map[conflict.entityId] = box?.searchTitle ?? conflict.entityType.displayName
        }
        conflicts = open
        titles = map
    }

    // MARK: - 辅助

    private func isTextLike(_ conflict: SyncConflict) -> Bool {
        if case .string = conflict.localValue { return true }
        if case .string = conflict.remoteValue { return true }
        return false
    }

    private func parseCustom(_ text: String, like value: JSONValue) -> JSONValue {
        switch value {
        case .int: return .int(Int(text) ?? 0)
        case .double: return .double(Double(text) ?? 0)
        case .bool: return .bool(text == "是" || text.lowercased() == "true")
        default: return .string(text)
        }
    }

    private func deviceLabel(_ id: String) -> String {
        id == env.store.deviceId ? "这台设备" : "另一台设备"
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}

#Preview("同步冲突") {
    let env = AppEnvironment.preview(today: DemoFixtures.referenceDate)
    return ConflictResolutionScreen()
        .environment(env)
        .environment(\.movoRouter, Router())
}
