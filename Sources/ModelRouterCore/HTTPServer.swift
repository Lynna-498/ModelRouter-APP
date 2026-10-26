import Foundation
import Network

// MARK: - HTTP 服务器（NWListener，单端口；按路径前缀 /anthropic、/codex 分流）
public final class HTTPServer {
    private let listener: NWListener
    private let router: Router
    private let onLog: LogFn
    private let queue = DispatchQueue(label: "mr.httpserver")
    private var connections: [HTTPConnection] = []
    private var nextConnID: UInt64 = 0            // queue 上分配，天然串行
    private var watchdog: DispatchSourceTimer?    // 下游读空闲看门狗
    private var pathMonitor: NWPathMonitor?       // 网络路径监控（中断快速失败）
    private var pathDegradedAt: Date?             // 路径断开起始时间（2s 去抖）
    private var pathDownHandled = false           // 本次断开是否已执行快速失败
    /// 监听器生命周期回调（ok, 详情）：.ready / .failed 透传给 App 层，端口占用等失败不再静默。
    /// 在服务器队列触发，接收方自行 hop 主线程。
    public var onLifecycle: ((Bool, String) -> Void)?

    /// 只监听 IPv4 回环 127.0.0.1 上的单个端口。
    /// 不做 IPv6 [::1] 双栈：Network.framework 同进程同端口 v4/v6 listener 互斥（后绑者报
    /// Address already in use），唯一绕法是 SO_REUSEPORT 类选项——会允许其他进程抢绑本端口，
    /// 扩大端口劫持面，安全上不可接受。IPv6 兼容由客户端侧处理：下发的 baseURL 是字面
    /// 127.0.0.1（AppState.endpointText），不依赖 localhost 解析；填 localhost 的客户端由
    /// 其 Happy Eyeballs 回落到 IPv4（curl/URLSession 等主流实现均支持）。
    public init(port: Int, router: Router, onLog: @escaping LogFn) throws {
        self.router = router
        self.onLog = onLog
        guard (0...65535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw HTTPServerError.invalidPort(port)
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: nwPort)
        self.listener = try NWListener(using: params)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            if self.connections.count >= K.maxConnections {   // 并发连接上限：防连接耗尽
                conn.cancel()
                return
            }
            self.nextConnID += 1
            let connection = HTTPConnection(connID: self.nextConnID, conn: conn, router: self.router, onLog: self.onLog) { [weak self] c in
                self?.connections.removeAll { $0 === c }
            }
            self.connections.append(connection)
            connection.start(on: self.queue)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onLifecycle?(true, "")
            case .failed(let err):
                print("[server] listener failed: \(err)")
                self?.onLifecycle?(false, "\(err)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        startWatchdog()
        startPathMonitor()
    }

    /// 停止监听并回收全部在途连接（改端口 / 重启监听用）。
    /// 服务器队列上收敛：先摘回调（onLifecycle 与 listener 两个 handler），再 cancel
    /// listener、看门狗与路径监控，最后逐连接 cleanup——下游收 FIN，上游经
    /// cancelForDownstreamGone 立即取消（不空烧 Token）。调用后本实例终结，不再泄漏状态回调。
    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.onLifecycle = nil
            self.listener.newConnectionHandler = nil
            self.listener.stateUpdateHandler = nil
            self.listener.cancel()
            self.watchdog?.cancel()
            self.watchdog = nil
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            for c in self.connections { c.cleanup() }   // cleanup 内部 hop 回本队列，队列封闭
        }
    }

    /// 客户端建连后长时间不发数据（或 body 永远发不完）的连接会被永久占用；
    /// 30s 扫一次：未收齐且建立超过绝对时限、或静默超 120s 即清理（防滴漏式慢速占用）。
    /// 响应阶段不受看门狗管（由上游超时管理）。
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            for c in self.connections where !c.bodyComplete && !c.cleaned {
                if now.timeIntervalSince(c.createdAt) > K.requestAbsoluteDeadline {
                    c.emit(.warning, .finish,
                           message: "请求收齐超时（绝对时限 \(Int(K.requestAbsoluteDeadline))s），已断开")
                    c.cleanup()
                    continue
                }
                if now.timeIntervalSince(c.lastActivity) > 120 {
                    c.emit(.warning, .finish,
                           message: "连接空闲超时：请求 120s 未收齐，已断开")
                    c.cleanup()
                }
            }
            // 响应阶段兜底：URLSession 保证任务不会合法活过总时长上限，超过仍未收尾必是卡死
            let stuckLimit = K.upstreamResourceTimeout + 120
            for c in self.connections
                where c.bodyComplete && !c.cleaned && now.timeIntervalSince(c.createdAt) > stuckLimit {
                c.emit(.warning, .finish,
                       message: "响应阶段连接超过总时长上限仍未收尾，已回收")
                c.cleanup()
            }
        }
        watchdog = t
        t.resume()
    }

    /// 网络路径监控：系统网络闪断（Wi-Fi 切换/VPN 重连等）会让已建立的上游 TCP 流静默黑洞化，
    /// 没有 FIN/RST 可察觉，只能等 300s 空闲超时。路径断开持续 2s（去抖）即主动终止所有在途中继，
    /// 让客户端几秒内拿到截断信号并自行重试。
    private func startPathMonitor() {
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { [weak self] p in
            guard let self = self else { return }
            if p.status == .satisfied {
                self.pathDegradedAt = nil
                self.pathDownHandled = false
            } else if self.pathDegradedAt == nil {
                self.pathDegradedAt = Date()
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self = self, self.pathDegradedAt != nil, !self.pathDownHandled else { return }
                    self.pathDownHandled = true
                    self.failInflightRelays(reason: "网络路径中断")
                }
            }
        }
        mon.start(queue: queue)
        pathMonitor = mon
    }

    /// 终止所有在途上游中继（由路径监控触发；中继自己负责留痕与通知下游）
    private func failInflightRelays(reason: String) {
        for c in self.connections {
            c.relay?.abortForNetworkLoss()
        }
    }
}
