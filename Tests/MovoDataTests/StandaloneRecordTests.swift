import XCTest
import MovoKit

/// 无计划记录（独立待办的投入）在导出与导入里的往返。
///
/// 导出原本只按计划聚合记录，这类记录会在 `activities.filter { $0.planId == plan.id }`
/// 里被静默丢掉——导出看着成功，内容却少了一块。这里把「它们必须出现在文件里、
/// 也必须能原样导入」钉住（AC18 / AC23）。
@MainActor
final class StandaloneRecordTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!

    private func makeStore(_ device: String = "standalone-record") -> DomainStore {
        DomainStore(repository: InMemoryRepository(),
                    clock: TravelClock(Date(timeIntervalSince1970: 1_800_000_000)),
                    timeZoneProvider: FixedTimeZoneProvider(identifier: tz.identifier),
                    deviceIDProvider: FixedDeviceIDProvider(device), defaults: .fallback)
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
        return ExportService.gather(plans: plans, stages: stages, tasks: await repo.allTasks(),
                                    metrics: metrics, measurements: await repo.allMeasurements(),
                                    activities: await repo.allActivities(), notes: await repo.allNotes(),
                                    occurrences: [], rules: await repo.rules())
    }

    private func bundle(_ store: DomainStore,
                        options: PlanFileOptions = PlanFileOptions(includeRecords: true)) async -> ExportBundle {
        ExportService.export(await scope(store), format: .json, options: options,
                             generatedAt: store.now, timeZone: tz)
    }

    private func exportFile(_ store: DomainStore,
                            options: PlanFileOptions = PlanFileOptions(includeRecords: true)) async throws -> PlanFile {
        try PlanFileCodec.decode(Data(await bundle(store, options: options).content.utf8))
    }

    /// 一个独立待办 + 它的投入记录，外加一个计划里的记录作对照。
    @discardableResult
    private func seed(_ store: DomainStore) async throws -> (looseTask: UUID, plan: UUID) {
        let looseResult = try await store.execute(CreateTask(title: "整理书架"))
        let looseTask = try XCTUnwrap(looseResult.entityID)
        _ = try await store.execute(LogActivity(taskID: looseTask, happenedAt: .precise(store.now),
                                                durationMinutes: 25, text: "顺手整理了一层"))

        let planResult = try await store.execute(
            CreatePlan(name: "英语", kind: .improvement, category: .study))
        let plan = try XCTUnwrap(planResult.entityID)
        _ = try await store.execute(LogActivity(planID: plan, happenedAt: .precise(store.now),
                                                durationMinutes: 40, text: "背了 20 个"))
        return (looseTask, plan)
    }

    // MARK: - 导出

    func testPlanLessRecordGoesToTheTopLevelNotIntoAPlan() async throws {
        let store = makeStore()
        let ids = try await seed(store)
        let bundle = await bundle(store)
        XCTAssertEqual(bundle.standaloneRecordCount, 1, "导出预览要能说出有这类记录")

        let file = try await exportFile(store)
        XCTAssertEqual(file.records?.count, 1, "无计划记录写进顶层 records")
        XCTAssertEqual(file.records?.first?.task, ids.looseTask.uuidString, "仍然记得它关联哪一项待办")
        XCTAssertEqual(file.records?.first?.minutes, 25)
        XCTAssertEqual(file.records?.first?.text, "顺手整理了一层")
        XCTAssertEqual(file.plans?.first?.records?.count, 1, "计划里的记录照旧挂在计划下")
    }

    func testPlanLessRecordsFollowTheSameOptInAsPlannedOnes() async throws {
        let store = makeStore()
        try await seed(store)

        let plain = try await exportFile(store, options: PlanFileOptions())
        XCTAssertNil(plain.records, "没勾选「行动记录」时不该出现")
        XCTAssertNil(plain.plans?.first?.records)
    }

    func testMarkdownListsPlanLessRecordsUnderTheirOwnHeading() async throws {
        let store = makeStore()
        try await seed(store)

        let bundle = ExportService.export(await scope(store), format: .markdown,
                                          options: PlanFileOptions(includeRecords: true),
                                          generatedAt: store.now, timeZone: tz)
        XCTAssertTrue(bundle.content.contains("## 未归属计划的行动记录"))
        XCTAssertTrue(bundle.content.contains("顺手整理了一层"))
    }

    /// 限定导出单个计划时，无计划记录不该被顺带带上——它们不属于这个计划。
    func testSinglePlanExportLeavesPlanLessRecordsOut() async throws {
        let store = makeStore()
        try await seed(store)
        let repo = store.repository
        let allPlans = await repo.allPlans()
        let plan = try XCTUnwrap(allPlans.first)

        let planScope = ExportService.gather(plans: allPlans, stages: [], tasks: [],
                                             metrics: [], measurements: [],
                                             activities: await repo.allActivities(), notes: [],
                                             occurrences: [], rules: [], onlyPlanID: plan.id)
        let bundle = ExportService.export(planScope, format: .json,
                                          options: PlanFileOptions(includeRecords: true),
                                          generatedAt: store.now, timeZone: tz)
        XCTAssertEqual(bundle.standaloneRecordCount, 0)
        XCTAssertEqual(bundle.includedPlanNames, ["英语"])
    }

    // MARK: - 导入

    func testImportWithoutATargetPlanKeepsRecordsPlanLess() async throws {
        let source = makeStore("source")
        try await seed(source)
        let file = try await exportFile(source)

        let target = makeStore("target")
        let plan = await PlanFileImporter.makePlan(file: file, store: target, duplicateMode: .skip)
        XCTAssertEqual(plan.errorCount, 0, plan.issues.map(\.message).joined(separator: "\n"))
        XCTAssertFalse(PlanFileImporter.needsTargetPlan(file), "行动记录不再强制要求目标计划")
        XCTAssertTrue(PlanFileImporter.hasLooseContent(file))

        _ = try await PlanFileImporter.apply(plan, store: target)

        let records = await target.repository.allActivities()
        XCTAssertEqual(records.count, 2, "顶层的无计划记录 + 计划里的记录，一条都不该丢")
        let orphan = records.filter { $0.planId == nil }
        XCTAssertEqual(orphan.count, 1, "没有目标计划时导入为无计划记录")
        XCTAssertEqual(orphan.first?.durationMinutes, 25)
        XCTAssertEqual(records.filter { $0.planId != nil }.count, 1, "计划里的记录仍然挂在新导入的计划下")
    }

    func testImportWithATargetPlanAttachesRecordsToIt() async throws {
        let source = makeStore("source")
        try await seed(source)
        let file = try await exportFile(source)

        let target = makeStore("target")
        let existingResult = try await target.execute(CreatePlan(name: "收件箱", kind: .improvement))
        let existing = try XCTUnwrap(existingResult.entityID)
        let plan = await PlanFileImporter.makePlan(file: file, store: target, duplicateMode: .skip,
                                                   targetPlanID: existing)
        XCTAssertEqual(plan.errorCount, 0, plan.issues.map(\.message).joined(separator: "\n"))

        _ = try await PlanFileImporter.apply(plan, store: target)

        let records = await target.repository.activities(planID: existing)
        XCTAssertEqual(records.count, 1, "选了目标计划就挂进去")
        XCTAssertEqual(records.first?.planId, existing)
    }

    /// 往返一次之后，无计划记录仍然是「有投入、有说明、关联着待办」的完整记录。
    func testRoundTripPreservesDurationAndNote() async throws {
        let source = makeStore("source")
        try await seed(source)
        let file = try await exportFile(source)

        let target = makeStore("target")
        let plan = await PlanFileImporter.makePlan(file: file, store: target, duplicateMode: .skip)
        _ = try await PlanFileImporter.apply(plan, store: target)

        let all = await target.repository.allActivities()
        let record = try XCTUnwrap(all.first { $0.planId == nil }, "无计划的那一条")
        let taskID = try XCTUnwrap(record.taskId, "记录应当仍然关联着导入进来的那项待办")
        let task = await target.repository.task(taskID)
        XCTAssertEqual(task?.title, "整理书架")
        XCTAssertEqual(record.durationMinutes, 25)
        XCTAssertEqual(record.text, "顺手整理了一层")
    }
}
