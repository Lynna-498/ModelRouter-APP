import SwiftUI
import AppKit
import ModelRouterCore

// MARK: - 元数据配置窗（C 窗，820 独立窗；R8-SPEC 一.C＋2026-09-29 复验四轮重做）
// 结构：编辑/显示双列（两列均无边界：NSTextView 不折行横向滚动）→「启用手动模式」开关
// →（手动模式开）高级模式行＋参数配置滚动区（基础参数＋高级参数）；
// 状态行＋取消/生成元数据/应用固定窗底（mfoot，滚动区外）。
// 手动模式关（默认）：参数界面整块隐藏，双列撑满窗高；生成元数据＝仅改写 slug/display_name。
// 手动模式开：识别回填（JSON→界面：高级模式关只回填基础；开则自动加参数行）；
// 生成元数据＝按界面内容整段生成（界面→JSON）——参数添加/编辑为纯界面状态，不即时写 JSON。
// slug/display_name 由模型名称接管；应用时强制覆写为名称。
// 配置选项打开元数据参数字典同窗覆盖层；超大长度参数（长文本类）经独立输入窗口编辑。
struct CodexMetadataWindow: View {
    @EnvironmentObject var state: AppState
    let groupKey: String
    let initial: String
    var onClose: () -> Void

    // ── 编辑器与模式 ──
    @State private var editorText = ""
    @State private var showDict = false
    @State private var manualMode = false
    @State private var advanced = false
    @State private var searchText = ""
    @State private var lastAddedKey: String? = nil

    // ── R23 未知容错（字典未命中参数的界面状态；生成时才并入 JSON）──
    @State private var unknownEdits: [String: Any] = [:]
    @State private var unknownRemoved: Set<String> = []
    @State private var showAutoDraft = false
    @State private var showManualAdd = false

    // ── 基础参数（界面状态；生成时才写入 JSON）──
    @State private var contextTier = "256K"
    @State private var contextCustom = ""
    @State private var imageInput = false
    @State private var tiers: [CodexCatalog.ReasoningTier] = []
    @State private var defaultTier: String? = nil

    // ── 高级参数行（纯界面状态；生成时才写入 JSON）──
    @State private var paramRows: [ParamRow] = []

    /// 推理档位枚举（S3 定夺：十态全量。custom＝自定义值入口——选中后行内自由输入实际档位串；
    /// schema 已放宽为任意非空字符串，十态之外的历史/厂商值识别回填后同样走 custom 呈现）
    static let tierOptions = ["none", "minimal", "low", "medium", "high", "xhigh", "ultra", "max", "persistent", "custom"]
    static let contextTiers = ["128K", "256K", "960K", "自定义"]

    /// 高级参数行的值形态（编辑态为字符串，生成时转换）
    enum ParamValue {
        case text(String)
        case longText(String)
        case toggle(Bool)
        case number(String)
        case picker(String)
        case modeNumber(String, String)   // 模式 + 数值
        case list([String])               // R23 二轮：字符串数组＝行内标签（与 input_modalities 同族）
        case object([String: Any])        // 对象＝主界面行内层级展开（子参数退一格）
        case array([Any])                 // 对象数组/混合数组＝行内递归展开（元素 [i]）
    }

    struct ParamRow: Identifiable {
        let key: String
        var value: ParamValue
        var id: String { key }
    }

    // MARK: - 解析辅助

    private var parsedMeta: [String: Any]? {
        guard let data = editorText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return obj as? [String: Any]
    }

    /// 状态条（R11 提示三件套之一）：点＋文字同色——绿＝合规、红＝不合规、灰＝中性（清除态）；
    /// 合规口径＝JSON 可解析（宽松口径，显示列格式化成功即算）＋ slug 与 display_name 均存在且已等于模型名称（接管完成）
    private var compliance: (Color, String, Bool) {
        let t = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return (ink3, "内容为空——应用后清除该名称的全部元数据", false) }
        if let obj = strictParse {
            if let arr = obj as? [Any], arr.count > 1 {
                return (errColor, "粘贴的是多条目集合——只保留一个模型条目（从 { 到 }）", false)
            }
            if let d = obj as? [String: Any], let models = d["models"] as? [Any], models.count > 1 {
                return (errColor, "粘贴的是整个 models.json（含 \(models.count) 个条目）——只复制其中一个模型条目", false)
            }
        }
        guard let e = effectiveEntry else {
            return (errColor, "JSON 非法：无法应用", false)
        }
        let slugOK = (e["slug"] as? String) == groupKey
        let dnOK = (e["display_name"] as? String) == groupKey
        if slugOK && dnOK {
            // S7：✓/✗ 符号已去——彩点已表达状态，双表达冗余
            return (okColor, "条目合规：JSON 合法，slug/display_name 已接管为模型名称", true)
        }
        let bad = !slugOK && !dnOK ? "slug 与 display_name" : (slugOK ? "display_name" : "slug")
        return (errColor, "\(bad)未接管为模型名称——先「生成元数据」再应用", false)
    }

    /// 严格解析（无修复）；状态行的多条目诊断用
    private var strictParse: Any? {
        guard let data = editorText.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    private var applyEnabled: Bool {
        // 名称下须有模型条目（ModelSheet 新增未保存时无条目——先保存模型再配置元数据）
        guard state.config.models.contains(where: { $0.groupKey == groupKey }) else { return false }
        let t = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }   // 清除通道（中性态，不属「保存条目」）
        return compliance.2            // R11：仅绿色（合规）允许应用
    }

    /// 单条目数组 [{…}] 提取
    private var singleEntryArray: [String: Any]? {
        guard let data = editorText.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [Any],
              arr.count == 1, let e = arr[0] as? [String: Any] else { return nil }
        return e
    }

    /// {"models":[单条]} 包裹提取
    private var modelsWrapperSingle: [String: Any]? {
        guard let data = editorText.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let models = d["models"] as? [Any], models.count == 1,
              let e = models[0] as? [String: Any] else { return nil }
        return e
    }

    /// 应用对象＝数组/包裹提取版或原对象（slug/display_name 应用时注入）。
    /// 宽松回退：严格解析失败时走 CodexMetaNorm 片段修复（漏外层大括号等）——编辑列不要求严格遵守 JSON 格式，
    /// 格式化后的结果体现在显示列。
    private var effectiveEntry: [String: Any]? {
        if let e = singleEntryArray ?? modelsWrapperSingle ?? parsedMeta { return e }
        let t = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let (outcome, obj) = CodexMetaNorm.normalize(t)
        return outcome == .ok ? obj : nil
    }

    // MARK: - 布局（有限值预算，禁 infinity：窗 820×745、内衬 16、mfoot 39；2026-10-03 管理员反馈列表加高 700→745）

    var body: some View {
        Group {
            if showDict { dictOverlay.transition(.opacity) } else { mainView.transition(.opacity) }
        }
        .frame(width: 820, height: 745, alignment: .topLeading)
        .background(winBg)
        .animation(.easeInOut(duration: 0.15), value: showDict)   // S7：覆盖层切换补过渡（本窗 withAnimation 先例）
        .onAppear(perform: loadOnce)
        // 识别触发挂在常驻根视图：挂在 manualRow/advancedRow 上会被分支销毁吞掉 onChange（复验问题 6 根因）
        .onChange(of: manualMode) { _, on in
            if on { recognizeFromJSON() }
        }
        .onChange(of: advanced) { _, on in
            // 高级模式从切开到开：补齐 JSON 中已有但尚未成行的字典参数（不动已有行的编辑值）
            if on, manualMode, let e = effectiveEntry { recognizeAdvanced(from: e, merge: true) }
        }
    }

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manualMode {
                dualColumns(editorHeight: 200)   // 手动模式开：双列固定高，下方参数区
                manualRow
                advancedRow
                ScrollView {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 10) {
                            basicSection
                            if advanced { advancedParamsSection }
                            unknownSection   // R23：字典未命中沉底（后端完整保留）
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 2026-10-03 管理员定：内容左右边距 22；滚动条独立处理——overlay 浮于右边距带，内容不单独让位（曾 trailing 14 车道）
                        .padding(.horizontal, 22)
                        .onChange(of: showDict) { _, shown in
                            if !shown, let key = lastAddedKey, advanced {
                                withAnimation { proxy.scrollTo(key, anchor: .center) }
                            }
                        }
                    }
                }
                .frame(height: 358)   // 2026-10-03 管理员反馈：列表加高（310→358，随窗 700→745）
                .sheet(isPresented: $showAutoDraft) {
                    DictAutoDraftSheet(candidates: Self.collectUnknownCandidates(effectiveEntry ?? [:])) { drafts in
                        for m in drafts { UserMetaDict.shared.upsert(m) }
                    }
                    .environmentObject(state)
                }
            } else {
                dualColumns(editorHeight: 606)   // 手动模式关（默认）：双列撑满窗高（558→606 随窗 745）
                manualRow
            }
            mfoot
        }
        .padding(16)
    }

    /// 编辑/显示双列（两列均为无边界：NSTextView 不折行、横向滚动；带边框；标签行定高）
    private func dualColumns(editorHeight: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("编辑").font(f(10.5)).foregroundStyle(ink3).frame(height: 16, alignment: .bottom)
                JSONCodeEditor(text: $editorText, mode: .json, showLineNumbers: false)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 388, height: editorHeight)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("显示").font(f(10.5)).foregroundStyle(ink3).frame(height: 16, alignment: .bottom)
                JSONDisplayView(source: prettySource)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.12, green: 0.12, blue: 0.13)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 388, height: editorHeight)
            }
        }
    }

    private var prettySource: String {
        guard let e = effectiveEntry,
              let d = try? JSONSerialization.data(withJSONObject: e, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else {
            return editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : editorText
        }
        return s
    }

    /// 「启用手动模式」：开＝展开参数配置界面；每次开启按当前 JSON 重新识别回填（覆盖界面）
    /// （识别触发挂在常驻根视图，见 body）
    private var manualRow: some View {
        HStack(spacing: 12) {
            Toggle("启用手动模式", isOn: $manualMode)
                .toggleStyle(.switch).controlSize(.mini)
                .help("开启后展开参数配置界面，并按当前元数据自动识别回填；生成元数据将按界面内容生成")
            Spacer()
        }
        .frame(height: 28)
    }

    /// 高级行：开关＋「配置选项」按钮（visibility 占位防行高跳变）
    private var advancedRow: some View {
        HStack(spacing: 12) {
            Toggle("高级模式", isOn: $advanced)
                .toggleStyle(.switch).controlSize(.mini)
                .help("开启后显示高级参数行与「配置选项」；开启时自动把元数据中已有的字典参数识别为高级参数行")
            Button("配置选项") { showDict = true }
                .cardBtn(mini: true)
                .opacity(advanced ? 1 : 0)   // 占位防跳版：恒渲染仅隐现，自然尺寸即占位（S7：去 88×26 魔法框——占位高曾与 mini 实高 22 不符）
                .disabled(!advanced)
            Spacer()
        }
        .frame(height: 28)
    }

    // MARK: - 基础参数

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("基础参数").font(f(12.5, .semibold))
                .frame(height: 30, alignment: .bottom)   // S7：与高级参数/未命中区段头同节奏
            takeoverRow("slug", "slug")
            takeoverRow("显示名", "display_name")
            HStack(spacing: 10) {
                fieldLabel("上下文窗口")
                Picker("", selection: $contextTier) {
                    ForEach(Self.contextTiers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                if contextTier == "自定义" {
                    InpField(monoStyle: true, text: $contextCustom).frame(width: 120)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                fieldLabel("输入模态")
                Toggle("支持图像输入", isOn: $imageInput)
                    .toggleStyle(.switch).controlSize(.mini)   // S7：与全窗开关统一（曾 checkbox）
                Spacer()
            }
            tiersEditor
            HStack(spacing: 10) {
                fieldLabel("默认档位")
                NativeMenuPicker<String>(
                    items: [(nil, tiers.isEmpty ? "不支持推理" : "选择档位")]
                        + tiers.map { (Optional($0.effort), $0.effort) },
                    selection: Binding(
                        get: { tiers.contains(where: { $0.effort == defaultTier }) ? defaultTier : nil },
                        set: { defaultTier = $0 }
                    )
                )
                .frame(width: 240, alignment: .leading)
                Spacer()
            }
        }
    }

    /// 接管项状态行：显示当前元数据中该键的值，并标注是否符合标准（＝模型名称；应用/生成时强制覆写）
    private func takeoverRow(_ label: String, _ key: String) -> some View {
        let cur = effectiveEntry?[key] as? String
        let compliant = cur == groupKey
        return HStack(spacing: 10) {
            fieldLabel(label)
            if compliant {
                Text("✓ \(cur ?? "")（＝模型名称）").font(f(11.5)).foregroundStyle(okColor)
            } else if let c = cur {
                Text("✗ 当前「\(c)」不符——应用/生成时将覆写为「\(groupKey)」")
                    .font(f(11.5)).foregroundStyle(warnColor)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("（元数据中无此键）——应用/生成时将写入模型名称").font(f(11.5)).foregroundStyle(ink3)
            }
            Spacer()
        }
    }

    /// 推理档位结构化行编辑：行＝档位下拉（六枚举）＋说明输入（280 上限）＋⊖；行可全删＝不支持推理；
    /// 增删改实时同步「默认档位」下拉选项
    private var tiersEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                fieldLabel("推理档位")
                if tiers.isEmpty {
                    Text("不支持推理（全删）").font(f(11.5)).foregroundStyle(ink3)
                }
                Spacer()
                Button {
                    tiers.append(CodexCatalog.ReasoningTier(effort: "low", description: ""))
                } label: {
                    Text("＋ 添加档位").font(f(11.5)).foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 30)
            ForEach(tiers.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    // 十态下拉；非十态值（识别回填的历史/厂商值）显示为 custom，选中 custom＝清空进入自由输入态
                    let known = Self.tierOptions.contains(tiers[i].effort)
                    Picker("", selection: Binding(
                        get: { known ? tiers[i].effort : "custom" },
                        set: { nv in tiers[i].effort = (nv == "custom") ? "" : nv }
                    )) {
                        ForEach(Self.tierOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 110)
                    if !known {
                        InpField(monoStyle: true, text: $tiers[i].effort)
                            .frame(width: 120)
                            .help("自定义档位值：任意非空字符串（schema 已放宽为非枚举）；留空＝该行生成时跳过")
                    }
                    InpField(text: $tiers[i].description)
                        .frame(maxWidth: 280)
                        .onChange(of: tiers[i].description) { _, new in
                            if new.count > 280 { tiers[i].description = String(new.prefix(280)) }
                        }
                    Spacer()
                    Button {
                        let removed = tiers[i].effort
                        tiers.remove(at: i)
                        if defaultTier == removed { defaultTier = nil }
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(ink2)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 36)
                .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
            }
        }
    }

    // MARK: - 高级参数（原「已添加参数」；纯界面状态，生成时才写入）

    private var advancedParamsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("高级参数").font(f(12.5, .semibold))
                .frame(height: 30, alignment: .bottom)
            if paramRows.isEmpty {
                Text("暂无高级参数（经「配置选项」添加，或开启时自动识别元数据）")
                    .font(f(11)).foregroundStyle(ink3)
                    .frame(height: 30, alignment: .center)
            }
            ForEach($paramRows) { $row in
                ParamRowView(row: $row,
                             onEditLongText: { presentLongTextInput(key: row.key, value: longTextOf(row)) },
                             onRemove: { removeRow(row.key) })
                    .id(row.key)
            }
        }
    }

    private func longTextOf(_ row: ParamRow) -> String {
        if case .longText(let s) = row.value { return s }
        return ""
    }

    private func removeRow(_ key: String) {
        paramRows.removeAll { $0.key == key }
        if lastAddedKey == key { lastAddedKey = nil }
    }

    // MARK: - R23 字典未命中区（沉底显示；后端完整保留，生成时原样回吐）

    private var unknownParams: [(key: String, value: Any)] {
        guard manualMode, let e = effectiveEntry else { return [] }
        return e.keys
            .filter { $0 != "slug" && $0 != "display_name" && !Self.isKnownParam($0) && !unknownRemoved.contains($0) }
            .sorted()
            .map { ($0, unknownEdits[$0] ?? (e[$0] ?? NSNull())) }
    }

    @ViewBuilder private var unknownSection: some View {
        let list = unknownParams
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("字典未命中（\(list.count)）").font(f(12.5, .semibold)).foregroundStyle(warnColor)
                    Text("后端完整保留 · 生成时原样回吐").font(f(10)).foregroundStyle(ink3)
                    Spacer()
                    Button { showAutoDraft = true } label: {
                        Text("⚡ 自动解析增补").font(f(11.5)).foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .help("把未命中参数解析为字典草稿（字段·层级·结构），二次编辑后写入用户增补字典（持久）")
                }
                .frame(height: 30)
                ForEach(list, id: \.key) { u in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text("⚠").font(f(10)).foregroundStyle(warnColor)
                                .help("字典未记录该参数 · 以元数据为准")
                            Text(u.key).font(mono(11.5)).foregroundStyle(warnColor)
                            Text(mrShapeSummary(u.value)).font(f(10)).foregroundStyle(ink3)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(NSColor.quaternaryLabelColor).opacity(0.2)))
                            Spacer(minLength: 0)
                            Button {
                                unknownRemoved.insert(u.key)
                                unknownEdits.removeValue(forKey: u.key)
                            } label: {
                                Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(ink2)
                            }
                            .buttonStyle(.plain)
                            .help("从元数据中移除该未知键（生成时不再写入）")
                        }
                        .frame(height: 32)   // S7：未命中键行 28→32（与主参数行 36 成梯度）
                        // R23 五轮·完备性：未知值同样按形态给行内控件（与已知参数同族），不再走弹窗
                        unknownValueEditor(u)
                            .padding(.leading, 16)
                    }
                    .padding(.vertical, 4)
                    .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
                }
            }
        }
    }

    /// 未知键值的行内编辑：布尔→开关、数字→窄框、字符串→等宽输入、字符串数组→逐项行、
    /// 对象→行内层级、数组→行内递归、null→占位（编辑写 unknownEdits，纯界面状态）
    @ViewBuilder private func unknownValueEditor(_ u: (key: String, value: Any)) -> some View {
        let cur = unknownEdits[u.key] ?? u.value
        let setEdit: (Any) -> Void = { unknownEdits[u.key] = $0 }
        if cur is NSNull {
            Text("null · 未设置").font(f(10.5)).foregroundStyle(ink3)
        } else if mrIsBool(cur) {
            Toggle("", isOn: Binding(
                get: { (unknownEdits[u.key] as? Bool) ?? (cur as? Bool ?? false) },
                set: { setEdit($0) }
            ))
            .toggleStyle(.switch).controlSize(.mini)
        } else if let d = cur as? [String: Any] {
            InlineStructEditor(depth: 0, dict: Binding(
                get: { (unknownEdits[u.key] as? [String: Any]) ?? d },
                set: { setEdit($0) }
            ), path: u.key)
        } else if let l = cur as? [String] {
            ListItemsEditor(items: Binding(
                get: { (unknownEdits[u.key] as? [String]) ?? l },
                set: { setEdit($0) }
            ))
        } else if let a = cur as? [Any] {
            InlineArrayEditor(depth: 0, items: Binding(
                get: { (unknownEdits[u.key] as? [Any]) ?? a },
                set: { setEdit($0) }
            ), path: u.key)
        } else if let s = cur as? String {
            InpField(monoStyle: true, text: Binding(
                get: { (unknownEdits[u.key] as? String) ?? s },
                set: { setEdit($0) }
            )).frame(maxWidth: 320, alignment: .leading)
        } else if let n = cur as? NSNumber {
            InpField(monoStyle: true, text: Binding(
                get: { ((unknownEdits[u.key] as? NSNumber) ?? n).stringValue },
                set: { nv in
                    if let d = Double(nv) { setEdit(d.truncatingRemainder(dividingBy: 1) == 0 ? (Int(d) as Any) : d) }
                }
            )).frame(width: 120)
        }
    }

    /// 长文本/结构化参数的独立输入窗口：值为 JSON 对象 → 结构化逐字段表单；否则纯文本大编辑面。
    /// （确定回填界面状态；取消放弃——均不动 JSON，生成时才写入）
    private func presentLongTextInput(key: String, value: String) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDict: Bool = {
            guard t.hasPrefix("{"), let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return false }
            return obj is [String: Any]
        }()
        FloatWindowCenter.shared.present(title: "参数编辑 · \(key)", size: NSSize(width: 640, height: 480),
                                         reuseKey: "param-edit:\(key)") { w in
            let confirm: (String) -> Void = { nv in
                if let i = paramRows.firstIndex(where: { $0.key == key }) {
                    // 保持行原值形态（text 行回 .text，longText 行回 .longText）
                    if case .text = paramRows[i].value { paramRows[i].value = .text(nv) }
                    else { paramRows[i].value = .longText(nv) }
                }
                w.close()
            }
            let cancel: () -> Void = { w.close() }
            if isDict {
                StructuredJSONInputView(paramKey: key, initialText: t,
                                        onConfirm: confirm, onCancel: cancel)
                    .environmentObject(state)
            } else {
                LongTextInputView(paramKey: key, initialText: value,
                                  onConfirm: confirm, onCancel: cancel)
                    .environmentObject(state)
            }
        }
    }

    // MARK: - 元数据参数字典（同窗覆盖层）

    /// 字典全集＝内置字典 ∪ 用户增补（顶层条目，与参数行同面渲染）
    private var allDictParams: [MetaParam] {
        MetaParamDict.all + UserMetaDict.shared.topLevel
    }

    /// 编辑中的用户增补条目（nil＝无；sheet(item:) 用）
    @State private var editingEntry: MetaParam? = nil

    private var dictOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button("返回配置") { showDict = false }.cardBtn(mini: true)
                Text("元数据参数字典 \(allDictParams.count)").font(f(12, .semibold))
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(ink3)
                    TextField("搜索变量名、中文名、描述或填写说明…", text: $searchText)
                        .textFieldStyle(.plain).font(f(12))
                }
                .padding(.horizontal, 9).frame(height: 28).frame(maxWidth: 360)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1))
                Spacer()
                Text(hitText).font(mono(11)).foregroundStyle(ink3)
                Button { showManualAdd = true } label: {
                    Text("＋ 手动增补").font(f(11.5)).foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("手动登记参数字段与层级关系，写入用户增补字典（持久有效）")
                Button("关闭") { showDict = false }.cardBtn(mini: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(MetaParamDict.groups + ["用户增补"], id: \.self) { g in
                        let rows = filtered.filter { $0.group == g }
                        if !rows.isEmpty {
                            Text(g).font(f(11, .semibold)).foregroundStyle(ink3)
                                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                            ForEach(rows) { p in dictRow(p) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showManualAdd) {
            DictManualAddSheet(existing: nil) { UserMetaDict.shared.upsert($0) }
        }
        .sheet(item: $editingEntry) { e in
            DictManualAddSheet(existing: e) { UserMetaDict.shared.upsert($0) }
        }
    }

    private var hitText: String {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? "全部 \(allDictParams.count) 项" : "命中 \(filtered.count) 项"
    }

    private var filtered: [MetaParam] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allDictParams }
        return allDictParams.filter {
            $0.key.lowercased().contains(q)
                || $0.zh.lowercased().contains(q)
                || $0.desc.lowercased().contains(q)
                || $0.howTo.lowercased().contains(q)
        }
    }

    /// 已添加＝界面已有行 ∪ 元数据 JSON 中已有该键（识别会带出）
    private func isAdded(_ p: MetaParam) -> Bool {
        if case .basic = p.control { return true }
        if paramRows.contains(where: { $0.key == p.key }) { return true }
        if let e = effectiveEntry { return e[p.key] != nil }
        return false
    }

    private func dictRow(_ p: MetaParam) -> some View {
        let added = isAdded(p)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 4) {
                    Text(p.key).font(mono(11.5))
                        .foregroundStyle(added ? ink3 : keyAccent)
                    if p.inferred {
                        Text("†").font(f(11, .bold)).foregroundStyle(warnColor)
                            .help("语义按官方实例推断")
                    }
                }
                .frame(width: 240, alignment: .leading)   // S7：与主参数行列宽同档（曾 300，覆盖层开合时列宽跳变）
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.zh).font(f(11.5, .semibold)).foregroundStyle(added ? ink3 : ink2)
                        Text(p.group).font(f(10)).foregroundStyle(ink3)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(Color(NSColor.quaternaryLabelColor).opacity(0.25)))
                        if p.status == .ignored {
                            Text("现行忽略").font(f(10)).foregroundStyle(warnColor)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(warnColor.opacity(0.12)))
                                .help("现行 Codex 不读取此字段（服务端亦不下发）；保留仅为兼容官方 catalog 形态与厂商脚本")
                        }
                        if p.status == .localOnly {
                            Text("官方 catalog 无").font(f(10)).foregroundStyle(ink3)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(NSColor.quaternaryLabelColor).opacity(0.25)))
                                .help("官方 catalog 无此字段（结构体无）；厂商/本机实例实有，按「未知字段忽略」口径可写")
                        }
                    }
                    DictDescBlock(id: p.key, text: p.desc, color: added ? ink3 : ink2)
                    Text("填写：\(p.howTo)").font(f(11)).foregroundStyle(ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if added {
                    Text("已添加").font(f(11)).foregroundStyle(ink3).padding(.top, 2)
                } else {
                    Button("添加") { addParamRow(p) }.cardBtn(mini: true)
                }
                if p.group == "用户增补" {
                    Button { editingEntry = p } label: {
                        Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(ink2)
                    }
                    .buttonStyle(.plain)
                    .help("编辑该增补条目")
                    Button {
                        UserMetaDict.shared.remove(key: p.key, parentPath: p.parentPath)
                        removeRow(p.key)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(ink2)
                    }
                    .buttonStyle(.plain)
                    .help("删除该增补条目（并移除已建参数行）")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .opacity(added || p.status == .ignored ? 0.55 : 1)   // 已添加与滞后条目同风格置灰（仍可添加·兼容保留）
        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
    }

    /// 字典「＋ 添加」：默认值建行（纯界面状态，不写 JSON——生成元数据时才写入）
    private func addParamRow(_ p: MetaParam) {
        guard !isAdded(p) else { return }
        paramRows.append(ParamRow(key: p.key, value: Self.defaultParamValue(p)))
        lastAddedKey = p.key
    }

    // MARK: - mfoot（状态行＋取消/生成元数据/应用固定窗底，滚动区外）

    private var mfoot: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .center, spacing: 8) {
                // 状态条：点＋文字同色（绿＝合规可应用、红＝不合规、灰＝中性清除态）
                HStack(spacing: 6) {
                    Circle().fill(compliance.0).frame(width: 6, height: 6)
                    Text(compliance.1).font(f(11)).foregroundStyle(compliance.0)
                }
                .frame(maxWidth: 420, alignment: .leading)
                Spacer()
                InfoPopoverButton(icon: "questionmark", title: "如何配置", lines: [
                    "手动模式：开启后按当前 JSON 识别回填，界面编辑、点「生成元数据」写回编辑列。",
                    "高级模式：展开字典参数行与「配置选项」字典；基础四项（上下文／模态／档位）在基础参数区。",
                    "推理档位十态；选 custom 后行内输入任意非空字符串（schema 已放宽为非枚举）。",
                    "字典未命中的参数沉在下方「字典未命中」区，可自动或手动增补进字典。",
                    "状态条绿色才可应用——绿＝JSON 合法且 slug/display_name 已接管为模型名称。",
                ])
                InfoPopoverButton(icon: "info", title: "ModelRouter 接入规范", lines: [
                    "slug 与 display_name 由模型名称强制接管；路由按名称命中。",   // S7：覆写语义与接管行文字重复已去
                    "元数据落 ~/.codex/model_modelrouter.json；config.toml 受管区 model_catalog_json 指向它——Codex 侧为权威目录，不与内置／远端目录合并。",
                    "未知键原样保留：ModelRouter 不因字典未记录而丢弃或改写任何字段。",
                    "清除＝清空编辑列后应用，将删除该名称的全部元数据。",
                ])
                // S7：取消放最左（惯例位；曾夹在生成与应用之间）
                Button("取消") { onClose() }.cardBtn()
                Button("生成元数据") { generateMetadata() }.cardBtn()
                Button("应用") { apply() }
                    .cardBtn(primary: true)
                    .disabled(!applyEnabled)
            }
            .frame(height: 30)
        }
    }

    // MARK: - 行为：载入 / 识别（JSON→界面） / 生成（界面→JSON） / 应用

    private func loadOnce() {
        editorText = initial
    }

    /// 启用手动模式：按当前 JSON 重新识别回填（覆盖界面；空/非法不回填，保留默认）
    private func recognizeFromJSON() {
        unknownEdits = [:]
        unknownRemoved = []
        guard let e = effectiveEntry else { return }
        if let cw = e["context_window"] as? Int { seedContext(cw) }
        else if let cw = e["context_window"] as? Double { seedContext(Int(cw)) }
        if let mods = e["input_modalities"] as? [Any] {
            imageInput = mods.contains { ($0 as? String) == "image" }
        }
        if let levels = e["supported_reasoning_levels"] as? [[String: Any]] {
            tiers = levels.compactMap { l in
                guard let effort = l["effort"] as? String else { return nil }
                return CodexCatalog.ReasoningTier(effort: effort,
                                                  description: (l["description"] as? String) ?? "")
            }
        } else if let levels = e["supported_reasoning_levels"] as? [String] {
            tiers = levels.map { CodexCatalog.ReasoningTier(effort: $0, description: "") }
        }
        if let d = e["default_reasoning_level"] as? String { defaultTier = d }
        if advanced { recognizeAdvanced(from: e, merge: false) }
    }

    /// 高级参数识别：JSON 中存在、属于字典 37 参数的非基础字段 → 参数行（含当前值）。
    /// merge=false（手动模式开启）整表重建；merge=true（高级模式开启）只补缺失键、不动已有行。
    private func recognizeAdvanced(from e: [String: Any], merge: Bool) {
        var rows: [ParamRow] = []
        for p in MetaParamDict.all where !MetaParamDict.basicKeys.contains(p.key) {
            if let v = e[p.key] {
                rows.append(ParamRow(key: p.key, value: Self.decodeValue(p, v)))
            }
        }
        if merge {
            let existing = Set(paramRows.map(\.key))
            paramRows.append(contentsOf: rows.filter { !existing.contains($0.key) })
        } else {
            paramRows = rows
        }
    }

    private func seedContext(_ cw: Int) {
        switch cw {
        case 131072: contextTier = "128K"
        case 262144: contextTier = "256K"
        case 983040: contextTier = "960K"
        default:
            contextTier = "自定义"
            contextCustom = String(cw)
        }
    }

    private var contextValue: Int {
        switch contextTier {
        case "128K": return 131072
        case "256K": return 262144
        case "960K": return 983040
        default: return Int(contextCustom) ?? 262144
        }
    }

    /// 生成元数据：
    /// 手动模式关＝仅改写 slug/display_name（其余保留；空/非法文本时生成仅含两键的对象）；
    /// 手动模式开＝以当前条目为底座、界面内容覆盖——R23 未知容错：字典外的键原样保留回吐；
    /// 已知非基础键：高级模式关＝未成行不丢（保留原值，用户未触及），高级模式开＝无行即删（行是全部事实）。
    private func generateMetadata() {
        guard manualMode else {
            if var e = effectiveEntry {
                e["slug"] = groupKey
                e["display_name"] = groupKey
                if let d = try? JSONSerialization.data(withJSONObject: e, options: [.prettyPrinted]),
                   let s = String(data: d, encoding: .utf8) { editorText = s }
            } else {
                let e: [String: Any] = ["slug": groupKey, "display_name": groupKey]
                if let d = try? JSONSerialization.data(withJSONObject: e, options: [.prettyPrinted]),
                   let s = String(data: d, encoding: .utf8) { editorText = s }
            }
            return
        }
        var e = Self.assembleBaseEntry(original: effectiveEntry,
                                       advanced: advanced,
                                       rowKeys: Set(paramRows.map(\.key)),
                                       unknownEdits: unknownEdits,
                                       unknownRemoved: unknownRemoved)
        e["slug"] = groupKey
        e["display_name"] = groupKey
        e["context_window"] = contextValue
        e["input_modalities"] = imageInput ? ["text", "image"] : ["text"]
        let liveTiers = tiers.filter { !$0.effort.isEmpty }   // custom 选中未输入＝未完成行，生成跳过
        if !liveTiers.isEmpty {
            if let d = defaultTier, !d.isEmpty, liveTiers.contains(where: { $0.effort == d }) {
                e["default_reasoning_level"] = d
            }
            e["supported_reasoning_levels"] = liveTiers.map { ["effort": $0.effort, "description": $0.description] }
        } else {
            e.removeValue(forKey: "supported_reasoning_levels")
            e.removeValue(forKey: "default_reasoning_level")
        }
        for row in paramRows {
            guard let p = MetaParamDict.all.first(where: { $0.key == row.key }),
                  !MetaParamDict.basicKeys.contains(row.key) else { continue }
            if let v = Self.encodeValue(p, row.value) { e[row.key] = v }
        }
        if let d = try? JSONSerialization.data(withJSONObject: e, options: [.prettyPrinted]),
           let s = String(data: d, encoding: .utf8) {
            editorText = s
        }
    }

    /// 键是否「字典已知」（内置字典 ∪ 用户增补字典·顶层）
    static func isKnownParam(_ key: String) -> Bool {
        MetaParamDict.all.contains { $0.key == key } || UserMetaDict.isKnown(key, parentPath: nil)
    }

    /// 生成底座装配（R23 未知容错核心，纯函数供断言台直驱）：
    /// 原条目 → 未知编辑覆盖/移除 → 高级模式开时已知非基础键「无行即删」（关则保留＝用户未触及）
    static func assembleBaseEntry(original: [String: Any]?, advanced: Bool, rowKeys: Set<String>,
                                  unknownEdits: [String: Any], unknownRemoved: Set<String>) -> [String: Any] {
        var e = original ?? [:]
        for k in unknownRemoved { e.removeValue(forKey: k) }
        for (k, v) in unknownEdits { e[k] = v }
        if advanced {
            for k in Array(e.keys)
            where isKnownParam(k) && !MetaParamDict.basicKeys.contains(k) && k != "slug" && k != "display_name" && !rowKeys.contains(k) {
                e.removeValue(forKey: k)
            }
        }
        return e
    }

    /// 自动解析候选：条目顶层未命中键＋已文档化复杂父内的未知子键（一层下钻；父本身已知也下钻）
    static func collectUnknownCandidates(_ e: [String: Any]) -> [(key: String, parentPath: String, value: Any)] {
        var out: [(key: String, parentPath: String, value: Any)] = []
        for k in e.keys.sorted() where k != "slug" && k != "display_name" && !isKnownParam(k) {
            out.append((k, "", e[k] ?? NSNull()))
        }
        for parent in MetaKnownShapes.subkeys.keys.sorted() {
            guard let d = e[parent] as? [String: Any] else { continue }
            let known = MetaKnownShapes.subkeys[parent] ?? []
            for sk in d.keys.sorted() where !known.contains(sk) && !UserMetaDict.isKnown(sk, parentPath: parent) {
                out.append((sk, parent, d[sk] ?? NSNull()))
            }
        }
        return out
    }

    /// 应用：slug/display_name 强制覆写为模型名称 → 名称级落库；空文本＝清除全部元数据
    private func apply() {
        let t = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            state.setGroupMeta(groupKey: groupKey, slug: nil, meta: nil)
            state.toast = "已清除 \(groupKey) 的元数据"
            state.flashToast()
            onClose()
            return
        }
        guard var e = effectiveEntry else { return }
        e["slug"] = groupKey
        e["display_name"] = groupKey
        guard let d = try? JSONSerialization.data(withJSONObject: e, options: [.prettyPrinted]),
              let s = String(data: d, encoding: .utf8) else { return }
        state.setGroupMeta(groupKey: groupKey, slug: groupKey, meta: s)
        state.toast = "已应用 \(groupKey) 的元数据（slug=display_name=\(groupKey)）"
        state.flashToast()
        onClose()
    }

    // MARK: - 参数值编码（JSON↔界面）

    private static func numTextAny(_ v: Any) -> String {
        if let d = v as? Double { return d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d) }
        if let i = v as? Int { return String(i) }
        return String(describing: v)
    }

    /// 整数值存 Int、非整存 Double（JSON 序列化出干净的整数形态）
    private static func wholeNumber(_ d: Double) -> Any {
        if d.truncatingRemainder(dividingBy: 1) == 0, let i = Int(exactly: d) { return i }
        return d
    }

    /// 参数默认值（控件形态决定；添加与回退共用）
    static func defaultParamValue(_ p: MetaParam) -> ParamValue {
        switch p.control {
        case .basic: return .text("")
        case .text(let prefill): return .text(prefill)
        case .longText: return .longText("")
        case .toggle(let d): return .toggle(d)
        case .number(let d, _): return .number(numTextAny(d))
        case .picker(_, let d): return .picker(d)
        case .modeNumber(_, let m, let n): return .modeNumber(m, numTextAny(n))
        case .stringList: return .list([])
        case .structure: return .object([:])
        case .structureList: return .array([])
        }
    }

    /// JSON 值 → 界面值（识别回填）。
    /// R23 二轮：容器值优先按形态落位——字符串数组→.list（逐项行）、对象→.object（行内层级）、
    /// 数组→.array（行内递归）。
    /// R23 五轮·完备性：类型不符的标量不套默认（防值偷换）——枚举遇非字符串、布尔遇非布尔、
    /// 数值遇非数字、模式+数值遇非对象 → 一律降级 .text 保真呈现与回写。
    static func decodeValue(_ p: MetaParam, _ v: Any) -> ParamValue {
        if let l = v as? [String] { return .list(l) }
        if let d = v as? [String: Any] { return .object(d) }
        if let a = v as? [Any] { return .array(a) }
        func asText(_ v: Any) -> String {
            if let s = v as? String { return s }
            if let b = v as? Bool { return b ? "true" : "false" }
            return numTextAny(v)
        }
        switch p.control {
        case .basic: return .text("")
        case .text: return .text(asText(v))
        case .longText: return .longText(asText(v))
        case .toggle:
            if mrIsBool(v) { return .toggle(v as! Bool) }
            return .text(asText(v))
        case .number:
            if v is NSNumber, !mrIsBool(v) { return .number(numTextAny(v)) }
            return .text(asText(v))
        case .picker(_, _):   // 字典形态仅作分支判定，关联值不参与取值（警告清理）
            if let s = v as? String { return .picker(s) }
            return .text(asText(v))
        case .modeNumber(_, let m, _):
            if let d = v as? [String: Any] {
                let mode = (d["mode"] as? String) ?? m
                let limit = (d["limit"].map { numTextAny($0) } ?? "")
                return .modeNumber(mode, limit)
            }
            return .text(asText(v))
        case .stringList: return .list([])
        case .structure: return .object([:])
        case .structureList: return .array([])
        }
    }

    /// 界面值 → JSON 值（生成）；数值不可解析时丢弃该键（不编造）。
    /// text/longText：文本可解析为 JSON 对象/数组时按结构写回（结构化参数往返），否则按字符串。
    /// R23 二轮：.list/.object/.array 为已成型 JSON 值，原样写回（行内编辑改的就是它们本身）。
    static func encodeValue(_ p: MetaParam, _ v: ParamValue) -> Any? {
        func structuralOrString(_ s: String) -> Any? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("{") || t.hasPrefix("["),
               let data = t.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data, options: []),
               obj is [String: Any] || obj is [Any] {
                return obj
            }
            return s
        }
        switch (p.control, v) {
        case (.text, .text(let s)): return structuralOrString(s)
        case (.longText, .longText(let s)): return structuralOrString(s)
        case (.toggle, .toggle(let b)): return b
        case (.number, .number(let s)): return Double(s).map { wholeNumber($0) }
        case (.picker, .picker(let s)): return s
        case (.modeNumber(let opts, _, let n), .modeNumber(let m, let s)):
            let mode = opts.contains(m) ? m : (opts.first ?? m)
            let limit = Double(s).map { wholeNumber($0) } ?? wholeNumber(n)
            return ["mode": mode, "limit": limit]
        case (_, .list(let l)): return l.filter { !$0.isEmpty }   // 逐项行留空＝未完成项，生成时剔除
        case (_, .object(let d)): return d
        case (_, .array(let a)): return a
        case (_, .text(let s)): return structuralOrString(s)   // 类型降级值（R23 五轮）：保真回写，任何控件不丢键
        default: return nil
        }
    }
}

// MARK: - 高级参数行（三段固定列：变量名｜中文名｜控件；行高 36＋行间 0＝上下线条等距；
// 长文本类＝值摘要＋「编辑」入口，独立输入窗口编辑）
private struct ParamRowView: View {
    @Binding var row: CodexMetadataWindow.ParamRow
    let onEditLongText: () -> Void
    let onRemove: () -> Void

    private var param: MetaParam? {
        MetaParamDict.all.first { $0.key == row.key }
    }

    var body: some View {
        if let p = param {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(p.key).font(mono(11.5)).foregroundStyle(keyAccent)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: 240, alignment: .leading)
                    Text(p.zh).font(f(11.5)).foregroundStyle(ink3)
                        .lineLimit(1)
                        .frame(width: 96, alignment: .leading)
                    control(p)
                        .frame(width: 300, alignment: .leading)
                    Spacer(minLength: 0)
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(ink2)
                    }
                    .buttonStyle(.plain)
                    .help("移除该参数行（生成元数据时不再写入该键）")
                }
                .frame(minHeight: 36)   // 标签折行/枚举未知值等自适应增高，单行仍 36
                .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
                expansion   // R23 二轮：对象/数组＝子参数直接显示在主界面，退一格表示层级
            }
        }
    }

    /// 数组/列表值的行内层级展开（退一格；每项独占一行，参考 truncation_policy 子参数行形态）
    @ViewBuilder private var expansion: some View {
        switch row.value {
        case .object:
            InlineStructEditor(depth: 0, dict: Binding(
                get: { if case .object(let d) = row.value { return d }; return [:] },
                set: { row.value = .object($0) }
            ), path: row.key)
            .padding(.leading, 16)
        case .array(let a):
            InlineArrayEditor(depth: 0, items: Binding(
                get: { if case .array(let arr) = row.value { return arr }; return a },
                set: { row.value = .array($0) }
            ), path: row.key)
            .padding(.leading, 16)
        case .list(let l):
            ListItemsEditor(items: Binding(
                get: { if case .list(let arr) = row.value { return arr }; return l },
                set: { row.value = .list($0) }
            ))
            .padding(.leading, 16)
        default:
            EmptyView()
        }
    }

    /// 长文本摘要：结构化内容（{ / [ 开头，如 model_messages）只报形态与长度；纯文本截断展示
    private func longTextSummary(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "（空）" }
        if t.hasPrefix("{") || t.hasPrefix("[") { return "结构化内容 · \(t.count) 字符" }
        return t
    }

    @ViewBuilder private func control(_ p: MetaParam) -> some View {
        // 结构化文本（{ / [ 开头）统一走「摘要＋编辑」形态，独立窗口按结构逐字段填写
        let structural: Bool = {
            if case .text(let s) = row.value { return s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") || s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") }
            if case .longText = row.value { return true }   // 长文本类恒用摘要＋编辑（含纯文本）
            return false
        }()
        switch (p.control, row.value) {
        case (.text, .text(let s)) where !structural:
            InpField(monoStyle: true, text: Binding(
                get: { s },
                set: { row.value = .text($0) }
            ))
        case (.text, .text(let s)):
            HStack(spacing: 8) {
                Text(longTextSummary(s))
                    .font(mono(10.5)).foregroundStyle(ink3)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .leading)
                Button("编辑") { onEditLongText() }.cardBtn(mini: true)
            }
        case (.longText, .longText(let s)):
            HStack(spacing: 8) {
                Text(longTextSummary(s))
                    .font(mono(10.5)).foregroundStyle(ink3)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .leading)
                Button("编辑") { onEditLongText() }.cardBtn(mini: true)
            }
        case (.toggle, .toggle(let b)):
            Toggle("", isOn: Binding(
                get: { b },
                set: { row.value = .toggle($0) }
            ))
            .toggleStyle(.switch).controlSize(.mini)
        case (.number(_, let unit), .number(let s)):
            HStack(spacing: 4) {
                InpField(monoStyle: true, text: Binding(
                    get: { s },
                    set: { row.value = .number($0) }
                )).frame(width: 120)   // S7：数字输入统一 120（曾 110）
                if !unit.isEmpty { Text(unit).font(f(10.5)).foregroundStyle(ink3) }
            }
        case (.picker(let opts, _), .picker(let cur)):
            // R23 值级以元数据为准：未知取值原样置顶显示（标「未记录」），不套默认、不过滤
            NativeMenuPicker<String>(
                items: (opts.contains(cur) || cur.isEmpty)
                    ? opts.map { (Optional($0), $0) }
                    : [(Optional(cur), cur + "（未记录）")] + opts.map { (Optional($0), $0) },
                selection: Binding(
                    get: { cur },
                    set: { row.value = .picker($0 ?? cur) }
                )
            ).frame(width: 160, alignment: .leading)
        case (.modeNumber(let opts, _, _), .modeNumber(let m, let n)):
            HStack(spacing: 6) {
                NativeMenuPicker<String>(
                    items: (opts.contains(m) || m.isEmpty)
                        ? opts.map { (Optional($0), $0) }
                        : [(Optional(m), m + "（未记录）")] + opts.map { (Optional($0), $0) },
                    selection: Binding(
                        get: { m },
                        set: { row.value = .modeNumber($0 ?? m, n) }
                    )
                ).frame(width: 110, alignment: .leading)
                InpField(monoStyle: true, text: Binding(
                    get: { n },
                    set: { row.value = .modeNumber(m, $0) }
                )).frame(width: 120)   // S7：数字输入统一 120
            }
        case (_, .list(let l)):
            // R23 五轮：字符串数组＝摘要＋退格逐项行（形态参考对象展开）
            Text("数组 · \(l.count) 项 ↓").font(f(11)).foregroundStyle(ink3)
        case (_, .object(let d)):
            Text("对象 · \(d.count) 键 ↓").font(f(11)).foregroundStyle(ink3)
        case (_, .array(let a)):
            Text("数组 · \(a.count) 项 ↓").font(f(11)).foregroundStyle(ink3)
        case (_, .text(let s)):
            // R23 五轮·完备性：类型降级值（如枚举参数遇数字值）按保真文本呈现，不丢不换
            InpField(monoStyle: true, text: Binding(
                get: { s },
                set: { row.value = .text($0) }
            )).frame(width: 300)
        default:
            Text("—").font(f(11)).foregroundStyle(ink3)
        }
    }
}

// MARK: - 长文本参数独立输入窗口（超大长度专用；确定回填界面状态/取消放弃；
// 行内层级编辑的长字符串「编辑全文」亦复用——只编辑字符串值本身）
private struct StructuredJSONInputView: View {
    @EnvironmentObject var state: AppState
    let paramKey: String
    let initialText: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    enum FieldValue {
        case str(String)
        case num(String)
        case bool(Bool)
        case json(String)
    }

    @State private var fields: [(String, FieldValue)] = []
    @State private var newKey = ""
    @State private var newKind = "文本"
    @State private var expanded: Set<String> = []
    static let kinds = ["文本", "数字", "布尔", "JSON"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(paramKey).font(mono(12.5))
                    .foregroundStyle(keyAccent)
                Text("\(fields.count) 个字段").font(f(11)).foregroundStyle(ink3)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fields.indices, id: \.self) { i in
                        fieldRow(i)
                    }
                }
                .frame(maxWidth: 592, alignment: .leading)
            }
            .frame(height: 320)
            addFieldRow
            HStack {
                Spacer()
                Button("取消") { onCancel() }.cardBtn()
                Button("确定") { confirm() }.cardBtn(primary: true)
            }
        }
        .padding(16)
        .frame(width: 640, height: 480, alignment: .topLeading)
        .onAppear(perform: parseInitial)
    }

    private func fieldRow(_ i: Int) -> some View {
        // R23：已知子键在前（官方文档序）、未命中随后（⚠ 标记）；行高按展开态自适应
        let known = MetaKnownShapes.subkeys[paramKey]?.contains(fields[i].0) ?? false
        let tall = isLongString(i) && expanded.contains(fields[i].0)
        return HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 4) {
                if !known { Text("⚠").font(f(10)).foregroundStyle(warnColor).help("字典未记录该子键 · 以元数据为准") }
                Text(fields[i].0).font(mono(11.5)).foregroundStyle(known ? ink2 : warnColor)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 180, alignment: .leading)
            fieldControl(i)
                .frame(width: 330, alignment: .leading)
            Spacer(minLength: 0)
            Button {
                fields.remove(at: i)
            } label: {
                Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(ink2)
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: tall ? 210 : 64)
        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
    }

    /// 长字符串判定（系统提示词模板类：给专用编辑面）
    private func isLongString(_ i: Int) -> Bool {
        if case .str(let s) = fields[i].1 { return s.count > 300 }
        return false
    }

    @ViewBuilder private func fieldControl(_ i: Int) -> some View {
        switch fields[i].1 {
        case .str(let s):
            if isLongString(i) {
                // 长字符串（模板/文案类）：摘要＋「编辑全文」展开专用大编辑面（F 适配）
                if expanded.contains(fields[i].0) {
                    TextEditor(text: Binding(
                        get: { s },
                        set: { fields[i].1 = .str($0) }
                    ))
                    .font(mono(11)).scrollContentBackground(.hidden)
                    .padding(6).background(Color(NSColor.controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(sep, lineWidth: 1))
                    .frame(width: 330, height: 176)
                    HStack {
                        Text("\(s.count) 字符").font(f(11)).foregroundStyle(ink3)
                        Spacer()
                        Button("收起") { withAnimation(.easeInOut(duration: 0.15)) { _ = expanded.remove(fields[i].0) } }.cardBtn(mini: true)
                    }
                    .frame(width: 330)
                } else {
                    // S7：包进 VStack——此前 TupleView 两兄弟各自吃到 330 列宽 frame，「编辑全文」被拉满
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(s.prefix(60)) + (s.count > 60 ? "…" : ""))
                            .font(mono(10)).foregroundStyle(ink3)
                            .lineLimit(2).truncationMode(.tail)
                            .frame(maxWidth: 330, alignment: .leading)
                        Text("\(s.count) 字符").font(f(11)).foregroundStyle(ink3)
                        Button("编辑全文") { withAnimation(.easeInOut(duration: 0.15)) { _ = expanded.insert(fields[i].0) } }.cardBtn(mini: true)
                    }
                }
            } else {
                TextEditor(text: Binding(
                    get: { s },
                    set: { fields[i].1 = .str($0) }
                ))
                .font(mono(11)).scrollContentBackground(.hidden)
                .padding(5).background(Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(sep, lineWidth: 1))
                .frame(height: 52)
            }
        case .num(let s):
            InpField(monoStyle: true, text: Binding(
                get: { s },
                set: { fields[i].1 = .num($0) }
            )).frame(width: 120)
        case .bool(let b):
            Toggle("", isOn: Binding(
                get: { b },
                set: { fields[i].1 = .bool($0) }
            ))
            .toggleStyle(.switch).controlSize(.mini)
        case .json(let s):
            TextEditor(text: Binding(
                get: { s },
                set: { fields[i].1 = .json($0) }
            ))
            .font(mono(11)).scrollContentBackground(.hidden)
            .padding(5).background(Color(NSColor.controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(sep, lineWidth: 1))
            .frame(height: 52)
        }
    }

    private var addFieldRow: some View {
        HStack(spacing: 8) {
            // S7：与 InlineStructEditor 添加行同形态（InpField 180＋Picker 108＋同款文案；曾两套规格）
            InpField(monoStyle: true, text: $newKey).frame(width: 180)
            Picker("", selection: $newKind) {
                ForEach(Self.kinds, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 108)
            Button("＋ 添加字段") {
                let k = newKey.trimmingCharacters(in: .whitespaces)
                guard !k.isEmpty, !fields.contains(where: { $0.0 == k }) else { return }
                switch newKind {
                case "数字": fields.append((k, .num("0")))
                case "布尔": fields.append((k, .bool(false)))
                case "JSON": fields.append((k, .json("{}")))
                default: fields.append((k, .str("")))
                }
                newKey = ""
            }
            .cardBtn(mini: true)
            Spacer()
        }
        .frame(height: 32)
    }

    private func parseInitial() {
        guard let data = initialText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let d = obj as? [String: Any] else { return }
        // R23 排序：已知子键在前（官方文档序）、未命中随后；原文本键序不再优先
        let ordered = MetaKnownShapes.orderedKeys(d, path: paramKey)
        fields = ordered.map { k in
            let v = d[k] ?? ""
            if mrIsBool(v) { return (k, .bool(v as! Bool)) }
            if v is Int || v is Double { return (k, .num(metaNumText(v))) }
            if v is [String: Any] || v is [Any] {
                if let dd = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]),
                   let s = String(data: dd, encoding: .utf8) {
                    return (k, .json(s))
                }
            }
            return (k, .str((v as? String) ?? ""))
        }
    }

    private func confirm() {
        var dict: [String: Any] = [:]
        for (k, fv) in fields {
            switch fv {
            case .str(let s): dict[k] = s
            case .num(let s):
                if let d = Double(s) { dict[k] = d.truncatingRemainder(dividingBy: 1) == 0 ? (Int(d) as Any) : d }
                else { dict[k] = s }
            case .bool(let b): dict[k] = b
            case .json(let s):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = t.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data, options: []) {
                    dict[k] = obj
                } else {
                    dict[k] = s
                }
            }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
              let s = String(data: d, encoding: .utf8) else { return }
        onConfirm(s)
    }
}

/// 数字值 → 干净文本（整数无小数点）；结构化编辑窗与主窗共用
private func metaNumText(_ v: Any) -> String {
    if let d = v as? Double { return d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d) }
    if let i = v as? Int { return String(i) }
    return String(describing: v)
}

private func fieldLabel(_ text: String) -> some View {
    Text(text).font(f(11.5)).foregroundStyle(ink2).frame(width: 88, alignment: .leading)
}
