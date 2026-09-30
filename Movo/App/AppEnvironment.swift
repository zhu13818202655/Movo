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

    public var vendor: AIVendor
    public var model: String

    // MARK: 结果与撤销（C9）

    /// 最近一次批量结果条
    public var lastBatchNotice: ChangeNotification?
    /// 最近一次整理的产出（M02 系列）
    public var lastPreparation: ProposalPreparation?
    /// 最近一次错误（统一横幅渲染）
    public var lastError: MovoError?
    /// AI 调用用量（8.8：只记录元数据，不含任何正文）
    public var usageLog: [AIUsageRecord] = []

    // MARK: 采集管线（6.1）

    public var activeCaptureID: UUID?
    public var captureText: String = ""
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
                vendor: AIVendor = .openai) {
        self.store = store
        self.defaults = defaults
        self.catalog = catalog
        self.keyStore = keyStore
        self.speech = speech
        self.notificationScheduler = notificationScheduler
        self.vendor = vendor
        self.model = catalog.entry(for: vendor)?.models.first?.id ?? ""
        self.notificationsHideDetails =
            (UserDefaults.standard.object(forKey: AppEnvironment.hideDetailsKey) as? Bool)
            ?? defaults.notifications.lockScreenHideDetails
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
                              speech: AppleSpeechTranscriptionService(defaults: defaults))
    }

    /// 预览/测试环境：内存仓库 + 内存 Keychain。
    public static func preview(today: Date? = nil,
                               vendor: AIVendor = .openai) -> AppEnvironment {
        let defaults = ConfigLoader.loadDefaults()
        let catalog = ConfigLoader.loadModelCatalog()
        let clock: MovoClock = today.map { TravelClock($0) } ?? SystemClock()
        let repository = InMemoryRepository()
        let store = DomainStore(repository: repository, clock: clock, defaults: defaults)
        return AppEnvironment(store: store, defaults: defaults, catalog: catalog,
                              keyStore: InMemoryAIKeyStore(), speech: MockSpeechTranscriptionService(),
                              notificationScheduler: InMemoryNotificationScheduler(),
                              vendor: vendor)
    }

    // MARK: - AI 提供商（8.2 / 8.5）

    public func availableModels() -> [ModelInfo] {
        (catalog.entry(for: vendor)?.models ?? []).map(ModelInfo.init(entry:))
    }

    public func hasKey(for vendor: AIVendor? = nil) -> Bool {
        let target = vendor ?? self.vendor
        return (keyStore.key(vendor: target)?.isEmpty == false)
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

    /// 8.1 设置页"测试连接"
    public func testConnection(vendor: AIVendor? = nil, model: String? = nil) async throws {
        let target = vendor ?? self.vendor
        let provider = makeProvider(vendor: target, model: model)
        try await provider.testConnection()
    }

    public func makeProvider(vendor: AIVendor? = nil, model: String? = nil) -> any AIProvider {
        let target = vendor ?? self.vendor
        let chosen = model ?? (target == self.vendor ? self.model : nil)
        switch target {
        case .openai:
            return OpenAIAdapter(keyStore: keyStore, catalog: catalog,
                                 defaults: defaults, model: chosen)
        case .claude:
            return ClaudeAdapter(keyStore: keyStore, catalog: catalog,
                                 defaults: defaults, model: chosen)
        }
    }

    public func makeProposalService(vendor: AIVendor? = nil, model: String? = nil) -> ProposalService {
        ProposalService.make(vendor: vendor ?? self.vendor, keyStore: keyStore,
                             catalog: catalog, defaults: defaults,
                             model: model ?? self.model)
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

    /// 今日快捷新增（D01 / M01 输入入口）
    @discardableResult
    public func quickAddTask(title: String, scheduledToday: Bool = true) async -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let result = try await store.execute(CreateTask(
                title: trimmed,
                scheduledDate: scheduledToday ? store.today : nil,
                source: .text))
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
