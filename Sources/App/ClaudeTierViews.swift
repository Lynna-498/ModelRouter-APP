// MARK: - Claude 档位注册窗与档位行（自 RoutesView 拆分·T9/I34，纯移动）
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ModelRouterCore

struct ClaudeTierRegisterSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    let harnessID: UUID
    /// R16① 更新模式：被替换的当前档位 ID（nil＝普通注册）
    var replacingField: String? = nil
    @State private var position: String = K.claudeCustomPositions[1]   // 默认 -fable
    @State private var suffix = ""
    @State private var err = ""
    @State private var presetID: String? = nil   // R16③：官方预设 ID 直选（选中自动填定位＋后缀）

    /// 官方预设 ID 全集（分组顺序：现有→Haiku→专用→旧版；Haiku 仅供官方 ID 直选，不进自定义定位）
    /// 预设下拉项（查重感知＋扁平无分组）：已在该卡使用的 ID 不再出现在可选列表——
    /// 「一个 ID 已被使用就不允许被添加」（后端 registerClaudeTier 查重保留为兜底）；标签＝写死显示名
    static func offeredPresets(usedIDs: Set<String>) -> [(String, String)] {
        K.anthropicOfferable
            .filter { !usedIDs.contains($0) }
            .map { ($0, Router.claudeDisplayName($0)) }
    }

    private var usedSlotIDs: Set<String> {
        Set(state.config.harnesses.first(where: { $0.id == harnessID })?.slots.map(\.clientModelField) ?? [])
    }

    /// 后缀归一：缺前导 - 自动补；仅 ASCII、非空、无空格
    private var part: String {
        let t = suffix.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("-") ? t : (t.isEmpty ? "" : "-" + t)
    }
    private var previewID: String { "claude" + position + part }
    private var partOK: Bool { part.count > 1 && part.allSatisfy({ $0.isASCII && !$0.isWhitespace }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(replacingField != nil ? "更新模型 ID" : "注册 Claude 兼容模型位").font(f(14.5, .semibold))
                HelpTip(tip: "ID 由三段组成：claude + 定位 + 自定义后缀（推荐 \(K.claudeSuffixExample) 形式）。注册后立即进入映射表与档序；完成映射后才会出现在模型发现入口。数量不限。")
            }
            if let rf = replacingField {
                HStack(spacing: 8) {
                    Text("当前 ID").font(f(11)).foregroundStyle(ink3).frame(width: 96, alignment: .trailing)
                    MonoBox(text: rf)
                }
                .padding(.horizontal, 2)
            }
            SheetField(label: { fieldLabel("官方 ID") }) {
                NativeMenuPicker<String>(
                    items: [(nil, "— 自定义 —")]
                        + Self.offeredPresets(usedIDs: usedSlotIDs).map { (Optional($0.0), $0.1) },
                    selection: $presetID
                )
                .frame(width: 300, alignment: .leading)
            }
            .onChange(of: presetID) { _, newValue in
                guard let id = newValue,
                      let d = Router.claudeDecompose(id) else { return }
                position = d.position
                suffix = d.suffix
            }
            SheetField(label: { fieldLabel("定位") }) {
                Picker("", selection: $position) {
                    ForEach(K.claudeCustomPositions, id: \.self) { p in Text(p).tag(p) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                .frame(width: 140, alignment: .leading)
                .disabled(presetID != nil)   // 预设锁定：选中官方 ID 后定位/后缀不可改，切回「— 自定义 —」解锁
            }
            SheetField(label: { fieldLabel("自定义后缀") }) {
                InpField(placeholder: K.claudeSuffixExample, monoStyle: true, text: $suffix, bad: err != "")
                    .frame(maxWidth: 220)
                    .disabled(presetID != nil)
            }
            .onChange(of: suffix) { _, new in
                let ascii = new.filter { $0.isASCII }   // 仅兼容 ASCII 字符输入
                if ascii != new { suffix = ascii }
            }
            HintLine(text: err, bad: true)
            HStack(spacing: 8) {
                Text(replacingField != nil ? "新 ID" : "注册 ID").font(f(11)).foregroundStyle(ink3).frame(width: 96, alignment: .trailing)
                MonoBox(text: previewID)
            }
            if partOK && !Router.isSupportedClaudeID(previewID) {
                Text("非官方 ID 格式，可能存在兼容性问题").font(f(10.5)).foregroundStyle(warnColor)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack {
                Button("取消") { dismiss() }.cardBtn()
                Spacer()
                Button(replacingField != nil ? "确认更新" : "注册") { register() }
                    .cardBtn(primary: true)
                    .disabled(!partOK)
            }
            .padding(.top, 6)
        }
        .padding(24).frame(width: 520)
    }

    private func register() {
        if let rf = replacingField {
            // R16① 更新通道：保留映射与锁定态，仅替换档位键
            guard state.renameSlot(harnessID: harnessID, from: rf, to: previewID) else {
                err = "新 ID 已存在，或后缀非法（仅 ASCII、非空、无空格）"
                return
            }
            dismiss()
            return
        }
        guard let id = state.registerClaudeTier(harnessID: harnessID, position: position, suffix: suffix) else {
            err = "该 ID 已存在，或后缀非法（仅 ASCII、非空、无空格）"
            return
        }
        state.toast = "已注册模型位 \(id)"
        state.toastDetail = "回到档位行完成映射后，才会进入模型发现入口"
        state.flashToast()
        dismiss()
    }
}

// MARK: - 档位行（模型位 | 请求的模型 | 供应商 | 状态）
struct TierRow: View {
    @EnvironmentObject var state: AppState
    let harness: Harness
    let slot: Slot
    let index: Int
    var onUpdateID: (() -> Void)? = nil   // R28：Claude 行常驻「更新ID信息」入口（nil＝非 Claude 行）

    private var isClaude: Bool { harness.tierOrder != nil }

    var body: some View {
        let api: ModelAPI = harness.proto == .anthropic ? .messages : .responses
        let invalid = state.slotInvalid(slot, api)
        let bound = slot.isMapped
        let slotName = state.slotGroupName(slot)   // 名称级选择单元（修订3：一个名称一个选项）
        let idNeedsUpdate = isClaude && state.isDeprecatedSlot(harness, slot)

        // 模型下拉：可用名称池 + 当前失效项（带「不可用」后缀）
        let modelOptions: [(String, String)] = {
            var opts = state.modelPool(api).map { ($0, $0) }
            if let name = slotName, !opts.contains(where: { $0.0 == name }) {
                opts.insert((name, name + "（不可用）"), at: 0)
            }
            return opts
        }()
        // 供应商下拉：该名称下全部可用供应商 + 当前不在池项（带「不可用」后缀）
        let vendorOptions: [Vendor] = {
            var pool = state.vendorPool(groupName: slotName, api)
            if let vid = slot.vendorID, !pool.contains(where: { $0.id == vid }),
               let v = state.config.vendors.first(where: { $0.id == vid }) {
                pool.insert(v, at: 0)
            }
            return pool
        }()

        return GridRow {
            // 第一列：档名 + 原生 ID / 转发键
            cell(invalid) {
                // R16①：单名字显示（固化命中→写死名；未命中→档位名），不再显示完整 ID 小字
                Text(isClaude ? Router.claudeDisplayName(slot.clientModelField) : slot.clientModelField)
                    .font(f(12.5, .semibold))
                    .frame(width: 88, alignment: .leading)
            }

            // 请求的模型（锁定行不可选；弹性列宽，逐行等宽）
            cell(invalid) {
                NativeMenuPicker<String>(
                    items: [(nil, "— 未映射 —")]
                        + modelOptions.map { (Optional($0.0), $0.1) },
                    selection: Binding(
                        get: { state.slotGroupName(slot) },
                        set: { state.setSlotModel(harnessID: harness.id, field: slot.clientModelField, groupName: $0) }
                    )
                )
                .disabled(slot.locked == true)
                .frame(width: 160, alignment: .leading)   // ≥最长选项理想宽，防 NSPopUpButton 溢出画框（F1 复修）
            }

            // 供应商（固定 200，逐行等宽）
            cell(invalid) {
                NativeMenuPicker<UUID>(
                    items: [(nil, slotName != nil ? "选择供应商" : "先选一侧")]
                        + vendorOptions.map { (Optional($0.id),
                                               $0.id == slot.vendorID && invalid ? $0.name + "（不可用）" : $0.name) },
                    selection: Binding(
                        get: { slot.vendorID },
                        set: { state.setSlotVendor(harnessID: harness.id, field: slot.clientModelField, vendorID: $0) }
                    )
                )
                .frame(width: 180, alignment: .leading)   // ≥最长供应商名理想宽，防溢出画框
            }

            // 模型锁定（Claude 卡，仅单行生效）：顶格显示，开关前沿对齐表头；锁图标在开关右侧
            if isClaude {
                cell(invalid) {
                    HStack(spacing: 5) {
                        Toggle("", isOn: Binding(
                            get: { slot.locked == true },
                            set: { state.setSlotLocked(harnessID: harness.id, field: slot.clientModelField, $0) }
                        ))
                        .toggleStyle(.switch).controlSize(.mini)
                        Image(systemName: slot.locked == true ? "lock.fill" : "lock.open")
                            .font(.system(size: 11))
                            .foregroundStyle(slot.locked == true ? accent : ink3)
                    }
                    .frame(width: 50, alignment: .leading)
                    .help("模型锁定：锁定后本行「请求的模型」不可更改，供应商仍可更改")
                }
            }

            // 状态
            cell(invalid) {
                HStack(spacing: 6) {
                    if invalid {
                        Dot(color: warnColor, size: 8)
                        Text("映射已失效，请重选").font(f(11)).foregroundStyle(errColor)
                    } else if bound {
                        Dot(color: okColor, size: 8)
                        Text(isClaude ? "已映射" : "转发中").font(f(11)).foregroundStyle(ink2)
                    } else {
                        Dot(color: ink3, size: 8)
                        Text("未映射").font(f(11)).foregroundStyle(ink2)
                    }
                    if let onUpdateID = onUpdateID {
                        Button("更新ID信息", action: onUpdateID)
                            .font(f(10.5))
                            .foregroundStyle(idNeedsUpdate ? Color(nsColor: .systemRed) : accent)
                            .buttonStyle(.plain)
                            .help(idNeedsUpdate
                                  ? "该模型 ID 已被官方弃用；更新 ID 保留既有映射"
                                  : "更新该模型 ID；更新后保留既有映射与锁定状态")
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)   // 状态列弹性吃满卡宽（修 Codex 右侧空白）
                .lineLimit(1)
            }

            // 删除列：全部模型位可删（R16②/S8②：原生四档解锁——删除＝移出档序与模型发现，
            // 请求该 ID 走 noMapping 透明失败、降级链跳过；可经「添加模型位」官方预设重建）
            cell(invalid) {
                    Button {
                        state.removeSlot(harnessID: harness.id, field: slot.clientModelField)
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(ink2)
                    }
                    .buttonStyle(.plain)
                    .help("删除该模型位（同步移出档序与模型发现）")
                    .frame(width: 14)
            }
        }
    }

    /// 行内单元格：统一垂直 padding、失效底色与底部分隔线（逐格绘制，跨列视觉连续）
    @ViewBuilder
    private func cell<V: View>(_ invalid: Bool, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(height: 44)   // 统一行高：各列分隔线同高（原逐列内容高度不一致线错位）
            .background(invalid ? Color(nsColor: .systemRed).opacity(0.07) : Color.clear)
            .overlay(Rectangle().fill(sep.opacity(0.55)).frame(height: 1), alignment: .bottom)
    }
}

// MARK: - 访问配置面板（Base URL + 访问 Key，复制/显隐/重新生成）
