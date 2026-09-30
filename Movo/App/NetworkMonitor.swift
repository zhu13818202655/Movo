//
//  NetworkMonitor.swift
//  App
//
//  T3.2 触发点之一：网络变化。恢复联网时触发一次（防抖）同步。
//  离线时本机照常写入，联网后增量补齐（9.1）。
//

import Foundation
import Network

/// 轻量网络可达性监听。回调在后台队列上派发，调用方自行 hop 回主 actor。
final class NetworkMonitor: @unchecked Sendable {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.movo.network.monitor")
    private let handler: @Sendable (Bool) -> Void
    private var started = false

    init(handler: @escaping @Sendable (Bool) -> Void) {
        self.handler = handler
    }

    func start() {
        guard !started else { return }
        started = true
        let handler = self.handler
        monitor.pathUpdateHandler = { path in
            handler(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
        started = false
    }
}
