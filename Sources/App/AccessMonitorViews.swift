// MARK: - 访问配置面板与监视器终端（自 RoutesView 拆分·T9/I34，纯移动）
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ModelRouterCore

struct AccessPanel: View {
    @EnvironmentObject var state: AppState
    let harness: Harness
    @State private var keyShown = false

    var body: some View {
        let key = state.accessKeyText(for: harness.accessKeyRef)
        let baseURL = state.endpointText + (harness.proto == .anthropic ? "/claude" : "/codex")
        let other = harness.proto == .anthropic ? "Codex" : "Claude"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Base URL").font(f(11)).foregroundStyle(ink3).frame(width: 64, alignment: .leading)
                MonoBox(text: baseURL)
                copyIconBtn("doc.on.doc") { state.copy(baseURL) }
            }
            HStack(spacing: 8) {
                Text("访问 Key").font(f(11)).foregroundStyle(ink3).frame(width: 64, alignment: .leading)
                MonoBox(text: key, isSecret: !keyShown)
                copyIconBtn(keyShown ? "eye.slash" : "eye") { keyShown.toggle() }
                copyIconBtn("doc.on.doc") { state.copy(key) }
            }
            HStack(spacing: 12) {
                Button("重新生成 \(harness.name) Key") {
                    state.regenerateAccessKey(ref: harness.accessKeyRef, harnessName: harness.name)
                }
                .cardBtn(mini: true)
                Text("此 Key 仅 \(harness.name) 使用，与 \(other) 不通用；Gateway auth scheme 选 Bearer Token。")
                    .font(f(11)).foregroundStyle(ink3)
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(NSColor.quaternaryLabelColor).opacity(0.12))
        .overlay(Rectangle().fill(sep).frame(height: 1), alignment: .top)
    }
}

// MARK: - 监视器（卡内微型终端：深色、仅内存、最近 1 小时 · 上限 2000 条；五档分级显示）
struct MonitorTerm: View {
    @EnvironmentObject var state: AppState
    let harness: Harness
    @AppStorage("mr.monitor.level") private var minLevelRaw = LogLevel.info.rawValue
    @State private var frozen: [MonitorEvent]? = nil   // 暂停瞬间的快照；nil = 实时
    /// 单次渲染行数上限（最新在顶）；更早的事件走导出，避免整环重建富文本
    private static let renderCap = 200

    /// 档位从最全到最少；选中 = 显示该级及更严重
    private static let levelOptions: [(raw: Int, label: String)] = [
        (LogLevel.verbose.rawValue, "全部"),
        (LogLevel.debug.rawValue, "调试"),
        (LogLevel.info.rawValue, "信息"),
        (LogLevel.warning.rawValue, "警告"),
        (LogLevel.error.rawValue, "错误"),
    ]

    var body: some View {
        let paused = state.monitorPaused[harness.id, default: false]
        let minLevel = LogLevel(rawValue: minLevelRaw) ?? .info
        let all = frozen ?? state.monitorEvents(harnessID: harness.id, minimum: minLevel)
        let lines = Array(all.prefix(Self.renderCap))   // 渲染上限：整环重建富文本太贵，全量走导出
        let omitted = all.count - lines.count
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text("监视器 · modelrouter.\(harness.name.lowercased()).log")
                    .font(mono(10.5, .bold)).foregroundStyle(Color(red: 0.79, green: 0.79, blue: 0.82))
                Text("仅内存 · 最近 1 小时 · 上限 \(AppState.eventCap) 条").font(f(10.5)).foregroundStyle(termDim)
                Spacer()
                Picker("", selection: $minLevelRaw) {
                    ForEach(Self.levelOptions, id: \.raw) { opt in
                        Text(opt.label).tag(opt.raw)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.mini)
                .frame(width: 64)
                .help("显示等级：选中档位及更严重的事件（记录始终全量，切档不丢历史）")
                termBtn(paused ? "继续" : "暂停") {
                    state.monitorPaused[harness.id] = !paused
                }
                termBtn("导出") { exportLog() }
                termBtn("清空") { state.clearEvents(harnessID: harness.id) }
                termBtn("收起") { state.monitorOpen[harness.id] = false }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(termBarBg)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(eventText(lines))
                        .font(mono(10.5)).foregroundStyle(termText)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if omitted > 0 {
                        Text("… 更早 \(omitted) 条省略（导出见全量）")
                            .font(mono(10.5)).foregroundStyle(termDim)
                            .padding(.top, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .frame(minHeight: 72, maxHeight: 260)
            .background(termBg)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(termBorder, lineWidth: 1))
        // I3 三向统一留边（2026-09-17 真机实测：通用卡左右 28px/下 15px，Claude·Codex 卡左右 0/下 15px）：
        // 左右 14pt 对齐卡内内容内缩；下 6 + 卡底 8 = 14pt，三卡一致；上 10pt 属与上方内容的间距、保持不变
        .padding(.top, 10).padding(.horizontal, 14).padding(.bottom, 6)
        .onChange(of: paused) { _, p in
            // 暂停 = 冻结当前显示；记录仍在后台全量进行，恢复即见完整历史
            frozen = p ? state.monitorEvents(harnessID: harness.id,
                                             minimum: LogLevel(rawValue: minLevelRaw) ?? .info) : nil
        }
    }

    private func termBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(f(10.5)).foregroundStyle(termText)
                .padding(.horizontal, 8).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.17, green: 0.18, blue: 0.21))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(red: 0.23, green: 0.23, blue: 0.27), lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    /// 导出全量日志（不受当前显示档位影响）：保存面板 → JSON 落盘 → toast 确认
    private func exportLog() {
        guard let data = state.exportLogData() else {
            state.toast = "✗ 导出失败"; state.flashToast(); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "modelrouter-log-\(Self.exportStamp()).json"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                state.toast = "日志已导出"
                state.toastDetail = url.path
            } catch {
                state.toast = "✗ 写入失败：\(error.localizedDescription)"
            }
            state.flashToast()
        }
    }

    private static func exportStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: 行渲染（终端风：时间 等级 正文；等级着色，2xx 绿 / 异常红 / 降级黄）

    private func eventText(_ lines: [MonitorEvent]) -> AttributedString {
        guard !lines.isEmpty else {
            var a = AttributedString("— 尚无请求 — 该工具经路由的每次调用会实时出现在这里")
            a.foregroundColor = termDim
            return a
        }
        var out = AttributedString()
        for (i, m) in lines.enumerated() {
            if i > 0 { out += AttributedString("\n") }
            out += lineText(m.event)
        }
        return out
    }

    private func lineText(_ e: LogEvent) -> AttributedString {
        var out = AttributedString("\(Self.timeFmt.string(from: e.ts))  ")
        out.foregroundColor = termDim
        out.font = mono(10.5)

        var tag = AttributedString(Self.levelTag(e.level).padding(toLength: 7, withPad: " ", startingAt: 0))
        tag.foregroundColor = Self.levelColor(e.level)
        tag.font = mono(10.5, .bold)
        out += tag

        out += bodyText(e)
        return out
    }

    private func bodyText(_ e: LogEvent) -> AttributedString {
        let base = Self.levelColor(e.level)
        var body = AttributedString()
        func seg(_ s: String, _ c: Color? = nil, bold: Bool = false) {
            var a = AttributedString(s)
            a.foregroundColor = c ?? base
            a.font = mono(10.5, bold ? .semibold : .regular)
            body += a
        }
        switch e.phase {
        case .request:
            seg("\(e.method ?? "GET") \(e.path)")
            if let b = e.bytesIn { seg(" · \(Self.bytes(b))", termDim) }
        case .decision:
            if let target = e.targetModel {
                seg("→ \(target) @ \(e.vendor ?? "?")")
                if let msg = e.message { seg("  · \(msg)", termWarn) }
            } else if let s = e.status {
                seg("\(s) ", s < 400 ? termOk : termBad, bold: true)
                if let msg = e.message { seg(msg) }
            }
        case .upstreamHead:
            if let s = e.status {
                seg("上游 \(s) ", s < 400 ? termOk : termBad, bold: true)
                if let ms = e.durationMs { seg("· 首包 \(Self.ms(ms)) ", termDim) }
            }
            if let msg = e.message { seg(msg) }
        case .progress:
            seg("↑ 已回传 \(Self.bytes(e.bytesOut ?? 0))", termDim)
        case .finish:
            if let s = e.status {
                seg("\(s) ", (200...399).contains(s) ? termOk : termBad, bold: true)
            }
            if let d = e.durationMs { seg("· \(Self.ms(d)) ", termDim) }
            if let b = e.bytesOut { seg("· 回传 \(Self.bytes(b)) ", termDim) }
            if let msg = e.message { seg(msg, e.level == .error ? termBad : base) }
        }
        return body
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func levelTag(_ l: LogLevel) -> String {
        switch l {
        case .verbose: return "VERB"
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }

    private static func levelColor(_ l: LogLevel) -> Color {
        switch l {
        case .verbose, .debug: return termDim
        case .info:    return termText
        case .warning: return termWarn
        case .error:   return termBad
        }
    }

    private static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fKB", Double(n) / 1024) }
        return String(format: "%.1fMB", Double(n) / (1024 * 1024))
    }

    private static func ms(_ v: Int) -> String {
        v < 1000 ? "\(v)ms" : String(format: "%.1fs", Double(v) / 1000)
    }
}

// MARK: - 通用路由卡（自定义服务商聚合口：/anthropic 与 /v1 一把 Key，模型 ID = 供应商/模型名）
