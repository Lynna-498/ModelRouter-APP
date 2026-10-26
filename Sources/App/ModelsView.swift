import SwiftUI
import ModelRouterCore

// MARK: - 模型管理（三层折叠卡片：名称 → 模型 ID → 供应商；徽标仅第三层·按条目）
// 分组键 = 模型名称（显示名，即条目自身 groupKey）；无显示名的条目以模型 ID 充当组名（等宽）。
// 徽标三态（纯色）：亮=检测通过；灰=不可用；黄=未检测。
struct ModelsView: View {
    @EnvironmentObject var state: AppState
    @State private var editTarget: ModelSheet.EditTarget? = nil
    @State private var showAdd = false
    @State private var confirm: ConfirmRequest? = nil
    @State private var defaultEditorGroup: ModelGroup? = nil
    @State private var renameGroupTarget: ModelGroup? = nil

    /// 删除单条目（第三层删除按钮，页面级二次确认）
    private func askDelete(_ e: ModelEntry) {
        let used = state.harnessUsage(modelID: e.modelID, vendorID: e.vendorID)
        let name = state.config.vendors.first(where: { $0.id == e.vendorID })?.name ?? "—"
        let msg = used.isEmpty
            ? "确定删除 **\(e.displayLabel)** `\(e.modelID)` @ \(name)？"
            : "\(used.map { "**\($0)**" }.joined(separator: "、")) 正在映射到该模型，删除后未锁定的映射回到未映射（锁定行保留）。"
        confirm = ConfirmRequest(title: "删除模型", message: msg) {
            state.deleteEntries([e.id])
        }
    }

    /// 删除整个名称组（组头 ⋯，页面级二次确认；一次批量、一次落盘）
    private func askDeleteGroup(_ g: ModelGroup) {
        let entries = g.sections.flatMap { $0.entries }
        let msg = "删除组 **\(g.title)**（\(g.idCount) 个模型 ID）共 \(entries.count) 条供应商条目？引用它们的映射回到未映射（锁定行保留）。"
        confirm = ConfirmRequest(title: "删除模型组", message: msg) {
            state.deleteEntries(entries.map(\.id))
        }
    }

    private var groups: [ModelGroup] {
        ModelGroup.groups(from: state.config.models)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ViewHeader(title: "模型管理",
                           tip: "同名模型自动归为一组，三层：名称 → 模型 ID → 供应商。一个模型 ID 可由多家供应商通用；徽标只看颜色：亮=检测通过，灰=不可用，黄=未检测（悬停看原因）。操作在供应商条目行。",
                           note: groups.isEmpty ? "" : "\(groups.count) 组 · \(state.config.models.count) 条")
                Button("＋ 添加模型") { showAdd = true }.cardBtn(primary: true)
            }
            .padding(.bottom, 14)

            if state.config.models.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 24)).foregroundStyle(ink3)
                    Text("模型库还是空的").font(f(12.5)).foregroundStyle(ink2)
                    Button("＋ 添加模型") { showAdd = true }.cardBtn(primary: true)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1)))
            } else {
                VStack(alignment: .leading, spacing: 12) {   // 卡片间距统一 12
                    ForEach(groups) { g in
                        GroupCard(group: g,
                                  onRenameGroup: { renameGroupTarget = g },
                                  onEditSection: { section in
                                      editTarget = ModelSheet.EditTarget(groupTitle: g.title,
                                                                         modelID: section.modelID,
                                                                         anchor: section.entries[0])
                                  },
                                  onDefaults: { defaultEditorGroup = g },
                                  onDeleteGroup: { askDeleteGroup(g) },
                                  onDeleteEntry: { askDelete($0) })
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) { ModelSheet(mode: .add) }
        .sheet(item: $editTarget) { t in ModelSheet(mode: .edit(t)) }
        .sheet(item: $confirm) { req in ConfirmSheet(request: req) }
        .sheet(item: $defaultEditorGroup) { g in DefaultSourcesSheet(group: g) }
        .sheet(item: $renameGroupTarget) { g in GroupRenameSheet(group: g) }
    }
}

// MARK: - 分组数据（名称 → 模型 ID → 条目）
struct ModelGroup: Identifiable {
    let title: String
    let isNameless: Bool
    let sections: [ModelGroupSection]
    var id: String { title }
    var idCount: Int { sections.count }                                   // 模型 ID 数
    var entryCount: Int { sections.reduce(0) { $0 + $1.entries.count } }  // 供应商条目数

    /// 名称分组（模型管理页与「复制通用 ID」独立窗共用；组顺序＝条目首现顺序）
    static func groups(from models: [ModelEntry]) -> [ModelGroup] {
        var order: [String] = []
        var byTitle: [String: [ModelEntry]] = [:]
        for m in models {
            let key = m.groupKey
            if byTitle[key] == nil { order.append(key) }
            byTitle[key, default: []].append(m)
        }
        return order.map { title in
            let entries = byTitle[title]!
            let isNameless = !entries.contains { $0.displayName?.isEmpty == false }
            var idOrder: [String] = []
            var byID: [String: [ModelEntry]] = [:]
            for e in entries {
                if byID[e.modelID] == nil { idOrder.append(e.modelID) }
                byID[e.modelID, default: []].append(e)
            }
            let sections = idOrder.map { ModelGroupSection(modelID: $0, entries: byID[$0]!) }
            return ModelGroup(title: title, isNameless: isNameless, sections: sections)
        }
    }
}
struct ModelGroupSection: Identifiable {   // 第二层：模型 ID（一个 ID 可多供应商通用；组内唯一）
    let modelID: String
    let entries: [ModelEntry]
    var id: String { modelID }
}

// MARK: - 第一层：模型名称组（组头：名称+计数 / 默认来源灯牌×3 / 默认来源按钮 / ⋯）
private struct GroupCard: View {
    @EnvironmentObject var state: AppState
    /// 名称列宽（修订2：170→190）。验算（真机卡宽 720、内宽 692）：
    /// 190 + 3×112 灯牌 + 66.5 默认来源钮 + 30 ⋯ + 6×10 间距 + Spacer 9.5 ≈ 692；依赖 ContentView 的 maxWidth:720，上限变更需重算
    private static let nameCol: CGFloat = 190
    let group: ModelGroup
    let onRenameGroup: () -> Void
    let onEditSection: (ModelGroupSection) -> Void
    let onDefaults: () -> Void
    let onDeleteGroup: () -> Void
    let onDeleteEntry: (ModelEntry) -> Void
    @State private var open = false

    /// R9 组级「无元数据」判据：组内全部条目（所有 ID 的所有供应商条目）均未配 codexMetaJSON；
    /// 任一条目携带 → 不显示。纯元数据存在性，不掺 Responses 线可用性（原 rOK 条件不迁移）。
    private var allNoMeta: Bool {
        group.sections.allSatisfy { $0.entries.allSatisfy { $0.codexMetaJSON == nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { open.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(ink3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title)
                                .font(group.isNameless ? mono(12.5, .semibold) : f(13.5, .bold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 6) {
                                Text("\(group.idCount) 个模型 ID · \(group.entryCount) 条")
                                    .font(f(11)).foregroundStyle(ink3).lineLimit(1)
                                // R9：组级「无元数据」提示（原三级行角标上移组头）；判据＝全组条目均无 codexMetaJSON
                                if allNoMeta {
                                    Text("·  无元数据").font(f(10)).foregroundStyle(ink3).lineLimit(1)
                                        .help("该名称未配官方 Codex 元数据；生成 model_modelrouter.json 时将按模型名称自动生成最小条目（slug=display_name=名称）")
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: Self.nameCol, alignment: .leading)   // 名称列定宽：灯牌跨卡对齐
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 默认来源灯牌（D2）：亮=该线已设/灭=未设；固定槽位跨卡对齐；亮态牌内复制该线通用 ID
                ForEach([ModelAPI.messages, .responses, .completions], id: \.rawValue) { api in
                    DefaultSourceBadge(api: api,
                                       lit: state.defaults(for: group.title)[api.rawValue] != nil,
                                       onCopy: { copyDefaultSource(api) })
                        .frame(width: 112, alignment: .leading)   // F2：槽宽收窄，跨卡对齐不变
                }
                Spacer()
                Button("默认来源", action: onDefaults)
                    .cardBtn(mini: true)
                    .fixedSize()   // F3：防 HStack 空间不足时标签被压成空框
                    .help("查看该名称下各供应商的三线检测结论，并按线独立设置默认来源")
                Menu {
                    Button("元数据配置…") { openMetaWindow() }
                    Button("重命名该组…") { onRenameGroup() }
                    Button("删除该组…", role: .destructive) { onDeleteGroup() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(ink2)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)

            if open {
                ForEach(group.sections) { section in
                    IDSection(groupTitle: group.title,
                              section: section,
                              onEdit: { onEditSection(section) },
                              onDeleteEntry: onDeleteEntry)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1))
    }

    private func copyDefaultSource(_ api: ModelAPI) {
        if let id = state.defaultSourceUniversalID(groupKey: group.title, api: api) {
            state.copy(id)
        }
    }

    /// 「元数据配置」第二入口（组头 ⋯ 菜单）：元数据对名称下全部 ID 生效（不分 ID），
    /// 装载组内首个非空元数据；R8 起开 C 窗（slug/显示名随模型名称，基础参数＋高级模式）
    private func openMetaWindow() {
        let initial = group.sections.flatMap(\.entries)
            .first(where: { !($0.codexMetaJSON ?? "").isEmpty })?
            .codexMetaJSON ?? ""
        FloatWindowCenter.shared.present(title: "元数据配置 · \(group.title)", size: NSSize(width: 820, height: 745),
                                         reuseKey: "meta:\(group.title)") { w in
            CodexMetadataWindow(groupKey: group.title, initial: initial, onClose: { w.close() })
                .environmentObject(state)   // 独立窗全新环境：手动注入
        }
    }
}

// MARK: - 第二层：模型 ID 行（整行点击展开/折叠该 ID 的供应商 / 铅笔编辑接入供应商）
private struct IDSection: View {
    let groupTitle: String
    let section: ModelGroupSection
    let onEdit: () -> Void
    let onDeleteEntry: (ModelEntry) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { open.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(ink3)
                            .frame(width: 14, height: 14)
                        Text(section.modelID).font(mono(12.5, .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("\(section.entries.count) 家供应商").font(f(11)).foregroundStyle(ink3)
                    }
                    .contentShape(Rectangle())   // 修订2：整行命中（含 Spacer 区），照抄组头做法
                }
                .buttonStyle(.plain)
                .help("点击展开/折叠该模型 ID 下的供应商条目")
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil").font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ink2)
                .help("编辑该模型 ID 的接入供应商（勾选＝新增接入；已保存的锁定不可取消，删除用条目行垃圾桶）")
            }
            .padding(.leading, 38).padding(.trailing, 14).padding(.vertical, 9)

            if open {
                VStack(spacing: 0) {
                    ForEach(section.entries) { e in
                        VendorEntryRow(groupTitle: groupTitle, entry: e, onDelete: { onDeleteEntry(e) })
                    }
                }
                .background(Color(NSColor.quaternaryLabelColor).opacity(0.10))
            }
        }
        .overlay(Rectangle().fill(sep).frame(height: 1), alignment: .top)
    }
}

// MARK: - 默认来源编辑器（三线独立：查看各供应商三线检测结论 + 按线设置默认来源）
private struct VendorEntryRow: View {
    @EnvironmentObject var state: AppState
    let groupTitle: String
    let entry: ModelEntry
    let onDelete: () -> Void
    @State private var copyHover = false
    @State private var trashHover = false
    @State private var ecgHover = false
    // S2/R10③：条目级真实测试（心电图键，复制键与删除键之间）的确认弹窗状态
    @State private var realConfirm = false
    @AppStorage("mr.probe.suppressEntryRealConfirm") private var realSuppress = false

    /// 本供应商是否为该名称组某线的默认来源（徽标绿点角标；I5 布局：替代行内「默认·X」绿标）
    private func isDefault(_ api: ModelAPI) -> Bool {
        state.config.defaultSourcesByAPI[groupTitle]?[api.rawValue] == entry.vendorID
    }

    var body: some View {
        let mOK = state.availability(entry, .messages)
        let rOK = state.availability(entry, .responses)
        let cOK = state.availability(entry, .completions)
        let vName = state.config.vendors.first(where: { $0.id == entry.vendorID })?.name ?? "—"
        return HStack(spacing: 10) {
            Text(vName).font(f(12.5, .semibold)).lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)   // I5 布局：名称优先保宽；全拼其次（限宽+中截，空间不足时先行退让）
            Text(PinYinLabel.label(for: vName)).font(mono(10.5)).foregroundStyle(ink3)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 110, alignment: .leading)
                .help("通用 ID 前缀（全拼）：\(PinYinLabel.label(for: vName))")
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ModelAPIBadge(api: .messages, avail: mOK, isDefault: isDefault(.messages), dotSlot: true)
                ModelAPIBadge(api: .responses, avail: rOK, isDefault: isDefault(.responses), dotSlot: true)
                ModelAPIBadge(api: .completions, avail: cOK, isDefault: isDefault(.completions), dotSlot: true)
            }
            // R4（设计稿 2026-09-17 确认，按设计器默认参数移植）：每行「复制该来源通用 ID」扁平键＋红色垃圾桶删除；
            // S2/R10③（2026-10-01 更正落位）：两键之间加心电图键＝该条目真实请求连通性测试（产生真实消费）
            HStack(spacing: 8) {
                let uid = state.universalID(entry)
                let realRunning = state.entryRealProbe[entry.id] == true
                Button {
                    state.copy(uid)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(copyHover ? accent.opacity(0.15) : Color.clear))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copyHover ? accent : ink3)
                .onHover { copyHover = $0 }
                .help("复制该来源通用 ID（\(uid)）")
                Button {
                    if realSuppress {
                        state.probeEntryReal(entry)
                    } else {
                        realConfirm = true
                    }
                } label: {
                    Image(systemName: realRunning ? "arrow.triangle.2.circlepath" : "waveform.path.ecg")
                        .font(.system(size: 12.5))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(ecgHover ? accent.opacity(0.15) : Color.clear))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ecgHover ? accent : ink3)
                .onHover { ecgHover = $0 }
                .disabled(realRunning)
                .help("真实请求连通性测试：对该条目的开放线各发一次最小真实请求并判定可用——产生真实消费（点击先确认）。判负即停止转发与下放，复测通过自动恢复")
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 13))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(trashHover ? errColor.opacity(0.15) : Color.clear))
                }
                .buttonStyle(.plain)
                .foregroundStyle(errColor)
                .onHover { trashHover = $0 }
                .help("删除该模型条目（二次确认）")
            }
        }
        .padding(.leading, 62).padding(.trailing, 14).padding(.vertical, 8)
        .sheet(isPresented: $realConfirm) {
            DetectionConfirmSheet(vendorCount: 1,
                                  endpointCount: state.entryRealProbeJobCount(entry),
                                  suppress: $realSuppress,
                                  onManual: {
                                      state.toast = "手动设置 API 支持在模型编辑窗进行（不产生消耗）"
                                      state.flashToast()
                                  },
                                  onConfirm: { state.probeEntryReal(entry) })
        }
    }
}

// MARK: - 模型统一编辑窗（添加与编辑同一张卡：ID/名称/元数据/供应商勾选/手动 API/真实检测）
