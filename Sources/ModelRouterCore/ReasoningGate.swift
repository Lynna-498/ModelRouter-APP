import Foundation

// MARK: - 思考等级闸门（S4 裁定附带需求 R21）：enabled-reasoning-efforts 须覆盖全部模型元数据档位并集
// 字段为 Codex Desktop 侧实测配置（官方 config-reference/schema 均未记载，拼写按管理员 2026-10-02 提供）。

public enum ReasoningGate {
    public static let effortsKey = "enabled-reasoning-efforts"
    /// 「设置思考模式」按键写入的完整档位行（六档全量）
    public static let presetLine = "enabled-reasoning-efforts = [\"low\", \"medium\", \"high\", \"xhigh\", \"ultra\", \"max\"]"

    /// 各模型 codexMetaJSON 的 supported_reasoning_levels.effort 并集（排序稳定；无元数据/解析失败＝空贡献）
    public static func requiredEfforts(metaJSONs: [String?]) -> [String] {
        var set = Set<String>()
        for raw in metaJSONs {
            guard let raw, let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let levels = obj["supported_reasoning_levels"] as? [[String: Any]] else { continue }
            for lv in levels where lv["effort"] is String {
                set.insert(lv["effort"] as! String)
            }
        }
        return set.sorted()
    }

    /// TOML 中 **[desktop] 节内**的 enabled-reasoning-efforts 值（缺失/形态异常 → nil）。
    /// 字段真实位置＝[desktop] 节（2026-10-02 管理员更正；顶层同名键对该字段无效、不参与判定）
    public static func enabledEfforts(toml: String) -> [String]? {
        guard let doc = try? TomlLite.parse(toml),
              let desktop = doc["desktop"] as? [String: Any],
              let arr = desktop[effortsKey] as? [Any] else { return nil }
        return arr.compactMap { $0 as? String }
    }

    /// 闸门：nil＝通过；非 nil＝红字文案（保存被阻止）。元数据无档位需求时恒通过。
    public static func check(toml: String, metaJSONs: [String?]) -> String? {
        let required = requiredEfforts(metaJSONs: metaJSONs)
        guard !required.isEmpty else { return nil }
        let enabled = Set(enabledEfforts(toml: toml) ?? [])
        guard !required.allSatisfy({ enabled.contains($0) }) else { return nil }
        let missing = required.filter { !enabled.contains($0) }
        if enabled.isEmpty {
            return "未设置 \(effortsKey)：模型思考档位（\(required.joined(separator: "、"))）会缺失——点「设置思考模式」写入后重试"
        }
        return "\(effortsKey) 未覆盖模型思考档位：缺 \(missing.joined(separator: "、"))（需含 \(required.joined(separator: "、"))）——点「设置思考模式」写入完整档位"
    }

    /// 「设置思考模式」：完整档位行写入 **[desktop] 节内**（2026-10-02 管理员更正落位）——
    /// 节内已有该键则原位替换；节在而无键则插至节内末行；节不存在则文件尾新建节（节键骨架规则）。
    /// 同时清除顶层同名散键（首版误写顶层的遗留，顶层键对本字段无效）。
    /// 豁免由此成立：[desktop] 为用户节，永不属于受管区，快速配置（整区覆盖、用户区不动）
    /// 与恢复 OpenAI 登录（只删受管区）都不触碰它。
    public static func applyPresetEfforts(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // 0) 清顶层散键（顶层区＝首个节头之前）
        var topEnd = lines.count
        for (i, raw) in lines.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") && t.hasSuffix("]") && t.count > 2 { topEnd = i; break }
        }
        var cleaned: [String] = []
        for (i, line) in lines.enumerated() {
            if i < topEnd {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(effortsKey),
                   t.dropFirst(effortsKey.count).trimmingCharacters(in: .whitespaces).hasPrefix("=") { continue }
            }
            cleaned.append(line)
        }
        lines = cleaned
        // 1) 定位 [desktop] 节
        var desktopHeader = -1
        for (i, raw) in lines.enumerated() where raw.trimmingCharacters(in: .whitespaces) == "[desktop]" {
            desktopHeader = i
            break
        }
        if desktopHeader >= 0 {
            var nextSec = lines.count
            for i in (desktopHeader + 1)..<lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[") && t.hasSuffix("]") && t.count > 2 { nextSec = i; break }
            }
            // 节内既有键 → 原位替换
            for i in (desktopHeader + 1)..<nextSec {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(effortsKey),
                   t.dropFirst(effortsKey.count).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                    lines[i] = presetLine
                    return lines.joined(separator: "\n")
                }
            }
            // 节内无键 → 插至节内末行（跳过节尾空行）
            var insertAt = nextSec
            while insertAt > desktopHeader + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(presetLine, at: insertAt)
            return lines.joined(separator: "\n")
        }
        // 2) 无 [desktop] 节：文件尾新建
        let base = lines.joined(separator: "\n")
        if base.isEmpty { return "[desktop]\n" + presetLine }
        return (base.hasSuffix("\n") ? base : base + "\n") + "\n[desktop]\n" + presetLine
    }
}
