import Foundation


// MARK: - Codex Responses 供应商方言归一化（I14：隔离路由第四件——客户端方言 → 服务端方言）
// Responses 生态的上游存在实现偏差（Anthropic 线上游全为兼容端点、无此问题）：
// 按目标供应商 baseURL host 匹配规则表；无匹配＝原样透传（保持既有行为）。
public enum CodexDialect {

    /// 单条方言规则：host 后缀匹配＋payload 变换
    public struct Rule {
        let hostSuffix: String
        let apply: (inout [String: Any]) -> Void
    }

    /// 已知方言差异表（后续差异逐条累加；host 为协议事实，不受供应商改名影响）
    public static let rules: [Rule] = [
        Rule(hostSuffix: "api.deepseek.com") { payload in
            // DeepSeek 官方 config.toml 口径：WebSearch 禁用（管理员 2026-09-29 提醒）——
            // 剥离历史 web_search_call 条目＋移除 web_search 工具声明（I15：消除「completed 无结果」空转）
            stripWebSearch(&payload)
            // 兜底：万一仍有 web_search_call 残留（如未来放开剥离），query 单数 → queries 数组，
            // 防 DeepSeek /responses 反序列化整单 422（missing field `queries`）
            normalizeWebSearchQueries(&payload)
        },
    ]

    /// 按目标供应商归一化请求体；无匹配规则＝原样返回
    public static func normalize(_ payload: [String: Any], host: String) -> [String: Any] {
        let h = host.lowercased()
        var out = payload
        for r in rules where h.hasSuffix(r.hostSuffix) {
            r.apply(&out)
        }
        return out
    }

    /// 剥离搜索相关内容：input[] 中 type=web_search_call 的条目；tools[] 中 type=web_search 的声明
    /// （tools 清空则整键移除，避免空数组边界）。其余条目与工具不动。
    public static func stripWebSearch(_ payload: inout [String: Any]) {
        if let input = payload["input"] as? [Any] {
            let kept = input.filter { ($0 as? [String: Any])?["type"] as? String != "web_search_call" }
            if kept.count != input.count { payload["input"] = kept }
        }
        if let tools = payload["tools"] as? [Any] {
            let kept = tools.filter { ($0 as? [String: Any])?["type"] as? String != "web_search" }
            if kept.count != tools.count {
                if kept.isEmpty { payload.removeValue(forKey: "tools") }
                else { payload["tools"] = kept }
            }
        }
    }

    /// web_search_call.action.query（单数）→ queries=[query]（只发 queries）；
    /// 已是 queries 或无 query 键不动；input 非数组（纯文本形态）不动；其余条目不动。
    public static func normalizeWebSearchQueries(_ payload: inout [String: Any]) {
        guard var input = payload["input"] as? [Any] else { return }
        var changed = false
        for i in input.indices {
            guard var item = input[i] as? [String: Any],
                  item["type"] as? String == "web_search_call",
                  var action = item["action"] as? [String: Any],
                  let q = action["query"] as? String,
                  action["queries"] == nil else { continue }
            action.removeValue(forKey: "query")
            action["queries"] = [q]
            item["action"] = action
            input[i] = item
            changed = true
        }
        if changed { payload["input"] = input }
    }
}
