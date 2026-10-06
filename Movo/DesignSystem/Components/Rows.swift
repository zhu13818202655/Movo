//
//  Rows.swift
//  DesignSystem/Components
//
//  任务行 / 计划行 / 树节点 / 重复行动行 / 结果记录行 / 建议卡 / 可撤销提示。
//  行内控件间距 4–8；触控区 ≥44；状态配文字，不只靠颜色。
//

import SwiftUI

// MARK: - 任务行

public struct TaskRowConfig: Hashable, Sendable {
    public var title: String
    public var planName: String?
    public var category: PlanCategory?
    public var status: TaskStatus
    public var timeText: String?
    public var dependencyText: String?
    public var isCompletedToday: Bool
    public var footnote: String?

    public init(title: String, planName: String? = nil, category: PlanCategory? = nil,
                status: TaskStatus = .todo, timeText: String? = nil, dependencyText: String? = nil,
                isCompletedToday: Bool = false, footnote: String? = nil) {
        self.title = title; self.planName = planName; self.category = category
        self.status = status; self.timeText = timeText; self.dependencyText = dependencyText
        self.isCompletedToday = isCompletedToday; self.footnote = footnote
    }
}

public struct TaskRow: View {
    private let config: TaskRowConfig
    private let showsCheckbox: Bool
    private let onToggle: (() -> Void)?
    private let onTap: (() -> Void)?

    public init(config: TaskRowConfig, showsCheckbox: Bool = true,
                onToggle: (() -> Void)? = nil, onTap: (() -> Void)? = nil) {
        self.config = config; self.showsCheckbox = showsCheckbox
        self.onToggle = onToggle; self.onTap = onTap
    }

    public init(item: TodayItem, onToggle: (() -> Void)? = nil, onTap: (() -> Void)? = nil) {
        let planName = item.planName
        let status: TaskStatus = {
            switch item.body {
            case .deadline(let t), .scheduled(let t), .inProgress(let t), .floating(let t),
                 .overdue(let t, _):
                return t.status
            case .occurrence(let o, _):
                switch o.status {
                case .done: return .done
                case .skipped: return .cancelled
                case .pending: return .todo
                }
            }
        }()
        self.config = TaskRowConfig(
            title: item.title, planName: planName, category: nil, status: status,
            timeText: item.timeText,
            dependencyText: item.dependency.isReady ? nil : item.dependency.badgeText,
            isCompletedToday: item.isCompletedToday,
            footnote: item.section == .completed ? nil : item.displayStatus)
        self.showsCheckbox = true
        self.onToggle = onToggle
        self.onTap = onTap
    }

    public var body: some View {
        HStack(alignment: .top, spacing: MovoSpace.s) {
            if showsCheckbox {
                Button {
                    onToggle?()
                } label: {
                    Image(systemName: checkboxIcon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(checkboxColor)
                        .frame(width: MovoSpace.minTouch, height: MovoSpace.minTouch, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(config.status == .done ? "标记未完成" : "标记完成")
            }

            VStack(alignment: .leading, spacing: MovoSpace.xs) {
                Text(config.title)
                    .font(MovoFont.bodyEmphasis)
                    .foregroundStyle(config.status == .done || config.status == .cancelled
                                     ? MovoColor.muted : MovoColor.ink)
                    .strikethrough(config.status == .done, color: MovoColor.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: MovoSpace.xs) {
                    if let planName = config.planName {
                        MovoTag(planName, systemImage: "folder")
                    }
                    if let category = config.category {
                        PlanCategoryTag(category, compact: true)
                    }
                    if let timeText = config.timeText {
                        MovoTag(timeText, systemImage: "clock")
                    }
                    if let dependencyText = config.dependencyText {
                        MovoTag(dependencyText, systemImage: "arrow.triangle.branch")
                    }
                }

                if let footnote = config.footnote, config.status != .done {
                    Text(footnote).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if config.status == .done {
                StatusTag(text: "已完成", foreground: MovoColor.done,
                          background: MovoColor.tint, systemImage: "checkmark.circle.fill")
            } else if config.status == .blocked {
                StatusTag(text: "受阻", foreground: MovoColor.warning,
                          background: MovoColor.soft, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .padding(.vertical, MovoSpace.s)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    private var checkboxIcon: String {
        switch config.status {
        case .done: "checkmark.circle.fill"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "circle.dashed"
        case .cancelled: "xmark.circle"
        case .todo: "circle"
        }
    }

    private var checkboxColor: Color {
        switch config.status {
        case .done: MovoColor.done
        case .inProgress: MovoColor.inProgress
        case .blocked: MovoColor.warning
        case .cancelled: MovoColor.inactive
        case .todo: MovoColor.muted
        }
    }
}

// MARK: - 计划行

public struct PlanRow: View {
    private let summary: PlanSummary
    private let onTap: (() -> Void)?

    public init(_ summary: PlanSummary, onTap: (() -> Void)? = nil) {
        self.summary = summary; self.onTap = onTap
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
                Text(summary.name).font(MovoFont.headline).foregroundStyle(MovoColor.ink)
                PlanCategoryTag(summary.category)
                if summary.status != .active {
                    StatusTag(planStatus: summary.status)
                }
                Spacer(minLength: 0)
            }

            if let goal = summary.goalText, !goal.isEmpty {
                Text(goal).font(MovoFont.body).foregroundStyle(MovoColor.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: MovoSpace.m) {
                Text(summary.progress.shortText)
                    .font(MovoFont.captionEmphasis)
                    .foregroundStyle(MovoColor.ink)
                if let stage = summary.currentStageName {
                    MovoTag(stage, systemImage: "flag")
                }
                if let target = summary.targetDateText {
                    MovoTag(target, systemImage: "calendar")
                }
            }

            if summary.progress.showsPercentage {
                MovoProgressBar(fraction: summary.progress.fraction,
                                caption: summary.progress.snapshotText)
            }

            if let next = summary.nextActionText {
                Text("下一步：\(next)")
                    .font(MovoFont.caption).foregroundStyle(MovoColor.primary)
            }
        }
        .padding(.vertical, MovoSpace.s)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

// MARK: - 执行树节点

public struct StageTreeNodeRow: View {
    private let node: PlanTreeNode
    private let depth: Int
    private let isExpanded: Bool
    private let isSelected: Bool
    private let onToggleExpand: (() -> Void)?
    private let onTap: (() -> Void)?

    public init(node: PlanTreeNode, depth: Int, isExpanded: Bool, isSelected: Bool = false,
                onToggleExpand: (() -> Void)? = nil, onTap: (() -> Void)? = nil) {
        self.node = node; self.depth = depth; self.isExpanded = isExpanded
        self.isSelected = isSelected; self.onToggleExpand = onToggleExpand; self.onTap = onTap
    }

    public var body: some View {
        HStack(alignment: .center, spacing: MovoSpace.s) {
            // 连接线 + 缩进
            HStack(spacing: 0) {
                ForEach(0..<min(max(depth, 0), 4), id: \.self) { _ in
                    Rectangle().fill(MovoColor.line).frame(width: 1).padding(.leading, MovoSpace.m)
                }
            }
            .frame(height: 22)

            if hasChildren {
                Button { onToggleExpand?() } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MovoColor.muted)
                        .frame(width: 20, height: MovoSpace.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "折叠" : "展开")
            } else {
                Color.clear.frame(width: 20, height: 1)
            }

            Image(systemName: kindIcon).font(.system(size: 13)).foregroundStyle(kindColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(node.isCancelled ? MovoFont.body : MovoFont.bodyEmphasis)
                    .foregroundStyle(node.isCancelled ? MovoColor.muted : MovoColor.ink)
                    .strikethrough(node.isCancelled, color: MovoColor.muted)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
            }

            Spacer(minLength: MovoSpace.s)

            if !node.dependency.isReady {
                MovoTag(node.dependency.badgeText, systemImage: "arrow.triangle.branch")
            }
            if let statusTag { StatusTag(taskStatus: statusTag) }

            if node.hiddenChildCount > 0 {
                MovoTag("+\(node.hiddenChildCount)")
            }

            if case .stage(_, let done, let total) = node.kind, total > 0 {
                MovoSegmentedProgressBar(
                    segments: [StageProgressSegment(name: title, done: done, total: total)],
                    totalDone: done,
                    totalCount: total,
                    isCompact: true
                )
                .frame(width: 48)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, MovoSpace.s)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? MovoColor.tint : .clear))
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    private var hasChildren: Bool { !node.children.isEmpty }

    private var title: String {
        switch node.kind {
        case .stage(let stage, _, _): stage.name
        case .task(let task): task.title
        case .group(let title, _, _, _): title
        }
    }

    private var subtitle: String? {
        if let progress = node.childProgress { return "子任务 \(progress.done)/\(progress.total)" }
        return switch node.kind {
        case .stage(_, let done, let total): "已完成 \(done)/\(total)"
        case .group(_, let done, let total, _): "\(done)/\(total)"
        case .task:
            node.historicalOccurrenceCount > 0 ? "另有 \(node.historicalOccurrenceCount) 次历史记录" : nil
        }
    }

    private var statusTag: TaskStatus? {
        if let progress = node.childProgress {
            return progress.total > 0 && progress.done == progress.total ? .done : .inProgress
        }
        if case .task(let task) = node.kind, task.status != .todo { return task.status }
        return nil
    }

    private var kindIcon: String {
        switch node.kind {
        case .stage: "flag"
        case .group: "square.stack.3d.up"
        case .task(let task): task.isTemplate ? "arrow.triangle.2.circlepath" : "circle"
        }
    }

    private var kindColor: Color {
        switch node.kind {
        case .stage: MovoColor.primary
        case .group: MovoColor.muted
        case .task(let task): task.status == .done ? MovoColor.done : MovoColor.muted
        }
    }
}

// MARK: - 重复行动行

public struct OccurrenceRow: View {
    private let occurrence: RecurrenceOccurrence
    private let taskTitle: String
    private let periodText: String?
    private let onToggle: (() -> Void)?
    private let onSkip: (() -> Void)?

    public init(occurrence: RecurrenceOccurrence, taskTitle: String, periodText: String? = nil,
                onToggle: (() -> Void)? = nil, onSkip: (() -> Void)? = nil) {
        self.occurrence = occurrence; self.taskTitle = taskTitle
        self.periodText = periodText; self.onToggle = onToggle; self.onSkip = onSkip
    }

    public var body: some View {
        HStack(spacing: MovoSpace.s) {
            Button { onToggle?() } label: {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: MovoSpace.minTouch, height: MovoSpace.minTouch, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(occurrence.status == .done ? "取消这次完成" : "完成这一次")

            VStack(alignment: .leading, spacing: 2) {
                Text(taskTitle).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                HStack(spacing: MovoSpace.xs) {
                    if let scheduled = occurrence.scheduledOn {
                        MovoTag(scheduled.displayString, systemImage: "calendar")
                    }
                    if let periodText { MovoTag(periodText, systemImage: "repeat") }
                }
            }

            Spacer(minLength: MovoSpace.s)

            StatusTag(text: occurrence.status.displayName,
                      foreground: statusColor, background: MovoColor.soft)

            if occurrence.status == .pending, let onSkip {
                Menu {
                    Button("跳过这一次", action: onSkip)
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(MovoColor.muted)
                        .frame(width: MovoSpace.minTouch, height: MovoSpace.minTouch)
                }
                .menuStyle(.borderlessButton)
                .frame(width: MovoSpace.minTouch)
            }
        }
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch occurrence.status {
        case .done: "checkmark.circle.fill"
        case .skipped: "arrow.uturn.forward.circle"
        case .pending: "circle"
        }
    }

    private var color: Color {
        switch occurrence.status {
        case .done: MovoColor.done
        case .skipped: MovoColor.inactive
        case .pending: MovoColor.muted
        }
    }

    private var statusColor: Color {
        switch occurrence.status {
        case .done: MovoColor.done
        case .skipped: MovoColor.inactive
        case .pending: MovoColor.todo
        }
    }
}

// MARK: - 结果记录行

public struct MetricRecordRow: View {
    private let point: MetricPoint
    private let metricName: String
    private let unit: String
    private let onCorrect: (() -> Void)?

    public init(point: MetricPoint, metricName: String, unit: String,
                onCorrect: (() -> Void)? = nil) {
        self.point = point; self.metricName = metricName; self.unit = unit; self.onCorrect = onCorrect
    }

    public var body: some View {
        HStack(spacing: MovoSpace.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(point.date.displayString).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                HStack(spacing: MovoSpace.xs) {
                    Text(valueText).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                    Text(PlanMetric.unitDisplayName(for: unit))
                        .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
            }
            Spacer(minLength: MovoSpace.s)
            if point.isRevised {
                MovoTag("已更正", systemImage: "pencil")
            }
            if let onCorrect {
                MovoIconButton("pencil", label: "更正这条记录", action: onCorrect)
            }
        }
        .padding(.vertical, 6)
    }

    private var valueText: String {
        if point.value == point.value.rounded() {
            return String(format: "%.0f", point.value)
        }
        return String(format: "%.1f", point.value)
    }
}

// MARK: - 行动记录行

public struct ActionRecordRow: View {
    private let entry: TimelineEntry
    private let planName: String?

    public init(_ entry: TimelineEntry, planName: String? = nil) {
        self.entry = entry; self.planName = planName
    }

    public var body: some View {
        HStack(alignment: .top, spacing: MovoSpace.s) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: MovoSpace.xs) {
                Text(entry.title).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: MovoSpace.xs) {
                    MovoTag(entry.kind.displayName)
                    if let planName { MovoTag(planName, systemImage: "folder") }
                    MovoTag(timeText, systemImage: "clock")
                }

                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason = entry.userReason, !reason.isEmpty {
                    Text("原因：\(reason)").font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
                if let old = entry.oldValue, let new = entry.newValue {
                    Text("\(old) → \(new)").font(MovoFont.caption).foregroundStyle(MovoColor.warning)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch entry.kind {
        case .completed: "checkmark.circle"
        case .record: "timer"
        case .adjustment, .recurrenceChanged, .goalChanged: "arrow.triangle.2.circlepath"
        case .skipped: "arrow.uturn.forward"
        case .paused: "pause.circle"
        case .resumed: "play.circle"
        case .cancelled: "xmark.circle"
        case .reopened: "arrow.counterclockwise.circle"
        case .measurementCorrected: "pencil.circle"
        case .aiUndone: "arrow.uturn.backward.circle"
        case .created: "plus.circle"
        case .structural: "square.stack.3d.up"
        case .deleted: "trash"
        case .restored: "arrow.uturn.up.circle"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .completed: MovoColor.done
        case .record: MovoColor.primary
        case .adjustment, .recurrenceChanged, .goalChanged: MovoColor.warning
        case .cancelled, .skipped: MovoColor.inactive
        case .aiUndone: MovoColor.danger
        default: MovoColor.muted
        }
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.dateFormat = entry.hasPreciseTime ? "M月d日 HH:mm" : "M月d日"
        return formatter.string(from: entry.occurredAt)
    }
}

// MARK: - 建议卡 / 待确认

public struct SuggestionCard: View {
    private let title: String
    private let reason: String?
    private let lines: [ImpactPreview.ImpactLine]
    private let sourceText: String?
    private let primaryTitle: String
    private let onPrimary: () -> Void
    private let onDismiss: (() -> Void)?

    public init(title: String, reason: String? = nil, lines: [ImpactPreview.ImpactLine] = [],
                sourceText: String? = nil, primaryTitle: String = "采纳",
                onPrimary: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.title = title; self.reason = reason; self.lines = lines
        self.sourceText = sourceText; self.primaryTitle = primaryTitle
        self.onPrimary = onPrimary; self.onDismiss = onDismiss
    }

    public var body: some View {
        MovoCard {
            VStack(alignment: .leading, spacing: MovoSpace.s) {
                HStack(spacing: MovoSpace.s) {
                    Image(systemName: "sparkles").foregroundStyle(MovoColor.primary)
                    Text(title).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                }
                if !lines.isEmpty {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        HStack(spacing: MovoSpace.xs) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 11)).foregroundStyle(MovoColor.muted)
                            Text(line.title).font(MovoFont.body).foregroundStyle(MovoColor.ink)
                            Text(line.changeText).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        }
                    }
                }
                if let sourceText, !sourceText.isEmpty {
                    Text("原文：\(sourceText)").font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason, !reason.isEmpty {
                    Text(reason).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
                HStack(spacing: MovoSpace.s) {
                    MovoButton(primaryTitle, kind: .primary, action: onPrimary)
                    if let onDismiss {
                        MovoButton("暂不处理", kind: .quiet, action: onDismiss)
                    }
                }
            }
        }
    }
}

// MARK: - 可撤销提示

public struct UndoBar: View {
    private let message: String
    private let undoTitle: String
    private let onUndo: () -> Void
    private let onDismiss: (() -> Void)?

    public init(message: String, undoTitle: String = "撤销",
                onUndo: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.message = message; self.undoTitle = undoTitle
        self.onUndo = onUndo; self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: MovoSpace.m) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(MovoColor.onPrimary)
            Text(message).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.onPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: MovoSpace.s)
            Button(undoTitle, action: onUndo)
                .font(MovoFont.bodyEmphasis)
                .foregroundStyle(MovoColor.onPrimary)
                .underline()
                .buttonStyle(.plain)
            if let onDismiss {
                MovoIconButton("xmark", label: "关闭提示", tint: MovoColor.onPrimary, action: onDismiss)
            }
        }
        .padding(.horizontal, MovoSpace.m)
        .padding(.vertical, MovoSpace.s)
        .frame(minHeight: MovoSpace.minTouch)
        .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
            .fill(MovoColor.primary))
        .movoOverlayShadow()
        .padding(.horizontal, MovoSpace.m)
    }
}
