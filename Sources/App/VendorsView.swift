import SwiftUI
import ModelRouterCore

// MARK: - 供应商管理（空态 + 列表 + 添加/编辑 + 删除确认）
struct VendorsView: View {
    @EnvironmentObject var state: AppState
    @State private var showAdd = false
    @State private var editing: Vendor? = nil
    @State private var confirm: ConfirmRequest? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ViewHeader(title: "供应商管理",
                           tip: "登记供应商连接。每家可配置 Anthropic 与 OpenAI 两个原生端点，至少填一个。「测试」只确认端点地址真实存在，不消耗 Token；模型级兼容性在添加模型时用真实请求检测，或用模型管理条目行的心电图键随时复测（产生真实消费）。",
                           note: state.config.vendors.isEmpty ? "" : "\(state.config.vendors.count) 家")
                Button("＋ 添加供应商") { showAdd = true }.cardBtn(primary: true)
            }
            .padding(.bottom, 14)

            if state.config.vendors.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "plus.circle").font(.system(size: 24)).foregroundStyle(ink3)
                    Text("还没有供应商").font(f(12.5)).foregroundStyle(ink2)
                    Button("＋ 添加供应商") { showAdd = true }.cardBtn(primary: true)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1)))
            } else {
                VStack(spacing: 0) {
                    ForEach(state.config.vendors) { v in
                        VendorRow(vendor: v,
                                  onEdit: { editing = v },
                                  onDelete: { askDelete(v) })
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1)))
            }
        }
        .sheet(isPresented: $showAdd) { AddVendorSheet(editing: nil) }
        .sheet(item: $editing) { v in AddVendorSheet(editing: v) }
        .sheet(item: $confirm) { req in ConfirmSheet(request: req) }
    }

    private func askDelete(_ v: Vendor) {
        let ms = state.config.models.filter { $0.vendorID == v.id }
        let used = state.harnessUsage(vendorID: v.id)
        let msg: String
        if !used.isEmpty {
            msg = "「\(v.name)」下有 **\(ms.count)** 个模型，其中 \(used.map { "**\($0)**" }.joined(separator: "、")) 正在使用。\n删除供应商会一并移除其模型，受影响映射回到未映射。"
        } else {
            msg = "「\(v.name)」下有 **\(ms.count)** 个模型，将一并移除。"
        }
        confirm = ConfirmRequest(title: "删除供应商", message: msg) {
            state.deleteVendor(v)
        }
    }
}

// MARK: - 供应商行（名称+徽标 / 等宽端点 / 连通性测试 / 模型数 / 编辑·删除）
struct VendorRow: View {
    @EnvironmentObject var state: AppState
    let vendor: Vendor
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let running = state.vendorProbe[vendor.id]?.values.contains(.running) == true
        return HStack(spacing: 14) {
            Text(vendor.name).font(f(13, .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 端点列只放灯牌：配置情况看灯牌状态，无任何内联文字（2026-09-15 管理员口径）；
            // 固定槽宽保跨行对齐；URL 与原因在悬停提示与编辑 sheet 查看
            ProtoBadge(proto: .anthropic, avail: badgeAvail(.anthropic))
                .frame(width: 84, alignment: .leading)
            ProtoBadge(proto: .openai, avail: badgeAvail(.openai))
                .frame(width: 84, alignment: .leading)
            Text("\(state.modelCount(for: vendor.id)) 个模型入库")
                .font(f(11.5)).foregroundStyle(ink2)
                .frame(width: 84, height: 22, alignment: .trailing)
            HStack(spacing: 12) {
                Button("测试") { state.probeVendor(vendor) }
                    .cardBtn(mini: true)
                    .disabled(running)
                LinkBtn(title: "编辑", action: onEdit)
                LinkBtn(title: "删除", danger: true, action: onDelete)
            }
            .frame(width: 150, height: 22, alignment: .trailing)   // 操作列定宽+定高：按钮组跨行不漂移、与统计同高
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(Rectangle().fill(sep).frame(height: 1), alignment: .bottom)
    }

    /// 灯牌状态即配置情况（I7 修订 2026-09-28）：亮=检测通过；黄=已配置未检测（含 baseURL 变更作废重测）；
    /// 灰=未配置/不可达/检测中。URLSupport 持久化布尔驱动；未配置由端点有无判定。
    private func badgeAvail(_ proto: Proto) -> Avail? {
        if state.vendorProbe[vendor.id]?[proto] == .running { return .off("检测中") }
        let base = proto == .anthropic ? vendor.anthropicBase : vendor.openaiBase
        guard base != nil else { return .off("未配置") }
        let s = proto == .anthropic ? vendor.anthropicURLSupport : vendor.openaiURLSupport
        if let s { return s ? nil : .off("不可达") }
        return .untested
    }
}

// MARK: - 添加/编辑供应商 sheet（逐字段校验 + 至少一个端点）
struct AddVendorSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    var editing: Vendor?
    @State private var name = ""
    @State private var apiKey = ""
    @State private var anthURL = ""
    @State private var openURL = ""
    @State private var keyShown = false
    @State private var anthErr = ""
    @State private var openErr = ""
    @State private var formErr = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(editing == nil ? "添加供应商" : "编辑供应商").font(f(14.5, .semibold))
                HelpTip(tip: "两个 Base URL 至少填写一个：Claude 用 Anthropic 端点，Codex 用 OpenAI 端点。API Key 两协议共用。")
            }
            SheetField(label: { fieldLabel("供应商名称") }) {
                InpField(text: $name)
            }
            SheetField(label: { fieldLabel("API Key") }) {
                HStack(spacing: 6) {
                    InpField(placeholder: "", monoStyle: true, secure: !keyShown, text: $apiKey)
                    Button {
                        keyShown.toggle()
                    } label: {
                        Image(systemName: keyShown ? "eye.slash" : "eye").font(.system(size: 12)).foregroundStyle(ink3)
                    }.buttonStyle(.plain)
                }
            }
            SheetField(label: { URLFieldLabel(proto: .anthropic) }) {
                InpField(placeholder: "https://…/anthropic", monoStyle: true, text: $anthURL, bad: anthErr != "")
            }
            HintLine(text: anthErr, bad: true, indent: 108)
            HintLine(text: VendorValidator.suffixHint(anthURL, kind: .anthropic) ?? "", bad: false, indent: 108)
            SheetField(label: { URLFieldLabel(proto: .openai) }) {
                InpField(placeholder: "https://…/v1", monoStyle: true, text: $openURL, bad: openErr != "")
            }
            HintLine(text: openErr, bad: true, indent: 108)
            HintLine(text: VendorValidator.suffixHint(openURL, kind: .openai) ?? "", bad: false, indent: 108)
            HintLine(text: formErr, bad: true, indent: 0)
            HStack {
                Button("取消") { dismiss() }.cardBtn()
                Spacer()
                Button(editing == nil ? "保存供应商" : "保存") { save() }.cardBtn(primary: true)
            }
            .padding(.top, 6)
        }
        .padding(24).frame(width: 500)
        .onAppear(perform: load)
        .onChange(of: anthURL) { _, _ in revalidateIfNeeded(kind: .anthropic) }
        .onChange(of: openURL) { _, _ in revalidateIfNeeded(kind: .openai) }
    }

    private func load() {
        guard let v = editing else { return }
        name = v.name
        apiKey = KeychainStore.get(v.keyRef, domain: .vendor) ?? ""
        anthURL = v.anthropicBase?.absoluteString ?? ""
        openURL = v.openaiBase?.absoluteString ?? ""
    }

    /// 出过错后边输入边重校验（对齐原型 hintline 交互）
    private func revalidateIfNeeded(kind: Proto) {
        switch kind {
        case .anthropic:
            if anthErr != "" { anthErr = VendorValidator.validateBaseURL(anthURL, kind: .anthropic) ?? "" }
        case .openai:
            if openErr != "" { openErr = Self.openaiParseError(openURL) }
        }
    }

    /// OpenAI 兼容 base 的唯一检查：能否解析成 URL（格式策略不校验，存在性交给「测试」）
    private static func openaiParseError(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || URL(string: t) != nil { return "" }
        return "地址无法解析"
    }

    private func save() {
        formErr = ""
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { formErr = "请填写供应商名称。"; return }
        let aErr = VendorValidator.validateBaseURL(anthURL, kind: .anthropic) ?? ""
        anthErr = aErr
        // OpenAI 兼容 base 信任用户：不格式校验、不变更（仅 trim），存在性由「测试」判定
        let oNorm = openURL.trimmingCharacters(in: .whitespaces)
        openErr = Self.openaiParseError(openURL)
        if !aErr.isEmpty || !openErr.isEmpty {
            formErr = "Base URL 格式有误，请修正后保存。"
            return
        }
        let aNorm = VendorValidator.normalize(anthURL)
        if aNorm.isEmpty && oNorm.isEmpty { formErr = "请至少填写一个 Base URL。"; return }
        if !aNorm.isEmpty && !oNorm.isEmpty && aNorm == oNorm {
            openErr = "两个端点不能是同一地址"
            formErr = "Anthropic 与 OpenAI 端点地址不能相同。"
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let keyRef = editing?.keyRef ?? "vendor-" + UUID().uuidString
        var vendor = Vendor(id: editing?.id ?? UUID(), name: n, keyRef: keyRef,
                            anthropicBase: aNorm.isEmpty ? nil : URL(string: aNorm),
                            openaiBase: oNorm.isEmpty ? nil : URL(string: oNorm))
        // 端点语义没变则保留旧的 URLSupport 检测结论；变了就作废重测（I7：语义比对，写法差异不误判）
        if let e = editing, let old = state.config.vendors.first(where: { $0.id == e.id }) {
            if VendorValidator.sameEndpoint(old.anthropicBase, vendor.anthropicBase) { vendor.anthropicURLSupport = old.anthropicURLSupport }
            if VendorValidator.sameEndpoint(old.openaiBase, vendor.openaiBase) { vendor.openaiURLSupport = old.openaiURLSupport }
        }
        if !key.isEmpty { KeychainStore.set(keyRef, value: key, domain: .vendor) }   // 留空 = 沿用已存的 Key
        let endpointChanged: Bool
        if let e = editing, let i = state.config.vendors.firstIndex(where: { $0.id == e.id }) {
            endpointChanged = !(VendorValidator.sameEndpoint(state.config.vendors[i].anthropicBase, vendor.anthropicBase)
                && VendorValidator.sameEndpoint(state.config.vendors[i].openaiBase, vendor.openaiBase))
            state.config.vendors[i] = vendor
        } else {
            endpointChanged = false
            state.config.vendors.append(vendor)
        }
        if endpointChanged {
            // 端点变更后，该供应商模型的旧探测定全部作废（内存 + 磁盘；只清内存会回落磁盘旧结论）
            for i in state.config.models.indices where state.config.models[i].vendorID == vendor.id {
                let id = state.config.models[i].id
                state.config.models[i].probeResults = nil
                state.config.models[i].probedAt = nil
                state.config.models[i].tested = nil
                state.entryProbe[id] = nil
            }
        }
        state.persist()
        state.toast = endpointChanged ? "已保存 · 端点有变更，该供应商的模型需重新探测" : "供应商已保存"
        state.flashToast()
        dismiss()
    }
}
