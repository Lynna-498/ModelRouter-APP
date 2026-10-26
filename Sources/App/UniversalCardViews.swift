// MARK: - 通用路由卡与访问面板（自 RoutesView 拆分·T9/I34，纯移动）
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ModelRouterCore

struct UniversalCard: View {
    @EnvironmentObject var state: AppState
    let harness: Harness
    @State private var expanded = true
    @State private var accessOpen = false
    @State private var keyShown = false

    var body: some View {
        let modelCount = state.config.models.count
        return VStack(alignment: .leading, spacing: 0) {
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
                    HelpTip(tip: "模型 ID = 供应商/模型名（供应商名自动转全拼大写：智谱 → ZHIPU，英文名照抄）。客户端把 供应商/模型名 填进 model 字段即可；只下发模型库里已配置的供应商和模型。通用 ID 用模型管理页供应商条目行尾的复制按钮。")
                    Spacer()
                    Toggle("路由", isOn: Binding(
                        get: { harness.enabled ?? true },
                        set: { state.setHarnessEnabled(harnessID: harness.id, $0) }
                    ))
                    .toggleStyle(.switch).controlSize(.mini)
                    .foregroundStyle(ink2)
                    Text("直通 · 已配置模型 \(modelCount) 个").font(f(11.5)).foregroundStyle(ink3)
                    miniBtn("监视") { state.monitorOpen[harness.id, default: false].toggle() }
                    miniBtn("访问配置") { accessOpen.toggle() }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── 支持协议提示（独立一行 · 全称 · 通用路由三线全支持）──
            HStack(spacing: 8) {
                ForEach([ModelAPI.messages, .responses, .completions], id: \.rawValue) { api in
                    ModelAPIBadge(api: api, long: true)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)   // P6：折叠态底部留白

            // ── 访问配置面板 ──
            if accessOpen {
                UniversalAccessPanel(harness: harness, keyShown: $keyShown)
            }

            // ── 展开区：提示 + 监视器 ──
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型 ID = 供应商/模型名；通用 ID 在模型管理页复制。")
                        .font(f(11)).foregroundStyle(ink3)
                        .padding(.horizontal, 14)   // I3：水平内缩移到提示行，监视器自带三向留边，避免双重内缩
                    if state.monitorOpen[harness.id, default: false] {
                        MonitorTerm(harness: harness)
                    }
                }
                .padding(.top, 10).padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1))
        .padding(.bottom, 12)   // 卡片间距统一 12
    }

    private func miniBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).cardBtn(mini: true)
    }
}

// MARK: - 通用路由访问配置（两个 baseURL + 一把共用 Key）
struct UniversalAccessPanel: View {
    @EnvironmentObject var state: AppState
    let harness: Harness
    @Binding var keyShown: Bool

    var body: some View {
        let key = state.universalKey
        let baseURL = state.endpointText
        return VStack(alignment: .leading, spacing: 8) {
            row(label: "Anthropic", value: "\(baseURL)/anthropic",
                help: "Anthropic 兼容客户端填这个（仅通用路由 Key 生效；Claude 卡 Key 在此路径会被拒绝，接入 Claude 请用 /claude）")
            row(label: "OpenAI", value: "\(baseURL)/v1",
                help: "OpenAI 兼容客户端填这个；responses 与 chat/completions 都走它")
            HStack(spacing: 8) {
                Text("访问 Key").font(f(11)).foregroundStyle(ink3).frame(width: 64, alignment: .leading)
                MonoBox(text: key, isSecret: !keyShown)
                copyIconBtn(keyShown ? "eye.slash" : "eye") { keyShown.toggle() }
                copyIconBtn("doc.on.doc") { state.copy(key) }
            }
            HStack(spacing: 12) {
                Button("重新生成通用路由 Key") {
                    state.regenerateAccessKey(ref: harness.accessKeyRef, harnessName: "通用路由")
                }
                .cardBtn(mini: true)
                Text("一把 Key 两个地址共用；与 Claude、Codex 卡的 Key 不通用。")
                    .font(f(11)).foregroundStyle(ink3)
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(NSColor.quaternaryLabelColor).opacity(0.12))
        .overlay(Rectangle().fill(sep).frame(height: 1), alignment: .top)
    }

    private func row(label: String, value: String, help: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(f(11)).foregroundStyle(ink3).frame(width: 64, alignment: .leading)
            MonoBox(text: value)
            copyIconBtn("doc.on.doc") { state.copy(value) }
        }
        .help(help)
    }
}
