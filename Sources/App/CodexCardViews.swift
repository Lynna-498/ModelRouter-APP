// MARK: - Codex 卡与槽位行（自 RoutesView 拆分·T9/I34，纯移动）
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ModelRouterCore

struct CodexCard: View {
    @EnvironmentObject var state: AppState
    let harness: Harness
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    Text("\(harness.slots.count) 个").font(f(11.5)).foregroundStyle(ink3)
                    miniBtn("监视") {
                        state.monitorOpen[harness.id, default: false].toggle()
                    }
                    miniBtn("配置") { presentCodexConfig() }
                    miniBtn("访问配置") {
                        state.accessOpen[harness.id, default: false].toggle()
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                ModelAPIBadge(api: .responses, long: true)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)

            if state.accessOpen[harness.id, default: false] {
                AccessPanel(harness: harness)
            }

            let enabled = harness.enabled ?? true
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    table
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
        .padding(.bottom, 12)
    }

    // ── 表：三列 176 / 弹性 / 152 贴右，列距 14（供应商列充满剩余卡宽——复验问题1：定宽 514 曾把主窗顶宽）
    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    Text("请求的模型")
                        .frame(width: 176, alignment: .leading).font(f(11)).foregroundStyle(ink3)
                        .padding(.top, 8).padding(.bottom, 2)
                    Text("供应商")
                        .frame(maxWidth: .infinity, alignment: .leading).font(f(11)).foregroundStyle(ink3)
                        .padding(.top, 8).padding(.bottom, 2)
                    Text("状态")
                        .frame(width: 152, alignment: .trailing).font(f(11)).foregroundStyle(ink3)
                        .padding(.top, 8).padding(.bottom, 2)
                }
                ForEach(harness.slots, id: \.clientModelField) { slot in
                    CodexRow(harness: harness, slot: slot)
                }
            }
            .padding(.horizontal, 14)

            if harness.slots.isEmpty {
                Text("暂无添加的模型")
                    .font(f(12)).foregroundStyle(ink3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            }
        }
    }

    /// Codex CLI 配置窗（B 窗）：承载 ~/.codex/config.toml 与 model_modelrouter.json（读 → 编辑 → 备份 → 覆盖 → 复原）
    private func presentCodexConfig() {
        let box = CLIDirtyBox()
        let guardDelegate = CLICloseGuard(box: box,
                                          message: "config.toml / model_modelrouter.json 有未保存的更改，关闭后将丢失。",
                                          invalidMessage: "当前修改不合法（TOML 解析失败，或思考档位未覆盖模型元数据），无法保存。继续编辑修复，或直接退出放弃全部修改。")
        FloatWindowCenter.shared.present(
            title: "Codex CLI 配置 · \(harness.name)",
            size: NSSize(width: 780, height: 640),
            reuseKey: "codex-config:\(harness.id)",
            closeGuard: guardDelegate) { w in
            CodexCLIConfigView(harnessID: harness.id, onClose: { w.close() }, dirtyBox: box)
                .environmentObject(state)   // 独立窗口全新环境，必须手动注入 AppState
        }
    }

    private func miniBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).cardBtn(mini: true)
    }
}

/// Codex 卡行：名称文本（纯派生，不可改）｜供应商自绘下拉（唯一可改）｜状态贴右
struct CodexRow: View {
    @EnvironmentObject var state: AppState
    let harness: Harness
    let slot: Slot

    private var invalid: Bool { state.slotInvalid(slot, .responses) }

    /// 供应商池＝该名称（行键即名称）在 responses 线的可用供应商；当前绑定不在池时补入（标不可用）
    private var vendorOptions: [Vendor] {
        var pool = state.vendorPool(groupName: slot.clientModelField, .responses)
        if let vid = slot.vendorID, !pool.contains(where: { $0.id == vid }),
           let v = state.config.vendors.first(where: { $0.id == vid }) {
            pool.insert(v, at: 0)
        }
        return pool
    }

    var body: some View {
        GridRow {
            // 请求的模型（名称文本；存量不合规名称标警示、悬停说明）
            cell(invalid) {
                HStack(spacing: 6) {
                    if !AppState.isCodexCompliantName(slot.clientModelField) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(warnColor)
                            .help("名称不合规（Codex slug 仅 ASCII、不含空格）——请到模型管理页改名后生效")
                    }
                    Text(slot.clientModelField).font(f(12.5, .semibold))
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(width: 176 - 16, height: 44, alignment: .leading)
            }

            // 供应商（唯一可改列；自绘下拉充满弹性列，随卡宽自适应）
            cell(invalid) {
                SelfDrawnDropdown<UUID>(
                    items: vendorOptions.map(\.id),
                    title: { vid in
                        let name = state.config.vendors.first { $0.id == vid }?.name ?? vid.uuidString
                        return (vid == slot.vendorID && invalid) ? name + "（不可用）" : name
                    },
                    selection: Binding(
                        get: { slot.vendorID },
                        set: { state.setSlotVendor(harnessID: harness.id, field: slot.clientModelField, vendorID: $0) }
                    ),
                    placeholder: vendorOptions.isEmpty ? "暂无可用供应商" : "选择供应商",
                    disabled: vendorOptions.isEmpty
                )
                .frame(maxWidth: .infinity)
            }

            // 状态（152 贴右）
            cell(invalid) {
                HStack(spacing: 6) {
                    if invalid {
                        Dot(color: warnColor, size: 8)
                        Text("映射已失效，请重选").font(f(11)).foregroundStyle(errColor)
                    } else if slot.isMapped {
                        Dot(color: okColor, size: 8)
                        Text("转发中").font(f(11)).foregroundStyle(ink2)
                    } else {
                        Dot(color: ink3, size: 8)
                        Text("未映射").font(f(11)).foregroundStyle(ink2)
                    }
                }
                .frame(width: 152, height: 44, alignment: .trailing)
                .lineLimit(1)
            }
        }
    }

    /// 行内单元格：统一行高与底部分隔线（对齐 TierRow 视觉）
    @ViewBuilder
    private func cell<V: View>(_ invalid: Bool, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(height: 44)
            .background(invalid ? Color(nsColor: .systemRed).opacity(0.07) : Color.clear)
            .overlay(Rectangle().fill(sep.opacity(0.55)).frame(height: 1), alignment: .bottom)
    }
}

// MARK: - Claude 模型位注册窗（仅注册 ID；映射回档位行完成，注册后立即落盘）
