//
//  EstimateMinutesEditor.swift
//  Features/Shared
//
//  分钟输入的共用控件。取值规则与措辞在 `MovoKit` 的 `EstimateMinutes`，
//  这里只负责画出来。
//
//  同一套控件服务四处，保证样子与措辞一致：
//  预计投入（新建 / 就地编辑 / 任务详情）与行动记录的投入时长（计时结束 / 补记）。
//  后两处多了 `−` `+` 步进与快捷取值，用来填「这次坐了多久」这种短数字。
//

import SwiftUI
import MovoKit

/// 表单式的分钟输入：一行标签 + 数字输入 + 单位，可选步进按钮与快捷取值。
struct EstimateMinutesField: View {
    @Binding private var text: String
    private let title: String
    private let placeholder: String
    private let errorMessage: String?
    private let showsSteppers: Bool
    private let chips: [Int]

    init(_ title: String = "预计投入", text: Binding<String>,
         placeholder: String = "未设置", errorMessage: String? = nil,
         showsSteppers: Bool = false, chips: [Int] = []) {
        self.title = title
        self._text = text
        self.placeholder = placeholder
        self.errorMessage = errorMessage
        self.showsSteppers = showsSteppers
        self.chips = chips
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.xs) {
            Text(title).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            HStack(spacing: MovoSpace.s) {
                if showsSteppers { stepButton(-1) }
                field
                if showsSteppers { stepButton(1) }
                Text("分钟").font(MovoFont.caption).foregroundStyle(MovoColor.muted)
            }
            if !chips.isEmpty {
                MovoStepChips(values: chips, selected: EstimateMinutes.parse(text).value) { value in
                    text = String(value)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(MovoFont.caption).foregroundStyle(MovoColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 步进一次 5 分钟。空着按 0 起步，减到 0 就回到「未填」，
    /// 不把 0 写进输入框——0 在取值规则里不是合法值，留在框里只会立刻报错。
    private func step(_ direction: Int) {
        let current = EstimateMinutes.parse(text).value ?? 0
        let next = max(0, current + direction * 5)
        text = next == 0 ? "" : String(next)
    }

    private func stepButton(_ direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: direction > 0 ? "plus" : "minus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MovoColor.primary)
                .frame(width: MovoSpace.minTouch, height: MovoSpace.minTouch)
                .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                    .fill(MovoColor.soft))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction > 0 ? "增加 5 分钟" : "减少 5 分钟")
    }

    /// 宽度刻意收窄：分钟数是短数字，占满整行会读成「要写长文」。
    private static let fieldWidth: CGFloat = 120

    @ViewBuilder
    private var field: some View {
        let base = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(MovoFont.body)
            .foregroundStyle(MovoColor.ink)
            .padding(MovoSpace.s)
            .frame(minHeight: MovoSpace.minTouch)
            .frame(maxWidth: Self.fieldWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                .fill(MovoColor.surface))
            .overlay(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                .strokeBorder(errorMessage == nil ? MovoColor.line : MovoColor.danger,
                              lineWidth: errorMessage == nil ? 1 : 2))
            .accessibilityLabel("\(title)，单位分钟")
        #if os(iOS)
        base.keyboardType(.numberPad)
        #else
        base
        #endif
    }
}
