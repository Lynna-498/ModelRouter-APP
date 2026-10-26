import Foundation

// MARK: - OpenAI Responses API Check
// 按官方 Responses API 的 SDK 请求形态，向 OpenAI 兼容 baseURL 发一次最小真实请求：
//   POST {base}/responses
//   headers: Authorization: Bearer <key>
//   body: {"model": <id>, "input": ".", "max_output_tokens": 16}
// max_output_tokens 取 16：Responses API 允许的最小值（低于会 400 "integer below minimum value"），
// 且满足单次 ≤50 Token 的预算。判定：2xx 且返回真实 Token（usage.output_tokens ≥ 1 或 output 非空）→ 可用。
public enum OpenAIResponsesAPICheck {
    public static let apiPath = "responses"
    public static let minMaxOutputTokens = 16

    public static func check(base: URL, key: String, modelID: String,
                             timeout: TimeInterval = 20) -> APICheckReport {
        guard !key.isEmpty else {
            return APICheckReport(verdict: .emptyKey, httpStatus: nil, latencyMs: 0,
                                  detail: "供应商 Key 缺失，未发请求")
        }
        let url = base.appendingPathComponent(apiPath)
        let body: [String: Any] = [
            "model": modelID,
            "input": ".",
            "max_output_tokens": minMaxOutputTokens,
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
            let output = (obj["output"] as? [Any]) ?? []
            let usage = obj["usage"] as? [String: Any]
            let outputTokens = (usage?["output_tokens"] as? Int) ?? 0
            if outputTokens >= 1 || !output.isEmpty {
                return report(.ok(outputTokens: outputTokens),
                              "返回真实 Token \(outputTokens) · \(resp.latencyMs)ms")
            }
            return report(.protocolMismatch, "HTTP \(status) 但响应不符合 OpenAI Responses 格式")
        }
        if status == 401 || status == 403 { return report(.authFail) }
        if status == 404 || status == 405 { return report(.pathNotSupported) }
        if status == 429 { return report(.rateLimited) }
        if status >= 500 { return report(.upstreamError) }
        if APICheckTransport.isModelNotFound(detail) { return report(.modelNotFound) }
        return report(.badRequest)
    }
}
