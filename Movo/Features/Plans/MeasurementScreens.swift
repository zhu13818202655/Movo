//
//  MeasurementScreens.swift
//  Features/Plans
//
//  M09-Result 补记结果 / M09-ResultHistory 结果历史。
//  记录测量 ≠ 宣告目标达成（REQ 21）；缺测不补 0；更正保留旧版本并标注"已更正"。
//

import SwiftUI
import MovoKit

// MARK: - 补记结果

public struct LogMeasurementScreen: View {
    @Environment(AppEnvironment.self) private var env
    /// 关闭本页：`.logMeasurement` 可能被压入导航栈（结果历史里「记录一次」），
    /// 也可能以浮层呈现（计划详情里「记录一次」），用 dismiss 兼顾两种。
    @Environment(\.dismiss) private var dismiss

    let metricID: UUID

    @State private var metric: PlanMetric?
    @State private var planName: String?
    @State private var valueText = ""
    @State private var measuredAt = Date()
    @State private var usesCustomDate = false
    @State private var note = ""
    @State private var isSaving = false

    public init(metricID: UUID) { self.metricID = metricID }

    public var body: some View {
        Group {
            if metric == nil {
                LoadingPlaceholder("正在读取指标…")
            } else {
                content
            }
        }
        .movoPageBackground()
        .task { await load() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScreenScroll {
                ScreenChrome("记录一次结果", subtitle: planName)

                if let error = env.lastError {
                    MovoBanner(error: error) { _ in env.lastError = nil }
                }

                MovoFormSection("数值",
                                footnote: "只记录你实际测到的数值。没有测量就留空，系统不会补 0。") {
                    MovoNumberField("\(metric?.name ?? "数值")（\(metric?.unitDisplayName ?? "")）",
                                    text: $valueText,
                                    placeholder: "例如：68.7",
                                    unitText: metric.map { $0.unitDisplayName },
                                    errorMessage: valueError)
                    if let latest = latestText {
                        Text("上一次记录：\(latest)").font(MovoFont.caption)
                            .foregroundStyle(MovoColor.muted)
                    }
                }

                MovoFormSection("时间") {
                    MovoDateField("补记到别的日期", placeholder: "今天",
                                  isOn: $usesCustomDate, date: $measuredAt,
                                  timeZone: env.store.currentTimeZone)
                }

                MovoFormSection("备注（可选）") {
                    MovoTextField("发生了什么", text: $note,
                                  placeholder: "例如：早上空腹称的", axis: .vertical)
                }
            }

            MovoActionBar {
                MovoButton("保存记录", kind: .primary,
                           isEnabled: parsedValue != nil && !isSaving, isLoading: isSaving) {
                    _Concurrency.Task { await save() }
                }
                MovoButton("取消", kind: .quiet) { dismiss() }
                Spacer(minLength: 0)
            }
        }
    }

    @State private var latestText: String?

    private var parsedValue: Double? {
        let trimmed = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    private var valueError: String? {
        let trimmed = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parsedValue == nil ? "请输入一个数字，例如 68.7。" : nil
    }

    private func save() async {
        guard let metric, let value = parsedValue, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let day = usesCustomDate
            ? DateOnly(from: measuredAt, in: env.store.currentTimeZone)
            : env.store.today
        do {
            try await env.store.execute(RecordMeasurement(
                planID: metric.planId, metricID: metric.id, measuredAt: day, value: value,
                unit: metric.unit, note: note.isEmpty ? nil : note, source: .manual))
            env.lastBatchNotice = env.store.lastNotification
            dismiss()
        } catch let error as MovoError {
            env.lastError = error
        } catch {
            env.lastError = .invalidStructure(reason: "这条结果没有保存成功。")
        }
    }

    private func load() async {
        guard let loaded = await env.store.repository.metric(metricID) else {
            env.lastError = .notFound(entityType: .metric, id: metricID)
            return
        }
        metric = loaded
        planName = await env.store.repository.plan(loaded.planId)?.name
        let measurements = await env.store.repository.measurements(metricID: metricID)
        if let latest = ProgressPolicy.latestMeasurement(metricID: metricID, measurements: measurements) {
            let value = latest.value.rounded() == latest.value
                ? String(Int(latest.value)) : String(format: "%.1f", latest.value)
            latestText = "\(value)\(loaded.unitDisplayName) · \(latest.measuredAt.displayString)"
        }
    }
}

// MARK: - 结果历史

public struct MetricHistoryScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let metricID: UUID

    @State private var metric: PlanMetric?
    @State private var planName: String?
    @State private var trend: MetricTrend?
    @State private var points: [MetricPoint] = []
    @State private var correcting: MetricPoint?

    public init(metricID: UUID) { self.metricID = metricID }

    public var body: some View {
        Group {
            if metric == nil {
                LoadingPlaceholder("正在读取结果历史…")
            } else {
                content
            }
        }
        .movoPageBackground()
        .task { await reload() }
        .sheet(item: $correcting) { point in
            MeasurementCorrectionSheet(point: point, metricID: metricID) {
                _Concurrency.Task { await reload() }
            }
            .environment(env)
        }
    }

    private var content: some View {
        ScreenScroll {
            ScreenChrome(metric?.name ?? "结果历史", subtitle: planName) {
                MovoButton("记录一次", systemImage: "plus", kind: .primary) {
                    router.push(.logMeasurement(metricID: metricID))
                }
            }

            if let trend, !trend.points.isEmpty {
                MovoFormSection("趋势", footnote: "只连接实际测量点，缺测留空，不做预测。") {
                    MetricTrendChart(trend)
                    HStack(spacing: MovoSpace.s) {
                        MovoTag("共 \(trend.points.count) 次测量", systemImage: "number")
                        if trend.hasGap { MovoTag("有缺测", systemImage: "calendar.badge.exclamationmark") }
                        if trend.correctedCount > 0 {
                            MovoTag("\(trend.correctedCount) 次更正", systemImage: "pencil")
                        }
                        if let deltaText = trend.deltaText {
                            MovoTag("较上次 \(deltaText)", systemImage: "arrow.left.arrow.right")
                        }
                    }
                }

                if let target = metric?.targetValue {
                    MovoFormSection("参考目标值", footnote: "仅用于录入时对照，不构成建议或健康结论。") {
                        MovoInfoRow("目标值",
                                    value: "\(PlanEditScreen.numberText(target))\(metric?.unitDisplayName ?? "")",
                                    systemImage: "target")
                        MovoInfoRow("方向", value: metric?.targetDirection.displayName ?? "不设定方向",
                                    systemImage: "arrow.up.arrow.down")
                    }
                }

                MovoFormSection("全部记录", footnote: "更正会保留旧版本，历史里仍可回看原来的数值。") {
                    ForEach(trend.points.reversed()) { point in
                        MetricRecordRow(point: point,
                                        metricName: metric?.name ?? "",
                                        unit: metric?.unit ?? "",
                                        onCorrect: point.isGap ? nil : { correcting = point })
                    }
                }
            } else {
                MovoEmptyState(systemImage: "chart.line.uptrend.xyaxis",
                               title: "还没有测量记录",
                               message: "记录一次实际测量后，这里会出现趋势。缺测不会用 0 补齐。",
                               actionTitle: "记录一次",
                               action: { router.push(.logMeasurement(metricID: metricID)) })
                    .frame(minHeight: 260)
            }
        }
    }

    private func reload() async {
        guard let loaded = await env.store.repository.metric(metricID) else {
            env.lastError = .notFound(entityType: .metric, id: metricID)
            return
        }
        metric = loaded
        planName = await env.store.repository.plan(loaded.planId)?.name
        let measurements = await env.store.repository.measurements(metricID: metricID)
        trend = ProgressPolicy.trend(for: loaded, measurements: measurements)
        points = trend?.points ?? []
    }
}

// MARK: - 更正一条结果

struct MeasurementCorrectionSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let point: MetricPoint
    let metricID: UUID
    let onSaved: () -> Void

    @State private var valueText: String
    @State private var note = ""
    @State private var isSaving = false

    init(point: MetricPoint, metricID: UUID, onSaved: @escaping () -> Void) {
        self.point = point
        self.metricID = metricID
        self.onSaved = onSaved
        self._valueText = State(initialValue: PlanEditScreen.numberText(point.value))
    }

    var body: some View {
        MovoSheet {
            MovoSheetHeader("更正这条结果",
                            subtitle: "\(point.date.displayString) · 原来的记录会保留",
                            onClose: { dismiss() })

            MovoNumberField("新的数值", text: $valueText, placeholder: "例如：68.7",
                            errorMessage: errorMessage)

            MovoTextField("备注（可选）", text: $note, placeholder: "为什么更正", axis: .vertical)

            HStack(spacing: MovoSpace.s) {
                MovoButton("保存更正", kind: .primary,
                           isEnabled: parsedValue != nil && !isSaving, isLoading: isSaving) {
                    _Concurrency.Task { await save() }
                }
                MovoButton("取消", kind: .quiet) { dismiss() }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 460)
        .movoPageBackground()
    }

    private var parsedValue: Double? {
        let trimmed = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    private var errorMessage: String? {
        valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请输入新的数值。" : nil
    }

    private func save() async {
        guard let value = parsedValue, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let measurementID = point.id
            let original = await env.store.repository.measurement(measurementID)
            try await env.store.execute(CorrectMeasurement(
                measurementID: measurementID, newValue: value,
                newNote: note.isEmpty ? nil : note,
                baseRevision: original?.revision ?? 0))
            onSaved()
            dismiss()
        } catch let error as MovoError {
            env.lastError = error
        } catch {
            env.lastError = .invalidStructure(reason: "更正没有保存成功。")
        }
    }
}

#Preview("结果历史") {
    MetricHistoryScreen(metricID: DemoFixtures.IDs.weightMetric)
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
