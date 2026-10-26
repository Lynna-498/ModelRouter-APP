// 路由核心测试（原 batch1 断言域重建·面向公开仓库）
// 覆盖：路径分类/协议识别、鉴权负路径（缺 Key/未知 Key）、槽位解析与档位降级、
// 悬挂绑定降级链、通用路由 VENDOR/MODEL 解析、模型发现、热换表即时生效、
// 上游请求构造的头剥离、配置修复的孤儿清理。
// 编号前缀 RT＝Router Test（历史编号 B1-n 为开发期批次号，保留可追溯）。
// 安全相关性：上游请求构造断言钉住「客户端凭证被剥离并替换为供应商 Key」「逐跳头剥离
// （含 accept-encoding）」——第三方复跑可验证转发不泄露客户端凭证、不破坏编码自洽。
import XCTest
@testable import ModelRouterCore

final class RouterTests: XCTestCase {
    private var pass = 0
    private var fail = 0
    private func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        if cond { pass += 1 } else { fail += 1 }
        XCTAssertTrue(cond, name + (detail.isEmpty ? "" : "  — \(detail)"))
    }

    private let vID = UUID()
    private let hID = UUID()
    private lazy var vendor = Vendor(id: vID, name: "智谱测试", keyRef: "k1",
                                     anthropicBase: URL(string: "https://api.test.internal"))
    private lazy var openaiVendor = Vendor(id: vID, name: "OpenAI测试", keyRef: "k1",
                                           openaiBase: URL(string: "https://api.openai.test"))

    private func mkRouter(_ tier: [String]?, _ slots: [Slot], universal: Bool = false,
                          proto: Proto = .anthropic, models: [ModelEntry] = [],
                          vendors: [Vendor]? = nil) -> Router {
        let h = Harness(id: hID, name: "T卡", proto: proto, accessKeyRef: "kc",
                        tierOrder: tier, universal: universal, slots: slots)
        let cfg = RouterConfig(endpoint: EndpointSpec(), vendors: vendors ?? [vendor],
                               harnesses: [h], models: models)
        return Router(table: HarnessTable(config: cfg))
    }

    func testRouterStatics() {
        check(Router.classify(path: "/claude/v1/messages") == .anthropic, "RT-1 /claude → anthropic")
        check(Router.classify(path: "/anthropic/v1/messages") == .anthropic, "RT-2 /anthropic → anthropic")
        check(Router.classify(path: "/v1/messages") == .anthropic, "RT-3 /v1/messages 旧版兼容")
        check(Router.classify(path: "/codex/responses") == .openai, "RT-4 /codex → openai")
        check(Router.classify(path: "/v1/responses") == .openai, "RT-5 /v1 → openai")
        check(Router.classify(path: "/other/path") == nil, "RT-6 未知路径 nil")
        check(Router.tierDisplay("claude-mythos-5-1") == "Mythos", "RT-7 mythos 显示名")
        check(Router.tierDisplay("claude-haiku-x") == "Haiku", "RT-8 haiku 显示名")
        check(Router.tierDisplay("custom-id") == "custom-id", "RT-9 非档位原样")
        check(Router.claudeTierRank("claude-mythos-5") == 0 && Router.claudeTierRank("claude-fable-x") == 1,
              "RT-10 mythos<fable 秩")
        check(Router.claudeTierRank("claude-opus-x") == 2 && Router.claudeTierRank("claude-sonnet-x") == 3,
              "RT-11 opus<sonnet 秩")
        check(Router.claudeTierRank("claude-haiku-x") == 4 && Router.claudeTierRank("unknown") == 5,
              "RT-12 haiku 秩 4、未知垫底")
        check(Router.claudeDecompose("claude-opus-5-5")?.position == "-opus"
              && Router.claudeDecompose("claude-opus-5-5")?.suffix == "-5-5", "RT-13 分解定位+后缀")
        check(Router.claudeDecompose("claude-opus") == nil, "RT-14 无后缀返回 nil")
        check(Router.normalizedClaudeID("claude-haiku-4-5-20251001") == "claude-haiku-4-5", "RT-15 日期归一")
        check(Router.normalizedClaudeID("claude-haiku-4-5") == "claude-haiku-4-5", "RT-16 无日期不动")
        check(Router.stripLead("/v1/", "/v1/messages") == "messages", "RT-17 stripLead")
        check(Router.stripVersion(Router.stripLeadAny(["/codex", "/v1"], "/codex/v1/responses")) == "/responses", "RT-18 stripVersion")
        check(Router.stripLeadAny(["/a/", "/b/"], "/b/x") == "x", "RT-19 stripLeadAny 次序命中")
        check(RouterError.noMapping.description.contains("not mapped"), "RT-20 noMapping 文案")
        check(RouterError.upstream("dns").description.contains("dns"), "RT-21 upstream 文案透传")
        check(RouterError.pathTraversal.description.contains("traversal"), "RT-22 pathTraversal 文案")
    }

    func testIdentifyNegativePaths() {
        let r = mkRouter(nil, [])
        if case .failure(let e) = r.identify(bearer: nil, path: "/claude/x", proto: .anthropic) {
            check(e.description == RouterError.missingKey.description, "RT-23 无 Authorization → missingKey")
        } else { check(false, "RT-23 无 Authorization → missingKey") }
        if case .failure(let e) = r.identify(bearer: "Token abc", path: "/claude/x", proto: .anthropic) {
            check(e.description == RouterError.missingKey.description, "RT-24 非 Bearer 形态 → missingKey")
        } else { check(false, "RT-24 非 Bearer 形态 → missingKey") }
        if case .failure(let e) = r.identify(bearer: "Bearer no-such-key", path: "/claude/x", proto: .anthropic) {
            check(e.description == RouterError.unknownKey.description, "RT-25 未知 Key → unknownKey")
        } else { check(false, "RT-25 未知 Key → unknownKey") }
    }

    func testResolveTiersAndFallback() {
        let sonnetSlot = Slot(clientModelField: "claude-sonnet-5", vendorID: vID, modelID: "m-sonnet")
        let r = mkRouter(["claude-fable-5", "claude-opus-5", "claude-sonnet-5"], [sonnetSlot],
                         models: [ModelEntry(modelID: "m-sonnet", vendorID: vID)])
        let direct = r.resolve(harnessID: hID, modelField: "claude-sonnet-5")
        check(direct?.modelID == "m-sonnet" && direct?.fellBackFrom == nil, "RT-26 直查命中无降级标记")
        let fell = r.resolve(harnessID: hID, modelField: "claude-fable-5")
        check(fell?.modelID == "m-sonnet" && fell?.fellBackFrom == "claude-fable-5",
              "RT-27 未映射档降级命中下位并留痕")
        check(r.resolve(harnessID: hID, modelField: "claude-haiku-x") == nil,
              "RT-28 低于已映射档且未映射 → noMapping")
        check(r.resolve(harnessID: hID, modelField: "not-a-tier") == nil,
              "RT-29 非已知档 → noMapping（不猜）")
        // 绑定供应商已删（悬挂引用）：该档无效，继续向下降级
        let ghostSlot = Slot(clientModelField: "claude-opus-5", vendorID: UUID(), modelID: "m-ghost")
        let r2 = mkRouter(["claude-fable-5", "claude-opus-5", "claude-sonnet-5"], [ghostSlot, sonnetSlot],
                         models: [ModelEntry(modelID: "m-sonnet", vendorID: vID)])
        let fell2 = r2.resolve(harnessID: hID, modelField: "claude-fable-5")
        check(fell2?.modelID == "m-sonnet", "RT-30 悬挂供应商档不短路降级链")
        // 路由开关关闭
        let h = Harness(id: hID, name: "T卡", proto: .anthropic, accessKeyRef: "kc",
                        tierOrder: ["claude-sonnet-5"], enabled: false, slots: [sonnetSlot])
        let cfg = RouterConfig(endpoint: EndpointSpec(), vendors: [vendor], harnesses: [h],
                               models: [ModelEntry(modelID: "m-sonnet", vendorID: vID)])
        let r3 = Router(table: HarnessTable(config: cfg))
        check(!r3.isRoutingEnabled(harnessID: hID), "RT-31 路由开关关闭生效")
        check(r3.isRoutingEnabled(harnessID: UUID()) == true, "RT-32 缺失开关视为开")
    }

    func testResolveCodexDirect() {
        let slot = Slot(clientModelField: "glm-test", vendorID: vID, modelID: "m-glm")
        let r = mkRouter(nil, [slot], proto: .openai,
                         models: [ModelEntry(modelID: "m-glm", vendorID: vID)], vendors: [openaiVendor])
        check(r.resolve(harnessID: hID, modelField: "glm-test")?.modelID == "m-glm", "RT-33 Codex 直查命中")
        check(r.resolve(harnessID: hID, modelField: "other") == nil, "RT-34 Codex 不降级")
    }

    func testResolveUniversal() {
        let entry = ModelEntry(modelID: "GLM-5.3", vendorID: vID)
        let r = mkRouter(nil, [Slot(clientModelField: "u")], universal: true, models: [entry])
        let hit = r.resolve(harnessID: hID, modelField: "智谱测试/GLM-5.3")
        check(hit?.modelID == "GLM-5.3", "RT-35 通用路由中文名标签命中")
        let hit2 = r.resolve(harnessID: hID, modelField: "ZHIPUCESHI/glm-5.3")
        check(hit2?.modelID == "GLM-5.3", "RT-36 拼音标签＋大小写不敏感命中")
        check(r.resolve(harnessID: hID, modelField: "nolabel") == nil, "RT-37 非 VENDOR/MODEL 形态 nil")
        check(r.resolve(harnessID: hID, modelField: "智谱测试/missing") == nil, "RT-38 未入库模型 nil")
    }

    func testModelList() {
        let sonnetSlot = Slot(clientModelField: "claude-sonnet-5", vendorID: vID, modelID: "m")
        let r = mkRouter(["claude-fable-5", "claude-sonnet-5"], [sonnetSlot])
        let ids = r.modelList(harnessID: hID, proto: .anthropic).map(\.id)
        check(ids == ["claude-sonnet-5"], "RT-39 Claude 卡发现＝已映射档")
        let rc = mkRouter(nil, [Slot(clientModelField: "glm-a"), Slot(clientModelField: "glm-b", vendorID: vID, modelID: "m")],
                          proto: .openai, vendors: [openaiVendor])
        let ids2 = rc.modelList(harnessID: hID, proto: .openai).map(\.id)
        check(ids2.contains("glm-b") && ids2.contains("glm-a"), "RT-40 Codex 卡发现＝全部槽位键（含未映射）")
    }

    func testSwapTable() {
        let slot = Slot(clientModelField: "claude-sonnet-5", vendorID: vID, modelID: "m-1")
        let r = mkRouter(["claude-sonnet-5"], [slot], models: [ModelEntry(modelID: "m-1", vendorID: vID),
                                                                ModelEntry(modelID: "m-2", vendorID: vID)])
        check(r.resolve(harnessID: hID, modelField: "claude-sonnet-5")?.modelID == "m-1", "RT-41 换表前命中 m-1")
        let h2 = Harness(id: hID, name: "T卡", proto: .anthropic, accessKeyRef: "kc",
                         tierOrder: ["claude-sonnet-5"],
                         slots: [Slot(clientModelField: "claude-sonnet-5", vendorID: vID, modelID: "m-2")])
        r.swapTable(HarnessTable(config: RouterConfig(endpoint: EndpointSpec(), vendors: [vendor],
                                                      harnesses: [h2],
                                                      models: [ModelEntry(modelID: "m-2", vendorID: vID)])))
        check(r.resolve(harnessID: hID, modelField: "claude-sonnet-5")?.modelID == "m-2", "RT-42 热换表即时生效")
    }

    func testBuildUpstreamStripsHopHeaders() {
        let slot = Slot(clientModelField: "claude-sonnet-5", vendorID: vID, modelID: "m")
        let r = mkRouter(["claude-sonnet-5"], [slot], models: [ModelEntry(modelID: "m", vendorID: vID)])
        KeychainStore.set("k1", value: "sk-test-vendor", domain: .vendor)
        let headers: [(String, String)] = [("authorization", "Bearer client"), ("x-api-key", "client"),
                       ("host", "127.0.0.1:21201"), ("content-length", "10"),
                       ("content-encoding", "gzip"), ("transfer-encoding", "chunked"),
                       ("accept-encoding", "gzip"), ("x-custom", "keep")]
        switch r.buildUpstream(path: "/claude/v1/messages", headers: headers,
                               payload: ["model": "claude-sonnet-5"],
                               harnessID: hID, proto: .anthropic, modelField: "claude-sonnet-5") {
        case .success(let plan):
            let req = plan.request
            check(req.value(forHTTPHeaderField: "x-custom") == "keep", "RT-43 自定义头透传")
            check(req.value(forHTTPHeaderField: "authorization") == nil
                  && req.value(forHTTPHeaderField: "x-api-key") != nil,
                  "RT-44 客户端凭证被剥离并换供应商真 Key")
            check(req.value(forHTTPHeaderField: "host") == nil, "RT-45 host 剥离")
            check(req.value(forHTTPHeaderField: "accept-encoding") == nil,
                  "T2 accept-encoding 剥离（本批修复回归锚）")
        case .failure:
            check(false, "RT-43..46 buildUpstream 应成功")
        }
    }

    func testConfigRepairOrphans() {
        let ghostModel = ModelEntry(modelID: "m-ghost", vendorID: UUID())
        let entry = ModelEntry(modelID: "m-live", vendorID: vID)
        let h = Harness(id: hID, name: "T卡", proto: .anthropic, accessKeyRef: "kc",
                        tierOrder: nil, slots: [Slot(clientModelField: "s")])
        let cfg = RouterConfig(endpoint: EndpointSpec(), vendors: [vendor], harnesses: [h],
                               models: [ghostModel, entry])
        let (fixed, notes) = ConfigRepair.repair(cfg)
        check(!fixed.models.contains { $0.modelID == "m-ghost" }, "RT-47 孤儿模型条目清除")
        check(fixed.models.contains { $0.modelID == "m-live" }, "RT-48 有效条目保留")
        check(notes.contains { $0.code == "I3" }, "RT-49 清理留痕（I3 note）")
    }
}
