import Foundation

// MARK: - 模型库纯规则（I5 批 2′：身份键纪律与保存语义；全部纯函数、无 IO）
//
// 身份规则：条目身份 = (vendorID, modelID)（INV-1 同键唯一）；名称组键 = 条目自身 groupKey（INV-2），
// 同名多模型 ID 全部保留、永不覆盖（管理员 2026-09-18 方向）；名称/键迁移必须显式（INV-3 禁静默改写）。
public enum ModelLibraryRules {

    // MARK: - 报告类型（UI 弹窗/toast/无头断言共用）

    public struct SlotRef: Equatable {
        public let harnessName: String
        public let field: String
    }

    public struct UpsertReport: Equatable {
        public let entryID: UUID
        public let created: Bool
        public let nameWritten: Bool
        public let metaUpdated: Bool
    }

    /// 就地换 ID（E1）：同一 (名称组, 供应商) 下既有条目改写为新模型 ID，条目身份 UUID 不变
    public struct SwapUpdate: Equatable {
        public let entryID: UUID
        public let vendorID: UUID
        public let oldID: String
        public let newID: String
        public let skippedLockedSlots: [SlotRef]  // 锁定行保留旧 ID 引用（映射仍可转发）
    }

    public struct DeletionReport: Equatable {
        public let removedEntryIDs: [UUID]        // AppState 据此清 entryProbe
        public let removedLabels: [String]        // 「名称 · ID @ 供应商」
        public let clearedSlots: [SlotRef]        // 已清引用的槽位
        public let skippedLockedSlots: [SlotRef]  // 锁定行保留引用（映射仍可转发）
        public let droppedGroupKeys: [String]     // 组内条目清空 → 移除的默认来源键
    }

    public struct RenameConflict: Equatable {
        public let api: String
        public let kept: UUID
        public let dropped: UUID
    }

    public struct RenameReport: Equatable {
        public let moved: [String: UUID]          // 并入新键的线 → 供应商
        public let conflicts: [RenameConflict]    // 新键已有值、旧值被丢弃的线
        public let skippedLiveOldKey: Bool        // 旧键仍有存活条目，未迁移
    }

    public struct SaveRequest {
        public let modelID: String
        public let groupName: String              // 已 trim；空 = 无名（组键回落 modelID）
        public let vendorIDs: [UUID]
        public let codexSlug: String?             // App 层由元数据算好传入（Core 不解析）
        public let codexMetaJSON: String?
        public let baselineModelID: String?       // 编辑基线 ID；nil（添加）或 ≠ modelID（改 ID=新建）时无删除

        public init(modelID: String, groupName: String, vendorIDs: [UUID],
                    codexSlug: String?, codexMetaJSON: String?, baselineModelID: String?) {
            self.modelID = modelID
            self.groupName = groupName
            self.vendorIDs = vendorIDs
            self.codexSlug = codexSlug
            self.codexMetaJSON = codexMetaJSON
            self.baselineModelID = baselineModelID
        }
    }

    public struct SavePlan {
        public let deletions: [ModelEntry]        // 将被删除的条目（确认框逐条列出）
        public let creates: Int
        public let updates: Int
        public let swaps: [SwapUpdate]            // 就地换 ID 预演（E1；零写入）
        public let conflicts: [String]            // E2：该供应商在别的名称下已持新 ID，保存将跳过
    }

    public struct SaveReport {
        public let upserts: [UpsertReport]
        public let deletion: DeletionReport?
        public let renames: [RenameReport]
        public let swapUpdates: [SwapUpdate]      // 就地换 ID 实写记录（E1）
        public let conflicts: [String]            // E2：跳过的供应商及原因说明
    }

    // MARK: - upsert（精确 (vendorID, modelID)；绝不触碰第三条目）

    /// 存在同 (vendorID, modelID) → 就地更新（overwriteName 控制名称写入：保存路径 true、探测/手动路径 false）；
    /// meta 仅在传入非空时覆盖；不存在 → 新建追加。
    @discardableResult
    public static func upsertEntry(_ cfg: inout RouterConfig,
                                   modelID: String, vendorID: UUID,
                                   displayName: String?,
                                   codexSlug: String?, codexMetaJSON: String?,
                                   overwriteName: Bool) -> UpsertReport {
        let nm = (displayName ?? "").trimmingCharacters(in: .whitespaces)
        if let i = cfg.models.firstIndex(where: { $0.modelID == modelID && $0.vendorID == vendorID }) {
            var nameWritten = false
            if overwriteName {
                let new: String? = nm.isEmpty ? nil : nm
                if cfg.models[i].displayName != new {
                    cfg.models[i].displayName = new
                    nameWritten = true
                }
            }
            var metaUpdated = false
            if let meta = codexMetaJSON, !meta.isEmpty {
                if cfg.models[i].codexMetaJSON != meta { cfg.models[i].codexMetaJSON = meta; metaUpdated = true }
                if let slug = codexSlug, !slug.isEmpty, cfg.models[i].codexSlug != slug { cfg.models[i].codexSlug = slug; metaUpdated = true }
            }
            return UpsertReport(entryID: cfg.models[i].id, created: false, nameWritten: nameWritten, metaUpdated: metaUpdated)
        }
        let m = ModelEntry(modelID: modelID, vendorID: vendorID,
                           displayName: nm.isEmpty ? nil : nm,
                           codexSlug: (codexSlug?.isEmpty == false) ? codexSlug : nil,
                           codexMetaJSON: (codexMetaJSON?.isEmpty == false) ? codexMetaJSON : nil)
        cfg.models.append(m)
        return UpsertReport(entryID: m.id, created: true, nameWritten: !nm.isEmpty, metaUpdated: false)
    }

    // MARK: - 删除（级联：槽位清引用跳过锁定行、组空清默认来源、组内语义剪枝）

    @discardableResult
    public static func deleteEntries(_ cfg: inout RouterConfig, ids: [UUID]) -> DeletionReport {
        let targets = cfg.models.filter { ids.contains($0.id) }
        guard !targets.isEmpty else {
            return DeletionReport(removedEntryIDs: [], removedLabels: [],
                                  clearedSlots: [], skippedLockedSlots: [], droppedGroupKeys: [])
        }
        let pairs = Set(targets.map { "\($0.vendorID.uuidString)|\($0.modelID)" })
        let keys = Set(targets.map(\.groupKey))
        cfg.models.removeAll { ids.contains($0.id) }
        func vname(_ id: UUID) -> String {
            cfg.vendors.first { $0.id == id }?.name ?? String(id.uuidString.prefix(8))
        }
        let labels = targets.map { "\($0.displayLabel) · \($0.modelID) @ \(vname($0.vendorID))" }
        var cleared: [SlotRef] = []
        var skipped: [SlotRef] = []
        for hi in cfg.harnesses.indices {
            for si in cfg.harnesses[hi].slots.indices {
                let s = cfg.harnesses[hi].slots[si]
                guard let mid = s.modelID, let vid = s.vendorID,
                      pairs.contains("\(vid.uuidString)|\(mid)") else { continue }
                if s.locked == true {
                    skipped.append(SlotRef(harnessName: cfg.harnesses[hi].name, field: s.clientModelField))
                } else {
                    cfg.harnesses[hi].slots[si].modelID = nil
                    cfg.harnesses[hi].slots[si].vendorID = nil
                    cleared.append(SlotRef(harnessName: cfg.harnesses[hi].name, field: s.clientModelField))
                }
            }
        }
        var dropped: [String] = []
        for k in keys {
            if !cfg.models.contains(where: { $0.groupKey == k }) {
                // 组已清空 → 整键移除
                if cfg.defaultSourcesByAPI[k] != nil {
                    cfg.defaultSourcesByAPI.removeValue(forKey: k)
                    dropped.append(k)
                }
                continue
            }
            // 组仍有条目：剪掉指向「该组已无条目供应商」的线（删除路径专属的语义剪枝）
            if var line = cfg.defaultSourcesByAPI[k] {
                var changed = false
                for (api, vid) in line
                where !cfg.models.contains(where: { $0.groupKey == k && $0.vendorID == vid }) {
                    line.removeValue(forKey: api)
                    changed = true
                }
                if changed {
                    if line.isEmpty { cfg.defaultSourcesByAPI.removeValue(forKey: k); dropped.append(k) }
                    else { cfg.defaultSourcesByAPI[k] = line }
                }
            }
        }
        return DeletionReport(removedEntryIDs: targets.map(\.id), removedLabels: labels,
                              clearedSlots: cleared, skippedLockedSlots: skipped, droppedGroupKeys: dropped)
    }

    /// 保存路径的精确删除：该 ID 下被取消勾选的供应商（同 ID 其它供应商、其它 ID 一律不动）
    @discardableResult
    public static func removeVendorFromID(_ cfg: inout RouterConfig, modelID: String,
                                          vendorIDs: Set<UUID>) -> DeletionReport {
        let ids = cfg.models.filter { $0.modelID == modelID && vendorIDs.contains($0.vendorID) }.map(\.id)
        return deleteEntries(&cfg, ids: ids)
    }

    // MARK: - 组键迁移（按线合并；旧键仍有存活条目 → 不迁移）

    @discardableResult
    public static func renameGroupKey(_ cfg: inout RouterConfig, from oldKey: String, to newKey: String) -> RenameReport {
        guard oldKey != newKey, let oldLine = cfg.defaultSourcesByAPI[oldKey] else {
            return RenameReport(moved: [:], conflicts: [], skippedLiveOldKey: false)
        }
        guard !cfg.models.contains(where: { $0.groupKey == oldKey }) else {
            return RenameReport(moved: [:], conflicts: [], skippedLiveOldKey: true)
        }
        var moved: [String: UUID] = [:]
        var conflicts: [RenameConflict] = []
        var newLine = cfg.defaultSourcesByAPI[newKey] ?? [:]
        for (api, oldV) in oldLine {
            if let newV = newLine[api] {
                conflicts.append(RenameConflict(api: api, kept: newV, dropped: oldV))
            } else {
                newLine[api] = oldV
                moved[api] = oldV
            }
        }
        if newLine.isEmpty { cfg.defaultSourcesByAPI.removeValue(forKey: newKey) }
        else { cfg.defaultSourcesByAPI[newKey] = newLine }
        cfg.defaultSourcesByAPI.removeValue(forKey: oldKey)
        return RenameReport(moved: moved, conflicts: conflicts, skippedLiveOldKey: false)
    }

    // MARK: - ID 选择器数据源（该名称下已注册的模型 ID，首现序）

    public static func registeredModelIDs(in cfg: RouterConfig, groupKey: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for m in cfg.models where m.groupKey == groupKey {
            if seen.insert(m.modelID).inserted { out.append(m.modelID) }
        }
        return out
    }

    // MARK: - 就地换 ID 判定（E1/E2；planSave 与 applySave 同一真源，只读零写入）

    /// 逐勾选供应商 v 归类：
    /// - 目标名称组下已有精确配对 (req.modelID, v) → 原 upsert 路径（非 swap）；
    /// - 目标名称组下该供应商持有别的 ID → swap 候选；此时若全库别处已持新 ID（E2 重叠，
    ///   就地改写会造成 (vendorID, modelID) 全库重复）→ 冲突跳过（既不 swap 也不 upsert）；
    /// - 无目标条目 → 原 upsert 路径（含旧键迁移收集，语义不变）。
    private static func swapCandidates(_ cfg: RouterConfig, _ req: SaveRequest, _ newKey: String)
        -> (swaps: [SwapUpdate], conflicts: [String], conflictedVendorIDs: Set<UUID>) {
        var swaps: [SwapUpdate] = []
        var conflicts: [String] = []
        var conflicted: Set<UUID> = []
        for v in req.vendorIDs {
            if cfg.models.contains(where: { $0.modelID == req.modelID && $0.vendorID == v && $0.groupKey == newKey }) {
                continue
            }
            guard let cand = cfg.models.first(where: {
                $0.groupKey == newKey && $0.vendorID == v && $0.modelID != req.modelID
            }) else { continue }
            if let elsewhere = cfg.models.first(where: { $0.modelID == req.modelID && $0.vendorID == v }) {
                let label = cfg.vendors.first { $0.id == v }?.name ?? String(v.uuidString.prefix(8))
                conflicts.append("供应商 \(label) 已持有该 ID（在名称 \(elsewhere.groupKey) 下）")
                conflicted.insert(v)
                continue
            }
            var skipped: [SlotRef] = []
            for h in cfg.harnesses {
                for s in h.slots where s.vendorID == v && s.modelID == cand.modelID && s.locked == true {
                    skipped.append(SlotRef(harnessName: h.name, field: s.clientModelField))
                }
            }
            swaps.append(SwapUpdate(entryID: cand.id, vendorID: v, oldID: cand.modelID,
                                    newID: req.modelID, skippedLockedSlots: skipped))
        }
        return (swaps, conflicts, conflicted)
    }

    // MARK: - 保存计划（只读，供确认框；零写入）

    public static func planSave(_ cfg: RouterConfig, _ req: SaveRequest) -> SavePlan {
        var deletions: [ModelEntry] = []
        if let base = req.baselineModelID, base == req.modelID {
            let keep = Set(req.vendorIDs)
            deletions = cfg.models.filter { $0.modelID == base && !keep.contains($0.vendorID) }
        }
        let newKey = req.groupName.isEmpty ? req.modelID : req.groupName
        let scan = swapCandidates(cfg, req, newKey)
        var creates = 0, updates = 0
        for v in req.vendorIDs {
            if cfg.models.contains(where: { $0.modelID == req.modelID && $0.vendorID == v }) { updates += 1 }
            else if scan.swaps.contains(where: { $0.vendorID == v }) { /* 就地换 ID：不新增条目 */ }
            else { creates += 1 }
        }
        return SavePlan(deletions: deletions, creates: creates, updates: updates,
                        swaps: scan.swaps, conflicts: scan.conflicts)
    }

    // MARK: - 应用保存（删除集合 → 逐勾选：swap 就地改写 / 冲突跳过 / 精确 upsert → 旧键迁移）

    @discardableResult
    public static func applySave(_ cfg: inout RouterConfig, _ req: SaveRequest) -> SaveReport {
        var deletion: DeletionReport? = nil
        if let base = req.baselineModelID, base == req.modelID {
            let keep = Set(req.vendorIDs)
            let ids = cfg.models.filter { $0.modelID == base && !keep.contains($0.vendorID) }.map(\.id)
            if !ids.isEmpty { deletion = deleteEntries(&cfg, ids: ids) }
        }
        let newKey = req.groupName.isEmpty ? req.modelID : req.groupName
        let scan = swapCandidates(cfg, req, newKey)   // 删除后计算：预演与实写同源同态
        var upserts: [UpsertReport] = []
        var swapUpdates: [SwapUpdate] = []
        var touchedOldKeys: Set<String> = []
        for v in req.vendorIDs {
            if let sw = scan.swaps.first(where: { $0.vendorID == v }) {
                // E1 就地改写：条目 UUID 不变，仅换 modelID 并作废检测结论；codex 元数据随条目保留
                if let i = cfg.models.firstIndex(where: { $0.id == sw.entryID }) {
                    cfg.models[i].modelID = req.modelID
                    cfg.models[i].probeResults = nil
                    cfg.models[i].probedAt = nil
                    cfg.models[i].tested = nil
                }
                var skipped: [SlotRef] = []
                for hi in cfg.harnesses.indices {
                    for si in cfg.harnesses[hi].slots.indices {
                        let s = cfg.harnesses[hi].slots[si]
                        guard s.vendorID == v, s.modelID == sw.oldID else { continue }
                        if s.locked == true {
                            skipped.append(SlotRef(harnessName: cfg.harnesses[hi].name, field: s.clientModelField))
                        } else {
                            cfg.harnesses[hi].slots[si].modelID = req.modelID
                        }
                    }
                }
                swapUpdates.append(SwapUpdate(entryID: sw.entryID, vendorID: v, oldID: sw.oldID,
                                              newID: req.modelID, skippedLockedSlots: skipped))
                continue
            }
            if scan.conflictedVendorIDs.contains(v) { continue }   // E2：零写入
            let oldKey = cfg.models.first(where: { $0.modelID == req.modelID && $0.vendorID == v })?.groupKey
            upserts.append(upsertEntry(&cfg, modelID: req.modelID, vendorID: v,
                                       displayName: req.groupName, codexSlug: req.codexSlug,
                                       codexMetaJSON: req.codexMetaJSON, overwriteName: true))
            if let ok = oldKey, ok != newKey { touchedOldKeys.insert(ok) }
        }
        var renames: [RenameReport] = []
        for oldKey in touchedOldKeys {
            renames.append(renameGroupKey(&cfg, from: oldKey, to: newKey))
        }
        return SaveReport(upserts: upserts, deletion: deletion, renames: renames,
                          swapUpdates: swapUpdates, conflicts: scan.conflicts)
    }
}
