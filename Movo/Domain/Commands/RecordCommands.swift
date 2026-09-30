//
//  RecordCommands.swift
//  Domain/Commands
//
//  LogActivity / CorrectActivity / RecordMeasurement / CorrectMeasurement / CreateNote
//  补记不改写录入时间：occurredAt 用用户指定时间，recordedAt 用当前时间（3.4 / REQ 15）。
//  记录投入 ≠ 任务完成；行动与结果分区显示，不产生达标率（AC06/AC07/AC19）。
//

import Foundation

public struct LogActivity: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .logActivity
    public let entityID: UUID
    public let entityType: EntityType = .activity
    public var planID: UUID
    public var taskID: UUID?
    public var occurrenceID: UUID?
    public var happenedAt: TimeValue
    public var durationMinutes: Int?
    public var text: String?
    public var source: SourceKind

    public init(operationID: UUID = UUID(), id: UUID = UUID(), planID: UUID, taskID: UUID? = nil,
                occurrenceID: UUID? = nil, happenedAt: TimeValue, durationMinutes: Int? = nil,
                text: String? = nil, source: SourceKind = .manual) {
        self.operationID = operationID; self.entityID = id; self.planID = planID; self.taskID = taskID
        self.occurrenceID = occurrenceID; self.happenedAt = happenedAt
        self.durationMinutes = durationMinutes; self.text = text; self.source = source
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard await context.repository.plan(planID) != nil else {
            throw MovoError.notFound(entityType: .plan, id: planID)
        }
        if let taskID {
            guard let task = await context.repository.task(taskID) else {
                throw MovoError.notFound(entityType: .task, id: taskID)
            }
            if task.planId != planID {
                throw MovoError.invalidStructure(reason: "这条记录和任务不属于同一个计划。")
            }
        }
        if let occurrenceID {
            guard let occurrence = await context.repository.occurrence(occurrenceID) else {
                throw MovoError.notFound(entityType: .occurrence, id: occurrenceID)
            }
            if occurrence.planId != planID {
                throw MovoError.invalidStructure(reason: "这条记录和重复实例不属于同一个计划。")
            }
        }
        if let d = durationMinutes, d <= 0 {
            throw MovoError.invalidStructure(reason: "投入时长需要是正数。")
        }

        let activity = ActionRecord(id: entityID, planId: planID, taskId: taskID,
                                    occurrenceId: occurrenceID, happenedAt: happenedAt,
                                    durationMinutes: durationMinutes, text: text,
                                    source: source, recordedAt: context.now, createdAt: context.now)
        let saved = try await context.write(activity, old: nil)
        context.setOccurredAt(happenedAt.sortEpoch)   // 实际发生时间
        context.setUserMessage("已记录一次行动。记录投入不等于任务已完成。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision,
                             occurredAt: happenedAt.sortEpoch)
    }
}

public struct CorrectActivity: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .correctActivity
    public var activityID: UUID
    public var entityID: UUID { activityID }
    public let entityType: EntityType = .activity
    public var baseRevision: Int
    public var newHappenedAt: TimeValue?
    public var newDurationMinutes: Int?
    public var newText: String?
    /// 是否显式清除时长/文本
    public var clearDuration: Bool
    public var clearText: Bool

    public init(operationID: UUID = UUID(), activityID: UUID, newHappenedAt: TimeValue? = nil,
                newDurationMinutes: Int? = nil, newText: String? = nil,
                clearDuration: Bool = false, clearText: Bool = false, baseRevision: Int = 0) {
        self.operationID = operationID; self.activityID = activityID
        self.newHappenedAt = newHappenedAt; self.newDurationMinutes = newDurationMinutes
        self.newText = newText; self.clearDuration = clearDuration; self.clearText = clearText
        self.baseRevision = baseRevision
    }

    /// 更正保留旧版本（PRD 3.4）：写一条 isCorrection 记录指向原记录
    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.activity(activityID) else {
            throw MovoError.notFound(entityType: .activity, id: activityID)
        }
        try await StructurePolicy.requireWritable(id: activityID, type: .activity, repository: context.repository)
        try context.assertDeclaredRevision(actual: old.revision, entityID: activityID)

        let corrected = ActionRecord(
            planId: old.planId, taskId: old.taskId, occurrenceId: old.occurrenceId,
            happenedAt: newHappenedAt ?? old.happenedAt,
            durationMinutes: clearDuration ? nil : (newDurationMinutes ?? old.durationMinutes),
            text: clearText ? nil : (newText ?? old.text),
            source: old.source, isCorrection: true, correctedFromId: old.id,
            recordedAt: context.now, createdAt: context.now)
        let saved = try await context.write(corrected, old: nil)
        context.setUserMessage("已更正这条记录，原来的版本仍然保留着。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision,
                             occurredAt: (newHappenedAt ?? old.happenedAt).sortEpoch)
    }
}

public struct RecordMeasurement: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .recordMeasurement
    public let entityID: UUID
    public let entityType: EntityType = .measurement
    public var planID: UUID
    public var metricID: UUID
    public var measuredAt: DateOnly
    public var value: Double
    public var unit: String?
    public var note: String?
    public var source: SourceKind

    public init(operationID: UUID = UUID(), id: UUID = UUID(), planID: UUID, metricID: UUID,
                measuredAt: DateOnly, value: Double, unit: String? = nil, note: String? = nil,
                source: SourceKind = .manual) {
        self.operationID = operationID; self.entityID = id; self.planID = planID
        self.metricID = metricID; self.measuredAt = measuredAt; self.value = value
        self.unit = unit; self.note = note; self.source = source
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let metric = await context.repository.metric(metricID) else {
            throw MovoError.notFound(entityType: .metric, id: metricID)
        }
        guard metric.planId == planID else {
            throw MovoError.invalidStructure(reason: "这条结果不属于所选的计划。")
        }
        guard value.isFinite else {
            throw MovoError.invalidStructure(reason: "数值必须是有效数字，缺测不要补 0。")
        }
        // V9 / AC21：单位缺失或不一致 → 需要确认，不自行猜测
        if let unit, !unit.isEmpty, !metric.unit.isEmpty, unit != metric.unit {
            throw MovoError.invalidStructure(reason: "单位与指标设定不一致（指标单位为 \(metric.unitDisplayName)）。")
        }
        let finalUnit = (unit?.isEmpty == false ? unit! : metric.unit)
        let measurement = Measurement(id: entityID, planId: planID, metricId: metricID,
                                      measuredAt: measuredAt, value: value, unit: finalUnit,
                                      note: note, source: source, recordedAt: context.now)
        try await StructurePolicy.validateMeasurement(measurement, repository: context.repository)
        let saved = try await context.write(measurement, old: nil)
        context.setOccurredAt(measuredAt.noon)
        // 自动保存，不宣告目标达成（REQ 21）
        context.setUserMessage("已记录 \(format(metric.name, value, finalUnit))")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision,
                             occurredAt: measuredAt.noon)
    }

    private func format(_ name: String, _ value: Double, _ unit: String) -> String {
        let v = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return "\(name) \(v)\(PlanMetric.unitDisplayName(for: unit))"
    }
}

public struct CorrectMeasurement: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .correctMeasurement
    public var measurementID: UUID
    public var entityID: UUID { measurementID }
    public let entityType: EntityType = .measurement
    public var baseRevision: Int
    public var newValue: Double
    public var newNote: String?
    public var clearNote: Bool

    public init(operationID: UUID = UUID(), measurementID: UUID, newValue: Double,
                newNote: String? = nil, clearNote: Bool = false, baseRevision: Int = 0) {
        self.operationID = operationID; self.measurementID = measurementID
        self.newValue = newValue; self.newNote = newNote; self.clearNote = clearNote
        self.baseRevision = baseRevision
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        guard let old = await context.repository.measurement(measurementID) else {
            throw MovoError.notFound(entityType: .measurement, id: measurementID)
        }
        try context.assertDeclaredRevision(actual: old.revision, entityID: measurementID)
        guard newValue.isFinite else {
            throw MovoError.invalidStructure(reason: "数值必须是有效数字。")
        }
        // 更正保留旧版本（趋势显示"已更正"标记）
        let corrected = Measurement(planId: old.planId, metricId: old.metricId,
                                    measuredAt: old.measuredAt, value: newValue, unit: old.unit,
                                    note: clearNote ? nil : (newNote ?? old.note),
                                    source: old.source, isCorrection: true, correctedFromId: old.id,
                                    recordedAt: context.now)
        try await StructurePolicy.validateMeasurement(corrected, repository: context.repository)
        let saved = try await context.write(corrected, old: nil)
        context.setUserMessage("已更正这条结果，历史里仍可回看原来的记录。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}

public struct CreateNote: DomainCommand {
    public let operationID: UUID
    public let kind: OperationKind = .createNote
    public let entityID: UUID
    public let entityType: EntityType = .note
    public var text: String
    public var noteKind: NoteKind
    public var planID: UUID?
    public var source: SourceKind
    public var captureID: UUID?

    public init(operationID: UUID = UUID(), id: UUID = UUID(), text: String, kind: NoteKind = .idea,
                planID: UUID? = nil, source: SourceKind = .manual, captureID: UUID? = nil) {
        self.operationID = operationID; self.entityID = id; self.text = text
        self.noteKind = kind; self.planID = planID; self.source = source; self.captureID = captureID
    }

    /// 想法/决定单独保留（AC01），不创建任务
    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MovoError.invalidStructure(reason: "还没有写下内容。")
        }
        if let planID, let plan = await context.repository.plan(planID) {
            if plan.status == .archived {
                throw MovoError.invalidStructure(reason: "「\(plan.name)」已归档，不能作为新想法的归属。")
            }
        }
        let note = Note(id: entityID, text: trimmed, kind: noteKind, planId: planID,
                        capturedAt: context.now, source: source, captureId: captureID)
        let saved = try await context.write(note, old: nil)
        context.setUserMessage("已记下这条\(noteKind.displayName)，不会自动变成任务。")
        return CommandResult(operationID: operationID, entityID: saved.id,
                             changedFields: context.changedFields,
                             userMessage: context.userMessage, newRevision: saved.revision)
    }
}
