import XCTest
import MovoKit

/// `.movo.json` 标准文件：导出 → 导入往返、校验、版本、重复导入、模板。
@MainActor
final class PlanFileTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!

    private func makeStore(_ device: String = "plan-file") -> DomainStore {
        DomainStore(repository: InMemoryRepository(),
                    clock: TravelClock(Date(timeIntervalSince1970: 1_800_000_000)),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: "Asia/Shanghai"),
                    deviceIDProvider: FixedDeviceIDProvider(device), defaults: .fallback)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DateOnly {
        DateOnly(y: y, m: m, d: d, sourceTZ: tz.identifier)
    }

    // MARK: - 夹具

    /// 一个带阶段、指标、嵌套子任务、前置、重复行动及步骤、独立待办的数据集
    private func seed(_ store: DomainStore) async throws {
        let planResult = try await store.execute(CreatePlan(
            name: "英语", kind: .improvement, category: .study, goal: "三个月考过 6 级",
            startAt: .day(day(2027, 2, 1)), endAt: .day(day(2027, 4, 30)), aliases: ["背单词"]))
        let plan = try XCTUnwrap(planResult.entityID)
        let stageResult = try await store.execute(CreateStage(
            planID: plan, name: "打基础", criteriaText: "词汇过半",
            startAt: .day(day(2027, 2, 1)), endAt: .day(day(2027, 3, 1))))
        let stage = try XCTUnwrap(stageResult.entityID)
        _ = try await store.execute(CreateMetric(planID: plan, name: "词汇量", unit: "个",
                                                 targetValue: 4000, targetDirection: .increase))

        let rootResult = try await store.execute(CreateTask(
            title: "准备", planID: plan, stageID: stage, startAt: .day(day(2027, 2, 1)),
            endAt: .day(day(2027, 2, 20)), estimateMinutes: 90, priority: .high, tags: ["起步"]))
        let root = try XCTUnwrap(rootResult.entityID)
        let pickResult = try await store.execute(CreateTask(title: "选教材", planID: plan, stageID: stage,
                                                            parentID: root))
        let pick = try XCTUnwrap(pickResult.entityID)
        let planResult2 = try await store.execute(CreateTask(title: "定计划", planID: plan, stageID: stage,
                                                             parentID: root))
        let schedule = try XCTUnwrap(planResult2.entityID)
        _ = try await store.execute(AddDependency(taskID: schedule, dependsOnID: pick))

        let recurring = try await store.execute(CreateTask(
            title: "背单词", planID: plan,
            recurrence: RecurrenceDraft(pattern: .weekdays, weekdays: [1, 2, 3, 4, 5],
                                        effectiveFrom: day(2027, 2, 1),
                                        dailyStart: TimeOfDay(hour: 8, minute: 0),
                                        dailyEnd: TimeOfDay(hour: 8, minute: 30))))
        let template = try XCTUnwrap(recurring.entityID)
        let review = try await store.execute(CreateTask(title: "复习旧词", parentID: template))
        _ = review
        let learn = try await store.execute(CreateTask(title: "学新词", parentID: template))
        let learnID = try XCTUnwrap(learn.entityID)
        _ = try await store.execute(CreateTask(title: "第一组 20 个", parentID: learnID))

        _ = try await store.execute(CreateTask(title: "报名考试", endAt: .day(day(2027, 2, 10))))
    }

    private func scope(_ store: DomainStore) async -> ExportScope {
        let repo = store.repository
        let plans = await repo.allPlans()
        var stages: [Stage] = []
        var metrics: [PlanMetric] = []
        for plan in plans {
            stages += await repo.stages(planID: plan.id)
            metrics += await repo.metrics(planID: plan.id)
        }
        let tasks = await repo.allTasks()
        let measurements = await repo.allMeasurements()
        let activities = await repo.allActivities()
        let notes = await repo.allNotes()
        let rules = await repo.rules()
        return ExportService.gather(plans: plans, stages: stages, tasks: tasks, metrics: metrics,
                                    measurements: measurements, activities: activities, notes: notes,
                                    occurrences: [], rules: rules)
    }

    private func exportFile(_ store: DomainStore, options: PlanFileOptions = PlanFileOptions()) async throws -> PlanFile {
        let bundle = ExportService.export(await scope(store), format: .json, options: options,
                                          generatedAt: store.now, timeZone: tz)
        XCTAssertTrue(bundle.fileName.hasSuffix(".movo.json"))
        return try PlanFileCodec.decode(Data(bundle.content.utf8))
    }

    /// 不含 id 的结构快照：用来比较导出前后是否一致
    private func snapshot(_ store: DomainStore) async -> [String] {
        let repo = store.repository
        let plans = await repo.allPlans()
        let tasks = await repo.allTasks()
        let rules = await repo.rules()
        let titles = Dictionary(tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        var lines: [String] = []
        var stageNames: [UUID: String] = [:]
        for plan in plans {
            lines.append("plan|\(plan.name)|\(plan.kind.rawValue)|\(plan.category?.rawValue ?? "-")|"
                         + "\(plan.goalText ?? "-")|\(plan.startAt?.iso8601String ?? "-")|"
                         + "\(plan.endAt?.iso8601String ?? "-")|\(plan.aliases.joined(separator: ","))")
            for stage in await repo.stages(planID: plan.id) {
                stageNames[stage.id] = stage.name
                lines.append("stage|\(plan.name)|\(stage.name)|\(stage.criteriaText ?? "-")|"
                             + "\(stage.startAt?.iso8601String ?? "-")|\(stage.endAt?.iso8601String ?? "-")")
            }
            for metric in await repo.metrics(planID: plan.id) {
                lines.append("metric|\(metric.name)|\(metric.unit)|\(metric.targetValue ?? -1)|\(metric.targetDirection.rawValue)")
            }
        }
        let planNames = Dictionary(plans.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for task in tasks {
            let rule = rules.first { $0.taskId == task.id }
            var ruleText = "-"
            if let rule {
                let weekdays = (rule.weekdays ?? []).map(String.init).joined()
                ruleText = [rule.pattern.rawValue, weekdays, rule.effectiveFrom.iso8601DateString,
                            rule.dailyStart?.displayString ?? "-",
                            rule.dailyEnd?.displayString ?? "-"].joined(separator: "/")
            }
            let deps = task.dependencyIDs.compactMap { titles[$0] }.sorted().joined(separator: ",")
            let planName = task.planId.flatMap { planNames[$0] } ?? "-"
            let parentTitle = task.parentId.flatMap { titles[$0] } ?? "-"
            let stageName = task.stageId.flatMap { stageNames[$0] } ?? "-"
            lines.append("task|\(task.title)|plan=\(planName)|parent=\(parentTitle)|stage=\(stageName)|"
                         + "template=\(task.isTemplate)|step=\(task.isStep)|"
                         + "\(task.startAt?.iso8601String ?? "-")|\(task.endAt?.iso8601String ?? "-")|"
                         + "\(task.estimateMinutes ?? -1)|\(task.priority?.rawValue ?? "-")|"
                         + "\(task.tags.joined(separator: ","))|deps=\(deps)|rule=\(ruleText)")
        }
        return lines.sorted()
    }

    // MARK: - 往返

    func testRoundTripPreservesStructureIncludingStepsAndDependencies() async throws {
        let source = makeStore("source")
        try await seed(source)
        let file = try await exportFile(source)

        let target = makeStore("target")
        let plan = await PlanFileImporter.makePlan(file: file, store: target, duplicateMode: .skip)
        XCTAssertEqual(plan.errorCount, 0, plan.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(plan.summary.plans, 1)
        XCTAssertEqual(plan.summary.stages, 1)
        XCTAssertEqual(plan.summary.metrics, 1)
        XCTAssertEqual(plan.summary.recurring, 1)
        XCTAssertEqual(plan.summary.steps, 3)

        let result = try await PlanFileImporter.apply(plan, store: target)
        XCTAssertTrue(result.rejected.isEmpty)

        let before = await snapshot(source)
        let after = await snapshot(target)
        XCTAssertEqual(before, after)
    }

    /// 导出把顶层任务的阶段写回 `stage`（与文件里阶段条目的 id 一致）；
    /// 子任务跟随上级，不重复写；没有阶段的任务不写。
    func testExportWritesStageOnTopLevelTasksOnly() async throws {
        let store = makeStore()
        try await seed(store)
        let file = try await exportFile(store)

        let planFile = try XCTUnwrap(file.plans?.first)
        let stageID = try XCTUnwrap(planFile.stages?.first?.id)
        let roots = try XCTUnwrap(planFile.tasks)

        let root = try XCTUnwrap(roots.first { $0.title == "准备" })
        XCTAssertEqual(root.stage, stageID)

        let child = try XCTUnwrap(root.children?.first { $0.title == "选教材" })
        XCTAssertNil(child.stage)

        let template = try XCTUnwrap(roots.first { $0.title == "背单词" })
        XCTAssertNil(template.stage)
    }

    func testImportCanBeUndoneAsOneBatch() async throws {
        let source = makeStore("source")
        try await seed(source)
        let file = try await exportFile(source)

        let target = makeStore("target")
        let plan = await PlanFileImporter.makePlan(file: file, store: target, duplicateMode: .skip)
        _ = try await PlanFileImporter.apply(plan, store: target)
        let batch = try XCTUnwrap(target.lastNotification?.batchID)
        _ = try await target.undo(batchID: batch)
        let live = await target.todos(includeCompleted: true)
        XCTAssertTrue(live.isEmpty)
    }

    func testExportKeepsRecordsMeasurementsAndNotesOptIn() async throws {
        let store = makeStore()
        try await seed(store)
        let plans = await store.repository.allPlans()
        let plan = try XCTUnwrap(plans.first)
        let metrics = await store.repository.metrics(planID: plan.id)
        let metric = try XCTUnwrap(metrics.first)
        _ = try await store.execute(LogActivity(planID: plan.id, happenedAt: .day(day(2027, 1, 14)),
                                                durationMinutes: 30, text: "背了 20 个"))
        _ = try await store.execute(RecordMeasurement(planID: plan.id, metricID: metric.id,
                                                      measuredAt: day(2027, 1, 14), value: 1200))
        _ = try await store.execute(CreateNote(text: "试试听力", kind: .idea, planID: plan.id))

        let plain = try await exportFile(store)
        let plainPlan = try XCTUnwrap(plain.plans?.first)
        XCTAssertNil(plainPlan.records)
        XCTAssertNil(plainPlan.measurements)
        XCTAssertNil(plainPlan.notes)

        let full = try await exportFile(store, options: PlanFileOptions(includeRecords: true,
                                                                       includeMeasurements: true,
                                                                       includeNotes: true))
        let fullPlan = try XCTUnwrap(full.plans?.first)
        XCTAssertEqual(fullPlan.records?.count, 1)
        XCTAssertEqual(fullPlan.measurements?.count, 1)
        XCTAssertEqual(fullPlan.notes?.count, 1)

        let target = makeStore("target")
        let imported = await PlanFileImporter.makePlan(file: full, store: target, duplicateMode: .skip)
        XCTAssertEqual(imported.errorCount, 0, imported.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(imported.summary.records, 1)
        XCTAssertEqual(imported.summary.measurements, 1)
        XCTAssertEqual(imported.summary.notes, 1)
    }

    func testExportDoesNotFilterByCloudAIAndNeverContainsSecrets() async throws {
        let store = makeStore()
        _ = try await store.execute(CreatePlan(name: "体重", kind: .improvement, category: .health))
        let plans = await store.repository.allPlans()
        XCTAssertEqual(plans.first?.cloudAIEnabled, false)
        let bundle = ExportService.export(await scope(store), format: .json, generatedAt: store.now, timeZone: tz)
        XCTAssertEqual(bundle.includedPlanNames, ["体重"], "导出不再按 cloudAIEnabled 过滤")
        for forbidden in ["cloudAIEnabled", "syncEnabled", "deviceId", "apiKey", "audio"] {
            XCTAssertFalse(bundle.content.contains(forbidden), forbidden)
        }
    }

    // MARK: - 重复导入

    func testDuplicateImportIsSkippedOrSavedAsCopy() async throws {
        let source = makeStore("source")
        try await seed(source)
        let file = try await exportFile(source)

        let skipOnSource = await PlanFileImporter.makePlan(file: file, store: source, duplicateMode: .skip)
        XCTAssertEqual(skipOnSource.summary.plans, 0)
        XCTAssertEqual(skipOnSource.summary.skippedDuplicates.count, 2, "计划与独立待办各一项")
        XCTAssertFalse(skipOnSource.canImport)

        let copy = await PlanFileImporter.makePlan(file: file, store: source, duplicateMode: .saveCopy)
        XCTAssertEqual(copy.summary.plans, 1)
        _ = try await PlanFileImporter.apply(copy, store: source)
        let plans = await source.repository.allPlans()
        XCTAssertEqual(plans.count, 2)

        let target = makeStore("target")
        let first = await PlanFileImporter.makePlan(file: file, store: target, duplicateMode: .skip)
        _ = try await PlanFileImporter.apply(first, store: target)
        let second = await PlanFileImporter.makePlan(file: file, store: target, duplicateMode: .skip)
        XCTAssertFalse(second.canImport, "同一份文件再次导入会被识别为重复")
    }

    // MARK: - 校验

    func testInvalidItemsAreReportedAndValidOnesStillImport() async throws {
        let json = """
        {"format":"movo.plan-file","schemaVersion":1,"plans":[
          {"name":"P1","kind":"delivery","endAt":"2027-03-31","tasks":[
            {"title":"好任务"},
            {"title":"坏日期","endAt":"明天"},
            {"title":"超出范围","endAt":"2027-12-01"},
            {"title":"重复带子任务","recurrence":{"pattern":"daily"},"children":[{"title":"x"}]},
            {"title":"普通任务带步骤","steps":[{"title":"y"}]}
          ]},
          {"name":"P2","kind":"unknown"}
        ]}
        """
        let file = try PlanFileCodec.decode(Data(json.utf8))
        let store = makeStore()
        let plan = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .skip)
        XCTAssertEqual(plan.summary.plans, 1)
        XCTAssertEqual(plan.summary.tasks, 1)
        XCTAssertEqual(plan.errorCount, 5, plan.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
        XCTAssertTrue(plan.issues.contains { $0.path.contains("P2") })
        XCTAssertTrue(plan.issues.contains { $0.path.contains("坏日期") })
        XCTAssertTrue(plan.issues.contains { $0.path.contains("超出范围") })
        XCTAssertTrue(plan.canImport)

        let result = try await PlanFileImporter.apply(plan, store: store)
        XCTAssertTrue(result.rejected.isEmpty)
        let tasks = await store.repository.allTasks()
        XCTAssertEqual(tasks.map(\.title), ["好任务"])
    }

    func testFailedParentSkipsItsChildrenWithoutSilentlyDroppingThem() async throws {
        let json = """
        {"format":"movo.plan-file","schemaVersion":1,"tasks":[
          {"title":"父","endAt":"2027-02-01","children":[
            {"title":"子","endAt":"2027-03-01"}
          ]}
        ]}
        """
        let file = try PlanFileCodec.decode(Data(json.utf8))
        let store = makeStore()
        let plan = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .skip)
        XCTAssertEqual(plan.summary.tasks, 1, "子任务超出父任务范围，只导入父任务")
        XCTAssertTrue(plan.issues.contains { $0.path.contains("子") })
    }

    func testDependenciesAndStatusesImport() async throws {
        let json = """
        {"format":"movo.plan-file","schemaVersion":1,"plans":[
          {"name":"P","tasks":[
            {"id":"a","title":"A","status":"done"},
            {"id":"b","title":"B","dependsOn":["a","missing"],"status":"inProgress"}
          ]}
        ]}
        """
        let file = try PlanFileCodec.decode(Data(json.utf8))
        let store = makeStore()
        let plan = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .skip)
        XCTAssertEqual(plan.errorCount, 0)
        XCTAssertEqual(plan.warningCount, 1, "找不到的前置给出提示而不是静默丢弃")
        _ = try await PlanFileImporter.apply(plan, store: store)
        let tasks = await store.repository.allTasks()
        let a = try XCTUnwrap(tasks.first { $0.title == "A" })
        let b = try XCTUnwrap(tasks.first { $0.title == "B" })
        XCTAssertEqual(a.status, .done)
        XCTAssertEqual(b.status, .inProgress)
        XCTAssertEqual(b.dependencyIDs, [a.id])
    }

    // MARK: - 导入到已有计划

    func testTopLevelContentNeedsATargetPlanAndImportsIntoIt() async throws {
        let store = makeStore()
        let created = try await store.execute(CreatePlan(
            name: "英语", kind: .improvement,
            startAt: .day(day(2027, 2, 1)), endAt: .day(day(2027, 4, 30))))
        let planID = try XCTUnwrap(created.entityID)
        let json = """
        {"format":"movo.plan-file","schemaVersion":1,
         "stages":[{"id":"s","name":"冲刺","startAt":"2027-03-01","endAt":"2027-04-01"}],
         "metrics":[{"id":"m","name":"词汇量","unit":"个"}],
         "tasks":[{"title":"刷真题","stage":"冲刺","endAt":"2027-03-20"}],
         "measurements":[{"metric":"词汇量","at":"2027-01-10","value":3000}]}
        """
        let file = try PlanFileCodec.decode(Data(json.utf8))
        XCTAssertTrue(PlanFileImporter.needsTargetPlan(file))

        let loose = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .skip)
        XCTAssertEqual(loose.errorCount, 3, "阶段、指标、测量值没有目标计划，明确报错")
        XCTAssertEqual(loose.summary.stages + loose.summary.metrics + loose.summary.measurements, 0)
        XCTAssertEqual(loose.summary.tasks, 1, "待办仍可作为独立待办导入")

        let targeted = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .skip,
                                                       targetPlanID: planID)
        XCTAssertEqual(targeted.errorCount, 0, targeted.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
        XCTAssertEqual(targeted.summary.stages, 1)
        XCTAssertEqual(targeted.summary.metrics, 1)
        XCTAssertEqual(targeted.summary.tasks, 1)
        XCTAssertEqual(targeted.summary.measurements, 1)

        let result = try await PlanFileImporter.apply(targeted, store: store)
        XCTAssertTrue(result.rejected.isEmpty)
        let stages = await store.repository.stages(planID: planID)
        let tasks = await store.repository.tasks(planID: planID)
        XCTAssertEqual(stages.map(\.name), ["冲刺"])
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.title, "刷真题")
        XCTAssertEqual(task.stageId, stages.first?.id)
    }

    func testTasksImportUnderAnExistingTaskButNotUnderTemplatesOrDoneTasks() async throws {
        let store = makeStore()
        let planResult = try await store.execute(CreatePlan(name: "英语", kind: .improvement))
        let planID = try XCTUnwrap(planResult.entityID)
        let parentResult = try await store.execute(CreateTask(title: "备考", planID: planID))
        let parentID = try XCTUnwrap(parentResult.entityID)
        let doneResult = try await store.execute(CreateTask(title: "已结束", planID: planID))
        let doneID = try XCTUnwrap(doneResult.entityID)
        _ = try await store.execute(CompleteTask(taskID: doneID, at: .precise(store.now)))
        let templateResult = try await store.execute(CreateTask(
            title: "背单词", planID: planID,
            recurrence: RecurrenceDraft(pattern: .daily, effectiveFrom: store.today)))
        let templateID = try XCTUnwrap(templateResult.entityID)

        let candidates = await PlanFileImporter.parentCandidates(planID: planID, store: store)
        XCTAssertEqual(candidates.map(\.title), ["备考"], "已完成的任务和重复行动不能放子任务")

        let json = """
        {"format":"movo.plan-file","schemaVersion":1,"tasks":[
          {"title":"整理错题","children":[{"title":"听力"}]}
        ]}
        """
        let file = try PlanFileCodec.decode(Data(json.utf8))
        let ok = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .skip,
                                                 targetPlanID: planID, targetTaskID: parentID)
        XCTAssertEqual(ok.errorCount, 0, ok.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(ok.summary.tasks, 2)
        _ = try await PlanFileImporter.apply(ok, store: store)
        let tasks = await store.repository.allTasks()
        let imported = try XCTUnwrap(tasks.first { $0.title == "整理错题" })
        XCTAssertEqual(imported.parentId, parentID)
        XCTAssertEqual(imported.planId, planID)

        for blockedID in [doneID, templateID] {
            let blocked = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .saveCopy,
                                                          targetPlanID: planID, targetTaskID: blockedID)
            XCTAssertEqual(blocked.errorCount, 1)
            XCTAssertEqual(blocked.summary.tasks, 0)
        }
    }

    // MARK: - docs/samples 示例文件

    private func sampleData(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("docs/samples/\(name).movo.json"))
    }

    /// 示例日期在 2026 年 10–12 月，时钟固定在 2026-10-04
    private func makeSampleStore() -> DomainStore {
        DomainStore(repository: InMemoryRepository(),
                    clock: TravelClock(Date(timeIntervalSince1970: 1_791_115_200)),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: "Asia/Shanghai"),
                    deviceIDProvider: FixedDeviceIDProvider("samples"), defaults: .fallback)
    }

    func testFullSampleImportsPlanStagesNestedTasksStepsAndOptionalContent() async throws {
        let file = try PlanFileCodec.decode(try sampleData("full-plan"))
        let store = makeSampleStore()
        let plan = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .skip)
        XCTAssertEqual(plan.errorCount, 0, plan.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
        XCTAssertEqual(plan.summary.plans, 1)
        XCTAssertEqual(plan.summary.stages, 2)
        XCTAssertEqual(plan.summary.metrics, 1)
        XCTAssertEqual(plan.summary.recurring, 1)
        XCTAssertEqual(plan.summary.steps, 4)
        XCTAssertEqual(plan.summary.records, 1)
        XCTAssertEqual(plan.summary.measurements, 1)
        XCTAssertEqual(plan.summary.notes, 1)
        _ = try await PlanFileImporter.apply(plan, store: store)

        let tasks = await store.repository.allTasks()
        let byTitle = Dictionary(tasks.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byTitle["错题复盘"].flatMap { id in tasks.first { $0.id == id.parentId }?.title }, "第二套")
        XCTAssertEqual(byTitle["第二套"].flatMap { id in tasks.first { $0.id == id.parentId }?.title }, "全真模拟题")
        XCTAssertEqual(byTitle["对比三本教材"]?.status, .done)
        XCTAssertEqual(byTitle["下单"]?.dependencyIDs, [byTitle["对比三本教材"]?.id].compactMap { $0 })
        XCTAssertEqual(byTitle["第一组 20 个"]?.isStep, true)
        XCTAssertEqual(byTitle["报名六级考试"]?.planId, nil)
    }

    func testPartialSampleImportsIntoExistingPlan() async throws {
        let store = makeSampleStore()
        let created = try await store.execute(CreatePlan(
            name: "英语六级冲刺", kind: .improvement,
            startAt: .day(DateOnly(y: 2026, m: 10, d: 1, sourceTZ: tz.identifier)),
            endAt: .day(DateOnly(y: 2026, m: 12, d: 31, sourceTZ: tz.identifier))))
        let planID = try XCTUnwrap(created.entityID)
        let file = try PlanFileCodec.decode(try sampleData("partial-into-existing-plan"))
        let plan = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .skip,
                                                   targetPlanID: planID)
        XCTAssertEqual(plan.errorCount, 0, plan.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
        XCTAssertEqual(plan.summary.stages, 1)
        XCTAssertEqual(plan.summary.metrics, 1)
        XCTAssertEqual(plan.summary.tasks, 3)
        XCTAssertEqual(plan.summary.measurements, 1)
    }

    func testInvalidSampleReportsEachProblem() async throws {
        let file = try PlanFileCodec.decode(try sampleData("invalid-demo"))
        let store = makeSampleStore()
        let plan = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .skip)
        XCTAssertEqual(plan.errorCount, 5, plan.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
        XCTAssertEqual(plan.warningCount, 1)
        XCTAssertEqual(plan.summary.tasks, 2)
        XCTAssertTrue(plan.canImport)
    }

    // MARK: - 文件与版本

    func testRejectsNonPlanFilesAndNewerVersions() {
        XCTAssertThrowsError(try PlanFileCodec.decode(Data("not json".utf8))) { error in
            XCTAssertTrue(error is PlanFileError)
            XCTAssertNotEqual(error as? PlanFileError, .notAPlanFile)
        }
        XCTAssertThrowsError(try PlanFileCodec.decode(Data(#"{"format":"other","schemaVersion":1}"#.utf8))) { error in
            XCTAssertEqual(error as? PlanFileError, .notAPlanFile)
        }
        XCTAssertThrowsError(try PlanFileCodec.decode(Data(#"{"format":"movo.plan-file","schemaVersion":99}"#.utf8))) { error in
            XCTAssertEqual(error as? PlanFileError, .newerVersion(99))
        }
        let missingName = #"{"format":"movo.plan-file","schemaVersion":1,"plans":[{"kind":"delivery"}]}"#
        XCTAssertThrowsError(try PlanFileCodec.decode(Data(missingName.utf8))) { error in
            let message = (error as? PlanFileError)?.message ?? ""
            XCTAssertTrue(message.contains("name"), message)
        }
    }

    func testBlankTemplateParsesAndImportsCleanly() async throws {
        let file = try PlanFileCodec.decode(Data(PlanFileTemplate.json.utf8))
        XCTAssertEqual(file.schemaVersion, PlanFile.currentSchemaVersion)
        let store = makeStore()
        let plan = await PlanFileImporter.makePlan(file: file, store: store, duplicateMode: .skip)
        XCTAssertEqual(plan.errorCount, 0, plan.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
        XCTAssertTrue(plan.canImport)
        XCTAssertEqual(plan.summary.recurring, 1)
        XCTAssertEqual(plan.summary.steps, 4)
    }
}
