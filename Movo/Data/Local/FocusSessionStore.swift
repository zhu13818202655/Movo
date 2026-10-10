//
//  FocusSessionStore.swift
//  Data/Local
//
//  进行中的专注会话落本机：App 被系统回收或退出后重新打开要能接着走，
//  所以会话不能只活在内存里。
//
//  只走本机偏好，不进 CloudKit、不进导出、不进日志：
//  「这台设备此刻在计时」换设备继续没有意义，也会把正在做的事泄漏到同步通道上。
//
//  同时只保留一次计时。计时条、状态机与暂停都按「一次一个」设计：
//  要开始新的计时，调用方先把手上这一次结束或放弃。存储层不做替换，
//  因为「静默丢掉一次正在跑的计时」不是一个存储层能替用户做的决定。
//

import Foundation

/// 进行中会话的读写契约。
///
/// 实现只在主 actor（`AppEnvironment`）上使用，因此不要求 `Sendable`——
/// `UserDefaults` 本身不是 Sendable 类型。测试与预览使用内存实现。
public protocol FocusSessionStore {
    /// 读回进行中的会话；没有、或存进去的东西解不出来时为 nil。
    func load() -> FocusPolicy.Session?
    /// 写入或清空。传 nil 表示这次计时已经结束或放弃。
    func save(_ session: FocusPolicy.Session?)
}

/// 本机偏好实现。
///
/// `load()` 解析不出内容时按「没有进行中的计时」处理，刻意不抛错：
/// 一条写坏的记录不该卡住启动，也不该让用户看到一条与当前操作无关的解析错误。
/// 会话只是「此刻在做什么」，丢一次的代价远小于启动被拦住。
public struct UserDefaultsFocusSessionStore: FocusSessionStore {

    /// 存储键。公开出来供测试与「还原到出厂状态」使用。
    public static let defaultKey = "movo.focus.session"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsFocusSessionStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> FocusPolicy.Session? {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(FocusPolicy.Session.self, from: data)
        else { return nil }
        return decoded
    }

    public func save(_ session: FocusPolicy.Session?) {
        guard let session else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 测试 / 预览实现（不触真实偏好）。引用类型，保证写入后能读回。
public final class InMemoryFocusSessionStore: FocusSessionStore {

    private let lock = NSLock()
    private var value: FocusPolicy.Session?

    public init(_ value: FocusPolicy.Session? = nil) { self.value = value }

    public func load() -> FocusPolicy.Session? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func save(_ session: FocusPolicy.Session?) {
        lock.lock(); defer { lock.unlock() }
        value = session
    }
}
