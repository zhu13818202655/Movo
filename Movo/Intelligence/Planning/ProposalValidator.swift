//
//  ProposalValidator.swift
//  Intelligence/Planning
//
//  6.6 校验清单。核心原则：**校验未过绝不猜测**——进收件箱可编辑，而不是猜一个值写下去。
//  高影响动作（依赖建议 / 频率调整 / 硬截止 / 结果单位）一律进"待确认"，确认后才物化为命令。
//

import Foundation

// MARK: - 待确认项

/// 需要用户确认的提议（不自动执行）。确认后由 `ProposalValidator.materialize` 物化为命令。
public struct PendingProposal: Identifiable, Sendable {

    public enum Kind: String, Sendable, CaseIterable {
        case taskCreation
        case planCreation
        case deadlineChange
        case recurrenceChange
        case dependencySuggestion
        case measurementUnitUnclear
        case classificationAmbiguous
        case bulkChange
        case noteCreation
        case activityLog
        case taskCompletion
        case taskSchedule
        case taskUpdate

        public var displayName: String {
            switch self {
            case .taskCreation: "新增待办"
            case .planCreation: "新建计划"
            case .deadlineChange: "修改结束时间"
            case .recurrenceChange: "调整频率"
            case .dependencySuggestion: "先后顺序建议"
            case .measurementUnitUnclear: "结果单位待确认"
            case .classificationAmbiguous: "归属待确认"
            case .bulkChange: "批量改动"
            case .noteCreation: "保存想法"
            case .activityLog: "记录行动"
            case .taskCompletion: "标记完成"
            case .taskSchedule: "安排日期"
            case .taskUpdate: "修改待办"
            }
        }
    }

    public var id: String
    public var item: AIProposalItem
    /// 影响到的对象摘要（标题等）
    public var affectedSummary: String
    /// 依赖变化：可读的前置任务标题
    public var dependencyChanges: [String]
    /// 影响预览行
    public var changeSummary: [ImpactPreview.ImpactLine]
    public var kind: PendingProposal.Kind

    public init(id: String, item: AIProposalItem, affectedSummary: String,
                dependencyChanges: [String] = [],
                changeSummary: [ImpactPreview.ImpactLine] = [],
                kind: PendingProposal.Kind) {
        self.id = id; self.item = item; self.affectedSummary = affectedSummary
        self.dependencyChanges = dependencyChanges
        self.changeSummary = changeSummary; self.kind = kind
    }
}

// MARK: - 校验未过项（进收件箱，可编辑）

public struct ProposalIssue: Identifiable, Hashable, Sendable {
    public var itemID: String
    public var sourceSpan: String?
    public var reasons: [RejectReason]
    public var suggestedAction: String?

    public var id: String { "\(itemID)#\(sourceSpan ?? "")" }

    public init(itemID: String, sourceSpan: String?,
                reasons: [RejectReason], suggestedAction: String? = nil) {
        self.itemID = itemID; self.sourceSpan = sourceSpan
        self.reasons = reasons; self.suggestedAction = suggestedAction
    }
}

// MARK: - 校验结果

public struct ValidatedProposal: Sendable {
    /// 可自动执行并撤销的命令
    public var commands: [any DomainCommand]
    public var commandKeys: [UUID: String] = [:]
    /// 需要用户确认的提议
    public var needsConfirmation: [PendingProposal]
    /// 校验未过项（进收件箱）
    public var issues: [ProposalIssue]
    /// 本地自动修正说明（可回看，不改用户原文）
    public var corrections: [String]
    /// 同批重复被合并的条数
    public var mergedDuplicates: Int
    /// 超过单次上限时的说明
    public var truncationNotice: String?

    public init(commands: [any DomainCommand] = [],
                needsConfirmation: [PendingProposal] = [],
                issues: [ProposalIssue] = [],
                corrections: [String] = [],
                mergedDuplicates: Int = 0,
                truncationNotice: String? = nil) {
        self.commands = commands; self.needsConfirmation = needsConfirmation
        self.issues = issues; self.corrections = corrections
        self.mergedDuplicates = mergedDuplicates; self.truncationNotice = truncationNotice
    }

    public var isEmpty: Bool {
        commands.isEmpty && needsConfirmation.isEmpty && issues.isEmpty
    }

    public var totalItemCount: Int {
        commands.count + needsConfirmation.count + issues.count
    }
}

// MARK: - 校验器

public enum ProposalValidator {

    /// 把一次模型输出校验为「可执行命令 + 待确认项 + 收件箱项」。
    public static func validate(proposal: AIProposal,
                                input: AIInput,
                                plans: [Plan],
                                tasks: [UUID: Task],
                                metrics: [UUID: PlanMetric],
                                occurrences: [UUID: RecurrenceOccurrence],
                                today: DateOnly,
                                timeZone: TimeZone,
                                defaults: AppDefaults,
                                deviceId: String,
                                captureID: UUID?,
                                source: SourceKind) -> ValidatedProposal {

        // 命令在用户确认后由 `materializeBatch` 生成，校验阶段只产出待确认项与未过项。
        let commands: [any DomainCommand] = []
        let commandKeys: [UUID: String] = [:]
        var needsConfirmation: [PendingProposal] = []
        var issues: [ProposalIssue] = []
        var corrections: [String] = []
        var mergedDuplicates = 0
        var truncationNotice: String?

        let planByID = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let characters = Array(input.text)

        var items = proposal.items
        if items.count > defaults.ai.maxItemsPerInput {
            let dropped = items.count - defaults.ai.maxItemsPerInput
            items = Array(items.prefix(defaults.ai.maxItemsPerInput))
            truncationNotice = "这次内容较多，先处理前 \(items.count) 项，另有 \(dropped) 项已放进收件箱。"
        }

        // MARK: 批内临时引用与结构前置扫描
        var declaredPlanRefs: Set<String> = []
        var declaredStageRefs: [String: String] = [:] // stageRef -> planRef
        var declaredTaskRefs: Set<String> = []
        var allDeclaredRefs: Set<String> = []
        var duplicateRefs: Set<String> = []
        var parentRefs: [String: String] = [:] // childRef -> parentRef
        var recurrenceRefs: Set<String> = []

        func registerRef(_ raw: String?) {
            guard let raw, !raw.isEmpty else { return }
            if !allDeclaredRefs.insert(raw).inserted {
                duplicateRefs.insert(raw)
            }
        }

        for item in items {
            if let p = item.plan {
                registerRef(p.ref)
                if let pr = p.ref { declaredPlanRefs.insert(pr) }
                for s in p.stages {
                    registerRef(s.ref)
                    if let sr = s.ref { declaredStageRefs[sr] = p.ref ?? "" }
                }
                for t in p.tasks {
                    registerRef(t.ref)
                    if let tr = t.ref {
                        declaredTaskRefs.insert(tr)
                        if let pr = t.parentRef { parentRefs[tr] = pr }
                        if t.recurrence != nil { recurrenceRefs.insert(tr) }
                    }
                    for step in t.steps {
                        registerRef(step.ref)
                        if let sr = step.ref, let pr = step.parentRef { parentRefs[sr] = pr }
                    }
                }
            }
            if item.action == .createTask, let t = item.task {
                registerRef(t.ref)
                if let tr = t.ref {
                    declaredTaskRefs.insert(tr)
                    if let pr = t.parentRef { parentRefs[tr] = pr }
                    if t.recurrence != nil || item.recurrence != nil { recurrenceRefs.insert(tr) }
                }
                for step in t.steps {
                    registerRef(step.ref)
                    if let sr = step.ref, let pr = step.parentRef { parentRefs[sr] = pr }
                }
            }
        }

        if !duplicateRefs.isEmpty {
            issues.append(ProposalIssue(
                itemID: items.first?.id ?? "batch",
                sourceSpan: nil,
                reasons: [.structureViolation("批内临时引用 ref 重复定义：\(duplicateRefs.joined(separator: ", "))")]))
        }

        for (child, parent) in parentRefs {
            let isParentKnown = allDeclaredRefs.contains(parent)
                || (UUID(uuidString: parent).map { input.allowedTaskIDs.contains($0) } ?? false)
            if !isParentKnown {
                issues.append(ProposalIssue(
                    itemID: child, sourceSpan: nil,
                    reasons: [.unknownReference(parent)]))
            }
            // 环检测
            var visited = Set<String>()
            var curr: String? = parent
            while let c = curr {
                if c == child {
                    issues.append(ProposalIssue(
                        itemID: child, sourceSpan: nil,
                        reasons: [.structureViolation("任务父子关系存在循环引用：\(child) 与 \(parent)")]))
                    break
                }
                if !visited.insert(c).inserted { break }
                curr = parentRefs[c]
            }
        }

        for rec in recurrenceRefs {
            if parentRefs[rec] != nil {
                issues.append(ProposalIssue(
                    itemID: rec, sourceSpan: nil,
                    reasons: [.structureViolation("重复任务模板不能放在其它待办下面")]))
            }
            for (child, parent) in parentRefs where parent == rec {
                if !declaredTaskRefs.contains(child) { continue }
                issues.append(ProposalIssue(
                    itemID: child, sourceSpan: nil,
                    reasons: [.structureViolation("重复任务模板不能包含普通子任务，只能包含步骤")]))
            }
        }

        var dedupKeys: Set<String> = []

        for var item in items {
            // 模型容易算错中文/emoji 偏移；只有原文片段唯一精确命中时才修正。
            if let source = item.sourceSpan, !source.isEmpty,
               let range = input.text.range(of: source),
               input.text.range(of: source, range: range.upperBound..<input.text.endIndex) == nil {
                item.span = [input.text.distance(from: input.text.startIndex, to: range.lowerBound),
                             input.text.distance(from: input.text.startIndex, to: range.upperBound)]
            }
            // MARK: V1 原文一致性（定位必须落在发送文本范围内）
            guard item.span.count == 2,
                  item.span[0] >= 0, item.span[1] <= characters.count,
                  item.span[0] < item.span[1] else {
                issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                            reasons: [.spanOutOfRange],
                                            suggestedAction: "可以手动整理这一段。"))
                continue
            }
            let spanText = String(characters[item.span[0]..<item.span[1]])

            if let declared = item.sourceSpan, !declared.isEmpty {
                let actual = spanText.trimmingCharacters(in: .whitespacesAndNewlines)
                let claimed = declared.trimmingCharacters(in: .whitespacesAndNewlines)
                if actual != claimed {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("模型引用的片段与原文不一致，请编辑后重试")]))
                    continue
                }
            }

            // MARK: V2 动作与数据块匹配
            if !item.extraBlocks.isEmpty {
                issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                            reasons: [.mismatchedDataBlock]))
                continue
            }

            // MARK: V11 同批去重
            var dedupKey = item.action.rawValue + "|" + spanText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let target = item.task?.candidateTaskId { dedupKey += "|" + target }
            if let start = item.task?.startAt { dedupKey += "|" + start }
            if let end = item.task?.endAt { dedupKey += "|" + end }
            if let title = item.task?.title { dedupKey += "|" + title }
            if let name = item.plan?.name { dedupKey += "|" + name }
            guard dedupKeys.insert(dedupKey).inserted else {
                mergedDuplicates += 1
                continue
            }

            let spec = item.task

            switch item.action {

            case .createPlan:
                guard let plan = item.plan else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("缺少计划名称或有效类型")]))
                    continue
                }
                do { try StructurePolicy.validatePlanName(plan.name) }
                catch {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("计划名称无效")]))
                    continue
                }
                let planStart = Self.parseTime(plan.startAt, timeZone: timeZone)
                let planEnd = Self.parseTime(plan.endAt, timeZone: timeZone)
                guard planStart.isValid, planEnd.isValid else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unparsableDate]))
                    continue
                }
                if let s = planStart.point, let e = planEnd.point, e.isEarlier(than: s) {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("计划的结束时间早于开始时间")]))
                    continue
                }
                guard plan.tasks.count <= defaults.ai.maxItemsPerInput else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("计划待办过多，请分次整理")]))
                    continue
                }

                var stageIssues: [ProposalIssue] = []
                for stage in plan.stages {
                    do { try StructurePolicy.validateStageName(stage.name) }
                    catch {
                        stageIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                         reasons: [.structureViolation("阶段名称无效")]))
                    }
                    let sStart = Self.parseTime(stage.startAt, timeZone: timeZone)
                    let sEnd = Self.parseTime(stage.endAt, timeZone: timeZone)
                    guard sStart.isValid, sEnd.isValid else {
                        stageIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                         reasons: [.unparsableDate]))
                        continue
                    }
                    if let s = sStart.point, let e = sEnd.point, e.isEarlier(than: s) {
                        stageIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                         reasons: [.structureViolation("阶段结束时间早于开始时间")]))
                    }
                    if let s = sStart.point, let ps = planStart.point, s.isEarlier(than: ps) {
                        stageIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                         reasons: [.structureViolation("阶段时间早于计划开始时间")]))
                    }
                    if let e = sEnd.point, let pe = planEnd.point, pe.isEarlier(than: e) {
                        stageIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                         reasons: [.structureViolation("阶段时间晚于计划结束时间")]))
                    }
                }
                guard stageIssues.isEmpty else { issues += stageIssues; continue }

                var taskIssues: [ProposalIssue] = []
                for task in plan.tasks {
                    let title = (task.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, title.count <= Task.maxTitleLength else {
                        taskIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                        reasons: [.structureViolation("计划待办缺少有效标题")]))
                        continue
                    }
                    // 直接写 UUID 的归属必须真实存在；批内临时引用走 `stage_ref` / `parent_ref` 前置扫描。
                    if let rawStage = task.stageId, !rawStage.isEmpty {
                        guard let sUUID = UUID(uuidString: rawStage), input.allowedStageIDs.contains(sUUID) else {
                            taskIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                            reasons: [.unknownReference(rawStage)]))
                            continue
                        }
                    }
                    if let rawParent = task.parentTaskId, !rawParent.isEmpty {
                        guard let pUUID = UUID(uuidString: rawParent), input.allowedTaskIDs.contains(pUUID) else {
                            taskIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                            reasons: [.unknownReference(rawParent)]))
                            continue
                        }
                    }
                    let tStart = Self.parseTime(task.startAt, timeZone: timeZone)
                    let tEnd = Self.parseTime(task.endAt, timeZone: timeZone)
                    guard tStart.isValid, tEnd.isValid else {
                        taskIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                        reasons: [.unparsableDate]))
                        continue
                    }
                    if let s = tStart.point, let e = tEnd.point, e.isEarlier(than: s) {
                        taskIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                        reasons: [.structureViolation("待办结束时间早于开始时间")]))
                    }
                    if let s = tStart.point, let ps = planStart.point, s.isEarlier(than: ps) {
                        taskIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                        reasons: [.structureViolation("待办时间早于计划开始时间")]))
                    }
                    if let e = tEnd.point, let pe = planEnd.point, pe.isEarlier(than: e) {
                        taskIssues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                        reasons: [.structureViolation("待办时间晚于计划结束时间")]))
                    }
                }
                guard taskIssues.isEmpty else { issues += taskIssues; continue }

                var lines = [ImpactPreview.ImpactLine(entityId: UUID(), title: "计划类型", changeText: plan.kind.displayName)]
                if let goal = plan.goal { lines.append(.init(entityId: UUID(), title: "目标", changeText: goal)) }
                if let date = plan.startAt { lines.append(.init(entityId: UUID(), title: "开始时间", changeText: date)) }
                if let date = plan.endAt { lines.append(.init(entityId: UUID(), title: "结束时间", changeText: date)) }
                for stage in plan.stages {
                    lines.append(.init(entityId: UUID(), title: "包含阶段", changeText: stage.name))
                }
                lines += plan.tasks.map { task in
                    let details = [task.startAt.map { "开始 \($0)" },
                                   task.endAt.map { "结束 \($0)" }, task.notes].compactMap { $0 }
                    return .init(entityId: UUID(), title: "新增：\(task.title ?? "")",
                                 changeText: details.isEmpty ? "未安排" : details.joined(separator: " · "))
                }
                needsConfirmation.append(PendingProposal(id: item.id, item: item,
                                                         affectedSummary: plan.name,
                                                         changeSummary: lines, kind: .planCreation))

            // MARK: needs_clarification
            case .needsClarification:
                issues.append(ProposalIssue(
                    itemID: item.id, sourceSpan: item.sourceSpan,
                    reasons: [.structureViolation(item.clarificationQuestion ?? "这条信息不足，需要你补充说明")],
                    suggestedAction: "补充说明后可重新整理"))

            // MARK: create_task
            case .createTask:
                let rawTitle = (spec?.title ?? spanText).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawTitle.isEmpty else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.emptyTitle]))
                    continue
                }
                var title = rawTitle
                if rawTitle.count > Task.maxTitleLength {
                    title = String(rawTitle.prefix(Task.maxTitleLength))
                    corrections.append("标题超过 \(Task.maxTitleLength) 字，已截断保存。")
                }

                var planID: UUID?
                if let raw = spec?.planId, !raw.isEmpty {
                    if let uuid = UUID(uuidString: raw) {
                        guard input.allowedPlanIDs.contains(uuid), planByID[uuid] != nil else {
                            issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                        reasons: [.unknownReference(raw)]))
                            continue
                        }
                        if planByID[uuid]?.status == .archived {
                            issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                        reasons: [.planArchived]))
                            continue
                        }
                        planID = uuid
                    } else if !declaredPlanRefs.contains(raw) {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.unknownReference(raw)]))
                        continue
                    }
                }

                if let stageID = spec?.stageId, !stageID.isEmpty {
                    guard let sUUID = UUID(uuidString: stageID), input.allowedStageIDs.contains(sUUID) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.unknownReference(stageID)]))
                        continue
                    }
                }

                if let rawParent = spec?.parentTaskId, !rawParent.isEmpty {
                    // 重复行动只能挂步骤，不能当别人的子任务——与其父 ID 是否存在无关，先判这条。
                    if (spec?.recurrence ?? item.recurrence)?.pattern != nil {
                        issues.append(ProposalIssue(
                            itemID: item.id, sourceSpan: item.sourceSpan,
                            reasons: [.structureViolation("重复任务模板不能放在其它待办下面")]))
                        continue
                    }
                    guard let pUUID = UUID(uuidString: rawParent), input.allowedTaskIDs.contains(pUUID) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.unknownReference(rawParent)]))
                        continue
                    }
                }

                let parsedStart = Self.parseTime(spec?.startAt, timeZone: timeZone)
                let parsedEnd = Self.parseTime(spec?.endAt, timeZone: timeZone)
                guard parsedStart.isValid, parsedEnd.isValid else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unparsableDate]))
                    continue
                }
                var startAt = parsedStart.point
                let endAt = parsedEnd.point
                if let start = startAt, start.dateOnly < today {
                    corrections.append("开始时间早于今天，已改为今天。")
                    startAt = .day(today)
                }
                if let start = startAt, let end = endAt, end.isEarlier(than: start) {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("结束时间早于开始时间")]))
                    continue
                }

                var changeLines: [ImpactPreview.ImpactLine] = []
                let details = [startAt.map { "开始 \($0.displayString)" },
                               endAt.map { "结束 \($0.displayString)" }, spec?.notes].compactMap { $0 }
                let subText = details.isEmpty ? "未安排时间" : details.joined(separator: " · ")
                changeLines.append(ImpactPreview.ImpactLine(entityId: planID ?? UUID(), title: title, changeText: subText))
                if let rec = spec?.recurrence ?? item.recurrence, let p = rec.pattern {
                    changeLines.append(ImpactPreview.ImpactLine(entityId: UUID(), title: "重复", changeText: p))
                }
                for step in (spec?.steps ?? []) {
                    changeLines.append(ImpactPreview.ImpactLine(entityId: UUID(), title: "步骤", changeText: step.title))
                }

                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item, affectedSummary: title,
                    changeSummary: changeLines,
                    kind: .taskCreation))

            // MARK: schedule_existing_task
            case .scheduleExistingTask:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }
                var start: TimePoint = .day(today)
                let parsedStart = Self.parseTime(spec?.startAt, timeZone: timeZone)
                guard parsedStart.isValid else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unparsableDate]))
                    continue
                }
                if let parsed = parsedStart.point {
                    if parsed.dateOnly < today {
                        corrections.append("开始时间早于今天，已改为今天。")
                    } else {
                        start = parsed
                    }
                }
                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item, affectedSummary: task.title,
                    changeSummary: [ImpactPreview.ImpactLine(
                        entityId: taskID, title: task.title,
                        changeText: "安排到 \(start.displayString)")],
                    kind: .taskSchedule))

            // MARK: update_task
            case .updateTask:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }

                let parsedEnd = Self.parseTime(spec?.endAt, timeZone: timeZone)
                guard parsedEnd.isValid else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unparsableDate]))
                    continue
                }
                let endAt = parsedEnd.point

                let parsedStart = Self.parseTime(spec?.startAt, timeZone: timeZone)
                guard parsedStart.isValid else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unparsableDate]))
                    continue
                }
                var startAt = parsedStart.point
                if let start = startAt, start.dateOnly < today {
                    corrections.append("开始时间早于今天，已改为今天。")
                    startAt = .day(today)
                }

                var patch = TaskPatch()
                if let rawTitle = spec?.title {
                    let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        patch.title = trimmed.count > Task.maxTitleLength
                            ? String(trimmed.prefix(Task.maxTitleLength)) : trimmed
                    }
                }
                if let notes = spec?.notes { patch.notes = notes }
                if let startAt { patch.startAt = startAt }
                if let endAt { patch.endAt = endAt }
                if let priority = spec?.priority,
                   let parsed = TaskPriority(rawValue: normalizePriority(priority)) {
                    patch.priority = parsed
                }
                if let estimate = spec?.estimateMinutes { patch.estimateMinutes = estimate }
                if let tags = spec?.tags, !tags.isEmpty { patch.tags = tags }
                if let stage = spec?.stageId.flatMap({ UUID(uuidString: $0) }) { patch.stageID = stage }
                if let rawPlan = spec?.planId, let planUUID = UUID(uuidString: rawPlan) {
                    guard input.allowedPlanIDs.contains(planUUID) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.unknownReference(rawPlan)]))
                        continue
                    }
                    patch.planID = planUUID
                }
                guard !patch.isEmpty else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.mismatchedDataBlock],
                                                suggestedAction: "这条没有需要修改的字段。"))
                    continue
                }

                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item, affectedSummary: task.title,
                    changeSummary: [ImpactPreview.ImpactLine(
                        entityId: taskID, title: task.title,
                        changeText: "修改待办信息",
                        oldValue: task.endAt?.displayString,
                        newValue: endAt?.displayString)],
                    kind: endAt != nil ? .deadlineChange : .taskUpdate))

            // MARK: complete_task
            case .completeTask:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }
                if task.status == .done {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.completedCannotComplete]))
                    continue
                }
                if task.status == .cancelled {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.unknownReference(raw)]))
                    continue
                }
                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item, affectedSummary: task.title,
                    changeSummary: [ImpactPreview.ImpactLine(
                        entityId: taskID, title: task.title, changeText: "标记完成")],
                    kind: .taskCompletion))

            // MARK: match_occurrence
            case .matchOccurrence:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }
                let day = resolvedDay(item: item, spec: spec, today: today, timeZone: timeZone) ?? today
                if task.isTemplate {
                    needsConfirmation.append(PendingProposal(
                        id: item.id, item: item, affectedSummary: task.title,
                        changeSummary: [ImpactPreview.ImpactLine(
                            entityId: taskID, title: task.title,
                            changeText: "完成 \(day.iso8601DateString) 的执行实例")],
                        kind: .taskCompletion))
                } else {
                    needsConfirmation.append(PendingProposal(
                        id: item.id, item: item, affectedSummary: task.title,
                        changeSummary: [ImpactPreview.ImpactLine(
                            entityId: taskID, title: task.title,
                            changeText: "安排到 \(day.iso8601DateString)")],
                        kind: .taskSchedule))
                }

            // MARK: log_activity
            case .logActivity:
                guard let rawPlan = spec?.planId, let planID = UUID(uuidString: rawPlan),
                      input.allowedPlanIDs.contains(planID), planByID[planID] != nil else {
                    issues.append(ProposalIssue(
                        itemID: item.id, sourceSpan: item.sourceSpan,
                        reasons: [.requiresCandidateTask],
                        suggestedAction: "去补充这条记录属于哪个计划。"))
                    continue
                }
                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item,
                    affectedSummary: planByID[planID]?.name ?? "行动记录",
                    changeSummary: [ImpactPreview.ImpactLine(
                        entityId: planID, title: planByID[planID]?.name ?? "计划",
                        changeText: "记录行动：\(item.note?.text ?? spanText)")],
                    kind: .activityLog))

            // MARK: record_measurement
            case .recordMeasurement:
                guard let measurement = item.measurement,
                      let value = measurement.value, value.isFinite else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.invalidMeasurementValue]))
                    continue
                }
                guard let rawMetric = measurement.metricId, let metricID = UUID(uuidString: rawMetric),
                      input.allowedMetricIDs.contains(metricID), let metric = metrics[metricID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask],
                                                suggestedAction: "去选择一个结果指标。"))
                    continue
                }
                var measuredAt = today
                if let rawDate = measurement.measuredAt, !rawDate.isEmpty {
                    guard let day = DateOnly(iso8601DateString: Self.dayPrefix(rawDate),
                                             sourceTZ: timeZone.identifier) else {
                        issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                    reasons: [.unparsableDate]))
                        continue
                    }
                    measuredAt = day
                }
                let unit = (measurement.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                item.measurement?.measuredAt = measuredAt.iso8601DateString
                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item,
                    affectedSummary: "\(metric.name) \(formatValue(value))",
                    changeSummary: [ImpactPreview.ImpactLine(
                        entityId: metricID, title: metric.name,
                        changeText: "记录结果：\(formatValue(value))\(metric.unitDisplayName)",
                        oldValue: metric.unitDisplayName, newValue: unit.isEmpty ? nil : unit)],
                    kind: .measurementUnitUnclear))

            // MARK: save_note
            case .saveNote:
                let text = (item.note?.text ?? spanText).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.emptyTitle]))
                    continue
                }
                var planID: UUID?
                if let raw = spec?.planId, let id = UUID(uuidString: raw) {
                    guard input.allowedPlanIDs.contains(id) else {
                        issues.append(ProposalIssue(
                            itemID: item.id, sourceSpan: item.sourceSpan,
                            reasons: [.unknownReference(raw)],
                            suggestedAction: "可以手动归类。"))
                        continue
                    }
                    planID = id
                }
                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item,
                    affectedSummary: text,
                    changeSummary: [ImpactPreview.ImpactLine(
                        entityId: planID ?? UUID(), title: "想法备忘", changeText: text)],
                    kind: .noteCreation))

            // MARK: set_recurrence
            case .setRecurrence:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }
                if tasks.values.contains(where: { $0.parentId == taskID && !$0.isStep }) {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.structureViolation("该待办带有普通子任务，不能直接设为重复行动")]))
                    continue
                }
                guard let recurrence = item.recurrence,
                      let patternRaw = recurrence.pattern,
                      let pattern = RecurrencePattern(rawValue: patternRaw) else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.incompleteRecurrence]))
                    continue
                }
                if pattern == .weekdays, recurrence.weekdays.isEmpty {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.incompleteRecurrence]))
                    continue
                }
                if pattern == .weeklyCount, !(1...7).contains(recurrence.count ?? 0) {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.incompleteRecurrence]))
                    continue
                }
                let summary = pattern == .weeklyCount
                    ? "每周 \(recurrence.count ?? 0) 次" : pattern.displayName
                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item, affectedSummary: task.title,
                    changeSummary: [ImpactPreview.ImpactLine(
                        entityId: taskID, title: task.title,
                        changeText: "重复频率调整为「\(summary)」，只作用于生效日及以后")],
                    kind: .recurrenceChange))

            // MARK: set_dependency
            case .setDependency:
                guard let raw = spec?.candidateTaskId, let taskID = UUID(uuidString: raw),
                      input.allowedTaskIDs.contains(taskID), let task = tasks[taskID] else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.requiresCandidateTask]))
                    continue
                }
                let rawDeps = spec?.dependencyIds ?? []
                let depIDs = rawDeps.compactMap { UUID(uuidString: $0) }
                guard !depIDs.isEmpty, depIDs.count == rawDeps.count,
                      depIDs.allSatisfy({ input.allowedTaskIDs.contains($0) && tasks[$0] != nil }) else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.dependencyInvalid]))
                    continue
                }
                guard depIDs.allSatisfy({ tasks[$0]?.planId == task.planId }),
                      !depIDs.contains(taskID),
                      !depIDs.contains(where: { wouldCreateCycle(taskID: taskID, dependsOn: $0, tasks: tasks) }) else {
                    issues.append(ProposalIssue(itemID: item.id, sourceSpan: item.sourceSpan,
                                                reasons: [.dependencyInvalid]))
                    continue
                }
                needsConfirmation.append(PendingProposal(
                    id: item.id, item: item, affectedSummary: task.title,
                    dependencyChanges: depIDs.map { tasks[$0]?.title ?? $0.uuidString },
                    changeSummary: depIDs.map { dep in
                        ImpactPreview.ImpactLine(
                            entityId: taskID, title: task.title,
                            changeText: "先完成「\(tasks[dep]?.title ?? "前置任务")」")
                    },
                    kind: .dependencySuggestion))
            }
        }

        var result = ValidatedProposal(commands: commands, needsConfirmation: needsConfirmation,
                                 issues: issues, corrections: corrections,
                                 mergedDuplicates: mergedDuplicates,
                                 truncationNotice: truncationNotice)
        result.commandKeys = commandKeys
        return result
    }

    // MARK: - 私有工具

    /// `2026-09-30T07:00:00Z` → `2026-09-30`
    static func dayPrefix(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
    }

    /// 解析硬截止。ISO8601（含时区）→ 保留其时刻；退化为「某天」→ 当天正午。
    static func parseDeadline(_ raw: String, fallbackTZ: TimeZone) -> DateTimeTZ? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) {
            if text.hasSuffix("Z") || text.contains("+") {
                return DateTimeTZ(epoch: date, tzID: "UTC")
            }
            return DateTimeTZ(date, in: fallbackTZ)
        }
        if let day = DateOnly(iso8601DateString: dayPrefix(text), sourceTZ: fallbackTZ.identifier) {
            return DateTimeTZ(day.noon, in: fallbackTZ)
        }
        return nil
    }

    /// 解析 AI 给出的起止时间。空串视为没填；无法解析时 `isValid == false`。
    static func parseTime(_ raw: String?, timeZone: TimeZone) -> (point: TimePoint?, isValid: Bool) {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, true) }
        guard let point = TimePoint.parse(raw, fallbackTZ: timeZone) else { return (nil, false) }
        return (point, true)
    }

    /// 模型给的优先级字符串 → `TaskPriority.rawValue`
    static func normalizePriority(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "高", "紧急", "urgent", "p1": return TaskPriority.high.rawValue
        case "low", "低", "p3": return TaskPriority.low.rawValue
        case "normal", "普通", "中", "medium", "p2": return TaskPriority.normal.rawValue
        default: return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// 由 AI 推断的字段标「建议」（PRD 4.2）
    static func suggestedFields(for item: AIProposalItem, taskSpec: AIProposalTask) -> [String] {
        var fields: [String] = []
        if taskSpec.planId != nil { fields.append("planId") }
        if taskSpec.startAt != nil, item.dateInterpretation?.resolvedDate == nil {
            fields.append("startAt")
        }
        if taskSpec.priority != nil { fields.append("priority") }
        if !taskSpec.dependencyIds.isEmpty { fields.append("dependencyIDs") }
        return fields
    }

    /// 已解析的日期（优先 date_interpretation.resolved_date，其次 start_at）
    static func resolvedDay(item: AIProposalItem, spec: AIProposalTask?,
                            today: DateOnly, timeZone: TimeZone) -> DateOnly? {
        let raw = item.dateInterpretation?.resolvedDate ?? spec?.startAt
        guard let raw, !raw.isEmpty else { return nil }
        guard let day = DateOnly(iso8601DateString: dayPrefix(raw), sourceTZ: timeZone.identifier) else {
            return nil
        }
        return day < today ? today : day
    }

    /// 依赖成环检测（C9）
    static func wouldCreateCycle(taskID: UUID, dependsOn: UUID, tasks: [UUID: Task]) -> Bool {
        var stack = [dependsOn]
        var visited: Set<UUID> = []
        while let current = stack.popLast() {
            if current == taskID { return true }
            guard visited.insert(current).inserted else { continue }
            stack.append(contentsOf: tasks[current]?.dependencyIDs ?? [])
        }
        return false
    }

    /// `12` → `12`；`12.5` → `12.5`
    static func formatValue(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
