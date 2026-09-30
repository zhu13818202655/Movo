//
//  ProposalMaterializer.swift
//  Intelligence/Planning
//
//  6.7 / C8：用户确认后，把"待确认项"物化为可提交的命令（同一 batch 一次提交）。
//  校验器在 V1–V13 通过后只产出摘要，真正写入发生在确认之后。
//

import Foundation

public extension ProposalValidator {

    /// 把一条待确认项物化为命令。数据不完整时返回空数组（留在收件箱）。
    static func materialize(_ pending: PendingProposal,
                            tasks: [UUID: Task],
                            metrics: [UUID: PlanMetric],
                            rules: [UUID: RecurrenceRule] = [:],
                            timeZone: TimeZone,
                            today: DateOnly,
                            source: SourceKind,
                            captureID: UUID?) -> [any DomainCommand] {
        let item = pending.item
        let spec = item.task
        var out: [any DomainCommand] = []

        func uuid(_ raw: String?) -> UUID? { raw.flatMap { UUID(uuidString: $0) } }

        switch pending.kind {
        case .classificationAmbiguous:
            guard let spec else { return [] }
            let title = (spec.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= Task.maxTitleLength else { return [] }
            let scheduled = spec.scheduledDate
                .flatMap { DateOnly(iso8601DateString: $0, sourceTZ: timeZone.identifier) }
            out.append(CreateTask(
                title: title,
                planID: uuid(spec.planId),
                stageID: uuid(spec.stageId),
                parentID: uuid(spec.parentTaskId),
                notes: spec.notes,
                scheduledDate: scheduled,
                deadline: nil,
                estimateMinutes: spec.estimateMinutes,
                priority: spec.priority.flatMap { TaskPriority(rawValue: normalizePriority($0)) },
                tags: spec.tags,
                dependencyIDs: spec.dependencyIds.compactMap { UUID(uuidString: $0) },
                recurrence: nil,
                source: source,
                captureID: captureID,
                suggestedFields: suggestedFields(for: item, taskSpec: spec)))

        case .dependencySuggestion:
            guard let spec, let candidateID = uuid(spec.candidateTaskId),
                  let task = tasks[candidateID] else { return [] }
            for dep in spec.dependencyIds.compactMap({ UUID(uuidString: $0) }) {
                out.append(AddDependency(taskID: candidateID, dependsOnID: dep,
                                         baseRevision: task.revision))
            }

        case .deadlineChange:
            guard let spec, let candidateID = uuid(spec.candidateTaskId),
                  let task = tasks[candidateID], let raw = spec.hardDeadline,
                  let deadline = parseDeadline(raw, fallbackTZ: timeZone) else { return [] }
            out.append(SetDeadline(taskID: candidateID, deadline: deadline,
                                   baseRevision: task.revision, reason: item.reason))

        case .recurrenceChange:
            guard let spec, let candidateID = uuid(spec.candidateTaskId),
                  let rule = rules[candidateID], let rec = item.recurrence,
                  let patternRaw = rec.pattern,
                  let pattern = RecurrencePattern(rawValue: patternRaw) else { return [] }
            var from = today
            if let raw = rec.effectiveFrom,
               let parsed = DateOnly(iso8601DateString: raw, sourceTZ: timeZone.identifier),
               parsed >= today { from = parsed }
            out.append(ChangeRecurrence(ruleID: rule.id, pattern: pattern,
                                        weekdays: rec.weekdays, weeklyCount: rec.count,
                                        effectiveFrom: from, baseRevision: rule.revision))

        case .measurementUnitUnclear:
            guard let spec = item.measurement, let metricID = uuid(spec.metricId),
                  let metric = metrics[metricID], let value = spec.value,
                  let rawDate = spec.measuredAt,
                  let measuredAt = DateOnly(iso8601DateString: rawDate, sourceTZ: timeZone.identifier)
            else { return [] }
            out.append(RecordMeasurement(
                planID: metric.planId, metricID: metricID, measuredAt: measuredAt,
                value: value, unit: metric.unit.isEmpty ? nil : metric.unit,
                note: spec.note, source: source))

        case .bulkChange:
            // 批量改期/取消：由调用方展开为具体命令后提交（此处保持空）
            return []
        }

        return out
    }
}
