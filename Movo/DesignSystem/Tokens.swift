//
//  Tokens.swift
//  DesignSystem
//
//  设计令牌。颜色取值来自 docs/design/Movo.pen 的 variables（light/dark 双模），
//  排版/间距/圆角来自 docs/UI-Prompt.md「视觉方向」。
//  本文件只用 SwiftUI 绘制，不依赖 UIKit/AppKit 业务类型。
//

import SwiftUI

// MARK: - Hex 解析

enum HexColor {
    static func components(_ hex: String) -> (Double, Double, Double) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return (0, 0, 0) }
        return (Double((value >> 16) & 0xFF) / 255.0,
                Double((value >> 8) & 0xFF) / 255.0,
                Double(value & 0xFF) / 255.0)
    }
}

// MARK: - 自适应颜色

public extension Color {
    /// 按 light/dark 双模构造自适应颜色（与 Movo.pen 的 variables 对齐）。
    static func movoAdaptive(light: String, dark: String) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(movoHex: dark) : UIColor(movoHex: light)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(movoHex: dark) : NSColor(movoHex: light)
        })
        #else
        return Color(red: HexColor.components(light).0,
                     green: HexColor.components(light).1,
                     blue: HexColor.components(light).2)
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(movoHex hex: String) {
        let (r, g, b) = HexColor.components(hex)
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
#elseif canImport(AppKit)
extension NSColor {
    convenience init(movoHex hex: String) {
        let (r, g, b) = HexColor.components(hex)
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
#endif

// MARK: - 颜色令牌

public enum MovoColor {
    /// 页面背景 #F7F8F5 / #141C17
    public static let bg = Color.movoAdaptive(light: "#F7F8F5", dark: "#141C17")
    /// 主要内容表面 #FFFFFF / #1D2822
    public static let surface = Color.movoAdaptive(light: "#FFFFFF", dark: "#1D2822")
    /// 辅助表面 #EEF2ED / #24332A
    public static let soft = Color.movoAdaptive(light: "#EEF2ED", dark: "#24332A")
    /// 主色 #247367 / #8ED1BC
    public static let primary = Color.movoAdaptive(light: "#247367", dark: "#8ED1BC")
    /// 浅主色 #E7F2EE / #244439
    public static let tint = Color.movoAdaptive(light: "#E7F2EE", dark: "#244439")
    /// 正文 #202723 / #EEF4EF
    public static let ink = Color.movoAdaptive(light: "#202723", dark: "#EEF4EF")
    /// 次级文字 #65706B / #B2BFB6
    public static let muted = Color.movoAdaptive(light: "#65706B", dark: "#B2BFB6")
    /// 分隔线 #E1E6E1 / #35443C
    public static let line = Color.movoAdaptive(light: "#E1E6E1", dark: "#35443C")
    /// 主色上的文字 #FFFFFF / #142B22
    public static let onPrimary = Color.movoAdaptive(light: "#FFFFFF", dark: "#142B22")

    // MARK: 状态色（语义固定，不靠颜色单独表意，始终配文字）

    /// 已完成
    public static let done = Color.movoAdaptive(light: "#247367", dark: "#8ED1BC")
    /// 进行中
    public static let inProgress = Color.movoAdaptive(light: "#2F6FB0", dark: "#8FB8E0")
    /// 待办
    public static let todo = Color.movoAdaptive(light: "#65706B", dark: "#B2BFB6")
    /// 已取消 / 已暂停
    public static let inactive = Color.movoAdaptive(light: "#8A938E", dark: "#7C8A82")
    /// 受阻 / 警告
    public static let warning = Color.movoAdaptive(light: "#A96A22", dark: "#E0B98F")
    /// 危险 / 冲突
    public static let danger = Color.movoAdaptive(light: "#B4553F", dark: "#E0A092")
}

// MARK: - 分类色（柔和蓝 / 橙 / 绿 / 珊瑚；始终配文字）

public enum MovoCategoryColor {
    public static func color(for category: PlanCategory?) -> Color {
        switch category {
        case .work: Color.movoAdaptive(light: "#2F6FB0", dark: "#8FB8E0")
        case .study: Color.movoAdaptive(light: "#A96A22", dark: "#E0B98F")
        case .health: Color.movoAdaptive(light: "#247367", dark: "#8ED1BC")
        case .life: Color.movoAdaptive(light: "#B4553F", dark: "#E0A092")
        case nil: MovoColor.muted
        }
    }

    public static func background(for category: PlanCategory?) -> Color {
        switch category {
        case .work: Color.movoAdaptive(light: "#E8F0FB", dark: "#22303F")
        case .study: Color.movoAdaptive(light: "#FBF0E4", dark: "#3A2F22")
        case .health: Color.movoAdaptive(light: "#E7F2EE", dark: "#244439")
        case .life: Color.movoAdaptive(light: "#FBE9E7", dark: "#3A2622")
        case nil: MovoColor.soft
        }
    }
}

// MARK: - 间距 / 圆角

public enum MovoSpace {
    /// 8 为基础间距
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32

    /// 页面左右边距：Mac 20 / iPhone 20
    public static let pageMargin: CGFloat = 20
    /// 触控区最小尺寸（iPhone 44×44）
    public static let minTouch: CGFloat = 44
}

public enum MovoRadius {
    /// 按钮圆角约 12
    public static let button: CGFloat = 12
    /// 卡片约 16
    public static let card: CGFloat = 16
    public static let tag: CGFloat = 8
    public static let sheet: CGFloat = 20
}

// MARK: - 排版

public enum MovoFont {
    #if os(macOS)
    public static let bodySize: CGFloat = 15
    public static let bodyLargeSize: CGFloat = 16
    #else
    public static let bodySize: CGFloat = 17
    public static let bodyLargeSize: CGFloat = 17
    #endif

    /// 主要标题 26–30
    public static let title = Font.system(size: 28, weight: .semibold, design: .default)
    public static let title2 = Font.system(size: 22, weight: .semibold)
    public static let headline = Font.system(size: bodyLargeSize, weight: .semibold)
    public static let body = Font.system(size: bodySize, weight: .regular)
    public static let bodyEmphasis = Font.system(size: bodySize, weight: .medium)
    /// 次级说明不低于 13，避免小字承载主要信息
    public static let caption = Font.system(size: 13, weight: .regular)
    public static let captionEmphasis = Font.system(size: 13, weight: .medium)
    public static let mono = Font.system(size: 13, weight: .medium, design: .monospaced)
}

// MARK: - 阴影（仅用于浮层等需要表达层级的区域）

public enum MovoShadow {
    public static func overlay<V: View>(_ view: V) -> some View {
        view.shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 8)
    }
}

// MARK: - 语义助手

public extension MovoColor {
    /// 状态标签前景色
    static func statusForeground(_ status: TaskStatus) -> Color {
        switch status {
        case .done: done
        case .inProgress: inProgress
        case .blocked: warning
        case .todo: todo
        case .cancelled: inactive
        }
    }

    static func statusBackground(_ status: TaskStatus) -> Color {
        switch status {
        case .inProgress: Color.movoAdaptive(light: "#E8F0FB", dark: "#22303F")
        case .blocked: Color.movoAdaptive(light: "#FBF0E4", dark: "#3A2F22")
        default: soft
        }
    }

    /// 计划状态前景色
    static func planStatusForeground(_ status: PlanStatus) -> Color {
        switch status {
        case .active: done
        case .paused: warning
        case .archived: inactive
        }
    }

    /// 阶段状态前景色
    static func stageStatusForeground(_ status: StageStatus) -> Color {
        switch status {
        case .achieved: done
        case .inProgress: inProgress
        case .awaitingConfirm: warning
        case .notStarted: todo
        case .paused: warning
        case .cancelled: inactive
        }
    }
}
