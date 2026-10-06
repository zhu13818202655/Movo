//
//  RootView.swift
//  App/Navigation
//
//  双端外壳：
//  · iPhone 393×852：单列 + 底部标签（待办/计划/回顾），收件箱与搜索从顶部进入。
//  · Mac 1440×960：约 220 宽左侧导航 + 主内容 + 按需 320 宽详情面板，设置放底部。
//

import SwiftUI
import MovoKit
#if os(iOS)
import UIKit
#endif

public struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Group {
            #if os(macOS)
            MacShell()
            #else
            PhoneShell()
            #endif
        }
        // 进前台 → 防抖触发同步（9.3 触发点）
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            _Concurrency.Task { await env.triggerSync() }
        }
        // 通知点按 → 深链到目标页（10.9）
        .onChange(of: env.notificationRouter.pending) { _, link in
            guard let link else { return }
            MovoDeepLink.apply(link, router: router)
            env.notificationRouter.clear()
        }
        .onOpenURL { url in
            if url.isFileURL {
                env.pendingImportURL = url
                router.present(.importPlan)
            } else {
                MovoDeepLink.apply(url: url, router: router)
            }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .movoImportPlan)) { _ in
            router.present(.importPlan)
        }
        #endif
        // 数据变更 → 1s 静默后重排通知（幂等覆盖）并触发同步；id 变化自动取消上一次
        .task(id: env.store.dataVersion) {
            guard env.store.dataVersion > 0 else { return }
            try? await _Concurrency.Task.sleep(for: .seconds(1))
            guard !_Concurrency.Task.isCancelled else { return }
            _ = await env.refreshNotifications()
            await env.triggerSync()
        }
    }
}

// MARK: - iPhone

#if os(iOS)
private struct PhoneShell: View {
    @Environment(\.movoRouter) private var router
    @Environment(AppEnvironment.self) private var env
    @State private var keyboardVisible = false

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.section) {
            ForEach(AppSection.phoneOrder) { section in
                NavigationStack(path: router.binding(for: section)) {
                    ScreenHost(route: .section(section))
                        .navigationDestination(for: Route.self) { ScreenHost(route: $0) }
                }
                .tabItem { Label(section.title, systemImage: section.systemImage) }
                .tag(section)
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible {
                HStack(spacing: 20) {
                    HStack(spacing: 0) {
                        ForEach(AppSection.phoneOrder) { section in
                            Button { router.section = section } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: section.systemImage).font(.system(size: 19))
                                    Text(section.title).font(MovoFont.caption)
                                }
                                .frame(maxWidth: .infinity).frame(minHeight: 56)
                                .foregroundStyle(router.section == section ? MovoColor.primary : MovoColor.muted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(router.section == section ? [.isSelected] : [])
                        }
                    }
                    .background(MovoColor.tint, in: RoundedRectangle(cornerRadius: 22))
                    Button { router.present(.quickCapture) } label: {
                        VStack(spacing: 1) {
                            Image(systemName: env.isProcessing ? "ellipsis" : "sparkles")
                            Text("AI").font(.caption2)
                        }
                        .foregroundStyle(.white).frame(width: 56, height: 56)
                        .background(MovoColor.primary, in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("AI 整理")
                }
                .padding(.horizontal, MovoSpace.m).padding(.vertical, MovoSpace.s)
                .background(MovoColor.bg)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .sheet(item: Binding(get: { router.sheet }, set: { router.sheet = $0 })) { route in
            SheetHost(route: route)
        }
    }
}
#endif

// MARK: - Mac

private struct MacShell: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 260)
        } detail: {
            HStack(spacing: 0) {
                NavigationStack(path: router.sectionPathBinding) {
                    ScreenHost(route: .section(router.section))
                        .navigationDestination(for: Route.self) { ScreenHost(route: $0) }
                }
                .frame(maxWidth: .infinity)

                if let inspector = router.inspector {
                    Rectangle().fill(MovoColor.line).frame(width: 1)
                    ScreenHost(route: inspector)
                        .navigationSplitViewColumnWidth(min: 320, ideal: 320, max: 360)
                        .frame(width: 320)
                        .background(MovoColor.surface)
                }
            }
        }
        .sheet(item: Binding(get: { router.sheet }, set: { router.sheet = $0 })) { route in
            SheetHost(route: route)
        }
        .background(MovoColor.bg)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("渐成")
                .font(MovoFont.title2)
                .foregroundStyle(MovoColor.ink)
                .padding(.horizontal, MovoSpace.m)
                .padding(.top, MovoSpace.m)
                .padding(.bottom, MovoSpace.s)

            ForEach(AppSection.sidebarOrder) { section in
                sidebarItem(section)
            }

            Spacer(minLength: MovoSpace.m)

            Divider()
            sidebarItem(nil, title: "设置", systemImage: "gearshape", route: .settings)
                .padding(.bottom, MovoSpace.s)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MovoColor.soft)
    }

    private func sidebarItem(_ section: AppSection) -> some View {
        sidebarItem(section, title: section.title, systemImage: section.systemImage,
                    route: .section(section))
    }

    private func sidebarItem(_ section: AppSection?, title: String, systemImage: String,
                             route: Route) -> some View {
        let isSelected = section.map { router.section == $0 } ?? (router.section == .today && false)
        return Button {
            if let section { router.select(section) } else { router.sheet = route }
        } label: {
            HStack(spacing: MovoSpace.s) {
                Image(systemName: systemImage).font(.system(size: 14, weight: .medium))
                Text(title).font(MovoFont.bodyEmphasis)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? MovoColor.primary : MovoColor.ink)
            .padding(.horizontal, MovoSpace.m)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: MovoRadius.button - 4, style: .continuous)
                .fill(isSelected ? MovoColor.tint : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MovoSpace.s)
        .padding(.vertical, 2)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - 浮层宿主

private struct SheetHost: View {
    let route: Route

    var body: some View {
        ScreenHost(route: route)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 420)
            #endif
    }
}
