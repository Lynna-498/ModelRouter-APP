import SwiftUI
import AppKit
import ModelRouterCore

// MARK: - Claude Code CLI 配置窗（~/.claude/settings.json：读 → 编辑 → 备份 → 覆盖 → 复原）
// 唯一保存入口＝底部保存状态按钮（dirty「未保存」/ 干净「已保存」），其余操作均只改本副本。
struct CLIClientConfigView: View {
    @EnvironmentObject var state: AppState
    let harnessID: UUID
    var onClose: () -> Void

    private let store = ClaudeSettingsStore()

    @State private var editorText = ""
    @State private var editDict: [String: Any]? = nil
    @State private var dirty = false
    @State private var showQuickSheet = false
    @State private var showDict = false
    @State private var showFullConfirm = false
    @State private var searchText = ""
    @State private var dictTab: DictTab = .env
    @State private var updateCmd: UpdateCmd = .claudeUpdate
    @State private var expandedExamples: Set<String> = []
    /// 未保存关窗守卫的共享状态（窗口 delegate 与本视图各持同一引用）
    let dirtyBox: CLIDirtyBox
    /// 本窗内部 toast：state.toast 呈现在主窗，被本窗遮挡时用户看不到，故窗内操作反馈走这里
    @State private var localToast = ""
    @State private var localToastDetail = ""
    @State private var localToastGen = 0
    /// 最近一次载入/落盘时的文本：编辑器回填不计入「未保存」
    @State private var loadedText = ""

    private var harness: Harness? {
        state.config.harnesses.first(where: { $0.id == harnessID })
    }

    var body: some View {
        Group {
            if showDict { dictView.transition(.opacity) } else { editorView.transition(.opacity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(winBg)
        .animation(.easeInOut(duration: 0.15), value: showDict)   // S7：两整页切换补过渡（对照本窗 toast 动画先例）
        .onAppear(perform: loadOnce)
        .onChange(of: dirty) { _, new in dirtyBox.isDirty = new }
        .overlay(alignment: .bottom) {
            if !localToast.isEmpty {
                ToastBar(text: localToast, detail: localToastDetail)
                    .padding(.bottom, 18)   // S7：底距职责归挂载点（组件内嵌 18pt 已移除）
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: localToast)
        .sheet(isPresented: $showQuickSheet) { quickSheet }
        .alert("彻底复原", isPresented: $showFullConfirm) {
            Button("取消", role: .cancel) { }
            Button("确认清空", role: .destructive) { doFullRestore() }
        } message: {
            Text("将清空至 {\"env\":{}}，用户自定义键一并删除；与编辑器操作同一副本，保存后覆盖原件。")
        }
    }

    // MARK: - 编辑器视图

    private var editorView: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorHeader
            JSONCodeEditor(text: $editorText)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                .onChange(of: editorText) { _, new in onEditorChange(new) }

            HStack(spacing: 8) {
                Button("快速配置") { showQuickSheet = true }.cardBtn(primary: true)
                Button("配置字典") { showDict = true }.cardBtn()
                Spacer()
                Button { copyUpdateCommand() } label: { Text("更新 Claude Code") }.cardBtn()
                updateCmdMenu
                HelpTip(tip: "接管配置写入 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 后，CLI 自动更新关闭；点击「更新 Claude Code」复制命令、到终端运行即可，▼ 可切换为 npm 安装命令")
            }

            bottomRow
        }
        .padding(16)
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {
            Text("~/.claude/settings.json").font(f(13, .semibold))   // S7：标题与路径二留一（前者是后者子串）
            validityTag
            Spacer()
            Text("\(lineCount) 行 · \(editorText.count) 字符").font(f(11)).foregroundStyle(ink3)
            Button("格式化") { format() }.cardBtn(mini: true)
        }
    }

    @ViewBuilder private var validityTag: some View {
        if let err = validityError {
            HStack(spacing: 4) {
                Text("✗ JSON 非法").font(f(11, .semibold)).foregroundStyle(errColor)
                Text(err).font(f(11)).foregroundStyle(ink3)
                    .lineLimit(1).truncationMode(.tail)
            }
        } else {
            Text("✓ JSON 合法").font(f(11, .semibold)).foregroundStyle(okColor)
        }
    }

    /// 非法时的简短原因；合法（顶层为对象）返回 nil
    private var validityError: String? {
        if editDict != nil { return nil }
        let t = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "内容为空" }
        do {
            let obj = try JSONSerialization.jsonObject(with: Data(editorText.utf8))
            return obj is [String: Any] ? nil : "顶层须为 JSON 对象"
        } catch {
            let msg = (error as NSError).localizedDescription
            return msg.count > 60 ? String(msg.prefix(60)) + "…" : msg
        }
    }

    private var lineCount: Int {
        editorText.isEmpty ? 0 : editorText.components(separatedBy: "\n").count
    }

    /// 本窗 toast：样式复用 ToastBar；同代号新 toast 刷新、旧的到点不清（与 AppState.flashToast 同语义）
    private func flashLocal(_ msg: String, detail: String = "") {
        localToast = msg
        localToastDetail = detail
        localToastGen += 1
        let g = localToastGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {   // 与 AppState.toastDuration(2.6s) 对齐
            guard localToastGen == g else { return }
            localToast = ""
            localToastDetail = ""
        }
    }

    /// 更新命令（▼ 菜单切换；点击「更新 Claude Code」复制当前选择到剪贴板）
    enum UpdateCmd {
        case claudeUpdate, npm
        var command: String {
            switch self {
            case .claudeUpdate: return "claude update"
            case .npm: return "npm install -g @anthropic-ai/claude-code"
            }
        }
    }

    private var updateCmdMenu: some View {
        Menu {
            Picker("", selection: $updateCmd) {
                Text("claude update（默认）").tag(UpdateCmd.claudeUpdate)
                Text("npm install -g @anthropic-ai/claude-code").tag(UpdateCmd.npm)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "chevron.down")
                .font(f(9, .bold)).foregroundStyle(ink2)
                .frame(width: 18, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func copyUpdateCommand() {
        state.copy(updateCmd.command, flash: false)   // 主窗不弹「已复制」，由本窗 flashLocal 呈现
        flashLocal("已复制 \(updateCmd.command) —— 请打开终端运行以更新 Claude Code")
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            Button("半复原") { halfRestore() }.cardBtn()
            HelpTip(tip: "清除与 ModelRouter 有关的接入配置，用户自定义键保留")
            Button("彻底复原") { showFullConfirm = true }.cardBtn(danger: true)   // S7：? 已删——点击后的确认弹窗即完整说明，曾逐字重复
            Spacer()
            saveButton
        }
    }

    private var saveButton: some View {
        Group {
            if dirty {
                Button("保存") { saveFlow() }
                    .cardBtn(primary: true)   // 亮起＝快速配置「确认写入」同款（实心强调色，管理员 2026-09-27）
            } else {
                // 灰态观感＝管理员像素实测定案（2026-09-28），已收敛进 Theme.GhostButtonLabel（两窗共用）
                GhostButtonLabel(title: "保存")
                    .help("无未保存改动")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: dirty)   // S7：dirty 两态互换补轻过渡
    }

    // MARK: - 配置字典视图（单一入口，两个子项：环境变量 / 设置；搜索＝参数名＋描述）

    private enum DictTab { case env, settings }

    /// Claude Code 官方配置文档：环境变量页→env-vars，设置页→settings-reference（随页签切换）
    private var dictRefURL: URL? {
        URL(string: dictTab == .env
            ? "https://code.claude.com/docs/en/env-vars"
            : "https://code.claude.com/docs/en/settings-reference")
    }

    private var dictRefTip: String {
        dictTab == .env
            ? "访问 Anthropic 官方环境变量支持文档"
            : "访问 Anthropic 官方设置支持文档"
    }

    private func openDictReferenceDoc() {
        if let url = dictRefURL { NSWorkspace.shared.open(url) }
    }

    private var dictView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button("返回配置") { showDict = false }.cardBtn(mini: true)
                Picker("", selection: $dictTab) {
                    Text("环境变量 \(ClaudeEnvDict.entries.count)").tag(DictTab.env)
                    Text("设置 \(ClaudeSettingsDict.entries.count)").tag(DictTab.settings)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 252)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(f(11)).foregroundStyle(ink3)
                    TextField("搜索参数名或描述…", text: $searchText)
                        .textFieldStyle(.plain).font(f(12))
                }
                .padding(.horizontal, 9).frame(height: 28).frame(maxWidth: 340)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1))
                Spacer()
                // S7：页签已含总数，空搜索时不再重复显示「全部 N 项」
                if !searchText.isEmpty {
                    Text("命中 \(dictTab == .env ? filteredEnv.count : filteredSettings.count) 项")
                        .font(f(11)).foregroundStyle(ink3)
                }
                Button("访问官方支持文档") { openDictReferenceDoc() }.cardBtn(mini: true)
                HelpTip(tip: dictRefTip)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch dictTab {
                    case .env:
                        if filteredEnv.isEmpty { emptyDictRow }
                        else { ForEach(filteredEnv) { e in dictRow(e) } }
                    case .settings:
                        if filteredSettings.isEmpty { emptyDictRow }
                        else { ForEach(filteredSettings) { e in settingRow(e) } }
                    }
                }
            }
        }
    }

    /// S7：搜索无命中空态（此前列表区整片空白）
    private var emptyDictRow: some View {
        Text("无匹配条目 —— 支持按参数名或描述搜索")
            .font(f(12)).foregroundStyle(ink3)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 28)
    }

    private var filteredEnv: [ClaudeEnvEntry] {
        let all = ClaudeEnvDict.entries.sorted { $0.key < $1.key }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.key.lowercased().contains(q)
                || $0.desc.lowercased().contains(q)
        }
    }

    private var filteredSettings: [ClaudeSettingEntry] {
        let all = ClaudeSettingsDict.entries.sorted { $0.key < $1.key }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.key.lowercased().contains(q)
                || $0.desc.lowercased().contains(q)
        }
    }

    private func dictRow(_ e: ClaudeEnvEntry) -> some View {
        let managed = e.managed
        return HStack(alignment: .top, spacing: 13) {
            Text(e.key).font(mono(11.5))
                .foregroundStyle(managed ? ink3 : keyAccent)
                .frame(width: 300, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                DictDescBlock(id: e.id, text: e.desc, color: managed ? ink3 : ink2)
                if !e.accepted.isEmpty {
                    Text("接受值 \(e.accepted)").font(f(11)).foregroundStyle(ink3)
                }
            }
            Spacer(minLength: 8)
            if managed {
                Text("已被 ModelRouter 接管").font(f(11)).foregroundStyle(ink3).padding(.top, 2)
            } else {
                Button("添加") { addEntry(e) }.cardBtn(mini: true)
                    .disabled(envKeyExists(e.key))   // S7：与设置页同哲学——键已存在置灰（管理员批准）
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
    }

    /// 设置条目行：键＋分类｜描述＋Scope/Type/Default｜添加；撰写示例＝左缘钮＋通栏 JSON 显示器
    private func settingRow(_ e: ClaudeSettingEntry) -> some View {
        let expanded = expandedExamples.contains(e.id)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 13) {
                HStack(spacing: 6) {
                    Text(e.key).font(mono(11.5))
                        .foregroundStyle(keyAccent)
                    Text(e.category).font(f(10)).foregroundStyle(ink3)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color(NSColor.quaternaryLabelColor).opacity(0.25)))
                }
                .frame(width: 300, alignment: .leading)   // S7：与 env 页键列统一 300（曾 280，切页描述列左缘横跳 20pt）
                VStack(alignment: .leading, spacing: 4) {
                    DictDescBlock(id: e.id, text: e.desc, color: ink2)
                    metaLine("Scope", e.scope)
                    metaLine("Type", e.type)
                    metaLine("Default", e.defaultText)
                }
                Spacer(minLength: 8)
                Button("添加") { addSettingEntry(e) }.cardBtn(mini: true)
                    .disabled(settingKeyExists(e.key))
            }
            if !e.example.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {   // S7：展开/收起补过渡
                        if expanded { expandedExamples.remove(e.id) } else { expandedExamples.insert(e.id) }
                    }
                } label: {
                    Text(expanded ? "▾ 撰写示例" : "▸ 撰写示例")
                }
                .buttonStyle(.plain)
                .font(f(11)).foregroundStyle(ink2)
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(e.exampleFile) · 官方示例")
                            .font(mono(10)).foregroundStyle(ink3)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.quaternaryLabelColor).opacity(0.18))
                        Text(jsonHighlightedText(e.example))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .transition(.opacity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
    }

    private func metaLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(label).font(f(10.5, .semibold)).foregroundStyle(ink2)
                .frame(width: 46, alignment: .leading)
            Text(value.isEmpty ? "—" : value).font(f(10.5)).foregroundStyle(ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 点路径（如 permissions.allow）已存在于编辑器副本 → 添加钮置灰
    private func settingKeyExists(_ key: String) -> Bool {
        guard var node = editDict else { return false }
        for part in key.components(separatedBy: ".") {
            if let sub = node[part] as? [String: Any] {
                node = sub
            } else {
                return node[part] != nil
            }
        }
        return true
    }

    /// S7：env 键已存在于编辑器副本 env 对象 → 添加钮置灰（与设置页 settingKeyExists 同哲学）
    private func envKeyExists(_ key: String) -> Bool {
        guard let env = editDict?["env"] as? [String: Any] else { return false }
        return env[key] != nil
    }

    /// 设置条目「添加」＝写入该键（支持点路径）的空骨架，具体值在编辑器调整
    private func addSettingEntry(_ e: ClaudeSettingEntry) {
        guard var d = editDict else {
            flashLocal("JSON 非法，无法添加"); return
        }
        insertSkeleton(e.key, into: &d)
        editDict = d
        rerender()
        dirty = true
        flashLocal("已添加 \(e.key)（骨架，具体值在编辑器调整）")
    }

    private func insertSkeleton(_ key: String, into dict: inout [String: Any]) {
        insertSkeletonParts(key.components(separatedBy: ".")[...], into: &dict)
    }

    private func insertSkeletonParts(_ parts: ArraySlice<String>, into dict: inout [String: Any]) {
        guard let p = parts.first else { return }
        if parts.count == 1 {
            if dict[p] == nil { dict[p] = [String: Any]() }
        } else if var sub = dict[p] as? [String: Any] {
            insertSkeletonParts(parts.dropFirst(), into: &sub)
            dict[p] = sub
        } else {
            var sub = [String: Any]()
            insertSkeletonParts(parts.dropFirst(), into: &sub)
            dict[p] = sub
        }
    }

    // MARK: - 快速配置 sheet

    @ViewBuilder private var quickSheet: some View {
        if let h = harness {
            QuickConfigSheet(
                baseURL: state.endpointText + "/claude",
                authToken: state.accessKeyText(for: K.claudeKeyRef),
                slots: h.slots,
                existingPicker: (editDict?["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]] ?? [],
                onConfirm: { applyQuick($0) }
            )
        }
    }

    // MARK: - 载入与校验

    private func loadOnce() {
        switch store.load() {
        case .ok(let d):
            let raw = (try? String(contentsOfFile: store.path, encoding: .utf8)) ?? pretty(d)
            editorText = raw
            editDict = d
        case .missing:
            editorText = "{}"
            editDict = [:]
        case .badJSON:
            let raw = (try? String(contentsOfFile: store.path, encoding: .utf8)) ?? ""
            editorText = raw
            editDict = nil
        }
        loadedText = editorText
        dirty = false
        dirtyBox.saveAndClose = { saveFlow() }
        // 关窗守卫合法性分支：JSON 解析＋顶层对象（与保存闸门同源）
        dirtyBox.contentValid = { validityError == nil }
    }

    private func onEditorChange(_ new: String) {
        editDict = parseDict(new)
        refreshDirty()
    }

    /// 脏判定＝语义比对（当前编辑字典 vs 最近一次载入/落盘内容的解析结果）：
    /// 加空格再删、纯格式/键序改动解析后等价，不计脏（管理员 2026-09-27 反馈）；
    /// 非法 JSON 保持脏，未保存关窗守卫兜底。NSDictionary isEqual 为深层结构比较。
    private func refreshDirty() {
        guard let d = editDict else { dirty = true; return }
        guard let base = parseDict(loadedText) else { dirty = true; return }
        dirty = !NSDictionary(dictionary: d).isEqual(to: base)
    }

    private func parseDict(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let d = obj as? [String: Any] else { return nil }
        return d
    }

    /// 美化输出；序列化失败回退当前编辑器文本（不破坏内容）
    private func pretty(_ d: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]),
              let s = String(data: data, encoding: .utf8) else { return editorText }
        return s
    }

    /// 用 editDict 重渲染编辑器（快速配置/复原/字典添加后统一走这里）
    private func rerender() {
        if let d = editDict { editorText = pretty(d) }
    }

    private func format() {
        guard let d = editDict else {
            flashLocal("JSON 非法，无法格式化"); return
        }
        editorText = pretty(d)
    }

    // MARK: - 写入 / 复原

    /// 全窗口唯一保存入口
    private func saveFlow() {
        guard let d = editDict else {
            flashLocal("JSON 非法，未覆盖"); return
        }
        if store.save(d) {
            dirty = false
            loadedText = editorText
            flashLocal("已保存并覆盖原件")
        } else {
            flashLocal("保存失败：\(store.lastError ?? "未知错误")")
        }
    }

    /// 返回 true 表示已写入（sheet 关闭）；false 表示未写入（sheet 保留）
    private func applyQuick(_ spec: ClaudeSettingsStore.QuickConfig) -> Bool {
        guard var d = editDict else {
            flashLocal("JSON 非法，先修复后再快速配置"); return false
        }
        let cleaned = ClaudeSettingsStore.applyQuick(spec, to: &d)
        editDict = d
        editorText = pretty(d)
        refreshDirty()
        var msg = "已写入快速配置"
        if !cleaned.isEmpty { msg += "，已清理前代遗留键：" + cleaned.joined(separator: "、") }
        flashLocal(msg)
        return true
    }

    private func halfRestore() {
        guard var d = editDict else {
            flashLocal("JSON 非法，无法复原"); return
        }
        ClaudeSettingsStore.applyHalfRestore(to: &d)
        editDict = d
        rerender()
        refreshDirty()
        flashLocal("半复原完成 · 已清除 ModelRouter 接入配置，自定义键保留")
    }

    private func doFullRestore() {
        editDict = ClaudeSettingsStore.emptyFullRestore()
        rerender()
        refreshDirty()
        flashLocal("彻底复原完成 · 已清空至 {\"env\":{}}，保存后覆盖原件")
    }

    // MARK: - 字典添加

    private func addEntry(_ e: ClaudeEnvEntry) {
        guard var d = editDict else {
            flashLocal("JSON 非法，无法添加"); return
        }
        var env = d["env"] as? [String: Any] ?? [:]
        env[e.key] = e.defaultValue
        d["env"] = env
        editDict = d
        rerender()
        refreshDirty()
        flashLocal("已添加 \(e.key)")
    }
}

// MARK: - 快速配置弹窗（固定四项只读 + 选择三项 + 该卡槽位模型列表，行集固定无增删）
private struct QuickConfigSheet: View {
    @Environment(\.dismiss) private var dismiss

    let baseURL: String
    let authToken: String
    let slotIDs: [String]
    let onConfirm: (ClaudeSettingsStore.QuickConfig) -> Bool

    struct ModelRow: Identifiable {
        let id: String
        let model: String
        var label: String
        var description: String
        var oneM: Bool
        var isHaiku: Bool { ClaudeSettingsStore.isHaikuModel(model) }
    }

    @State private var rows: [ModelRow]
    @State private var subModel: String?
    @State private var effort: String
    @State private var compact: String

    init(baseURL: String, authToken: String, slots: [Slot], existingPicker: [[String: Any]],
         onConfirm: @escaping (ClaudeSettingsStore.QuickConfig) -> Bool) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.onConfirm = onConfirm
        self.slotIDs = slots.map { $0.clientModelField }

        // modelPicker 现状：双锚匹配（内部槽位 ID → 该槽位当前映射的供应商模型 ID，均剥 [1m]），
        // 命中的槽位按文件现状预填；写出侧 model 恒为内部槽位 ID（供应商真实 ID 条目写出时自动改回）
        let prefill = ClaudeSettingsStore.pickerPrefill(
            existing: existingPicker,
            anchors: slots.map { (slotID: $0.clientModelField, vendorModelID: $0.modelID) })
        var built: [ModelRow] = []
        for s in slots {
            let field = s.clientModelField
            let tier = Router.tierDisplay(field)
            let defaultLabel = s.modelID.map { "\(tier) · \($0)" } ?? tier
            if let p = prefill[field] {
                built.append(ModelRow(id: field, model: field,
                                      label: p.label.isEmpty ? defaultLabel : p.label,
                                      description: p.description, oneM: p.oneM))
            } else {
                built.append(ModelRow(id: field, model: field, label: defaultLabel,
                                      description: "", oneM: false))
            }
        }
        _rows = State(initialValue: built)
        let ids = slots.map { $0.clientModelField }
        _subModel = State(initialValue: ids.contains("claude-haiku-4-5") ? "claude-haiku-4-5" : ids.first)
        _effort = State(initialValue: "max")
        _compact = State(initialValue: "1000000")
    }

    private var authTokenDisplay: String {
        guard authToken.count > 16 else { return authToken }
        return "\(authToken.prefix(10))…\(authToken.suffix(4))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快速配置").font(f(14.5, .semibold))

            // 固定四项只读
            VStack(spacing: 0) {
                fixedRow("ANTHROPIC_BASE_URL", baseURL)
                fixedRow("ANTHROPIC_AUTH_TOKEN", authTokenDisplay)
                fixedRow("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1")
                fixedRow("CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY", "1")
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.quaternaryLabelColor).opacity(0.12)))

            // 选择三项
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("子代理模型").font(f(11.5)).foregroundStyle(ink2).frame(width: 112, alignment: .leading)
                    NativeMenuPicker<String>(
                        items: slotIDs.map { (Optional($0), $0) },
                        selection: Binding(get: { subModel }, set: { subModel = $0 })
                    )
                    .frame(width: 240, alignment: .leading)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Text("思考等级").font(f(11.5)).foregroundStyle(ink2).frame(width: 112, alignment: .leading)
                    Picker("", selection: $effort) {
                        ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 320)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Text("auto-compact 窗口").font(f(11.5)).foregroundStyle(ink2).frame(width: 112, alignment: .leading)
                    InpField(monoStyle: true, text: $compact).frame(width: 160)
                    Spacer()
                }
            }

            // 模型列表（行集＝该卡全部槽位，固定）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("模型").font(f(10.5)).foregroundStyle(ink3).frame(width: 160, alignment: .leading)
                    Text("label").font(f(10.5)).foregroundStyle(ink3)
                        .frame(width: 180, alignment: .leading).padding(.trailing, 8)   // S7：补与行内输入框一致的尾距
                    Text("description（选填）").font(f(10.5)).foregroundStyle(ink3)
                        .frame(width: 180, alignment: .leading).padding(.trailing, 8)   // 同上（第 4 列曾偏左 16pt）
                    Text("百万上下文").font(f(10.5)).foregroundStyle(ink3)
                    Spacer()
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($rows) { $row in modelRow($row) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 180)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.cardBtn()
                Button("确认写入") { confirm() }.cardBtn(primary: true)
            }
        }
        .padding(20)
        .frame(width: 700)
    }

    private func fixedRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).font(mono(11)).foregroundStyle(keyAccent)
                .frame(width: 322, alignment: .leading)
            Text(value).font(mono(11)).foregroundStyle(ink2)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().fill(sep.opacity(0.5)).frame(height: 1), alignment: .bottom)
    }

    private func modelRow(_ row: Binding<ModelRow>) -> some View {
        let dis = row.wrappedValue.isHaiku
        return HStack(spacing: 0) {
            Text(row.wrappedValue.model).font(mono(11)).foregroundStyle(ink2)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 160, alignment: .leading)
            InpField(monoStyle: true, text: row.label)
                .frame(width: 180).padding(.trailing, 8)
            InpField(monoStyle: true, text: row.description)
                .frame(width: 180).padding(.trailing, 8)
            Toggle("", isOn: Binding(get: { row.wrappedValue.oneM },
                                     set: { row.wrappedValue.oneM = $0 }))
                .toggleStyle(.switch).controlSize(.mini)
                .disabled(dis)
                .opacity(dis ? 0.4 : 1)
                .help(dis ? "haiku 档不支持 [1m]" : "百万上下文：写出时在 model ID 追加 [1m]")
            Spacer()
        }
    }

    private func confirm() {
        let opts = rows.map { r in
            ClaudeSettingsStore.PickerOption(model: r.model, label: r.label,
                                             description: r.description,
                                             oneM: r.isHaiku ? false : r.oneM)
        }
        let trimmed = compact.trimmingCharacters(in: .whitespaces)
        let spec = ClaudeSettingsStore.QuickConfig(
            baseURL: baseURL,
            authToken: authToken,
            subModel: subModel ?? (slotIDs.first ?? "claude-haiku-4-5"),
            effort: effort,
            compactWindow: trimmed.isEmpty ? "1000000" : trimmed,
            options: opts)
        if onConfirm(spec) { dismiss() }
    }
}

// MARK: - 未保存关窗守卫（CLI 配置独立窗的 NSWindowDelegate；FloatWindowCenter 强引用保活）
final class CLIDirtyBox {
    var isDirty = false
    var saveAndClose: (() -> Void)? = nil
    /// 关窗守卫用：当前编辑内容是否合法可保存（nil＝不检测视为合法；两配置窗各自注入检测算法——
    /// Claude 窗＝JSON 解析＋顶层对象；Codex 窗＝TOML 解析＋思考档位闸门）
    var contentValid: (() -> Bool)? = nil
}

final class CLICloseGuard: NSObject, NSWindowDelegate {
    private let box: CLIDirtyBox
    private let message: String
    private let invalidMessage: String

    init(box: CLIDirtyBox,
         message: String = "settings.json 的修改尚未保存并覆盖原件，关闭后将丢失。",
         invalidMessage: String = "当前修改不合法（JSON 解析失败或顶层不是对象），无法保存。继续编辑修复，或直接退出放弃全部修改。") {
        self.box = box
        self.message = message
        self.invalidMessage = invalidMessage
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard box.isDirty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if box.contentValid?() ?? true {
            // 合法：原有三选（保存并关闭 / 不保存并关闭 / 取消）
            alert.messageText = "有未保存的更改"
            alert.informativeText = message
            alert.addButton(withTitle: "保存并关闭")
            alert.addButton(withTitle: "不保存并关闭")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: sender) { [box] resp in
                switch resp {
                case .alertFirstButtonReturn:
                    box.saveAndClose?()
                    sender.close()
                case .alertSecondButtonReturn:
                    sender.close()
                default:
                    break
                }
            }
        } else {
            // 内容不合法：保存不可用（保存路径本就拒绝写非法文件），只剩继续编辑 / 直接退出两行为
            alert.messageText = "有未保存的更改（内容不合法）"
            alert.informativeText = invalidMessage
            alert.addButton(withTitle: "继续编辑")
            alert.addButton(withTitle: "直接退出")
            alert.beginSheetModal(for: sender) { resp in
                if resp == .alertSecondButtonReturn { sender.close() }   // 继续编辑＝不关窗
            }
        }
        return false
    }
}
