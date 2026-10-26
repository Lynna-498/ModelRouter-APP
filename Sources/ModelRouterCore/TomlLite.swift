import Foundation


// MARK: - TOML 子集解析器
// 用途：①写前语法校验（失败中止）②脏态语义比对（解析结果深层 isEqual，纯格式化不计脏）③受管区取值。
// 支持：注释、[节] 与 [[节数组]]、点键与带引号键、基本/字面字符串（含多行）、整数（_ 与 0x/0o/0b）、
// 浮点、布尔、日期时间（按字符串保留）、数组（含多行嵌套与尾逗号）、内联表。重复键/重复表头 → 解析失败。
public enum TomlLite {
    public struct ParseError: Error, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "TOML 第 \(line) 行：\(message)" }
    }

    public static func parse(_ text: String) throws -> [String: Any] {
        let c = Cursor(text)
        let root = NSMutableDictionary()
        var current: NSMutableDictionary = root
        var explicitTables = Set<String>()
        var arrayTables = Set<String>()

        while true {
            c.skipTrivia()
            if c.atEnd { break }
            if c.peek == "[" {
                _ = c.next()
                let isArray = c.peek == "["
                if isArray { _ = c.next() }
                let path = try c.keyPath()
                try c.expectClose("]", doubled: isArray)
                try c.endOfLine()
                let canonical = path.joined(separator: "\u{1F}")
                if isArray {
                    arrayTables.insert(canonical)
                    current = try descendArray(path, root: root, line: c.line)
                } else {
                    if explicitTables.contains(canonical), !arrayTables.contains(canonical) {
                        throw c.err("重复定义表 [\(path.joined(separator: "."))]")
                    }
                    explicitTables.insert(canonical)
                    current = try descend(path, root: root, line: c.line)
                }
            } else {
                let path = try c.keyPath()
                try c.expect("=")
                let value = try c.value()
                try c.endOfLine()
                try assign(path, value, into: current, line: c.line)
            }
        }
        guard let dict = root as? [String: Any] else { throw ParseError(line: 1, message: "内部错误：根表转换失败") }
        return dict
    }

    // MARK: 赋值与下探

    private static func assign(_ path: [String], _ value: Any,
                               into table: NSMutableDictionary, line: Int) throws {
        var t = table
        for (idx, seg) in path.enumerated() {
            let isLast = idx == path.count - 1
            if isLast {
                if t[seg] != nil { throw ParseError(line: line, message: "重复定义键 \(seg)") }
                t[seg] = value
            } else if let next = t[seg] as? NSMutableDictionary {
                t = next
            } else if let arr = t[seg] as? NSMutableArray, let last = arr.lastObject as? NSMutableDictionary {
                t = last
            } else if t[seg] == nil {
                let n = NSMutableDictionary()
                t[seg] = n
                t = n
            } else {
                throw ParseError(line: line, message: "键 \(seg) 已是非表值，无法下探")
            }
        }
    }

    private static func descend(_ path: [String], root: NSMutableDictionary, line: Int) throws -> NSMutableDictionary {
        var t = root
        for (idx, seg) in path.enumerated() {
            let isLast = idx == path.count - 1
            if let next = t[seg] as? NSMutableDictionary {
                t = next
            } else if let arr = t[seg] as? NSMutableArray {
                if isLast {
                    throw ParseError(line: line, message: "[\(path.joined(separator: "."))] 与既有数组表冲突")
                }
                guard let last = arr.lastObject as? NSMutableDictionary else {
                    throw ParseError(line: line, message: "表路径 \(seg) 结构异常")
                }
                t = last
            } else if t[seg] == nil {
                let n = NSMutableDictionary()
                t[seg] = n
                t = n
            } else {
                throw ParseError(line: line, message: "键 \(seg) 已是非表值，无法定义子表")
            }
        }
        return t
    }

    private static func descendArray(_ path: [String], root: NSMutableDictionary, line: Int) throws -> NSMutableDictionary {
        guard !path.isEmpty else { throw ParseError(line: line, message: "空表头") }
        let t = try descend(Array(path.dropLast()), root: root, line: line)
        let seg = path.last!
        if let arr = t[seg] as? NSMutableArray {
            let n = NSMutableDictionary()
            arr.add(n)
            return n
        }
        if t[seg] != nil {
            throw ParseError(line: line, message: "[[\(path.joined(separator: "."))]] 与既有键 \(seg) 冲突")
        }
        let arr = NSMutableArray()
        let n = NSMutableDictionary()
        arr.add(n)
        t[seg] = arr
        return n
    }

    // MARK: 光标

    private final class Cursor {
        private let chars: [Character]
        private var i = 0
        var line = 1

        init(_ s: String) { chars = Array(s) }
        var atEnd: Bool { i >= chars.count }
        var peek: Character? { i < chars.count ? chars[i] : nil }

        @discardableResult
        func next() -> Character? {
            guard i < chars.count else { return nil }
            let c = chars[i]
            i += 1
            if c == "\n" { line += 1 }
            return c
        }

        func skipSpaces() {
            while peek == " " || peek == "\t" { _ = next() }
        }

        /// 跨行 trivia：空白、换行、整行注释
        func skipTrivia() {
            while let c = peek {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { _ = next() }
                else if c == "#" { while let x = peek, x != "\n" { _ = next() } }
                else { break }
            }
        }

        func err(_ m: String) -> ParseError { ParseError(line: line, message: m) }

        func expect(_ ch: Character) throws {
            skipSpaces()
            guard peek == ch else { throw err("期望 '\(ch)'，实际\(peek.map { " '\($0)'" } ?? "到达末尾")") }
            _ = next()
        }

        func expectClose(_ ch: Character, doubled: Bool) throws {
            try expect(ch)
            if doubled { try expect(ch) }
        }

        /// 行尾：允许尾注释与 \r\n；非行尾字符 → 失败（值后多余内容）
        func endOfLine() throws {
            skipSpaces()
            if peek == "#" { while let x = peek, x != "\n" { _ = next() } }
            if peek == "\r" { _ = next() }
            if peek == "\n" { _ = next(); return }
            if !atEnd { throw err("行尾有多余内容") }
        }

        func keyPath() throws -> [String] {
            var segs: [String] = []
            while true {
                skipSpaces()
                guard let c = peek else { throw err("键名为空") }
                if c == "\"" { segs.append(try basicString(singleLine: true)) }
                else if c == "'" { segs.append(try literalString(singleLine: true)) }
                else {
                    var k = ""
                    while let x = peek, x.isLetter || x.isNumber || x == "_" || x == "-" {
                        k.append(x)
                        _ = next()
                    }
                    guard !k.isEmpty else { throw err("键名含非法字符") }
                    segs.append(k)
                }
                skipSpaces()
                if peek == "." { _ = next(); continue }
                break
            }
            return segs
        }

        // MARK: 值

        func value() throws -> Any {
            skipSpaces()
            guard let c = peek else { throw err("缺少值") }
            switch c {
            case "\"": return try basicStringValue()
            case "'": return try literalStringValue()
            case "[": return try arrayValue()
            case "{": return try inlineTableValue()
            default: return try scalarValue()
            }
        }

        /// 基本字符串；三引号 → 多行
        private func basicStringValue() throws -> String {
            if hasPrefix(after: 0, "\"\"\"") { return try multilineBasic() }
            return try basicString(singleLine: false)
        }

        private func literalStringValue() throws -> String {
            if hasPrefix(after: 0, "'''") { return try multilineLiteral() }
            return try literalString(singleLine: false)
        }

        private func hasPrefix(after offset: Int, _ s: String) -> Bool {
            guard i + offset <= chars.count else { return false }
            let sub = chars[(i + offset)...].prefix(s.count)
            return String(sub) == s
        }

        func basicString(singleLine: Bool) throws -> String {
            _ = next()   // 开头 "
            var out = ""
            while let c = next() {
                if c == "\"" { return out }
                if c == "\\" {
                    guard let e = next() else { throw err("转义序列不完整") }
                    switch e {
                    case "b": out.append("\u{08}")
                    case "t": out.append("\t")
                    case "n": out.append("\n")
                    case "f": out.append("\u{0C}")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "u": out.append(try unicodeHex(4))
                    case "U": out.append(try unicodeHex(8))
                    default: throw err("非法转义 \\\(e)")
                    }
                } else if c == "\n" {
                    throw err("单行字符串内出现换行")
                } else {
                    out.append(c)
                }
            }
            throw err("字符串未闭合")
        }

        private func multilineBasic() throws -> String {
            _ = next(); _ = next(); _ = next()   // 开头 """
            if peek == "\r" { _ = next() }
            if peek == "\n" { _ = next() }       // 紧跟换行属定界符，不计入内容
            var out = ""
            while true {
                guard let c = next() else { throw err("多行字符串未闭合") }
                if c == "\"" && hasPrefix(after: 0, "\"\"") {
                    _ = next(); _ = next()
                    return out
                }
                if c == "\\" {
                    guard let e = next() else { throw err("转义序列不完整") }
                    switch e {
                    case "b": out.append("\u{08}")
                    case "t": out.append("\t")
                    case "n": out.append("\n")
                    case "f": out.append("\u{0C}")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "u": out.append(try unicodeHex(4))
                    case "U": out.append(try unicodeHex(8))
                    case " ", "\t", "\r", "\n":
                        // 行尾反斜杠：吃掉后续空白（含换行），内容拼接
                        while let x = peek, x == " " || x == "\t" || x == "\r" || x == "\n" { _ = next() }
                    default: throw err("非法转义 \\\(e)")
                    }
                } else {
                    out.append(c)
                }
            }
        }

        func literalString(singleLine: Bool) throws -> String {
            _ = next()   // 开头 '
            var out = ""
            while let c = next() {
                if c == "'" { return out }
                if c == "\n" && singleLine { throw err("单行字符串内出现换行") }
                out.append(c)
            }
            throw err("字符串未闭合")
        }

        private func multilineLiteral() throws -> String {
            _ = next(); _ = next(); _ = next()
            if peek == "\r" { _ = next() }
            if peek == "\n" { _ = next() }
            var out = ""
            while true {
                guard let c = next() else { throw err("多行字符串未闭合") }
                if c == "'" && hasPrefix(after: 0, "''") {
                    _ = next(); _ = next()
                    return out
                }
                out.append(c)
            }
        }

        private func unicodeHex(_ n: Int) throws -> Character {
            var hex = ""
            for _ in 0..<n {
                guard let c = next() else { throw err("Unicode 转义不完整") }
                hex.append(c)
            }
            guard let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) else {
                throw err("非法 Unicode 转义 \\U\(hex)")
            }
            return Character(sc)
        }

        private func arrayValue() throws -> Any {
            _ = next()   // [
            var out: [Any] = []
            while true {
                skipTrivia()
                if peek == "]" { _ = next(); return out }
                guard !atEnd else { throw err("数组未闭合") }
                out.append(try value())
                skipTrivia()
                if peek == "," { _ = next(); continue }
                if peek == "]" { _ = next(); return out }
                throw err("数组元素后缺 ',' 或 ']'")
            }
        }

        private func inlineTableValue() throws -> Any {
            _ = next()   // {
            let dict = NSMutableDictionary()
            skipSpaces()
            if peek == "}" { _ = next(); return dict }
            while true {
                skipSpaces()
                let path = try keyPath()
                try expect("=")
                let v = try value()
                try TomlLite.assign(path, v, into: dict, line: line)
                skipSpaces()
                if peek == "," { _ = next(); continue }
                if peek == "}" { _ = next(); return dict }
                throw err("内联表元素后缺 ',' 或 '}'")
            }
        }

        /// 标量：布尔 / 数字 / 日期时间（日期时间按原文保留为字符串）
        private func scalarValue() throws -> Any {
            var tok = ""
            while let c = peek, !(c == " " || c == "\t" || c == "\n" || c == "\r" || c == "," || c == "]" || c == "}" || c == "#") {
                tok.append(c)
                _ = next()
            }
            guard !tok.isEmpty else { throw err("缺少值") }
            if tok == "true" { return true }
            if tok == "false" { return false }
            // 日期时间：含冒号，或 YYYY-MM-DD 形态（本地时间/偏移/空格分隔变体按字符串保留）
            if tok.contains(":") { return tok }
            if isDateOnly(tok), let withTime = tryTimeSuffix() { return tok + " " + withTime }
            if isDateOnly(tok) { return tok }
            if tok.hasPrefix("0x") || tok.hasPrefix("0o") || tok.hasPrefix("0b") {
                let radix: [String: Int] = ["0x": 16, "0o": 8, "0b": 2]
                let r = radix[String(tok.prefix(2))]!
                guard let v = Int64(tok.dropFirst(2), radix: r) else { throw err("非法整数 \(tok)") }
                return NSNumber(value: v)
            }
            let plain = tok.replacingOccurrences(of: "_", with: "")
            if plain.hasSuffix("inf") || plain.hasSuffix("nan") {
                let negative = plain.hasPrefix("-")
                let body = plain.hasPrefix("+") || negative ? String(plain.dropFirst()) : plain
                switch body {
                case "inf": return NSNumber(value: negative ? -Double.infinity : Double.infinity)
                case "nan": return NSNumber(value: Double.nan)
                default: throw err("非法数值 \(tok)")
                }
            }
            if let v = Int64(plain) { return NSNumber(value: v) }
            if let v = Double(plain) { return NSNumber(value: v) }
            throw err("无法识别的值 \(tok)")
        }

        private func isDateOnly(_ s: String) -> Bool {
            let parts = s.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return false }
            let y = parts[0], m = parts[1]
            guard y.count == 4, y.allSatisfy(\.isNumber), m.count == 2, m.allSatisfy(\.isNumber) else { return false }
            let d = parts[2]
            return d.count >= 2 && d.prefix(2).allSatisfy(\.isNumber)
        }

        /// TOML 允许日期与时间以单个空格分隔（1979-05-27 07:32:00）：日期 token 后前瞻消费时间部分。
        /// 匹配失败则回退光标（该空格属普通 trivia，交给上层处理）。
        private func tryTimeSuffix() -> String? {
            let saveI = i, saveLine = line
            skipSpaces()
            guard peek?.isNumber == true else { i = saveI; line = saveLine; return nil }
            var tok = ""
            while let c = peek, !(c == " " || c == "\t" || c == "\n" || c == "\r" || c == "," || c == "]" || c == "}" || c == "#") {
                tok.append(c)
                _ = next()
            }
            guard tok.contains(":"), tok.firstIndex(where: { $0 == ":" }) == tok.index(tok.startIndex, offsetBy: 2) else {
                i = saveI; line = saveLine
                return nil
            }
            return tok
        }
    }
}
