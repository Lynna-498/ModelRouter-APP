import SwiftUI

// MARK: - R23 未知容错 UI 支撑（层级树 / 已知子键表 / 自动解析增补 / 手动增补）
// 配套 CodexMetadataWindow：字典未命中参数按实际形态与真实层级呈现，用户可增补字典（持久）。

/// 官方文档化的复杂结构子键（materials/codex-metadata-complex-structures-20261003.md 全录口径）。
/// 用途＝层级树与结构化编辑窗的「已知优先排序＋未命中标记」，以及自动解析的下钻范围。
enum MetaKnownShapes {
    static let subkeys: [String: [String]] = [
        "model_messages": ["instructions_template", "instructions_variables", "approvals", "auto_review",
                           "token_budget", "collaboration_modes", "confirmation_policies", "guardian_v2",
                           "multi_agent", "persistent_instructions", "permissions", "tools",
                           "content_filter_guidance"],
        "instructions_variables": ["personality_default", "personality_friendly", "personality_pragmatic"],
        "truncation_policy": ["mode", "limit"],
        "guardian": ["computer_use", "shell", "file_changes", "mcp", "network", "permissions"],
        "upgrade": ["model", "migration_markdown", "retirement_at"],
        "availability_nux": ["message"],
        "service_tiers": ["id", "name", "description"],
        "model_messages.approvals": ["on_request", "on_request_auto_review", "never", "unless_trusted"],
        "model_messages.auto_review": ["policy", "policy_template", "node_repl_policy", "rejection_instructions", "timeout_instructions"],
        "model_messages.token_budget": ["enabled", "use_history_notes_extension", "reminder_threshold_tokens",
                                        "reminder_message_template", "guidance_message",
                                        "auto_compact_fallback_prompt", "auto_compact_fallback_buffer_tokens"],
        "model_messages.collaboration_modes": ["default", "plan"],
        "model_messages.confirmation_policies": ["browser_use", "computer_use"],
        "model_messages.permissions": ["danger_full_access", "workspace_write", "read_only"],
    ]

    /// 增补表单可选的层级挂靠点（顶层＋已文档化复杂父）
    static let supplementParents: [(path: String, label: String)] =
        [("", "条目顶层")] + ["model_messages", "guardian", "upgrade", "truncation_policy", "availability_nux", "service_tiers"]
            .map { ($0, "\($0) 内") }

    /// 对象内子键排序：已知在前（按官方文档序），未知按字母序随后。
    /// path＝自参数根的点路径（"model_messages"、"model_messages.approvals"…，对应 subkeys 表键）
    static func orderedKeys(_ dict: [String: Any], path: String) -> [String] {
        let known = subkeys[path] ?? []
        return dict.keys.sorted { a, b in
            let ia = known.firstIndex(of: a) ?? Int.max
            let ib = known.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            return a < b
        }
    }
}

// MARK: - JSON 值形态工具

/// JSONSerialization 值的布尔判定（__NSCFBoolean 与数字 0/1 的区分，as? Bool 不可靠）
func mrIsBool(_ v: Any) -> Bool {
    guard v is NSNumber else { return false }
    return CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID()
}

func mrShapeSummary(_ v: Any) -> String {
    if v is NSNull { return "null · 未设置" }
    if mrIsBool(v) { return "布尔 · \((v as! Bool) ? "true" : "false")" }
    if let d = v as? [String: Any] { return "对象 · \(d.count) 键" }
    if let a = v as? [Any] { return "数组 · \(a.count) 项" }
    if let n = v as? NSNumber { return "数字 · \(n.stringValue)" }
    if let s = v as? String { return s.isEmpty ? "字符串 · 空 \"\"" : "字符串 · \(s.count) 字符" }
    return "未知形态"
}

// MARK: - 自动解析增补（主界面未命中区入口；解析→二次编辑→入用户字典）

struct DictAutoDraftSheet: View {
    /// 候选（key, parentPath, value）——由主窗从未命中参数收集
    let candidates: [(key: String, parentPath: String, value: Any)]
    let onConfirm: ([MetaParam]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [AutoDraft] = []

    struct AutoDraft: Identifiable {
        let id = UUID()
        var key: String
        var parentPath: String
        var zh: String
        var structure: String
        var on: Bool = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("⚡ 自动解析增补").font(f(13, .semibold))
                Text("未命中参数 → 字典草稿").font(f(11)).foregroundStyle(ink3)   // S7：「可二次编辑」「持久」语义由行内编辑与底部说明承担，不三处重复
                Spacer()
            }.padding(.bottom, 10)
            if drafts.isEmpty {
                Text("当前元数据没有未命中字典的参数").font(f(12)).foregroundStyle(ink3).padding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($drafts) { $d in
                            HStack(spacing: 8) {
                                Toggle("", isOn: $d.on).toggleStyle(.checkbox).labelsHidden()
                                TextField("字段名", text: $d.key).textFieldStyle(.plain).font(mono(11))
                                    .frame(width: 190)
                                Picker("", selection: $d.parentPath) {
                                    ForEach(MetaKnownShapes.supplementParents, id: \.path) { p in
                                        Text(p.label).tag(p.path)
                                    }
                                }.pickerStyle(.menu).labelsHidden().frame(width: 150)
                                TextField("中文名（可空）", text: $d.zh).textFieldStyle(.plain).font(f(11))
                                    .frame(width: 110)
                                Text(d.structure).font(f(10)).foregroundStyle(ink3).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .frame(height: 32)   // S7：草稿行 34→32（与未命中键行同档）
                            .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1))
            }
            HStack {
                Text("确认后写入用户增补字典（持久有效；原未命中参数转为命中）").font(f(10.5)).foregroundStyle(ink3)
                Spacer()
                Button("取消") { dismiss() }.cardBtn()
                Button("确认增补") { confirm() }.cardBtn(primary: true).disabled(drafts.allSatisfy { !$0.on })
            }.padding(.top, 10)
        }
        .padding(16)
        .frame(width: 760, height: 420, alignment: .topLeading)
        .onAppear {
            drafts = candidates.map { c in
                AutoDraft(key: c.key, parentPath: c.parentPath, zh: "",
                          structure: c.parentPath.isEmpty ? mrShapeSummary(c.value) : mrShapeSummary(c.value))
            }
        }
    }

    private func confirm() {
        var out: [MetaParam] = []
        for d in drafts where d.on {
            let k = d.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty, UserMetaDict.shared.canAdd(key: k, parentPath: d.parentPath) else { continue }
            out.append(MetaParam(key: k,
                                 zh: d.zh.isEmpty ? k : d.zh,
                                 group: "用户增补",
                                 desc: "自动解析增补（\(d.structure)）",
                                 inferred: false,
                                 control: .text(""),
                                 howTo: "用户增补条目（自动解析）；值按原样保留。",
                                 status: .active,
                                 parentPath: d.parentPath.isEmpty ? nil : d.parentPath))
        }
        onConfirm(out)
        dismiss()
    }
}

// MARK: - 手动增补（字典内入口：字段名＋层级＋文案）

struct DictManualAddSheet: View {
    /// 编辑模式＝传入既有用户条目（字段名/层级锁定只读）；nil＝新增
    let existing: MetaParam?
    let onConfirm: (MetaParam) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var parentPath = ""
    @State private var zh = ""
    @State private var desc = ""
    @State private var howTo = ""
    @State private var dup = false

    private var isEdit: Bool { existing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(isEdit ? "✎ 编辑增补条目" : "＋ 手动增补").font(f(13, .semibold))
                Text("自行登记参数字段与层级关系").font(f(11)).foregroundStyle(ink3)
                Spacer()
            }
            HStack(spacing: 10) {
                Text("字段名").font(f(11.5)).frame(width: 64, alignment: .leading)
                TextField("如 experimental_routing_hints", text: $key).textFieldStyle(.plain).font(mono(11))
                    .disabled(isEdit)
                Text("层级").font(f(11.5))
                Picker("", selection: $parentPath) {
                    ForEach(MetaKnownShapes.supplementParents, id: \.path) { p in
                        Text(p.label).tag(p.path)
                    }
                }.pickerStyle(.menu).labelsHidden().frame(width: 150)   // S7：与自动草稿行统一 150（曾 170）
                    .disabled(isEdit)
            }
            fieldRow("中文名", $zh, "展示用（可空，默认＝字段名）")
            fieldRow("描述", $desc, "字典内展示的说明（可空）")
            fieldRow("填写说明", $howTo, "「填写：」行文案（可空）")
            if dup {
                Text("✗ 该层级下已有同名字段（或与内置条目冲突）").font(f(11)).foregroundStyle(errColor)
            }
            HStack {
                Text("写入用户增补字典（持久有效）").font(f(10.5)).foregroundStyle(ink3)
                Spacer()
                Button("取消") { dismiss() }.cardBtn()
                Button(isEdit ? "保存" : "增补") { add() }.cardBtn(primary: true).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || dup)
            }
        }
        .padding(16)
        .frame(width: 560, height: 300, alignment: .topLeading)
        .onAppear {
            if let e = existing {
                key = e.key
                parentPath = e.parentPath ?? ""
                zh = e.zh
                desc = e.desc
                howTo = e.howTo
            }
        }
        .onChange(of: key) { _, new in
            guard !isEdit else { return }
            dup = !UserMetaDict.shared.canAdd(key: new.trimmingCharacters(in: .whitespaces), parentPath: parentPath)
        }
    }

    private func fieldRow(_ label: String, _ text: Binding<String>, _ ph: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(f(11.5)).frame(width: 64, alignment: .leading)
            TextField(ph, text: text).textFieldStyle(.plain).font(f(11.5))
        }
    }

    private func add() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, UserMetaDict.shared.canAdd(key: k, parentPath: parentPath) else { return }
        onConfirm(MetaParam(key: k,
                            zh: zh.isEmpty ? k : zh,
                            group: "用户增补",
                            desc: desc,
                            inferred: false,
                            control: .text(""),
                            howTo: howTo,
                            status: .active,
                            parentPath: parentPath.isEmpty ? nil : parentPath))
        dismiss()
    }
}

// MARK: - R23 二轮·行内层级编辑（管理员呈现形式指正）
// 字符串数组＝与 input_modalities 同族的行内标签（无预置选项），不属结构化内容、不弹独立小窗；
// 对象子参数直接显示在主界面，相对参数行退一格表示层级，按内容与格式给对应控件。

/// 字符串数组行内逐项编辑（管理员口径·五轮：每添加一项多一行，行形态参考 truncation_policy 子参数行）
struct ListItemsEditor: View {
    @Binding var items: [String]
    @State private var newItem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("（空）").font(f(10.5)).foregroundStyle(ink3)
                    .frame(height: 26, alignment: .leading)
            }
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    InpField(monoStyle: true, text: Binding(
                        get: { items[i] },
                        set: { items[i] = $0 }
                    )).frame(maxWidth: 320)
                    Spacer(minLength: 0)
                    Button { items.remove(at: i) } label: {
                        Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(ink2)
                    }
                    .buttonStyle(.plain)
                    .help("移除该项（生成元数据时不再写入）")
                }
                .frame(minHeight: 30)
                .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)   // S7：分隔线透明度统一 0.5
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(ink3)
                TextField("添加一项（回车确认）", text: $newItem).textFieldStyle(.plain).font(mono(11))
                    .onSubmit(add)
                Button("添加", action: add).cardBtn(mini: true)
                Spacer(minLength: 0)
            }
            .frame(height: 30)
        }
    }

    private func add() {
        let t = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(t)
        newItem = ""
    }
}

/// 对象行内层级编辑：每键一行（已知在前·官方文档序、未命中 ⚠ 沉底），值按形态给控件；
/// 嵌套对象/数组继续退格递归；长字符串（>300）摘要＋「编辑全文」开大编辑面（只编辑该字符串本身）
struct InlineStructEditor: View {
    var depth: Int
    @Binding var dict: [String: Any]
    var path: String            // 自参数根的点路径（已知子键表查找）
    @State private var newKey = ""
    @State private var newKind = "文本"
    static let kinds = ["文本", "数字", "布尔", "字符串数组", "对象", "数组"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MetaKnownShapes.orderedKeys(dict, path: path), id: \.self) { k in
                keyRow(k)
            }
            addRow
        }
        .padding(.leading, depth == 0 ? 0 : 16)   // 每深一层退一格
    }

    private func keyRow(_ k: String) -> some View {
        let isKnown = (MetaKnownShapes.subkeys[path] ?? []).contains(k)
        return HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 3) {
                if !isKnown { Text("⚠").font(f(9.5)).foregroundStyle(warnColor).help("字典未记录该子键 · 以元数据为准") }
                Text(k).font(mono(11)).foregroundStyle(isKnown ? ink2 : warnColor)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 168, alignment: .leading)
            valueControl(k)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { dict.removeValue(forKey: k) } label: {
                Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(ink2)
            }
            .buttonStyle(.plain)
            .help("移除该子键")
        }
        .padding(.vertical, 4)
        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder private func valueControl(_ k: String) -> some View {
        let v = dict[k] ?? NSNull()
        if v is NSNull {
            Text("null · 未设置").font(f(10.5)).foregroundStyle(ink3)
        } else if mrIsBool(v) {
            Toggle("", isOn: Binding(
                get: { (dict[k] as? Bool) ?? false },
                set: { dict[k] = $0 }
            ))
            .toggleStyle(.switch).controlSize(.mini)
        } else if v is [String: Any] {   // 绑定值不直接使用（Binding 内重新取源）→ 布尔测试（警告清理）
            InlineStructEditor(depth: depth + 1, dict: Binding(
                get: { (dict[k] as? [String: Any]) ?? [:] },
                set: { dict[k] = $0 }
            ), path: path + "." + k)
        } else if let l = v as? [String] {
            ListItemsEditor(items: Binding(
                get: { l },
                set: { dict[k] = $0 }
            ))
        } else if v is [Any] {
            InlineArrayEditor(depth: depth + 1, items: Binding(
                get: { (dict[k] as? [Any]) ?? [] },
                set: { dict[k] = $0 }
            ), path: path + "." + k)
        } else if let s = v as? String {
            if s.count > 300 {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(s.prefix(56)) + "…").font(mono(10)).foregroundStyle(ink3)
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text("\(s.count) 字符").font(f(11)).foregroundStyle(ink3)
                        Button("编辑全文") { presentLongTextFor(k) }.cardBtn(mini: true)
                    }
                }
            } else {
                InpField(monoStyle: true, text: Binding(
                    get: { s },
                    set: { dict[k] = $0 }
                )).frame(width: 320)
            }
        } else if let n = v as? NSNumber {
            InpField(monoStyle: true, text: Binding(
                get: { n.stringValue },
                set: { nv in
                    if let d = Double(nv) {
                        dict[k] = (d.truncatingRemainder(dividingBy: 1) == 0) ? (Int(d) as Any) : d
                    }
                }
            )).frame(width: 120)
        }
    }

    /// 长字符串专用大编辑面（只编辑该字符串值本身；确定写回子键）
    private func presentLongTextFor(_ k: String) {
        let cur = (dict[k] as? String) ?? ""
        FloatWindowCenter.shared.present(title: "编辑全文 · \(path).\(k)", size: NSSize(width: 640, height: 480),
                                         reuseKey: "inline-text:\(path).\(k)") { w in
            LongTextInputView(paramKey: "\(path).\(k)", initialText: cur,
                              onConfirm: { nv in dict[k] = nv; w.close() },
                              onCancel: { w.close() })
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(ink3)
            TextField("新字段名", text: $newKey).textFieldStyle(.plain).font(mono(11)).frame(width: 180)   // S7：与结构化窗添加行统一 180
            Picker("", selection: $newKind) {
                ForEach(Self.kinds, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 108)
            Button("＋ 添加字段") {
                let k = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty, dict[k] == nil else { return }
                switch newKind {
                case "数字": dict[k] = 0
                case "布尔": dict[k] = false
                case "字符串数组": dict[k] = [String]()
                case "对象": dict[k] = [String: Any]()
                case "数组": dict[k] = [Any]()
                default: dict[k] = ""
                }
                newKey = ""
            }
            .cardBtn(mini: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// 数组行内递归编辑（对象数组如 service_tiers：元素 [i] 分组退格展开；标量元素行内改）
struct InlineArrayEditor: View {
    var depth: Int
    @Binding var items: [Any]
    var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                elementRow(i)
            }
            HStack(spacing: 8) {
                Button("＋ 对象元素") { items.append([String: Any]()) }.cardBtn(mini: true)
                Button("＋ 文本元素") { items.append("") }.cardBtn(mini: true)
                Button("＋ 数字元素") { items.append(0) }.cardBtn(mini: true)      // S7：与行内编辑能力配套
                Button("＋ 布尔元素") { items.append(false) }.cardBtn(mini: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .padding(.leading, depth == 0 ? 0 : 16)
    }

    @ViewBuilder private func elementRow(_ i: Int) -> some View {
        let v = items[i]
        HStack(alignment: .top, spacing: 8) {
            Text("[\(i)]").font(mono(10.5)).foregroundStyle(ink3).frame(width: 34, alignment: .leading)
            if v is [String: Any] {   // 警告清理：绑定值不直接使用（同上）
                InlineStructEditor(depth: depth + 1, dict: Binding(
                    get: { (items[i] as? [String: Any]) ?? [:] },
                    set: { items[i] = $0 }
                ), path: path + ".\(i)")
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let s = v as? String {
                InpField(monoStyle: true, text: Binding(
                    get: { s },
                    set: { items[i] = $0 }
                )).frame(maxWidth: 320, alignment: .leading)
            } else if mrIsBool(v) {
                // S7：数组内布尔/数字元素不再只读——行内开关/窄框直改（与对象内标量同能力）
                Toggle("", isOn: Binding(
                    get: { (items[i] as? Bool) ?? false },
                    set: { items[i] = $0 }
                ))
                .toggleStyle(.switch).controlSize(.mini)
            } else if let n = v as? NSNumber {
                InpField(monoStyle: true, text: Binding(
                    get: { n.stringValue },
                    set: { nv in
                        if let d = Double(nv) {
                            items[i] = (d.truncatingRemainder(dividingBy: 1) == 0) ? (Int(d) as Any) : d
                        }
                    }
                )).frame(width: 120)
            } else {
                Text(mrShapeSummary(v)).font(f(10.5)).foregroundStyle(ink3)
            }
            Button { items.remove(at: i) } label: {
                Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(ink2)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)   // S7：分隔线透明度统一 0.5
    }
}

// MARK: - 提示三件套用「?／i」弹泡按钮（点击弹出说明，宽文本）

struct InfoPopoverButton: View {
    let icon: String          // "questionmark" / "info"
    let title: String
    let lines: [String]
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink2)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color(NSColor.quaternaryLabelColor).opacity(0.22)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(f(11.5, .semibold)).foregroundStyle(.white)
                ForEach(lines, id: \.self) { l in
                    Text(l).font(f(11)).foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 340, alignment: .topLeading)
            // S7：帮助弹泡样式收敛——与 Theme.HelpTip 同一深底族（原系统浅底两套并存）
            .background(Color(red: 0.12, green: 0.12, blue: 0.13).opacity(0.97))
        }
    }
}
