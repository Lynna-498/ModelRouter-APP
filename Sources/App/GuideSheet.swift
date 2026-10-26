import SwiftUI
import ModelRouterCore

// MARK: - 配置引导 sheet（三步 + 警示条，对齐原型）
struct GuideSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("配置引导").font(f(14.5, .semibold))

            // 1. 本地监听
            HStack(alignment: .top, spacing: 11) {
                stepNum(1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ModelRouter 已在本地监听").font(f(12.5))
                    HStack(spacing: 10) {
                        Text(state.endpointText).font(mono(11.5)).foregroundStyle(ink2)
                            .textSelection(.enabled)
                        LinkBtn(title: "复制") { state.copy(state.endpointText) }   // S7：手写文字链换 Theme.LinkBtn（悬停/光标语义同款）
                    }
                }
            }

            // 2. 客户端填端点与 Key（P8：每步一句 + HelpTip 承载说明）
            HStack(alignment: .top, spacing: 11) {
                stepNum(2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("在客户端填入端点与访问 Key").font(f(12.5))
                        HelpTip(tip: "Claude、Codex 各一把 Key，不通用；通用路由一把 Key 共用两个地址（…/anthropic 与 …/v1），模型填 供应商/模型名（如 ZHIPU/GLM-5.3-Flash）。Codex 在 config.toml 填本地端点。")
                    }
                    Text("两者在对应卡的「访问配置」获取；写入后需重启该客户端一次。")
                        .font(f(11.5)).foregroundStyle(ink2)
                }
            }

            // 3. 供应商 → 模型 → 路由
            HStack(alignment: .top, spacing: 11) {
                stepNum(3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("添加供应商 → 添加模型 → 设置路由").font(f(12.5))
                        HelpTip(tip: "模型元数据推荐粘贴官方 models.json 的单条；没有官方元数据（如 Kimi）时用编辑窗「手动配置」生成最小条目。")
                    }
                    Text("Codex 接入的模型还需粘贴元数据（见 ?）。")   // S7：细节由 ？ 承载，行内只留指向
                        .font(f(11.5)).foregroundStyle(ink2)
                }
            }

            // 警示条
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shippingbox").font(.system(size: 12)).foregroundStyle(ink3).padding(.top, 2)
                Text("本应用只做地址路由，不做 Anthropic↔OpenAI 协议转换；「CLI 配置」仅在用户明确确认后写入 ~/.claude/settings.json，写入前自动备份。")
                    .font(f(11.5)).foregroundStyle(ink2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.quaternaryLabelColor).opacity(0.18)))

            HStack {
                Spacer()
                Button("完成") { dismiss() }.cardBtn()
                Button("去添加供应商") {
                    dismiss()
                    state.selected = .vendors
                }
                .cardBtn(primary: true)
            }
            .padding(.top, 4)
        }
        .padding(20).frame(width: 500)   // S7：内衬统一 20；宽度档＝440（确认/端口/弃用）/500（引导）
    }

    private func stepNum(_ n: Int) -> some View {
        Text("\(n)").font(f(11.5, .bold)).foregroundStyle(.white)
            .frame(width: 21, height: 21)
            .background(Circle().fill(accent))
    }
}
