import SwiftUI
import ModelRouterCore

// MARK: - 复制通用 ID 独立窗（R5 追加，2026-09-26 定案）：简化版模型管理
// 三级布局与模型管理页一致（名称组 → 模型 ID → 供应商条目），但仅保留复制通用 ID 功能——
// 无铅笔编辑、垃圾桶删除、组头 ⋯ 菜单、默认来源按钮、无元数据提示（简化范围＝只留复制相关）。
// 入口＝菜单栏「复制通用 ID…」（MenuBarController.openUIDCopyWindow，660×540，单实例：已开则前置）。
// 窗名即标题（独立窗不重复页头标题，P7/P8 先例）；数据实时读 AppState，本窗只读、无任何写入路径。
struct UIDCopyView: View {
    @EnvironmentObject var state: AppState

    /// 本窗内部 toast：state.toast 呈现在主窗会被本窗遮挡，复制反馈走这里（CLIClientConfigView 先例）
    @State private var localToast = ""
    @State private var localToastGen = 0

    private var groups: [ModelGroup] { ModelGroup.groups(from: state.config.models) }

    var body: some View {
        Group {
            if groups.isEmpty {
                emptyCard
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {   // 卡片间距统一 12（与模型管理一致）
                        ForEach(groups) { g in
                            UIDCopyGroupCard(group: g, onCopy: copyUID)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(winBg)
        .overlay(alignment: .bottom) {
            if !localToast.isEmpty {
                ToastBar(text: localToast)
                    .padding(.bottom, 18)   // S7：底距职责归挂载点（组件内嵌 18pt 已移除）
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: localToast)
    }

    /// 空库提示（本窗只读，引导回主界面添加）
    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2").font(.system(size: 24)).foregroundStyle(ink3)
            Text("模型库还是空的").font(f(12.5)).foregroundStyle(ink2)
            Text("在主界面「模型管理」添加模型后，可在此复制通用 ID").font(f(11)).foregroundStyle(ink3)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1)))
        .padding(.horizontal, 16).padding(.top, 14)
    }

    private func copyUID(_ uid: String) {
        state.copy(uid, flash: false)   // 主窗不弹「已复制」，由本窗 toast 呈现
        flashLocal("已复制 \(uid)")
    }

    /// 本窗 toast：样式复用 ToastBar；同代号新 toast 刷新、旧的到点不清（与 AppState.flashToast 同语义）
    private func flashLocal(_ msg: String) {
        localToast = msg
        localToastGen += 1
        let g = localToastGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {   // 与 AppState.toastDuration(2.6s) 对齐
            guard localToastGen == g else { return }
            localToast = ""
        }
    }
}

// MARK: - 第一层：名称组（组头＝折叠钮＋名称/计数＋默认来源灯牌×3；灯牌亮态复制该线默认来源通用 ID）
private struct UIDCopyGroupCard: View {
    @EnvironmentObject var state: AppState
    let group: ModelGroup
    let onCopy: (String) -> Void
    /// 名称列宽与灯牌槽宽：与模型管理页 nameCol(190)/F2(112) 一致，跨卡对齐；上限变更需两处同改
    private static let nameCol: CGFloat = 190
    private static let badgeSlot: CGFloat = 112
    @State private var open = false

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
                            Text("\(group.idCount) 个模型 ID · \(group.entryCount) 家供应商")   // S7：量词与子行「N 家供应商」统一（曾「N 条」）
                                .font(f(11)).foregroundStyle(ink3).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: Self.nameCol, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach([ModelAPI.messages, .responses, .completions], id: \.rawValue) { api in
                    DefaultSourceBadge(api: api,
                                       lit: state.defaults(for: group.title)[api.rawValue] != nil,
                                       onCopy: {
                                           if let id = state.defaultSourceUniversalID(groupKey: group.title, api: api) {
                                               onCopy(id)
                                           }
                                       })
                        .frame(width: Self.badgeSlot, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)

            if open {
                ForEach(group.sections) { section in
                    UIDCopyIDSection(groupTitle: group.title, section: section, onCopy: onCopy)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBg)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sep, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1))
    }
}

// MARK: - 第二层：模型 ID 行（整行点击展开/折叠供应商条目；无铅笔编辑）
private struct UIDCopyIDSection: View {
    let groupTitle: String
    let section: ModelGroupSection
    let onCopy: (String) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                .contentShape(Rectangle())   // 整行命中（含 Spacer 区），照抄模型管理页做法
            }
            .buttonStyle(.plain)
            .padding(.leading, 38).padding(.trailing, 14).padding(.vertical, 9)

            if open {
                VStack(spacing: 0) {
                    ForEach(section.entries) { e in
                        UIDCopyVendorRow(groupTitle: groupTitle, entry: e, onCopy: onCopy)
                    }
                }
                .background(Color(NSColor.quaternaryLabelColor).opacity(0.10))
            }
        }
        .overlay(Rectangle().fill(sep).frame(height: 1), alignment: .top)
    }
}

// MARK: - 第三层：供应商条目行（名称＋全拼＋三线徽标＋复制键；无垃圾桶删除）
private struct UIDCopyVendorRow: View {
    @EnvironmentObject var state: AppState
    let groupTitle: String
    let entry: ModelEntry
    let onCopy: (String) -> Void

    /// 本供应商是否为该名称组某线的默认来源（徽标绿点角标，与模型管理页同判据）
    private func isDefault(_ api: ModelAPI) -> Bool {
        state.config.defaultSourcesByAPI[groupTitle]?[api.rawValue] == entry.vendorID
    }

    var body: some View {
        let vName = state.config.vendors.first(where: { $0.id == entry.vendorID })?.name ?? "—"
        let uid = state.universalID(entry)
        return HStack(spacing: 10) {
            Text(vName).font(f(12.5, .semibold)).lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)   // 名称优先保宽（与模型管理页一致）
            Text(PinYinLabel.label(for: vName)).font(mono(10.5)).foregroundStyle(ink3)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 110, alignment: .leading)
                .help("通用 ID 前缀（全拼）：\(PinYinLabel.label(for: vName))")
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ModelAPIBadge(api: .messages, avail: state.availability(entry, .messages),
                              isDefault: isDefault(.messages), dotSlot: true)
                ModelAPIBadge(api: .responses, avail: state.availability(entry, .responses),
                              isDefault: isDefault(.responses), dotSlot: true)
                ModelAPIBadge(api: .completions, avail: state.availability(entry, .completions),
                              isDefault: isDefault(.completions), dotSlot: true)
            }
            // S7：复制钮统一 Theme.copyIconBtn 规格（曾自绘 22×22 无边框 hover 一套）
            copyIconBtn("doc.on.doc") { onCopy(uid) }
                .help("复制该来源通用 ID（\(uid)）")
        }
        .padding(.leading, 62).padding(.trailing, 14).padding(.vertical, 8)
    }
}
