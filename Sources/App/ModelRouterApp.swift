import SwiftUI
import AppKit
import ServiceManagement

// MARK: - 应用入口（辅助应用形态 + 主窗 AppKit 直管）
// I6 定案（2026-09-22 定案、2026-09-24 实施）：主窗原为 SwiftUI WindowGroup 托管，⌘W 即销毁窗口，
// 菜单栏「进入主界面」按 title 找不到窗、唤不回。现主窗由 AppDelegate 直管：⌘W/红点＝隐藏不销毁，
// 「进入主界面」瞬时唤回且界面状态保留。LSUIElement（Info.plist）与运行时 .accessory 双保险不变。
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = AppState()
    private var mainWindow: NSWindow?

    /// 显式入口：AppKit 对 @main 的隐式装配依赖 Info.plist 主类/nib（生成式 plist 没有），
    /// 隐式路径下 delegate 永不装上 → 无窗无菜单栏图标（真机已复现）。手动装配后 app.run()。
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupAppMenu()
        createMainWindow()
        Self.registerLoginItemOnce()
    }

    /// R24：安装后自动加入「登录时打开」——DMG 拖装无安装期代码可跑，注册点＝首次启动；
    /// 一次性注册：用户日后在系统设置手动移除后不反复抢注（标记位兜住）。
    private static func registerLoginItemOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "mr.loginItem.attempted") else { return }
        d.set(true, forKey: "mr.loginItem.attempted")
        do { try SMAppService.mainApp.register() } catch {
            NSLog("ModelRouter login-item register failed: \(error.localizedDescription)")
        }
    }

    /// 主窗（隐藏式标题栏：透明 titlebar + fullSizeContentView，等价 windowStyle(.hiddenTitleBar)）
    private func createMainWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "ModelRouter"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: RootView().environmentObject(state))
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        mainWindow = w
    }

    /// ⌘W/红点＝隐藏不销毁（菜单栏「进入主界面」为唯一唤回入口）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func setupAppMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // File 子菜单：关闭窗口 ⌘W（走 windowShouldClose＝隐藏）
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "关闭窗口",
                                    action: #selector(NSWindow.performClose(_:)),
                                    keyEquivalent: "w"))
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit 子菜单：剪切/复制/粘贴/全选（辅助应用下 ⌘C 等需靠主菜单转发到响应链）
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
    }
}

// MARK: - 根视图（侧栏 + 详情 + 警告横幅 + Toast）
private struct RootView: View {
    @EnvironmentObject var state: AppState
    // R16①：启动弃用弹窗（每次启动检查；存在不受支持档才弹）＋「立即更新」续接
    @State private var noticeDismissed = false
    @State private var updateFromNotice: AppState.DeprecatedSlot? = nil

    /// 弃用条目行（弃用弹窗用；>6 项时套滚动容器）
    private var deprecatedRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.launchDeprecated) { d in
                MonoBox(text: d.field)
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                Sidebar().frame(width: 188)
                Divider()
                DetailPane()
            }
            // 硬填充顶栏（类独立窗标题栏观感、无文字）：填满安全区条带，窗口顶边界明确
            Rectangle().fill(winBg)
                .frame(height: 32)
                .overlay(alignment: .bottom) { Rectangle().fill(sep).frame(height: 1) }   // I1：分隔线挂顶栏 frame 底 = 顶栏下沿（32pt），修正偏下
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            // 警告横幅悬浮于内容之上（不推挤布局——401 风暴时反复弹横幅曾把编辑中的 sheet 挤掉）；位于顶栏之下
            if let banner = state.banner {
                BannerBar(text: banner.text,
                          onCopy: { state.copy(banner.copyValue) },
                          onDismiss: { state.dismissBanner() })
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
            VStack {
                Spacer()
                if !state.toast.isEmpty {
                    ToastBar(text: state.toast, detail: state.toastDetail)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 18)   // S7：底距职责归挂载点（组件内嵌 18pt 已移除，两处曾叠加至 30pt）
                }
            }
        }
        // 横幅/Toast 出入过渡（此前 transition 挂了但无 animation 驱动，从未播过）；以 text 为动画键（元组不 Equipable）
        .animation(.easeInOut(duration: 0.18), value: state.banner?.text)
        .animation(.easeInOut(duration: 0.18), value: state.toast)
        .onAppear {
            state.attachMenuBar()   // R5：主窗出现后创建菜单栏状态项（避免启动早期注册）
            state.runStartupDeprecationCheck()   // R16①：启动弃用检查
        }
        .sheet(isPresented: $state.showGuide) {
            GuideSheet()
        }
        // R16①：弃用弹窗（「稍后操作」收起——行内「更新ID」按钮仍在；「立即更新」续接更新模式）
        .sheet(isPresented: Binding(
            get: { !state.launchDeprecated.isEmpty && !noticeDismissed && updateFromNotice == nil },
            set: { if !$0 { noticeDismissed = true } }
        )) {
            VStack(alignment: .leading, spacing: 14) {
                Text("模型 ID 已被官方弃用").font(f(14, .semibold))
                Text("检测到以下模型 ID 已被官方弃用，继续使用可能存在兼容性问题：")
                    .font(f(12)).foregroundStyle(ink2).fixedSize(horizontal: false, vertical: true)
                // S7：条目多时限高滚动，防撑爆 sheet（≤6 项原样铺开）
                if state.launchDeprecated.count > 6 {
                    ScrollView { deprecatedRows }.frame(height: 208)
                } else {
                    deprecatedRows
                }
                HStack {
                    Button("稍后操作") { noticeDismissed = true }.cardBtn()
                    Spacer()
                    Button("立即更新") {
                        updateFromNotice = state.launchDeprecated.first
                        noticeDismissed = true
                    }
                    .cardBtn(primary: true)
                }
            }
            .padding(20)
            .frame(width: 440, alignment: .topLeading)
        }
        .sheet(item: $updateFromNotice) { target in
            ClaudeTierRegisterSheet(harnessID: target.harnessID, replacingField: target.field)
                .onDisappear {
                    let before = state.launchDeprecated.count
                    state.runStartupDeprecationCheck()
                    if state.launchDeprecated.count < before { noticeDismissed = false }   // 处理成功且仍有余项→续弹下一项
                }
        }
    }
}
