//
//  Scaffold.swift
//  Features/Shared
//
//  页面骨架与共用片段：标题区、分区容器、可折叠分区、输入入口、加载占位。
//

import SwiftUI
import MovoKit

// MARK: - 页面标题区

public struct ScreenChrome<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    public init(_ title: String, subtitle: String? = nil,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: MovoSpace.xs) {
                Text(title).font(MovoFont.title).foregroundStyle(MovoColor.ink)
                if let subtitle {
                    Text(subtitle).font(MovoFont.body).foregroundStyle(MovoColor.muted)
                }
            }
            Spacer(minLength: MovoSpace.m)
            trailing
        }
        .padding(.horizontal, MovoSpace.pageMargin)
        .padding(.top, MovoSpace.l)
        .padding(.bottom, MovoSpace.s)
    }
}

public extension ScreenChrome where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - 分区

public struct SectionBlock<Content: View>: View {
    private let title: String
    private let trailing: String?
    private let content: Content

    public init(_ title: String, trailing: String? = nil,
                @ViewBuilder content: () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            MovoSectionHeader(title, trailing: trailing)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: MovoRadius.card, style: .continuous)
                    .fill(MovoColor.surface))
                .overlay(RoundedRectangle(cornerRadius: MovoRadius.card, style: .continuous)
                    .strokeBorder(MovoColor.line, lineWidth: 1))
        }
    }
}

/// 可折叠分区（已完成 / 阶段检查点 / 历史记录）
public struct CollapsibleSection<Content: View>: View {
    private let title: String
    private let trailing: String?
    @Binding private var isExpanded: Bool
    private let content: Content

    public init(_ title: String, trailing: String? = nil,
                isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title; self.trailing = trailing
        self._isExpanded = isExpanded; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: MovoSpace.s) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MovoColor.muted)
                    Text(title).font(MovoFont.headline).foregroundStyle(MovoColor.ink)
                    Spacer(minLength: MovoSpace.s)
                    if let trailing {
                        Text(trailing).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                    }
                }
                .frame(minHeight: MovoSpace.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)，\(isExpanded ? "已展开" : "已折叠")")

            if isExpanded { content }
        }
    }
}

// MARK: - 输入入口（D01 / M01 / M14）

public struct QuickCaptureEntry: View {
    private let onText: () -> Void
    private let onVoice: () -> Void

    public init(onText: @escaping () -> Void, onVoice: @escaping () -> Void) {
        self.onText = onText; self.onVoice = onVoice
    }

    public var body: some View {
        HStack(spacing: MovoSpace.s) {
            Button(action: onText) {
                HStack(spacing: MovoSpace.s) {
                    Image(systemName: "square.and.pencil").foregroundStyle(MovoColor.muted)
                    Text("记下一件事，或说说你的计划")
                        .font(MovoFont.body)
                        .foregroundStyle(MovoColor.muted)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: MovoSpace.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onVoice) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MovoColor.onPrimary)
                    .frame(width: MovoSpace.minTouch, height: MovoSpace.minTouch)
                    .background(Circle().fill(MovoColor.primary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("语音记下一件事")
        }
        .padding(.horizontal, MovoSpace.s)
        .background(RoundedRectangle(cornerRadius: MovoRadius.card, style: .continuous)
            .fill(MovoColor.surface))
        .overlay(RoundedRectangle(cornerRadius: MovoRadius.card, style: .continuous)
            .strokeBorder(MovoColor.line, lineWidth: 1))
    }
}

// MARK: - 加载占位

public struct LoadingPlaceholder: View {
    private let text: String
    public init(_ text: String = "正在读取…") { self.text = text }

    public var body: some View {
        VStack(spacing: MovoSpace.s) {
            ProgressView()
            Text(text).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 页面滚动容器

public struct ScreenScroll<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MovoSpace.l) { content }
                .padding(.horizontal, MovoSpace.pageMargin)
                .padding(.bottom, MovoSpace.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .movoPageBackground()
    }
}
