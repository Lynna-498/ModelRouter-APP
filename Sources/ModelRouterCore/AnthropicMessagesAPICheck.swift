import Foundation

// MARK: - Anthropic Messages API Check
// 按官方 Messages API 的 SDK 请求形态，向 Anthropic 兼容 baseURL 发一次最小真实请求：
//   POST {base}/v1/messages
//   headers: x-api-key + anthropic-version: 2023-06-01（与官方 SDK 一致）
//   body: {"model": <id>, "max_tokens": 1, "messages": [{"role":"user","content":"."}]}
// 判定：2xx 且返回了真实 Token（content 非空 / usage.output_tokens ≥ 1）→ 该模型在此协议下可用。
// 单次 Token 消耗：max_tokens=1 + 约 10 个输入 Token，远低于 50 上限。
public enum AnthropicMessagesAPICheck {
    public static let apiPath = "v1/messages"
    public static let version = "2023-06-01"

    public static func check(base: URL, key: String, modelID: String,
                             timeout: TimeInterval = 20) -> APICheckReport {
        guard !key.isEmpty else {
            return APICheckReport(verdict: .emptyKey, httpStatus: nil, latencyMs: 0,
                                  detail: "供应商 Key 缺失，未发请求")
        }
        let url = base.appendingPathComponent(apiPath)
        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]],
        ]
        let resp = APICheckTransport.post(url: url,
                                          headers: [("x-api-key", key),
                                                    ("anthropic-version", version)],
                                          body: body, timeout: timeout)
        return classify(resp)
    }

    static func classify(_ resp: APICheckTransport.Response) -> APICheckReport {
        let detail = APICheckTransport.errorMessage(resp.body, status: resp.status)
        if let err = resp.error {
            return APICheckReport(verdict: .unreachable, httpStatus: nil, latencyMs: resp.latencyMs, detail: err)
        }
        guard let status = resp.status else {
            return APICheckReport(verdict: .unreachable, httpStatus: nil, latencyMs: resp.latencyMs, detail: "无响应")
        }
        func report(_ v: APICheckVerdict, _ d: String? = nil) -> APICheckReport {
            APICheckReport(verdict: v, httpStatus: status, latencyMs: resp.latencyMs, detail: d ?? detail)
        }
        if (200...299).contains(status) {
            guard let data = resp.body,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return report(.protocolMismatch, "HTTP \(status) 但响应不是 JSON（该地址可能并非 Anthropic 兼容端点）")
            }
            let type = obj["type"] as? String
            let content = (obj["content"] as? [[String: Any]]) ?? []
            let usage = obj["usage"] as? [String: Any]
            let outputTokens = (usage?["output_tokens"] as? Int) ?? 0
            // 官方格式：type == "message" 且 content 非空；usage 缺失时以 content 为准（兼容第三方实现）
            if (type == "message" || type == nil) && !content.isEmpty {
                return report(.ok(outputTokens: outputTokens),
                              "返回真实 Token \(outputTokens) · \(resp.latencyMs)ms")
            }
            return report(.protocolMismatch, "HTTP \(status) 但响应不符合 Anthropic Messages 格式")
        }
        if status == 401 || status == 403 { return report(.authFail) }
        if status == 404 || status == 405 { return report(.pathNotSupported) }
        if status == 429 { return report(.rateLimited) }
        if status >= 500 { return report(.upstreamError) }
        if APICheckTransport.isModelNotFound(detail) { return report(.modelNotFound) }
        return report(.badRequest)
    }
}
