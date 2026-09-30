//
//  MetricTrendChart.swift
//  DesignSystem/Components
//
//  结果趋势图。只连接实际测量，缺测留空、不补 0、不预测；
//  显示单位与实际日期，刻度合理，避免夸大细微波动（UI-Prompt「回顾与健康隐私」）。
//

import SwiftUI
import Charts

public struct MetricTrendChart: View {
    private let trend: MetricTrend

    public init(_ trend: MetricTrend) { self.trend = trend }

    private var realPoints: [MetricPoint] { trend.points.filter { !$0.isGap } }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
                Text(trend.name).font(MovoFont.headline).foregroundStyle(MovoColor.ink)
                if let latest = trend.latest {
                    Text("\(formatted(latest)) \(trend.unitDisplayName)")
                        .font(MovoFont.bodyEmphasis)
                        .foregroundStyle(MovoColor.ink)
                }
                Spacer(minLength: 0)
                if let delta = trend.deltaText {
                    Text(delta).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
            }

            if realPoints.isEmpty {
                Text("还没有测量记录。缺测的日期不会补 0。")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            } else {
                Chart(realPoints) { point in
                    LineMark(x: .value("日期", point.date.iso8601DateString),
                             y: .value(trend.name, point.value))
                        .foregroundStyle(MovoColor.primary)
                        .interpolationMethod(.linear)
                    PointMark(x: .value("日期", point.date.iso8601DateString),
                              y: .value(trend.name, point.value))
                        .foregroundStyle(point.isRevised ? MovoColor.warning : MovoColor.primary)
                        .symbolSize(point.isRevised ? 80 : 50)
                }
                .chartYScale(domain: yDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(MovoColor.line)
                        AxisValueLabel {
                            if let raw = value.as(String.self),
                               let day = DateOnly(iso8601DateString: raw, sourceTZ: "UTC") {
                                Text(day.displayString).font(MovoFont.caption)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(MovoColor.line)
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(formatted(number)).font(MovoFont.caption)
                            }
                        }
                    }
                }
                .frame(height: 180)

                HStack(spacing: MovoSpace.xs) {
                    MovoTag("单位 \(trend.unitDisplayName)")
                    if trend.hasGap { MovoTag("有缺测日期") }
                    if trend.correctedCount > 0 { MovoTag("含 \(trend.correctedCount) 次更正") }
                }
                Text("仅展示实际测量，不生成健康结论。")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
        }
    }

    /// 刻度只在实测范围内留出边距，避免夸大细微波动
    private var yDomain: ClosedRange<Double> {
        let values = realPoints.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        if low == high {
            let pad = max(abs(low) * 0.05, 1)
            return (low - pad)...(high + pad)
        }
        let pad = (high - low) * 0.25
        return (low - pad)...(high + pad)
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
