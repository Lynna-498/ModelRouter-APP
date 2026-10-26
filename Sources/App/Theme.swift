import SwiftUI
import AppKit
import ModelRouterCore

// MARK: - 主题（对齐交互原型 v0.13：品牌色固定，中性色随系统明暗）
let accent = Color(red: 0x0A / 255, green: 0x72 / 255, blue: 0xE6 / 255)   // #0a72e6
let okColor = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)   // #34c759
let errColor = Color(red: 0xFF / 255, green: 0x3B / 255, blue: 0x30 / 255)  // #ff3b30
let warnColor = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255) // #ff9f0a
let anthColor = Color(red: 0xC0 / 255, green: 0x5F / 255, blue: 0x2C / 255) // #c05f2c
let openColor = Color(red: 0x12 / 255, green: 0xA5 / 255, blue: 0x94 / 255) // #12a594
let keyAccent = Color(red: 0.49, green: 0.77, blue: 1.0)   // 字典键名蓝（各配置窗字典行共用；沿用量测原值，0–1 直值）

let cardBg = Color(NSColor.textBackgroundColor)
let winBg = Color(NSColor.windowBackgroundColor)
let sidebarBg = Color(NSColor.windowBackgroundColor).opacity(0.72)
let sep = Color(NSColor.separatorColor)
let ink2 = Color(NSColor.secondaryLabelColor)
let ink3 = Color(NSColor.tertiaryLabelColor)

// 监视器终端配色（固定深色，与明暗模式无关）
let termBg = Color(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1C / 255)
let termBarBg = Color(red: 0x21 / 255, green: 0x22 / 255, blue: 0x29 / 255)
let termBorder = Color(red: 0x2C / 255, green: 0x2D / 255, blue: 0x33 / 255)
let termText = Color(red: 0xC9 / 255, green: 0xCA / 255, blue: 0xD1 / 255)
let termDim = Color(red: 0x6F / 255, green: 0x70 / 255, blue: 0x79 / 255)
let termOk = Color(red: 0x7E / 255, green: 0xE2 / 255, blue: 0xA8 / 255)
let termBad = Color(red: 0xFF / 255, green: 0x7B / 255, blue: 0x72 / 255)
let termWarn = Color(red: 0xF5 / 255, green: 0xC9 / 255, blue: 0x7B / 255)

func f(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

// MARK: - 接入可用性（模型 × API 线）
enum Avail: Equatable { case ok; case off(String); case untested }

// MARK: - 端点/模型检测结论（UI 展示用；来源：EndpointPresenceCheck 与两个 APICheck）
enum ProbePhase: Equatable {
    case running
    case ok
    case authFail
    case modelNotFound
    case pathNotSupported
    case protocolMismatch
    case rateLimited
    case bad(Int)
    case unreachable
    case offline          // 本机无网络连接
    case noKey            // 供应商未配置 Key

    var label: String {
        switch self {
        case .running: return "检测中…"
        case .ok: return "可用 · 返回了真实 Token"
        case .authFail: return "认证失败 · 到供应商管理改 Key 后重探"
        case .modelNotFound: return "模型不被接受 · 端点与 Key 正常"
        case .pathNotSupported: return "该端点未开放此 API"
        case .protocolMismatch: return "响应不是该协议格式"
        case .rateLimited: return "限流 · 稍后重探"
        case .bad(let c): return "HTTP \(c) · 未通过"
        case .unreachable: return "不可达 · 可重探"
        case .offline: return "网络未连接"
        case .noKey: return "未配置 Key"
        }
    }
    var passed: Bool { self == .ok }
    /// 徽标里的短原因（pass 时无需）
    var shortReason: String {
        switch self {
        case .running: return "检测中…"
        case .authFail: return "认证失败"
        case .modelNotFound: return "模型不被接受"
        case .pathNotSupported: return "未开放此 API"
        case .protocolMismatch: return "响应格式不符"
        case .rateLimited: return "限流"
        case .bad(let c): return "HTTP \(c)"
        case .unreachable: return "不可达"
        case .offline: return "网络未连接"
        case .noKey: return "无 Key"
        case .ok: return ""
        }
    }
}

// MARK: - 协议徽标（供应商页端点标签：同样只用颜色表达，原因进悬停提示）
struct ProtoBadge: View {
    let proto: Proto
    var avail: Avail? = nil

    var body: some View {
        let name = proto == .anthropic ? "Anthropic" : "OpenAI"
        let c = proto == .anthropic ? anthColor : openColor
        let (fg, fill, border, reason): (Color, Color, Color, String) = {
            switch avail {
            case .ok, .none:
                return (c, c.opacity(0.12), c.opacity(0.30), "")
            case .untested:
                // I7：未检测独立成态（黄），baseURL 变更作废重测后灯牌 visibly 回黄，不再与「测通」同貌
                return (warnColor, warnColor.opacity(0.12), warnColor.opacity(0.35), "尚未检测")
            case .off(let r):
                return (ink3, Color(NSColor.quaternaryLabelColor).opacity(0.18), sep, r)
            }
        }()
        return Text(name).font(f(11, .semibold)).foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(border, lineWidth: 1)))
            .help(reason.isEmpty ? name : "\(name)：\(reason)")
    }
}

// MARK: - API 线徽标（模型管理页专用：Messages 橙 / Responses 青 / Completions 蓝）
// 只用颜色表达状态：亮=检测通过；灰=已认定不可用；黄=未检测。原因不放徽标里（悬停可见，详情区可查）。
struct ModelAPIBadge: View {
    let api: ModelAPI
    var avail: Avail? = nil
    var long = false   // 显示协议全称（路由卡兼容标签行 / 默认来源编辑器）
    var isDefault = false   // I5：本供应商为该名称组该线默认来源 → 绿点角标（替代行内「默认·X」绿标，省行宽）
    var dotSlot = false     // 修订2 中轴对齐：恒占点位（行间同宽→同类灯牌左右沿/中点对齐），非默认态灰点（恒占位，行间灯牌对齐）

    var body: some View {
        let c: Color = {
            switch api {
            case .messages:    return anthColor
            case .responses:   return openColor
            case .completions: return accent
            }
        }()
        let (fg, fill, border, reason): (Color, Color, Color, String) = {
            switch avail {
            case .ok, .none:
                return (c, c.opacity(0.12), c.opacity(0.30), "")
            case .off(let r):
                return (ink3, Color(NSColor.quaternaryLabelColor).opacity(0.18), sep, r)
            case .untested:
                return (warnColor, warnColor.opacity(0.12), warnColor.opacity(0.35), "尚未检测")
            }
        }()
        var help = reason.isEmpty ? (long ? api.fullName : api.label) : "\(api.label)：\(reason)"
        if isDefault { help += " · 该线默认来源（本供应商）" }
        return HStack(spacing: 4) {
            if isDefault || dotSlot {
                Circle().fill(isDefault ? okColor : ink3).frame(width: 5, height: 5)
            }
            Text(long ? api.fullName : api.label).font(f(11, .semibold)).foregroundStyle(fg)
        }
        .lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 5).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(border, lineWidth: 1)))
        .help(help)
        .fixedSize()   // I5 布局：徽标拒绝压缩/换行（行宽不足时由行内弹性元素吸收）
    }
}

// MARK: - 默认来源灯牌（模型管理组头：亮=该线已设默认来源，灭=未设；复制图标恒显——亮=可点复制，灭=灰态不可点）
// 复制内容 = 该线默认来源供应商的通用 ID（VENDOR/MODEL）；槽位宽由调用方 frame 固定以跨卡对齐。
struct DefaultSourceBadge: View {
    let api: ModelAPI
    let lit: Bool
    var onCopy: (() -> Void)? = nil

    var body: some View {
        let c: Color = api == .messages ? anthColor : (api == .responses ? openColor : accent)
        return HStack(spacing: 5) {
            Text(api.label).font(f(11, .semibold))
            if lit {
                if let onCopy {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc").font(.system(size: 9.5))
                    }
                    .buttonStyle(.plain)
                    .opacity(0.75)
                    .help("复制该线默认来源的通用 ID")
                }
            } else {
                // R9：灭态恒显同款复制图标（非交互、沿用外层 ink3 灰态）——与亮态同槽，牌宽不因灯态跳变
                Image(systemName: "doc.on.doc").font(.system(size: 9.5))
                    .help("该线未设默认来源")
            }
        }
        .foregroundStyle(lit ? c : ink3)
        .padding(.horizontal, 7).padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(lit ? c.opacity(0.12) : Color(NSColor.quaternaryLabelColor).opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(lit ? c.opacity(0.30) : sep, lineWidth: 1))
    }
}

// MARK: - 状态圆点
struct Dot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

// MARK: - ? 帮助点（点击弹深色气泡）
struct HelpTip: View {
    let tip: String
    var scale: CGFloat = 1
    @State private var show = false

    var body: some View {
        Button {
            show.toggle()
        } label: {
            Text("?").font(f(10.5 * scale, .semibold)).foregroundStyle(show ? accent : ink3)
                .frame(width: 16 * scale, height: 16 * scale)
                .background(Circle().stroke(show ? accent : ink3, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            Text(tip).font(f(11.5)).foregroundStyle(.white).lineSpacing(3)
                .padding(11).frame(width: 292, alignment: .leading)
                .background(Color(red: 0.12, green: 0.12, blue: 0.13).opacity(0.97))
        }
    }
}

// MARK: - 页头（标题 + ? + 注释 [+ 尾部主按钮由调用方放 Spacer 后追加]）
struct ViewHeader: View {
    let title: String
    var tip: String = ""
    var note: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(f(16, .bold))
            if !tip.isEmpty { HelpTip(tip: tip) }
            if !note.isEmpty {
                Text(note).font(f(11.5)).foregroundStyle(ink3)
            }
            Spacer()
        }
    }
}

// MARK: - 按钮样式（原型 .btn：26 高圆角描边；主色填充；mini 22 高；禁用变灰）
struct CardBtnStyle: ButtonStyle {
    var primary = false
    var mini = false
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        CardBtnLabel(configuration: configuration, primary: primary, mini: mini, danger: danger)
    }

    private struct CardBtnLabel: View {
        let configuration: Configuration
        let primary: Bool
        let mini: Bool
        let danger: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let radius: CGFloat = mini ? 5 : 6
            configuration.label
                .font(f(mini ? 12 : 12.5))
                .foregroundStyle(primary ? Color.white : (danger ? errColor : Color.primary))
                .padding(.horizontal, primary ? 12 : 9)
                .frame(height: mini ? 22 : 26)
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .fill(primary ? accent : Color(NSColor.controlBackgroundColor))
                        .opacity(configuration.isPressed ? 0.75 : 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(primary ? accent : Color(NSColor.separatorColor).opacity(0.9), lineWidth: 1)
                )
                .opacity(configuration.isPressed ? 0.85 : (enabled ? 1 : 0.4))
        }
    }
}

extension Button {
    func cardBtn(primary: Bool = false, mini: Bool = false, danger: Bool = false) -> some View {
        buttonStyle(CardBtnStyle(primary: primary, mini: mini, danger: danger))
    }
}

// MARK: - 灰态幽灵按钮（保存/快速配置的「无改动态」标签）
// 观感为管理员像素实测定案（2026-09-28，勿改）：白 4% 叠加任意窗底恒 ≈+10 级、浅深两外观同构；
// 字色 primary 25%。两配置窗曾各抄一份同段代码，收敛于此。
struct GhostButtonLabel: View {
    let title: String
    var body: some View {
        Text(title).font(f(12.5))
            .foregroundStyle(Color.primary.opacity(0.25))
            .padding(.horizontal, 12).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
    }
}

// MARK: - 文字链按钮（编辑=强调色 / 删除=红）
struct LinkBtn: View {
    let title: String
    var danger = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(f(12.5)).foregroundStyle(danger ? errColor : accent)
        }.buttonStyle(.plain).onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            // 悬停中视图被移除（切页/删行）时 onHover(false) 不会到来，补 pop 防光标栈失衡
            if hovering { NSCursor.pop(); hovering = false }
        }
    }
}

// MARK: - 24pt 描边小图标按钮（访问配置/速查列表的复制、显隐共用）
func copyIconBtn(_ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol).font(.system(size: 11))
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(NSColor.separatorColor).opacity(0.8), lineWidth: 1)))
            .foregroundStyle(ink2)
    }
    .buttonStyle(.plain)
}

// MARK: - 原生下拉选择器（NSPopUpButton 包装）
// SwiftUI 的 Menu/Picker 宽度取 min(提议宽, 内容理想宽)，无法拉伸到统一列宽，且本 beta 上
// Menu 样式组合的渲染行为不一致（空菜单/双重 bezel 都出现过）。NSPopUpButton 设 autoresizingMask
// 后宽度完全由外部 frame 决定：原生外观、原生菜单、原生勾选态，列宽逐行严格相等。
// 顶层非泛型协调器：嵌套在泛型类型内的类其 @objc 方法不会注册到 ObjC 运行时，
// target-action 会被静默丢弃（下拉选择只改外观、不进状态/不落盘）。闭包回写 Binding。
final class NativeMenuCoordinator: NSObject {
    var onChanged: ((Int) -> Void)?
    @objc func changed(_ b: NSPopUpButton) {
        onChanged?(b.indexOfSelectedItem)
    }
}

struct NativeMenuPicker<Tag: Hashable>: NSViewRepresentable {
    let items: [(tag: Tag?, title: String)]
    @Binding var selection: Tag?
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> NativeMenuCoordinator { NativeMenuCoordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let b = NSPopUpButton(frame: .zero, pullsDown: false)
        b.target = context.coordinator
        b.action = #selector(NativeMenuCoordinator.changed(_:))
        b.controlSize = .small
        b.font = .systemFont(ofSize: 12)
        // 列宽为准：降低水平压缩阻力/拥抱优先级，否则长选项的固有宽会撑出画框（真机逐行宽窄不一）
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.setContentHuggingPriority(.defaultLow, for: .horizontal)
        b.autoresizingMask = [.width, .height]   // 填满 SwiftUI 给的 frame → 列宽由外部控制
        return b
    }

    func updateNSView(_ b: NSPopUpButton, context: Context) {
        context.coordinator.onChanged = { [items, self] i in
            guard i >= 0, i < items.count else { return }
            self.$selection.wrappedValue = items[i].tag
        }
        b.isEnabled = isEnabled
        let titles = items.map { $0.title }
        if b.itemArray.map({ $0.title }) != titles {
            b.removeAllItems()
            b.addItems(withTitles: titles)
        }
        let idx = selection == nil
            ? items.firstIndex { $0.tag == nil }
            : items.firstIndex { $0.tag == selection }
        if let idx, b.indexOfSelectedItem != idx { b.select(b.itemArray[idx]) }
        if let idx { b.toolTip = items[idx].title }   // 修订2：闭合态截断时长得一样的选项可悬停分辨
    }
}

// MARK: - 表单字段（96pt 标签列，右对齐；可选副标签/色块）
struct SheetField<Label: View, Content: View>: View {
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                label()
            }
            .frame(width: 96, alignment: .trailing)
            content()
        }
    }
}

func fieldLabel(_ text: String, sub: String = "") -> some View {
    VStack(alignment: .trailing, spacing: 1) {
        Text(text).font(f(12.5)).foregroundStyle(ink2)
        if !sub.isEmpty { Text(sub).font(f(11)).foregroundStyle(ink3) }
    }
}

/// URL 字段的双行标签（色块 + 协议名 / 副标签），对齐原型 .urlmark
struct URLFieldLabel: View {
    let proto: Proto

    var body: some View {
        let c = proto == .anthropic ? anthColor : openColor
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
                Text(proto == .anthropic ? "Anthropic" : "OpenAI").font(f(12.5)).foregroundStyle(ink2)
                Spacer(minLength: 0)
            }
            Text("兼容 Base URL").font(f(11)).foregroundStyle(ink3)
        }
        .frame(width: 96, alignment: .trailing)
    }
}

// MARK: - 等宽值盒（访问配置 / 片段路径里的白色单行框）
struct MonoBox: View {
    let text: String
    var isSecret = false

    var body: some View {
        Text(isSecret ? String(repeating: "•", count: 24) : text)
            .font(mono(11.5)).foregroundStyle(isSecret ? Color.primary : ink2)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(sep, lineWidth: 1)))
    }
}

// MARK: - S1 三线：NSSecureTextField 封装＋抑制系统「Passwords...」自动填充挂件
// 排查定因（2026-10-01，截图取证＋SO 65907104）：macOS 对窗口内**首个可见安全字段**无条件挂
// 「Passwords...」挂件，与 contentType 无关（一线 .URL／二线 AppKit 级声明均无效；AppKit 无
// .newPassword，.oneTimeCode 有空泡副作用）。唯一有效抑制＝覆写私有选择器
// _isPasswordAutofillEnabled 返回 NO。本应用经 GitHub 直接分发不经 App Store，私有 API 审核
// 风险不适用；若未来 macOS 移除该选择器，退化表现＝弹窗回归，无崩溃风险。
final class NoAutofillSecureTextField: NSSecureTextField {
    // Swift 侧不可见父类私有方法：以同选择子注册，运行时经 ObjC 动态派发命中本实现
    @objc(_isPasswordAutofillEnabled)
    func _isPasswordAutofillEnabled() -> Bool { false }
}

struct SecureInpField: NSViewRepresentable {
    var placeholder: String = ""
    var monoStyle = false
    @Binding var text: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NoAutofillSecureTextField()
        field.placeholderString = placeholder
        field.font = monoStyle
            ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            : NSFont.systemFont(ofSize: 12.5)
        field.usesSingleLineMode = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.truncatesLastVisibleLine = true
        field.cell?.wraps = false
        field.stringValue = text
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        // 同值不重设：编辑中重设 stringValue 会打断输入与选区
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var parent: SecureInpField
        init(_ parent: SecureInpField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            parent.text = field.stringValue
        }
    }
}

// MARK: - 输入框（原型 .inp：28 高圆角描边；错误红框）
struct InpField: View {
    var placeholder: String = ""
    var monoStyle = false
    var secure = false
    @Binding var text: String
    var bad = false

    var body: some View {
        Group {
            if secure {
                // S1 二线（2026-10-01）：SwiftUI 层 textContentType 声明复验未过，换 AppKit 封装
                SecureInpField(placeholder: placeholder, monoStyle: monoStyle, text: $text)
            } else {
                TextField(placeholder, text: $text)
                    .font(monoStyle ? mono(11.5) : f(12.5))
            }
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(bad ? errColor : Color(NSColor.separatorColor).opacity(0.9), lineWidth: bad ? 1.5 : 1))
    }
}

// 表单内的红色/灰色提示行（原型 .hintline）
struct HintLine: View {
    var text: String
    var bad = false
    var indent: CGFloat = 0

    var body: some View {
        Group {
            if !text.isEmpty {
                Text(text).font(f(11)).foregroundStyle(bad ? errColor : ink3)
            }
        }
        .padding(.leading, indent)
    }
}

// MARK: - Toast（底部深色 HUD：绿点 + 文案 + 可选小字）
struct ToastBar: View {
    let text: String
    var detail: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Dot(color: okColor, size: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(f(12.5)).foregroundStyle(.white)
                if !detail.isEmpty {
                    Text(detail).font(f(11)).foregroundStyle(Color(red: 0.72, green: 0.72, blue: 0.74))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 0.12, green: 0.12, blue: 0.13).opacity(0.93)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(maxWidth: 520)   // 底距职责归挂载点（组件不再内嵌 bottom padding，主窗/浮窗各自给）
    }
}

// MARK: - 警告横幅（Key 重新生成等事件；黄底通栏 + 复制 + ✕ 关闭，P1）
struct BannerBar: View {
    let text: String
    let onCopy: () -> Void
    var onDismiss: (() -> Void)? = nil
    /// 左内边距（横幅位于硬填充顶栏之下，无需为红绿灯让位）
    var leadingInset: CGFloat = 16

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(f(12)).foregroundStyle(warnColor)
            Text(text).font(f(12.5)).foregroundStyle(Color(red: 0.48, green: 0.30, blue: 0.0))
                .lineLimit(2)
            Button("复制") { onCopy() }.cardBtn(mini: true)
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(f(10.5, .semibold))
                        .foregroundStyle(Color(red: 0.48, green: 0.30, blue: 0.0))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.48, green: 0.30, blue: 0.0).opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("关闭通知")
            }
        }
        .padding(.leading, leadingInset).padding(.trailing, 12).padding(.vertical, 7)
        .background(Color(red: 1.0, green: 0.953, blue: 0.875))          // #fff3df
        .overlay(Rectangle().fill(Color(red: 0.941, green: 0.851, blue: 0.675)).frame(height: 1), alignment: .bottom) // #f0d9ac
    }
}

// MARK: - 字典长描述块（S7：>90 字默认 3 行截断＋「展开」看全文——管理员 2026-10-03 批准保留展开形式；三配置窗字典行共用）
struct DictDescBlock: View {
    let id: String
    let text: String
    var color: Color = ink2
    @State private var open = false

    var body: some View {
        let long = text.count > 90
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(f(11.5)).foregroundStyle(color)
                .lineLimit(open || !long ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            if long {
                Button(open ? "收起" : "展开") {
                    withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
                }
                .buttonStyle(.plain).font(f(11)).foregroundStyle(accent)
            }
        }
    }
}

// MARK: - 通用确认弹窗（原型 confirmSheet：标题 + 富文本 + 取消/删除）
struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String        // 支持 **markdown 加粗**
    var okLabel: String = "删除"
    var okDanger = true
    let onOk: () -> Void
}

struct ConfirmSheet: View {
    let request: ConfirmRequest
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(f(14.5, .semibold))
            Text(try! AttributedString(markdown: request.message))
                .font(f(12.5)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.cardBtn()
                Button(request.okLabel) {
                    dismiss()
                    request.onOk()
                }
                .cardBtn(primary: request.okDanger)
                .tint(request.okDanger ? errColor : nil)
            }
        }
        .padding(20).frame(width: 440)   // 弹窗宽度档统一：440（确认/端口/弃用）；500（配置引导）
    }
}

// JSON 语法高亮已统一收敛到 JSONCodeEditor.swift 的 jsonHighlighted（VS Code Dark+/Light+ 自适应色板，
// 2026-09-24 二次应用：管理员在组件滚动/配色修复后重新指定「显示」列采用新显示器）。

// MARK: - Codex models.json 单条元数据：粘贴容错解析 + 最小条目生成
// 用户的输入可能是：单条目对象 / 整个 {"models":[…]} 包裹 / 复制时漏掉外层大括号的字段片段 / 空。
// 应用时统一改写成合法的单条目 JSON（有 models 包裹则提取，仅一个条目时自动取用）。
enum CodexMetaNorm {
    enum Outcome: Equatable {
        case empty
        case ok                       // 合法单条目（含 slug）
        case invalidJSON(String)      // JSON 语法错误（带原因）
        case modelsWrapper(Int)       // 整个 models.json，含 N 个条目（N≠1 需用户挑一个）
        case notAnObject              // 不是单个条目对象
        case missingSlug              // 缺少 slug（Codex 必需）
    }

    static func normalize(_ text: String) -> (Outcome, [String: Any]?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return (.empty, nil) }
        if case .success(let obj) = parse(t) { return entry(obj) }
        // 字段片段：用户从官方 models.json 复制时漏掉外层大括号 → 补全再试
        for candidate in ["{" + stripTrailingCommas(t) + "}", "{" + t + "}"] {
            if case .success(let obj) = parse(candidate) { return entry(obj) }
        }
        if case .failure(let e) = parse(t) {
            return (.invalidJSON(e.localizedDescription), nil)
        }
        return (.invalidJSON("无法解析"), nil)
    }

    private static func parse(_ s: String) -> Result<Any, Error> {
        Result { try JSONSerialization.jsonObject(with: Data(s.utf8)) }
    }

    private static func entry(_ obj: Any) -> (Outcome, [String: Any]?) {
        if let arr = obj as? [Any] {
            if arr.count == 1, let e = arr[0] as? [String: Any] { return check(e) }
            return (.notAnObject, nil)
        }
        if let d = obj as? [String: Any] {
            if let models = d["models"] as? [Any] {
                if models.count == 1, let e = models[0] as? [String: Any] { return check(e) }
                return (.modelsWrapper(models.count), nil)
            }
            return check(d)
        }
        return (.notAnObject, nil)
    }

    private static func check(_ e: [String: Any]) -> (Outcome, [String: Any]?) {
        if let slug = e["slug"] as? String, !slug.isEmpty { return (.ok, e) }
        return (.missingSlug, nil)
    }

    private static func stripTrailingCommas(_ s: String) -> String {
        s.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
    }

    static func pretty(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }

    static func slug(of text: String) -> String? {
        let (outcome, obj) = normalize(text)
        guard outcome == .ok, let slug = obj?["slug"] as? String else { return nil }
        return slug
    }
}

// MARK: - 独立编辑窗（内容可能比主窗口高，用独立 NSWindow 承载，不占用 sheet）
final class FloatWindowCenter {
    static let shared = FloatWindowCenter()
    private var windows: [NSWindow] = []
    /// 窗口 delegate 强引用（NSWindow.delegate 为弱引用；现用于 CLI 配置窗的未保存关窗警告）
    private var closeGuards: [ObjectIdentifier: NSWindowDelegate] = [:]
    /// S10（2026-10-01）窗口单例：reuseKey → 在窗映射；同键再次 present 唤回既有窗，不再新开
    private var reuseWindows: [String: NSWindow] = [:]
    private var keyMonitor: Any?

    private init() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow, let self else { return }
            self.windows.removeAll { $0 === w }
            self.closeGuards.removeValue(forKey: ObjectIdentifier(w))
            self.reuseWindows = self.reuseWindows.filter { $0.value !== w }
        }
    }

    /// 浮动窗内 ⌘V/⌘C/⌘X/⌘A 直通文本响应链：辅助应用（LSUIElement）下主菜单等价键路由不可靠，
    /// 曾致独立编辑窗无法粘贴。仅当首响应者是文本视图时消费，其余按键原样放行。
    private func ensureKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let w = event.window, self.windows.contains(w) else { return event }
            let flags = event.modifierFlags
            guard flags.contains(.command), !flags.contains(.shift),
                  !flags.contains(.control), !flags.contains(.option),
                  let ch = event.charactersIgnoringModifiers?.lowercased() else { return event }
            let action: Selector?
            switch ch {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            default:  action = nil
            }
            guard let action, let fr = w.firstResponder, fr.responds(to: action) else { return event }
            NSApp.sendAction(action, to: nil, from: event)
            return nil   // 已消费：阻断后续路由，防二次触发
        }
    }

    /// 弹出一个可调大小的独立窗口；content 闭包拿到窗口本身，用于把关闭动作传给视图。
    /// closeGuard：可选窗口 delegate（传入者须自持生命周期之外的一份引用以传参）。
    /// reuseKey：S10 窗口单例——非 nil 时同键已开窗则唤回（deminiaturize＋置前）不再新开；关窗自动除名。
    /// 粒度＝类型＋目标（如 "codex-config:<harnessID>"）：同一目标重复打开唤回，不同目标可并存。
    func present<V: View>(title: String, size: NSSize, reuseKey: String? = nil,
                          closeGuard: NSWindowDelegate? = nil, @ViewBuilder content: @escaping (NSWindow) -> V) {
        // isVisible 护栏：willClose 观察块经 queue:.main 异步派发，close() 与除名之间有空窗期——
        // 键已残留但窗已关时不唤回，落到下方重建并覆盖注册（自愈）
        if let reuseKey, let exist = reuseWindows[reuseKey], exist.isVisible {
            exist.deminiaturize(nil)
            exist.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }
        ensureKeyMonitor()
        let w = NSWindow(contentRect: NSRect(origin: NSPoint.zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable],   // 去 .resizable：内容定高，窗不被拉伸
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content(w)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        w.center()
        windows.append(w)
        if let reuseKey { reuseWindows[reuseKey] = w }
        if let closeGuard {
            w.delegate = closeGuard
            closeGuards[ObjectIdentifier(w)] = closeGuard
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
}

