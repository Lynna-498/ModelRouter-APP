// MARK: - 模型编辑窗与探测确认窗（自 ModelsView 拆分·T9/I34，纯移动）
import SwiftUI
import ModelRouterCore

struct ModelSheet: View {
    enum Mode { case add; case edit(EditTarget) }

    /// 编辑目标（sheet 身份）：名称组 + 模型 ID + 锚点条目——显式携带，禁由名称反查（I5）
    struct EditTarget: Identifiable {
        let groupTitle: String
        let modelID: String
        let anchor: ModelEntry
        var id: String { groupTitle + "|" + modelID }
    }

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    let mode: Mode

    @State private var modelID = ""
    @State private var name = ""
    @State private var loadedName = ""                 // R8：名称 ASCII 约束只拦「新改」的名称，存量不改不拦
    @State private var namePicked = false          // 从既有名称里选中的 → 输入框禁用
    @State private var idPicked = false            // 从 ID 菜单选中的 → 输入框禁用（镜像名称字段）
    @State private var loadedID = ""               // 编辑基线 ID（删除集合的作用域；添加模式为空）
    @State private var metaRaw = ""
    @State private var checked: [UUID: Bool] = [:]
    @State private var outcomes: [String: ProbePhase] = [:]
    @State private var outcomeDetails: [String: String] = [:]
    @State private var touched: Set<UUID> = []
    @State private var hint = ""
    @State private var hintBad = false
    @State private var resultFoot = ""
    @State private var showResults = false
    @State private var showManual = false
    @State private var manual: [UUID: [ModelAPI: Bool]] = [:]
    @State private var confirming = false
    @State private var pendingTargets: [Vendor] = []
    @AppStorage("mr.probe.suppressConfirm") private var suppressConfirm = false

    private var editingTarget: EditTarget? {
        if case .edit(let t) = mode { return t }
        return nil
    }
    private var metaConfigured: Bool { !metaRaw.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 编辑时改了 ID：修订3 就地换 ID 语义（勾选且该名称下已有条目的供应商改写为新 ID；未勾选供应商条目不动）
    private var idChangedHint: String? {
        guard editingTarget != nil, !loadedID.isEmpty,
              !modelID.trimmingCharacters(in: .whitespaces).isEmpty,
              modelID.trimmingCharacters(in: .whitespaces) != loadedID else { return nil }
        return "模型 ID 已更改：已勾选且在该名称下已有条目的供应商，保存将就地改写为新 ID（引用它的未锁定模型位一并改绑，锁定行保留旧 ID）；未勾选供应商的条目不动"
    }

    /// 模型 ID 校验：只禁空格（斜杠允许——部分兼容端接受 供应商/模型名 形态的模型 ID）
    private var modelIDError: String? {
        let t = modelID.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if t.contains(" ") { return "模型 ID 不能含空格" }
        return nil
    }

    /// R8 名称约束（slug=display_name=名称字面直用）：新改的名称仅 ASCII（空格自动转 -）；未改动的存量名称不拦
    private var nameError: String? {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != loadedName else { return nil }
        return AppState.isCodexCompliantName(t)
            ? nil : "名称仅支持 ASCII 字符（中文等不可用，空格自动转换为 -）——Codex 接入的 slug 直用名称"
    }

    // ── 保存预览（与 save() 共用同一请求构造；字段非法/未勾选时返回 nil，错误文案仍归 save()）──
    /// 保存请求（单一构造源：save() 与换 ID 影响清单均复用它；baseline 计算规则不变）
    private var saveRequest: ModelLibraryRules.SaveRequest? {
        guard modelIDError == nil, nameError == nil else { return nil }
        let mid = modelID.trimmingCharacters(in: .whitespaces)
        guard !mid.isEmpty else { return nil }
        let targets = checkedVendors
        guard !targets.isEmpty else { return nil }
        let nm = name.trimmingCharacters(in: .whitespaces)
        let meta = metaRaw.trimmingCharacters(in: .whitespaces)
        let baseline: String? = (editingTarget == nil || loadedID.isEmpty) ? nil : loadedID
        return ModelLibraryRules.SaveRequest(modelID: mid, groupName: nm,
                                             vendorIDs: targets.map(\.id),
                                             codexSlug: slugFrom(metaRaw),
                                             codexMetaJSON: meta.isEmpty ? nil : meta,
                                             baselineModelID: baseline)
    }

    /// 换 ID 影响清单（planSave 预演；非空才渲染）
    private var saveSwapHint: String? {
        guard let req = saveRequest else { return nil }
        let swaps = ModelLibraryRules.planSave(state.config, req).swaps
        guard !swaps.isEmpty else { return nil }
        var lines = ["以下供应商在该名称下已有其他 ID，保存将改写其 ID："]
        for sw in swaps {
            let vn = state.config.vendors.first(where: { $0.id == sw.vendorID })?.name
                ?? String(sw.vendorID.uuidString.prefix(8))
            lines.append("\(vn)（\(sw.oldID) → \(sw.newID)）")
        }
        let locked = swaps.reduce(0) { $0 + $1.skippedLockedSlots.count }
        if locked > 0 {
            lines.append("（其中 \(locked) 个锁定模型位保留旧 ID）")
        }
        return lines.joined(separator: "\n")
    }

    /// 冲突清单（保存将跳过的供应商；独立 HintLine 以红色呈现）
    private var saveConflictHint: String? {
        guard let req = saveRequest else { return nil }
        let conflicts = ModelLibraryRules.planSave(state.config, req).conflicts
        guard !conflicts.isEmpty else { return nil }
        return "存在冲突，保存时将跳过：\n" + conflicts.joined(separator: "\n")
    }

    /// 库内已有的模型名称（去重、排序），供快速选取
    private var existingNames: [String] {
        Array(Set(state.config.models.compactMap { $0.displayName }.filter { !$0.isEmpty })).sorted()
    }

    private var checkedVendors: [Vendor] {
        state.config.vendors.filter { checked[$0.id, default: false] }
    }
    /// 探测目标：勾选了就用勾选的，没勾就遍历全部
    private var detectionTargets: [Vendor] {
        checkedVendors.isEmpty ? state.config.vendors : checkedVendors
    }
    private var probeTitle: String { checkedVendors.isEmpty ? "自动探测" : "探测" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text(editingTarget == nil ? "添加模型" : "编辑模型").font(f(14.5, .semibold))
                        HelpTip(tip: "「保存」只写入模型信息，不产生消耗。同名多模型 ID 全部保留、互不覆盖；模型 ID 可从该名称下已注册的 ID 中选取。已保存供应商锁定勾选——保存只新增，删除供应商条目用条目行的垃圾桶。「探测」按 Anthropic Messages / OpenAI Responses / OpenAI Chat Completions 的官方请求形态发最小真实请求，返回真实 Token 才判定可用——会产生真实消费（单端点 ≤50 Token），点击后有二次确认，取消可改用手动设置。黄色徽标 = 未检测。")
                    }
                    SheetField(label: { fieldLabel("模型 ID") }) {
                        HStack(spacing: 6) {
                            InpField(monoStyle: true, text: $modelID, bad: modelIDError != nil)
                                .disabled(idPicked)
                            Menu {
                                Button("手动输入") { idPicked = false }
                                Divider()
                                let ids = ModelLibraryRules.registeredModelIDs(in: state.config, groupKey: name.trimmingCharacters(in: .whitespaces))
                                if ids.isEmpty {
                                    Button("（该名称下暂无已注册模型 ID）") {}.disabled(true)
                                } else {
                                    ForEach(ids, id: \.self) { id in
                                        Button(id) {
                                            modelID = id
                                            idPicked = true
                                            syncCluster(id)
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: idPicked ? "text.cursor" : "list.bullet")
                                    .font(.system(size: 11))
                                    .frame(width: 28, height: 28)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.9), lineWidth: 1)))
                                    .foregroundStyle(idPicked ? accent : ink2)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .help("从该名称下已注册的模型 ID 中选取；选中后勾选自动切到该 ID 的供应商；「手动输入」解锁")
                        }
                    }
                    HintLine(text: modelIDError ?? "", bad: true)
                    if let h = idChangedHint {
                        HintLine(text: h, bad: false)
                    }
                    if let h = saveSwapHint {
                        HintLine(text: h, bad: false)
                    }
                    if let h = saveConflictHint {
                        HintLine(text: h, bad: true)
                    }
                    SheetField(label: { fieldLabel("模型名称") }) {
                        HStack(spacing: 6) {
                            InpField(text: Binding(
                                get: { name },
                                set: { new in
                                    // 空格自动转 -（仅手动输入态；从既有名称选取的存量原名不动）
                                    let converted = namePicked ? new : new.replacingOccurrences(of: " ", with: "-")
                                    name = converted
                                }
                            ), bad: nameError != nil)
                                .disabled(namePicked)
                            Menu {
                                Button("手动输入") { namePicked = false }
                                Divider()
                                ForEach(existingNames, id: \.self) { n in
                                    Button(n) {
                                        name = n
                                        namePicked = true
                                    }
                                }
                            } label: {
                                Image(systemName: namePicked ? "text.cursor" : "list.bullet")
                                    .font(.system(size: 11))
                                    .frame(width: 28, height: 28)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.9), lineWidth: 1)))
                                    .foregroundStyle(namePicked ? accent : ink2)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .help("从已有模型名称中快速选取；选中后名称框锁定，再点此按钮可改回手动输入")
                        }
                    }
                    if let ne = nameError {
                        HintLine(text: ne, bad: true)
                    }
                    SheetField(label: {
                        HStack(spacing: 4) {
                            Text("模型元数据").font(f(12.5)).foregroundStyle(ink2)
                            HelpTip(tip: "推荐粘贴官方 models.json 中的单条模型元数据。整段粘贴时：仅一个条目会自动提取。没有官方元数据时用编辑窗生成最小条目，或留空（生成目录时自动按 slug=模型名称 补最小条目）。")
                        }
                    }) {
                        HStack {
                            Text(metaConfigured ? "已配置 · slug=\(slugFrom(metaRaw) ?? "?")" : "未配置 · 自动条目（slug=模型名称）")
                                .font(mono(11)).foregroundStyle(metaConfigured ? ink2 : ink3)
                            Spacer()
                            Button("编辑 JSON…") { presentMetaEditor() }.cardBtn(mini: true)
                        }
                    }

                    // 供应商勾选（S2/R10①④：勾选＝新增接入；已保存的锁定不可取消，删除只走条目行垃圾桶；
                    // 全部线测试失败的供应商变灰不可选；探测目标=勾选的，没勾则全部）
                    VStack(spacing: 0) {
                        ForEach(state.config.vendors) { v in
                            vendorCheckRow(v)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1)))

                    HintLine(text: hint, bad: hintBad)

                    if showManual {
                        manualSection
                    }

                    if showResults {
                        resultsSection
                    }
                }
                .padding(24)
                .frame(width: 560, alignment: .leading)
            }
            .frame(width: 560)   // I5：窗高交外层封顶，内容超出滚动；底栏固定不滚（探测后「保存」始终可点）
            Divider()
            HStack {
                Button("完成") { dismiss() }.cardBtn()
                Spacer()
                Button(probeTitle) { requestDetection() }.cardBtn()
                Button("保存") { save() }.cardBtn(primary: true)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(maxWidth: 560, maxHeight: 800)   // I5：限高 800（finite；内容不足时窗高=内容高；禁 .infinity）
        .sheet(isPresented: $confirming) {
            DetectionConfirmSheet(vendorCount: pendingTargets.count,
                                  endpointCount: pendingTargets.reduce(0) { $0 + (endpointOpen($1, .messages) ? 1 : 0) + (endpointOpen($1, .responses) ? 1 : 0) + (endpointOpen($1, .completions) ? 1 : 0) },
                                  suppress: $suppressConfirm,
                                  onManual: { openManual() },
                                  onConfirm: { runDetection(pendingTargets) })
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let t = editingTarget else { return }
        modelID = t.modelID
        loadedID = t.modelID
        idPicked = true
        name = t.anchor.displayName ?? ""
        loadedName = name
        // 该 ID 段首个非空元数据跟随（I5：编辑按 (供应商, 模型ID) 精确预勾，绝不按名称跨 ID 卷入）
        metaRaw = state.config.models
            .first(where: { $0.modelID == t.modelID && !($0.codexMetaJSON ?? "").isEmpty })?
            .codexMetaJSON ?? ""
        for e in state.config.models where e.modelID == t.modelID {
            checked[e.vendorID] = true
        }
    }

    // ── 供应商勾选行（S2/R10①④：基线已保存＝锁定勾选；全部线测试失败＝变灰不可选）──
    private func vendorCheckRow(_ v: Vendor) -> some View {
        let saved = isBaselineVendor(v)
        let failed = vendorFailedTests(v)
        let isChecked = Binding<Bool>(
            get: { checked[v.id, default: false] },
            set: { checked[v.id] = $0 }
        )
        return HStack(spacing: 9) {
            if saved {
                // 增删分离：已保存供应商锁定勾选（不可取消）；删除只走条目行垃圾桶
                Toggle("", isOn: .constant(true))
                    .toggleStyle(.checkbox).labelsHidden().controlSize(.regular)
                    .disabled(true)
            } else {
                Toggle("", isOn: isChecked)
                    .toggleStyle(.checkbox).labelsHidden().controlSize(.regular)
                    .disabled(failed)
            }
            Text(v.name).font(f(12.5))
            HStack(spacing: 4) {
                if v.anthropicBase != nil { ProtoBadge(proto: .anthropic) }
                if v.openaiBase != nil { ProtoBadge(proto: .openai) }
            }
            if saved {
                Text("已保存").font(f(10)).foregroundStyle(ink3)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(sep.opacity(0.5)))
                    .help("该模型 ID 下已有此供应商条目（保存只新增，不会删除；删除请用条目行的垃圾桶）")
            }
            if failed {
                Text("测试未通过").font(f(10)).foregroundStyle(errColor)
                    .help("该供应商全部已配置端点的测试未通过，暂不可选；在供应商管理重新测试通过后自动恢复")
            }
            Spacer()
            verdictText(v)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .overlay(Rectangle().fill(sep).frame(height: 1), alignment: .bottom)
        .opacity(failed && !saved ? 0.55 : 1)
    }

    /// 基线（编辑目标 ID）下已有条目的供应商：锁定勾选（保存永不删除基线）
    private func isBaselineVendor(_ v: Vendor) -> Bool {
        guard !loadedID.isEmpty else { return false }   // 添加模式无基线
        return state.config.models.contains { $0.modelID == loadedID && $0.vendorID == v.id }
    }

    /// S2/R10① 失效＝全部已配置线的 URL 检查均失败（未检测/待重测不算灰，与「未检测算可用」口径一致）
    private func vendorFailedTests(_ v: Vendor) -> Bool {
        var lines = 0, failed = 0
        if v.anthropicBase != nil { lines += 1; if v.anthropicURLSupport == false { failed += 1 } }
        if v.openaiBase != nil { lines += 1; if v.openaiURLSupport == false { failed += 1 } }
        return lines > 0 && failed == lines
    }

    /// 勾选行右侧的三线结论：一枚 API 一枚小徽标（只看颜色），不再堆长句
    @ViewBuilder
    private func verdictText(_ v: Vendor) -> some View {
        let states: [(ModelAPI, Avail?)] = [(.messages, apiAvail(v, .messages)),
                                            (.responses, apiAvail(v, .responses)),
                                            (.completions, apiAvail(v, .completions))]
        if states.contains(where: { $0.1 != nil }) {
            HStack(spacing: 4) {
                ForEach(states, id: \.0) { api, avail in
                    if let avail {
                        ModelAPIBadge(api: api, avail: avail)
                    }
                }
            }
        } else if verdictOf(v) != nil {
            Text("检测中…").font(f(11)).foregroundStyle(ink3)
        } else {
            Text("未检测").font(f(11)).foregroundStyle(ink3)
        }
    }

    /// 单线结论 → 徽标颜色；没跑过的线或检测中返回 nil（不显示徽标，行上显示「检测中…」）
    private func apiAvail(_ v: Vendor, _ api: ModelAPI) -> Avail? {
        guard let ph = outcomes[outcomeKey(v, api)], ph != .running else { return nil }
        return ph.passed ? .ok : .off(ph.shortReason)
    }

    /// 检测中：任意一条线还在跑
    private func verdictOf(_ v: Vendor) -> ProbePhase? {
        for api in [ModelAPI.messages, .responses, .completions] {
            if outcomes[outcomeKey(v, api)] == .running { return .running }
        }
        return nil
    }

    // ── 手动设置 API 支持（取消二次确认后出现；不产生消耗）──
    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动设置 API 支持（不产生消耗；应用到勾选的供应商，徽标按此显示）")
                .font(f(11)).foregroundStyle(ink3)
            ForEach(checkedVendors) { v in
                HStack(spacing: 12) {
                    Text(v.name).font(f(12)).frame(width: 150, alignment: .leading).lineLimit(1)
                    ForEach([ModelAPI.messages, .responses, .completions], id: \.rawValue) { api in
                        Toggle(api.label, isOn: manualBinding(v.id, api))
                            .toggleStyle(.checkbox).font(f(11.5))
                    }
                }
            }
            if checkedVendors.isEmpty {
                Text("先勾选要设置的供应商。").font(f(11)).foregroundStyle(ink3)
            }
            Button("应用手动设置") { applyManual() }.cardBtn(mini: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.quaternaryLabelColor).opacity(0.12)))
    }

    private func manualBinding(_ vid: UUID, _ api: ModelAPI) -> Binding<Bool> {
        Binding(get: { manual[vid]?[api] ?? true },
                set: { manual[vid, default: [:]][api] = $0 })
    }

    private func openManual() {
        confirming = false
        for v in checkedVendors {
            for api in [ModelAPI.messages, .responses, .completions]
            where manual[v.id]?[api] == nil {
                manual[v.id, default: [:]][api] = true
            }
        }
        showManual = true
    }

    /// 手动设置：写进勾选供应商的条目（没有则建），tested = true
    private func applyManual() {
        let vs = checkedVendors
        guard !vs.isEmpty else { setHint("请先勾选要设置的供应商。", bad: true); return }
        let mid = modelID.trimmingCharacters(in: .whitespaces)
        guard !mid.isEmpty else { setHint("请填写模型 ID。", bad: true); return }
        let nm = name.trimmingCharacters(in: .whitespaces)
        let meta = metaRaw.trimmingCharacters(in: .whitespaces)
        for v in vs {
            let entry = state.upsertEntry(modelID: mid, vendorID: v.id,
                                          displayName: nm.isEmpty ? nil : nm,
                                          codexSlug: slugFrom(metaRaw),
                                          codexMetaJSON: meta.isEmpty ? nil : meta)
            var flags: [String: Bool] = [:]
            for api in [ModelAPI.messages, .responses, .completions] {
                flags[api.rawValue] = manual[v.id]?[api] ?? true
            }
            var probe = state.entryProbe[entry.id] ?? [:]
            for (k, val) in flags { probe[k] = val }
            state.entryProbe[entry.id] = probe
            touched.insert(entry.id)
        }
        persistTouched()
        setHint("已应用手动设置（不产生消耗）。", bad: false)
    }

    /// 把 touched 条目的内存检测结论合并落盘，并标记 tested = true
    private func persistTouched() {
        let iso = ISO8601DateFormatter().string(from: Date())
        for id in touched {
            guard let i = state.config.models.firstIndex(where: { $0.id == id }) else { continue }
            var merged = state.config.models[i].probeResults ?? [:]
            for (k, val) in (state.entryProbe[id] ?? [:]) { merged[k] = val }
            state.config.models[i].probeResults = merged
            state.config.models[i].probedAt = iso
            state.config.models[i].tested = true
        }
        state.persist()
    }

    // ── 检测 ──
    /// 该 API 线是否可探测：端点已配置且供应商 URL 检查未失败（URLSupport == false 直接跳过）
    private func endpointOpen(_ v: Vendor, _ api: ModelAPI) -> Bool {
        if api == .messages {
            return v.anthropicBase != nil && v.anthropicURLSupport != false
        }
        return v.openaiBase != nil && v.openaiURLSupport != false
    }

    private func requestDetection() {
        if let e = modelIDError { setHint(e, bad: true); return }
        guard !modelID.trimmingCharacters(in: .whitespaces).isEmpty else { setHint("请填写模型 ID。", bad: true); return }
        let targets = detectionTargets
        guard !targets.isEmpty else { setHint("请先在供应商管理添加供应商。", bad: true); return }
        // 网络预检异步化（T3/I28）：不再阻塞主线程，结论回来后再进确认/执行流。
        NetCheck.isOnlineAsync { online in
            guard online else { setHint("网络未连接，无法探测。", bad: true); return }
            pendingTargets = targets
            if suppressConfirm {
                runDetection(targets)
            } else {
                confirming = true
            }
        }
    }

    private func runDetection(_ targets: [Vendor]) {
        hint = ""; hintBad = false
        showResults = true
        let mid = modelID.trimmingCharacters(in: .whitespaces)
        let nm = name.trimmingCharacters(in: .whitespaces)
        var jobs: [(Vendor, ModelAPI)] = []
        for v in targets {
            if endpointOpen(v, .messages) { jobs.append((v, .messages)) }
            if endpointOpen(v, .responses) { jobs.append((v, .responses)) }
            if endpointOpen(v, .completions) { jobs.append((v, .completions)) }
        }
        guard !jobs.isEmpty else { setHint("所选供应商没有可探测的端点。", bad: true); return }
        for (v, api) in jobs {
            outcomes[outcomeKey(v, api)] = .running
        }
        var finished = 0
        for (v, api) in jobs {
            DispatchQueue.global().async {
                let (ph, detail) = Self.checkEndpoint(v, api, mid)
                DispatchQueue.main.async {
                    self.outcomes[self.outcomeKey(v, api)] = ph
                    self.outcomeDetails[self.outcomeKey(v, api)] = detail
                    self.recordOutcome(vendor: v, api: api, modelID: mid, name: nm, passed: ph.passed)
                    if ph.passed { self.checked[v.id] = true }
                    finished += 1
                    if finished == jobs.count {
                        self.finishDetection(jobs: jobs, mid: mid, nm: nm, targets: targets)
                    }
                }
            }
        }
    }

    private func finishDetection(jobs: [(Vendor, ModelAPI)], mid: String, nm: String, targets: [Vendor]) {
        // 迟到的失败结论补账：条目建出来后，把本轮所有线的最终结论（含先于建条目到达的失败）合并进去
        for (v, api) in jobs {
            guard let ph = outcomes[outcomeKey(v, api)], ph != .running,
                  let e = state.config.models.first(where: { $0.modelID == mid && $0.vendorID == v.id }) else { continue }
            var probe = state.entryProbe[e.id] ?? [:]
            probe[api.rawValue] = ph.passed
            state.entryProbe[e.id] = probe
            touched.insert(e.id)
        }
        // 检测结论统一落盘 + tested = true（只 persist 一次）
        let iso = ISO8601DateFormatter().string(from: Date())
        for id in touched {
            guard let i = state.config.models.firstIndex(where: { $0.id == id }) else { continue }
            var merged = state.config.models[i].probeResults ?? [:]
            for (k, val) in (state.entryProbe[id] ?? [:]) { merged[k] = val }
            state.config.models[i].probeResults = merged
            state.config.models[i].probedAt = iso
            state.config.models[i].tested = true
        }
        state.persist()
        let okVendors = Set(state.config.models
            .filter { $0.modelID == mid && (state.routable($0, .messages) || state.routable($0, .responses) || state.routable($0, .completions)) }
            .map { $0.vendorID }).intersection(Set(targets.map { $0.id }))
        var foot = "「\(nm.isEmpty ? mid : nm)」\(okVendors.count) 家供应商可接入"
        if targets.contains(where: { $0.openaiBase != nil && !metaConfigured }) {
            foot += " · 未配官方元数据的应用自动最小条目（slug=模型名称）"
        }
        resultFoot = foot
    }

    /// 单条检测结论入库（内存）：通过且未入库则建条目；结论写 entryProbe，落盘统一在收尾做
    /// （I5：条目写入走 state.upsertEntry——已存在者禁改非空名称，新建者带名）
    private func recordOutcome(vendor: Vendor, api: ModelAPI, modelID mid: String, name nm: String, passed: Bool) {
        if passed {
            let meta = metaRaw.trimmingCharacters(in: .whitespaces)
            _ = state.upsertEntry(modelID: mid, vendorID: vendor.id,
                                  displayName: nm.isEmpty ? nil : nm,
                                  codexSlug: slugFrom(metaRaw),
                                  codexMetaJSON: meta.isEmpty ? nil : meta)
        }
        guard let e = state.config.models.first(where: { $0.modelID == mid && $0.vendorID == vendor.id }) else { return }
        var probe = state.entryProbe[e.id] ?? [:]
        probe[api.rawValue] = passed
        state.entryProbe[e.id] = probe
        touched.insert(e.id)
    }

    /// ID 菜单选中后：勾选切到该 ID 的供应商集合，元数据跟随（不动名称——名称是选择器的输入条件）
    private func syncCluster(_ id: String) {
        checked = [:]
        for e in state.config.models where e.modelID == id { checked[e.vendorID] = true }
        // S2/R10④：编辑模式换选 ID 后，基线（编辑目标 ID）条目仍保持勾选（保存永不删除基线）
        if !loadedID.isEmpty {
            for e in state.config.models where e.modelID == loadedID { checked[e.vendorID] = true }
        }
        if let meta = state.config.models.first(where: { $0.modelID == id && !($0.codexMetaJSON ?? "").isEmpty })?.codexMetaJSON {
            metaRaw = meta
        }
    }

    // ── 保存（不产生消耗；I5：同名多 ID 全保留、永不覆盖；S2/R10④ 增删分离：勾选只新增，删除只走条目行垃圾桶）──
    private func save() {
        if let e = modelIDError { setHint(e, bad: true); return }
        guard !modelID.trimmingCharacters(in: .whitespaces).isEmpty else { setHint("请填写模型 ID。", bad: true); return }
        guard !checkedVendors.isEmpty else { setHint("请至少勾选一个供应商。", bad: true); return }
        guard let req = saveRequest else { setHint("请检查填写内容后重试。", bad: true); return }   // 防御分支：上方校验已覆盖 saveRequest 的全部 nil 条件
        let plan = ModelLibraryRules.planSave(state.config, req)
        if !plan.deletions.isEmpty {
            // S2/R10④：保存永不删除——正常流程基线供应商锁定勾选，不会产生删除；
            // 触达此处＝状态异常（如基线条目被并发改动），阻止保存并引导走条目行垃圾桶
            setHint("保存不删除条目（已阻止 \(plan.deletions.count) 条基线变动）。删除请用条目行的垃圾桶。", bad: true)
            return
        }
        performSave(req)
    }

    private func performSave(_ req: ModelLibraryRules.SaveRequest) {
        let report = state.applyModelSave(req)
        var parts: [String] = []
        let created = report.upserts.filter(\.created).count
        let updated = report.upserts.count - created
        if created > 0 { parts.append("新增 \(created) 条") }
        if updated > 0 { parts.append("更新 \(updated) 条") }
        if !report.swapUpdates.isEmpty { parts.append("改写 ID \(report.swapUpdates.count) 条") }
        let locked = report.swapUpdates.reduce(0) { $0 + $1.skippedLockedSlots.count }
        if locked > 0 { parts.append("（\(locked) 个锁定模型位保留旧 ID）") }
        state.toast = parts.isEmpty ? "已保存" : "已保存（\(parts.joined(separator: "，"))）"
        state.toastDetail = report.conflicts.isEmpty ? "" : "跳过冲突 \(report.conflicts.count) 条（见保存前提示）"
        state.flashToast()
        dismiss()
    }

    // ── 检测执行（真实 API 请求：Anthropic Messages / OpenAI Responses / OpenAI Chat Completions Check；
    //    static：供应商管理页的供应商级真实测试（S2/R10③）复用同一判定）──
    static func checkEndpoint(_ v: Vendor, _ api: ModelAPI, _ mid: String) -> (ProbePhase, String) {
        let key = KeychainStore.get(v.keyRef, domain: .vendor) ?? ""
        guard !key.isEmpty else { return (.noKey, "供应商未配置 Key，未发请求") }
        let base = api == .messages ? v.anthropicBase! : v.openaiBase!
        let report: APICheckReport
        switch api {
        case .messages:    report = AnthropicMessagesAPICheck.check(base: base, key: key, modelID: mid)
        case .responses:   report = OpenAIResponsesAPICheck.check(base: base, key: key, modelID: mid)
        case .completions: report = OpenAIChatCompletionsAPICheck.check(base: base, key: key, modelID: mid)
        }
        return (Self.phase(of: report), report.detail)
    }

    static func phase(of r: APICheckReport) -> ProbePhase {
        switch r.verdict {
        case .ok:               return .ok
        case .emptyKey:         return .noKey
        case .authFail:         return .authFail
        case .modelNotFound:    return .modelNotFound
        case .pathNotSupported: return .pathNotSupported
        case .protocolMismatch: return .protocolMismatch
        case .rateLimited:      return .rateLimited
        case .upstreamError, .badRequest: return .bad(r.httpStatus ?? 0)
        case .unreachable:      return .unreachable
        }
    }

    // ── 探测结果展示 ──
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(detectionTargets) { v in
                if hasOutcome(v) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(v.name).font(f(11.5, .semibold)).foregroundStyle(ink2)
                        VStack(spacing: 0) {
                            resultRow(v, .messages)
                            resultRow(v, .responses)
                            resultRow(v, .completions)
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1)))
                    }
                }
            }
            Text(resultFoot).font(f(11.5)).foregroundStyle(ink2)
        }
    }

    @ViewBuilder
    private func resultRow(_ v: Vendor, _ api: ModelAPI) -> some View {
        let key = outcomeKey(v, api)
        if endpointOpen(v, api) {
            let phase = outcomes[key] ?? .running
            HStack(alignment: .top, spacing: 9) {
                phaseIcon(phase)
                    .frame(width: 13).padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    ModelAPIBadge(api: api)
                    Text(phase.label).font(f(11)).foregroundStyle(phase.passed ? Color(red: 0.10, green: 0.50, blue: 0.22) : ink2).padding(.top, 2)
                    if let d = outcomeDetails[key], !d.isEmpty {
                        Text(d).font(mono(10.5)).foregroundStyle(ink3)
                            .lineLimit(4).textSelection(.enabled)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .overlay(Rectangle().fill(sep).frame(height: 1), alignment: .bottom)
        }
    }

    @ViewBuilder
    private func phaseIcon(_ phase: ProbePhase) -> some View {
        switch phase {
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(ink3)
        case .ok:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(okColor)
        default:
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(errColor)
        }
    }

    private func outcomeKey(_ v: Vendor, _ p: ModelAPI) -> String {
        let tag: String
        switch p {
        case .messages:    tag = "m"
        case .responses:   tag = "r"
        case .completions: tag = "c"
        }
        return "\(v.id.uuidString)|\(tag)"
    }
    private func hasOutcome(_ v: Vendor) -> Bool {
        outcomes.keys.contains { $0.hasPrefix(v.id.uuidString + "|") }
    }

    /// 从元数据 JSON 里取 slug（容错解析）
    private func slugFrom(_ raw: String) -> String? {
        CodexMetaNorm.slug(of: raw)
    }

    private func setHint(_ t: String, bad: Bool) {
        hint = t
        hintBad = bad
    }

    /// 元数据编辑在独立窗口进行（R8：统一名称级 C 窗；slug/显示名随模型名称接管）
    private func presentMetaEditor() {
        let key = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? modelID.trimmingCharacters(in: .whitespaces)
            : name.trimmingCharacters(in: .whitespaces)
        let initial = state.config.models.first(where: { $0.groupKey == key })?.codexMetaJSON ?? ""
        FloatWindowCenter.shared.present(title: "元数据配置 · \(key)", size: NSSize(width: 820, height: 745),
                                         reuseKey: "meta:\(key)") { w in
            CodexMetadataWindow(groupKey: key, initial: initial, onClose: { w.close() })
                .environmentObject(state)   // 独立窗是全新环境：补注入，防后续加 @EnvironmentObject 即崩
        }
    }
}

// MARK: - 真实消费二次确认（可取消转手动设置；可不再提示）
struct DetectionConfirmSheet: View {
    let vendorCount: Int
    let endpointCount: Int
    @Binding var suppress: Bool
    let onManual: () -> Void
    let onConfirm: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("真实请求检测确认").font(f(14.5, .semibold))
            Text("将对 \(vendorCount) 家供应商的 \(endpointCount) 个端点各发一次最小真实请求，**产生真实消费**（单端点 ≤50 Token，以供应商计费为准）。返回真实 Token 才判定可用。")
                .font(f(12.5)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            Toggle("不再提示（此后点击探测直接执行）", isOn: $suppress)
                .toggleStyle(.checkbox).font(f(12))
            HStack {
                Button("手动选择支持的API") {
                    dismiss()
                    onManual()
                }.cardBtn()
                Spacer()
                Button("取消") { dismiss() }.cardBtn()
                Button("确认并继续") {
                    dismiss()
                    onConfirm()
                }.cardBtn(primary: true)
            }
        }
        .padding(20).frame(width: 470)
    }
}

// MARK: - 组级元数据配置窗（组头 ⋯ 菜单第二入口）：对名称下全部 ID 生效，直接落盘（不经模型编辑窗保存）
// R8 起由 CodexMetadataWindow（C 窗）承担：slug/显示名随模型名称、基础参数＋高级模式＋参数字典覆盖层。
