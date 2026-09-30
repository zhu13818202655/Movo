//
//  CommandTypes.swift
//  Domain/Commands
//
//  4.2 写入唯一入口：领域命令。
//  每个命令处理器在一个本地事务内：读当前状态 → 校验 → 写实体 → 追加 ChangeEvent
//  →（P3）标记待同步 → 更新搜索索引 → 返回结果。
//  重复提交同一 operationId 直接返回原结果（幂等）。
//

import Foundation

// MARK: - 可版本化 / 可索引实体

public protocol RevisionedEntity: Sendable {
    var id: UUID { get }
    var revision: Int { get set }
    static var entityType: EntityType { get }
    /// 搜索索引文档（5.3）
    var searchTitle: String { get }
    var searchBody: String { get }
    var searchPlanID: UUID? { get }
    /// 用于搜索结果的"最近活动"排序
    var searchUpdatedAt: Date { get }
}

public extension RevisionedEntity {
    var searchBody: String { "" }
    var searchPlanID: UUID? { nil }
    var searchUpdatedAt: Date { Date() }
}

extension Plan: RevisionedEntity {
    public static var entityType: EntityType { .plan }
    public var searchTitle: String { name }
    public var searchBody: String { [goalText, aliases.joined(separator: " "), contextPhrases.joined(separator: " ")]
        .compactMap { $0 }.joined(separator: " ") }
    public var searchPlanID: UUID? { id }
    public var searchUpdatedAt: Date { updatedAt }
}

extension Stage: RevisionedEntity {
    public static var entityType: EntityType { .stage }
    public var searchTitle: String { name }
    public var searchBody: String { criteriaText ?? "" }
    public var searchPlanID: UUID? { planId }
    public var searchUpdatedAt: Date { createdAt }
}

extension PlanMetric: RevisionedEntity {
    public static var entityType: EntityType { .metric }
    public var searchTitle: String { name }
    public var searchBody: String { unit }
    public var searchPlanID: UUID? { planId }
    public var searchUpdatedAt: Date { createdAt }
}

extension Task: RevisionedEntity {
    public static var entityType: EntityType { .task }
    public var searchTitle: String { title }
    public var searchBody: String { [notes, tags.joined(separator: " ")].compactMap { $0 }.joined(separator: " ") }
    public var searchPlanID: UUID? { planId }
    public var searchUpdatedAt: Date { updatedAt }
}

extension RecurrenceRule: RevisionedEntity {
    public static var entityType: EntityType { .rule }
    public var searchTitle: String { ruleDescription }
    public var searchPlanID: UUID? { nil }
    public var searchUpdatedAt: Date { createdAt }
}

extension RecurrenceOccurrence: RevisionedEntity {
    public static var entityType: EntityType { .occurrence }
    public var searchTitle: String { scheduledOn?.iso8601DateString ?? occurredOn?.iso8601DateString ?? "" }
    public var searchPlanID: UUID? { planId }
    public var searchUpdatedAt: Date { doneAt ?? Date(timeIntervalSince1970: 0) }
}

extension ActionRecord: RevisionedEntity {
    public static var entityType: EntityType { .activity }
    public var searchTitle: String { text ?? "行动记录" }
    public var searchBody: String { text ?? "" }
    public var searchPlanID: UUID? { planId }
    public var searchUpdatedAt: Date { recordedAt }
}

extension Measurement: RevisionedEntity {
    public static var entityType: EntityType { .measurement }
    public var searchTitle: String {
        let v = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return "\(v)\(unit)"
    }
    public var searchBody: String { note ?? "" }
    public var searchPlanID: UUID? { planId }
    public var searchUpdatedAt: Date { recordedAt }
}

extension Note: RevisionedEntity {
    public static var entityType: EntityType { .note }
    public var searchTitle: String { text }
    public var searchPlanID: UUID? { planId }
    public var searchUpdatedAt: Date { capturedAt }
}

extension Capture: RevisionedEntity {
    public static var entityType: EntityType { .capture }
    public var searchTitle: String { String(effectiveText.prefix(60)) }
    public var searchBody: String { effectiveText }
    public var searchUpdatedAt: Date { capturedAt }
}

extension OperationBatch: RevisionedEntity {
    public static var entityType: EntityType { .batch }
    public var searchTitle: String { summary }
    public var searchUpdatedAt: Date { createdAt }
}

extension Operation: RevisionedEntity {
    public static var entityType: EntityType { .operation }
    public var searchTitle: String { kind.displayName }
    public var searchUpdatedAt: Date { createdAt }
}

extension Suggestion: RevisionedEntity {
    public static var entityType: EntityType { .suggestion }
    public var searchTitle: String { text }
    public var searchBody: String { sourceText ?? "" }
    public var searchPlanID: UUID? { planId }
    public var searchUpdatedAt: Date { createdAt }
}

extension ReviewNote: RevisionedEntity {
    public static var entityType: EntityType { .reviewNote }
    public var searchTitle: String { text }
    public var searchPlanID: UUID? { planId }
    public var searchUpdatedAt: Date { createdAt }
}

extension SyncConflict: RevisionedEntity {
    public static var entityType: EntityType { .conflict }
    public var searchTitle: String { field }
    public var searchUpdatedAt: Date { detectedAt }
}

extension Tombstone: RevisionedEntity {
    public static var entityType: EntityType { .tombstone }
    public var searchTitle: String { entityType.displayName }
    public var searchUpdatedAt: Date { deletedAt }
}

// MARK: - 命令协议

public protocol DomainCommand: Sendable {
    /// 幂等键：重试复用；同 ID 重复提交直接返回首次结果
    var operationID: UUID { get }
    var kind: OperationKind { get }
    /// 目标对象（创建类在提交前生成）
    var entityID: UUID { get }
    var entityType: EntityType { get }
    /// 执行时读取到的版本（乐观锁与撤销校验用）
    var baseRevision: Int { get }

    /// 在 `DomainStore` 提供的事务上下文内执行。上下文为主 actor 隔离，
    /// 与 1.3 的事务边界约定一致（事务体固定执行在主 ModelContext）。
    @MainActor
    func execute(in context: CommandContext) async throws -> CommandResult
}

public extension DomainCommand {
    var baseRevision: Int { 0 }
}

public struct CommandResult: Hashable, Sendable {
    public var operationID: UUID
    public var entityID: UUID?
    public var changedFields: [String]
    public var userMessage: String
    public var newRevision: Int
    /// 补记时：事件的实际发生时间
    public var occurredAt: Date?

    public init(operationID: UUID, entityID: UUID? = nil, changedFields: [String] = [],
                userMessage: String, newRevision: Int = 1, occurredAt: Date? = nil) {
        self.operationID = operationID; self.entityID = entityID
        self.changedFields = changedFields; self.userMessage = userMessage
        self.newRevision = newRevision; self.occurredAt = occurredAt
    }
}

public struct BatchInput: Sendable {
    public var batchID: UUID
    public var captureId: UUID?
    public var source: BatchSource
    public var commands: [any DomainCommand]
    public var summary: String
    public var deviceId: String?

    public init(batchID: UUID = UUID(), captureId: UUID? = nil, source: BatchSource = .userManual,
                commands: [any DomainCommand], summary: String = "", deviceId: String? = nil) {
        self.batchID = batchID; self.captureId = captureId; self.source = source
        self.commands = commands; self.summary = summary; self.deviceId = deviceId
    }
}

public struct BatchRejection: Hashable, Sendable {
    public var operationID: UUID
    public var entityID: UUID?
    public var reason: String
    public init(operationID: UUID, entityID: UUID? = nil, reason: String) {
        self.operationID = operationID; self.entityID = entityID; self.reason = reason
    }
}

public struct BatchResult: Hashable, Sendable {
    public var batchID: UUID
    public var applied: [UUID]
    public var rejected: [BatchRejection]
    public var needsConfirmation: [Operation]
    public var state: BatchState
    public var summary: String

    public init(batchID: UUID, applied: [UUID] = [], rejected: [BatchRejection] = [],
                needsConfirmation: [Operation] = [], state: BatchState = .applied, summary: String = "") {
        self.batchID = batchID; self.applied = applied; self.rejected = rejected
        self.needsConfirmation = needsConfirmation; self.state = state; self.summary = summary
    }

    public var appliedCount: Int { applied.count }

    /// "已添加 2 项，可撤销" / "3项已处理，1项需要选择计划"
    public var resultBanner: String {
        guard !rejected.isEmpty else { return "已整理 \(applied.count) 项 · 可撤销" }
        return "\(applied.count)项已处理，\(rejected.count)项需要你确认"
    }
}

// MARK: - 执行上下文

/// 命令执行上下文。`DomainStore` 在**一个事务内**构造它并交给命令。
/// 所有写入、事件追加、索引更新都经由这里，保证"唯一写入口"。
@MainActor
public final class CommandContext {
    public let repository: DomainRepository
    public let now: Date
    public let today: DateOnly
    public let timeZone: TimeZone
    public let defaults: AppDefaults
    public let deviceId: String
    public let operationID: UUID
    public let batchID: UUID
    /// 命令声明的基准版本（乐观锁）
    public let declaredBaseRevision: Int

    public private(set) var changedFields: [String] = []
    public private(set) var patch: [String: FieldPatch] = [:]
    public private(set) var primaryEntityID: UUID?
    public private(set) var primaryEntityType: EntityType?
    public private(set) var occurredAt: Date?
    public private(set) var userMessage: String = ""
    public private(set) var newRevision: Int = 1
    public private(set) var touchedEntityIDs: Set<UUID> = []
    /// 撤销 create* 时需要真删的对象
    public private(set) var hardDeleted: [(EntityType, UUID)] = []
    public private(set) var tombstoneRequests: [Tombstone] = []
    public private(set) var recordedReason: String?

    /// 释放的依赖数（删除/移动预览用）
    public private(set) var releasedDependencyCount: Int = 0

    public init(repository: DomainRepository, now: Date, today: DateOnly, timeZone: TimeZone,
                defaults: AppDefaults, deviceId: String, operationID: UUID, batchID: UUID,
                declaredBaseRevision: Int = 0) {
        self.repository = repository; self.now = now; self.today = today; self.timeZone = timeZone
        self.defaults = defaults; self.deviceId = deviceId
        self.operationID = operationID; self.batchID = batchID
        self.declaredBaseRevision = declaredBaseRevision
    }

    // MARK: 元信息

    public func declarePrimary(_ type: EntityType, _ id: UUID) {
        if primaryEntityID == nil { primaryEntityID = id; primaryEntityType = type }
    }

    public func setUserMessage(_ message: String) { userMessage = message }
    public func setOccurredAt(_ date: Date) { occurredAt = date }
    public func setReason(_ reason: String?) { recordedReason = reason }
    public func addReleasedDependencies(_ n: Int) { releasedDependencyCount += n }
    public func requestTombstone(_ tombstone: Tombstone) { tombstoneRequests.append(tombstone) }
    public func hardDelete(_ type: EntityType, _ id: UUID) { hardDeleted.append((type, id)) }

    // MARK: 乐观锁

    /// baseRevision 必须等于读取时的 revision，否则报版本冲突（3.4）
    public func assertRevision(expected: Int, actual: Int, entityID: UUID) throws {
        if expected > 0 && expected != actual {
            throw MovoError.versionConflict(entityID: entityID)
        }
    }

    /// 命令声明了 baseRevision（>0）时必须与当前一致
    public func assertDeclaredRevision(actual: Int, entityID: UUID) throws {
        try assertRevision(expected: declaredBaseRevision, actual: actual, entityID: entityID)
    }

    // MARK: 写入

    /// 写入实体并追加 ChangeEvent + 更新搜索索引。
    /// - Parameters:
    ///   - entity: 新值（revision 由本方法自增）
    ///   - old: 旧值（nil 表示新建）
    @discardableResult
    public func write<T: RevisionedEntity & Encodable>(_ entity: T, old: T?) async throws -> T {
        var new = entity
        new.revision = (old?.revision ?? 0) + 1

        let diff = try JSONDiff.diff(old: old, new: new)
        await persist(new)
        await index(new)

        try await recordEvent(entityType: T.entityType, entityID: new.id,
                              fields: diff.fields, patch: diff.patch,
                              baseRevision: old?.revision ?? 0, newRevision: new.revision)

        mergeChangedFields(diff.fields)
        newRevision = new.revision
        touchedEntityIDs.insert(new.id)
        declarePrimary(T.entityType, new.id)
        return new
    }

    /// 只追加事件，不写实体（如依赖解析、纯状态派生变更的显式记录）
    public func recordEvent(entityType: EntityType, entityID: UUID, fields: [String],
                            patch: [String: FieldPatch], baseRevision: Int, newRevision: Int) async throws {
        let event = ChangeEvent(
            operationId: operationID, batchId: batchID, entityId: entityID, entityType: entityType,
            fields: fields, patch: patch, baseRevision: baseRevision, newRevision: newRevision,
            occurredAt: occurredAt ?? now, recordedAt: now, deviceId: deviceId, undoOf: nil, synced: false)
        try await repository.append(event)
    }

    // MARK: 私有

    private func persist<T: RevisionedEntity>(_ entity: T) async {
        switch entity {
        case let e as Plan: try? await repository.upsert(e)
        case let e as Stage: try? await repository.upsert(e)
        case let e as PlanMetric: try? await repository.upsert(e)
        case let e as Task: try? await repository.upsert(e)
        case let e as RecurrenceRule: try? await repository.upsert(e)
        case let e as RecurrenceOccurrence: try? await repository.upsert(e)
        case let e as ActionRecord: try? await repository.upsert(e)
        case let e as Measurement: try? await repository.upsert(e)
        case let e as Note: try? await repository.upsert(e)
        case let e as Capture: try? await repository.upsert(e)
        case let e as OperationBatch: try? await repository.upsert(e)
        case let e as Operation: try? await repository.upsert(e)
        case let e as Suggestion: try? await repository.upsert(e)
        case let e as ReviewNote: try? await repository.upsert(e)
        case let e as SyncConflict: try? await repository.upsert(e)
        case let e as Tombstone: try? await repository.upsert(e)
        default: break
        }
    }

    /// 事务内按序：写实体 → 追加 EventM → 更新 SearchDocM（5.2）
    private func index<T: RevisionedEntity>(_ entity: T) async {
        // Capture 与 Operation 不进搜索索引（原文通过收件箱访问）
        switch T.entityType {
        case .capture, .batch, .operation, .event, .conflict, .tombstone: return
        default: break
        }
        let doc = SearchDocument(
            id: entity.id, entityType: T.entityType, entityId: entity.id,
            planID: entity.searchPlanID, title: entity.searchTitle, body: entity.searchBody,
            tokens: SearchTokenizer.tokens(for: entity.searchTitle + " " + entity.searchBody),
            updatedAt: entity.searchUpdatedAt)
        try? await repository.upsertSearchDocument(doc)
    }

    private func mergeChangedFields(_ fields: [String]) {
        for f in fields where !changedFields.contains(f) { changedFields.append(f) }
    }

    public func mergePatch(_ p: [String: FieldPatch], fields: [String]) {
        for (k, v) in p { patch[k] = v }
        mergeChangedFields(fields)
    }
}

// MARK: - JSON 差异（自动生成 ChangeEvent 的 fields / patch）

public enum JSONDiff {
    public struct Result: Sendable {
        public var fields: [String]
        public var patch: [String: FieldPatch]
        public init(fields: [String], patch: [String: FieldPatch]) {
            self.fields = fields; self.patch = patch
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func dictionary<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let data = try makeEncoder().encode(value)
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        return decoded
    }

    public static func diff<T: Encodable & RevisionedEntity>(old: T?, new: T) throws -> Result {
        let newDict = try dictionary(new)
        guard let old else {
            // 新建：patch.old 全为 null
            var patch: [String: FieldPatch] = [:]
            for (k, v) in newDict where k != "revision" {
                patch[k] = FieldPatch(old: .null, new: v)
            }
            return Result(fields: patch.keys.sorted(), patch: patch)
        }
        let oldDict = try dictionary(old)
        var patch: [String: FieldPatch] = [:]
        for (k, newValue) in newDict {
            if k == "revision" { continue }
            let oldValue = oldDict[k] ?? .null
            if oldValue != newValue {
                patch[k] = FieldPatch(old: oldValue, new: newValue)
            }
        }
        return Result(fields: patch.keys.sorted(), patch: patch)
    }
}

// MARK: - 分词（5.3）

public enum SearchTokenizer {
    /// 中文按二元组（bigram）+ 完整词；拉丁/数字按空白与标点切词；统一小写。
    public static func tokens(for text: String) -> [String] {
        let lowered = text.lowercased()
        var out: Set<String> = []

        // 拉丁/数字词
        var latin = ""
        var cjkBuffer: [Character] = []

        func flushLatin() {
            if !latin.isEmpty { out.insert(latin); latin = "" }
        }
        func flushCJK() {
            guard !cjkBuffer.isEmpty else { return }
            let chars = cjkBuffer
            if chars.count == 1 { out.insert(String(chars[0])) }
            for i in 0..<chars.count {
                // bigram
                if i + 1 < chars.count { out.insert(String(chars[i...(i + 1)])) }
                // 完整词（连续中文片段）
                out.insert(String(chars))
            }
            cjkBuffer.removeAll()
        }

        for ch in lowered {
            if isASCIIWord(ch) {
                flushCJK()
                latin.append(ch)
            } else if isCJK(ch) {
                flushLatin()
                cjkBuffer.append(ch)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return out.sorted()
    }

    /// 查询侧：把查询串切成 token，多词 AND
    public static func queryTokens(for text: String) -> [String] {
        let lowered = text.lowercased()
        var out: [String] = []
        var latin = ""
        var cjkBuffer: [Character] = []
        func flushLatin() { if !latin.isEmpty { out.append(latin); latin = "" } }
        func flushCJK() {
            let chars = cjkBuffer
            if !chars.isEmpty {
                if chars.count == 1 { out.append(String(chars[0])) }
                else { out.append(String(chars)) }
                for i in 0..<(chars.count - 1) { out.append(String(chars[i...(i + 1)])) }
            }
            cjkBuffer.removeAll()
        }
        for ch in lowered {
            if isASCIIWord(ch) { flushCJK(); latin.append(ch) }
            else if isCJK(ch) { flushLatin(); cjkBuffer.append(ch) }
            else { flushLatin(); flushCJK() }
        }
        flushLatin(); flushCJK()
        return Array(Set(out)).sorted()
    }

    /// 文档 token 是否命中全部查询 token（多词 AND）
    public static func matches(documentTokens: Set<String>, queryTokens: [String]) -> Bool {
        guard !queryTokens.isEmpty else { return false }
        return queryTokens.allSatisfy { q in
            if documentTokens.contains(q) { return true }
            // 拉丁前缀匹配（"汇" 类极短查询已由 bigram 覆盖）
            return documentTokens.contains { $0.hasPrefix(q) && q.count >= 2 }
        }
    }

    static func isASCIIWord(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        return (ascii >= 48 && ascii <= 57) || (ascii >= 97 && ascii <= 122) || ascii == 95
    }

    static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)      // CJK 统一表意
            || (0x3400...0x4DBF).contains(v)      // 扩展 A
            || (0xF900...0xFAFF).contains(v)      // 兼容表意
            || (0x3040...0x30FF).contains(v)      // 假名
    }
}
