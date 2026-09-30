//
//  SnapshotScreen.swift
//  Features/Plans
//
//  D09-Snapshot / M11-Snapshot 只读快照。
//  由事件回放到 asOf 当日结束重建，**不允许**在快照上编辑（AC14）。
//  返回当前视图时数值必须回到最新，验证：9/14 快照 2/7，返回当前仍 3/7。
//

import SwiftUI
import MovoKit

public struct SnapshotScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let planID: UUID

    @State private var asOf: DateOnly
    @State private var snapshot: PlanSnapshot?

    public init(planID: UUID, asOf: DateOnly) {
        self.planID = planID
        self._asOf = State(initialValue: asOf)
    }

    public var body: some View {
        Group {
            if let snapshot {
                content(snapshot)
            } else {
                LoadingPlaceholder("正在重建这一天的记录…")
            }
        }
        .movoPageBackground()
        .task(id: asOf) { await reload() }
    }

    @ViewBuilder
    private func content(_ snapshot: PlanSnapshot) -> some View {
        ScreenScroll {
            ScreenChrome(snapshot.planName, subtitle: snapshot.bannerText) {
                HStack(spacing: MovoSpace.s) {
                    MovoIconButton("chevron.left", label: "前一天") {
                        asOf = asOf.adding(days: -1)
                    }
                    MovoIconButton("chevron.right", label: "后一天") {
                        let next = asOf.adding(days: 1)
                        if next <= env.store.today { asOf = next }
                    }
                    MovoButton("回到今天", kind: .quiet) { asOf = env.store.today }
                }
            }

            MovoBanner(kind: .info,
                       title: "这是历史快照",
                       message: "只读视图，不会改动当前计划。重建用了 \(snapshot.restoredFromEventCount) 条变更事件。")

            MovoFormSection("日期") {
                MovoFormRow("查看哪一天的记录") {
                    DatePicker("", selection: pickerBinding, in: ...Date(),
                               displayedComponents: [.date])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .environment(\.timeZone, env.store.currentTimeZone)
                        .accessibilityLabel("查看哪一天的记录")
                }
            }

            MovoFormSection("概况") {
                MovoInfoRow("计划名称", value: snapshot.planName, systemImage: "folder")
                if let goal = snapshot.goalText, !goal.isEmpty {
                    MovoInfoRow("目标", value: goal, systemImage: "target")
                }
                if let target = snapshot.targetDate {
                    MovoInfoRow("目标日期", value: target.displayString, systemImage: "calendar")
                }
                MovoInfoRow("完成情况", value: snapshot.progressText, systemImage: "checkmark.circle")
            }

            if !snapshot.stages.isEmpty {
                MovoFormSection("阶段") {
                    ForEach(snapshot.stages) { stage in
                        HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
                            Image(systemName: "flag").font(.system(size: 12))
                                .foregroundStyle(MovoColor.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stage.name).font(MovoFont.bodyEmphasis)
                                    .foregroundStyle(MovoColor.ink)
                                Text("\(stage.statusText) · \(stage.done)/\(stage.total)")
                                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                            }
                            Spacer(minLength: MovoSpace.s)
                            if let achieved = stage.achievedAt {
                                MovoTag(Self.dayText(achieved, in: env.store.currentTimeZone),
                                        systemImage: "checkmark.seal")
                            }
                        }
                        .frame(minHeight: 32)
                    }
                }
            }

            if !snapshot.metrics.isEmpty {
                MovoFormSection("结果指标", footnote: "只显示该日及之前的最后一次实际测量，缺测留空。") {
                    ForEach(snapshot.metrics) { metric in
                        MovoInfoRow(metric.name, value: metricValue(metric),
                                    systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
            }

            MovoFormSection("历史调整") {
                MovoButton("查看完整时间线", systemImage: "clock.arrow.circlepath", kind: .quiet) {
                    router.push(.planHistory(planID))
                }
            }
        }
    }

    private var pickerBinding: Binding<Date> {
        Binding(
            get: { asOf.pickerDate },
            set: { newValue in
                let candidate = DateOnly(from: newValue, in: env.store.currentTimeZone)
                asOf = candidate > env.store.today ? env.store.today : candidate
            })
    }

    private func metricValue(_ metric: SnapshotMetric) -> String {
        guard let value = metric.latestValue else { return "该日之前没有测量" }
        let text = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        let dateText = metric.latestAt.map { " · \($0.displayString)" } ?? ""
        return "\(text)\(PlanMetric.unitDisplayName(for: metric.unit))\(dateText)"
    }

    private static func dayText(_ date: Date, in tz: TimeZone) -> String {
        DateOnly(from: date, in: tz).displayString
    }

    private func reload() async {
        snapshot = await env.store.snapshot(planID: planID, asOf: asOf)
    }
}

#Preview("只读快照") {
    SnapshotScreen(planID: DemoFixtures.IDs.workPlan,
                   asOf: DemoFixtures.today.adding(days: -14))
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
