//
//  PlanFileImport.swift
//  Data/Export
//
//  导入 `.movo.json`：解析 → 生成命令 → 在临时存储里预演 → 预览 → 作为一个批次写入。
//  · 校验与手动创建完全一致：命令走 `StructurePolicy`，不另建一套规则。
//  · 不合法的条目在预览里逐条标出，不静默丢弃；通过检查的部分仍可导入。
//  · 默认生成新 id；外部 id 是 UUID（Movo 导出的文件）时按稳定规则映射，用来识别重复导入。
//

import Foundation
import CryptoKit

// MARK: - 对外类型

public enum PlanImportDuplicateMode: String, Sendable, CaseIterable, Identifiable {
    /// 已经导入过（或原数据还在）的计划、任务跳过
    case skip
    /// 重复的也导入，全部使用新 id
    case saveCopy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .skip: "跳过已有的"
        case .saveCopy: "另存一份"
        }
    }
}

public struct PlanImportIssue: Identifiable, Hashable, Sendable {
    public enum Severity: String, Sendable { case error, warning }

    public let id = UUID()
    public var severity: Severity
    /// 出问题的位置，如「计划「减脂」 / 任务「跑步」」
    public var path: String
    public var message: String

    public init(severity: Severity, path: String, message: String) {
        self.severity = severity; self.path = path; self.message = message
    }
}

public struct ImportParentCandidate: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    /// 在计划任务树里的层级，0 为顶层
    public let depth: Int
}

public struct PlanImportSummary: Sendable, Equatable {
    public var plans = 0
    public var stages = 0
    public var metrics = 0
    public var tasks = 0
    public var recurring = 0
    public var steps = 0
    public var records = 0
    public var measurements = 0
    public var notes = 0
    /// 因为已经导入过而跳过的计划或任务名称
    public var skippedDuplicates: [String] = []

    public var isEmpty: Bool {
        plans + stages + metrics + tasks + recurring + steps + records + measurements + notes == 0
    }
}

/// 一次导入的预演结果：只含通过检查、可以写入的命令。
public struct PlanImportPlan: Sendable {
    public var summary: PlanImportSummary
    public var issues: [PlanImportIssue]
    var commands: [PlannedImportCommand]

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    public var canImport: Bool { !commands.isEmpty }
}

struct PlannedImportCommand: Sendable {
    enum Category: Sendable { case plan, stage, metric, task, recurring, step, dependency, status, record, measurement, note }

    var command: any DomainCommand
    var category: Category
    var label: String
    /// 必须先创建成功的实体；其中任何一个失败，这条命令就不再执行
    var requires: [UUID]

    /// 创建实体的命令失败时，依赖它的后续命令一并跳过
    var createsEntity: Bool {
        switch category {
        case .plan, .stage, .metric, .task, .recurring, .step: true
        default: false
        }
    }
}

// MARK: - 导入器

@MainActor
public enum PlanFileImporter {

    /// 读取并校验文件。不合法时抛 `PlanFileError`。
    public static func load(_ data: Data) throws -> PlanFile {
        try PlanFileCodec.decode(data)
    }

    /// 生成导入计划：逐项转换、预演、汇总问题。纯读取，不写入真实数据。
    /// `targetPlanID` 非空时，文件顶层的阶段、指标、任务、记录、测量值、笔记都放进这个已有计划。
    /// `targetTaskID` 非空时（需要同时指定目标计划），顶层 `tasks` 作为这个任务的子任务导入。
    public static func makePlan(file: PlanFile, store: DomainStore,
                                duplicateMode: PlanImportDuplicateMode,
                                targetPlanID: UUID? = nil,
                                targetTaskID: UUID? = nil) async -> PlanImportPlan {
        var builder = Builder(tz: store.currentTimeZone, today: store.today, now: store.now,
                              mode: duplicateMode)
        var skipped: [String] = []

        for (index, plan) in (file.plans ?? []).enumerated() {
            if duplicateMode == .skip, await exists(plan.id, in: store, as: .plan) {
                skipped.append("计划「\(plan.name)」")
                continue
            }
            builder.addPlan(plan, index: index)
        }

        var looseScope = PlanScope(planID: nil, ids: IDMap(mode: duplicateMode))
        var target: ExistingPlan?
        var loosePath = "独立内容"
        if let targetPlanID, let existing = await loadExisting(targetPlanID, store: store) {
            target = existing
            looseScope.planID = existing.plan.id
            for stage in existing.stages {
                looseScope.stageByExt[stage.id.uuidString] = stage.id
                if looseScope.stageByName[stage.name] == nil { looseScope.stageByName[stage.name] = stage.id }
            }
            for metric in existing.metrics {
                looseScope.metricByExt[metric.id.uuidString] = metric.id
                if looseScope.metricByName[metric.name] == nil { looseScope.metricByName[metric.name] = metric.id }
            }
            for task in existing.tasks { looseScope.taskByExt[task.id.uuidString] = task.id }
            loosePath = "已有计划「\(existing.plan.name)」"
        }

        if let target {
            for (order, stage) in (file.stages ?? []).enumerated() {
                builder.addStage(stage, order: target.stages.count + order, scope: &looseScope,
                                 planPath: loosePath)
            }
            for metric in file.metrics ?? [] {
                builder.addMetric(metric, scope: &looseScope, planPath: loosePath)
            }
        } else {
            builder.requirePlan(for: "阶段", count: file.stages?.count ?? 0)
            builder.requirePlan(for: "指标", count: file.metrics?.count ?? 0)
            builder.requirePlan(for: "行动记录", count: file.records?.count ?? 0)
            builder.requirePlan(for: "测量值", count: file.measurements?.count ?? 0)
        }
        // 子任务的上级必须是未完成的普通待办：重复行动下只能是步骤，已完成的任务下不该再添新的未完成子任务
        var parent: (id: UUID, stage: UUID?)?
        var tasksBlocked = false
        var taskPrefix = target == nil ? "独立待办 / " : loosePath + " / "
        if let targetTaskID, let target {
            if let task = target.tasks.first(where: { $0.id == targetTaskID }),
               !task.isTemplate, task.status.isOpen {
                parent = (id: task.id, stage: task.stageId)
                taskPrefix = loosePath + " / 任务「\(task.title)」 / "
            } else {
                builder.report(.error, loosePath,
                               "选中的任务不能放新的子任务（需要是未完成的普通待办，重复行动请用步骤）。文件里的待办没有导入。")
                tasksBlocked = true
            }
        }
        for task in file.tasks ?? [] where !tasksBlocked {
            if duplicateMode == .skip, await exists(task.id, in: store, as: .task) {
                skipped.append("待办「\(task.title)」")
                continue
            }
            builder.addTask(task, scope: &looseScope, parent: parent, pathPrefix: taskPrefix)
        }
        builder.finish(scope: &looseScope, pathPrefix: loosePath + " / ")
        if target != nil {
            for record in file.records ?? [] {
                builder.addRecord(record, scope: &looseScope, planPath: loosePath)
            }
            for item in file.measurements ?? [] {
                builder.addMeasurement(item, scope: &looseScope, planPath: loosePath)
            }
        }
        for note in file.notes ?? [] {
            builder.addNote(note, planID: looseScope.planID, scope: &looseScope, path: loosePath)
        }

        return await dryRun(builder, store: store, skipped: skipped, existing: target)
    }

    /// 导入页用：文件顶层是否有必须放进某个计划才能导入的内容
    public static func needsTargetPlan(_ file: PlanFile) -> Bool {
        !(file.stages ?? []).isEmpty || !(file.metrics ?? []).isEmpty
            || !(file.records ?? []).isEmpty || !(file.measurements ?? []).isEmpty
    }

    /// 导入页用：文件顶层是否有可以放进已有计划的内容
    public static func hasLooseContent(_ file: PlanFile) -> Bool {
        needsTargetPlan(file) || !(file.tasks ?? []).isEmpty || !(file.notes ?? []).isEmpty
    }

    /// 导入页用：计划里可以放新子任务的任务（未完成的普通待办），按层级排好并带缩进深度
    public static func parentCandidates(planID: UUID, store: DomainStore) async -> [ImportParentCandidate] {
        let deleted = Set(await store.repository.tombstones(activeOnly: true).map(\.entityId))
        let tasks = await store.repository.tasks(planID: planID)
            .filter { !deleted.contains($0.id) && !$0.isStep }
        let ids = Set(tasks.map(\.id))
        let byParent = Dictionary(grouping: TaskHierarchy.ordered(tasks), by: \.parentId)
        var out: [ImportParentCandidate] = []
        var seen: Set<UUID> = []
        func walk(_ task: Task, depth: Int) {
            guard seen.insert(task.id).inserted else { return }
            if !task.isTemplate, task.status.isOpen {
                out.append(ImportParentCandidate(id: task.id, title: task.title, depth: depth))
            }
            for child in byParent[task.id] ?? [] { walk(child, depth: depth + 1) }
        }
        for task in tasks where task.parentId == nil || !ids.contains(task.parentId!) { walk(task, depth: 0) }
        return out
    }

    private static func loadExisting(_ id: UUID, store: DomainStore) async -> ExistingPlan? {
        guard let plan = await store.repository.plan(id) else { return nil }
        let deleted = Set(await store.repository.tombstones(activeOnly: true).map(\.entityId))
        let stages = await store.repository.stages(planID: id).filter { !deleted.contains($0.id) }
        let metrics = await store.repository.metrics(planID: id).filter { !deleted.contains($0.id) }
        let tasks = await store.repository.tasks(planID: id).filter { !deleted.contains($0.id) }
        return ExistingPlan(plan: plan, stages: stages, metrics: metrics, tasks: tasks)
    }

    /// 把预演通过的命令作为一个批次写入。可通过结果条撤销。
    public static func apply(_ plan: PlanImportPlan, store: DomainStore) async throws -> BatchResult {
        let s = plan.summary
        var parts: [String] = []
        if s.plans > 0 { parts.append("\(s.plans) 个计划") }
        let taskCount = s.tasks + s.recurring
        if taskCount > 0 { parts.append("\(taskCount) 项待办") }
        let summary = parts.isEmpty ? "导入文件" : "导入 " + parts.joined(separator: "、")
        return try await store.executeBatchAllowingPartial(
            BatchInput(source: .userManual, commands: plan.commands.map(\.command), summary: summary))
    }

    // MARK: 预演

    private static func dryRun(_ builder: Builder, store: DomainStore,
                               skipped: [String], existing: ExistingPlan?) async -> PlanImportPlan {
        let scratch = DomainStore(repository: InMemoryRepository(), clock: store.clock,
                                  timeZoneProvider: store.timeZoneProvider,
                                  deviceIDProvider: store.deviceIDProvider, defaults: store.defaults)
        // 目标计划已有的内容也放进临时存储，时间范围、前置和归属校验才和真实情况一致
        if let existing {
            try? await scratch.repository.upsert(existing.plan)
            for stage in existing.stages { try? await scratch.repository.upsert(stage) }
            for metric in existing.metrics { try? await scratch.repository.upsert(metric) }
            for task in existing.tasks { try? await scratch.repository.upsert(task) }
        }
        var issues = builder.issues
        var accepted: [PlannedImportCommand] = []
        var failed: Set<UUID> = []

        for planned in builder.commands {
            if planned.requires.contains(where: { failed.contains($0) }) {
                issues.append(PlanImportIssue(severity: .error, path: planned.label,
                                              message: "所属的上级内容没有通过检查，这一项也没有导入。"))
                if planned.createsEntity { failed.insert(planned.command.entityID) }
                continue
            }
            do {
                try await scratch.execute(planned.command)
                accepted.append(planned)
            } catch let error as MovoError {
                issues.append(PlanImportIssue(severity: .error, path: planned.label, message: error.message))
                if planned.createsEntity { failed.insert(planned.command.entityID) }
            } catch {
                issues.append(PlanImportIssue(severity: .error, path: planned.label,
                                              message: error.localizedDescription))
                if planned.createsEntity { failed.insert(planned.command.entityID) }
            }
        }

        var summary = PlanImportSummary()
        summary.skippedDuplicates = skipped
        for planned in accepted {
            switch planned.category {
            case .plan: summary.plans += 1
            case .stage: summary.stages += 1
            case .metric: summary.metrics += 1
            case .task: summary.tasks += 1
            case .recurring: summary.recurring += 1
            case .step: summary.steps += 1
            case .record: summary.records += 1
            case .measurement: summary.measurements += 1
            case .note: summary.notes += 1
            case .dependency, .status: break
            }
        }
        return PlanImportPlan(summary: summary, issues: issues, commands: accepted)
    }

    // MARK: 重复识别

    private enum ExistingKind { case plan, task }

    /// 外部 id 是 UUID 时：原 id 或映射后的 id 已经存在，就认为导入过。
    private static func exists(_ external: String?, in store: DomainStore, as kind: ExistingKind) async -> Bool {
        guard let key = normalized(external), let source = UUID(uuidString: key) else { return false }
        for id in [source, derivedID(for: source)] {
            switch kind {
            case .plan: if await store.repository.plan(id) != nil { return true }
            case .task: if await store.repository.task(id) != nil { return true }
            }
        }
        return false
    }

    nonisolated static func normalized(_ external: String?) -> String? {
        guard let text = external?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// 稳定映射：同一个外部 UUID 总是得到同一个新 id，且不同于原 id。
    nonisolated public static func derivedID(for source: UUID) -> UUID {
        let digest = Array(SHA256.hash(data: Data("movo.import.v1:\(source.uuidString.lowercased())".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
       ExistingPlan: Sendable {
    var plan: Plan
    var stages: [Stage]
    var metrics: [PlanMetric]
    var tasks: [Task]
}

struct  return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

// MARK: - 转换

struct ExistingPlan: Sendable {
    var plan: Plan
    var stages: [Stage]
    var metrics: [PlanMetric]
    var tasks: [Task]
}

struct IDMap {
    let mode: PlanImportDuplicateMode
    private var table: [String: UUID] = [:]

    init(mode: PlanImportDuplicateMode) { self.mode = mode }

    /// 为一个条目分配 id。同一范围内文件 id 重复时 `isDuplicate` 为真。
    mutating func define(_ external: String?, scope: String) -> (id: UUID, isDuplicate: Bool) {
        guard let key = PlanFileImporter.normalized(external) else { return (UUID(), false) }
        let tableKey = scope + ":" + key
        if table[tableKey] != nil { return (UUID(), true) }
        let id: UUID
        if mode == .skip, let source = UUID(uuidString: key) {
            id = PlanFileImporter.derivedID(for: source)
        } else {
            id = UUID()
        }
        table[tableKey] = id
        return (id, false)
    }
}

struct PlanScope {
    var planID: UUID?
    var ids: IDMap
    var stageByExt: [String: UUID] = [:]
    var stageByName: [String: UUID] = [:]
    var metricByExt: [String: UUID] = [:]
    var metricByName: [String: UUID] = [:]
    var taskByExt: [String: UUID] = [:]
    var deps: [(task: UUID, refs: [String], path: String)] = []
    var statuses: [(task: UUID, status: TaskStatus, path: String)] = []

    init(planID: UUID?, ids: IDMap) { self.planID = planID; self.ids = ids }
}

struct Builder {
    let tz: TimeZone
    let today: DateOnly
    let now: Date
    let mode: PlanImportDuplicateMode
    var commands: [PlannedImportCommand] = []
    var issues: [PlanImportIssue] = []

    init(tz: TimeZone, today: DateOnly, now: Date, mode: PlanImportDuplicateMode) {
        self.tz = tz; self.today = today; self.now = now; self.mode = mode
    }

    // MARK: 工具

    mutating func report(_ severity: PlanImportIssue.Severity, _ path: String, _ message: String) {
        issues.append(PlanImportIssue(severity: severity, path: path, message: message))
    }

    mutating func add(_ command: any DomainCommand, _ category: PlannedImportCommand.Category,
                      label: String, requires: [UUID?] = []) {
        commands.append(PlannedImportCommand(command: command, category: category, label: label,
                                             requires: requires.compactMap { $0 }))
    }

    /// 解析某天或某一时刻；空值表示没填。
    mutating func time(_ raw: String?, field: String, path: String) -> (ok: Bool, value: TimePoint?) {
        guard let text = PlanFileImporter.normalized(raw) else { return (true, nil) }
        guard let point = TimePoint.parse(text, fallbackTZ: tz) else {
            report(.error, path, "\(field)「\(text)」不是有效的日期或时间（日期写 2026-06-30，时刻写 2026-06-30T18:00:00+08:00）。")
            return (false, nil)
        }
        return (true, point)
    }

    mutating func day(_ raw: String?, field: String, path: String) -> (ok: Bool, value: DateOnly?) {
        guard let text = PlanFileImporter.normalized(raw) else { return (true, nil) }
        let parsed = time(text, field: field, path: path)
        guard parsed.ok, let point = parsed.value else { return (false, nil) }
        switch point {
        case .day(let day): return (true, day)
        case .instant(let instant):
            let zone = TimeZone(identifier: instant.tzID) ?? tz
            return (true, DateOnly(from: instant.epoch, in: zone))
        }
    }

    mutating func timeOfDay(_ raw: String?, field: String, path: String) -> (ok: Bool, value: TimeOfDay?) {
        guard let text = PlanFileImporter.normalized(raw) else { return (true, nil) }
        let parts = text.split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, !parts.contains(where: { $0 == nil }) else {
            report(.error, path, "\(field)「\(text)」不是有效的时刻（写成 08:30）。")
            return (false, nil)
        }
        let value = TimeOfDay(hour: parts[0] ?? 0, minute: parts[1] ?? 0, second: parts.count == 3 ? (parts[2] ?? 0) : 0)
        guard value.isValid else {
            report(.error, path, "\(field)「\(text)」不是有效的时刻（写成 08:30）。")
            return (false, nil)
        }
        return (true, value)
    }

    /// 在同一范围内给条目分配 id；文件 id 重复时报错并返回 nil。
    mutating func define(_ external: String?, scope: String, in plan: inout PlanScope, path: String) -> UUID? {
        let result = plan.ids.define(external, scope: scope)
      / 没有目标计划时，顶层的阶段、指标、记录、测量值无处可放：明确报错而不是忽略
    mutating func requirePlan(for kind: String, count: Int) {
        guard count > 0 else { return }
        report(.error, "文件顶层的\(kind)（\(count) 项）",
               "\(kind)需要放进一个计划。请在「导入到」里选择一个已有计划，这些内容没有导入。")
    }

    //  if result.isDuplicate {
            report(.error, path, "文件里有两个相同的 id「\(external ?? "")」，这一项没有导入。")
            return nil
        }
        return result.id
    }

    // MARK: 计划

    mutating func addPlan(_ file: FilePlan, index: Int) {
        let name = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = name.isEmpty ? "第 \(index + 1) 个计划" : "计划「\(name)」"

        let kindText = PlanFileImporter.normalized(file.kind) ?? PlanKind.delivery.rawValue
        guard let kind = PlanKind(rawValue: kindText) else {
            report(.error, path, "类型「\(kindText)」不认识，可用：delivery、improvement、maintenance。整个计划没有导入。")
            return
        }
        var category: PlanCategory?
        if let text = PlanFileImporter.normalized(file.category) {
            guard let value = PlanCategory(rawValue: text) else {
                report(.error, path, "分类「\(text)」不认识，可用：work、study、health、life。整个计划没有导入。")
                return
            }
            category = value
        }
        let start = time(file.startAt, field: "startAt", path: path)
        let end = time(file.endAt, field: "endAt", path: path)
        guard start.ok, end.ok else { return }

        var scope = PlanScope(planID: nil, ids: IDMap(mode: mode))
        let planID = scope.ids.define(file.id, scope: "plan").id
        scope.planID = planID
        add(CreatePlan(id: planID, name: file.name, kind: kind, category: category, goal: file.goal,
                       startAt: start.value, endAt: end.value, aliases: file.aliases ?? []),
            .plan, label: path)

        for (order, stage) in (file.stages ?? []).enumerated() {
            addStage(stage, order: order, scope: &scope, planPath: path)
        }
        for metric in file.metrics ?? [] {
            addMetric(metric, scope: &scope, planPath: path)
        }
        for task in file.tasks ?? [] {
            addTask(task, scope: &scope, parent: nil, pathPrefix: path + " / ")
        }
        finish(scope: &scope, pathPrefix: path + " / ")

        for record in file.records ?? [] { addRecord(record, scope: &scope, planPath: path) }
        for measurement in file.measurements ?? [] { addMeasurement(measurement, scope: &scope, planPath: path) }
        for note in file.notes ?? [] { addNote(note, planID: planID, scope: &scope, path: path) }
    }

    mutating func addStage(_ stage: FileStage, order: Int, scope: inout PlanScope, planPath: String) {
        let path = "\(planPath) / 阶段「\(stage.name)」"
        guard let id = define(stage.id, scope: "stage", in: &scope, path: path) else { return }
        let start = time(stage.startAt, field: "startAt", path: path)
        let end = time(stage.endAt, field: "endAt", path: path)
        guard start.ok, end.ok else { return }
        add(CreateStage(id: id, planID: scope.planID ?? id, name: stage.name, criteriaText: stage.criteria,
                        startAt: start.value, endAt: end.value, sortIndex: order),
            .stage, label: path, requires: [scope.planID])
        if let key = PlanFileImporter.normalized(stage.id) { scope.stageByExt[key] = id }
        if scope.stageByName[stage.name] == nil { scope.stageByName[stage.name] = id }
    }

    mutating func addMetric(_ metric: FileMetric, scope: inout PlanScope, planPath: String) {
        let path = "\(planPath) / 指标「\(metric.name)」"
        guard let id = define(metric.id, scope: "metric", in: &scope, path: path) else { return }
        var direction = MetricDirection.none
        if let text = PlanFileImporter.normalized(metric.direction) {
            guard let value = MetricDirection(rawValue: text) else {
                report(.error, path, "方向「\(text)」不认识，可用：increase、decrease、none。")
                return
            }
            direction = value
        }
        add(CreateMetric(id: id, planID: scope.planID ?? id, name: metric.name, unit: metric.unit,
                         targetValue: metric.targetValue, targetDirection: direction),
            .metric, label: path, requires: [scope.planID])
        if let key = PlanFileImporter.normalized(metric.id) { scope.metricByExt[key] = id }
        if scope.metricByName[metric.name] == nil { scope.metricByName[metric.name] = id }
    }

    // MARK: 任务

    mutating func addTask(_ file: FileTask, scope: inout PlanScope,
                          parent: (id: UUID, stage: UUID?)?, pathPrefix: String) {
        let path = pathPrefix + "任务「\(file.title)」"
        guard let taskID = define(file.id, scope: "task", in: &scope, path: path) else { return }

        let children = file.children ?? []
        let steps = file.steps ?? []
        if file.recurrence != nil, !children.isEmpty {
            report(.error, path, "重复行动不能有子任务（children），多级内容请写成 steps。这一项没有导入。")
            return
        }
        if file.recurrence == nil, !steps.isEmpty {
            report(.error, path, "只有重复行动（recurrence）可以有 steps；普通待办的多级内容请写成 children。这一项没有导入。")
            return
        }
        if parent != nil, file.recurrence != nil {
            report(.error, path, "重复行动不能放在其它待办下面。这一项没有导入。")
            return
        }

        var status = TaskStatus.todo
        if let text = PlanFileImporter.normalized(file.status) {
            guard let value = TaskStatus(rawValue: text) else {
                report(.error, path, "状态「\(text)」不认识，可用：todo、inProgress、blocked、done、cancelled。这一项没有导入。")
                return
            }
            status = value
        }
        var priority: TaskPriority?
        if let text = PlanFileImporter.normalized(file.priority) {
            guard let value = TaskPriority(rawValue: text) else {
                report(.error, path, "优先级「\(text)」不认识，可用：low、normal、high。这一项没有导入。")
                return
            }
            priority = value
        }
        let start = time(file.startAt, field: "startAt", path: path)
        let end = time(file.endAt, field: "endAt", path: path)
        guard start.ok, end.ok else { return }

        var draft: RecurrenceDraft?
        if let recurrence = file.recurrence {
            guard let parsed = recurrenceDraft(recurrence, path: path) else { return }
            draft = parsed
        }

        // 阶段：顶层任务按 id 或名称查找；子任务跟随上级
        var stageID: UUID? = parent?.stage
        if let ref = PlanFileImporter.normalized(file.stage) {
            if parent != nil {
                report(.warning, path, "子任务的阶段跟随上级，已忽略 stage「\(ref)」。")
            } else if scope.planID == nil {
                report(.warning, path, "独立待办没有阶段，已忽略 stage「\(ref)」。")
            } else if let found = scope.stageByExt[ref] ?? scope.stageByName[ref] {
                stageID = found
            } else {
                report(.warning, path, "找不到阶段「\(ref)」，已导入到计划下，不挂阶段。")
            }
        }

        add(CreateTask(id: taskID, title: file.title, planID: scope.planID, stageID: stageID,
                       parentID: parent?.id, notes: file.notes, startAt: start.value, endAt: end.value,
                       estimateMinutes: file.estimateMinutes, priority: priority, tags: file.tags ?? [],
                       recurrence: draft),
            draft == nil ? .task : .recurring, label: path,
            requires: [scope.planID, stageID, parent?.id])

        if let key = PlanFileImporter.normalized(file.id) { scope.taskByExt[key] = taskID }
        if let refs = file.dependsOn, !refs.isEmpty { scope.deps.append((taskID, refs, path)) }
        if status != .todo {
            if draft != nil || !children.isEmpty {
                report(.warning, path, "重复行动和有子任务的待办不单独设置状态，已忽略 status「\(status.rawValue)」。")
            } else {
                scope.statuses.append((taskID, status, path))
            }
        }

        for step in steps { addStep(step, parent: taskID, scope: &scope, pathPrefix: path + " / ") }
        for child in children {
            addTask(child, scope: &scope, parent: (id: taskID, stage: stageID), pathPrefix: path + " / ")
        }
    }

    mutating func addStep(_ step: FileStep, parent: UUID, scope: inout PlanScope, pathPrefix: String) {
        let path = pathPrefix + "步骤「\(step.title)」"
        guard let id = define(step.id, scope: "task", in: &scope, path: path) else { return }
        add(CreateTask(id: id, title: step.title, parentID: parent), .step, label: path, requires: [parent])
        for child in step.children ?? [] {
            addStep(child, parent: id, scope: &scope, pathPrefix: path + " / ")
        }
    }

    mutating func recurrenceDraft(_ file: FileRecurrence, path: String) -> RecurrenceDraft? {
        let patternText = PlanFileImporter.normalized(file.pattern) ?? ""
        guard let pattern = RecurrencePattern(rawValue: patternText) else {
            report(.error, path, "重复方式「\(patternText)」不认识，可用：daily、weekdays、weeklyCount。这一项没有导入。")
            return nil
        }
        let from = day(file.effectiveFrom, field: "effectiveFrom", path: path)
        let until = day(file.effectiveUntil, field: "effectiveUntil", path: path)
        let dailyStart = timeOfDay(file.dailyStart, field: "dailyStart", path: path)
        let dailyEnd = timeOfDay(file.dailyEnd, field: "dailyEnd", path: path)
        guard from.ok, until.ok, dailyStart.ok, dailyEnd.ok else { return nil }
        return RecurrenceDraft(pattern: pattern, weekdays: file.weekdays ?? [], weeklyCount: file.weeklyCount,
                               effectiveFrom: from.value ?? today, effectiveUntil: until.value,
                               dailyStart: dailyStart.value, dailyEnd: dailyEnd.value)
    }

    /// 一个范围内的任务都创建完后：补前置关系与状态
    mutating func finish(scope: inout PlanScope, pathPrefix: String) {
        for pending in scope.deps {
            for ref in pending.refs {
                guard let key = PlanFileImporter.normalized(ref), let dependency = scope.taskByExt[key] else {
                    report(.warning, pending.path, "找不到前置任务「\(ref)」，这条前置关系没有导入。")
                    continue
                }
                guard dependency != pending.task else {
                    report(.warning, pending.path, "任务不能把自己作为前置，这条前置关系没有导入。")
                    continue
                }
                add(AddDependency(taskID: pending.task, dependsOnID: dependency), .dependency,
                    label: pending.path + " / 前置「\(ref)」", requires: [pending.task, dependency])
            }
        }
        for pending in scope.statuses {
            switch pending.status {
            case .done:
                add(CompleteTask(taskID: pending.task, at: .precise(now)), .status,
                    label: pending.path + " / 状态", requires: [pending.task])
            case .cancelled:
                add(CancelTask(taskID: pending.task), .status,
                    label: pending.path + " / 状态", requires: [pending.task])
            case .inProgress, .blocked:
                add(UpdateTask(taskID: pending.task, patch: TaskPatch(status: pending.status)), .status,
                    label: pending.path + " / 状态", requires: [pending.task])
            case .todo:
                break
            }
        }
        scope.deps = []
        scope.statuses = []
    }

    // MARK: 可选内容

    mutating func addRecord(_ record: FileRecord, scope: inout PlanScope, planPath: String) {
        let path = "\(planPath) / 行动记录「\(record.at)」"
        guard let planID = scope.planID,
              let id = define(record.id, scope: "record", in: &scope, path: path) else { return }
        let parsed = time(record.at, field: "at", path: path)
        guard parsed.ok else { return }
        guard let point = parsed.value else {
            report(.error, path, "行动记录缺少发生时间 at。")
            return
        }
        let happenedAt: TimeValue
        switch point {
        case .day(let day): happenedAt = .day(day)
        case .instant(let instant): happenedAt = .precise(instant.epoch)
        }
        var taskID: UUID?
        if let ref = PlanFileImporter.normalized(record.task) {
            if let found = scope.taskByExt[ref] {
                taskID = found
            } else {
                report(.warning, path, "找不到关联任务「\(ref)」，这条记录导入时没有关联任务。")
            }
        }
        add(LogActivity(id: id, planID: planID, taskID: taskID, happenedAt: happenedAt,
                        durationMinutes: record.minutes, text: record.text),
            .record, label: path, requires: [planID, taskID])
    }

    mutating func addMeasurement(_ item: FileMeasurement, scope: inout PlanScope, planPath: String) {
        let path = "\(planPath) / 测量值「\(item.metric) \(item.at)」"
        guard let planID = scope.planID,
              let id = define(item.id, scope: "measurement", in: &scope, path: path) else { return }
        let ref = PlanFileImporter.normalized(item.metric) ?? ""
        guard let metricID = scope.metricByExt[ref] ?? scope.metricByName[ref] else {
            report(.error, path, "找不到指标「\(item.metric)」，这条测量值没有导入。")
            return
        }
        let measured = day(item.at, field: "at", path: path)
        guard measured.ok else { return }
        guard let measuredAt = measured.value else {
            report(.error, path, "测量值缺少日期 at。")
            return
        }
        add(RecordMeasurement(id: id, planID: planID, metricID: metricID, measuredAt: measuredAt,
                              value: item.value, note: item.note),
            .measurement, label: path, requires: [planID, metricID])
    }

    mutating func addNote(_ note: FileNote, planID: UUID?, scope: inout PlanScope, path: String) {
        let label = "\(path) / 笔记"
        guard let id = define(note.id, scope: "note", in: &scope, path: label) else { return }
        var kind = NoteKind.idea
        if let text = PlanFileImporter.normalized(note.kind) {
            guard let value = NoteKind(rawValue: text) else {
                report(.error, label, "笔记类型「\(text)」不认识，可用：idea、decision、memo。")
                return
            }
            kind = value
        }
        add(CreateNote(id: id, text: note.text, kind: kind, planID: planID), .note,
            label: label, requires: [planID])
    }
}
