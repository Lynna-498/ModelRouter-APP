import Foundation
import Network

// MARK: - 上游中继（URLSession；响应体含 SSE 时原样字节透传）
/// 并发口径（T1/I26）：全部可变状态（session/headSent/status/totalOut/attempt/networkLossReason 等）
/// 队列封闭于 stateQueue——start/abort/cancel 与 URLSession delegate 回调都经该队列串行执行，
/// 消除「重试等待期下游断开后新任务漏取消」与跨队列数据竞争（先例：HTTPConnection.connections 同类修复）。
final class UpstreamRelay: NSObject, URLSessionDataDelegate {
    let req: URLRequest
    weak var downstream: HTTPConnection?
    let proto: Proto
    let onLog: LogFn
    let connID: UInt64
    let harnessID: UUID
    let modelField: String
    let targetModel: String
    let vendorName: String
    let t0 = Date()
    var session: URLSession?
    var headSent = false
    var status = 0
    var totalOut = 0                    // 已向下游回传的累计字节数
    var lastProgressAt = Date()         // progress 心跳节流：每 2s 或每 64KB 记一条（verbose）
    var lastProgressBytes = 0
    var attempt = 0                      // 已发起的上游尝试次数（含首次；零交付重试用）
    var networkLossReason: String?       // 网络路径中断主动终止时置位（区别于普通取消，不触发重试）
    static let maxPreDeliveryAttempts = 2   // 零交付前的最大尝试次数（首次 + 1 次重试）
    private let stateQueue = DispatchQueue(label: "mr.upstream-relay.state")

    init(req: URLRequest, downstream: HTTPConnection, proto: Proto, onLog: @escaping LogFn,
         connID: UInt64, harnessID: UUID, modelField: String, targetModel: String, vendorName: String) {
        self.req = req
        self.downstream = downstream
        self.proto = proto
        self.onLog = onLog
        self.connID = connID
        self.harnessID = harnessID
        self.modelField = modelField
        self.targetModel = targetModel
        self.vendorName = vendorName
    }

    private func emit(_ level: LogLevel, _ phase: LogPhase,
                      status: Int? = nil, bytesOut: Int? = nil, durationMs: Int? = nil, message: String? = nil) {
        onLog(LogEvent(level: level, phase: phase, connID: connID, harnessID: harnessID,
                       method: req.httpMethod, path: req.url?.path ?? "",
                       modelField: modelField, targetModel: targetModel, vendor: vendorName,
                       status: status, bytesOut: bytesOut,
                       durationMs: durationMs, message: message))
    }

    func start() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            // 重试等待期内网络中断/下游已断开：不再发起新上游任务（否则将无人取消，空烧 Token）
            guard self.networkLossReason == nil else { return }
            self.attempt += 1
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = K.upstreamIdleTimeout      // 空闲超时：覆盖上游长思考的首包等待；SSE 数据到达会重置
            cfg.timeoutIntervalForResource = K.upstreamResourceTimeout // 总时长上限：长对话流式生成远超 60s，不能用短值
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            self.session = s
            s.dataTask(with: self.req).resume()
        }
    }

    /// 网络路径中断（Wi-Fi 切换/VPN 重连等）：主动终止上游任务。
    /// 在途 SSE 无法续传，尽快让下游拿到截断信号并自行重试——不然只能干等 300s 空闲超时。
    func abortForNetworkLoss() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard self.networkLossReason == nil else { return }
            self.networkLossReason = "网络路径中断"
            self.session?.invalidateAndCancel()
        }
    }

    /// 下游客户端断开（取消/关连接）：上游任务必须立即终止，否则会一直生成到空闲超时、白烧 Token。
    /// 复用 networkLossReason 留痕分支（同时抑制零交付重试），原因文案用于监视器区分。
    func cancelForDownstreamGone() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard self.networkLossReason == nil else { return }
            self.networkLossReason = Self.downstreamGoneReason
            self.session?.invalidateAndCancel()
        }
    }

    static let downstreamGoneReason = "下游已断开"

    /// 连接类瞬时错误：零交付（未回传任何字节）时可安全重试。
    /// 超时不重试——首包等待本身已有 300s 预算，重试会让等待翻倍。
    static func isRetryableTransportError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return true
        default:
            return false
        }
    }

    /// 拒绝自动跟随重定向：301/302 会把 POST 转成 GET 丢 body，307/308 会静默重发——
    /// 路由器是透明转发，3xx 原样透传给客户端由它自己决定。
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        emit(.warning, .upstreamHead, status: response.statusCode,
             message: "上游重定向 \(response.statusCode) 已拒绝跟随，原样透传：\(response.value(forHTTPHeaderField: "Location") ?? "?")")
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        stateQueue.async { [weak self] in
            guard let self else { completionHandler(.cancel); return }
            self.status = http.statusCode
            // 上游 4xx/5xx 是"能转发但结果异常"：warning 档可见，排查上游侧问题
            self.emit(http.statusCode < 400 ? .debug : .warning, .upstreamHead,
                 status: http.statusCode, durationMs: Int(Date().timeIntervalSince(self.t0) * 1000),
                 message: http.statusCode < 400 ? nil : "上游返回 \(http.statusCode)")
            // 回传上游响应头，剥掉与逐跳转发冲突的四类
            var hs: [(String, String)] = []
            for (k, v) in http.allHeaderFields {
                let lk = "\(k)".lowercased()
                if lk == "content-length" || lk == "transfer-encoding" || lk == "connection" || lk == "content-encoding" { continue }
                hs.append(("\(k)", "\(v)"))
            }
            self.downstream?.sendHead(status: http.statusCode, headers: hs)
            self.headSent = true
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.totalOut += data.count
            self.downstream?.sendBody(data)   // stateQueue 串行 ⇒ 数据顺序保持
            let now = Date()
            if now.timeIntervalSince(self.lastProgressAt) >= 2 || self.totalOut - self.lastProgressBytes >= 65536 {
                self.lastProgressAt = now
                self.lastProgressBytes = self.totalOut
                self.emit(.verbose, .progress, bytesOut: self.totalOut,
                     durationMs: Int(now.timeIntervalSince(self.t0) * 1000))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(self.t0) * 1000)
            guard let error = error else {
                self.emit(.info, .finish, status: self.status, bytesOut: self.totalOut, durationMs: ms)
                self.downstream?.cleanup()
                session.invalidateAndCancel()
                return
            }
            // 零交付重试：尚未向下游回传任何字节前，连接类瞬时失败可安全重发（无重复输出风险）
            if !self.headSent, self.networkLossReason == nil, self.attempt < Self.maxPreDeliveryAttempts,
               Self.isRetryableTransportError(error) {
                self.emit(.warning, .decision, durationMs: ms,
                     message: "上游连接失败（\(error.localizedDescription)），零交付重试 \(self.attempt + 1)/\(Self.maxPreDeliveryAttempts)")
                session.invalidateAndCancel()
                self.stateQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.start()
                }
                return
            }
            if let reason = self.networkLossReason {
                let downstreamGone = reason == Self.downstreamGoneReason
                if !self.headSent {
                    self.emit(downstreamGone ? .info : .warning, .finish,
                         status: downstreamGone ? nil : 502, durationMs: ms,
                         message: downstreamGone
                             ? "\(reason)：上游任务已取消，未继续消耗"
                             : "\(reason)：上游连接已取消")
                    if !downstreamGone {
                        self.downstream?.sendError(status: 502, proto: self.proto, error: .upstream(reason), hid: self.harnessID)
                    }
                } else {
                    self.emit(.warning, .finish, status: self.status, bytesOut: self.totalOut, durationMs: ms,
                         message: downstreamGone
                             ? "\(reason)：上游任务已取消"
                             : "\(reason)：上游流已断开（截断，客户端可重试）")
                    if !downstreamGone { self.downstream?.cleanup() }
                }
            } else if !self.headSent {
                // 上游连接都没建立起来：下游还等着响应头，回 502
                self.emit(.error, .finish, status: 502, durationMs: ms,
                     message: "上游不可达: \(error.localizedDescription)")
                self.downstream?.sendError(status: 502, proto: self.proto, error: .upstream(error.localizedDescription), hid: self.harnessID)
            } else {
                // 流式已开始后被中断（超时/上游断开）：客户端收到截断流，无法补救；
                // 必须记 error——否则监视器显示 status 200 正常完成，排障时无从分辨
                self.emit(.error, .finish, status: self.status, bytesOut: self.totalOut, durationMs: ms,
                     message: "传输中断: \(error.localizedDescription)")
                self.downstream?.cleanup()
            }
            session.invalidateAndCancel()
        }
    }
}
