// Claude 档位管理测试（自原 S3 套件按域拆出·面向公开仓库）
// 覆盖：①原生档位删除后的路由语义（noMapping 透明失败＋降级链）；②官方预设 ID 固化集
// （15 项、分解重组、档序、预设查重感知）；③弃用检查与 ID 更新通道（豁免权、防自陷）。
// 编号前缀 CT＝Claude Tier（删除权）/CTP＝官方预设/CTD＝弃用与更新。
// 安全相关性：槽位 ID 更新只改档位键、映射与锁定态保持——验证「ID 迁移不动绑定关系」。

import XCTest
@testable import ModelRouter
@testable import ModelRouterCore
import ModelRouterCore

final class ClaudeTierTests: XCTestCase {
    private var pass = 0
    private var fail = 0
    private func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        if cond { pass += 1 } else { fail += 1 }
        XCTAssertTrue(cond, name + (detail.isEmpty ? "" : "  — \(detail)"))
    }

    func testClaudeTierSuite() throws {
// ───────────────────────── ① 原生档位删除权（删除后语义与降级链） ─────────────────────────

check(K.claudePositions.count == 5 && K.claudePositions.contains("-haiku")
      && !K.claudeCustomPositions.contains("-haiku"),
      "CT-1 解析段含 -haiku，但自定义定位不提供 Haiku（官方预设直选恢复）")
check(Router.claudeTierRank("claude-haiku-4-5") == 4, "CT-2 haiku 档序秩稳定（4，注册不乱序）")
check(K.claudeTierOrder == ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
      "CT-3 原生默认档＝Fable5.1/Opus5.5/Sonnet5.5/Haiku5.5（Mythos 不默认）")

// 内存构造 Claude 卡（不触磁盘）：验证删除后的路由语义＝noMapping 透明失败＋降级链跳过已删档
do {
    let vID = UUID()
    let hID = UUID()
    let vendor = Vendor(id: vID, name: "V测试", keyRef: "k1", anthropicBase: URL(string: "https://api.test.internal"))
    func mkRouter(_ tier: [String], _ slots: [Slot]) -> Router {
        let h = Harness(id: hID, name: "C测试", proto: .anthropic, accessKeyRef: "kc",
                        tierOrder: tier, slots: slots)
        let cfg = RouterConfig(endpoint: EndpointSpec(), vendors: [vendor], harnesses: [h], models: [ModelEntry(modelID: "m-sonnet", vendorID: vID)])
        return Router(table: HarnessTable(config: cfg))
    }
    let sonnetSlot = Slot(clientModelField: "claude-sonnet-5", vendorID: vID, modelID: "m-sonnet")
    // 删 haiku：tier 只剩 fable/sonnet/haiku → fable 请求降级命中 sonnet；haiku 请求 404
    let afterHaiku = mkRouter(["claude-fable-5", "claude-sonnet-5", "claude-haiku-4-5"], [sonnetSlot])
    let r1 = afterHaiku.resolve(harnessID: hID, modelField: "claude-haiku-4-5")
    check(r1 == nil, "CT-4 已删档请求 → noMapping 透明失败（resolve nil）")
    let r2 = afterHaiku.resolve(harnessID: hID, modelField: "claude-fable-5")
    check(r2?.modelID == "m-sonnet" && r2?.fellBackFrom == "claude-fable-5",
          "CT-5 未映射档降级命中下位（fable→sonnet）")
    // 再删 sonnet（tier 只剩 fable/haiku，全未映射）→ fable 请求到底无可降 → nil
    let afterSonnet = mkRouter(["claude-fable-5", "claude-haiku-4-5"], [])
    let r3 = afterSonnet.resolve(harnessID: hID, modelField: "claude-fable-5")
    check(r3 == nil, "CT-6 下位全删后降级到底 → noMapping（档链删空可复原）")
}

// ───────────────────────── ② 官方预设 ID 固化集与直选 ─────────────────────────

check(K.anthropicSupported.count == 15, "CTP-1 固化集 15 项（扁平无分组）")
check(K.anthropicOfferable == ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5",
                               "claude-haiku-5-5", "claude-haiku-4-5",
                               "claude-mythos-5-1", "claude-mythos-5",
                               "claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8"],
      "CTP-2 预设清单精确（4.8 之后＋Haiku5.5/4.5 恢复入口）")
check(K.anthropicOfferable.allSatisfy { K.anthropicSupported.contains($0) },
      "CTP-3 预设 ⊆ 固化集")
let allPresets = Array(K.anthropicSupported).sorted()
check(allPresets.count == 15 && Set(allPresets).count == 15, "CTP-4 固化集 15 项无重复")
check(allPresets.allSatisfy { !$0.contains("2025") && !$0.contains("2026") },
      "CTP-5 固化集全部剥离日期段")
check(K.anthropicSupported.contains("claude-haiku-5-5") && K.anthropicSupported.contains("claude-haiku-4-5")
      && !K.anthropicSupported.contains("claude-sonnet-4-5"), "CTP-6 固化集含 haiku-5.5/4.5、不含已弃用 sonnet-4-5")
var decomposeOK = true
for id in allPresets {
    guard let d = Router.claudeDecompose(id), "claude" + d.position + d.suffix == id,
          K.claudePositions.contains(d.position) else { decomposeOK = false; break }
}
check(decomposeOK, "CTP-7 15 项全部分解且重组还原（注册通路复用成立）")
check(Router.claudeDecompose("claude-haiku-4-5-20251001")?.position == "-haiku",
      "CTP-8 分解器含日期形态也正确（档秩 contains 语义）")
var rankOK = true
let expectRank = ["claude-mythos-5-1": 0, "claude-mythos-5": 0,
                  "claude-fable-5-1": 1, "claude-fable-5": 1,
                  "claude-opus-5-5": 2, "claude-opus-5": 2, "claude-opus-4-8": 2,
                  "claude-sonnet-5-5": 3, "claude-sonnet-5": 3]
for (id, r) in expectRank where Router.claudeTierRank(id) != r { rankOK = false }
check(rankOK, "CTP-9 预设 ID 档秩全部正确（mythos=0→sonnet=3）")

// S8③ 补充：预设下拉查重感知（已使用的 ID 不再可选）
let nativeUsed = Set(K.claudeTierOrder)
let offeredNative = ClaudeTierRegisterSheet.offeredPresets(usedIDs: nativeUsed).map(\.0)
check(!offeredNative.contains("claude-fable-5-1") && !offeredNative.contains("claude-opus-5-5")
      && !offeredNative.contains("claude-sonnet-5-5") && !offeredNative.contains("claude-haiku-5-5")
      && offeredNative.contains("claude-haiku-4-5") && offeredNative.contains("claude-mythos-5")
      && offeredNative.contains("claude-opus-4-8"),
      "CTP-10 新原生四档在用时：旧版与 Haiku4.5 仍可选")
check(offeredNative.contains("claude-fable-5") && offeredNative.contains("claude-opus-5")
      && offeredNative.contains("claude-sonnet-5"),
      "CTP-11 旧版官方 ID 保留为可添加预设")
let offeredPartial = ClaudeTierRegisterSheet.offeredPresets(usedIDs: ["claude-opus-5-5"]).map(\.0)
check(!offeredPartial.contains("claude-opus-5-5") && offeredPartial.count == 10,
      "CTP-12 单个已用 ID 被过滤（其余 10 项保留）")
check(ClaudeTierRegisterSheet.offeredPresets(usedIDs: []).count == 11,
      "CTP-13 空占用＝11 项全可选")

// ───────────────────────── ③ 弃用检查与 ID 更新通道 ─────────────────────────

check(Router.normalizedClaudeID("claude-haiku-4-5-20251001") == "claude-haiku-4-5"
      && Router.normalizedClaudeID("claude-opus-5") == "claude-opus-5",
      "CTD-1 日期段归一（剥尾部八位日期；无日期不动）")
check(Router.isSupportedClaudeID("claude-haiku-4-5-20251001")
      && Router.isSupportedClaudeID("claude-opus-4-5-20251101"),
      "CTD-2 带日期官方 ID 判支持")
check(!Router.isSupportedClaudeID("claude-sonnet-4-5-20250929")
      && !Router.isSupportedClaudeID("claude-sonnet-4-5")
      && !Router.isSupportedClaudeID("claude-opus-5-9-myown"),
      "CTD-3 弃用/自定义未命中判不支持")
check(Router.claudeDisplayName("claude-sonnet-5-5") == "Sonnet5.5"
      && Router.claudeDisplayName("claude-mythos-5") == "Mythos5"
      && Router.claudeDisplayName("claude-opus-4-8") == "Opus4.8"
      && Router.claudeDisplayName("claude-haiku-5-5") == "Haiku5.5"
      && Router.claudeDisplayName("claude-haiku-4-5-20251001") == "Haiku4.5",
      "CTD-4 显示名表（固化命中→写死名；带日期归一后命中）")
check(Router.claudeDisplayName("claude-opus-5-9-myown") == "Opus"
      && Router.claudeDisplayName("claude-mythos-5-3") == "Mythos",
      "CTD-5 未命中只显示档位名（无提醒）")
check(Router.claudeDisplayNames.count == 15, "CTD-6 显示名表 15 项全覆盖固化集")

// R28：存量默认档升级只动未被用户添加标记的旧档键，映射与锁定保留，且幂等
do {
    let hID = UUID()
    let vID = UUID()
    let oldOrder = ["claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
    let h = Harness(id: hID, name: "存量Claude", proto: .anthropic, accessKeyRef: "kc",
                    tierOrder: oldOrder,
                    slots: [
                        Slot(clientModelField: "claude-fable-5", vendorID: vID, modelID: "m-fable"),
                        Slot(clientModelField: "claude-opus-5"),
                        Slot(clientModelField: "claude-sonnet-5", vendorID: vID, modelID: "m-sonnet", locked: true),
                        Slot(clientModelField: "claude-haiku-4-5", vendorID: vID, modelID: "m-haiku"),
                    ])
    var cfg = RouterConfig(endpoint: EndpointSpec(), vendors: [], harnesses: [h], models: [])
    check(ConfigStore.upgradeDefaultClaudeTiers(&cfg), "CTR-1 存量旧默认档触发迁移")
    let upgraded = cfg.harnesses[0]
    check(upgraded.tierOrder == K.claudeTierOrder, "CTR-2 tierOrder 四键原位升级")
    check(upgraded.slots.map(\.clientModelField) == K.claudeTierOrder, "CTR-3 slot 键同步升级")
    check(upgraded.slots[0].vendorID == vID && upgraded.slots[0].modelID == "m-fable"
          && upgraded.slots[2].locked == true && upgraded.slots[3].modelID == "m-haiku",
          "CTR-4 迁移保留映射与锁定状态")
    check(!ConfigStore.upgradeDefaultClaudeTiers(&cfg), "CTR-5 迁移幂等")

    var collision = RouterConfig(endpoint: EndpointSpec(), vendors: [], harnesses: [
        Harness(id: UUID(), name: "冲突Claude", proto: .anthropic, accessKeyRef: "kc",
                tierOrder: ["claude-fable-5", "claude-fable-5-1"],
                slots: [Slot(clientModelField: "claude-fable-5"),
                        Slot(clientModelField: "claude-fable-5-1", userAdded: true)])
    ], models: [])
    _ = ConfigStore.upgradeDefaultClaudeTiers(&collision)
    check(collision.harnesses[0].slots.contains { $0.clientModelField == "claude-fable-5" },
          "CTR-6 新默认档已存在时不冲突迁移旧键")
}

do {
    // 内存配置直驱：弃用判定＋豁免＋renameSlot 纯函数
    let hID = UUID()
    let h = Harness(id: hID, name: "C测试", proto: .anthropic, accessKeyRef: "kc",
                    tierOrder: ["claude-fable-5", "claude-opus-5-9-x", "claude-sonnet-4-5"],
                    slots: [
                        Slot(clientModelField: "claude-fable-5"),
                        Slot(clientModelField: "claude-sonnet-4-5"),
                        Slot(clientModelField: "claude-opus-5-9-x", userAdded: true),
                    ])
    var cfg = RouterConfig(endpoint: EndpointSpec(), vendors: [], harnesses: [h], models: [])
    let dep = AppState.deprecatedSlots(in: cfg)
    check(dep.map(\.field) == ["claude-sonnet-4-5"],
          "CTD-7 弃用清单：无标+未命中才列入（原生命中/用户添加豁免）")
    let ok = AppState.renameSlotInConfig(&cfg, harnessID: hID, from: "claude-sonnet-4-5", to: "claude-sonnet-5-5")
    let h2 = cfg.harnesses[0]
    check(ok && !h2.slots.contains { $0.clientModelField == "claude-sonnet-4-5" }
          && h2.slots.contains { $0.clientModelField == "claude-sonnet-5-5" },
          "CTD-8 renameSlot 替换档位键")
    check(h2.tierOrder == ["claude-fable-5", "claude-opus-5-9-x", "claude-sonnet-5-5"],
          "CTD-9 tierOrder 旧删新插（sonnet-5-5 秩 3 兜尾，秩序保持）")
    check(AppState.deprecatedSlots(in: cfg).isEmpty, "CTD-10 更新后弃用清零")
    check(!AppState.renameSlotInConfig(&cfg, harnessID: hID, from: "claude-fable-5", to: "claude-sonnet-5-5"),
          "CTD-11 目标 ID 查重拒绝（sonnet-5-5 已存在）")
    // 目标为非官方 ID → 自动转「用户添加」防自陷
    _ = AppState.renameSlotInConfig(&cfg, harnessID: hID, from: "claude-fable-5", to: "claude-fable-5-2-x")
    check(cfg.harnesses[0].slots.first { $0.clientModelField == "claude-fable-5-2-x" }?.userAdded == true,
          "CTD-12 目标未命中固化 → 补用户添加标（豁免后续检查）")
    check(AppState.deprecatedSlots(in: cfg).isEmpty, "CTD-13 自陷防回（非官方目标不再判弃用）")
}

        XCTAssertTrue(fail == 0, "Claude 档位套件存在失败项：\(fail)（共 \(pass + fail) check）")
    }
}
