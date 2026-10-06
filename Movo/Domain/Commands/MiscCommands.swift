//
//  MiscCommands.swift
//  Domain/Commands
//
//  ProcessCapture（原文落库）/ AddSuggestion / AcceptSuggestion / DismissSuggestion /
//  ResolveConflict / RecordReviewNote
//

import Foundation

// MARK: - ProcessCapture

/// 内部命令：落库原文，执行本地可确定项（6.2 C1–C2）。
/// 任何失败分支下 rawText 已持久化，离开页面再回来可继续（REQ 02）。
public struct ProcessCapture: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .processCapture
    public let entityID: UUID
    public let entityType: EntityType = .capture
    public var rawText: String
    public var editedText: String?
    public var inputMode: InputMode
    public var segments: [SourceSpan]
    public var state: CaptureState
    public var batchID: UUID?
    public var proposalJSON: String?
    public var audioRetention: AudioRetention

    public init(operationID: UUID = UUID(), id: UUID = UUID(), rawText: String,
                editedText: String? = nil, inputMode: InputMode = .text,
                segments: [SourceSpan] = [], state: CaptureState = .saved,
                batchID: UUID? = nil, proposalJSON: String? = nil,
                audioRetention: AudioRetention = .none) {
        self.operationID = operationID; self.entityID = id; self.rawText = rawText
        self.editedText = editedText; self.inputMode = inputMode; self.segments = segments
        self.state = state; self.batchID = batchID; self.proposalJSON = proposalJSON
        self.audioRetention = audioRetention
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MovoError.invalidStructure(reason: "还没有输入内容。")
        }
        var capture = Capture(id: entityID, rawText: rawText, editedText: editedText,
                              inputMode: inputMode, capturedAt: context.now,
                              timezoneID: context.timeZone.identifier, state: state,
                              batchId: batchID, segments: segments,
                              proposalJSON: proposalJSON)
        capture.audioRetention = audioRetention
        if audioRetention == .retain24h {
            capture.audioExpiresAt = context.now.addingTimeInterval(
                Double(AudioRetention.retentionHours) * 3600)
        }
        let existing = await context.repository.capture(entityID)
        if let existing {
            capture.rawText = existing.rawText
            capture.capturedAt = existing.capturedAt
            capture.timezoneID = existing.timezoneID
            capture.audioExpiresAt = existing.audioExpiresAt
            if capture.proposalJSON == nil { capture.proposalJSON = existing.proposalJSON }
        }
        let saved = try await context.write(capture, old: existing)
        context.setUserMessage("原文已保存。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

// MARK: - Suggestion

public struct AddSuggestion: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .addSuggestion
    public let entityID: UUID
    public let entityType: EntityType = .suggestion
    public var text: String
    public var suggestionKind: SuggestionKind
    public var planID: UUID?
    public var weekStart: DateOnly?
    /// 建议必须带来源（REQ 17）
    public var sourceText: String?
    public var sourceEntityID: UUID?

    public init(operationID: UUID = UUID(), id: UUID = UUID(), text: String,
                kind: SuggestionKind = .nextAction, planID: UUID? = nil, weekStart: DateOnly? = nil,
                sourceText: String? = nil, sourceEntityID: UUID? = nil) {
        self.operationID = operationID; self.entityID = id; self.text = text
        self.suggestionKind = kind; self.planID = planID; self.weekStart = weekStart
        self.sourceText = sourceText; self.sourceEntityID = sourceEntityID
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MovoError.invalidStructure(reason: "建议内容为空。")
        }
        guard !(sourceText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || sourceEntityID != nil else {
            throw MovoError.invalidStructure(reason: "建议需要带上它的来源，否则不展示。")
        }
        let suggestion = Suggestion(id: entityID, planId: planID, weekStart: weekStart,
                                    kind: suggestionKind, text: trimmed, sourceText: sourceText,
                                    sourceEntityId: sourceEntityID, status: .pending,
                                    createdAt: context.now)
        let saved = try await context.write(suggestion, old: nil)
        context.setUserMessage("已生成一条建议，采纳后才会加入安排。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct AcceptSuggestion: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .acceptSuggestion
    public var suggestionID: UUID
    public var entityID: UUID { suggestionID }
    public let entityType: EntityType = .suggestion
    public var taskID: UUID?
    public var baseRevision: Int

    public init(operationID: UUID = UUID(), suggestionID: UUID, creatingTask taskID: UUID? = nil,
                baseRevision: Int = 0) {
        self.operationID = operationID; self.suggestionID = suggestionID
        self.taskID = taskID; self.baseRevision = baseRevision
    }

    /// 采纳才创建安排（REQ 17）
    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.suggestion(suggestionID) else {
            throw MovoError.notFound(entityType: .suggestion, id: suggestionID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: suggestionID)
        guard old.status == .pending else {
            throw MovoError.invalidStructure(reason: "这条建议已经处理过了。")
        }
        var updated = old
        updated.status = .accepted
        updated.acceptedTaskId = taskID
        let saved = try await context.write(updated, old: old)
        context.setUserMessage("已采纳这条建议。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct DismissSuggestion: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .dismissSuggestion
    public var suggestionID: UUID
    public var entityID: UUID { suggestionID }
    public let entityType: EntityType = .suggestion
    public var baseRevision: Int

    public init(operationID: UUID = UUID(), suggestionID: UUID, baseRevision: Int = 0) {
        self.operationID = operationID; self.suggestionID = suggestionID; self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.suggestion(suggestionID) else {
            throw MovoError.notFound(entityType: .suggestion, id: suggestionID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: suggestionID)
        var updated = old
        updated.status = .dismissed
        let saved = try await context.write(updated, old: old)
        context.setUserMessage("已忽略这条建议，未采纳不会出现在今日。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

// MARK: - ReviewNote

public struct RecordReviewNote: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .logActivity
    public let entityID: UUID
    public let entityType: EntityType = .reviewNote
    public var text: String
    public var planID: UUID?
    public var weekStart: DateOnly?

    public init(operationID: UUID = UUID(), id: UUID = UUID(), text: String,
                planID: UUID? = nil, weekStart: DateOnly? = nil) {
        self.operationID = operationID; self.entityID = id; self.text = text
        self.planID = planID; self.weekStart = weekStart
    }

    /// 人工补记与建议分存
    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MovoError.invalidStructure(reason: "还没有写下内容。")
        }
        let note = ReviewNote(id: entityID, planId: planID, weekStart: weekStart,
                              text: trimmed, createdAt: context.now)
        let saved = try await context.write(note, old: nil)
        context.setUserMessage("已记下你的观察。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

// MARK: - ResolveConflict

public struct ResolveConflict: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .resolveConflict
    public var conflictID: UUID
    public var entityID: UUID { conflictID }
    public let entityType: EntityType = .conflict
    public var choice: ConflictResolution
    public var customValue: JSONValue?

    public init(operationID: UUID = UUID(), conflictID: UUID, choice: ConflictResolution,
                customValue: JSONValue? = nil) {
        self.operationID = operationID; self.conflictID = conflictID; self.choice = choice
        self.customValue = customValue
    }

    /// 双候选都在，写决议事件（新 revision）
    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.conflict(conflictID) else {
            throw MovoError.notFound(entityType: .conflict, id: conflictID)
        }
        guard !old.isResolved else {
            throw MovoError.invalidStructure(reason: "这个冲突已经处理过了。")
        }
        // 冲突解决前不丢失任一版本（P3 完成条件）
        guard old.bothVersionsPresent else {
            throw MovoError.invalidStructure(reason: "冲突的候选值不完整，无法处理。")
        }
        let resolvedValue: JSONValue = {
            switch choice {
            case .local: old.localValue
            case .remote: old.remoteValue
            case .custom: customValue ?? old.localValue
            }
        }()
        var updated = old
        updated.resolution = choice
        updated.resolvedValue = resolvedValue
        updated.resolvedAt = context.now
        let saved = try await context.write(updated, old: old)
        context.setUserMessage("已保留你选择的版本，两端会再同步一次。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}
