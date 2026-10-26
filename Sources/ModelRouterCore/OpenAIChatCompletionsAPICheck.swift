import Foundation

// MARK: - OpenAI Chat Completions API Check
// 按官方 Chat Completions API 的 SDK 请求形态，向 OpenAI 兼容 baseURL 发一次最小真实请求：
//   POST {base}/chat/completions
//   headers: Authorization: Bearer <key>
//   body: {"model": <id>, "messages": [{"role":"user","content":"."}], "max_tokens": 1}
// max_tokens 是兼容端最通用的参数（官方新模型推荐 max_completion_tokens，但本检测面向
// 兼容生态，优先 max_tokens）；判定：2xx 且返回真实 Token（choices 非空 / usage.completion_tokens ≥ 1）→ 可用。
// 单次 Token 消耗约 10 个，远低于 50 上限。
public enum OpenAIChatCompletionsAPICheck {
    public static let apiPath = "chat/completions"

    public static func check(base: URL, key: String, modelID: String,
                             timeout: TimeInterval = 20) -> APICheckReport {
        guard !key.isEmpty else {
            return APICheckReport(verdict: .emptyKey, httpStatus: nil, latencyMs: 0,
                                  detail: "供应商 Key 缺失，未发请求")
        }
        let url = base.appendingPathComponent(apiPath)
        let body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": "."]],
            "max_tokens": 1,
        ]
        let resp = APICheckTransport.post(url: url,
                                          headers: [("Authorization", "Bearer \(key)")],
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
                return report(.protocolMismatch, "HTTP \(status) 但响应不是 JSON（该地址可能并非 OpenAI 兼容端点）")
            }
            let choices = (obj["choices"] as? [Any]) ?? []
            let usage = obj["usage"] as? [String: Any]
            let completionTokens = (usage?["completion_tokens"] as? Int) ?? 0
            if completionTokens >= 1 || !choices.isEmpty {
                return report(.ok(outputTokens: completionTokens),
                              "返回真实 Token \(completionTokens) · \(resp.latencyMs)ms")
            }
            return report(.protocolMismatch, "HTTP \(status) 但响应不符合 Chat Completions 格式")
        }
        if status == 401 || status == 403 { return report(.authFail) }
        if status == 404 || status == 405 { return report(.pathNotSupported) }
        if status == 429 { return report(.rateLimited) }
        if status >= 500 { return report(.upstreamError) }
        if APICheckTransport.isModelNotFound(detail) { return report(.modelNotFound) }
        return report(.badRequest)
    }
}
