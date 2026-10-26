import Foundation

// MARK: - API 真实请求检测（共享结果类型 + 传输层 + 端点存在性检查）
// 检测理念（对齐 one-api / new-api 渠道测试的业界做法）：不发"试探包"，而是按协议官方 SDK
// 的请求形态发一次最小真实请求；返回真实 Token 即认为该模型在该协议下可用。
// 单次检测 Token 消耗上限 50（Anthropic max_tokens=1；OpenAI max_output_tokens=16）。

public enum APICheckVerdict: Equatable {
    case ok(outputTokens: Int)            // 返回了真实 Token：该模型在此协议下可用
    case emptyKey                          // 供应商 Key 缺失，未发请求
    case authFail                          // 401/403
    case modelNotFound                     // 端点与 Key 正常，但该供应商不接受此模型
    case pathNotSupported                  // 404/405：该端点未开放此 API
    case rateLimited                       // 429
    case protocolMismatch                  // 2xx 但响应不符合该协议格式（地址可能实为另一协议）
    case upstreamError                     // 5xx
    case badRequest                        // 其他 4xx
    case unreachable                       // DNS/拒连/超时（未拿到 HTTP 响应）
}

public struct APICheckReport: Equatable {
    public let verdict: APICheckVerdict
    public let httpStatus: Int?
    public let latencyMs: Int
    /// 面向用户的补充说明（供应商错误消息摘要 / Token 数等）
    public let detail: String

    public var passed: Bool {
        if case .ok = verdict { return true }
        return false
    }
}

// MARK: - 同步 JSON POST 运行器（检测专用一次性调用，不进转发热路径）
enum APICheckTransport {
    struct Response {
        let status: Int?
        let body: Data?
        let error: String?      // 传输层错误描述（DNS/拒连/超时）
        let latencyMs: Int
    }

    static func post(url: URL, headers: [(String, String)], body: [String: Any], timeout: TimeInterval) -> Response {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let start = Date()
        var status: Int?
        var data: Data?
        var message: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, err in
            status = (resp as? HTTPURLResponse)?.statusCode
            data = d
            message = err.map { ($0 as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? $0.localizedDescription }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return Response(status: status, body: data, error: message,
                        latencyMs: Int(Date().timeIntervalSince(start) * 1000))
    }

    static func get(url: URL, timeout: TimeInterval) -> Response {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let start = Date()
        var status: Int?
        var data: Data?
        var message: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, err in
            status = (resp as? HTTPURLResponse)?.statusCode
            data = d
            message = err.map { ($0 as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? $0.localizedDescription }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return Response(status: status, body: data, error: message,
                        latencyMs: Int(Date().timeIntervalSince(start) * 1000))
    }

    /// 从供应商错误响应里提取可读消息（error.message / message / detail），截断到 140 字符。
    /// error 字段本身是内嵌 JSON 字符串时（部分网关这么返回），再解一层取 message。
    static func errorMessage(_ data: Data?, status: Int?) -> String {
        if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let candidates = [(obj["error"] as? [String: Any])?["message"],
                              obj["error"] as? String,
                              obj["message"],
                              obj["detail"]]
            for c in candidates {
                if let s = c as? String, !s.isEmpty {
                    return String(unwrapMessage(s).prefix(140))
                }
                if let d = c as? [String: Any], let m = d["message"] as? String, !m.isEmpty {
                    return String(m.prefix(140))
                }
            }
        }
        if let data, let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return String(unwrapMessage(s).prefix(140))
        }
        return "HTTP \(status ?? 0)"
    }

    /// error 字段是 JSON 字符串时解出 message；否则原样返回
    private static func unwrapMessage(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), let inner = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
              let m = inner["message"] as? String, !m.isEmpty else { return s }
        return m
    }

    /// 供应商对"模型不存在"的典型报错关键词
    /// （DeepSeek: "The supported API model names are … but you passed …"；OpenAI: "does not exist"；阿里: "Model not exist" 等）
    static func isModelNotFound(_ msg: String) -> Bool {
        let m = msg.lowercased()
        guard m.contains("model") else { return false }
        let hits = ["not exist", "does not exist", "doesn't exist", "not found", "no such",
                    "invalid model", "unknown model", "unsupported model", "不存在", "不支持该模型",
                    "you passed", "model names are", "valid model", "available model"]
        return hits.contains { m.contains($0) }
    }
}

// MARK: - 供应商 Base URL 存在性检查（连通性测试用：不发 API 请求、不消耗 Token）
// 「网址真实存在」= 该地址返回了任意 HTTP 响应（哪怕 404/405）；拿不到任何 HTTP 响应 = 不可达。
public enum EndpointPresence: Equatable {
    case exists(status: Int)
    case unreachable(detail: String)
}

public enum EndpointPresenceCheck {
    public static func check(base: URL, timeout: TimeInterval = 10) -> EndpointPresence {
        let resp = APICheckTransport.get(url: base, timeout: timeout)
        if let status = resp.status { return .exists(status: status) }
        return .unreachable(detail: resp.error ?? "无响应")
    }
}
