import Foundation

// MARK: - 受管区引擎（纯函数，无 IO）

public enum CodexRegion {
    public static let begin = "# ───── ModelRouter 受管区 开始 ─────"
    public static let end = "# ───── ModelRouter 受管区 结束 ─────"
    public static let providerHeader = "[model_providers.modelrouter]"
    public static let catalogPathValue = "~/.codex/model_modelrouter.json"

    /// 顶层受管键（受管区外散落时按需收编；model 单列——未设默认模型时不收编）。
    /// preferred_auth_method 保留在名单＝**清除**语义：R25（2026-10-03）起受管区不再写入该键
    /// （最新 Codex 不接受），旧版散落的该键在下次快速配置时被收编移除、且新模板不回填。
    public static let managedTopLevelKeys = ["model_provider", "model_catalog_json",
                                             "preferred_auth_method", "forced_login_method"]

    /// 定位受管区（begin 行首到 end 标记串尾，不含 end 行换行）。任一标记缺失返回 nil。
    public static func findRange(in text: String) -> Range<String.Index>? {
        guard let b = text.range(of: begin) else { return nil }
        guard let e = text.range(of: end, range: b.upperBound..<text.endIndex) else { return nil }
        return b.lowerBound..<e.upperBound
    }

    public static func hasRegion(_ text: String) -> Bool { findRange(in: text) != nil }

    /// 构建受管区标准块（defaultModel 为空则不写 model 行）。
    /// R25（2026-10-03 管理员）：不再写入 preferred_auth_method——最新版 Codex 已不接受该键。
    public static func build(defaultModel: String?, baseURL: String, token: String) -> String {
        var lines = [begin,
                     "# 此区域由 ModelRouter 写入维护；用户亦可修改，下次快速配置将整区覆盖"]
        if let m = defaultModel, !m.isEmpty { lines.append("model = \(tomlString(m))") }
        lines += ["model_provider = \"modelrouter\"",
                  "model_catalog_json = \"\(catalogPathValue)\"",
                  "forced_login_method = \"api\"",
                  "",
                  providerHeader,
                  "name = \"ModelRouter\"",
                  "base_url = \(tomlString(baseURL))",
                  "wire_api = \"responses\"",
                  "experimental_bearer_token = \(tomlString(token))",
                  end]
        return lines.joined(separator: "\n")
    }

    /// 整区替换；无受管区时插入到**顶层区末尾**（首个节头行之前；无节则文件尾）。
    /// 不插文件顶部：受管区自带 [model_providers.modelrouter] 节头，顶部插入会把既有用户顶层键吞进该节（TOML 节语义）。
    public static func replace(_ text: String, block: String) -> String {
        if let r = findRange(in: text) {
            return text[..<r.lowerBound] + block + text[r.upperBound...]
        }
        let lines = text.components(separatedBy: "\n")
        if let first = firstSectionHeaderLine(in: lines) {
            let prefix = first == 0 ? "" : lines[..<first].joined(separator: "\n") + "\n"
            let suffix = lines[first...].joined(separator: "\n")
            return prefix + block + "\n\n" + suffix
        }
        if text.isEmpty { return block }
        let t = text.hasSuffix("\n") ? text : text + "\n"
        return t + "\n" + block
    }

    /// 字典「＋ 添加」的骨架插入（纯文本手术）：节键骨架追加文件尾；顶层键插至顶层区末尾（首个节头前）。
    /// 受管区在场时顶层骨架插到受管区**之前**（顶层区语义止于受管区自带的节头，且不得落入受管区内）。
    /// 节头已在文件中时只补子键行（同节多次添加不产生重复表定义）。
    public static func insertSkeleton(_ text: String, skeleton: String, isSection: Bool) -> String {
        let skelLines = skeleton.components(separatedBy: "\n")
        if isSection {
            let header = skelLines[0]
            let subLines = Array(skelLines.dropFirst())
            var out = text.components(separatedBy: "\n")
            if let idx = out.firstIndex(of: header) {
                guard !subLines.isEmpty else { return text }
                out.insert(contentsOf: subLines, at: idx + 1)
                return out.joined(separator: "\n")
            }
            if text.isEmpty { return skeleton }
            let t = text.hasSuffix("\n") ? text : text + "\n"
            return t + "\n" + skeleton
        }
        if let r = findRange(in: text) {
            return String(text[..<r.lowerBound]) + skeleton + "\n\n" + String(text[r.lowerBound...])
        }
        let lines = text.components(separatedBy: "\n")
        if let first = firstSectionHeaderLine(in: lines) {
            let prefix = first == 0 ? "" : lines[..<first].joined(separator: "\n") + "\n"
            let suffix = lines[first...].joined(separator: "\n")
            return prefix + skeleton + "\n\n" + suffix
        }
        if text.isEmpty { return skeleton }
        let t = text.hasSuffix("\n") ? text : text + "\n"
        return t + "\n" + skeleton
    }

    /// 首个节头行号（[x] / [[x]]；跳过多行字符串内的形似行）；无则 nil。
    private static func firstSectionHeaderLine(in lines: [String]) -> Int? {
        var inBasic = false, inLiteral = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inBasic || inLiteral {
                if inBasic && line.contains("\"\"\"") { inBasic = false }
                if inLiteral && line.contains("'''") { inLiteral = false }
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") && line.count > 2 {
                return i
            }
            // 同行开启多行字符串（奇数个定界符）则进入字符串态，其中的形似节头行不参与检测
            if line.components(separatedBy: "\"\"\"").count > 1,
               (line.components(separatedBy: "\"\"\"").count - 1) % 2 == 1 { inBasic = true }
            if line.components(separatedBy: "'''").count > 1,
               (line.components(separatedBy: "'''").count - 1) % 2 == 1 { inLiteral = true }
        }
        return nil
    }

    /// 移除受管区（半复原的副本操作）；余文首部空行收拢。
    public static func remove(_ text: String) -> String {
        guard let r = findRange(in: text) else { return text }
        let out = text[..<r.lowerBound] + text[r.upperBound...]
        return String(out.drop { $0 == "\n" })
    }

    /// 受管区内的键值（顶层键＋[model_providers.modelrouter] 子键，展平为字符串）。
    /// 区缺失或区内 TOML 不合法 → nil（调用方按未就绪处理）。
    public static func values(in text: String) -> [String: String]? {
        guard let r = findRange(in: text) else { return nil }
        let slice = String(text[r])
        guard let doc = try? TomlLite.parse(slice) else { return nil }
        var out: [String: String] = [:]
        for (k, v) in doc { out[k] = scalarText(v) }
        if let provider = doc["model_providers"] as? [String: Any],
           let mr = provider["modelrouter"] as? [String: Any] {
            for (k, v) in mr { out[k] = scalarText(v) }
        }
        return out
    }

    /// 受管区当前 model 键值（B 窗首启继承默认模型行用）。
    public static func defaultModel(in text: String) -> String? {
        values(in: text)?["model"]
    }

    /// 语义比对：受管区在且逐键实际值与期望值一致（model 随默认模型，未设＝区内无 model 键）。
    public static func isSettled(_ text: String, defaultModel: String?, baseURL: String, token: String) -> Bool {
        guard let got = values(in: text) else { return false }
        var expect: [String: String] = [
            "model_provider": "modelrouter",
            "model_catalog_json": catalogPathValue,
            "forced_login_method": "api",
            "name": "ModelRouter",
            "base_url": baseURL,
            "wire_api": "responses",
            "experimental_bearer_token": token,
        ]
        if let m = defaultModel, !m.isEmpty { expect["model"] = m }
        for (k, want) in expect where got[k] != want { return false }
        if defaultModel == nil || defaultModel?.isEmpty == true {
            if got["model"] != nil { return false }   // 未设默认模型：区内不应有 model 键
        }
        // R25（2026-10-03）：区内残留 preferred_auth_method 即未就绪（最新 Codex 不接受该键）——
        // 存量旧区由此点亮快速配置，整区重写后自愈清除（与上方 model 键负校验同款先例）
        if got["preferred_auth_method"] != nil { return false }
        return true
    }

    /// 快速配置纯函数：整区替换 + 区外散键收编（返回新文本；IO 由调用方走 save 阶梯）。
    public static func applyQuick(_ text: String, defaultModel: String?, baseURL: String, token: String) -> String {
        let replaced = replace(text, block: build(defaultModel: defaultModel, baseURL: baseURL, token: token))
        return stripStray(replaced, includeModel: !(defaultModel?.isEmpty ?? true))
    }

    /// 区外散键收编：移除顶层散落的受管键行与既有 [model_providers.modelrouter] 整节（避免 TOML 重复键非法）；
    /// includeModel=false 时不动区外 model（那是用户自己的默认模型）。受管区内行不动；其余逐字节保留。
    public static func stripStray(_ text: String, includeModel: Bool) -> String {
        var strip = Set(managedTopLevelKeys)
        if includeModel { strip.insert("model") }
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var inRegion = false
        var inTopLevel = true
        var skippingProvider = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == begin { inRegion = true; out.append(line); i += 1; continue }
            if t == end { inRegion = false; out.append(line); i += 1; continue }
            if inRegion { out.append(line); i += 1; continue }

            if t.hasPrefix("[") && t.hasSuffix("]") && t.count > 2 {
                inTopLevel = false
                if t == providerHeader {
                    skippingProvider = true
                    i += 1
                    continue
                }
                skippingProvider = false
                out.append(line)
                i += 1
                continue
            }
            if skippingProvider { i += 1; continue }

            if inTopLevel, let key = topLevelKey(of: line), strip.contains(key) {
                // 值为多行结构（多行字符串/数组）时连同续行一并收编，避免留下半截语法
                if let consumed = multilineContinuation(from: lines, at: i) {
                    i = consumed
                    continue
                }
                i += 1
                continue
            }
            out.append(line)
            i += 1
        }
        return out.joined(separator: "\n")
    }

    /// 级联改名的受管区 model 行外科改写：区内 model = "<old>" → model = "<new>"，其余不动。
    /// 无受管区或值不等于 old → nil（不动文件）。
    public static func rewriteModelLine(_ text: String, from old: String, to new: String) -> String? {
        guard let r = findRange(in: text) else { return nil }
        let oldLine = "model = \(tomlString(old))"
        let newLine = "model = \(tomlString(new))"
        let slice = String(text[r])
        guard slice.contains(oldLine + "\n") || slice.hasSuffix(oldLine) else { return nil }
        let newSlice = slice.replacingOccurrences(of: oldLine, with: newLine)
        return text[..<r.lowerBound] + newSlice + text[r.upperBound...]
    }

    /// 顶层赋值行的键名（裸键或基本字符串键）；非赋值行/含注释前缀返回 nil。
    private static func topLevelKey(of line: String) -> String? {
        guard let eq = firstEqOutsideComment(line) else { return nil }
        let keyPart = line[..<eq].trimmingCharacters(in: .whitespaces)
        if keyPart.isEmpty { return nil }
        if keyPart.hasPrefix("\"") && keyPart.hasSuffix("\"") && keyPart.count >= 2 {
            return String(keyPart.dropFirst().dropLast())
        }
        if keyPart.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) { return keyPart }
        return nil   // 点键（a.b = …）不属于本函数处理的单键收编范围
    }

    private static func firstEqOutsideComment(_ line: String) -> String.Index? {
        var inBasic = false, inLiteral = false
        var prev: Character = " "
        for idx in line.indices {
            let c = line[idx]
            if inBasic {
                if c == "\"" && prev != "\\" { inBasic = false }
            } else if inLiteral {
                if c == "'" { inLiteral = false }
            } else if c == "\"" {
                inBasic = true
            } else if c == "'" {
                inLiteral = true
            } else if c == "#" {
                return nil   // 注释先行，本行无赋值
            } else if c == "=" {
                return idx
            }
            prev = c
        }
        return nil
    }

    /// 判断 lines[at] 的值部分是否开启未闭合多行结构；是则返回消费后的下一行号。
    private static func multilineContinuation(from lines: [String], at index: Int) -> Int? {
        let line = lines[index]
        guard let eq = firstEqOutsideComment(line) else { return nil }
        let value = String(line[line.index(after: eq)...])
        let basic3 = value.components(separatedBy: "\"\"\"").count - 1
        let literal3 = value.components(separatedBy: "'''").count - 1
        var bracketBalance = 0
        var inBasic = false, inLiteral = false
        var prev: Character = " "
        for c in value {
            if inBasic {
                if c == "\"" && prev != "\\" { inBasic = false }
            } else if inLiteral {
                if c == "'" { inLiteral = false }
            } else if c == "\"" {
                inBasic = true
            } else if c == "'" {
                inLiteral = true
            } else if c == "[" { bracketBalance += 1 } else if c == "]" { bracketBalance -= 1 }
            prev = c
        }
        if basic3 % 2 == 1 || literal3 % 2 == 1 || bracketBalance > 0 {
            var j = index + 1
            while j < lines.count {
                let l = lines[j]
                if basic3 % 2 == 1 {
                    if l.components(separatedBy: "\"\"\"").count >= 2 { return j + 1 }
                } else if literal3 % 2 == 1 {
                    if l.components(separatedBy: "'''").count >= 2 { return j + 1 }
                } else {
                    let open = l.filter { $0 == "[" }.count
                    let close = l.filter { $0 == "]" }.count
                    bracketBalance += open - close
                    if bracketBalance <= 0 { return j + 1 }
                }
                j += 1
            }
            return lines.count
        }
        return nil
    }

    /// TOML 基本字符串字面量（转义反斜杠与双引号）
    static func tomlString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func scalarText(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let b = v as? Bool { return b ? "true" : "false" }
        return String(describing: v)
    }
}
