//
//  Support.swift
//  Domain
//
//  可注入的 Clock / TimeZone（12.1：时间旅行测试跨月、跨时区、夏令时）
//

import Foundation

/// 可注入时钟。领域层不直接调用 Date()。
public protocol MovoClock: Sendable {
    func now() -> Date
}

public struct SystemClock: MovoClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// 测试用时间旅行时钟：固定时刻，可推进。
public final class TravelClock: MovoClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date) { self.current = start }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }

    /// 推进 n 天（按当前时区）
    public func advance(days: Int, in tz: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        lock.lock(); defer { lock.unlock() }
        current = cal.date(byAdding: .day, value: days, to: current) ?? current
    }
}

/// 时区提供者：所有"今天"的判定都经此，便于跨时区测试。
public protocol TimeZoneProvider: Sendable {
    func current() -> TimeZone
}

public struct SystemTimeZoneProvider: TimeZoneProvider {
    public init() {}
    public func current() -> TimeZone { TimeZone.current }
}

public struct FixedTimeZoneProvider: TimeZoneProvider {
    private let tz: TimeZone
    public init(_ tz: TimeZone) { self.tz = tz }
    public init(identifier: String) { self.tz = TimeZone(identifier: identifier) ?? .gmt }
    public func current() -> TimeZone { tz }
}

/// 设备标识（同步用）。稳定、可注入。
public protocol DeviceIDProvider: Sendable {
    func deviceID() -> String
}

public struct StoredDeviceIDProvider: DeviceIDProvider {
    private let key = "movo.device.id"

    public init() {}

    public func deviceID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key) { return existing }
        let generated = "dev-" + UUID().uuidString.prefix(8).lowercased()
        defaults.set(generated, forKey: key)
        return generated
    }
}

public struct FixedDeviceIDProvider: DeviceIDProvider {
    private let id: String
    public init(_ id: String) { self.id = id }
    public func deviceID() -> String { id }
}

// MARK: - 配置装载（Config/*.json）

public struct AppDefaults: Sendable, Codable {
    public struct Notifications: Sendable, Codable {
        public var timedTaskLeadMinutes: Int
        public var dateOnlyTaskHour: Int
        public var dateOnlyTaskMinute: Int
        public var hardDeadlineLeadDays: Int
        public var hardDeadlineSameDayHour: Int
        public var hardDeadlineSameDayMinute: Int
        public var quietHoursStart: Int
        public var quietHoursEnd: Int
        public var aggregationWindowMinutes: Int
        public var weeklyReviewWeekday: Int
        public var weeklyReviewHour: Int
        public var weeklyReviewMinute: Int
        public var blockedReminderEnabled: Bool
        public var blockedRescheduleThreshold: Int
        public var lockScreenHideDetails: Bool

        enum CodingKeys: String, CodingKey {
            case timedTaskLeadMinutes = "timed_task_lead_minutes"
            case dateOnlyTaskHour = "date_only_task_hour"
            case dateOnlyTaskMinute = "date_only_task_minute"
            case hardDeadlineLeadDays = "hard_deadline_lead_days"
            case hardDeadlineSameDayHour = "hard_deadline_same_day_hour"
            case hardDeadlineSameDayMinute = "hard_deadline_same_day_minute"
            case quietHoursStart = "quiet_hours_start"
            case quietHoursEnd = "quiet_hours_end"
            case aggregationWindowMinutes = "aggregation_window_minutes"
            case weeklyReviewWeekday = "weekly_review_weekday"
            case weeklyReviewHour = "weekly_review_hour"
            case weeklyReviewMinute = "weekly_review_minute"
            case blockedReminderEnabled = "blocked_reminder_enabled"
            case blockedRescheduleThreshold = "blocked_reschedule_threshold"
            case lockScreenHideDetails = "lock_screen_hide_details"
        }
    }

    public struct AI: Sendable, Codable {
        public var classificationConfidenceThreshold: Double
        public var classificationMarginThreshold: Double
        public var maxItemsPerInput: Int
        public var maxTextCharacters: Int
        public var recentTaskTitlesLimit: Int
        public var contextTasksLimit: Int
        public var connectTimeoutSeconds: Double
        public var totalTimeoutSeconds: Double
        public var autoRetryCount: Int
        public var autoRetryBackoffSeconds: [Double]
        public var progressMustShowAfterSeconds: Double

        enum CodingKeys: String, CodingKey {
            case classificationConfidenceThreshold = "classification_confidence_threshold"
            case classificationMarginThreshold = "classification_margin_threshold"
            case maxItemsPerInput = "max_items_per_input"
            case maxTextCharacters = "max_text_characters"
            case recentTaskTitlesLimit = "recent_task_titles_limit"
            case contextTasksLimit = "context_tasks_limit"
            case connectTimeoutSeconds = "connect_timeout_seconds"
            case totalTimeoutSeconds = "total_timeout_seconds"
            case autoRetryCount = "auto_retry_count"
            case autoRetryBackoffSeconds = "auto_retry_backoff_seconds"
            case progressMustShowAfterSeconds = "progress_must_show_after_seconds"
        }
    }

    public struct Capture: Sendable, Codable {
        public var maxRecordingSeconds: Double
        public var stopFinalSegmentTimeoutSeconds: Double
        public var audioRetentionHours: Int
        public var audioRetentionDefault: String

        enum CodingKeys: String, CodingKey {
            case maxRecordingSeconds = "max_recording_seconds"
            case stopFinalSegmentTimeoutSeconds = "stop_final_segment_timeout_seconds"
            case audioRetentionHours = "audio_retention_hours"
            case audioRetentionDefault = "audio_retention_default"
        }
    }

    public struct Sync: Sendable, Codable {
        public var recordStateJSONLimitBytes: Int
        public var eventPushBatchSize: Int
        public var debounceSeconds: Double

        enum CodingKeys: String, CodingKey {
            case recordStateJSONLimitBytes = "record_state_json_limit_bytes"
            case eventPushBatchSize = "event_push_batch_size"
            case debounceSeconds = "debounce_seconds"
        }
    }

    public struct Lifecycle: Sendable, Codable {
        public var tombstoneRetentionDays: Int
        enum CodingKeys: String, CodingKey { case tombstoneRetentionDays = "tombstone_retention_days" }
    }

    public var notifications: Notifications
    public var ai: AI
    public var capture: Capture
    public var sync: Sync
    public var lifecycle: Lifecycle

    /// 内置兜底值：Config 资源缺失时仍可运行（不阻塞构建）
    public static let fallback = AppDefaults(
        notifications: Notifications(
            timedTaskLeadMinutes: 0, dateOnlyTaskHour: 9, dateOnlyTaskMinute: 0,
            hardDeadlineLeadDays: 1, hardDeadlineSameDayHour: 9, hardDeadlineSameDayMinute: 0,
            quietHoursStart: 22, quietHoursEnd: 7, aggregationWindowMinutes: 15,
            weeklyReviewWeekday: 7, weeklyReviewHour: 20, weeklyReviewMinute: 0,
            blockedReminderEnabled: false, blockedRescheduleThreshold: 3, lockScreenHideDetails: true),
        ai: AI(classificationConfidenceThreshold: 0.90, classificationMarginThreshold: 0.15,
               maxItemsPerInput: 10, maxTextCharacters: 2000, recentTaskTitlesLimit: 10,
               contextTasksLimit: 30, connectTimeoutSeconds: 10, totalTimeoutSeconds: 30,
               autoRetryCount: 2, autoRetryBackoffSeconds: [1, 2], progressMustShowAfterSeconds: 15),
        capture: Capture(maxRecordingSeconds: 180, stopFinalSegmentTimeoutSeconds: 3,
                         audioRetentionHours: 24, audioRetentionDefault: "none"),
        sync: Sync(recordStateJSONLimitBytes: 65536, eventPushBatchSize: 500, debounceSeconds: 3),
        lifecycle: Lifecycle(tombstoneRetentionDays: 30))
}

/// Config 资源装载器。找不到资源时回落到内置默认，保证无资源运行也可用。
public enum ConfigLoader {
    public static func loadDefaults(bundle: Bundle = .movoResources) -> AppDefaults {
        guard let url = bundle.url(forResource: "Defaults", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppDefaults.self, from: data)
        else { return .fallback }
        return decoded
    }

    public static func loadHealthKeywords(bundle: Bundle = .movoResources) -> [String] {
        struct Doc: Decodable { let keywords: [String] }
        guard let url = bundle.url(forResource: "HealthKeywords", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Doc.self, from: data)
        else { return HealthKeywordFallback.builtin }
        return doc.keywords
    }

    public static func loadModelCatalog(bundle: Bundle = .movoResources) -> ModelCatalog {
        guard let url = bundle.url(forResource: "ModelsCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(ModelCatalog.self, from: data)
        else { return .fallback }
        return doc
    }
}

extension Bundle {
    /// Config/ 以 folder reference 打包，资源可直接在 bundle 根查找；SPM/测试环境下回落到 main。
    public static var movoResources: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }
}

final class BundleToken {}

/// 健康词表内置兜底（Config 资源不可用时）
public enum HealthKeywordFallback {
    public static let builtin: [String] = [
        "体重", "称重", "减肥", "减重", "公斤", "千克", "体脂", "腰围", "卡路里", "热量",
        "饮食", "节食", "血糖", "血压", "心率", "睡眠", "失眠", "散步", "跑步", "慢跑",
        "游泳", "骑行", "锻炼", "健身", "运动", "瑜伽", "体检", "复诊", "吃药", "服药"
    ]
}

// MARK: - 模型清单

public struct ModelCatalog: Sendable, Codable {
    public struct VendorEntry: Sendable, Codable {
        public var vendor: AIVendor
        public var displayName: String
        public var keyPrefixHint: String
        /// OpenAI 兼容的 chat completions 端点（测试连接与实际调用共用）
        public var endpoint: String
        public var models: [Entry]

        enum CodingKeys: String, CodingKey {
            case vendor, endpoint, models
            case displayName = "display_name"
            case keyPrefixHint = "key_prefix_hint"
        }
    }

    public struct Entry: Sendable, Codable, Identifiable, Hashable {
        public var id: String
        public var displayName: String
        public var contextHint: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case contextHint = "context_hint"
        }

        public init(id: String, displayName: String, contextHint: String? = nil) {
            self.id = id; self.displayName = displayName; self.contextHint = contextHint
        }
    }

    public var catalogVersion: String
    public var vendors: [VendorEntry]

    enum CodingKeys: String, CodingKey {
        case vendors
        case catalogVersion = "catalog_version"
    }

    /// 内置兜底：仅 DeepSeek。自定义厂商不进入目录，由用户配置提供端点与模型。
    public static let fallback = ModelCatalog(catalogVersion: "fallback", vendors: [
        VendorEntry(vendor: .deepseek, displayName: "DeepSeek", keyPrefixHint: "sk-",
                    endpoint: "https://api.deepseek.com/v1/chat/completions",
                    models: [
                        Entry(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro",
                              contextHint: "结构化输出更稳，适合复杂整理"),
                        Entry(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash",
                              contextHint: "更快更省，适合日常短句整理")
                    ])
    ])

    public func entry(for vendor: AIVendor) -> VendorEntry? {
        vendors.first { $0.vendor == vendor }
    }
}
