import SwiftUI

// MARK: - 导航
enum NavView: String, CaseIterable, Identifiable {
    case vendors = "供应商管理"
    case models = "模型管理"
    case routes = "路由管理"

    var id: String { rawValue }
}

// MARK: - 侧栏（对齐原型：三项导航 + 底部配置引导）
struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 2) {
            // D1：hiddenTitleBar 后红绿灯浮于侧栏上沿；安全区已让位约 28pt，顶垫勿重复计数（F6）
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("ModelRouter").font(f(15, .bold)).lineLimit(1)   // F7：字号加大、去中文副标、单行
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.top, 4).padding(.bottom, 8)
            ForEach(NavView.allCases) { v in
                navButton(v)
            }
            Spacer()
            statusRow
            HStack(spacing: 7) {
                Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(ink2)
                Button {
                    state.showGuide = true
                } label: {
                    Text("配置引导").font(f(12)).foregroundStyle(ink2)
                        .underline()
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
        }
        .padding(.horizontal, 8).padding(.bottom, 10)
        .background(sidebarBg)   // 顶栏由 RootView 硬填充条提供，侧栏背景不再延伸安全区
        .sheet(item: $state.portSheet) { _ in PortSheet() }
    }

    // MARK: - 监听状态行（R1：常驻侧栏底部；红/黄/绿灯 + 端点，点击改端口）
    private var statusRow: some View {
        Button {
            state.portSheet = PortSheetState(mode: .settings)
        } label: {
            HStack(spacing: 7) {
                Dot(color: statusColor, size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(f(11.5)).foregroundStyle(ink2)
                    Text(statusSub).font(mono(9.5)).foregroundStyle(ink3)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.quaternaryLabelColor).opacity(0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.serverPhase == .starting || state.portSheet != nil)   // 防重入 / 至多一个弹窗
        .help(statusHelp)
        .padding(.bottom, 5)   // S7：外层横距去除——盒沿 x=8、文字 x=17 与导航项对齐（曾内 8 外 9 双层错位 8pt）
    }

    private var statusColor: Color {
        switch state.serverPhase {
        case .running:  return okColor
        case .failed:   return errColor
        case .starting: return warnColor
        }
    }
    private var statusTitle: String {
        switch state.serverPhase {
        case .running:  return "监听中"
        case .failed:   return "端口冲突"
        case .starting: return "启动中…"
        }
    }
    private var statusSub: String {
        switch state.serverPhase {
        case .running:  return state.endpointText
        case .failed:   return ":\(state.config.endpoint.port) 被占 · 点击处理"
        case .starting: return "正在绑定 :\(state.config.endpoint.port)"
        }
    }
    private var statusHelp: String {
        switch state.serverPhase {
        case .running:  return "监听正常 · 点击修改端口（客户端 Base URL 需随之更新）"
        case .failed:   return "端口监听失败 · 点击打开处理弹窗（重试 / 改端口）"
        case .starting: return "正在绑定端口…"
        }
    }

    private func navButton(_ v: NavView) -> some View {
        let on = state.selected == v
        return Button {
            state.selected = v
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon(v)).font(.system(size: 14)).frame(width: 16)
                Text(v.rawValue).font(f(13))
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? accent : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(_ v: NavView) -> String {
        switch v {
        case .vendors: return "plus.circle"
        case .models:  return "square.grid.2x2"
        case .routes:  return "shuffle"
        }
    }
}

// MARK: - 详情区
struct DetailPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch state.selected {
                case .routes:  RoutesView()
                case .vendors: VendorsView()
                case .models:  ModelsView()
                }
            }
            .frame(maxWidth: 720)   // 详情列居中：修左右留白不对称（26/45 → 等宽）
                                        // R8 复验问题1（2026-09-29）：曾为 Codex 卡定宽 900 改 952，内容最小宽把主窗顶到 ~1140pt——已回退，
                                        // Codex 卡供应商列改弹性充满自适应列宽（宽度参数 514/440/900 废除，176/14/152/44 保留）
            .padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 26)   // F6：顶部留白收紧
        }
        .frame(maxWidth: .infinity)
        .background(winBg)   // 同上：顶部硬填充条由 RootView 提供
    }
}

// MARK: - 端口弹窗（R1：settings/conflict 双模；校验红字 + 确认/重试/稍后；监听成功自动关闭）
struct PortSheet: View {
    @EnvironmentObject var state: AppState
    @State private var input = ""
    @State private var err = ""

    private var conflict: (port: Int, detail: String)? {
        guard let mode = state.portSheet?.mode, case .conflict(let p, let d) = mode else { return nil }
        return (p, d)
    }
    private var starting: Bool { state.serverPhase == .starting }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(conflict == nil ? "修改监听端口" : "端口冲突").font(f(14.5, .semibold))
                HelpTip(tip: "端口全局唯一（Claude / Codex / 通用路由三张卡共用），真源是 config.json 的 endpoint.port。改端口会立即中断在途请求；成功后客户端 Base URL 需更新为新地址（横幅提供复制）。")
            }
            if let c = conflict {
                VStack(alignment: .leading, spacing: 4) {
                    Text("端口 \(c.port) 无法监听：\(c.detail)")
                        .font(f(12)).foregroundStyle(errColor)
                    Text("可能被旧 ModelRouter 实例或其他进程占用。终端查占用：lsof -i :\(c.port)；杀掉占用者后点「重试」，或直接改用新端口。")
                        .font(f(11.5)).foregroundStyle(ink2).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(errColor.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(errColor.opacity(0.3), lineWidth: 1)))
            }
            SheetField(label: { fieldLabel("新端口", sub: "1024–65535") }) {
                HStack(spacing: 8) {
                    InpField(placeholder: "", monoStyle: true, text: $input, bad: err != "")
                        .frame(width: 90)   // S7：130 对 5 位数字过宽；当前端口由右侧常显文字承担
                    Text("当前：\(state.config.endpoint.port)").font(f(11)).foregroundStyle(ink3)
                }
            }
            HintLine(text: err, bad: true, indent: 108)
            HintLine(text: starting ? "正在重启监听…" : "", bad: false, indent: 108)
            Text("修改成功后，访问配置面板与配置引导里的 Base URL 自动更新；路由行为不受端口影响。")
                .font(f(11)).foregroundStyle(ink3).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if conflict != nil {
                    Button("重试") { retry() }.cardBtn().disabled(starting)
                }
                Spacer()
                Button(conflict == nil ? "取消" : "稍后") { state.dismissPortSheet() }.cardBtn().disabled(starting)
                Button("确认") { confirm() }.cardBtn(primary: true).disabled(starting)
            }
            .padding(.top, 4)
        }
        .padding(20).frame(width: 440)   // 弹窗宽度档统一：440（确认/端口/弃用）
        .interactiveDismissDisabled(starting)
        .onChange(of: input) { _, _ in if err != "" { err = "" } }
    }

    private func confirm() {
        let raw = input.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { err = "请填写端口号"; return }
        if let e = state.setPort(raw) { err = e; return }
        err = ""
        // 已受理：弹窗保持打开显示「正在重启监听…」（按钮禁用）；
        // onLifecycle 成功 → portSheet 置 nil 自动关窗；失败 → 转新 conflict 原地刷新
    }

    private func retry() {
        err = ""
        state.retryServer()
    }
}
