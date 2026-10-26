import SwiftUI
import AppKit

// MARK: - 标准 JSON 代码显示器（NSTextView：语法着色＋行号槽；草稿 mr-cli-dict-refine 定稿形态）
// 替代 CLI 配置窗的 plain TextEditor；编辑语义不变——text 绑定 + SwiftUI onChange 驱动既有 dirty/校验逻辑。
// 横向不换行（长行横向滚动），显示行＝换行数，行号槽逐行对齐。
// mode=.toml 时改用 TOML 着色（R8 B 窗编辑器；行号/滚动/绑定管线与 JSON 共用）。
struct JSONCodeEditor: NSViewRepresentable {
    enum Mode { case json, toml }

    @Binding var text: String
    var mode: Mode = .json
    /// 行号槽开关（C 窗编辑列不要行号——2026-09-29 复验：编辑列只做无边界编辑，行号留给 B 窗 TOML 编辑器）
    var showLineNumbers: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.enabledTextCheckingTypes = 0   // 关闭自动文本检查/数据检测：JSON 编辑无需，且规避 linkd.autoShortcut 系统服务注册报错
        tv.drawsBackground = true
        tv.backgroundColor = .controlBackgroundColor
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.delegate = context.coordinator
        context.coordinator.observeAppearance(tv)

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = .controlBackgroundColor
        sv.documentView = tv

        if showLineNumbers {
            let ruler = LineNumberRuler(textView: tv)
            context.coordinator.ruler = ruler
            sv.hasVerticalRuler = true
            sv.verticalRulerView = ruler
            sv.rulersVisible = true
        }

        context.coordinator.refresh(tv)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? NSTextView else { return }
        guard tv.string != text else { return }
        tv.string = text   // 程序化回填（快速配置/复原/格式化）：走这里，不触发 textDidChange
        context.coordinator.refresh(tv)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONCodeEditor
        var ruler: LineNumberRuler?
        var appearanceObservation: NSKeyValueObservation?

        init(parent: JSONCodeEditor) { self.parent = parent }

        /// 深浅外观切换时整体重刷着色（自适应色板按 effectiveAppearance 解析）
        func observeAppearance(_ tv: NSTextView) {
            appearanceObservation = tv.observe(\.effectiveAppearance, options: [.new]) { [weak self] textView, _ in
                DispatchQueue.main.async { self?.refresh(textView) }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            refresh(tv)
            parent.text = tv.string
        }

        func refresh(_ tv: NSTextView) {
            switch parent.mode {
            case .json: jsonHighlightInto(tv.textStorage!)
            case .toml: tomlHighlightInto(tv.textStorage!)
            }
            ruler?.needsDisplay = true
        }
    }
}

// MARK: - JSON 语法着色（键/字符串/数字/布尔与 null/标点）
// 色板＝VS Code Dark+/Light+ 的 JSON 配色，随系统外观自适应（管理员 2026-09-24 定：采用知名 JSON 编辑器配色）
enum JSONSyntaxColor {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
            return best == .darkAqua ? dark : light
        }
    }
    static let key = adaptive(light: NSColor(srgbRed: 0x04 / 255, green: 0x51 / 255, blue: 0xA5 / 255, alpha: 1),
                              dark: NSColor(srgbRed: 0x9C / 255, green: 0xDC / 255, blue: 0xFE / 255, alpha: 1))
    static let string = adaptive(light: NSColor(srgbRed: 0xA3 / 255, green: 0x15 / 255, blue: 0x15 / 255, alpha: 1),
                                 dark: NSColor(srgbRed: 0xCE / 255, green: 0x91 / 255, blue: 0x78 / 255, alpha: 1))
    static let number = adaptive(light: NSColor(srgbRed: 0x09 / 255, green: 0x86 / 255, blue: 0x58 / 255, alpha: 1),
                                 dark: NSColor(srgbRed: 0xB5 / 255, green: 0xCE / 255, blue: 0xA8 / 255, alpha: 1))
    static let boolean = adaptive(light: NSColor(srgbRed: 0x00 / 255, green: 0x00 / 255, blue: 0xFF / 255, alpha: 1),
                                  dark: NSColor(srgbRed: 0x56 / 255, green: 0x9C / 255, blue: 0xD6 / 255, alpha: 1))
    static let punctuation = adaptive(light: NSColor(srgbRed: 0x3B / 255, green: 0x3B / 255, blue: 0x3B / 255, alpha: 1),
                                      dark: NSColor(srgbRed: 0xD4 / 255, green: 0xD4 / 255, blue: 0xD4 / 255, alpha: 1))
}

private let jsonKeyRegex = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"(?=\\s*:)")
private let jsonStringRegex = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"")
private let jsonTokenRegex = try! NSRegularExpression(
    pattern: #""(?:[^"\\]|\\.)*"(\s*:)?|\b(?:true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?|[{}\[\]:,]"#)

/// 着色色板：adaptive＝VS Code Dark+/Light+ 随外观（编辑器/字典示例块）；
/// darkPanel＝「显示」列深色面板固定色（原 highlightJSON 色值，面板恒深底不随外观）
struct JSONSyntaxPalette {
    let base: NSColor
    let key: NSColor
    let string: NSColor
    let number: NSColor
    let boolean: NSColor
    let punctuation: NSColor

    static func adaptive() -> JSONSyntaxPalette {
        JSONSyntaxPalette(base: .labelColor,
                          key: JSONSyntaxColor.key, string: JSONSyntaxColor.string,
                          number: JSONSyntaxColor.number, boolean: JSONSyntaxColor.boolean,
                          punctuation: JSONSyntaxColor.punctuation)
    }

    static let darkPanel = JSONSyntaxPalette(
        base: NSColor(srgbRed: 0.90, green: 0.90, blue: 0.93, alpha: 1),
        key: NSColor(srgbRed: 0x7C / 255, green: 0xC4 / 255, blue: 0xFF / 255, alpha: 1),
        string: NSColor(srgbRed: 0x8B / 255, green: 0xE2 / 255, blue: 0x8B / 255, alpha: 1),
        number: NSColor(srgbRed: 0xE7 / 255, green: 0xC9 / 255, blue: 0x8A / 255, alpha: 1),
        boolean: NSColor(srgbRed: 0xF0 / 255, green: 0xA3 / 255, blue: 0x5E / 255, alpha: 1),
        punctuation: NSColor(srgbRed: 0x9A / 255, green: 0x9A / 255, blue: 0xA0 / 255, alpha: 1))
}

private func jsonTokenColor(_ token: String, palette: JSONSyntaxPalette) -> NSColor {
    if token.hasPrefix("\"") {
        // 组合正则把键的冒号一起吞了：带冒号后缀的引号串 = 键
        return token.hasSuffix(":") ? palette.key : palette.string
    }
    if token == "true" || token == "false" || token == "null" { return palette.boolean }
    if token == "{" || token == "}" || token == "[" || token == "]" || token == ":" || token == "," { return palette.punctuation }
    return palette.number
}

/// 对整段 JSON 文本整体着色（单趟 O(n+m)：字符串在 alternation 首位整段吞掉，
/// 串内标点/数字天然不重复匹配——勿改回逐类扫描＋包含性检查，大文档 O(n·m) 会假死）
func jsonHighlightInto(_ storage: NSMutableAttributedString,
                       baseColor: NSColor = .labelColor,
                       font: NSFont = .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                       palette: JSONSyntaxPalette = .adaptive()) {
    let src = storage.string as NSString
    let full = NSRange(location: 0, length: src.length)
    storage.beginEditing()
    storage.setAttributes([.foregroundColor: baseColor, .font: font], range: full)
    for m in jsonTokenRegex.matches(in: storage.string as String, range: full) {
        let token = src.substring(with: m.range)
        let color = jsonTokenColor(token, palette: palette)
        storage.addAttribute(.foregroundColor, value: color, range: m.range)
    }
    storage.endEditing()
}

/// SwiftUI Text 版 JSON 着色（「显示」列用）：与 jsonHighlightInto 同规则同色板，直接产出
/// SwiftUI 原生 AttributedString。勿走 NSAttributedString→AttributedString 转换——属性落在
/// AppKit 作用域，SwiftUI Text 会渲染成空（真机已复现）。
func jsonHighlightedText(_ source: String, palette: JSONSyntaxPalette = .adaptive()) -> AttributedString {
    // 按序分段拼接（旧版 highlightJSON 同款结构）：勿改回逐命中区间赋值——
    // AttributedString 区间赋值近乎全串操作，大文档 O(n·m) 假死（1MB 样本实测 47s）
    let ns = source as NSString
    let full = NSRange(location: 0, length: ns.length)
    let base = AttributeContainer()
        .font(.system(size: 11.5).monospaced())
        .foregroundColor(Color(palette.base))
    var out = AttributedString()
    var cursor = 0
    for m in jsonTokenRegex.matches(in: source, range: full) {
        if m.range.location > cursor {
            out += AttributedString(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)),
                                    attributes: base)
        }
        let token = ns.substring(with: m.range)
        let color = jsonTokenColor(token, palette: palette)
        var seg = AttributedString(token, attributes: base)
        seg.foregroundColor = Color(nsColor: color)
        out += seg
        cursor = m.range.location + m.range.length
    }
    if cursor < ns.length {
        out += AttributedString(ns.substring(from: cursor), attributes: base)
    }
    return out
}

// MARK: - TOML 语法着色（注释/键/字符串/数字/布尔/节头；单趟组合正则，与 JSON 着色同纪律）
private let tomlTokenRegex = try! NSRegularExpression(
    pattern: ###"""
    \#.*                                    # 注释（优先，吞到行尾）
    |"""[\s\S]*?"""|'''[\s\S]*?'''           # 多行字符串
    |"(?:[^"\\\n]|\\.)*"|'(?:[^'\n])*'      # 单行字符串（基本/字面）
    |(?m)^[\t ]*\[[^\]\n]*\][\t ]*(?:\#.*)?$  # 节头整行（行首 [ … ]）
    |(?m)^[\t ]*[A-Za-z0-9_.\-"]+(?=[\t ]*=)  # 键（行首至 = 之前；含点键/引号键）
    |\b(?:true|false)\b
    |\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+\-]\d{2}:\d{2})?)?
    |-?\b\d[\d_]*(?:\.\d+)?(?:[eE][+\-]?\d+)?
    """###, options: [])

extension JSONSyntaxColor {
    /// TOML 注释色（VS Code 注释绿：Dark+ #6A9955 / Light+ #008000）
    static let comment = adaptive(light: NSColor(srgbRed: 0x00 / 255, green: 0x80 / 255, blue: 0x00 / 255, alpha: 1),
                                  dark: NSColor(srgbRed: 0x6A / 255, green: 0x99 / 255, blue: 0x55 / 255, alpha: 1))
}

/// 对整段 TOML 文本整体着色（单趟 O(n+m)：注释与字符串在 alternation 前列整段吞掉，串内符号不重复匹配）
func tomlHighlightInto(_ storage: NSMutableAttributedString,
                       baseColor: NSColor = .labelColor,
                       font: NSFont = .monospacedSystemFont(ofSize: 11.5, weight: .regular)) {
    let src = storage.string as NSString
    let full = NSRange(location: 0, length: src.length)
    let palette = JSONSyntaxPalette.adaptive()
    storage.beginEditing()
    storage.setAttributes([.foregroundColor: baseColor, .font: font], range: full)
    for m in tomlTokenRegex.matches(in: storage.string as String, range: full) {
        let token = src.substring(with: m.range)
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        let color: NSColor
        if trimmed.hasPrefix("#") {
            color = JSONSyntaxColor.comment
        } else if trimmed.hasPrefix("[") {
            color = palette.key          // 节头＝键色
        } else if token.hasPrefix("\"") || token.hasPrefix("'") {
            color = palette.string
        } else if token == "true" || token == "false" {
            color = palette.boolean
        } else if token.contains(":") || (token.count >= 10 && token.dropFirst(4).first == "-") {
            color = palette.string       // 日期时间按串色
        } else if token.first?.isNumber == true || token.first == "-" {
            color = palette.number
        } else {
            color = palette.key          // 行首至 = 的键
        }
        storage.addAttribute(.foregroundColor, value: color, range: m.range)
    }
    storage.endEditing()
}

// MARK: - 只读 JSON 显示视图（无界文本专用，如「显示」列）：NSTextView 按行绘制、长行自动换行。
// 勿用 SwiftUI Text 承载超长单行——文本会铺成一整块超宽 CALayer，超限即 bogus layer size 整层拒渲
// （真机实测 127697pt 宽被拒，「显示」栏整层空白）。
struct JSONDisplayView: NSViewRepresentable {
    let source: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var cached: String? = nil
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.drawsBackground = false
        tv.enabledTextCheckingTypes = 0   // 同编辑器：规避 linkd.autoShortcut 注册报错
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true        // 与编辑器一致：长行不折行、横向滚动（折行会堆叠难读）
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.allowsUndo = false
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.documentView = tv
        apply(source, to: tv, coordinator: context.coordinator)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        guard context.coordinator.cached != source else { return }
        apply(source, to: tv, coordinator: context.coordinator)
    }

    private func apply(_ source: String, to tv: NSTextView, coordinator: Coordinator) {
        let out = NSMutableAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: JSONSyntaxPalette.darkPanel.base,
        ])
        jsonHighlightInto(out, baseColor: JSONSyntaxPalette.darkPanel.base, palette: .darkPanel)
        tv.textStorage?.setAttributedString(out)
        coordinator.cached = source
    }
}

// MARK: - 行号槽（不换行布局：显示行＝换行行；编号按布局行片段＋视图坐标换算定位，滚动安全）
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var scrollObservation: NSKeyValueObservation?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        // 滚动即整条重绘：不依赖标尺默认的「条带补绘」，杜绝快速滚动中的行号丢失
        scrollObservation = textView.enclosingScrollView?.contentView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var requiredThickness: CGFloat {
        let digits = max(2, String(lineCount).count)
        return CGFloat(12 + digits * 7)
    }

    private var lineCount: Int {
        guard let tv = textView else { return 1 }
        return tv.string.isEmpty ? 1 : tv.string.components(separatedBy: "\n").count
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let font = tv.font, let lm = tv.layoutManager,
              let container = tv.textContainer else { return }
        NSColor.quaternaryLabelColor.withAlphaComponent(0.14).setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let sepPath = NSBezierPath()
        sepPath.move(to: NSPoint(x: bounds.maxX - 0.5, y: 0))
        sepPath.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        sepPath.stroke()

        let content = tv.string as NSString
        guard content.length > 0 else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        // 文本布局是惰性的：快速滚动时新暴露区域可能尚未布局，行片段拿不到就会缺号。
        // 先强制完成外扩两行范围（上下预渲染）的布局，再取可见行片段。
        let lineHeight = lm.defaultLineHeight(for: font)
        var visible = scrollView?.contentView.bounds ?? rect
        visible = visible.insetBy(dx: 0, dy: -lineHeight * 2)
        lm.ensureLayout(forBoundingRect: visible, in: container)
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: container)
        var lineNumber = 1
        if glyphRange.location > 0 {
            lineNumber = content.substring(with: NSRange(location: 0, length: glyphRange.location))
                .components(separatedBy: "\n").count
        }
        var glyph = glyphRange.location
        while glyph < NSMaxRange(glyphRange) {
            var fragmentGlyphs = NSRange()
            let fragmentRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
            let charRange = lm.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            if charRange.length > 0 {
                let inView = fragmentRect.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
                let inRuler = convert(inView, from: tv)
                if inRuler.maxY >= rect.minY && inRuler.minY <= rect.maxY {
                    let label = String(lineNumber) as NSString
                    let size = label.size(withAttributes: attrs)
                    label.draw(at: NSPoint(x: bounds.width - size.width - 6, y: inRuler.minY), withAttributes: attrs)
                }
                lineNumber += content.substring(with: charRange).components(separatedBy: "\n").count - 1
            }
            glyph = NSMaxRange(fragmentGlyphs)
        }
    }
}
