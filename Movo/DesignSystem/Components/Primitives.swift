//
//  Primitives.swift
//  DesignSystem/Components
//
//  00 Foundations 组件库：按钮、输入框、标签、卡片、空状态、错误横幅、分段控件。
//  所有组件区分状态（完成/进行中/待归类/暂停），按钮含禁用与键盘焦点，
//  输入框含聚焦与错误状态（UI-Prompt「本轮画板 · 00 Foundations」）。
//

import SwiftUI

// MARK: - 按钮

public enum MovoButtonStyleKind: Sendable {
    case primary, secondary, quiet, destructive

    var background: Color {
        switch self {
        case .primary: MovoColor.primary
        case .secondary: MovoColor.soft
        case .quiet: .clear
        case .destructive: MovoColor.danger
        }
    }

    var foreground: Color {
        switch self {
        case .primary: MovoColor.onPrimary
        case .secondary: MovoColor.ink
        case .quiet: MovoColor.primary
        case .destructive: .white
        }
    }
}

public struct MovoButton: View {
    private let title: String
    private let systemImage: String?
    private let kind: MovoButtonStyleKind
    private let isEnabled: Bool
    private let isLoading: Bool
    private let action: () -> Void

    @FocusState private var isFocused: Bool

    public init(_ title: String, systemImage: String? = nil,
                kind: MovoButtonStyleKind = .primary,
                isEnabled: Bool = true, isLoading: Bool = false,
                action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.kind = kind
        self.isEnabled = isEnabled; self.isLoading = isLoading; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: MovoSpace.s) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(kind.foreground)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).font(MovoFont.bodyEmphasis)
            }
            .frame(minHeight: MovoSpace.minTouch)
            .padding(.horizontal, MovoSpace.m)
            .background(
                RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                    .fill(kind.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                    .strokeBorder(kind == .quiet ? MovoColor.line : .clear, lineWidth: 1)
            )
            .foregroundStyle(kind.foreground)
            .opacity(isEnabled ? 1 : 0.45)
            .overlay(
                RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                    .strokeBorder(MovoColor.primary, lineWidth: isFocused ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .focused($isFocused)
        .accessibilityLabel(title)
    }
}

/// 图标按钮（工具栏/行内操作，触控区 ≥44）
public struct MovoIconButton: View {
    private let systemImage: String
    private let label: String
    private let tint: Color
    private let action: () -> Void

    public init(_ systemImage: String, label: String, tint: Color = MovoColor.muted,
                action: @escaping () -> Void) {
        self.systemImage = systemImage; self.label = label; self.tint = tint; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: MovoSpace.minTouch, height: MovoSpace.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - 输入框

public struct MovoTextField: View {
    private let title: String
    private let placeholder: String
    @Binding private var text: String
    private let errorMessage: String?
    private let axis: Axis

    @FocusState private var isFocused: Bool

    public init(_ title: String, text: Binding<String>, placeholder: String = "",
                errorMessage: String? = nil, axis: Axis = .horizontal) {
        self.title = title; self._text = text; self.placeholder = placeholder
        self.errorMessage = errorMessage; self.axis = axis
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.xs) {
            if !title.isEmpty {
                Text(title).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
            Group {
                if axis == .vertical {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(2...6)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(MovoFont.body)
            .foregroundStyle(MovoColor.ink)
            .padding(MovoSpace.s)
            .frame(minHeight: MovoSpace.minTouch)
            .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                .fill(MovoColor.surface))
            .overlay(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused || errorMessage != nil ? 2 : 1))
            .focused($isFocused)

            if let errorMessage {
                Text(errorMessage).font(MovoFont.caption).foregroundStyle(MovoColor.danger)
            }
        }
    }

    private var borderColor: Color {
        if errorMessage != nil { return MovoColor.danger }
        return isFocused ? MovoColor.primary : MovoColor.line
    }
}

// MARK: - 标签

/// 计划分类标签（始终配文字；颜色与任务状态分开）
public struct PlanCategoryTag: View {
    private let category: PlanCategory?
    private let compact: Bool

    public init(_ category: PlanCategory?, compact: Bool = false) {
        self.category = category; self.compact = compact
    }

    public var body: some View {
        Text(category?.displayName ?? "未归类")
            .font(MovoFont.captionEmphasis)
            .padding(.horizontal, MovoSpace.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(MovoCategoryColor.background(for: category)))
            .foregroundStyle(MovoCategoryColor.color(for: category))
            .accessibilityLabel("分类：\(category?.displayName ?? "未归类")")
    }
}

/// 状态标签（完成 / 进行中 / 受阻 / 待办 / 已取消）——状态不只靠颜色表达
public struct StatusTag: View {
    private let text: String
    private let foreground: Color
    private let background: Color
    private let systemImage: String?

    public init(text: String, foreground: Color, background: Color, systemImage: String? = nil) {
        self.text = text; self.foreground = foreground; self.background = background
        self.systemImage = systemImage
    }

    public init(taskStatus: TaskStatus) {
        self.init(text: taskStatus.displayName,
                  foreground: MovoColor.statusForeground(taskStatus),
                  background: MovoColor.statusBackground(taskStatus),
                  systemImage: taskStatus == .done ? "checkmark.circle.fill" : nil)
    }

    public init(planStatus: PlanStatus) {
        self.init(text: planStatus.displayName,
                  foreground: MovoColor.planStatusForeground(planStatus),
                  background: MovoColor.soft,
                  systemImage: planStatus == .paused ? "pause.circle.fill" : nil)
    }

    public init(stageStatus: StageStatus) {
        self.init(text: stageStatus.displayName,
                  foreground: MovoColor.stageStatusForeground(stageStatus),
                  background: MovoColor.soft,
                  systemImage: stageStatus == .achieved ? "checkmark.seal.fill" : nil)
    }

    public var body: some View {
        HStack(spacing: MovoSpace.xs) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
            Text(text).font(MovoFont.captionEmphasis)
        }
        .padding(.horizontal, MovoSpace.s)
        .padding(.vertical, 3)
        .background(Capsule().fill(background))
        .foregroundStyle(foreground)
        .accessibilityLabel("状态：\(text)")
    }
}

/// 中性小标签（来源 / 时间 / 归属路径）
public struct MovoTag: View {
    private let text: String
    private let systemImage: String?

    public init(_ text: String, systemImage: String? = nil) {
        self.text = text; self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: MovoSpace.xs) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
            Text(text).font(MovoFont.caption)
        }
        .padding(.horizontal, MovoSpace.s)
        .padding(.vertical, 2)
        .background(Capsule().fill(MovoColor.soft))
        .foregroundStyle(MovoColor.muted)
    }
}

// MARK: - 容器

public struct MovoCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    public init(padding: CGFloat = MovoSpace.m, @ViewBuilder content: () -> Content) {
        self.padding = padding; self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: MovoRadius.card, style: .continuous)
                .fill(MovoColor.surface))
            .overlay(RoundedRectangle(cornerRadius: MovoRadius.card, style: .continuous)
                .strokeBorder(MovoColor.line, lineWidth: 1))
    }
}

public struct MovoSectionHeader: View {
    private let title: String
    private let trailing: String?

    public init(_ title: String, trailing: String? = nil) {
        self.title = title; self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(MovoFont.headline).foregroundStyle(MovoColor.ink)
            Spacer(minLength: MovoSpace.s)
            if let trailing {
                Text(trailing).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
        }
    }
}

public struct MovoDivider: View {
    public init() {}
    public var body: some View { Rectangle().fill(MovoColor.line).frame(height: 1) }
}

// MARK: - 空状态

public struct MovoEmptyState: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(systemImage: String, title: String, message: String,
                actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage; self.title = title; self.message = message
        self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
        VStack(spacing: MovoSpace.m) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(MovoColor.muted)
            Text(title).font(MovoFont.headline).foregroundStyle(MovoColor.ink)
            Text(message)
                .font(MovoFont.body).foregroundStyle(MovoColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                MovoButton(actionTitle, kind: .secondary, action: action)
            }
        }
        .frame(maxWidth: 420)
        .padding(MovoSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 错误横幅（无恢复入口的错误态不存在）

public struct MovoBanner: View {
    public enum Kind: Sendable { case info, warning, danger, success }

    private let kind: Kind
    private let title: String
    private let message: String
    private let actions: [(String, () -> Void)]

    public init(kind: Kind, title: String, message: String,
                actions: [(String, () -> Void)] = []) {
        self.kind = kind; self.title = title; self.message = message; self.actions = actions
    }

    /// 4.5：MovoError 统一渲染，附恢复动作按钮
    public init(error: MovoError, onAction: @escaping (RecoveryAction) -> Void) {
        self.kind = error.recoveryActions.contains(.dismiss) && error.recoveryActions.count == 1
            ? .info : .warning
        self.title = error.title
        self.message = error.message
        self.actions = error.recoveryActions.map { action in
            (action.label, { onAction(action) })
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            HStack(spacing: MovoSpace.s) {
                Image(systemName: icon).foregroundStyle(accent)
                Text(title).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
            }
            if !message.isEmpty {
                Text(message).font(MovoFont.body).foregroundStyle(MovoColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !actions.isEmpty {
                HStack(spacing: MovoSpace.s) {
                    ForEach(actions.indices, id: \.self) { index in
                        MovoButton(actions[index].0, kind: .quiet, action: actions[index].1)
                    }
                }
            }
        }
        .padding(MovoSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MovoRadius.card, style: .continuous)
            .fill(background))
        .overlay(RoundedRectangle(cornerRadius: MovoRadius.card, style: .continuous)
            .strokeBorder(accent.opacity(0.35), lineWidth: 1))
    }

    private var accent: Color {
        switch kind {
        case .info: MovoColor.inProgress
        case .warning: MovoColor.warning
        case .danger: MovoColor.danger
        case .success: MovoColor.done
        }
    }

    private var background: Color {
        switch kind {
        case .info: Color.movoAdaptive(light: "#E8F0FB", dark: "#22303F")
        case .warning: Color.movoAdaptive(light: "#FBF0E4", dark: "#3A2F22")
        case .danger: Color.movoAdaptive(light: "#FBE9E7", dark: "#3A2622")
        case .success: MovoColor.tint
        }
    }

    private var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "exclamationmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }
}

// MARK: - 分段控件（行动 / 记录 / 成果）

public struct MovoSegmented<Value: Hashable>: View {
    private let options: [(Value, String)]
    @Binding private var selection: Value

    public init(options: [(Value, String)], selection: Binding<Value>) {
        self.options = options; self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let (value, label) = options[index]
                let isSelected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(MovoFont.bodyEmphasis)
                        .foregroundStyle(isSelected ? MovoColor.onPrimary : MovoColor.muted)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(RoundedRectangle(cornerRadius: MovoRadius.button - 3, style: .continuous)
                            .fill(isSelected ? MovoColor.primary : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
            .fill(MovoColor.soft))
    }
}

// MARK: - 进度

/// 进度条（叶子任务 x/y）。不合成结果型计划的百分比。
public struct MovoProgressBar: View {
    private let fraction: Double
    private let caption: String?

    public init(fraction: Double, caption: String? = nil) {
        self.fraction = min(max(fraction, 0), 1); self.caption = caption
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.xs) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(MovoColor.soft)
                    Capsule().fill(MovoColor.primary)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            if let caption {
                Text(caption).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? "进度")
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}

// MARK: - 浮层容器

public struct MovoSheetHeader: View {
    private let title: String
    private let subtitle: String?
    private let onClose: (() -> Void)?

    public init(_ title: String, subtitle: String? = nil, onClose: (() -> Void)? = nil) {
        self.title = title; self.subtitle = subtitle; self.onClose = onClose
    }

    public var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: MovoSpace.xs) {
                Text(title).font(MovoFont.title2).foregroundStyle(MovoColor.ink)
                if let subtitle {
                    Text(subtitle).font(MovoFont.body).foregroundStyle(MovoColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: MovoSpace.s)
            if let onClose {
                MovoIconButton("xmark", label: "关闭", action: onClose)
            }
        }
    }
}

public struct MovoSheet<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.m) { content }
            .padding(MovoSpace.l)
            .background(RoundedRectangle(cornerRadius: MovoRadius.sheet, style: .continuous)
                .fill(MovoColor.surface))
            .overlay(RoundedRectangle(cornerRadius: MovoRadius.sheet, style: .continuous)
                .strokeBorder(MovoColor.line, lineWidth: 1))
            .movoOverlayShadow()
            .padding(MovoSpace.m)
    }
}

public extension View {
    func movoOverlayShadow() -> some View {
        shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 8)
    }

    /// 页面底色
    func movoPageBackground() -> some View {
        background(MovoColor.bg.ignoresSafeArea())
    }
}
