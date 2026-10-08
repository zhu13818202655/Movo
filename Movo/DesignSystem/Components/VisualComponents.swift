//
//  VisualComponents.swift
//  DesignSystem/Components
//
//  统计与可视化组件：
//  - MovoSegmentedProgressBar：阶段分段进度条（交付型）
//  - MovoDayBarChart：7天每日行动分布柱状图（回顾页）
//  - MovoCategoryDistributionBar：分类精力占比堆叠条（回顾页）
//  - MovoOccurrenceStrip：重复任务实例状态离散序列（重复任务）
//  - MovoTimelineView：计划与任务时间线跨度图（时间线视图）
//

import SwiftUI
import Charts

// MARK: - 1. 阶段分段进度条（MovoSegmentedProgressBar）

public struct MovoSegmentedProgressBar: View {
    private let segments: [StageProgressSegment]
    private let totalDone: Int
    private let totalCount: Int
    private let isCompact: Bool

    @State private var hoveredSegmentID: UUID?

    public init(segments: [StageProgressSegment], totalDone: Int, totalCount: Int, isCompact: Bool = false) {
        self.segments = segments
        self.totalDone = totalDone
        self.totalCount = totalCount
        self.isCompact = isCompact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.xs) {
            if segments.isEmpty || totalCount == 0 {
                // 回退到简单进度条
                let fraction = totalCount == 0 ? 0 : Double(totalDone) / Double(totalCount)
                Capsule().fill(MovoColor.soft)
                    .overlay(alignment: .leading) {
                        Capsule().fill(MovoColor.done)
                            .frame(width: max(0, fraction * 100))
                    }
                    .frame(height: isCompact ? 4 : 8)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(segments) { seg in
                            let segWidth = max(4, (Double(seg.total) / Double(totalCount)) * (geo.size.width - Double(max(0, segments.count - 1) * 2)))
                            segmentBar(seg, width: segWidth)
                                #if os(macOS)
                                .onHover { hovering in
                                    hoveredSegmentID = hovering ? seg.id : nil
                                }
                                #endif
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: isCompact ? 2 : 4, style: .continuous))
                }
                .frame(height: isCompact ? 4 : 8)
            }

            if !isCompact {
                if let hovered = segments.first(where: { $0.id == hoveredSegmentID }) {
                    Text(hovered.displayText)
                        .font(MovoFont.captionEmphasis)
                        .foregroundStyle(MovoColor.ink)
                        .transition(.opacity)
                } else {
                    HStack {
                        Text("\(totalDone)/\(totalCount) 项完成")
                            .font(MovoFont.caption)
                            .foregroundStyle(MovoColor.muted)
                        Spacer()
                        if totalCount > 0 {
                            Text("\(Int(Double(totalDone) / Double(totalCount) * 100))%")
                                .font(MovoFont.captionEmphasis)
                                .foregroundStyle(MovoColor.ink)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("阶段分段进度")
        .accessibilityValue("\(totalDone)/\(totalCount) 项完成")
    }

    @ViewBuilder
    private func segmentBar(_ seg: StageProgressSegment, width: CGFloat) -> some View {
        let fillFraction = seg.total == 0 ? 0 : min(max(Double(seg.done) / Double(seg.total), 0), 1)
        ZStack(alignment: .leading) {
            Rectangle().fill(MovoColor.soft)
            Rectangle().fill(MovoColor.done)
                .frame(width: max(0, width * fillFraction))
        }
        .frame(width: width)
    }
}

// MARK: - 2. 7天每日行动分布柱状图（MovoDayBarChart）

public struct MovoDayBarChart: View {
    private let dailyActions: [DayActionStat]
    private let totalCount: Int

    public init(dailyActions: [DayActionStat], totalCount: Int) {
        self.dailyActions = dailyActions
        self.totalCount = totalCount
    }

    private var maxCount: Int {
        max(dailyActions.map(\.count).max() ?? 0, 1)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            HStack {
                Text("本周行动分布")
                    .font(MovoFont.headline)
                    .foregroundStyle(MovoColor.ink)
                Spacer()
                Text("共 \(totalCount) 次记录")
                    .font(MovoFont.caption)
                    .foregroundStyle(MovoColor.muted)
            }

            if totalCount == 0 {
                HStack {
                    Spacer()
                    Text("这一周暂无行动记录")
                        .font(MovoFont.caption)
                        .foregroundStyle(MovoColor.muted)
                        .padding(.vertical, MovoSpace.m)
                    Spacer()
                }
            } else {
                Chart(dailyActions) { item in
                    BarMark(
                        x: .value("星期", item.weekdayName),
                        y: .value("行动次数", item.count)
                    )
                    .foregroundStyle(item.count > 0 ? MovoColor.primary : Color.clear)
                    .cornerRadius(4)
                }
                .chartYScale(domain: 0...max(4, maxCount + 1))
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisValueLabel {
                            if let name = value.as(String.self) {
                                Text(name).font(MovoFont.caption)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(MovoColor.line)
                        AxisValueLabel {
                            if let intVal = value.as(Int.self) {
                                Text("\(intVal)").font(MovoFont.caption)
                            }
                        }
                    }
                }
                .frame(height: 120)

                Text("按实际记录日期汇总，不计算连续打卡。")
                    .font(MovoFont.caption)
                    .foregroundStyle(MovoColor.muted)
            }
        }
        .padding(MovoSpace.s)
        .background(RoundedRectangle(cornerRadius: MovoRadius.card).fill(MovoColor.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("本周行动分布")
        .accessibilityValue("共 \(totalCount) 次记录")
    }
}

// MARK: - 3. 分类精力占比堆叠条（MovoCategoryDistributionBar）

public struct MovoCategoryDistributionBar: View {
    private let distribution: [CategoryShareStat]
    private let totalCount: Int

    public init(distribution: [CategoryShareStat], totalCount: Int) {
        self.distribution = distribution
        self.totalCount = totalCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            HStack {
                Text("分类投入分布")
                    .font(MovoFont.headline)
                    .foregroundStyle(MovoColor.ink)
                Spacer()
            }

            if totalCount == 0 || distribution.isEmpty {
                Text("暂无分类记录")
                    .font(MovoFont.caption)
                    .foregroundStyle(MovoColor.muted)
            } else {
                // 水平堆叠条
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(distribution) { item in
                            let width = max(4, geo.size.width * item.share - 2)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(MovoCategoryColor.color(for: item.category))
                                .frame(width: width)
                        }
                    }
                }
                .frame(height: 10)

                // 图例文本
                FlowLayout(spacing: MovoSpace.s) {
                    ForEach(distribution) { item in
                        HStack(spacing: MovoSpace.xs) {
                            Circle()
                                .fill(MovoCategoryColor.color(for: item.category))
                                .frame(width: 8, height: 8)
                            Text("\(item.displayName) \(item.count)次")
                                .font(MovoFont.caption)
                                .foregroundStyle(MovoColor.ink)
                            Text("(\(Int(item.share * 100))%)")
                                .font(MovoFont.caption)
                                .foregroundStyle(MovoColor.muted)
                        }
                    }
                }
            }
        }
        .padding(MovoSpace.s)
        .background(RoundedRectangle(cornerRadius: MovoRadius.card).fill(MovoColor.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("分类投入分布")
        .accessibilityValue(distribution.map { "\($0.displayName) \(Int($0.share * 100))%" }.joined(separator: "，"))
    }
}

// MARK: - 4. 重复任务实例离散状态序列（MovoOccurrenceStrip）

public struct MovoOccurrenceStrip: View {
    private let items: [OccurrenceStatusItem]

    public init(items: [OccurrenceStatusItem]) {
        self.items = items
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            HStack {
                Text("近期执行分布")
                    .font(MovoFont.headline)
                    .foregroundStyle(MovoColor.ink)
                Spacer()
                Text("最近 \(items.count) 次")
                    .font(MovoFont.caption)
                    .foregroundStyle(MovoColor.muted)
            }

            if items.isEmpty {
                Text("还没有执行记录。")
                    .font(MovoFont.caption)
                    .foregroundStyle(MovoColor.muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MovoSpace.s) {
                        ForEach(items) { item in
                            VStack(spacing: MovoSpace.xs) {
                                stateIcon(item.state)
                                Text(item.date?.displayString ?? "-")
                                    .font(MovoFont.caption)
                                    .foregroundStyle(MovoColor.muted)
                            }
                        }
                    }
                    .padding(.vertical, MovoSpace.xs)
                }

                HStack(spacing: MovoSpace.m) {
                    legendItem(color: MovoColor.done, systemName: "checkmark", text: "已完成")
                    legendItem(color: MovoColor.inactive, systemName: "forward.fill", text: "已跳过")
                    legendItem(color: MovoColor.muted, systemName: "circle", text: "未记录")
                    legendItem(color: MovoColor.todo, systemName: "clock", text: "待做")
                }
            }
        }
        .padding(MovoSpace.s)
        .background(RoundedRectangle(cornerRadius: MovoRadius.card).fill(MovoColor.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("近期执行分布")
        .accessibilityValue("已完成 \(items.filter { $0.state == .done }.count) 次，跳过 \(items.filter { $0.state == .skipped }.count) 次")
    }

    @ViewBuilder
    private func stateIcon(_ state: OccurrenceStatusItem.State) -> some View {
        ZStack {
            Circle()
                .fill(stateColor(state).opacity(0.15))
                .frame(width: 28, height: 28)
            Image(systemName: iconName(state))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(stateColor(state))
        }
    }

    private func stateColor(_ state: OccurrenceStatusItem.State) -> Color {
        switch state {
        case .done: MovoColor.done
        case .skipped: MovoColor.inactive
        case .unrecorded: MovoColor.muted
        case .pending: MovoColor.todo
        }
    }

    private func iconName(_ state: OccurrenceStatusItem.State) -> String {
        switch state {
        case .done: "checkmark"
        case .skipped: "forward.fill"
        case .unrecorded: "minus"
        case .pending: "clock"
        }
    }

    @ViewBuilder
    private func legendItem(color: Color, systemName: String, text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
        }
    }
}

// MARK: - 5. 时间线甘特跨度图（MovoTimelineView）

public struct MovoTimelineView: View {
    private let timeline: PlanTimelineView
    private let onSelectTask: ((UUID) -> Void)?

    @State private var showUnscheduled = false

    public init(timeline: PlanTimelineView, onSelectTask: ((UUID) -> Void)? = nil) {
        self.timeline = timeline
        self.onSelectTask = onSelectTask
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.m) {
            if timeline.spans.isEmpty {
                VStack(spacing: MovoSpace.s) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 32))
                        .foregroundStyle(MovoColor.muted)
                    Text("当前计划暂无带起止时间的事项")
                        .font(MovoFont.body)
                        .foregroundStyle(MovoColor.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(RoundedRectangle(cornerRadius: MovoRadius.card).fill(MovoColor.surface))
            } else {
                VStack(alignment: .leading, spacing: MovoSpace.s) {
                    HStack {
                        Text("起止时间线")
                            .font(MovoFont.headline)
                            .foregroundStyle(MovoColor.ink)
                        Spacer()
                        if let min = timeline.minDate, let max = timeline.maxDate {
                            Text("\(min.displayString) – \(max.displayString)")
                                .font(MovoFont.caption)
                                .foregroundStyle(MovoColor.muted)
                        }
                    }

                    // 跨度条列表
                    VStack(spacing: MovoSpace.s) {
                        ForEach(timeline.spans) { span in
                            spanRow(span)
                        }
                    }
                }
                .padding(MovoSpace.s)
                .background(RoundedRectangle(cornerRadius: MovoRadius.card).fill(MovoColor.surface))
            }

            // 未排期抽屉
            if !timeline.unscheduledTasks.isEmpty {
                DisclosureGroup(
                    isExpanded: $showUnscheduled,
                    content: {
                        VStack(alignment: .leading, spacing: MovoSpace.s) {
                            ForEach(timeline.unscheduledTasks) { task in
                                HStack {
                                    Image(systemName: "circle")
                                        .foregroundStyle(MovoColor.muted)
                                    Text(task.title)
                                        .font(MovoFont.body)
                                        .foregroundStyle(MovoColor.ink)
                                    Spacer()
                                    Button("设置时间") {
                                        onSelectTask?(task.id)
                                    }
                                    .font(MovoFont.caption)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(MovoColor.primary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.top, MovoSpace.s)
                    },
                    label: {
                        HStack {
                            Image(systemName: "clock.badge.questionmark")
                                .foregroundStyle(MovoColor.muted)
                            Text("未排期任务 (\(timeline.unscheduledTasks.count) 项)")
                                .font(MovoFont.bodyEmphasis)
                                .foregroundStyle(MovoColor.ink)
                        }
                    }
                )
                .padding(MovoSpace.s)
                .background(RoundedRectangle(cornerRadius: MovoRadius.card).fill(MovoColor.surface))
            }
        }
    }

    @ViewBuilder
    private func spanRow(_ span: TimelineSpanItem) -> some View {
        Button {
            if span.kind == .task {
                onSelectTask?(span.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: MovoSpace.xs) {
                    if span.depth > 0 {
                        Spacer().frame(width: CGFloat(span.depth) * 12)
                    }
                    iconForKind(span.kind)
                    Text(span.title)
                        .font(span.kind == .plan ? MovoFont.headline : MovoFont.body)
                        .foregroundStyle(MovoColor.ink)
                    Spacer()
                    timeRangeText(start: span.startAt, end: span.endAt)
                }

                // 时间胶囊指示条
                GeometryReader { geo in
                    let (offsetPct, widthPct) = calculateSpanPosition(start: span.startAt?.dateOnly, end: span.endAt?.dateOnly)
                    ZStack(alignment: .leading) {
                        Capsule().fill(MovoColor.soft.opacity(0.6))
                        Capsule()
                            .fill(spanColor(span))
                            .overlay(
                                Capsule()
                                    .stroke(MovoColor.warning, lineWidth: span.isOutRange ? 1.5 : 0)
                            )
                            .frame(width: max(8, geo.size.width * widthPct))
                            .offset(x: geo.size.width * offsetPct)
                    }
                }
                .frame(height: span.kind == .plan ? 8 : 6)
            }
        }
        .buttonStyle(.plain)
    }

    private func calculateSpanPosition(start: DateOnly?, end: DateOnly?) -> (offset: CGFloat, width: CGFloat) {
        guard let minD = timeline.minDate, let maxD = timeline.maxDate else {
            return (0, 1)
        }
        let totalDays = max(1, daysBetween(minD, maxD))
        let startD = start ?? minD
        let endD = end ?? maxD

        let startOffsetDays = max(0, daysBetween(minD, startD))
        let spanDays = max(1, daysBetween(startD, endD))

        let offset = CGFloat(startOffsetDays) / CGFloat(totalDays)
        let width = min(1.0 - offset, CGFloat(spanDays) / CGFloat(totalDays))
        return (offset, max(0.05, width))
    }

    private func daysBetween(_ a: DateOnly, _ b: DateOnly) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let start = cal.date(from: DateComponents(year: a.y, month: a.m, day: a.d)) ?? Date()
        let end = cal.date(from: DateComponents(year: b.y, month: b.m, day: b.d)) ?? Date()
        return max(0, cal.dateComponents([.day], from: start, to: end).day ?? 0)
    }

    private func spanColor(_ span: TimelineSpanItem) -> Color {
        if span.isCompleted { return MovoColor.done }
        switch span.kind {
        case .plan: return MovoColor.primary
        case .stage: return MovoColor.inProgress
        case .task: return span.isOutRange ? MovoColor.warning : MovoColor.todo
        }
    }

    @ViewBuilder
    private func iconForKind(_ kind: TimelineSpanItem.Kind) -> some View {
        switch kind {
        case .plan:
            Image(systemName: "flag.checkered").font(.system(size: 12)).foregroundStyle(MovoColor.primary)
        case .stage:
            Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(MovoColor.inProgress)
        case .task:
            Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(MovoColor.muted)
        }
    }

    private func timeRangeText(start: TimePoint?, end: TimePoint?) -> some View {
        let text: String
        if let start, let end {
            text = "\(start.displayString) – \(end.displayString)"
        } else if let end {
            text = "截止 \(end.displayString)"
        } else if let start {
            text = "\(start.displayString) 开始"
        } else {
            text = "未设置时间"
        }
        return Text(text).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
    }
}

// 辅助流式布局
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeightInRow: CGFloat = 0

        for view in subviews {
            let viewSize = view.sizeThatFits(.unspecified)
            if currentX + viewSize.width > width && currentX > 0 {
                currentX = 0
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            maxHeightInRow = max(maxHeightInRow, viewSize.height)
            currentX += viewSize.width + spacing
        }
        height = currentY + maxHeightInRow
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var maxHeightInRow: CGFloat = 0

        for view in subviews {
            let viewSize = view.sizeThatFits(.unspecified)
            if currentX + viewSize.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            view.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            maxHeightInRow = max(maxHeightInRow, viewSize.height)
            currentX += viewSize.width + spacing
        }
    }
}
