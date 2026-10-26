// Codex 配置写入管线测试（原 R8 断言域重建·面向公开仓库）
// 覆盖：①受管区引擎（构建/就绪判定/整区重写自愈/散键收编——含废弃键清除语义）；
// ②思考档位闸门（[desktop] 节内读写与并集校验）；③供应商方言归一化（web_search 剥离）；
// ④模型目录生成；⑤TOML 子集解析器；⑥安全写盘（备份留 5、原子写、仅新建设 0600）。
// 编号前缀 CW＝Codex Writer；历史编号（R25/R21/I14/A4/T 等）为开发期需求/问题单号，保留可追溯。
// 安全相关性：本套件钉住「受管区只写声明范围」「密钥文件权限 0600」「备份不外泄」三条红线——
// 第三方复跑即可验证配置代写的边界与文件安全。
import XCTest
@testable import ModelRouterCore

final class CodexConfigWriterTests: XCTestCase {
    private var pass = 0
    private var fail = 0
    private func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        if cond { pass += 1 } else { fail += 1 }
        XCTAssertTrue(cond, name + (detail.isEmpty ? "" : "  — \(detail)"))
    }
    private func perms(_ p: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int) ?? -1
    }
    private var tmp: String = ""

    override func setUp() {
        super.setUp()
        tmp = NSTemporaryDirectory() + "/mr-r8tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    func testManagedRegion() {
        // R25：新模板不写 preferred_auth_method
        let block = CodexRegion.build(defaultModel: "g-test", baseURL: "http://127.0.0.1:21201/codex", token: "mr-t")
        check(!block.contains("preferred_auth_method"), "R25-1 新区模板无 preferred_auth_method")
        check(block.contains("model = \"g-test\""), "R8-b1 build 含 model 行（设默认模型）")
        check(CodexRegion.build(defaultModel: nil, baseURL: "http://x", token: "t").contains("model =") == false,
              "R8-b2 未设默认模型不写 model 行")
        check(block.contains(CodexRegion.providerHeader) && block.contains("wire_api = \"responses\""),
              "R8-b3 provider 节与 wire_api")
        check(block.contains("experimental_bearer_token = \"mr-t\""), "R8-b4 token 行")

        // 就绪判定
        check(CodexRegion.isSettled(block, defaultModel: "g-test",
                                     baseURL: "http://127.0.0.1:21201/codex", token: "mr-t"),
              "R25-2 新区夹具判就绪")
        let old = block.replacingOccurrences(of: "model_provider", with: "preferred_auth_method = \"apikey\"\nmodel_provider")
        check(!CodexRegion.isSettled(old, defaultModel: "g-test",
                                     baseURL: "http://127.0.0.1:21201/codex", token: "mr-t"),
              "R25-3 区内残留 preferred_auth_method 判未就绪（自愈入口点亮）")
        let healed = CodexRegion.applyQuick(old, defaultModel: "g-test",
                                            baseURL: "http://127.0.0.1:21201/codex", token: "mr-t")
        check(!healed.contains("preferred_auth_method"), "R25-4 整区重写自愈＝键全区消失")
        check(CodexRegion.isSettled(healed, defaultModel: "g-test",
                                     baseURL: "http://127.0.0.1:21201/codex", token: "mr-t"),
              "R25-5 自愈后判就绪")

        // 散键收编
        var stray = "preferred_auth_method = \"apikey\"\n" + block
        stray = CodexRegion.applyQuick(stray, defaultModel: nil, baseURL: "http://x", token: "t")
        check(!stray.contains("preferred_auth_method"), "R25-6 旧版散键经快速配置清除（不回填）")

        // 区定位与替换
        check(CodexRegion.hasRegion(block), "R8-r1 hasRegion")
        let withUser = "# user top\n" + block + "\n\n[other]\nk = 1\n"
        let replaced = CodexRegion.replace(withUser, block: CodexRegion.build(defaultModel: nil, baseURL: "http://y", token: "t2"))
        check(replaced.hasPrefix("# user top\n") && replaced.contains("[other]"), "R8-r2 整区替换保留区外内容")
        check(CodexRegion.values(in: block)?["base_url"] == "http://127.0.0.1:21201/codex", "R8-r3 values 读取平铺")
        check(CodexRegion.defaultModel(in: block) == "g-test", "R8-r4 defaultModel 读取")
        check(CodexRegion.rewriteModelLine(block, from: "g-test", to: "g-new")!.contains("model = \"g-new\""),
              "R8-r5 rewriteModelLine 命中改写")
        check(CodexRegion.rewriteModelLine(block, from: "nope", to: "x") == nil, "R8-r6 值不匹配返回 nil（不动文件）")
        check(Set(CodexRegion.managedTopLevelKeys).isSuperset(of: ["model_provider", "model_catalog_json",
                                                                   "preferred_auth_method", "forced_login_method"]),
              "R8-r7 managedTopLevelKeys 全集")
        // 未设默认模型：区内不应有 model 键（负校验）
        let noModel = CodexRegion.build(defaultModel: nil, baseURL: "http://x", token: "t")
        check(CodexRegion.isSettled(noModel, defaultModel: nil, baseURL: "http://x", token: "t"),
              "R8-r8 未设默认模型就绪")
    }

    func testReasoningGateCoverage() {
        let metaA = #"{"supported_reasoning_levels":[{"effort":"medium"},{"effort":"xhigh"}]}"#
        let metaB = #"{"supported_reasoning_levels":[{"effort":"medium"},{"effort":"high"}]}"#
        check(ReasoningGate.requiredEfforts(metaJSONs: [metaA, metaB]) == ["high", "medium", "xhigh"],
              "R21-1 并集排序稳定")
        check(ReasoningGate.requiredEfforts(metaJSONs: [nil, "not json"]) == [], "R21-2 无元数据/解析失败＝空贡献")
        let toml = "[desktop]\n" + ReasoningGate.presetLine
        check(ReasoningGate.enabledEfforts(toml: toml)?.count == 6, "R21-3 [desktop] 节内读取六档")
        check(ReasoningGate.enabledEfforts(toml: ReasoningGate.presetLine) == nil,
              "R21-4 顶层同名键无效（节语义）")
        check(ReasoningGate.check(toml: toml, metaJSONs: [metaA]) == nil, "R21-5 覆盖并集＝通过")
        let miss = ReasoningGate.check(toml: toml, metaJSONs: [#"{"supported_reasoning_levels":[{"effort":"turbo"}]}"#])
        check(miss?.contains("缺 turbo") == true, "R21-6 未覆盖＝红字含缺失档")
        check(ReasoningGate.check(toml: "", metaJSONs: [metaA])?.contains("未设置") == true, "R21-7 未设置文案")
        check(ReasoningGate.check(toml: "", metaJSONs: [nil]) == nil, "R21-8 无档位需求恒通过")
        // 写入落位
        let inPlace = ReasoningGate.applyPresetEfforts("[desktop]\nother = 1\nenabled-reasoning-efforts = [\"low\"]\n")
        check(inPlace.contains(ReasoningGate.presetLine + "\n") && inPlace.contains("other = 1"),
              "R21-9 节内既有键原位替换")
        let inserted = ReasoningGate.applyPresetEfforts("[desktop]\nother = 1\n")
        check(inserted.contains("other = 1\n" + ReasoningGate.presetLine), "R21-10 节内无键插至末键后")
        check(inserted.hasPrefix("[desktop]"), "R21-11 无节文件尾新建 [desktop]")
        let cleared = ReasoningGate.applyPresetEfforts("enabled-reasoning-efforts = [\"low\"]\n\n[other]\nk = 1\n")
        check(!cleared.hasPrefix("enabled-reasoning-efforts"), "R21-12 顶层散键被清除")
        check(ReasoningGate.presetLine.contains("max"), "R21-13 预设六档含 max")
    }

    func testDialectNormalization() {
        let payload: [String: Any] = [
            "input": [["type": "web_search_call", "action": ["query": "q"]] as [String: Any],
                      ["type": "message", "text": "hi"] as [String: Any]],
            "tools": [["type": "web_search"] as [String: Any], ["type": "local_shell"] as [String: Any]],
        ]
        let deep = CodexDialect.normalize(payload, host: "API.DEEPSEEK.COM")
        let input = deep["input"] as? [[String: Any]] ?? []
        check(!input.contains { $0["type"] as? String == "web_search_call" }, "I14-1 DeepSeek：web_search_call 剥离")
        let tools = deep["tools"] as? [[String: Any]] ?? []
        check(!tools.contains { $0["type"] as? String == "web_search" } && tools.count == 1,
              "I14-2 web_search 工具声明剥离（保留其余）")
        let untouched = CodexDialect.normalize(payload, host: "https://api.other.com/v1")
        check((untouched["input"] as? [Any])?.count == 2, "I14-3 无匹配 host 原样返回")
        let emptyTools: [String: Any] = ["tools": [["type": "web_search"] as [String: Any]]]
        var p = emptyTools
        CodexDialect.stripWebSearch(&p)
        check(p["tools"] == nil, "I14-4 tools 清空则整键移除")
        let q: [String: Any] = ["input": [["type": "web_search_call", "action": ["query": "q"]] as [String: Any]]]
        var q2 = q
        CodexDialect.normalizeWebSearchQueries(&q2)
        let act = ((q2["input"] as? [[String: Any]])?.first)?["action"] as? [String: Any]
        check(act?["queries"] as? [String] == ["q"] && act?["query"] == nil, "I14-5 query 单数→queries 数组")
    }

    func testCatalogGeneration() {
        let e = CodexCatalog.minimalEntry(slug: "g-test", displayName: "g-test")
        check(e["slug"] as? String == "g-test" && e["display_name"] as? String == "g-test", "R8-c1 最小条目 slug/display_name")
        check(e["context_window"] as? Int == 262144, "R8-c2 默认上下文窗")
        check(e["input_modalities"] as? [String] == ["text"], "R8-c3 默认纯文本模态")
        let img = CodexCatalog.minimalEntry(slug: "v", displayName: "v", imageInput: true)
        check((img["input_modalities"] as? [String])?.contains("image") == true, "R8-c4 图像输入模态")
        let meta = #"{"supported_reasoning_levels":[{"effort":"high","summary":"H"}],"supported_tiers":["flex","priority"]}"#
        let full = CodexCatalog.entry(name: "g-full", metaJSON: meta)
        check(full["display_name"] as? String == "g-full", "R8-c5 元数据条目名称字面直用")
        let cat = CodexCatalog.generate(added: ["g-test"], metaJSON: { _ in meta })
        let models = cat["models"] as? [[String: Any]] ?? []
        check(models.first?["slug"] as? String == "g-test", "R8-c6 generate 外层 models 数组")
        let text = CodexCatalog.prettyText(added: ["a", "b"], metaJSON: { _ in nil })
        check(text.contains("\"slug\" : \"a\""), "R8-c7 prettyText 含条目（pretty 格式）")
        check(CodexCatalog.slugs(inJSON: text) == ["a", "b"], "R8-c8 slugs 反解析")
    }

    func testTomlParser() {
        let doc = try? TomlLite.parse("""
        top = \"v\"
        n = 5
        b = true
        arr = [1, \"two\", true]
        [sec]
        k = \"sv\"
        [sec.deep]
        dk = 2
        """)
        check(doc?["top"] as? String == "v", "T-1 顶层字符串")
        check(doc?["n"] as? Int == 5, "T-2 整数")
        check(doc?["b"] as? Bool == true, "T-3 布尔")
        check((doc?["arr"] as? [Any])?.count == 3, "T-4 数组")
        let sec = doc?["sec"] as? [String: Any]
        check(sec?["k"] as? String == "sv", "T-5 表节")
        check((sec?["deep"] as? [String: Any])?["dk"] as? Int == 2, "T-6 嵌套表")
        check((try? TomlLite.parse("[a]\n[a]")) == nil, "T-7 重复表定义报错")
        check((try? TomlLite.parse("k =")) == nil, "T-8 键缺值报错")
        check((try? TomlLite.parse("= v")) == nil, "T-9 缺键报错")
    }

    func testSafeFileWriting() {
        let p1 = tmp + "/new.json"
        check(SafeFileWriter.write(Data("{}".utf8), to: p1), "A4-1 新建写入成功")
        check(perms(p1) == 0o600, "A4-2 新建文件 0600")
        let p2 = tmp + "/keep.json"
        FileManager.default.createFile(atPath: p2, contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
        check(SafeFileWriter.write(Data("y".utf8), to: p2), "A4-3 既有文件写入成功")
        check(perms(p2) == 0o644, "A4-4 既有权限保持 0644")
        check(SafeFileWriter.write(Data("y".utf8), to: p2, pinMode: .always), "A4-5 always 写入成功")
        check(perms(p2) == 0o600, "A4-6 always 收紧到 0600")
        for i in 0..<7 {
            Thread.sleep(forTimeInterval: 1.1)
            try? "v\(i)".write(toFile: p1, atomically: true, encoding: .utf8)
            _ = SafeFileWriter.backup(file: p1, reason: "pre-test")
        }
        let baks = ((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []).filter { $0.hasSuffix(".bak") }
        check(baks.count == 5, "A4-7 备份只留 5 份")
        check(perms(tmp + "/" + (baks.first ?? "")) == 0o600, "A4-8 备份文件 0600")

        let csDir = tmp + "/claude"
        try? FileManager.default.createDirectory(atPath: csDir, withIntermediateDirectories: true)
        let cs = ClaudeSettingsStore(path: csDir + "/settings.json", backupDir: tmp + "/claude-bak")
        check(cs.save(["env": ["ANTHROPIC_AUTH_TOKEN": "mr-test"]]), "A4-9 settings.json 新建保存成功")
        check(perms(csDir + "/settings.json") == 0o600, "A4-10 settings.json 新建 0600（T4 修复）")
        let cs2p = csDir + "/settings2.json"
        FileManager.default.createFile(atPath: cs2p, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644])
        let cs2 = ClaudeSettingsStore(path: cs2p, backupDir: tmp + "/claude-bak")
        check(cs2.save(["env": [:]]), "A4-11 settings2 保存成功")
        check(perms(cs2p) == 0o644, "A4-12 settings2 既有权限保持")

        let cx = CodexConfigStore(path: tmp + "/codex/config.toml",
                                  catalogPath: tmp + "/codex/catalog.json",
                                  backupDir: tmp + "/codex-bak")
        try? FileManager.default.createDirectory(atPath: tmp + "/codex", withIntermediateDirectories: true)
        check(!cx.save("this is [ not toml"), "A4-13 非法 TOML 拒绝写入")
        check(!FileManager.default.fileExists(atPath: tmp + "/codex/config.toml"), "A4-14 拒写时未产生文件")
        check(cx.save("[model_providers.mr]\nbase_url = \"http://x\"\nwire_api = \"responses\"\n"), "A4-15 合法 TOML 保存成功")
        check(perms(tmp + "/codex/config.toml") == 0o600, "A4-16 config.toml 新建 0600")
        XCTAssertTrue(fail == 0, "Codex 配置写入套件存在失败项：\(fail)")
    }
}
