import AppKit
import Combine
import ModelRouterCore

// MARK: - 菜单栏状态项（R5）：复合图标（字形 + 状态点）＋ 直出常用动作菜单（复制 baseURL/Key、切换模型供应商）
final class MenuBarController: NSObject, NSMenuDelegate {
    let state: AppState
    private let statusItem: NSStatusItem
    private let menu: NSMenu

    private var dotSubscription: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var buttonAppearanceObservation: NSKeyValueObservation?
    private var iconCache: [IconKey: NSImage] = [:]

    /// 状态点直径与字形右侧间距（pt）；字形显示高 18pt、宽按原始比例
    private static let dotDiameter: CGFloat = 7
    private static let dotGap: CGFloat = 4
    private static let glyphHeight: CGFloat = 18

    /// 合成图缓存键：外观 × 状态点等级（重绘仅在两种变化下发生）
    private struct IconKey: Hashable {
        let dark: Bool
        let level: MenuDotLevel
    }

    /// 点选供应商的承载（NSMenuItem.representedObject）
    private final class VendorPick: NSObject {
        let harnessID: UUID
        let field: String
        let vendorID: UUID
        init(harnessID: UUID, field: String, vendorID: UUID) {
            self.harnessID = harnessID
            self.field = field
            self.vendorID = vendorID
        }
    }

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false   // 手动控制可用态：复制项恒可用、错误行恒禁用
        statusItem.menu = menu   // 系统托管弹出：原生状态菜单外观与全屏跟踪；menuNeedsUpdate 每次打开重建

        // 重绘触发一：状态点等级变化（Combine 订阅，主线程）
        dotSubscription = state.$menuDot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIcon() }
        // 重绘触发二：状态项按钮自身外观（菜单栏区域的实际渲染依据）——主触发
        if let button = statusItem.button {
            buttonAppearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                self?.refreshIcon()
            }
        }
        // 重绘触发三：应用级外观切换（effectiveAppearance KVO）——次要触发
        if let app = NSApp {
            appearanceObservation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                self?.refreshIcon()
            }
        }
        refreshIcon()
    }

    // MARK: - 复合状态图标

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let dark = Self.isDarkAppearance(button: button)
        let key = IconKey(dark: dark, level: state.menuDot)
        if let cached = iconCache[key] {
            button.image = cached
        } else {
            let composed = composeIcon(dark: dark, level: state.menuDot)
            iconCache[key] = composed
            button.image = composed
        }
    }

    /// 外观信号取状态项按钮自身的 effectiveAppearance（系统对菜单栏区域的实际渲染依据），
    /// 而非 NSApp.effectiveAppearance（仅反映应用跟随的系统外观，桌面浅栏＋系统深色时会误判）；
    /// 按钮不可用时回落应用级外观，bestMatch 为 nil 时回落浅色
    private static func isDarkAppearance(button: NSStatusBarButton?) -> Bool {
        (button?.effectiveAppearance ?? NSApp?.effectiveAppearance)?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 合成整图（非 template）：字形按外观着色，右侧距 4pt 画 7pt 状态圆点，垂直居中
    private func composeIcon(dark: Bool, level: MenuDotLevel) -> NSImage {
        let glyph = Self.tintedGlyph(dark: dark)
        let gw = glyph.size.width
        let canvasH = max(glyph.size.height, Self.dotDiameter)
        let image = NSImage(size: NSSize(width: gw + Self.dotGap + Self.dotDiameter, height: canvasH))
        image.lockFocus()
        glyph.draw(in: NSRect(x: 0, y: (canvasH - glyph.size.height) / 2,
                              width: glyph.size.width, height: glyph.size.height))
        let dotRect = NSRect(x: gw + Self.dotGap,
                             y: (canvasH - Self.dotDiameter) / 2,
                             width: Self.dotDiameter, height: Self.dotDiameter)
        Self.dotColor(level: level, dark: dark).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// 字形着色（浅色菜单栏黑 / 深色白）：先把原字形画入新 NSImage，再以 sourceAtop 填充只覆盖已有像素
    private static func tintedGlyph(dark: Bool) -> NSImage {
        guard let src = NSImage(named: "MenuBarGlyph") else {
            return NSImage(size: NSSize(width: glyphHeight, height: glyphHeight))
        }
        let h = glyphHeight
        let w = src.size.height > 0 ? src.size.width * h / src.size.height : h
        let tinted = NSImage(size: NSSize(width: w, height: h))
        tinted.lockFocus()
        src.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        (dark ? NSColor.white : NSColor.black).setFill()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }

    private static func dotColor(level: MenuDotLevel, dark: Bool) -> NSColor {
        func hex(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                    green: CGFloat((v >> 8) & 0xFF) / 255.0,
                    blue: CGFloat(v & 0xFF) / 255.0,
                    alpha: 1)
        }
        switch level {
        case .ok:   return hex(dark ? 0x30D158 : 0x2FA14E)
        case .warn: return hex(dark ? 0xFFD60A : 0xC9930A)
        case .err:  return hex(dark ? 0xFF453A : 0xE5484D)
        case .idle: return hex(dark ? 0x98989D : 0x8E8E93)
        }
    }

    // MARK: - 菜单（每次打开整建；顺序为设计稿定稿）

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // 1) 进入主界面（管理员 2026-10-03 定名；唤回被 ⌘W/红点隐藏的主窗）
        let enter = NSMenuItem(title: "进入主界面", action: #selector(enterMainWindow), keyEquivalent: "")
        enter.target = self
        menu.addItem(enter)
        // 2) 状态行（R17 双口径）：近期＝200 条窗口聚合（报错显示最近一条报错内容）；
        //    当前＝最近 1 条（与状态点同源）。两口径 idle 条件同源（降噪后无事件），合并为一行「暂无事件」；
        //    S7（2026-10-03）：两口径指向同一条事件时只留「当前」行，不再前后缀重复
        if state.menuDot == .idle {
            let idleLine = NSMenuItem(title: "暂无事件", action: nil, keyEquivalent: "")
            idleLine.isEnabled = false
            menu.addItem(idleLine)
        } else {
            let sameStory = state.menuRecent == state.menuDot
                && Self.eventHead(state.menuRecentEvent) == Self.eventHead(state.menuDotEvent)
            if !sameStory {
                let recentLine = NSMenuItem(title: Self.statusLineTitle(scope: "近期", level: state.menuRecent,
                                                                        event: state.menuRecentEvent),
                                            action: nil, keyEquivalent: "")
                recentLine.isEnabled = false
                menu.addItem(recentLine)
            }
            let curLine = NSMenuItem(title: Self.statusLineTitle(scope: "当前", level: state.menuDot,
                                                                 event: state.menuDotEvent),
                                     action: nil, keyEquivalent: "")
            curLine.isEnabled = false
            menu.addItem(curLine)
        }
        // 3) Claude 组
        menu.addItem(.separator())
        addCopyItem(menu, title: "复制 Claude Base URL", text: state.endpointText + "/claude")
        addCopyItem(menu, title: "复制 Claude API Key", text: state.accessKeyText(for: K.claudeKeyRef))
        addSwitchItem(menu, title: "切换 Claude 模型供应商",
                      harness: state.config.harnesses.first { $0.tierOrder != nil }, api: .messages, codex: false)
        // S6（R14）：复制 Claude 模型 ID——形式与切换项一致（切换项之后）
        addClaudeModelIDCopyItem(menu)
        // 4) Codex 组
        menu.addItem(.separator())
        addCopyItem(menu, title: "复制 Codex Base URL", text: state.endpointText + "/codex")
        addCopyItem(menu, title: "复制 Codex API Key", text: state.accessKeyText(for: K.codexKeyRef))
        addSwitchItem(menu, title: "切换 Codex 模型供应商",
                      harness: state.config.harnesses.first { $0.proto == .openai && $0.universal != true && $0.tierOrder == nil },
                      api: .responses, codex: true)
        // 5) 通用组
        menu.addItem(.separator())
        addCopyItem(menu, title: "复制通用 Anthropic 兼容 Base URL", text: state.endpointText + "/anthropic")
        addCopyItem(menu, title: "复制通用 OpenAI 兼容 Base URL", text: state.endpointText + "/v1")
        addCopyItem(menu, title: "复制通用 API Key", text: state.accessKeyText(for: K.universalKeyRef))
        // 6) 复制通用 ID 独立窗（R5 追加，2026-09-26 定案：位置在「复制通用 API Key」与退出项之间）
        let uidCopy = NSMenuItem(title: "复制通用 ID…", action: #selector(openUIDCopyWindow), keyEquivalent: "")
        uidCopy.target = self
        menu.addItem(uidCopy)
        // 7) 退出（辅助应用无 Dock 退出路径，此为唯一入口）
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 ModelRouter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    /// 事件摘要（近期/当前同内容判定与状态行共用）：取报错首个「：」前段落，截 24 字
    static func eventHead(_ event: LogEvent?) -> String {
        guard let m = event?.message, !m.isEmpty else { return "" }
        let head: Substring
        if let r = m.range(of: "：") { head = m[..<r.lowerBound] }
        else if let r = m.range(of: ":") { head = m[..<r.lowerBound] }
        else { head = m[...] }
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 状态行文案（R17 双口径共用）：err/warn 前缀「<口径>异常/警告」＋事件摘要；ok/idle 常规文案
    static func statusLineTitle(scope: String, level: MenuDotLevel, event: LogEvent?) -> String {
        switch level {
        case .idle: return "暂无事件"
        case .ok:   return "\(scope)无异常"
        case .err, .warn:
            let kind = level == .err ? "异常" : "警告"
            let t = eventHead(event)
            return t.isEmpty ? "\(scope)\(kind)" : "\(scope)\(kind)：\(t.prefix(24))"
        }
    }

    /// 复制项：文本经 representedObject 携带，动作统一走 state.copy(_:)
    private func addCopyItem(_ menu: NSMenu, title: String, text: String) {
        let item = NSMenuItem(title: title, action: #selector(copyText(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = text
        menu.addItem(item)
    }

    /// 「切换 X 模型供应商」：
    /// Claude（codex=false）＝一级锁定槽位（名称经 slotGroupName 解析显示名），二级该名称可用供应商（当前项打勾）；
    /// Codex（codex=true，R8 纯派生架构）＝一级**全部添加的模型**（行名＝槽位键直用，不限锁定），
    /// 二级该名称 responses 线可用供应商（当前项打勾）；切换走 setSlotVendor 名称级换绑。
    /// 找不到对应卡 → 父项禁用；无槽位 → 单个禁用提示项。
    private func addSwitchItem(_ menu: NSMenu, title: String, harness: Harness?, api: ModelAPI, codex: Bool) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        guard let harness else {
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        let sub = NSMenu()
        sub.autoenablesItems = false
        let slots = codex ? harness.slots : harness.slots.filter { $0.locked == true }
        if slots.isEmpty {
            let hint = codex
                ? "暂无添加的模型——在 Codex CLI 配置窗添加后可在此切换"
                : "暂无锁定的映射位——在路由管理中锁定模型位后可在此切换"
            let none = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for slot in slots {
                let name = codex
                    ? slot.clientModelField
                    : (state.slotGroupName(slot) ?? slot.modelID ?? "")
                guard !name.isEmpty else { continue }
                let nameItem = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                let vendorMenu = NSMenu()
                vendorMenu.autoenablesItems = false
                let vendors = state.vendorPool(groupName: name, api)
                if vendors.isEmpty {
                    let empty = NSMenuItem(title: "该名称下暂无可用供应商", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    vendorMenu.addItem(empty)
                } else {
                    for v in vendors {
                        let vi = NSMenuItem(title: v.name, action: #selector(pickVendor(_:)), keyEquivalent: "")
                        vi.target = self
                        vi.representedObject = VendorPick(harnessID: harness.id, field: slot.clientModelField, vendorID: v.id)
                        if slot.vendorID == v.id { vi.state = NSControl.StateValue.on }
                        vendorMenu.addItem(vi)
                    }
                }
                nameItem.submenu = vendorMenu
                sub.addItem(nameItem)
            }
        }
        item.submenu = sub
        menu.addItem(item)
    }

    /// 「复制 Claude 模型 ID」（S6/R14）：三级结构＝一级 Claude 卡锁定槽位（行名「Opus-5 · GLM-5.3」＝
    /// 档名＋被路由模型的模型名称）→ 二级两项：复制模型 ID（内部槽位 ID，Claude Desktop 手动配置应填的
    /// 请求模型 ID）／复制 Display name（模型管理界面设置的模型名称＝前台显示名，2026-10-01 管理员更正；
    /// 条目缺失回落供应商侧 modelID）。与列表显示两段一一对应；未映射槽位显示档名＋禁用提示项。
    private func addClaudeModelIDCopyItem(_ menu: NSMenu) {
        let item = NSMenuItem(title: "复制 Claude 模型 ID", action: nil, keyEquivalent: "")
        guard let harness = state.config.harnesses.first(where: { $0.tierOrder != nil }) else {
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        let sub = NSMenu()
        sub.autoenablesItems = false
        let slots = harness.slots.filter { $0.locked == true }
        if slots.isEmpty {
            let none = NSMenuItem(title: "暂无锁定的映射位——在路由管理中锁定模型位后可复制", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for slot in slots {
                let tierName = Self.claudeTierMenuLabel(slot.clientModelField)
                let nameItem = NSMenuItem(title: tierName, action: nil, keyEquivalent: "")
                let m = NSMenu()
                m.autoenablesItems = false
                if let bound = slot.modelID {
                    // Display name＝被路由条目的模型名称（模型管理设置；nil 回落 modelID；条目缺失回落槽位 modelID）
                    let dn = state.config.models
                        .first(where: { $0.modelID == slot.modelID && $0.vendorID == slot.vendorID })?
                        .displayLabel ?? bound
                    nameItem.title = "\(tierName) · \(dn)"
                    let idItem = NSMenuItem(title: "复制模型 ID", action: #selector(copyText(_:)), keyEquivalent: "")
                    idItem.target = self
                    idItem.representedObject = slot.clientModelField
                    let dnItem = NSMenuItem(title: "复制 Display name", action: #selector(copyText(_:)), keyEquivalent: "")
                    dnItem.target = self
                    dnItem.representedObject = dn
                    m.addItem(idItem)
                    m.addItem(dnItem)
                } else {
                    let none = NSMenuItem(title: "未映射，无可复制", action: nil, keyEquivalent: "")
                    none.isEnabled = false
                    m.addItem(none)
                }
                nameItem.submenu = m
                sub.addItem(nameItem)
            }
        }
        item.submenu = sub
        menu.addItem(item)
    }

    /// 「Opus-5」形态（S6/R14 决策例）：claude-opus-5 → 去 claude- 前缀、首字母大写；非该前缀回落 tierDisplay
    static func claudeTierMenuLabel(_ field: String) -> String {
        guard field.hasPrefix("claude-") else { return Router.tierDisplay(field) }
        let rest = String(field.dropFirst("claude-".count))
        guard let first = rest.first else { return Router.tierDisplay(field) }
        return String(first).uppercased() + String(rest.dropFirst())
    }

    // MARK: - 动作

    /// 「复制通用 ID」独立窗标题（单实例判定：已开则前置，不重复开窗）
    private static let uidCopyWindowTitle = "复制通用 ID"

    /// 打开「复制通用 ID」独立窗（简化版模型管理，660×540，仅复制功能；R5 追加）
    @objc private func openUIDCopyWindow() {
        if let window = NSApp.windows.first(where: { $0.title == Self.uidCopyWindowTitle }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        FloatWindowCenter.shared.present(title: Self.uidCopyWindowTitle, size: NSSize(width: 660, height: 540)) { _ in
            UIDCopyView().environmentObject(self.state)   // 独立窗全新环境：手动注入（GroupMetaWindow 先例）
        }
    }

    /// 唤回主窗口（找不到忽略）
    @objc private func enterMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.title == "ModelRouter" }) else { return }
        // 辅助应用不占 Dock，窗口最小化后没有 Dock 落点，菜单「进入主界面」是唯一还原入口
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        state.copy(text)
    }

    @objc private func pickVendor(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? VendorPick else { return }
        state.setSlotVendor(harnessID: pick.harnessID, field: pick.field, vendorID: pick.vendorID)
    }
}