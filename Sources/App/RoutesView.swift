import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ModelRouterCore

// MARK: - 管理路由（Harness 卡：卡头 / 访问配置 / 档位表 / 监视器）
struct RoutesView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewHeader(title: "路由管理",
                       tip: "一个 Harness 工具一张卡片，展开后逐行映射模型位。未映射的模型位请求将返回 404；切换即保存，不改动客户端配置。")
            .padding(.bottom, 14)
            ForEach(state.config.harnesses) { h in
                HarnessCard(harness: h)
            }
        }
    }
}

struct HarnessCard: View {
    @EnvironmentObject var state: AppState
    let harness: Harness
    @State private var expanded = true
    @State private var showRegister = false
    @State private var updateIDTarget: AppState.DeprecatedSlot? = nil   // R16①：行内「更新ID」目标

    /// 该卡支持的协议线（卡头提示用；Claude 仅 Messages、Codex 仅 Responses）
    private var supportedAPIs: [ModelAPI] {
        harness.proto == .anthropic ? [.messages] : [.responses]
    }

    var body: some View {
        if harness.universal == true { return AnyView(UniversalCard(harness: harness)) }
        if harness.proto == .openai { return AnyView(CodexCard(harness: harness)) }   // R8：Codex 卡纯派生
        let isClaude = harness.tierOrder != nil
        let mapped = harness.slots.filter { $0.isMapped }.count
        let enabled = harness.enabled ?? true
        let summary = !enabled
            ? "路由已停用"
            : (isClaude
                ? "\(mapped) 个已映射 · \(harness.slots.count - mapped) 个未映射"
                : "\(harness.slots.count) 个")
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            // ── 卡头 ──
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(ink3)
                    Text(harness.name).font(f(13.5, .bold))
                    Toggle("路由", isOn: Binding(
                        get: { harness.enabled ?? true },
                        set: { state.setHarnessEnabled(harnessID: harness.id, $0) }
                    ))
                    .toggleStyle(.switch).controlSize(.mini)
                    .foregroundStyle(ink2)
                    Spacer()
                    Text(summary).font(f(11.5)).foregroundStyle(ink3)
                    miniBtn("监视") {
                        state.monitorOpen[harness.id, default: false].toggle()
                    }
                    if isClaude {
                        miniBtn("Claude Code CLI 配置") { presentCLIConfig() }
                    }   // Codex 卡在 body 顶部分流到 CodexCard（配置按钮开 B 窗），此处仅 Claude 走到
                    miniBtn("访问配置") {
                        state.accessOpen[harness.id, default: false].toggle()
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── 支持协议提示（独立一行 · 全称 · 纯展示无检测语义）──
            HStack(spacing: 8) {
                ForEach(supportedAPIs, id: \.rawValue) { api in
                    ModelAPIBadge(api: api, long: true)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)   // P6：折叠态底部留白提出条件外

            // ── 访问配置面板 ──
            if state.accessOpen[harness.id, default: false] {
                AccessPanel(harness: harness)
            }

            // ── 档位表 + 监视器 ──
            // Grid 按列索引强制对齐表头与所有行（HStack 各自分布曾导致表头/控件错位）
            if expanded {
                VStack(alignment: .leading, spacing: 0) {   // leading：表格贴卡边（默认 center 致收窄后左右留空）
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {   // 列距 10→14：列间呼吸感
                        GridRow {
                            Text(isClaude ? "模型位" : "转发")
                                .frame(width: 88, alignment: .leading).font(f(11)).foregroundStyle(ink3)
                                .padding(.top, 8).padding(.bottom, 2)
                            Text("请求的模型").frame(width: 160, alignment: .leading).font(f(11)).foregroundStyle(ink3)
                                .padding(.top, 8).padding(.bottom, 2)
                            Text("供应商").frame(width: 180, alignment: .leading).font(f(11)).foregroundStyle(ink3)
                                .padding(.top, 8).padding(.bottom, 2)
                            if isClaude {
                                Text("模型锁定").frame(width: 50, alignment: .leading).font(f(11)).foregroundStyle(ink3)
                                    .padding(.top, 8).padding(.bottom, 2)
                            }
                            Text("状态").frame(maxWidth: .infinity, alignment: .leading).font(f(11)).foregroundStyle(ink3)
                                .padding(.top, 8).padding(.bottom, 2)
                            Color.clear.frame(width: 14)   // 删除列占位
                        }

                        ForEach(Array(harness.slots.enumerated()), id: \.offset) { i, slot in
                            TierRow(harness: harness, slot: slot, index: i,
                                    onUpdateID: isClaude
                                        ? { updateIDTarget = .init(harnessID: harness.id, field: slot.clientModelField) }
                                        : nil)
                        }
                    }
                    .padding(.horizontal, 14)

                    if isClaude {
                        HStack(spacing: 8) {
                            Button("＋ 添加模型位") { showRegister = true }
                                .cardBtn(mini: true)
                                .help("注册 Claude 兼容 ID（claude + 定位 + 自定义后缀）；完成映射后才进入模型发现")
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
                    }

                    if state.monitorOpen[harness.id, default: false] {
                        MonitorTerm(harness: harness)
                    }
                }
                .padding(.bottom, 8)
                .opacity(enabled ? 1 : 0.45)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1))
        .padding(.bottom, 12)   // 卡片间距统一 12
        .sheet(isPresented: $showRegister) {
            ClaudeTierRegisterSheet(harnessID: harness.id)
        }
        .sheet(item: $updateIDTarget) { target in
            ClaudeTierRegisterSheet(harnessID: target.harnessID, replacingField: target.field)
        })
    }

    /// Claude 卡「Claude Code CLI 配置」：承载 ~/.claude/settings.json（读 → 编辑 → 备份 → 覆盖 → 复原）
    private func presentCLIConfig() {
        let box = CLIDirtyBox()
        let guardDelegate = CLICloseGuard(box: box)
        FloatWindowCenter.shared.present(
            title: "Claude Code CLI 配置 · Claude",
            size: NSSize(width: 780, height: 640),
            reuseKey: "cli-config:\(harness.id)",
            closeGuard: guardDelegate) { w in
            CLIClientConfigView(harnessID: harness.id, onClose: { w.close() }, dirtyBox: box)
                .environmentObject(state)   // 独立窗口全新环境，必须手动注入 AppState
        }
    }

    private func miniBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).cardBtn(mini: true)
    }
}

// MARK: - Codex 卡（R8 纯派生架构）
// 行集合＝B 窗「添加的模型」（槽位键＝模型名称，slug=display_name 字面直用）；卡上仅供应商列可改；
// 无转发列、无 ⊖、无添加控件；表三列定参（管理员设计器定参 2026-09-29）：176 / 514（下拉 440）/ 152，列距 14、行高 44。
