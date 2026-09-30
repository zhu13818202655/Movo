//
//  SettingsSections.swift
//  Features/Settings
//
//  设置分区内容：AI 与数据 / 计划隐私 / 同步 / 通知 / 导出 / 管理。
//  每个分区都能独立工作：没有 Key、没有 iCloud、没有通知权限时，
//  手动记录与整理仍然完全可用（无网络也能操作）。
//

import SwiftUI
import MovoKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AI 与数据（8.1 / T2.2）

/// URL / 模型 ID 这类标识符输入：禁用自动纠正；iOS 上再关掉首字母大写。
/// （`textInputAutocapitalization` 在 macOS 上不可用，必须按平台条件编译。）
private struct IdentifierInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        content.autocorrectionDisabled()
        #endif
    }
}

private extension View {
    func identifierInputStyle() -> some View { modifier(IdentifierInputStyle()) }
}

struct AISettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var vendor: AIVendor = .deepseek
    @State private var model: String = ""
    @State private var keyInput = ""
    @State private var connectionState: ConnectionState = .idle

    enum ConnectionState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    /// 自定义厂商配置直接写回环境，随输入即时持久化（Base URL 与模型 ID 非敏感）。
    private var baseURLBinding: Binding<String> {
        Binding(get: { env.customProvider.baseURL },
                set: { env.customProvider.baseURL = $0 })
    }

    private var customModelBinding: Binding<String> {
        Binding(get: { env.customProvider.modelID },
                set: { env.customProvider.modelID = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.l) {
            MovoFormSection("提供商",
                            footnote: "Key 只保存在本机钥匙串（kSecAttrAccessibleWhenUnlockedThisDeviceOnly）；自定义厂商的 Base URL 与模型 ID 存在本机偏好。三者都不会同步到 iCloud，也不会进入导出。") {
                MovoFormRow("厂商") {
                    MovoRequiredChipRow(options: AIVendor.allCases, selection: $vendor,
                                        label: \.displayName)
                }

                switch vendor {
                case .deepseek:
                    builtinFields
                case .custom:
                    customFields
                }
            }

            MovoFormSection("访问 Key") {
                HStack(spacing: MovoSpace.s) {
                    StatusTag(text: env.hasKey(for: vendor) ? "已配置" : "未配置",
                              foreground: env.hasKey(for: vendor) ? MovoColor.done : MovoColor.warning,
                              background: MovoColor.soft,
                              systemImage: env.hasKey(for: vendor) ? "checkmark.circle" : "exclamationmark.circle")
                    if let masked = env.maskedKey(for: vendor) {
                        MovoTag(masked, systemImage: "key")
                    }
                    Spacer(minLength: 0)
                }

                SecureField("粘贴 \(vendor.displayName) 的 Key", text: $keyInput)
                    .textFieldStyle(.plain)
                    .font(MovoFont.mono)
                    .padding(MovoSpace.s)
                    .frame(minHeight: MovoSpace.minTouch)
                    .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                        .fill(MovoColor.surface))
                    .overlay(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                        .strokeBorder(MovoColor.line, lineWidth: 1))

                if !keyInput.isEmpty, !AIKeyFormat.looksValid(keyInput, vendor: vendor) {
                    Text("Key 格式不像 \(vendor.displayName) 的常见格式，仍可以先保存再测试连接。")
                        .font(MovoFont.caption).foregroundStyle(MovoColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: MovoSpace.s) {
                    MovoButton("保存 Key", kind: .primary,
                               isEnabled: !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        save()
                    }
                    MovoButton("测试连接", kind: .secondary,
                               isLoading: connectionState == .testing) {
                        _Concurrency.Task { await test() }
                    }
                    if env.hasKey(for: vendor) {
                        MovoButton("删除 Key", kind: .destructive) { deleteKey() }
                    }
                    Spacer(minLength: 0)
                }

                switch connectionState {
                case .idle:
                    EmptyView()
                case .testing:
                    Text("正在测试连接…").font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                case .success(let message):
                    Text(message).font(MovoFont.caption).foregroundStyle(MovoColor.done)
                case .failure(let message):
                    Text(message).font(MovoFont.caption).foregroundStyle(MovoColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("没有 Key 也可以使用：录入原文、手动整理、记录与回顾都不依赖 AI。")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !env.usageLog.isEmpty {
                MovoFormSection("最近用量", footnote: "只记录模型、耗时与 token 数，不含任何正文。") {
                    ForEach(env.usageLog.prefix(8)) { record in
                        HStack(spacing: MovoSpace.s) {
                            Text(record.provider).font(MovoFont.captionEmphasis)
                                .foregroundStyle(MovoColor.ink)
                            Text(record.model).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                            Spacer(minLength: MovoSpace.s)
                            MovoTag("\(record.totalTokens) token")
                            MovoTag("\(record.latencyMs) ms")
                            StatusTag(text: record.status,
                                      foreground: record.status == "成功" ? MovoColor.done : MovoColor.warning,
                                      background: MovoColor.soft)
                        }
                        .frame(minHeight: 30)
                    }
                }
            }

            if let error = env.lastError {
                MovoFormSection("最近错误", footnote: "错误信息不含你的正文。") {
                    Text("\(error.title)：\(error.message)")
                        .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            vendor = env.vendor
            model = env.model
        }
        .onChange(of: vendor) { _, newValue in
            connectionState = .idle
            env.vendor = newValue
            model = env.model
        }
        .onChange(of: model) { _, newValue in
            if vendor == .deepseek { env.model = newValue }
        }
    }

    // MARK: 内置厂商字段

    @ViewBuilder
    private var builtinFields: some View {
        MovoFormRow("模型") {
            Picker("", selection: $model) {
                ForEach(env.availableModels(for: .deepseek)) { info in
                    Text(info.displayName).tag(info.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        if let hint = env.catalog.entry(for: .deepseek)?.keyPrefixHint {
            Text("Key 通常以 \(hint) 开头。").font(MovoFont.caption)
                .foregroundStyle(MovoColor.muted)
        }
    }

    // MARK: 自定义厂商字段（OpenAI 兼容）

    /// 地址填了但不可用时的即时提示。裸 IP（如 203.0.113.10:21003/v1）最常忘记写 scheme。
    private var baseURLHint: String? {
        guard !env.customProvider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !env.customProvider.hasUsableBaseURL else { return nil }
        return "地址要以 http:// 或 https:// 开头"
    }

    @ViewBuilder
    private var customFields: some View {
        MovoTextField("Base URL", text: baseURLBinding,
                      placeholder: "https://your-server/v1",
                      errorMessage: baseURLHint)
            .identifierInputStyle()
        MovoTextField("模型 ID", text: customModelBinding,
                      placeholder: "your-model-id")
            .identifierInputStyle()
        // 把归一化后的真实端点显示出来：用户可以直接核对地址拼得对不对
        if let endpoint = env.customProvider.chatCompletionsURL() {
            Text("请求会发往 \(endpoint)。")
                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("按 OpenAI 兼容协议调用，鉴权头为 Authorization: Bearer <Key>。")
            .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        do {
            try env.saveKey(keyInput.trimmingCharacters(in: .whitespacesAndNewlines), vendor: vendor)
            keyInput = ""
            env.lastError = nil
            connectionState = .success("Key 已保存到本机钥匙串。")
        } catch {
            connectionState = .failure("Key 没有保存成功，请重试。")
        }
    }

    private func deleteKey() {
        do {
            try env.deleteKey(vendor: vendor)
            connectionState = .idle
        } catch {
            connectionState = .failure("Key 没有删除成功。")
        }
    }

    private func test() async {
        connectionState = .testing
        // 自定义厂商的模型取自已写入环境的配置，这里只在内置厂商时显式传入选择值。
        let testModel = (vendor == .deepseek && !model.isEmpty) ? model : nil
        do {
            try await env.testConnection(vendor: vendor, model: testModel)
            connectionState = .success("连接正常。")
        } catch let error as MovoError {
            // 这里没有待整理的原文，用 diagnosticDetail（可执行解释）而不是 message。
            connectionState = .failure("\(error.title)：\(error.diagnosticDetail ?? error.message)")
        } catch {
            connectionState = .failure("连接没有成功，请检查网络后重试。")
        }
    }
}

// MARK: - 计划隐私（两个开关独立）

struct PrivacySettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var plans: [Plan] = []
    @State private var loaded = false

    var body: some View {
        MovoFormSection("计划隐私",
                        footnote: "「允许云端 AI」与「云同步」互不影响：可以只在本机整理但仍然同步，反之亦然。") {
            if plans.isEmpty && loaded {
                Text("还没有计划。新建计划时可以单独设置这两个开关。")
                    .font(MovoFont.body).foregroundStyle(MovoColor.muted)
            }
            ForEach(plans) { plan in
                VStack(alignment: .leading, spacing: MovoSpace.s) {
                    HStack(spacing: MovoSpace.s) {
                        Text(plan.name).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                        if let category = plan.category { PlanCategoryTag(category, compact: true) }
                        Spacer(minLength: 0)
                        StatusTag(planStatus: plan.status)
                    }
                    Toggle(isOn: Binding(
                        get: { plan.cloudAIEnabled },
                        set: { newValue in
                            _Concurrency.Task { await setCloudAI(plan, enabled: newValue) }
                        })) {
                        Text("允许云端 AI 处理").font(MovoFont.body).foregroundStyle(MovoColor.ink)
                    }
                    .toggleStyle(.switch).controlSize(.small)

                    Toggle(isOn: Binding(
                        get: { plan.syncEnabled },
                        set: { newValue in
                            _Concurrency.Task { await setSync(plan, enabled: newValue) }
                        })) {
                        Text("同步到 iCloud").font(MovoFont.body).foregroundStyle(MovoColor.ink)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }
                .padding(.vertical, MovoSpace.s)
                MovoDivider()
            }
        }
        .task { await reload() }
    }

    private func setCloudAI(_ plan: Plan, enabled: Bool) async {
        var patch = PlanPatch()
        patch.cloudAIEnabled = enabled
        _ = try? await env.store.execute(UpdatePlan(planID: plan.id, patch: patch,
                                                baseRevision: plan.revision))
        await reload()
    }

    private func setSync(_ plan: Plan, enabled: Bool) async {
        var patch = PlanPatch()
        patch.syncEnabled = enabled
        _ = try? await env.store.execute(UpdatePlan(planID: plan.id, patch: patch,
                                                baseRevision: plan.revision))
        await reload()
    }

    private func reload() async {
        plans = await env.store.repository.allPlans().sorted { $0.updatedAt > $1.updatedAt }
        loaded = true
    }
}

// MARK: - 同步（P3 状态位 / 9.6 计划级开关与账号状态）

struct SyncSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    @State private var state: SyncState = .notSignedIn
    @State private var account: CloudAccountState = .unknown
    @State private var conflictCount = 0
    @State private var eventCount = 0
    @State private var busy = false
    @State private var lastAction: String?

    var body: some View {
        MovoFormSection("iCloud 账号",
                        footnote: "同步走 iCloud 私有数据库；AI Key 永不进入 iCloud，也不出现在导出与日志里。") {
            MovoInfoRow("账号状态", value: account.displayName,
                        systemImage: account.isReady ? "icloud.fill" : "icloud.slash")
            if let hint = account.recoveryHint {
                Text(hint).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: MovoSpace.s) {
                MovoButton("立即同步", kind: .primary,
                           isEnabled: account.isReady && !busy, isLoading: busy) {
                    _Concurrency.Task { await syncNow() }
                }
                MovoButton("刷新状态", kind: .secondary) {
                    _Concurrency.Task { await reload() }
                }
                Spacer(minLength: 0)
            }
            if let lastAction {
                Text(lastAction).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
        }

        MovoFormSection("同步状态") {
            MovoInfoRow("当前状态", value: state.displayText,
                        systemImage: "arrow.triangle.2.circlepath")
            MovoInfoRow("待同步事件", value: "\(state.pendingCount) 项",
                        systemImage: "tray.and.arrow.up")
            MovoInfoRow("待处理冲突", value: conflictCount > 0 ? "\(conflictCount) 处" : "无",
                        systemImage: "exclamationmark.triangle")
            if conflictCount > 0 {
                MovoButton("处理冲突", kind: .secondary) { router.push(.conflicts) }
            }
        }

        // 9.6：退出登录 / 换机前若存在 pending 数据 → 提示先同步或先导出（REQ 20）
        if state.pendingCount > 0 || conflictCount > 0 {
            MovoFormSection("退出或换机前",
                            footnote: "退出 iCloud 前若有没同步完的内容，先等同步完成再退出，或先导出留档。") {
                MovoBanner(kind: .warning, title: "还有内容没同步",
                           message: "待传 \(state.pendingCount) 项、待确认 \(conflictCount) 处。",
                           actions: [
                            ("立即同步", { _Concurrency.Task { await syncNow() } }),
                            ("导出留档", { router.push(.exportPreview(planID: nil)) })
                           ])
            }
        }

        MovoFormSection("关于跨设备同步",
                        footnote: "计划级开关在「计划隐私」里单独设置；重新打开某个计划的同步会全量重推该计划（9.6）。") {
            MovoInfoRow("同步机制", value: "变更事件 + 逐字段合并", systemImage: "arrow.left.arrow.right")
            MovoInfoRow("冲突处理", value: "两份都保留，由你选择", systemImage: "arrow.triangle.branch")
            MovoInfoRow("删除保护", value: "\(env.defaults.lifecycle.tombstoneRetentionDays) 天可恢复", systemImage: "trash.slash")
            MovoInfoRow("同步开关", value: "按计划单独设置（见「计划隐私」）", systemImage: "switch.2")
        }

        MovoFormSection("本机数据",
                        footnote: "任一端的完成/跳过会在下次同步后取消对端待发提醒；离线窗口内不保证绝对无重复（10.9）。") {
            MovoInfoRow("事件总数", value: "\(eventCount) 条", systemImage: "list.bullet.rectangle")
            MovoInfoRow("通知重排", value: "数据变更后自动覆盖写入", systemImage: "bell")
        }
        .task { await reload() }
    }

    private func syncNow() async {
        busy = true
        defer { busy = false }
        await env.syncNow()
        await reload()
        lastAction = env.lastSyncReport?.summaryText ?? "刚刚完成一次同步。"
    }

    private func reload() async {
        await env.refreshSyncStatus()
        state = env.store.currentSyncState()
        account = env.syncAccount
        conflictCount = env.pendingConflictCount
        eventCount = await env.store.repository.eventCount()
    }
}

// MARK: - 通知（10.9 / T0.12）

struct NotificationSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var status: PermissionState = .undetermined
    @State private var planned: [PlannedNotification] = []
    @State private var lastDelivery: String?

    /// 与 App 共用同一个排期写入端（系统通知中心）
    private var scheduler: any NotificationScheduling { env.notificationScheduler }

    private var hideDetailsBinding: Binding<Bool> {
        Binding(get: { env.notificationsHideDetails },
                set: { env.notificationsHideDetails = $0 })
    }

    var body: some View {
        MovoFormSection("权限") {
            HStack(spacing: MovoSpace.s) {
                StatusTag(text: statusText,
                          foreground: status == .granted ? MovoColor.done : MovoColor.warning,
                          background: MovoColor.soft,
                          systemImage: status == .granted ? "bell.badge" : "bell.slash")
                Spacer(minLength: 0)
                if status != .granted {
                    MovoButton("请求通知权限", kind: .secondary) {
                        _Concurrency.Task { await request() }
                    }
                }
            }
            Text("没有通知权限时其它功能完全不受影响，只是不会主动提醒你。")
                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
        }

        MovoFormSection("排期规则", footnote: "排期来自 10.9：仅日期任务在当天固定时刻提醒；带时刻的任务提前提醒；硬截止提前与当天各一次。") {
            MovoInfoRow("仅日期任务", value: "\(String(format: "%02d:%02d", env.defaults.notifications.dateOnlyTaskHour, env.defaults.notifications.dateOnlyTaskMinute))", systemImage: "clock")
            MovoInfoRow("硬截止提前", value: "\(env.defaults.notifications.hardDeadlineLeadDays) 天", systemImage: "exclamationmark.triangle")
            MovoInfoRow("安静时段", value: "\(env.defaults.notifications.quietHoursStart):00 – \(env.defaults.notifications.quietHoursEnd):00", systemImage: "moon.zzz")
            MovoInfoRow("聚合窗口", value: "\(env.defaults.notifications.aggregationWindowMinutes) 分钟", systemImage: "square.stack.3d.up")
            Toggle(isOn: hideDetailsBinding) {
                Text("锁屏不显示任务标题").font(MovoFont.body).foregroundStyle(MovoColor.ink)
            }
            .toggleStyle(.switch).controlSize(.small)
            .onChange(of: env.notificationsHideDetails) { _, _ in
                _Concurrency.Task { _ = await env.refreshNotifications() }
            }
        }

        MovoFormSection("接下来的提醒", footnote: lastDelivery ?? "预览为本机计算，写入系统后会覆盖上一次排期。") {
            if planned.isEmpty {
                Text("未来两周没有需要提醒的安排。")
                    .font(MovoFont.body).foregroundStyle(MovoColor.muted)
            } else {
                ForEach(planned.prefix(6)) { item in
                    HStack(alignment: .top, spacing: MovoSpace.s) {
                        Image(systemName: icon(item.kind)).font(.system(size: 12))
                            .foregroundStyle(MovoColor.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                            Text(item.body).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                                .lineLimit(2)
                            Text(Self.stamp(item.fireDate, in: env.store.currentTimeZone))
                                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        }
                        Spacer(minLength: 0)
                        if item.mergedCount > 0 {
                            MovoTag("合并 \(item.mergedCount + 1) 条")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack(spacing: MovoSpace.s) {
                MovoButton("写入系统通知", kind: .primary, isEnabled: !planned.isEmpty) {
                    _Concurrency.Task { await deliver() }
                }
                MovoButton("取消全部提醒", kind: .quiet) {
                    _Concurrency.Task {
                        await scheduler.cancelAll()
                        lastDelivery = "已取消全部提醒。"
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .task { await reload() }
    }

    private var statusText: String {
        switch status {
        case .undetermined: "还没有决定"
        case .granted: "已允许"
        case .denied: "已拒绝"
        case .restricted: "被系统限制"
        }
    }

    private func icon(_ kind: PlannedNotification.Kind) -> String {
        switch kind {
        case .timedTask: "clock"
        case .dateOnlyTask: "calendar"
        case .hardDeadline: "exclamationmark.triangle"
        case .weeklyReview: "chart.bar.doc.horizontal"
        case .blockedReview: "arrow.triangle.branch"
        }
    }

    private func request() async {
        _ = await scheduler.requestAuthorization()
        status = await scheduler.authorizationStatus()
    }

    private func deliver() async {
        planned = await env.refreshNotifications()
        let count = await scheduler.pendingIdentifiers().count
        lastDelivery = "已写入 \(count) 条提醒，标识固定，重复写入会覆盖同一条。"
    }

    private func reload() async {
        status = await scheduler.authorizationStatus()
        planned = await env.notificationService.plan(now: env.store.now,
                                                     timeZone: env.store.currentTimeZone,
                                                     today: env.store.today)
    }

    static func stamp(_ date: Date, in timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 导出（T1.8）

struct ExportSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var format: ExportFormat = .markdown
    @State private var includeSensitive = false
    @State private var bundle: ExportBundle?
    @State private var copied = false

    var body: some View {
        MovoFormSection("导出格式", footnote: "JSON 导出含依赖关系字段（前置任务），可被重新解析后再导入。") {
            MovoFormRow("格式") {
                MovoRequiredChipRow(options: ExportFormat.allCases, selection: $format,
                                    label: \.displayName)
            }
            Toggle(isOn: $includeSensitive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("包含未允许云 AI 的计划").font(MovoFont.bodyEmphasis)
                        .foregroundStyle(MovoColor.ink)
                    Text("默认排除：健康类等敏感计划不进入导出（AC16）。")
                        .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
            }
            .toggleStyle(.switch)
        }

        MovoFormSection("导出范围") {
            HStack(spacing: MovoSpace.s) {
                MovoButton("导出全部计划", systemImage: "square.and.arrow.up", kind: .primary) {
                    _Concurrency.Task { await generate(planID: nil) }
                }
                Spacer(minLength: 0)
            }
        }

        if let bundle {
            MovoFormSection("预览", footnote: bundle.summaryText) {
                HStack(spacing: MovoSpace.s) {
                    MovoButton("复制内容", systemImage: "doc.on.doc", kind: .secondary) {
                        copy(bundle.content)
                    }
                    MovoButton("重新生成", kind: .quiet) { _Concurrency.Task { await generate(planID: nil) } }
                    Spacer(minLength: 0)
                    if copied { MovoTag("已复制", systemImage: "checkmark") }
                }
                ScrollView {
                    Text(bundle.content)
                        .font(MovoFont.mono)
                        .foregroundStyle(MovoColor.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(MovoSpace.s)
                }
                .frame(maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                    .fill(MovoColor.soft))
            }
        }
    }

    private func generate(planID: UUID?) async {
        bundle = await ExportPreviewScreen.makeBundle(env: env, planID: planID,
                                                      format: format,
                                                      includeSensitive: includeSensitive)
        copied = false
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        copied = true
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        #endif
    }
}

// MARK: - 管理

struct ManageSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var deleted: [Tombstone] = []
    @State private var showRecentlyDeleted = false
    @State private var showPurgeConfirm = false
    @State private var speechCapability: SpeechCapability?
    @AppStorage("movo.demo.enabled") private var demoEnabled = false

    var body: some View {
        MovoFormSection("最近删除", footnote: "删除后 \(env.defaults.lifecycle.tombstoneRetentionDays) 天内可以恢复；到期后自动清理。") {
            HStack(spacing: MovoSpace.s) {
                Text("\(deleted.count) 项待清理").font(MovoFont.body).foregroundStyle(MovoColor.ink)
                Spacer(minLength: 0)
                MovoButton("查看", kind: .secondary) { showRecentlyDeleted = true }
            }
        }
        .sheet(isPresented: $showRecentlyDeleted) {
            RecentlyDeletedScreen()
                .environment(env)
                .frame(minWidth: 420, minHeight: 520)
        }

        MovoFormSection("数据维护") {
            MovoButton("重建搜索索引", systemImage: "arrow.clockwise", kind: .secondary) {
                _Concurrency.Task { await rebuildIndex() }
            }
            Text("如果搜索结果看起来不完整，可以重建。重建只读现有内容，不修改任何计划。")
                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }

        MovoFormSection("语音权限") {
            if let capability = speechCapability {
                MovoInfoRow("麦克风", value: microphoneText, systemImage: "mic")
                MovoInfoRow("本机识别", value: capability.onDevice ? "可用" : "不可用", systemImage: "waveform")
                if let reason = capability.failureReason {
                    Text(reason.displayName + "。可以先改成文字输入，原文不会丢。")
                        .font(MovoFont.caption).foregroundStyle(MovoColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("正在检查语音能力…").font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
        }

        #if DEBUG
        MovoFormSection("演示数据", footnote: "载入与设计稿一致的示例数据（季度汇报 3/7、散步 0/3、体重 68.7）。仅调试版本可见。") {
            Toggle(isOn: $demoEnabled) {
                Text("载入示例数据").font(MovoFont.body).foregroundStyle(MovoColor.ink)
            }
            .toggleStyle(.switch)
            .onChange(of: demoEnabled) { _, isOn in
                if isOn { _Concurrency.Task { try? await DemoFixtures.seed(into: env.store) } }
            }
        }
        #endif

        MovoFormSection("清除数据",
                        footnote: "此操作不可撤销。清除后不会补造任何历史记录。") {
            MovoButton("清除全部本地数据", kind: .destructive) { showPurgeConfirm = true }
                .confirmationDialog("确定要清除全部本地数据吗？", isPresented: $showPurgeConfirm) {
                    Button("清除全部数据", role: .destructive) {
                        _Concurrency.Task { try? await env.store.repository.purgeAll() }
                    }
                    Button("取消", role: .cancel) { }
                }
        }

        MovoFormSection("关于") {
            MovoInfoRow("应用", value: "渐成 Movo", systemImage: "app")
            MovoInfoRow("版本", value: "1.0 (1)", systemImage: "number")
        }
        .task { await reload() }
    }

    private var microphoneText: String {
        switch speechCapability?.mic {
        case .granted: "已允许"
        case .denied: "已拒绝"
        case .restricted: "被系统限制"
        default: "还没有决定"
        }
    }

    private func reload() async {
        deleted = await env.store.recentlyDeleted()
        speechCapability = await env.speech.capability(locale: Locale(identifier: "zh-Hans"))
    }

    /// 从现存实体重建搜索索引（T0.8 的维护入口）
    private func rebuildIndex() async {
        let repository = env.store.repository
        try? await repository.removeAllSearchDocuments()
        let plans = await repository.allPlans()
        let tasks = await repository.allTasks()
        let notes = await repository.allNotes()
        let activities = await repository.allActivities()
        let measurements = await repository.allMeasurements()

        var stages: [Stage] = []
        var metrics: [PlanMetric] = []
        for plan in plans {
            stages += await repository.stages(planID: plan.id)
            metrics += await repository.metrics(planID: plan.id)
        }

        var docs: [SearchDocument] = []
        docs += plans.map {
            Self.document($0, type: .plan, planID: $0.id, title: $0.name,
                          body: $0.goalText ?? "")
        }
        docs += stages.map {
            Self.document($0, type: .stage, planID: $0.planId, title: $0.name,
                          body: $0.criteriaText ?? "")
        }
        docs += metrics.map {
            Self.document($0, type: .metric, planID: $0.planId, title: $0.name, body: $0.unit)
        }
        docs += tasks.map {
            Self.document($0, type: .task, planID: $0.planId, title: $0.title,
                          body: [$0.notes ?? "", $0.tags.joined(separator: " ")]
                            .filter { !$0.isEmpty }.joined(separator: " "))
        }
        docs += notes.map {
            Self.document($0, type: .note, planID: $0.planId, title: $0.text, body: "")
        }
        docs += activities.map {
            Self.document($0, type: .activity, planID: $0.planId,
                          title: $0.text ?? "行动记录", body: $0.text ?? "")
        }
        docs += measurements.map {
            Self.document($0, type: .measurement, planID: $0.planId,
                          title: "\(PlanEditScreen.numberText($0.value))\($0.unit)",
                          body: $0.note ?? "")
        }

        for doc in docs { try? await repository.upsertSearchDocument(doc) }
    }

    private static func document<T: RevisionedEntity>(_ entity: T, type: EntityType,
                                                      planID: UUID?, title: String,
                                                      body: String) -> SearchDocument {
        SearchDocument(id: entity.id, entityType: type, entityId: entity.id, planID: planID,
                       title: title, body: body,
                       tokens: SearchTokenizer.tokens(for: title + " " + body),
                       updatedAt: entity.searchUpdatedAt)
    }
}
