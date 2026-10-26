import Foundation

// MARK: - 配置修复（I5：存量数据一致性；幂等纯函数，不落盘、无 IO）
//
// 只删确定性违规项（对齐排查不变量 I3/I4/I6/I12/I13/I14 与卡内键唯一）；
// 语义级剪枝（如「默认来源指向的供应商在该组已无条目」）不在此处做——那是删除路径的级联职责。
public enum ConfigRepair {

    public struct RepairNote: CustomStringConvertible, Identifiable {
        public let id = UUID()
        public let code: String       // 规则编号：I3 / I4 / I6 / I12 / I13 / I14 / SLOT-DUP / TIER-DUP
        public let message: String
        public var description: String { "[\(code)] \(message)" }
    }

    /// 修复并返回新配置与明细。幂等：对修复结果再跑一遍应为零 note。
    public static func repair(_ cfg: RouterConfig) -> (config: RouterConfig, notes: [RepairNote]) {
        var c = cfg
        var notes: [RepairNote] = []
        orphanModels(&c, &notes)
        duplicateEntries(&c, &notes)
        defaultSources(&c, &notes)
        codexSlotMigration(&c, &notes)
        slots(&c, &notes)
        tierOrder(&c, &notes)
        return (c, notes)
    }

    /// R8-MIG：Codex 卡旧槽位迁移到「名称即 slug」纯派生架构（2026-09-26 分支定案 2）。
    /// - clientModelField 已是库内名称（groupKey）→ 保留原样；
    /// - 非名称但有绑定（vendorID+modelID）→ 按绑定定位条目，键换为该条目 groupKey（映射保留、slug 换名称）；条目不存在 → 弃槽；
    /// - 无绑定且非名称（旧「映射N」空槽）→ 删；
    /// - 迁移产生的重名键由随后的 SLOT-DUP 规则去重；热切换四档槽（gpt-astra 等）同规则按绑定迁移。
    /// 名称不合规（中文/空格）的既有绑定保留行与映射（不静默丢弃），界面层负责标记提醒。
    private static func codexSlotMigration(_ c: inout RouterConfig, _ notes: inout [RepairNote]) {
        let nameSet = Set(c.models.map(\.groupKey))
        var byBinding: [String: String] = [:]   // vendorID|modelID → groupKey
        for m in c.models {
            byBinding["\(m.vendorID.uuidString)|\(m.modelID)"] = m.groupKey
        }
        for hi in c.harnesses.indices
        where c.harnesses[hi].proto == .openai && (c.harnesses[hi].universal ?? false) == false {
            let slots = c.harnesses[hi].slots
            guard slots.contains(where: { !nameSet.contains($0.clientModelField) }) else { continue }
            var kept: [Slot] = []
            var renamed = 0, dropped = 0
            for s in slots {
                if nameSet.contains(s.clientModelField) { kept.append(s); continue }
                if let vid = s.vendorID, let mid = s.modelID,
                   let name = byBinding["\(vid.uuidString)|\(mid)"] {
                    var n = s
                    n.clientModelField = name
                    kept.append(n)
                    renamed += 1
                    continue
                }
                dropped += 1
            }
            c.harnesses[hi].slots = kept
            notes.append(RepairNote(code: "R8-MIG",
                message: "\(c.harnesses[hi].name)：\(renamed) 个旧槽位迁移为模型名称（映射保留），\(dropped) 个失效槽位移除（名称/绑定已不存在）"))
        }
    }

    /// I3：条目指向不存在的供应商（模型管理页不可见但驻留 JSON）
    private static func orphanModels(_ c: inout RouterConfig, _ notes: inout [RepairNote]) {
        let vids = Set(c.vendors.map(\.id))
        let orphans = c.models.filter { !vids.contains($0.vendorID) }
        guard !orphans.isEmpty else { return }
        c.models.removeAll { !vids.contains($0.vendorID) }
        notes.append(RepairNote(code: "I3",
            message: "移除 \(orphans.count) 条供应商已不存在的模型条目：\(shortList(orphans.map(\.displayLabel)))"))
    }

    /// I4：同 (供应商, 模型ID) 多条——保留数据最全者（tested 优先 → 检测结论键数多者优先 → id 字典序），其余删除
    private static func duplicateEntries(_ c: inout RouterConfig, _ notes: inout [RepairNote]) {
        let models = c.models
        var byPair: [String: [Int]] = [:]
        for (i, m) in models.enumerated() {
            byPair["\(m.vendorID.uuidString)|\(m.modelID)", default: []].append(i)
        }
        var drop = Set<Int>()
        var kept: [String] = []
        for (_, idxs) in byPair where idxs.count > 1 {
            let best = idxs.min { a, b in
                let ma = models[a], mb = models[b]
                if (ma.tested == true) != (mb.tested == true) { return ma.tested == true }
                if (ma.probeResults?.count ?? 0) != (mb.probeResults?.count ?? 0) {
                    return (ma.probeResults?.count ?? 0) > (mb.probeResults?.count ?? 0)
                }
                return ma.id.uuidString < mb.id.uuidString
            }!
            for i in idxs where i != best { drop.insert(i) }
            let m = models[best]
            kept.append("\(m.displayLabel)@\(vendorName(c, m.vendorID))")
        }
        if !drop.isEmpty {
            c.models = models.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
            notes.append(RepairNote(code: "I4",
                message: "合并 \(kept.count) 组重复模型条目（同供应商同模型 ID，保留数据最全者）：\(shortList(kept))"))
        }
    }

    /// I12 孤儿组键 / I13 未知内层键 / I14 值指向不存在的供应商
    private static func defaultSources(_ c: inout RouterConfig, _ notes: inout [RepairNote]) {
        let vids = Set(c.vendors.map(\.id))
        let liveKeys = Set(c.models.map(\.groupKey))
        let validAPIs: Set<String> = ["messages", "responses", "completions"]
        var orphanKeys: [String] = []
        var badInner: [String] = []
        var deadValues: [String] = []
        for (k, line) in c.defaultSourcesByAPI {
            if !liveKeys.contains(k) {
                orphanKeys.append(k)
                continue
            }
            for (api, _) in line where !validAPIs.contains(api) { badInner.append("\(k).\(api)") }
            for (api, vid) in line where !vids.contains(vid) { deadValues.append("\(k).\(api)") }
        }
        if !orphanKeys.isEmpty {
            for k in orphanKeys { c.defaultSourcesByAPI.removeValue(forKey: k) }
            notes.append(RepairNote(code: "I12",
                message: "移除 \(orphanKeys.count) 个无对应模型条目的默认来源组键：\(shortList(orphanKeys))"))
        }
        if !badInner.isEmpty || !deadValues.isEmpty {
            for (k, line) in c.defaultSourcesByAPI {
                var cleaned = line
                for (api, vid) in line where !validAPIs.contains(api) || !vids.contains(vid) {
                    cleaned.removeValue(forKey: api)
                }
                if cleaned.isEmpty { c.defaultSourcesByAPI.removeValue(forKey: k) }
                else if cleaned.count != line.count { c.defaultSourcesByAPI[k] = cleaned }
            }
            if !badInner.isEmpty {
                notes.append(RepairNote(code: "I13", message: "移除未知 API 线键：\(shortList(badInner))"))
            }
            if !deadValues.isEmpty {
                notes.append(RepairNote(code: "I14", message: "移除指向不存在供应商的默认来源：\(shortList(deadValues))"))
            }
        }
    }

    /// I6：半绑定槽（vendorID/modelID 只一侧非空 → 双侧清＋清锁定，防空行锁死局）
    /// SLOT-DUP：卡内 clientModelField 重复（保留有绑定/锁定/首条者）
    private static func slots(_ c: inout RouterConfig, _ notes: inout [RepairNote]) {
        var halfCount = 0
        var halfCards: Set<String> = []
        for hi in c.harnesses.indices {
            for si in c.harnesses[hi].slots.indices {
                let s = c.harnesses[hi].slots[si]
                if (s.vendorID == nil) != (s.modelID == nil) {
                    c.harnesses[hi].slots[si].vendorID = nil
                    c.harnesses[hi].slots[si].modelID = nil
                    c.harnesses[hi].slots[si].locked = nil
                    halfCount += 1
                    halfCards.insert(c.harnesses[hi].name)
                }
            }
        }
        if halfCount > 0 {
            notes.append(RepairNote(code: "I6",
                message: "修复 \(halfCount) 个半绑定槽位（供应商/模型两侧同清，含清除其锁定）：\(shortList(Array(halfCards)))"))
        }
        for hi in c.harnesses.indices {
            let slots = c.harnesses[hi].slots
            var byField: [String: [Int]] = [:]
            for (si, s) in slots.enumerated() {
                byField[s.clientModelField, default: []].append(si)
            }
            var drop = Set<Int>()
            var dupFields: [String] = []
            for (field, idxs) in byField where idxs.count > 1 {
                let best = idxs.min { a, b in
                    let sa = slots[a], sb = slots[b]
                    if sa.isMapped != sb.isMapped { return sa.isMapped }
                    if (sa.locked == true) != (sb.locked == true) { return sa.locked == true }
                    return a < b
                }!
                for i in idxs where i != best { drop.insert(i) }
                dupFields.append(field)
            }
            if !drop.isEmpty {
                c.harnesses[hi].slots = slots.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
                notes.append(RepairNote(code: "SLOT-DUP",
                    message: "\(c.harnesses[hi].name)：移除 \(dupFields.count) 个重复模型位键（保留有绑定/锁定者）：\(shortList(dupFields))"))
            }
        }
    }

    /// TIER-DUP：同一卡档序含重复键（保序去重）
    private static func tierOrder(_ c: inout RouterConfig, _ notes: inout [RepairNote]) {
        for hi in c.harnesses.indices {
            guard let tier = c.harnesses[hi].tierOrder, Set(tier).count != tier.count else { continue }
            var seen: Set<String> = []
            let deduped = tier.filter { seen.insert($0).inserted }
            let removed = tier.count - deduped.count
            c.harnesses[hi].tierOrder = deduped
            notes.append(RepairNote(code: "TIER-DUP",
                message: "\(c.harnesses[hi].name)：档序去除 \(removed) 个重复键"))
        }
    }

    private static func vendorName(_ c: RouterConfig, _ id: UUID) -> String {
        c.vendors.first { $0.id == id }?.name ?? String(id.uuidString.prefix(8))
    }

    /// 明细列表截断（最多 6 项，避免横幅/日志过长）
    private static func shortList(_ items: [String]) -> String {
        let prefix = items.prefix(6).joined(separator: "、")
        return items.count > 6 ? "\(prefix) 等 \(items.count) 项" : prefix
    }
}
