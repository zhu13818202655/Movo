//
//  AppEnvironment.swift
//  App
//
//  应用级依赖容器：DomainStore（唯一写入者）+ 智能层服务 + 采集管线状态。
//  双端共享；不包含任何视图代码。
//

import Foundation
import Observation
import SwiftUI
import MovoKit

@MainActor
@Observable
public final class AppEnvironment {

    // MARK: 核心

    public let store: DomainStore
    public let defaults: AppDefaults
    public let catalog: ModelCatalog
    public let keyStore: any AIKeyStore
    public let speech: any SpeechTranscriptionService
    /// 通知排期写入端（系统通知中心 / 内存替身）
    public let notificationScheduler: any NotificationScheduling

    // MARK: 同步（P3）

    /// 同步引擎（未激活时为 nil：只在账号可用后构造，见 9.6）
    public private(set) var syncEngine: SyncEngine?
    /// 最近一次查询到的 iCloud 账号状态
    public private(set) var syncAccount: CloudAccountState = .unknown
    /// 最近一次往返收据
    public private(set) var lastSyncReport: SyncPassReport?
    /// 待处理冲突数（UI 角标）
    public private(set) var pendingConflictCount = 0

    // MARK: 通知偏好（10.9）

    /// 锁屏是否隐藏任务详情（写系统通知时用，跨端一致）
    public var notificationsHideDetails: Bool {
        didSet {
            UserDefaults.standard.set(notificationsHideDetails,
                                      forKey: AppEnvironment.hideDetailsKey)
        }
    }

    static let hideDetailsKey = "movo.notifications.hideDetails"

    private var networkMonitor: NetworkMonitor?

    // MARK: 通知深链（T0.12）

    /// 通知点击后的目标（RootView 观察并跳转）
    public let notificationRouter = NotificationRouter()
    /// 系统通知代理（强引用持有；装配见 NotificationHandling.swift）
    var notificationDelegate: MovoNotificationDelegate?

    // MARK: AI 选择（8.5）

    /// 全局 AI 开关
    public var globalAIEnabled: Bool {
        didSet {
            guard oldValue != globalAIEnabled else { return }
            persistAISettings()
        }
    }

    /// 隐私告知状态（开启 AI 或首次使用时已告知）
    public var hasShownPrivacyNotice: Bool {
        didSet {
            guard oldValue != hasShownPrivacyNotice else { return }
            persistAISettings()
        }
    }

    /// 当前厂商：内置 DeepSeek 或用户自定义（OpenAI 兼容）。切换后自动回落该厂商默认模型。
    public var vendor: AIVendor {
        didSet {
            guard oldValue != vendor else { return }
            model = Self.defaultModel(for: vendor, catalog: catalog, custom: customProvider)
            persistAISettings()
        }
    }

    /// 当前模型 id。内置厂商取自目录；自定义厂商等于用户填写的模型 ID。
    public var model: String {
        didSet {
            guard oldValue != model else { return }
            persistAISettings()
        }
    }

    /// 自定义厂商的 Base URL 与模型 ID（Key 只经 `AIKeyStore` 进钥匙串）。
    public var customProvider: CustomProviderConfig {
        didSet {
            guard oldValue != customProvider else { return }
            if vendor == .custom { model = customProvider.trimmedModelID }
            persistAISettings()
        }
    }

    /// 选择与自定义配置的持久化。preview / 测试用内存实现，不写真实偏好。
    private let aiSettingsStore: any AISettingsStore

    // MARK: 结果与撤销（C9）

    /// 最近一次批量结果条
    public var lastBatchNotice: ChangeNotification?
    /// 最近一次整理的产出（M02 系列）
    public var lastPreparation: ProposalPreparation?
    /// 最近一次错误（统一横幅渲染）
    public var lastError: MovoError?
    /// 系统「用 Movo 打开」传来的计划文件，由导入页读取后清空
    public var pendingImportURL: URL?
    /// AI 调用用量（8.8：只记录元数据，不含任何正文）
    public var usageLog: [AIUsageRecord] = []

    // MARK: 采集管线（6.1）

    public var activeCaptureID: UUID?
    public var captureText: String = "" {
        didSet { capturePreferences?.set(captureText, forKey: "movo.capture.draft") }
    }
    public var capturePlanID: UUID? {
        didSet { capturePreferences?.set(capturePlanID?.uuidString, forKey: "movo.capture.plan") }
    }
    public var captureInputMode: InputMode = .text
    public var isSubmittingCapture = false
    public var captureResults: [UUID: ProposalPreparation] = [:]
    var savedProposals: [UUID: AIProposal] = [:]
    @ObservationIgnored let capturePreferences: UserDefaults?
    public var isProcessing = false
    public var lastTranscript: TranscriptFinal?

    /// 频率编辑的待确认草稿（编辑器 → M09-FrequencyPreview 影响预览）
    public var pendingRecurrence: RecurrenceDraft?

    private var speechSession: SpeechSession?

    // MARK: - 初始化

    public init(store: DomainStore,
                defaults: AppDefaults,
                catalog: ModelCatalog,
                keyStore: any AIKeyStore,
                speech: any SpeechTranscriptionService,
                notificationScheduler: any NotificationScheduling = LocalNotificationScheduler(),
                aiSettingsStore: any AISettingsStore = InMemoryAISettingsStore(),
                vendor: AIVendor? = nil, capturePreferences: UserDefaults? = nil) {
        self.store = store
        self.defaults = defaults
        self.catalog = catalog
        self.keyStore = keyStore
        self.speech = speech
        self.notificationScheduler = notificationScheduler
        self.aiSettingsStore = aiSettingsStore
        self.capturePreferences = capturePreferences
        self.captureText = capturePreferences?.string(forKey: "movo.capture.draft") ?? ""
        self.capturePlanID = capturePreferences?.string(forKey: "movo.capture.plan").flatMap(UUID.init(uuidString:))
        self.activeCaptureID = capturePreferences?.string(forKey: "movo.capture.active").flatMap(UUID.init(uuidString:))
        if let data = capturePreferences?.data(forKey: "movo.capture.proposals"),
           let proposals = try? JSONDecoder().decode([UUID: AIProposal].self, from: data) {
            self.savedProposals = proposals
        }

        let saved = aiSettingsStore.load()
        self.globalAIEnabled = saved.globalAIEnabled
        self.hasShownPrivacyNotice = saved.hasShownPrivacyNotice
        let resolvedVendor = vendor ?? saved.vendor
        self.vendor = resolvedVendor
        self.customProvider = saved.custom
        self.model = Self.initialModel(for: resolvedVendor, catalog: catalog, saved: saved)
        self.notificationsHideDetails =
            (UserDefaults.standard.object(forKey: AppEnvironment.hideDetailsKey) as? Bool)
            ?? defaults.notifications.lockScreenHideDetails
    }

    /// 启动时的模型：自定义厂商取用户配置；内置厂商优先沿用上次选择，失效则回落目录首项。
    private static func initialModel(for vendor: AIVendor,
                                     catalog: ModelCatalog,
                                     saved: AISettings) -> String {
        switch vendor {
        case .custom:
            return saved.custom.trimmedModelID
        case .deepseek:
            let available = catalog.entry(for: vendor)?.models.map(\.id) ?? []
            return available.contains(saved.model) ? saved.model : (available.first ?? "")
        }
    }

    private static func defaultModel(for vendor: AIVendor,
                                     catalog: ModelCatalog,
                                     custom: CustomProviderConfig) -> String {
        AIProviderResolver.defaultModel(vendor: vendor, catalog: catalog, custom: custom)
    }

    private func persistAISettings() {
        aiSettingsStore.save(AISettings(globalAIEnabled: globalAIEnabled,
                                        hasShownPrivacyNotice: hasShownPrivacyNotice,
                                        vendor: vendor, model: model, custom: customProvider))
    }

    // MARK: - 同步与通知（P3 / T0.12）

    /// 通知服务（取数 → 排期 → 系统通知中心）
    public var notificationService: NotificationCenterService {
        NotificationCenterService(repository: store.repository,
                                  scheduler: notificationScheduler,
                                  defaults: defaults)
    }

    /// 构造并启动同步引擎（幂等）。后端在无 iCloud 环境会自动降级为 `.unavailable`，
    /// 本机功能不受影响（PRD 19 / 9.1）。
    public func activateSync(backend: (any SyncBackend)? = nil,
                             enableNetworkMonitoring: Bool = true) async {
        guard syncEngine == nil else { return }
        // 未配置 iCloud 容器（entitlement 缺失 / 未签名构建）时**完全不构造后端**：
        // CKContainer.default() 会抛 ObjC 异常终止进程，且 Swift 无法捕获。
        // 此处降级为 .unavailable，本机功能不受影响（PRD 19 / 9.1）。
        guard let resolved = backend ?? CloudKitSyncBackend.makeDefault() else {
            syncAccount = .unavailable
            store.updateSyncState(.notSignedIn)
            return
        }
        let engine = SyncEngine(
            repository: store.repository,
            backend: resolved,
            defaults: defaults,
            deviceId: store.deviceId,
            now: { Date() },
            onStateChange: { [weak self] state in
                await MainActor.run { self?.store.updateSyncState(state) }
            })
        syncEngine = engine
        if enableNetworkMonitoring {
            let monitor = NetworkMonitor { online in
                guard online else { return }
                _Concurrency.Task { await engine.trigger(debounced: true) }
            }
            networkMonitor = monitor
            monitor.start()
        }
        _ = await engine.start()
        await refreshSyncStatus()
    }

    /// 进前台等触发点：按 3s 防抖合并连续触发（9.3）。
    public func triggerSync() async {
        await syncEngine?.trigger(debounced: true)
    }

    public func stopSync() {
        networkMonitor?.cancel()
        networkMonitor = nil
    }

    /// 重新查询账号状态 / 待处理冲突数 / 最近收据，刷新给 UI。
    public func refreshSyncStatus() async {
        guard let engine = syncEngine else {
            syncAccount = .unavailable
            pendingConflictCount = 0
            store.updateSyncState(.notSignedIn)
            return
        }
        syncAccount = await engine.accountState()
        lastSyncReport = await engine.lastReport()
        pendingConflictCount = await engine.pendingConflictCount()
        store.updateSyncState(await engine.state())
    }

    /// 手动「立即同步」（设置页按钮，无防抖）。
    public func syncNow() async {
        guard let engine = syncEngine else { return }
        _ = await engine.syncNow()
        await refreshSyncStatus()
        store.updateSyncState(await engine.state())
    }

    /// 冲突裁决后把决议值幂等写回目标实体，并触发一次同步。
    @discardableResult
    public func applyResolvedConflicts() async -> Int {
        guard let engine = syncEngine else { return 0 }
        let applied = await engine.applyResolvedConflicts()
        _ = await engine.syncNow()
        await refreshSyncStatus()
        store.updateSyncState(await engine.state())
        return applied
    }

    /// 重新计算并写入系统通知（数据变更后调用，幂等覆盖）。
    @discardableResult
    public func refreshNotifications() async -> [PlannedNotification] {
        await notificationService.refresh(now: store.now,
                                          timeZone: store.currentTimeZone,
                                          today: store.today,
                                          hideDetails: notificationsHideDetails)
    }

    /// 生产环境：SwiftData 落盘 + Keychain。
    public static func live() -> AppEnvironment {
        let defaults = ConfigLoader.loadDefaults()
        let catalog = ConfigLoader.loadModelCatalog()
        let repository: any DomainRepository
        do {
            repository = try SwiftDataRepository.applicationDefault()
        } catch {
            // 落盘失败时退化为内存仓库，保证可启动（数据不持久）
            repository = (try? SwiftDataRepository.inMemory()) ?? InMemoryRepository()
        }
        let store = DomainStore(repository: repository, defaults: defaults)
        return AppEnvironment(store: store, defaults: defaults, catalog: catalog,
                              keyStore: KeychainAIKeyStore(),
                              speech: AppleSpeechTranscriptionService(defaults: defaults),
                              aiSettingsStore: UserDefaultsAISettingsStore(), capturePreferences: .standard)
    }

    /// 预览/测试环境：内存仓库 + 内存 Keychain + 内存 AI 偏好。
    public static func preview(today: Date? = nil,
                               vendor: AIVendor? = nil) -> AppEnvironment {
        let defaults = ConfigLoader.loadDefaults()
        let catalog = ConfigLoader.loadModelCatalog()
        let clock: MovoClock = today.map { TravelClock($0) } ?? SystemClock()
        let repository = InMemoryRepository()
        let store = DomainStore(repository: repository, clock: clock, defaults: defaults)
        return AppEnvironment(store: store, defaults: defaults, catalog: catalog,
                              keyStore: InMemoryAIKeyStore(), speech: MockSpeechTranscriptionService(),
                              notificationScheduler: InMemoryNotificationScheduler(),
                              aiSettingsStore: InMemoryAISettingsStore(),
                              vendor: vendor)
    }

    // MARK: - AI 提供商（8.2 / 8.5）

    /// 该厂商当前可选的模型。自定义厂商只有用户填写的那个模型 ID。
    public func availableModels(for vendor: AIVendor? = nil) -> [ModelInfo] {
        let target = vendor ?? self.vendor
        switch target {
        case .deepseek:
            return (catalog.entry(for: .deepseek)?.models ?? []).map(ModelInfo.init(entry:))
        case .custom:
            let id = customProvider.trimmedModelID
            return id.isEmpty ? [] : [ModelInfo(id: id, displayName: id)]
        }
    }

    public func hasKey(for vendor: AIVendor? = nil) -> Bool {
        let target = vendor ?? self.vendor
        return (keyStore.key(vendor: target)?.isEmpty == false)
    }

    /// 该厂商是否既填了 Key、又（对自定义厂商）填完了 Base URL 与模型 ID。
    public func isConfigured(for vendor: AIVendor? = nil) -> Bool {
        let target = vendor ?? self.vendor
        guard hasKey(for: target) else { return false }
        return target == .custom ? customProvider.isComplete : true
    }

    /// 未就绪时的错误：区分「没有 Key」与「自定义厂商没填完」。
    public func configurationError(for vendor: AIVendor? = nil) -> MovoError {
        let target = vendor ?? self.vendor
        if target == .custom, !customProvider.isComplete {
            return .providerNotConfigured(vendor: .custom)
        }
        return .noKey(vendor: target)
    }

    public func maskedKey(for vendor: AIVendor? = nil) -> String? {
        guard let key = keyStore.key(vendor: vendor ?? self.vendor), !key.isEmpty else { return nil }
        return AIKeyFormat.mask(key)
    }

    public func saveKey(_ key: String, vendor: AIVendor? = nil) throws {
        try keyStore.save(key, vendor: vendor ?? self.vendor)
    }

    public func deleteKey(vendor: AIVendor? = nil) throws {
        try keyStore.delete(vendor: vendor ?? self.vendor)
    }

    /// 8.1 设置页"测试连接"。自定义厂商未配置完整时抛 `.providerNotConfigured`。
    public func testConnection(vendor: AIVendor? = nil, model: String? = nil) async throws {
        let provider = try makeProvider(vendor: vendor, model: model)
        try await provider.testConnection()
    }

    public func makeProvider(vendor: AIVendor? = nil, model: String? = nil) throws -> any AIProvider {
        let target = vendor ?? self.vendor
        let chosen = model ?? (target == self.vendor ? self.model : nil)
        let resolved = try AIProviderResolver.resolve(vendor: target, catalog: catalog,
                                                      custom: customProvider, model: chosen)
        return OpenAICompatibleAdapter(resolved: resolved, keyStore: keyStore, defaults: defaults)
    }

    public func makeProposalService(vendor: AIVendor? = nil, model: String? = nil) throws -> ProposalService {
        let target = vendor ?? self.vendor
        let chosen = model ?? (target == self.vendor ? self.model : nil)
        return try ProposalService.make(vendor: target, keyStore: keyStore, catalog: catalog,
                                        custom: customProvider, defaults: defaults, model: chosen)
    }

    // MARK: - 撤销

    public func undoLastBatch() async {
        guard let batchID = lastBatchNotice?.batchID else { return }
        do {
            let result = try await store.undo(batchID: batchID)
            lastBatchNotice = nil
            if !result.unsafeOperations.isEmpty || !result.nonUndoableOperations.isEmpty {
                lastError = .invalidStructure(reason: result.summaryText)
            }
        } catch let error as MovoError {
            lastError = error
        } catch {
            lastError = .invalidStructure(reason: "撤销没有完成，请稍后重试。")
        }
    }

    public func clearNotice() { lastBatchNotice = nil }

    /// 记录一次 AI 调用用量（只保留最近 20 条元数据）
    public func recordUsage(_ record: AIUsageRecord?) {
        guard let record else { return }
        usageLog.insert(record, at: 0)
        if usageLog.count > 20 { usageLog.removeLast(usageLog.count - 20) }
    }

    // MARK: - 语音会话（7.3）

    public func startSpeechSession(locale: Locale = Locale(identifier: "zh-Hans")) -> SpeechSession {
        let session = speech.makeSession(locale: locale)
        speechSession = session
        return session
    }

    public func endSpeechSession() {
        speechSession = nil
        lastTranscript = nil
    }

    public var currentSpeechSession: SpeechSession? { speechSession }

    // MARK: - 常用动作（供各页面复用）

    /// 今日完成开关：一次性任务完成 vs Occurrence 当次完成（事件不同）
    public func toggleCompletion(of item: TodayItem) async {
        do {
            switch item.completionTarget {
            case .occurrence(let occurrenceID):
                guard let occurrence = await store.repository.occurrence(occurrenceID) else { return }
                if occurrence.status == .done {
                    _ = try await store.execute(SkipOccurrence(occurrenceID: occurrenceID,
                                                               at: .precise(store.now),
                                                               baseRevision: occurrence.revision))
                } else {
                    _ = try await store.execute(CompleteOccurrence(occurrenceID: occurrenceID,
                                                                   at: .precise(store.now),
                                                                   baseRevision: occurrence.revision))
                }
            case .task(let taskID):
                guard let task = await store.repository.task(taskID) else { return }
                if task.status == .done {
                    _ = try await store.execute(ReopenTask(taskID: taskID, baseRevision: task.revision))
                } else {
                    _ = try await store.execute(CompleteTask(taskID: taskID, at: .precise(store.now),
                                                             baseRevision: task.revision))
                }
            }
            lastBatchNotice = store.lastNotification
        } catch let error as MovoError {
            lastError = error
        } catch {
            lastError = .invalidStructure(reason: "这次操作没有完成。")
        }
    }

    /// 待办手动快捷新增（D01 / M01 输入入口）
    @discardableResult
    public func quickAddTask(title: String, scheduledToday: Bool = false) async -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let result = try await store.execute(CreateTask(
                title: trimmed,
                startAt: scheduledToday ? TimePoint.day(store.today) : nil,
                source: .manual))
            lastBatchNotice = store.lastNotification
            return result.entityID
        } catch let error as MovoError {
            lastError = error
            return nil
        } catch {
            lastError = .invalidStructure(reason: "没有添加成功。")
            return nil
        }
    }

    /// 生成模板任务（REQ 14 / 16）
    public func makeTemplate(title: String, planID: UUID, rule: RecurrenceDraft) async {
        do {
            try await store.execute(CreateTask(title: title, planID: planID,
                                               recurrence: rule, source: .manual))
            lastBatchNotice = store.lastNotification
        } catch let error as MovoError {
            lastError = error
        } catch {
            lastError = .invalidStructure(reason: "没有生成成功。")
        }
    }
}
