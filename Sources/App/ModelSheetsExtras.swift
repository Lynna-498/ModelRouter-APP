// MARK: - 默认来源与组改名两张 sheet（自 ModelsView 拆分·T9/I34，纯移动）
import SwiftUI
import ModelRouterCore

struct DefaultSourcesSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    let group: ModelGroup

    private static let apis: [ModelAPI] = [.messages, .responses, .completions]
    /// 固定列宽：保证表头、徽标列、选择框逐行对齐
    private static let vendorCol: CGFloat = 150
    private static let apiCol: CGFloat = 115    // I4：650 宽 + 短称；短徽标 "Completions"≈82pt < 115，余 33pt
    private static let pickerCol: CGFloat = 220

    private var current: [String: UUID] { state.defaults(for: group.title) }

    /// 供应商行（从扁平条目就地按供应商重分组：同供应商多条目竖排——同名多 ID 共存）
    private var vendorRows: [(vendor: Vendor, entries: [ModelEntry])] {
        var order: [UUID] = []
        var byV: [UUID: [ModelEntry]] = [:]
        for e in group.sections.flatMap(\.entries) {
            if byV[e.vendorID] == nil { order.append(e.vendorID) }
            byV[e.vendorID, default: []].append(e)
        }
        return order.compactMap { vid in
            state.config.vendors.first(where: { $0.id == vid }).map { ($0, byV[vid]!) }
        }
    }

    /// 该线探测通过的供应商（选择框候选；未通过者不可选）
    private func supporters(_ api: ModelAPI) -> [Vendor] {
        vendorRows
            .filter { row in row.entries.contains { $0.probeResults?[api.rawValue] == true } }
            .map(\.vendor)
    }

    /// 选择框条目：未设置 + 该线测通者；当前值若已未测通则附加保留项以便清除
    private func pickerItems(_ api: ModelAPI) -> [(tag: UUID?, title: String)] {
        var items: [(tag: UUID?, title: String)] = [(nil, "未设置")]
        for v in supporters(api) { items.append((v.id, v.name)) }
        if let cur = current[api.rawValue],
           !supporters(api).contains(where: { $0.id == cur }),
           let cv = state.config.vendors.first(where: { $0.id == cur }) {
            items.append((cur, "\(cv.name)（当前 · 该线未测通）"))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("默认来源 · \(group.title)").font(f(14.5, .semibold))
                HelpTip(tip: "三条线彼此独立：路由管理里选模型时按该卡协议线自动填默认来源（Claude 卡看 Messages、Codex 卡看 Responses）。下表徽标是各供应商在该名称下每条线的检测结论；每线只能从检测通过的供应商里选。")
            }
            // ── 支持情况矩阵（列宽固定，逐行对齐）──
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("供应商").font(f(11)).foregroundStyle(ink3)
                        .frame(width: Self.vendorCol, alignment: .leading)
                    ForEach(Self.apis, id: \.rawValue) { api in
                        Text(api.label).font(f(11)).foregroundStyle(ink3)
                            .frame(width: Self.apiCol, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                ForEach(vendorRows, id: \.vendor.id) { row in
                    HStack(spacing: 10) {
                        Text(row.vendor.name).font(f(12)).lineLimit(1)
                            .frame(width: Self.vendorCol, alignment: .leading)
                        ForEach(Self.apis, id: \.rawValue) { api in
                            VStack(alignment: .leading, spacing: 3) {   // 同格多条目竖排（短徽标 ≈82pt/枚）
                                ForEach(row.entries) { e in
                                    ModelAPIBadge(api: api, avail: state.availability(e, api))
                                }
                            }
                            .frame(width: Self.apiCol, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .overlay(Rectangle().fill(sep).frame(height: 1), alignment: .bottom)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1)))
            // ── 按线设置默认来源（标签列/选择框列固定宽，逐行对齐）──
            ForEach(Self.apis, id: \.rawValue) { api in
                HStack(spacing: 10) {
                    Text(api.label).font(f(12)).foregroundStyle(ink2).lineLimit(1)
                        .frame(width: Self.vendorCol + 42, alignment: .trailing)
                    NativeMenuPicker<UUID>(
                        items: pickerItems(api),
                        selection: Binding(
                            get: { current[api.rawValue] },
                            set: { state.setDefault(groupKey: group.title, api: api, vendorID: $0) }
                        )
                    )
                    .frame(width: Self.pickerCol, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.cardBtn(primary: true)
            }
            .padding(.top, 4)
        }
        .padding(24).frame(width: 650)   // I4：650 宽 + 短称（Messages/Responses/Completions）；列宽 150/115/220
    }
}

// MARK: - 重命名名称组（组头 ⋯ 入口；D 区形态：预填现名并全选＋？帮助＋ASCII 约束＋级联改名链）
struct GroupRenameSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    let group: ModelGroup
    @State private var name = ""
    @State private var err = ""
    @FocusState private var nameFocused: Bool

    /// R8 名称约束（slug=display_name=名称字面直用）：仅 ASCII；空格输入侧自动转 -；非 ASCII 拦截并禁存。
    /// 未改动的存量名称不拦（存量保留口径）。
    private func recheck(_ newValue: String) {
        let converted = newValue.replacingOccurrences(of: " ", with: "-")
        if converted != newValue { name = converted; return }
        let t = name.trimmingCharacters(in: .whitespaces)
        err = (t.isEmpty || t == group.title || AppState.isCodexCompliantName(t))
            ? "" : "名称仅支持 ASCII 字符（中文等不可用）；空格会自动转换为 -。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("重命名该组").font(f(14.5, .semibold))
                HelpTip(tip: "改名影响范围：组内全部 \(group.entryCount) 条条目改到新名称下（默认来源按线并入新名称，同名组合并）；Codex 侧 slug/显示名、添加的模型行、默认模型键与 model_modelrouter.json 条目一并级联更新（仅 ModelRouter 接管时自动改写文件）。名称仅支持 ASCII 字符，空格自动转为 -。")
            }
            SheetField(label: { fieldLabel("新名称") }) {
                InpField(text: $name, bad: !err.isEmpty)
                    .focused($nameFocused)
                    .onChange(of: name) { _, new in recheck(new) }
            }
            HintLine(text: err, bad: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.cardBtn()
                Button("保存") { save() }.cardBtn(primary: true)
                    .disabled(!err.isEmpty)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear {
            name = group.isNameless ? "" : group.title
            nameFocused = true
            // 预填现名并全选（弹窗形态规范 2）
            DispatchQueue.main.async {
                (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
            }
        }
    }

    private func save() {
        let nm = name.trimmingCharacters(in: .whitespaces)
        guard !nm.isEmpty else { err = "新名称不能为空。"; return }
        guard AppState.isCodexCompliantName(nm) else { return }   // 非法期间保存不可用（禁用＋双保险）
        guard nm != group.title else { dismiss(); return }
        state.renameGroup(from: group.title, to: nm)   // R8 级联：codexSlug/槽位键/受管文件随动
        state.toast = "已重命名组：\(group.title) → \(nm)"
        state.flashToast()
        dismiss()
    }
}

// MARK: - 第三层：供应商条目行（一行 = 一个 (供应商, 模型 ID) 条目；徽标/通用 ID 复制/真实测试/删除均为 per-entry）
