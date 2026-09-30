//
//  FormControls.swift
//  Features/Shared
//
//  表单行与字段控件：新建/编辑计划、补记结果、频率编辑共用。
//  日期与硬截止分别编辑（AC02）；输入框含聚焦与错误状态。
//

import SwiftUI
import MovoKit

// MARK: - 表单分区

public struct MovoFormSection<Content: View>: View {
    private let title: String
    private let footnote: String?
    private let content: Content

    public init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footnote = footnote; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            if !title.isEmpty { MovoSectionHeader(title) }
            VStack(alignment: .leading, spacing: MovoSpace.m) { content }
                .padding(MovoSpace.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: MovoRadius.card, style: .continuous)
                    .fill(MovoColor.surface))
                .overlay(RoundedRectangle(cornerRadius: MovoRadius.card, style: .continuous)
                    .strokeBorder(MovoColor.line, lineWidth: 1))
            if let footnote {
                Text(footnote).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 表单行

public struct MovoFormRow<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let content: Content

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
                Text(title).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                if let subtitle {
                    Spacer(minLength: MovoSpace.s)
                    Text(subtitle).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
            }
            content
        }
    }
}

/// 只读信息行（详情页展示）
public struct MovoInfoRow: View {
    private let title: String
    private let value: String
    private let systemImage: String?

    public init(_ title: String, value: String, systemImage: String? = nil) {
        self.title = title; self.value = value; self.systemImage = systemImage
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(MovoColor.muted)
            }
            Text(title).font(MovoFont.body).foregroundStyle(MovoColor.muted)
            Spacer(minLength: MovoSpace.s)
            Text(value).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 28)
    }
}

// MARK: - 日期字段（可开关）

/// 可开关的日期字段。DateOnly ↔ Date 的换算固定走注入的时区（AC02）。
public struct MovoDateField: View {
    private let title: String
    private let placeholder: String
    @Binding private var isOn: Bool
    @Binding private var date: Date
    private let timeZone: TimeZone

    public init(_ title: String, placeholder: String = "未设置",
                isOn: Binding<Bool>, date: Binding<Date>, timeZone: TimeZone) {
        self.title = title; self.placeholder = placeholder
        self._isOn = isOn; self._date = date; self.timeZone = timeZone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            Toggle(isOn: $isOn) {
                Text(title).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if isOn {
                DatePicker("", selection: $date, displayedComponents: [.date])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .environment(\.timeZone, timeZone)
                    .accessibilityLabel(title)
            } else {
                Text(placeholder).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
        }
    }
}

// MARK: - 单选标签行

public struct MovoChipRow<Value: Hashable & Identifiable>: View {
    private let options: [Value]
    private let label: (Value) -> String
    @Binding private var selection: Value?

    public init(options: [Value], selection: Binding<Value?>, label: @escaping (Value) -> String) {
        self.options = options; self._selection = selection; self.label = label
    }

    public var body: some View {
        HStack(spacing: MovoSpace.s) {
            TransparentFilterChip(title: "未选择", isSelected: selection == nil) { selection = nil }
            ForEach(options) { option in
                TransparentFilterChip(title: label(option), isSelected: selection == option) {
                    selection = option
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 必选标签行（计划类型）
public struct MovoRequiredChipRow<Value: Hashable & Identifiable>: View {
    private let options: [Value]
    private let label: (Value) -> String
    @Binding private var selection: Value

    public init(options: [Value], selection: Binding<Value>, label: @escaping (Value) -> String) {
        self.options = options; self._selection = selection; self.label = label
    }

    public var body: some View {
        HStack(spacing: MovoSpace.s) {
            ForEach(options) { option in
                TransparentFilterChip(title: label(option), isSelected: selection == option) {
                    selection = option
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 数值输入

public struct MovoNumberField: View {
    private let title: String
    private let placeholder: String
    @Binding private var text: String
    private let unitText: String?
    private let errorMessage: String?

    public init(_ title: String, text: Binding<String>, placeholder: String = "",
                unitText: String? = nil, errorMessage: String? = nil) {
        self.title = title; self._text = text; self.placeholder = placeholder
        self.unitText = unitText; self.errorMessage = errorMessage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.xs) {
            Text(title).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            HStack(spacing: MovoSpace.s) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(MovoFont.mono)
                    .foregroundStyle(MovoColor.ink)
                    .padding(MovoSpace.s)
                    .frame(minHeight: MovoSpace.minTouch)
                    .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                        .fill(MovoColor.surface))
                    .overlay(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                        .strokeBorder(errorMessage == nil ? MovoColor.line : MovoColor.danger, lineWidth: 1))
                if let unitText {
                    Text(unitText).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.muted)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(MovoFont.caption).foregroundStyle(MovoColor.danger)
            }
        }
    }
}

// MARK: - 列表编辑（阶段 / 结果指标）

public struct MovoEditableListRow: View {
    private let title: String
    private let subtitle: String?
    private let onDelete: (() -> Void)?

    public init(title: String, subtitle: String? = nil, onDelete: (() -> Void)? = nil) {
        self.title = title; self.subtitle = subtitle; self.onDelete = onDelete
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                if let subtitle {
                    Text(subtitle).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
            }
            Spacer(minLength: MovoSpace.s)
            if let onDelete {
                MovoIconButton("minus.circle", label: "移除", tint: MovoColor.danger, action: onDelete)
            }
        }
        .frame(minHeight: 32)
    }
}

// MARK: - 底部动作条

public struct MovoActionBar: View {
    private let content: AnyView

    public init<Content: View>(@ViewBuilder content: () -> Content) {
        self.content = AnyView(content())
    }

    public var body: some View {
        HStack(spacing: MovoSpace.s) { content }
            .padding(.horizontal, MovoSpace.pageMargin)
            .padding(.vertical, MovoSpace.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MovoColor.bg)
            .overlay(alignment: .top) { MovoDivider() }
    }
}

// MARK: - DateOnly ↔ Date 工具

public extension DateOnly {
    /// 用于 DatePicker 的绑定基准（当天正午，避免夏令时边界偏移）
    var pickerDate: Date { noon }

    static func fromPicker(_ date: Date, in tz: TimeZone) -> DateOnly {
        DateOnly(from: date, in: tz)
    }
}
