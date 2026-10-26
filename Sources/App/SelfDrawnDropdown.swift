import SwiftUI
import AppKit

// MARK: - 自绘下拉（R8 A 卡供应商列）
// 形态（R8-SPEC 一.A / 管理员截图定案）：闭态＝控件盒（文本＋箭头）；开态＝菜单层贴控件盒下缘弹出，
// 宽＝控件盒、选中项蓝底白字带 ✓、点选/外部点击/滚动关闭。
// 原生 select/Menu 的弹出菜单由 macOS 定位无法与控件盒对齐（管理员 HTML 草稿结论，SwiftUI Menu 同病），
// 故菜单层用无边框 NSPanel 独立承载——不受卡片/滚动容器裁切，天然置顶。
struct SelfDrawnDropdown<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    let selection: Binding<Item?>
    let placeholder: String
    var disabled: Bool = false

    @State private var open = false
    /// 控件盒的 NSView 引用（开菜单时换算屏幕坐标）；class 盒避免 State 重置
    @State private var anchorBox = ViewAnchorBox()

    final class ViewAnchorBox {
        weak var view: NSView?
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(selection.wrappedValue.map(title) ?? placeholder)
                .font(f(12)).foregroundStyle(selection.wrappedValue == nil ? ink3 : ink2)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(ink2)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(open ? accent : sep, lineWidth: 1))
        .opacity(disabled ? 0.55 : 1)
        .background(AnchorReader(box: anchorBox))
        .onTapGesture {
            guard !disabled else { return }
            if open { closeMenu() } else { openMenu() }
        }
    }

    // MARK: - 菜单层（NSPanel）

    private func openMenu() {
        guard let anchor = anchorBox.view, let window = anchor.window else { return }
        let boxRect = anchor.convert(anchor.bounds, to: nil)          // window 坐标
        let screenRect = window.convertToScreen(boxRect)
        let width = max(160, screenRect.width)
        let rowH: CGFloat = 26
        let maxH: CGFloat = 264
        let height = min(CGFloat(items.count) * rowH + 4, maxH)

        let panel = DropdownPanel(width: width, height: height)
        let isDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let menu = DropdownMenuList(items: items, title: title,
                                    selected: selection.wrappedValue) { pick in
            selection.wrappedValue = pick
            closeMenu()
        }
        let host = NSHostingView(rootView: menu.environment(\.colorScheme, isDark ? .dark : .light))
        panel.contentView = host

        // 贴下弹出；屏幕下方放不下时翻转到控件盒上方
        var origin = CGPoint(x: screenRect.minX, y: screenRect.maxY - height)
        if origin.y < 0 { origin.y = screenRect.minY + height + screenRect.height }
        panel.setFrameOrigin(origin)
        open = true
        panel.orderFrontRegardless()
        panel.installDismissMonitor { [weak anchorBox = anchorBox] in
            // 外部点击/滚动：全局监听不消费事件，关闭菜单即透传底层
            Task { @MainActor in _ = anchorBox; closeMenu() }
        }
        currentPanel = panel
    }

    @State private var currentPanel: DropdownPanel?

    private func closeMenu() {
        currentPanel?.close()
        currentPanel = nil
        open = false
    }

    /// 捕获控件盒自身 NSView（背景放一个透明占位视图）
    private struct AnchorReader: NSViewRepresentable {
        let box: ViewAnchorBox
        final class AnchorView: NSView {
            override func draw(_ dirtyRect: NSRect) {}   // 透明不绘制
        }
        func makeNSView(context: Context) -> NSView { AnchorView() }
        func updateNSView(_ v: NSView, context: Context) { box.view = v }
    }
}

/// 无边框菜单层：不吃键盘焦点（nonactivating），点击穿透由全局监听关闭实现
final class DropdownPanel: NSPanel {
    var dismissMonitor: Any?

    init(width: CGFloat, height: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar              // 压过一切常规窗内容
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }

    func installDismissMonitor(_ onDismiss: @escaping () -> Void) {
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { _ in
            onDismiss()
        }
    }

    override func close() {
        if let m = dismissMonitor {
            NSEvent.removeMonitor(m)
            dismissMonitor = nil
        }
        super.close()
    }
}

/// 菜单列表：宽＝控件盒；选中项蓝底白字带 ✓；hover 高亮
private struct DropdownMenuList<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    let selected: Item?
    let onPick: (Item?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.self) { item in
                DropdownMenuRow(item: item,
                                title: title,
                                isSel: item == selected,
                                onPick: { onPick(item) },
                                onHover: { _ = item })
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1))
        )
    }
}

/// 菜单行（独立子视图：泛型长链拆分，避免类型检查超时）
private struct DropdownMenuRow<Item: Hashable>: View {
    let item: Item
    let title: (Item) -> String
    let isSel: Bool
    let onPick: () -> Void
    let onHover: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            checkIcon
            rowText
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(rowBackground))
        .contentShape(Rectangle())
        .onHover { h in hover = h; if h { onHover() } }
        .onTapGesture { onPick() }
    }

    private var checkIcon: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isSel ? Color.white : Color.clear)
            .frame(width: 12)
    }

    private var rowText: some View {
        Text(title(item))
            .font(f(12)).foregroundStyle(isSel ? Color.white : ink2)
            .lineLimit(1).truncationMode(.middle)
    }

    /// 行底色：选中＝主色（蓝底白字）；悬停＝弱高亮；其余透明
    private var rowBackground: Color {
        if isSel { return accent }
        if hover { return Color(NSColor.quaternaryLabelColor).opacity(0.3) }
        return Color.clear
    }
}
