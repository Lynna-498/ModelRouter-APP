import Foundation
import Network

// MARK: - 单条下游连接：解析 → 鉴权 → 转发
final class HTTPConnection {
    let connID: UInt64
    let conn: NWConnection
    let router: Router
    let onLog: LogFn
    let release: (HTTPConnection) -> Void
    var buffer = Data()
    var parsed = false
    var bodyStart = Data.Index(0)   // 头结束位置（body 累积起点；大 body 需多次 receive 凑齐）
    var bodyComplete = false        // body 已凑齐并进入处理/响应阶段
    var cleaned = false
    var lastActivity = Date()       // 看门狗：最近一次收到下游数据的时间
    var method = "GET"
    var path = "/"
    var headers: [(String, String)] = []
    var contentLength = 0
    var chunked = false            // Transfer-Encoding: chunked（大 body 客户端可能不用 Content-Length）
    var chunkScanPos = Data.Index(0)   // chunked 增量解析游标
    var chunkBody = Data()             // 已解析出的 body 累积
    enum ChunkState { case size, data, trailer }
    var chunkState: ChunkState = .size
    var chunkDataRemaining = 0
    var relay: UpstreamRelay?
    var badFraming = false          // Content-Length/Transfer-Encoding 冲突或非法
    var bodyTooLarge = false        // Content-Length 声明超过上限
    let createdAt = Date()          // 看门狗：连接建立时间（请求收齐绝对时限用）
    private var queue: DispatchQueue?   // 服务器队列：cleanup 及其后续状态全部收敛到此队列

    init(connID: UInt64, conn: NWConnection, router: Router, onLog: @escaping LogFn, release: @escaping (HTTPConnection) -> Void) {
        self.connID = connID
        self.conn = conn
        self.router = router
        self.onLog = onLog
        self.release = release
    }

    /// 埋点统一入口：method/path 恒已知，其余按环节填
    func emit(_ level: LogLevel, _ phase: LogPhase,
              hid: UUID? = nil, modelField: String? = nil, targetModel: String? = nil,
              vendor: String? = nil, status: Int? = nil, bytesIn: Int? = nil,
              bytesOut: Int? = nil, durationMs: Int? = nil, message: String? = nil) {
        onLog(LogEvent(level: level, phase: phase, connID: connID, harnessID: hid,
                       method: method, path: path, modelField: modelField,
                       targetModel: targetModel, vendor: vendor, status: status,
                       bytesIn: bytesIn, bytesOut: bytesOut,
                       durationMs: durationMs, message: message))
    }

    func start(on queue: DispatchQueue) {
        self.queue = queue
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:      self?.receive()
            case .failed:     self?.cleanup()
            case .cancelled:  self?.cleanup()
            case .waiting:    self?.cleanup()   // 已接受的入站连接进入 waiting = 对端/路径异常，不再可能完成
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.lastActivity = Date()
                self.buffer.append(data)
                self.tryParse()
            }
            if error != nil { self.cleanup(); return }
            // 对端关闭（FIN/RST）：无论请求是否已收齐，这条连接都不可能再继续。
            // 响应阶段必须同样收尾——否则客户端中止后上游会空烧到自然超时。
            if isComplete {
                if !self.bodyComplete {
                    self.emit(.warning, .finish, message: "客户端在请求收齐前断开连接")
                }
                self.cleanup()
            }
        }
    }

    func tryParse() {
        if bodyComplete { return }   // 已进入响应阶段或已拒绝：不再处理后续数据
        if !parsed {
            // 头部上限：超过上限仍未见头结束符，属异常请求（慢速大头部攻击）
            if buffer.count > K.maxHeaderBytes,
               buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                bodyComplete = true
                emit(.error, .decision, status: 400, message: "请求头部超限")
                sendError(status: 400, proto: .anthropic, error: .badFraming, hid: nil)
                return
            }
            guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else { receive(); return }
            let headerStr = String(data: buffer.subdata(in: buffer.startIndex..<sep.lowerBound), encoding: .utf8) ?? ""
            parseHeaders(headerStr)
            parsed = true
            bodyStart = sep.upperBound
            chunkScanPos = sep.upperBound

            // 框架检查：CL/TE 冲突与 CL 超限在 parseHeaders 阶段已判定
            if badFraming {
                bodyComplete = true
                emit(.error, .decision, status: 400, message: "请求框架非法（Content-Length/Transfer-Encoding 冲突或非法）")
                sendError(status: 400, proto: .anthropic, error: .badFraming, hid: nil)
                return
            }
            if bodyTooLarge {
                bodyComplete = true
                emit(.error, .decision, status: 413, message: "请求体超过 \(K.maxBodyBytes / 1_048_576)MB 上限")
                sendError(status: 413, proto: .anthropic, error: .bodyTooLarge, hid: nil)
                return
            }
            // 鉴权前置：路径、Key、方法与 Host 在收 body 之前完成校验——无许可不缓冲请求体、不消耗后续资源
            let bearer = headerValue("Authorization")
            guard let preProto = Router.classify(path: path) else {
                bodyComplete = true
                if bearer?.hasPrefix("Bearer ") == true {
                    emit(.error, .decision, status: 404, message: RouterError.unknownPath.description)
                    sendError(status: 404, proto: .anthropic, error: .unknownPath, hid: nil)
                } else {
                    emit(.error, .decision, status: 401, message: RouterError.missingKey.description)
                    sendError(status: 401, proto: .anthropic, error: .missingKey, hid: nil)
                }
                return
            }
            if case .failure(let e) = router.identify(bearer: bearer, path: path, proto: preProto) {
                bodyComplete = true
                emit(.error, .decision, status: 401, message: e.description)
                sendError(status: 401, proto: preProto, error: e, hid: nil)
                return
            }
            // 方法白名单：GET（模型发现）/ POST（转发）/ HEAD（客户端连通性预检用，放行后按旧逻辑在 handle 阶段回 400）
            let methodOK = method == "GET" || method == "POST" || method == "HEAD"
            if !methodOK {
                bodyComplete = true
                emit(.error, .decision, status: 405, message: RouterError.methodNotAllowed.description)
                sendError(status: 405, proto: preProto, error: .methodNotAllowed, hid: nil)
                return
            }
            if !hostIsLocal() {
                bodyComplete = true
                emit(.warning, .decision, status: 403, message: "Host 头非本地地址，已拒绝")
                sendError(status: 403, proto: preProto, error: .badHost, hid: nil)
                return
            }
        }
        if chunked {
            // chunked 请求体：增量解析，每次收到新数据推进游标
            switch parseChunkedBody() {
            case .done(let body):
                bodyComplete = true
                handle(body: body)
            case .incomplete:
                receive()
            case .bad:
                bodyComplete = true
                emit(.error, .decision, status: 400, message: "chunked 请求体格式非法")
                sendError(status: 400, proto: .anthropic, error: .badBody, hid: nil)
            case .tooLarge:
                bodyComplete = true
                emit(.error, .decision, status: 413, message: "chunked 请求体超限")
                sendError(status: 413, proto: .anthropic, error: .bodyTooLarge, hid: nil)
            }
            return
        }
        // Content-Length 请求体：每次收到新数据都检查是否凑齐（大 body > 单次 receive 上限 64KB 需多次累积）
        let bodyData = buffer.subdata(in: bodyStart..<buffer.endIndex)
        if bodyData.count >= contentLength {
            bodyComplete = true
            let body = contentLength > 0 ? Data(bodyData.prefix(contentLength)) : Data()
            handle(body: body)
        } else {
            receive()
        }
    }

    // MARK: chunked 解码（RFC 9112 §7.1：<size-hex>[;ext]\r\n <data>\r\n … 0\r\n [trailers] \r\n）
    enum ChunkedResult { case incomplete, done(Data), bad, tooLarge }

    func parseChunkedBody() -> ChunkedResult {
        while true {
            switch chunkState {
            case .size:
                guard let r = buffer.range(of: Data("\r\n".utf8), in: chunkScanPos..<buffer.endIndex) else {
                    return .incomplete
                }
                let sizeLine = String(data: buffer.subdata(in: chunkScanPos..<r.lowerBound), encoding: .utf8) ?? ""
                let hex = sizeLine.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let n = Int(hex, radix: 16), n >= 0 else { return .bad }
                chunkScanPos = r.upperBound
                if n == 0 {
                    chunkState = .trailer
                } else {
                    chunkDataRemaining = n
                    chunkState = .data
                }
            case .data:
                guard let n = Int(exactly: buffer.distance(from: chunkScanPos, to: buffer.endIndex)),
                      n >= chunkDataRemaining + 2 else { return .incomplete }
                chunkBody.append(buffer.subdata(in: chunkScanPos..<buffer.index(chunkScanPos, offsetBy: chunkDataRemaining)))
                chunkScanPos = buffer.index(chunkScanPos, offsetBy: chunkDataRemaining + 2)   // data + CRLF
                if chunkBody.count > K.maxBodyBytes { return .tooLarge }
                chunkState = .size
            case .trailer:
                // 逐行跳过 trailer，空行（\r\n）即结束
                if buffer.distance(from: chunkScanPos, to: buffer.endIndex) < 2 { return .incomplete }
                if buffer.subdata(in: chunkScanPos..<buffer.index(chunkScanPos, offsetBy: 2)) == Data("\r\n".utf8) {
                    return .done(chunkBody)
                }
                guard let r = buffer.range(of: Data("\r\n".utf8), in: chunkScanPos..<buffer.endIndex) else {
                    return .incomplete
                }
                chunkScanPos = r.upperBound
            }
        }
    }

    func parseHeaders(_ str: String) {
        var lines = str.components(separatedBy: "\r\n")
        if let first = lines.first {
            let parts = first.split(separator: " ")
            if parts.count >= 2 {
                method = String(parts[0])
                path = String(parts[1])
                if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }   // 剥查询串
                if let h = path.firstIndex(of: "#") { path = String(path[..<h]) }   // 剥片段
            }
            lines.removeFirst()
        }
        var cls: [Int] = []
        var sawChunked = false
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<i]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            headers.append((key, val))
            let lk = key.lowercased()
            if lk == "content-length" { cls.append(Int(val) ?? -1) }
            if lk == "transfer-encoding" && val.lowercased().contains("chunked") { sawChunked = true }
        }
        // CL 解析：取首个合法值；重复且不同值 / 非数字 / 负数 → 框架非法
        if cls.isEmpty {
            contentLength = 0
        } else if let v = cls.first, v >= 0, cls.allSatisfy({ $0 == v }) {
            contentLength = v
        } else {
            badFraming = true
            return
        }
        if sawChunked {
            if !cls.isEmpty { badFraming = true; return }   // CL 与 chunked 并存：按 RFC 9112 拒绝
            chunked = true
        }
        if contentLength > K.maxBodyBytes { bodyTooLarge = true }
    }

    func headerValue(_ name: String) -> String? {
        for (k, v) in headers where k.lowercased() == name.lowercased() { return v }
        return nil
    }

    /// Host 必须指向本机回环（防 DNS rebinding 探测）；端口段不校验
    func hostIsLocal() -> Bool {
        let h = (headerValue("Host") ?? "").lowercased()
        let bare: String
        if h.hasPrefix("[") {
            guard let end = h.firstIndex(of: "]") else { return false }
            bare = String(h[h.startIndex...end])
        } else if let colon = h.firstIndex(of: ":") {
            bare = String(h[..<colon])
        } else {
            bare = h
        }
        return ["127.0.0.1", "localhost", "[::1]"].contains(bare)
    }

    func handle(body: Data) {
        // 解析一次，request 事件即带 model 字段（监视器里能直接看到是哪个模型的请求）
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let modelField = payload?["model"] as? String
        emit(.debug, .request, modelField: modelField, bytesIn: body.count)
        // 路径前缀定协议；不认识的路径按 Anthropic 风格回 404
        guard let proto = Router.classify(path: path) else {
            emit(.error, .decision, status: 404, message: RouterError.unknownPath.description)
            sendError(status: 404, proto: .anthropic, error: .unknownPath, hid: nil)
            return
        }
        let bearer = headerValue("Authorization")
        switch router.identify(bearer: bearer, path: path, proto: proto) {
        case .success(let hid):
            if !router.isRoutingEnabled(harnessID: hid) {
                emit(.warning, .decision, hid: hid, status: 503,
                     message: RouterError.routingDisabled.description)
                sendError(status: 503, proto: proto, error: .routingDisabled, hid: hid)
                return
            }
            // 模型发现：GET */v1/models —— 识别通过后直接回本机模型清单，不转发、不消耗
            if method == "GET" && (path.hasSuffix("/models") || path.hasSuffix("/models/")) {
                sendModelList(proto: proto, hid: hid)
                return
            }
            forward(payload: payload, modelField: modelField, proto: proto, hid: hid)
        case .failure(let e):
            emit(.error, .decision, status: 401, message: e.description)
            sendError(status: 401, proto: proto, error: e, hid: nil)
        }
    }

    /// 模型发现响应：Anthropic 面 = data[{type,id,display_name}]；OpenAI 面 = object:list data[{id,object,…}]
    func sendModelList(proto: Proto, hid: UUID) {
        let list = router.modelList(harnessID: hid, proto: proto)
        let body: Data
        switch proto {
        case .anthropic:
            // 对齐官方 /v1/models 规范：first_id/last_id 缺了部分严格 SDK 会解析失败
            let items: [[String: Any]] = list.map {
                ["type": "model", "id": $0.id, "display_name": $0.name ?? $0.id]
            }
            var root: [String: Any] = ["data": items, "has_more": false]
            if let f = items.first?["id"] { root["first_id"] = f }
            if let l = items.last?["id"] { root["last_id"] = l }
            body = (try? JSONSerialization.data(withJSONObject: root)) ?? Data("{}".utf8)
        case .openai:
            let items: [[String: Any]] = list.map {
                ["id": $0.id, "object": "model", "created": 0, "owned_by": "modelrouter"]
            }
            body = (try? JSONSerialization.data(withJSONObject: ["object": "list", "data": items])) ?? Data("{}".utf8)
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.cleanup()
        })
        emit(.info, .finish, hid: hid, status: 200,
             bytesOut: body.count, durationMs: 0, message: "模型发现 · \(list.count) 个模型")
    }

    func forward(payload: [String: Any]?, modelField: String?, proto: Proto, hid: UUID) {
        guard let payload, let modelField else {
            emit(.error, .decision, hid: hid, status: 400, message: RouterError.badBody.description)
            sendError(status: 400, proto: proto, error: .badBody, hid: hid)
            return
        }
        switch router.buildUpstream(path: path, headers: headers, payload: payload,
                                    harnessID: hid, proto: proto, modelField: modelField) {
        case .success(let plan):
            // 降级是"部分请求行为异常"的头号线索：沿档序换了模型必须显式留痕
            emit(plan.fellBackFrom == nil ? .debug : .warning, .decision,
                 hid: hid, modelField: modelField, targetModel: plan.targetModel,
                 vendor: plan.vendorName,
                 message: plan.fellBackFrom == nil ? nil : "档位降级生效：\(plan.fellBackFrom!) → \(plan.targetModel)")
            relay = UpstreamRelay(req: plan.request, downstream: self, proto: proto, onLog: onLog,
                                  connID: connID, harnessID: hid, modelField: modelField,
                                  targetModel: plan.targetModel, vendorName: plan.vendorName)
            relay?.start()
        case .failure(let e):
            emit(.error, .decision, hid: hid, modelField: modelField,
                 status: Self.errorCode(e), message: e.description)
            sendError(status: Self.errorCode(e), proto: proto, error: e, hid: hid, modelField: modelField)
        }
    }

    static func errorCode(_ e: RouterError) -> Int {
        switch e {
        case .routingDisabled:                                        return 503
        case .noMapping, .noAnthropicBase, .noOpenAIBase, .unknownPath,
             .universalNotFound:                                      return 404
        case .noVendorKey, .upstream:                                 return 502
        case .badBody, .universalBadModel, .pathTraversal, .badFraming: return 400
        case .methodNotAllowed:                                       return 405
        case .bodyTooLarge:                                           return 413
        case .badHost:                                                return 403
        case .missingKey, .unknownKey, .protoMismatch, .baseURLMismatch: return 401
        }
    }

    func sendHead(status: Int, headers: [(String, String)]) {
        let reason = Self.httpReason(for: status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.cleanup() }   // 对端已死：尽快收尾并终止上游
        })
    }

    func sendBody(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { [weak self] err in
            if err != nil { self?.cleanup() }
        })
    }

    func sendError(status: Int, proto: Proto, error: RouterError, hid: UUID?, modelField: String? = nil) {
        // 按客户端协议的惯例错误体回传，消息原样透明；JSONSerialization 构造，防插值注入。
        // 头和体合并为一次 send：分两次发再立刻 cancel 会把体丢掉（连接在刷出前被取消）。
        // 事件埋点在调用点完成，这里只负责发送。
        let obj: [String: Any]
        switch proto {
        case .anthropic:
            obj = ["type": "error", "error": ["type": "router_error", "message": error.description]]
        case .openai:
            obj = ["error": ["message": error.description, "type": "router_error"]]
        }
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status) \(Self.httpReason(for: status))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.cleanup()
        })
    }

    /// 清理入口。调用方可能在 URLSession delegate 队列 / NW 回调上，统一 hop 回服务器队列执行——
    /// connections 数组与 cleaned 标志变为队列封闭状态（此前跨队列 removeAll 曾崩溃并泄漏连接）。
    func cleanup() {
        guard let queue = queue else { return }
        queue.async { self.finishCleanup() }
    }

    private func finishCleanup() {
        guard !cleaned else { return }
        cleaned = true
        conn.stateUpdateHandler = nil
        conn.cancel()
        relay?.cancelForDownstreamGone()   // 下游已走：上游立即终止，不再空烧 Token
        relay = nil
        release(self)
    }

    static func httpReason(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default:  return "OK"
        }
    }
}
