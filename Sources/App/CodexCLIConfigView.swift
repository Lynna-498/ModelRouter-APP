import SwiftUI
import AppKit
import ModelRouterCore

// MARK: - Codex CLI 配置窗（B 窗：~/.codex/config.toml 受管区外科手术 + model_modelrouter.json 目录）
// 结构同 Claude CLI 配置窗：文件头 → TOML 编辑器 → 添加的模型 → 默认模型 → 动作行 → 复原＋保存。
// 唯一保存入口＝保存按钮；快速配置＝确认窗一步落盘（备份→校验→原子写，含目录）。
// 配置字典/预览＝同窗覆盖层（if showDict/showPreview 条件渲染，退出靠 state 存活恢复）。
struct CodexCLIConfigView: View {
    @EnvironmentObject var state: AppState
    let harnessID: UUID
    var onClose: () -> Void

    private let store = CodexConfigStore()

    @State private var editorText = ""
    @State private var dirty = false
    @State private var showDict = false
    @State private var showPreview = false
    @State private var showQuickSheet = false
    @State private var showAddPop = false
    /// 默认模型行（窗口本地态，源＝文件受管区 model 键；不设＝不写入 model 键）
    @State private var defaultModel: String? = nil
    @State private var searchText = ""
    @State private var localToast = ""
    @State private var localToastDetail = ""
    @State private var localToastGen = 0
    @State private var loadedText = ""
    /// 磁盘目录的 slug 基线（开窗时读取；目录脏＝受管态下模型列表与基线不一致——表没变不改文件）
    @State private var diskCatalogSlugs: [String]? = nil
    let dirtyBox: CLIDirtyBox

    private var harness: Harness? {
        state.config.harnesses.first(where: { $0.id == harnessID })
    }

    /// 添加的模型（行集合＝槽位键＝模型名称；A 卡同源纯派生）
    private var addedModels: [String] {
        harness?.slots.map(\.clientModelField) ?? []
    }

    private var baseURL: String { state.endpointText + "/codex" }
    private var token: String { state.accessKeyText(for: K.codexKeyRef) }

    /// 快速配置灰态＝语义比对（受管区逐键实际值 vs 期望值；model 随默认模型联动）
    private var quickSettled: Bool {
        CodexRegion.isSettled(editorText, defaultModel: defaultModel, baseURL: baseURL, token: token)
    }

    var body: some View {
        Group {
            if showDict { dictView.transition(.opacity) }
            else if showPreview { previewView.transition(.opacity) }
            else { editorView.transition(.opacity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(winBg)
        // S7：三态切换补过渡（对照本窗 toast 动画先例）
        .animation(.easeInOut(duration: 0.15), value: showDict)
        .animation(.easeInOut(duration: 0.15), value: showPreview)
        .onAppear(perform: loadOnce)
        .onChange(of: combinedDirty) { _, new in dirtyBox.isDirty = new }   // 关窗守卫跟随合并脏（TOML ∨ 目录表变更）
        .overlay(alignment: .bottom) {
            if !localToast.isEmpty {
                ToastBar(text: localToast, detail: localToastDetail)
                    .padding(.bottom, 18)   // S7：底距职责归挂载点（组件内嵌 18pt 已移除）
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: localToast)
        .sheet(isPresented: $showQuickSheet) { quickSheet }
    }

    // MARK: - 编辑器视图

    private var editorView: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorHeader
            JSONCodeEditor(text: $editorText, mode: .toml)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 360)
                .onChange(of: editorText) { _, new in onEditorChange(new) }

            addedModelsCard
            defaultModelRow

            HStack(spacing: 8) {
                quickButton
                Button("配置字典") { showDict = true }.cardBtn()
                Spacer()
                Button("model_modelrouter.json 预览") { showPreview = true }.cardBtn()
            }
            .animation(.easeInOut(duration: 0.15), value: quickSettled)   // S7：幽灵↔实心跳变补过渡

            bottomRow
        }
        .padding(16)
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {
            Text("~/.codex/config.toml").font(f(13, .semibold))   // S7：标题与路径二留一（前者是后者子串）
            validityTag
            Spacer()
            Text("\(lineCount) 行 · \(editorText.count) 字符").font(f(11)).foregroundStyle(ink3)
            Button("格式化") { format() }.cardBtn(mini: true)
        }
    }

    @ViewBuilder private var validityTag: some View {
        if let err = validityError {
            HStack(spacing: 4) {
                Text("✗ TOML 非法").font(f(11, .semibold)).foregroundStyle(errColor)
                Text(err).font(f(11)).foregroundStyle(ink3)
                    .lineLimit(1).truncationMode(.tail)
            }
        } else {
            Text("✓ TOML 合法").font(f(11, .semibold)).foregroundStyle(okColor)
        }
    }

    /// 非法时的简短原因（TomlLite 校验器）；合法返回 nil
    private var validityError: String? {
        do {
            _ = try TomlLite.parse(editorText)
            return nil
        } catch let e as TomlLite.ParseError {
            return e.description
        } catch {
            return "解析失败"
        }
    }

    private var lineCount: Int {
        editorText.isEmpty ? 0 : editorText.components(separatedBy: "\n").count
    }

    // MARK: - 添加的模型（列表在上、「＋ 添加模型」在下；弹层自按钮向上弹出）

    private var addedModelsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("添加的模型").font(f(12.5, .semibold))
            if addedModels.isEmpty {
                Text("暂无添加的模型")
                    .font(f(11.5)).foregroundStyle(ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.quaternaryLabelColor).opacity(0.12)))
            } else {
                VStack(spacing: 0) {
                    ForEach(addedModels, id: \.self) { name in
                        HStack(spacing: 8) {
                            Text(name).font(f(12)).foregroundStyle(
                                AppState.isCodexCompliantName(name) ? ink2 : warnColor)
                                .lineLimit(1).truncationMode(.middle)
                            if !AppState.isCodexCompliantName(name) {
                                Text("名称不合规（需 ASCII）").font(f(10.5)).foregroundStyle(warnColor)
                            }
                            Spacer()
                            Button {
                                removeModel(name)
                            } label: {
                                Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(ink2)
                            }
                            .buttonStyle(.plain)
                            .help("从添加的模型中移除（A 卡行随之消失；model_modelrouter.json 于下次写入时更新）")
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.quaternaryLabelColor).opacity(0.12)))
            }
            HStack(spacing: 8) {
                Button("＋ 添加模型") { showAddPop = true }.cardBtn(mini: true)
                Spacer()
            }
            .popover(isPresented: $showAddPop, arrowEdge: .bottom) { addPopover }
        }
    }

    /// 候选＝模型管理页全部名称；已添加禁选；不合规禁选（决策 7：拦截＋提醒改名）
    private var candidates: [(name: String, added: Bool, compliant: Bool)] {
        var seen = Set<String>()
        var names: [String] = []
        for m in state.config.models where !seen.contains(m.groupKey) {
            seen.insert(m.groupKey)
            names.append(m.groupKey)
        }
        return names.map { ($0, addedModels.contains($0), AppState.isCodexCompliantName($0)) }
    }

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("选择要添加的模型").font(f(12, .semibold))
                Spacer()
                // S7：「关闭」已删——popover 点击外部即收起（原生行为）
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(candidates, id: \.name) { c in
                        HStack(spacing: 8) {
                            Text(c.name).font(f(12)).foregroundStyle(c.compliant ? ink2 : warnColor)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if !c.compliant {
                                Text("名称不合规（需 ASCII）——请先在模型管理页改名").font(f(10.5)).foregroundStyle(warnColor)
                            } else if c.added {
                                Text("已添加").font(f(10.5)).foregroundStyle(ink3)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 30)   // S7：与已添加模型行统一 30（曾 28）
                        .contentShape(Rectangle())
                        .opacity(c.added || !c.compliant ? 0.5 : 1)
                        .onTapGesture {
                            guard !c.added, c.compliant else { return }
                            addModel(c.name)
                        }
                        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
                    }
                }
            }
            .frame(height: 240)
        }
        .frame(width: 360)
    }

    // MARK: - 默认模型行（可不选；独立于快速配置；改动让快速配置键亮起）

    private var defaultModelRow: some View {
        HStack(spacing: 10) {
            Text("默认模型").font(f(12)).foregroundStyle(ink2).frame(width: 64, alignment: .leading)   // S7：112 对 4 字标签过宽
            NativeMenuPicker<String>(
                items: [(nil, "不设置（不写入 model 键）")]
                    + addedModels.map { (Optional($0), $0) },
                selection: $defaultModel
            )
            .frame(width: 300, alignment: .leading)
            Spacer()
        }
    }

    // MARK: - 动作行

    @ViewBuilder private var quickButton: some View {
        if quickSettled {
            // 灰态观感＝管理员像素实测定案（2026-09-28），收敛进 Theme.GhostButtonLabel（两窗共用）
            GhostButtonLabel(title: "快速配置")
                .help("受管参数已写入且与当前选择一致，无需重复写入")
        } else {
            Button("快速配置") { showQuickSheet = true }.cardBtn(primary: true)
                .help("把受管区写入编辑器副本（散键一并收编）；点击「保存」后覆盖原件并生成 model_modelrouter.json")
        }
    }

    /// S4 裁定附带需求（R21）：思考档位闸门＝enabled-reasoning-efforts 须覆盖全部模型元数据
    /// supported_reasoning_levels.effort 并集；未过＝红字＋保存禁用（saveFlow 另有双保险）。
    /// 独立性（2026-10-02 管理员反馈）：TOML 解析失败时闸门**让位**——非法告警由头部 TOML 状态行独立承担，
    /// 不再叠加误报「未设置思考档位」（解析失败本就找不到参数，属 TOML 域问题）。
    private var effortsGateError: String? {
        guard validityError == nil else { return nil }
        return ReasoningGate.check(toml: editorText, metaJSONs: addedModels.map { name in
            state.config.models.first { $0.groupKey == name }?.codexMetaJSON
        })
    }

    private var bottomRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let gateErr = effortsGateError {
                HintLine(text: gateErr, bad: true)
            }
            HStack(spacing: 8) {
                // R21：直接写入完整六档（两步流——保存是唯一落盘路径）；键不入受管区＝豁免快速配置与恢复登录
                Button("设置思考模式") {
                    editorText = ReasoningGate.applyPresetEfforts(editorText)
                    refreshDirty()
                    flashLocal("已写入 \(ReasoningGate.effortsKey)（六档全量）——点击「保存」后生效")
                }.cardBtn()
                    .help("把完整思考档位 \(ReasoningGate.presetLine) 写入编辑器副本（豁免区：不随快速配置清除、不入受管区）")   // S7：尾句与保存语义重复已删
                Button("恢复 OpenAI 登录") { restoreOpenAILogin() }.cardBtn()
                    .help("从副本中移除 ModelRouter 受管区，模型改走官方 OpenAI 登录；用户自定义区域保留")   // S7：尾句同上
                Spacer()
                saveButton
            }
        }
    }

    private var saveButton: some View {
        Group {
            if combinedDirty {
                Button("保存") { saveFlow() }
                    .cardBtn(primary: true)
                    .disabled(effortsGateError != nil || validityError != nil)
                    .help(effortsGateError ?? validityError ?? "保存并覆盖原件（config.toml / model_modelrouter.json 按需）；重启 Codex 后生效")
            } else {
                GhostButtonLabel(title: "保存")
                    .help("无未保存改动")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: combinedDirty)   // S7：幽灵↔实心跳变补过渡
    }

    // MARK: - 配置字典覆盖层（同窗条件渲染；「返回配置」退出，文档访问钮在搜索行内）
    // 2026-10-02 管理员指令：原「关闭」与「返回配置」功能完全重复——改为访问 OpenAI 官方文档

    /// 访问 OpenAI 官方 config.toml 配置文档（官方文档缺 enabled-reasoning-efforts 等键＝OpenAI 文档不全，
    /// 不代为补录；在线文档作为字典的查证补充）
    private func openConfigReferenceDoc() {
        if let url = URL(string: "https://learn.chatgpt.com/docs/config-file/config-reference#configtoml") {
            NSWorkspace.shared.open(url)
        }
    }

    private var dictView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button("返回配置") { showDict = false }.cardBtn(mini: true)
                Text("config.toml 键位 \(CodexConfigDict.all.count)").font(f(12, .semibold))
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(ink3)
                    TextField("搜索键名、中文名或描述…", text: $searchText)
                        .textFieldStyle(.plain).font(f(12))
                }
                .padding(.horizontal, 9).frame(height: 28).frame(maxWidth: 340)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1))
                Spacer()
                // S7：标题已含总数，空搜索时不再重复显示「全部 N 项」
                if !searchText.isEmpty {
                    Text("命中 \(filteredDict.count) 项").font(f(11)).foregroundStyle(ink3)
                }
                Button("访问在线支持文档") { openConfigReferenceDoc() }.cardBtn(mini: true)
                HelpTip(tip: "访问 OpenAI 官方关于 config.toml 的配置文档")
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if filteredDict.isEmpty { emptyDictRow }
                    else { ForEach(filteredDict) { e in dictRow(e) } }
                }
            }
        }
    }

    /// S7：搜索无命中空态（此前列表区整片空白）
    private var emptyDictRow: some View {
        Text("无匹配条目 —— 支持按键名、中文名或描述搜索")
            .font(f(12)).foregroundStyle(ink3)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 28)
    }

    private var filteredDict: [CodexConfigEntry] {
        let all = CodexConfigDict.all
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.key.lowercased().contains(q)
                || $0.zh.lowercased().contains(q)
                || $0.desc.lowercased().contains(q)
        }
    }

    private func dictRow(_ e: CodexConfigEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(e.key).font(mono(11.5))
                .foregroundStyle(e.managed ? ink3 : keyAccent)
                .lineLimit(2)   // S7：超长键（如 permissions 子路径 63 字符）限两行，不再撑破行高
                .frame(width: 300, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.zh).font(f(11.5, .semibold)).foregroundStyle(e.managed ? ink3 : ink2)   // S7：单子元素空壳 HStack 去壳
                DictDescBlock(id: e.key, text: e.desc, color: e.managed ? ink3 : ink2)   // S7：长描述 3 行截断＋展开
                if !e.accepted.isEmpty {
                    Text("接受值 \(e.accepted)").font(f(11)).foregroundStyle(ink3)
                }
            }
            Spacer(minLength: 8)
            if e.managed {
                Text("已被 ModelRouter 接管").font(f(11)).foregroundStyle(ink3).padding(.top, 2)
            } else {
                Button("添加") { addDictEntry(e) }.cardBtn(mini: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .opacity(e.managed ? 0.5 : 1)
        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
    }

    /// 字典「＋ 添加」＝把该键骨架写入编辑器副本（顶层键插至顶层区末尾、避开受管区；节键追加文件尾）
    private func addDictEntry(_ e: CodexConfigEntry) {
        guard !e.managed else { return }
        editorText = CodexRegion.insertSkeleton(editorText, skeleton: e.skeleton, isSection: e.isSection)
        onEditorChange(editorText)
        dirty = true
        flashLocal("已添加 \(e.key)（骨架，具体值在编辑器调整）")
    }

    // MARK: - model_modelrouter.json 预览覆盖层（只读，无说明文字）

    private var previewView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button("返回配置") { showPreview = false }.cardBtn(mini: true)
                Text("model_modelrouter.json 预览").font(f(12, .semibold))
                Spacer()
                Text("随添加的模型实时生成").font(f(11)).foregroundStyle(ink3)
                // S7：「关闭」已删——与「返回配置」同功能重复（字典层 2026-10-02 已修，预览层此处补齐）
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
            JSONDisplayView(source: previewText)
                .padding(12)
        }
    }

    private var previewText: String {
        CodexCatalog.prettyText(added: addedModels) { name in
            state.config.models.first { $0.groupKey == name }?.codexMetaJSON
        }
    }

    // MARK: - 快速配置确认 sheet

    private var tokenDisplay: String {
        token.count > 16 ? "\(token.prefix(10))…\(token.suffix(4))" : token
    }

    @ViewBuilder private var quickSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快速配置").font(f(14.5, .semibold))
            VStack(spacing: 0) {
                quickRow("model", defaultModel.map { "\"\($0)\"（默认模型）" } ?? "未设置 — 不写入该键")
                quickRow("model_provider", "\"modelrouter\"")
                quickRow("model_catalog_json", "\"~/.codex/model_modelrouter.json\"")
                // R25（2026-10-03）：preferred_auth_method 行已删——最新 Codex 不接受该键，受管区不再写入
                quickRow("forced_login_method", "\"api\"")
                quickRow("[model_providers.modelrouter]",
                         "name=\"ModelRouter\" · base_url=\(baseURL) · wire_api=\"responses\" · bearer（访问 Key \(tokenDisplay)）")
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.quaternaryLabelColor).opacity(0.12)))

            // S7：说明四行铺陈收敛为两行（第 1 行＝写入语义＋收编＋自定义区保留；第 2 行＝两步流＋models.json 不触碰）
            VStack(alignment: .leading, spacing: 5) {
                reminder("受管区整区覆盖写入编辑器副本；区外散落的本次将写键与旧 [model_providers.modelrouter] 节将被收编移除；用户自定义区域逐键保留、永不触碰")
                reminder("确认后仅写入副本——点击「保存」才覆盖原件（写前自动备份、失败不动原件）并同批生成 model_modelrouter.json；既有 ~/.codex/models.json 不触碰，接管后不再生效")
            }

            HStack {
                Spacer()
                Button("取消") { showQuickSheet = false }.cardBtn()
                Button("确认写入") { quickWrite() }.cardBtn(primary: true)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func quickRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).font(mono(11)).foregroundStyle(keyAccent)
                .frame(width: 250, alignment: .leading)
            Text(value).font(mono(11)).foregroundStyle(ink2)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)   // S7：长值两行呈现，不再中截断丢信息
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
    }

    private func reminder(_ text: String) -> some View {
        Text(text).font(f(11)).foregroundStyle(ink3).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 载入与校验

    /// 目录脏＝受管态（受管区在）且模型列表与磁盘目录 slug 基线不一致；
    /// 目录变更只跟随模型列表（表没变就不用改）；未受管不点亮（保存不会写目录）。
    private var catalogDirty: Bool {
        guard CodexRegion.hasRegion(editorText) else { return false }
        return diskCatalogSlugs != addedModels
    }

    /// 合并脏＝TOML 副本脏 ∨ 目录表变更——保存键点亮与关窗守卫的唯一依据
    private var combinedDirty: Bool { dirty || catalogDirty }

    private func loadOnce() {
        switch store.loadText() {
        case .ok(let t): editorText = t
        case .missing: editorText = ""
        case .unreadable:
            editorText = ""
            flashLocal("config.toml 存在但不可读——保存前请先确认内容")
        }
        loadedText = editorText
        dirty = false
        // 目录脏基线：磁盘目录的 slug 清单（表没变就不用改——目录变更只跟随模型列表）
        diskCatalogSlugs = store.loadCatalogText().flatMap { CodexCatalog.slugs(inJSON: $0) }
        dirtyBox.saveAndClose = { saveFlow() }
        // 关窗守卫合法性分支：TOML 解析＋思考档位闸门（与保存闸门同源——合法分支的「保存并关闭」才不会静默失败）
        dirtyBox.contentValid = { (try? TomlLite.parse(editorText)) != nil && effortsGateError == nil }
        // 首启继承：受管区 model 行且值∈已添加 → 预选；否则不设置
        let inherited = CodexRegion.defaultModel(in: editorText)
        defaultModel = (inherited != nil && addedModels.contains(inherited!)) ? inherited : nil
    }

    private func onEditorChange(_ new: String) {
        refreshDirty()
    }

    /// 脏判定＝语义比对（TOML 解析结果深层 isEqual，纯格式化不计脏——R7 口径）；非法保持脏
    private func refreshDirty() {
        guard let cur = try? TomlLite.parse(editorText),
              let base = try? TomlLite.parse(loadedText) else { dirty = true; return }
        dirty = !NSDictionary(dictionary: cur).isEqual(to: base)
    }

    /// 保守格式化：行尾空白清理＋3 连空行压至 2（不重排用户 TOML；语义不变不计脏）
    private func format() {
        let trimmed = editorText.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
        }
        var out: [String] = []
        var blanks = 0
        for l in trimmed {
            if l.isEmpty {
                blanks += 1
                if blanks <= 2 { out.append(l) }
            } else {
                blanks = 0
                out.append(l)
            }
        }
        editorText = out.joined(separator: "\n")
    }

    private func flashLocal(_ msg: String, detail: String = "") {
        localToast = msg
        localToastDetail = detail
        localToastGen += 1
        let g = localToastGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            guard localToastGen == g else { return }
            localToast = ""
            localToastDetail = ""
        }
    }

    // MARK: - 写入 / 复原

    /// 目录写入（快速配置与保存联动共用）：条目＝当前添加的模型，slug=display_name=名称
    private func writeCatalogNow() -> Bool {
        let entries = addedModels.map { name in
            CodexCatalog.entry(name: name,
                               metaJSON: state.config.models.first { $0.groupKey == name }?.codexMetaJSON)
        }
        if store.saveCatalog(entries) {
            diskCatalogSlugs = addedModels   // 基线随落盘更新
            return true
        }
        flashLocal("model_modelrouter.json 写入失败：\(store.lastError ?? "")")
        return false
    }

    /// 快速配置＝确认后写入**编辑器副本**（复验问题 8：两步流——保存是唯一落盘路径，
    /// 草稿原行为；确认窗只改副本并标脏，点保存才备份→校验→覆盖原件并同批生成目录）
    private func quickWrite() {
        editorText = CodexRegion.applyQuick(editorText, defaultModel: defaultModel,
                                            baseURL: baseURL, token: token)
        refreshDirty()
        flashLocal("受管区已写入编辑器副本——点击「保存」覆盖原件（写前自动备份）并生成 model_modelrouter.json")
        showQuickSheet = false
    }

    /// 全窗口唯一保存入口；受管区在场时同批重生成目录（spec 四.5：写入时点＝快速配置/保存）
    /// 全窗口唯一保存入口＝两文件唯一落盘时刻：TOML 副本脏→写 config.toml；
    /// 模型列表变更（目录脏）→重生成写 model_modelrouter.json。保存成功提示重启 Codex 生效
    /// （两文件 Codex 均重启后才读取，实时写盘无意义）。
    private func saveFlow() {
        var parts: [String] = []
        // R21 双保险：思考档位闸门未过不落盘（正常由保存键禁用拦住）
        if let gateErr = effortsGateError {
            flashLocal(gateErr)
            return
        }
        if dirty {
            guard (try? TomlLite.parse(editorText)) != nil else {
                flashLocal("TOML 非法，未覆盖"); return
            }
            if store.save(editorText) {
                loadedText = editorText
                dirty = false
                parts.append("config.toml")
            } else {
                flashLocal("保存失败：\(store.lastError ?? "未知错误")")
                return
            }
        }
        if catalogDirty {
            if writeCatalogNow() {
                parts.append("model_modelrouter.json")
            }
        }
        guard !parts.isEmpty else {
            flashLocal("无未保存改动")
            return
        }
        flashLocal("已保存：\(parts.joined(separator: " ＋ "))——请重启 Codex 使变更生效")
    }

    /// 恢复 OpenAI 登录（原「半复原」，S4 裁定 2026-10-02 更名——功能取向不变：移除受管区＝模型改走官方登录）
    private func restoreOpenAILogin() {
        guard CodexRegion.hasRegion(editorText) else {
            flashLocal("副本中没有受管区"); return
        }
        editorText = CodexRegion.remove(editorText)
        refreshDirty()
        flashLocal("恢复 OpenAI 登录 · 已移除受管区，用户自定义区域保留")
    }

    // MARK: - 添加的模型增删

    private func addModel(_ name: String) {
        var ok = false
        withAnimation(.easeInOut(duration: 0.15)) {   // S7：列表增删补过渡
            ok = state.addCodexModel(harnessID: harnessID, name: name)
        }
        if ok { flashLocal("已添加 \(name)") }
    }

    private func removeModel(_ name: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            state.removeSlot(harnessID: harnessID, field: name)
            if defaultModel == name { defaultModel = nil }
        }
        flashLocal("已移除 \(name)")
    }
}
