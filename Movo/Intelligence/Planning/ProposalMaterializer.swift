//
//  ProposalMaterializer.swift
//  Intelligence/Planning
//
//  6.7 / C8：用户确认后，把"待确认项"物化为可提交的命令（同一 batch 一次提交）。
//  校验器在通过后只产出预览树与待确认项，真正写入发生在确认之后。
//

import Foundation

/// 重复块解析结果：规则草稿，以及用户明确给出的窗口端点。
/// 窗口端点用来把模板任务自身的 startAt / endAt 对齐到同一个窗口，
/// 避免出现「规则重复到 11月9日、任务的结束时间却空着」这类不一致。
struct RecurrencePlan {
    var draft: RecurrenceDraft
    var explicitStart: DateOnly?
    var explicitUntil: DateOnly?
}

public extension ProposalValidator {

    /// 批量物化用户确认的提案集合，解析批内临时引用并按依赖拓扑顺序输出命令。
    static func materializeBatch(_ proposals: [PendingProposal],
                                 plans: [Plan] = [],
                                 tasks: [UUID: Task] = [:],
                                 metrics: [UUID: PlanMetric] = [:],
                                 rules: [UUID: RecurrenceRule] = [:],
                                 timeZone: TimeZone,
                                 today: DateOnly,
                                 source: SourceKind,
                                 captureID: UUID?) -> [any DomainCommand] {
        var refToID: [String: UUID] = [:]

        // 1. 预分配所有引用的 UUID
        for pending in proposals {
            let item = pending.item
            if let plan = item.plan {
                let pid = UUID()
                if let pr = plan.ref { refToID[pr] = pid }
                for stage in plan.stages {
                    let sid = UUID()
                    if let sr = stage.ref { refToID[sr] = sid }
                }
                for task in plan.tasks {
                    let tid = UUID()
                    if let tr = task.ref { refToID[tr] = tid }
                    for step in task.steps {
                        if let sr = step.ref { refToID[sr] = UUID() }
                    }
                }
            }
            if let task = item.task {
                let tid = UUID()
                if let tr = task.ref { refToID[tr] = tid }
                for step in task.steps {
                    if let sr = step.ref { refToID[sr] = UUID() }
                }
            }
        }

        func resolveUUID(_ raw: String?) -> UUID? {
            guard let raw, !raw.isEmpty else { return nil }
            return refToID[raw] ?? UUID(uuidString: raw)
        }

        var planCommands: [any DomainCommand] = []
        var stageCommands: [any DomainCommand] = []
        var taskItems: [(parentID: UUID?, cmd: any DomainCommand, taskID: UUID)] = []
        var stepCommands: [any DomainCommand] = []
        var otherCommands: [any DomainCommand] = []

        func buildRecurrenceDraft(_ rec: AIRecurrence?, startAt: TimePoint?) -> RecurrencePlan? {
            ProposalValidator.recurrencePlan(rec, startAt: startAt, today: today, timeZone: timeZone)
        }

        for pending in proposals {
            let item = pending.item
            switch pending.kind {
            case .planCreation:
                guard let plan = item.plan else { continue }
                let planID = plan.ref.flatMap { refToID[$0] } ?? UUID()
                planCommands.append(CreatePlan(
                    id: planID, name: plan.name, kind: plan.kind, goal: plan.goal,
                    startAt: plan.startAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) },
                    endAt: plan.endAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) },
                    syncEnabled: true))

                for (idx, stage) in plan.stages.enumerated() {
                    let stageID = stage.ref.flatMap { refToID[$0] } ?? UUID()
                    stageCommands.append(CreateStage(
                        id: stageID, planID: planID, name: stage.name,
                        startAt: stage.startAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) },
                        endAt: stage.endAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) },
                        sortIndex: idx))
                }

                // 子任务未声明阶段时继承父任务所在阶段（同一子树保持计划与阶段一致）。
                var stageByRef: [String: UUID] = [:]
                for task in plan.tasks {
                    guard let ref = task.ref else { continue }
                    stageByRef[ref] = resolveUUID(task.stageRef) ?? resolveUUID(task.stageId)
                }
                for _ in 0..<max(1, plan.tasks.count) {
                    var changed = false
                    for task in plan.tasks {
                        guard let ref = task.ref, stageByRef[ref] == nil,
                              let parentRef = task.parentRef, let inherited = stageByRef[parentRef] else { continue }
                        stageByRef[ref] = inherited
                        changed = true
                    }
                    if !changed { break }
                }

                for task in plan.tasks {
                    let taskID = task.ref.flatMap { refToID[$0] } ?? UUID()
                    let stageID = resolveUUID(task.stageRef) ?? resolveUUID(task.stageId)
                        ?? task.ref.flatMap { stageByRef[$0] }
                    let parentID = resolveUUID(task.parentRef) ?? resolveUUID(task.parentTaskId)
                    var start = task.startAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) }
                    if let s = start, s.dateOnly < today { start = .day(today) }
                    let recPlan = buildRecurrenceDraft(task.recurrence, startAt: start)
                    if start == nil, let explicitStart = recPlan?.explicitStart { start = .day(explicitStart) }

                    let cmd = CreateTask(
                        id: taskID, title: task.title ?? "", planID: planID,
                        stageID: stageID, parentID: parentID, notes: task.notes,
                        startAt: start,
                        endAt: task.endAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) }
                            ?? recPlan?.explicitUntil.map { TimePoint.day($0) },
                        estimateMinutes: task.estimateMinutes,
                        priority: task.priority.flatMap { TaskPriority(rawValue: normalizePriority($0)) },
                        tags: task.tags,
                        dependencyIDs: task.dependencyIds.compactMap(resolveUUID),
                        recurrence: recPlan?.draft, source: source, captureID: captureID)
                    taskItems.append((parentID, cmd, taskID))

                    // 步骤
                    for step in task.steps {
                        let stepID = step.ref.flatMap { refToID[$0] } ?? UUID()
                        let stepParentID = resolveUUID(step.parentRef) ?? taskID
                        stepCommands.append(CreateTask(
                            id: stepID, title: step.title, planID: planID,
                            stageID: stageID, parentID: stepParentID, notes: step.notes,
                            source: source, captureID: captureID))
                    }
                }

            case .taskCreation, .classificationAmbiguous:
                guard let spec = item.task else { continue }
                let taskID = spec.ref.flatMap { refToID[$0] } ?? UUID()
                let title = (spec.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let planID = resolveUUID(spec.planId)
                let stageID = resolveUUID(spec.stageRef) ?? resolveUUID(spec.stageId)
                let parentID = resolveUUID(spec.parentRef) ?? resolveUUID(spec.parentTaskId)
                var start = spec.startAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) }
                if let s = start, s.dateOnly < today { start = .day(today) }
                let recPlan = buildRecurrenceDraft(spec.recurrence ?? item.recurrence, startAt: start)
                if start == nil, let explicitStart = recPlan?.explicitStart { start = .day(explicitStart) }

                let cmd = CreateTask(
                    id: taskID, title: title, planID: planID,
                    stageID: stageID, parentID: parentID, notes: spec.notes,
                    startAt: start,
                    endAt: spec.endAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) }
                        ?? recPlan?.explicitUntil.map { TimePoint.day($0) },
                    estimateMinutes: spec.estimateMinutes,
                    priority: spec.priority.flatMap { TaskPriority(rawValue: normalizePriority($0)) },
                    tags: spec.tags,
                    dependencyIDs: spec.dependencyIds.compactMap(resolveUUID),
                    recurrence: recPlan?.draft, source: source, captureID: captureID,
                    suggestedFields: suggestedFields(for: item, taskSpec: spec))
                taskItems.append((parentID, cmd, taskID))

                for step in spec.steps {
                    let stepID = step.ref.flatMap { refToID[$0] } ?? UUID()
                    let stepParentID = resolveUUID(step.parentRef) ?? taskID
                    stepCommands.append(CreateTask(
                        id: stepID, title: step.title, planID: planID,
                        stageID: stageID, parentID: stepParentID, notes: step.notes,
                        source: source, captureID: captureID))
                }

            default:
                let singles = materialize(pending, tasks: tasks, metrics: metrics, rules: rules,
                                          timeZone: timeZone, today: today, source: source,
                                          captureID: captureID)
                otherCommands.append(contentsOf: singles)
            }
        }

        // 2. 任务按父子依赖拓扑排序（父任务必须在子任务前写入）
        var sortedTaskCommands: [any DomainCommand] = []
        var emittedIDs = Set<UUID>()
        var remaining = taskItems

        while !remaining.isEmpty {
            let ready = remaining.filter { item in
                guard let pid = item.parentID else { return true }
                return emittedIDs.contains(pid) || (taskItems.allSatisfy { $0.taskID != pid })
            }
            if ready.isEmpty {
                // 有未解依赖或环时兜底直接排放
                for item in remaining {
                    sortedTaskCommands.append(item.cmd)
                    emittedIDs.insert(item.taskID)
                }
                break
            }
            for item in ready {
                sortedTaskCommands.append(item.cmd)
                emittedIDs.insert(item.taskID)
            }
            let readyIDs = Set(ready.map(\.taskID))
            remaining.removeAll { readyIDs.contains($0.taskID) }
        }

        var result: [any DomainCommand] = []
        result.append(contentsOf: planCommands)
        result.append(contentsOf: stageCommands)
        result.append(contentsOf: sortedTaskCommands)
        result.append(contentsOf: stepCommands)
        result.append(contentsOf: otherCommands)
        return result
    }

    /// 把单条待确认项物化为命令。数据不完整时返回空数组。
    static func materialize(_ pending: PendingProposal,
                            tasks: [UUID: Task],
                            metrics: [UUID: PlanMetric],
                            rules: [UUID: RecurrenceRule] = [:],
                            timeZone: TimeZone,
                            today: DateOnly,
                            source: SourceKind,
                            captureID: UUID?, planID: UUID = UUID()) -> [any DomainCommand] {
        let item = pending.item
        let spec = item.task
        var out: [any DomainCommand] = []

        func uuid(_ raw: String?) -> UUID? { raw.flatMap { UUID(uuidString: $0) } }

        switch pending.kind {
        case .planCreation:
            guard let plan = item.plan else { return [] }
            out.append(CreatePlan(id: planID, name: plan.name, kind: plan.kind, goal: plan.goal,
                                  startAt: plan.startAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) },
                                  endAt: plan.endAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) },
                                  syncEnabled: true))
            for (idx, stage) in plan.stages.enumerated() {
                out.append(CreateStage(planID: planID, name: stage.name,
                                       startAt: stage.startAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) },
                                       endAt: stage.endAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) },
                                       sortIndex: idx))
            }
            for task in plan.tasks {
                var start = task.startAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) }
                if let current = start, current.dateOnly < today { start = .day(today) }
                let recPlan = Self.recurrencePlan(task.recurrence, startAt: start,
                                                  today: today, timeZone: timeZone)
                if start == nil, let explicitStart = recPlan?.explicitStart { start = .day(explicitStart) }
                out.append(CreateTask(title: task.title ?? "", planID: planID, notes: task.notes,
                                      startAt: start,
                                      endAt: task.endAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) }
                                          ?? recPlan?.explicitUntil.map { TimePoint.day($0) },
                                      estimateMinutes: task.estimateMinutes,
                                      priority: task.priority.flatMap { TaskPriority(rawValue: normalizePriority($0)) },
                                      tags: task.tags, recurrence: recPlan?.draft,
                                      source: source, captureID: captureID))
            }

        case .taskCreation, .classificationAmbiguous:
            guard let spec else { return [] }
            let title = (spec.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= Task.maxTitleLength else { return [] }
            var start = spec.startAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) }
            let recPlan = Self.recurrencePlan(spec.recurrence ?? item.recurrence,
                                              startAt: start, today: today, timeZone: timeZone)
            if start == nil, let explicitStart = recPlan?.explicitStart { start = .day(explicitStart) }
            let taskID = UUID()
            out.append(CreateTask(
                id: taskID,
                title: title,
                planID: uuid(spec.planId),
                stageID: uuid(spec.stageId),
                parentID: uuid(spec.parentTaskId),
                notes: spec.notes,
                startAt: start,
                endAt: spec.endAt.flatMap { TimePoint.parse($0, fallbackTZ: timeZone) }
                    ?? recPlan?.explicitUntil.map { TimePoint.day($0) },
                estimateMinutes: spec.estimateMinutes,
                priority: spec.priority.flatMap { TaskPriority(rawValue: normalizePriority($0)) },
                tags: spec.tags,
                dependencyIDs: spec.dependencyIds.compactMap { UUID(uuidString: $0) },
                recurrence: recPlan?.draft,
                source: source,
                captureID: captureID,
                suggestedFields: suggestedFields(for: item, taskSpec: spec)))
            for step in spec.steps {
                out.append(CreateTask(
                    title: step.title, planID: uuid(spec.planId),
                    stageID: uuid(spec.stageId), parentID: taskID, notes: step.notes,
                    source: source, captureID: captureID))
            }

        case .dependencySuggestion:
            guard let spec, let candidateID = uuid(spec.candidateTaskId),
                  let task = tasks[candidateID] else { return [] }
            for dep in spec.dependencyIds.compactMap({ UUID(uuidString: $0) }) {
                out.append(AddDependency(taskID: candidateID, dependsOnID: dep,
                                         baseRevision: task.revision))
            }

        case .deadlineChange:
            guard let spec, let candidateID = uuid(spec.candidateTaskId),
                  let task = tasks[candidateID], let raw = spec.endAt,
                  let end = TimePoint.parse(raw, fallbackTZ: timeZone) else { return [] }
            out.append(SetDeadline(taskID: candidateID, endAt: end,
                                   baseRevision: task.revision, reason: item.reason))

        case .taskSchedule:
            guard let spec, let candidateID = uuid(spec.candidateTaskId),
                  let task = tasks[candidateID], let raw = spec.startAt,
                  let start = TimePoint.parse(raw, fallbackTZ: timeZone) else { return [] }
            out.append(ScheduleTask(taskID: candidateID, startAt: start, baseRevision: task.revision))

        case .taskUpdate:
            guard let spec, let candidateID = uuid(spec.candidateTaskId),
                  let task = tasks[candidateID] else { return [] }
            var patch = TaskPatch()
            if let title = spec.title { patch.title = title }
            if let notes = spec.notes { patch.notes = notes }
            if let start = spec.startAt.flatMap({ TimePoint.parse($0, fallbackTZ: timeZone) }) { patch.startAt = start }
            if let end = spec.endAt.flatMap({ TimePoint.parse($0, fallbackTZ: timeZone) }) { patch.endAt = end }
            if let prio = spec.priority.flatMap({ TaskPriority(rawValue: normalizePriority($0)) }) { patch.priority = prio }
            if let stage = uuid(spec.stageId) { patch.stageID = stage }
            if let plan = uuid(spec.planId) { patch.planID = plan }
            out.append(UpdateTask(taskID: candidateID, patch: patch, baseRevision: task.revision))

        case .taskCompletion:
            guard let spec, let candidateID = uuid(spec.candidateTaskId),
                  let task = tasks[candidateID] else { return [] }
            let day = resolvedDay(item: item, spec: spec, today: today, timeZone: timeZone) ?? today
            out.append(CompleteTask(taskID: candidateID, at: .day(day),
                                    baseRevision: task.revision, reason: item.reason))

        case .noteCreation:
            let text = (item.note?.text ?? item.sourceSpan ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let kind = NoteKind(rawValue: item.note?.kind ?? "") ?? .idea
            out.append(CreateNote(text: text, kind: kind, planID: uuid(spec?.planId),
                                  source: source, captureID: captureID))

        case .activityLog:
            guard let planID = uuid(spec?.planId) else { return [] }
            let day = resolvedDay(item: item, spec: spec, today: today, timeZone: timeZone) ?? today
            out.append(LogActivity(planID: planID, taskID: uuid(spec?.candidateTaskId),
                                   occurrenceID: nil, happenedAt: .day(day),
                                   durationMinutes: nil, text: item.note?.text ?? item.sourceSpan ?? "",
                                   source: source))

        case .recurrenceChange:
            guard let spec, let candidateID = uuid(spec.candidateTaskId),
                  let rule = rules[candidateID], let rec = item.recurrence,
                  let patternRaw = rec.pattern,
                  let pattern = RecurrencePattern(rawValue: patternRaw) else { return [] }
            guard let plan = ProposalValidator.recurrencePlan(rec, startAt: nil,
                                                              today: today, timeZone: timeZone) else { return [] }
            out.append(ChangeRecurrence(ruleID: rule.id, pattern: pattern,
                                        weekdays: rec.weekdays, weeklyCount: rec.count,
                                        effectiveFrom: plan.draft.effectiveFrom,
                                        updatesEffectiveUntil: rec.effectiveUntil != nil,
                                        effectiveUntil: plan.draft.effectiveUntil,
                                        updatesDailyTimes: rec.resolvedDailyStart != nil
                                            || rec.resolvedDailyEnd != nil,
                                        dailyStart: plan.draft.dailyStart,
                                        dailyEnd: plan.draft.dailyEnd,
                                        baseRevision: rule.revision))

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
            return []
        }

        return out
    }

    /// 把模型给出的重复块解析成规则草稿与窗口端点。
    /// - Parameters:
    ///   - startAt: 任务自身的开始时间点。模型经常把「早上 6:30」只写进 `start_at`，
    ///     这里当作每天时刻的兜底来源，否则规则会丢掉时刻（实例没有钟点、也不产生定点提醒）。
    /// 只在模块内使用（`RecurrencePlan` 是内部类型），因此显式标 `internal`。
    internal static func recurrencePlan(_ rec: AIRecurrence?, startAt: TimePoint?,
                                        today: DateOnly, timeZone: TimeZone) -> RecurrencePlan? {
        guard let rec, let pRaw = rec.pattern, let p = RecurrencePattern(rawValue: pRaw) else { return nil }
        // 与 `recurrenceFieldIssue` 用同一套「取日期前缀」的解析口径，
        // 免得校验通过、这里却因为模型多带了时刻而静默丢窗口。
        var explicitStart: DateOnly?
        if let rawFrom = rec.effectiveFrom,
           let parsed = DateOnly(iso8601DateString: dayPrefix(rawFrom), sourceTZ: timeZone.identifier) {
            explicitStart = parsed
        }
        let from = max(explicitStart ?? today, today)
        var until: DateOnly?
        if let rawUntil = rec.effectiveUntil,
           let parsed = DateOnly(iso8601DateString: dayPrefix(rawUntil), sourceTZ: timeZone.identifier) {
            until = parsed
        }
        // 结束日不能早于生效日；早于时保留生效日当天，避免规则永不生效。
        if let value = until, value < from { until = from }
        let draft = RecurrenceDraft(pattern: p, weekdays: rec.weekdays, weeklyCount: rec.count,
                                   effectiveFrom: from, effectiveUntil: until,
                                   dailyStart: rec.resolvedDailyStart ?? startAt?.timeOfDay,
                                   dailyEnd: rec.resolvedDailyEnd)
        return RecurrencePlan(draft: draft, explicitStart: explicitStart, explicitUntil: until)
    }
}
