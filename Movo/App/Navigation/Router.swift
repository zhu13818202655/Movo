//
//  Router.swift
//  App/Navigation
//
//  统一跳转状态。iOS 用 NavigationStack(path:)，Mac 用侧边导航 + 主区 + 详情面板；
//  页面通过 @Environment(\.movoRouter) 访问，与平台无关。
//

import SwiftUI
import Observation

@Observable
public final class Router: @unchecked Sendable {
    /// 每个顶部入口一份导航栈（iPhone 底部标签互不干扰）
    public var paths: [AppSection: [Route]] = [:]
    /// 当前顶部入口
    public var section: AppSection = .today
    /// Mac 右侧详情面板
    public var inspector: Route?
    /// 浮层（快速输入 / 录音 / 设置子页）
    public var sheet: Route?

    public init() {}

    // MARK: - 路径

    public func path(for section: AppSection) -> [Route] { paths[section] ?? [] }

    public func setPath(_ path: [Route], for section: AppSection) { paths[section] = path }

    public func binding(for section: AppSection) -> Binding<[Route]> {
        Binding(get: { self.path(for: section) },
                set: { self.setPath($0, for: section) })
    }

    /// macOS 主区栈（跟随当前入口）
    public var sectionPathBinding: Binding<[Route]> { binding(for: section) }

    // MARK: - 操作

    // 关闭当前页面的规则（避免同类 bug 复发）：
    //   页面「关闭 / 取消 / 完成」一律用 SwiftUI 的 `@Environment(\.dismiss)`——
    //   它既能弹出导航栈，也能关闭浮层，页面不需要知道自己是怎么被呈现的。
    //   `pop()` 只改 `paths`，`dismissSheet()` 只清 `sheet`；如果页面实际由另一种
    //   方式呈现，这两个调用会静默失效（按钮看起来「点了没反应」）。
    //   它们只在明确知道当前呈现方式时使用，例如由 Router 主动切换的采集流水线。

    public func push(_ route: Route) {
        sheet = nil
        paths[section, default: []].append(route)
    }

    public func pop() {
        guard var stack = paths[section], !stack.isEmpty else { return }
        stack.removeLast()
        paths[section] = stack
    }

    public func popToRoot() { paths[section] = [] }

    public func select(_ section: AppSection) {
        #if os(iOS)
        if !AppSection.phoneOrder.contains(section) {
            sheet = nil
            inspector = nil
            paths[self.section, default: []].append(.section(section))
            return
        }
        #endif
        self.section = section
        paths[section] = []
        inspector = nil
    }

    public func present(_ route: Route) { sheet = route }

    public func dismissSheet() { sheet = nil }

    public func inspect(_ route: Route) { inspector = route }

    public func clearInspector() { inspector = nil }

    /// 深链：先切入口再压栈
    public func go(to route: Route, in section: AppSection) {
        #if os(iOS)
        if !AppSection.phoneOrder.contains(section) {
            select(.today)
            push(route)
            return
        }
        #endif
        select(section)
        paths[section, default: []].append(route)
    }
}

private struct RouterKey: EnvironmentKey {
    static let defaultValue = Router()
}

public extension EnvironmentValues {
    var movoRouter: Router {
        get { self[RouterKey.self] }
        set { self[RouterKey.self] = newValue }
    }
}
