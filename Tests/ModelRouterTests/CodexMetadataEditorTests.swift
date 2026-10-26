// Codex 元数据编辑器测试（原 S3 断言台移植重命名·面向公开仓库）
// 覆盖：①档位选项十态；②未知结构容错（assembleBaseEntry 纯函数）；③参数字典命中/候选/增补
// （UserMetaDict）；④字典 51 条基准与控件形态；⑤行内层级呈现与编解码往返；⑥类型不符保真
// （不偷换用户值）。编号前缀 CM＝Codex Metadata；段字母 B/C/D/A/I/J 沿用原分域。
// 安全相关性：未知字段永不静默丢弃/改写——第三方可用本套件验证「代写配置不越权改动用户数据」。

import XCTest
import AppKit
import SwiftUI
@testable import ModelRouter
import ModelRouterCore

final class CodexMetadataEditorTests: XCTestCase {
    private var pass = 0
    private var fail = 0
    private func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        if cond { pass += 1 } else { fail += 1 }
        XCTAssertTrue(cond, name + (detail.isEmpty ? "" : "  — \(detail)"))
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        UserMetaDict.shared.persist = false   // 测试不落盘
    }

    func testMetadataEditorSuite() throws {
        func jobj(_ s: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
        }

// ───────────────────────── B：档位选项十态 ─────────────────────────

check(CodexMetadataWindow.tierOptions.count == 10, "CM-B1 tierOptions 十态",
      "实为 \(CodexMetadataWindow.tierOptions)")
check(CodexMetadataWindow.tierOptions.contains("persistent"), "CM-B2 补 persistent")
check(CodexMetadataWindow.tierOptions.contains("custom"), "CM-B3 补 custom")
check(CodexMetadataWindow.tierOptions.first == "none" && CodexMetadataWindow.tierOptions[6] == "ultra",
      "CM-B4 原八档次序不回归（none…ultra）")

// ───────────────────────── C：未知容错后端（assembleBaseEntry 直驱） ─────────────────────────

let sample: [String: Any] = [
    "slug": "old-name", "display_name": "old-name",
    "context_window": 1048576,                          // basicKeys
    "priority": 1,                                      // 已知·非基础（现字典有）
    "experimental_routing_hints": ["a" as Any],         // 未知键（对象值亦可）
    "reasoning_style": "balanced",                      // 未知键（标量）
]

let keptAll = CodexMetadataWindow.assembleBaseEntry(original: sample, advanced: false,
                                                    rowKeys: [], unknownEdits: [:], unknownRemoved: [])
check(keptAll["experimental_routing_hints"] != nil && keptAll["reasoning_style"] != nil,
      "CM-C1 高级关：未知键原样保留（R23 核心）")
check(keptAll["priority"] != nil, "CM-C2 高级关：已知非基础键未成行不丢（用户未触及）")

let advNoRows = CodexMetadataWindow.assembleBaseEntry(original: sample, advanced: true,
                                                      rowKeys: [], unknownEdits: [:], unknownRemoved: [])
check(advNoRows["priority"] == nil, "CM-C3 高级开：已知键无行即删（行是全部事实）")
check(advNoRows["experimental_routing_hints"] != nil && advNoRows["reasoning_style"] != nil,
      "CM-C4 高级开：未知键仍保留（不受行集合影响）")
check(advNoRows["slug"] != nil && advNoRows["display_name"] != nil && advNoRows["context_window"] != nil,
      "CM-C5 接管键与 basicKeys 永不被高级删枝")

let advWithRow = CodexMetadataWindow.assembleBaseEntry(original: sample, advanced: true,
                                                       rowKeys: ["priority"], unknownEdits: [:], unknownRemoved: [])
check(advWithRow["priority"] != nil, "CM-C6 高级开：成行已知键保留")

let edited = CodexMetadataWindow.assembleBaseEntry(original: sample, advanced: false, rowKeys: [],
                                                   unknownEdits: ["reasoning_style": "deep"], unknownRemoved: [])
check((edited["reasoning_style"] as? String) == "deep", "CM-C7 未知键编辑覆盖生效")

let removed = CodexMetadataWindow.assembleBaseEntry(original: sample, advanced: false, rowKeys: [],
                                                    unknownEdits: [:], unknownRemoved: ["reasoning_style"])
check(removed["reasoning_style"] == nil && removed["experimental_routing_hints"] != nil,
      "CM-C8 未知键移除只作用目标键")

// ───────────────────────── D：未知容错静态面 ─────────────────────────

check(CodexMetadataWindow.isKnownParam("priority"), "CM-D1 内置字典命中")
check(!CodexMetadataWindow.isKnownParam("reasoning_style"), "CM-D2 未知键未命中")

UserMetaDict.shared.upsert(MetaParam(key: "reasoning_style", zh: "推理风格", group: "用户增补",
                                     desc: "断言用", inferred: false, control: .text(""),
                                     howTo: "断言用", status: .active, parentPath: nil))
check(CodexMetadataWindow.isKnownParam("reasoning_style"), "CM-D3 用户增补后转命中（未命中区上移）")
check(!UserMetaDict.shared.canAdd(key: "priority", parentPath: nil), "CM-D4 与内置同名禁止")
check(UserMetaDict.shared.canAdd(key: "reasoning_style", parentPath: "model_messages"), "CM-D5 同名不同层级允许")

let advAfterSupplement = CodexMetadataWindow.assembleBaseEntry(original: sample, advanced: true,
                                                               rowKeys: [], unknownEdits: [:], unknownRemoved: [])
check(advAfterSupplement["reasoning_style"] == nil,
      "CM-D6 增补条目按已知参与高级删枝（无行即删）")

let candidates = CodexMetadataWindow.collectUnknownCandidates([
    "slug": "x", "display_name": "x", "priority": 1,
    "future_flag": true,
    "model_messages": ["instructions_template": "You are…", "weird_sub": 3] as [String: Any],
])
let candKeys = candidates.map(\.key)
check(candKeys.contains("future_flag") && (candidates.first(where: { $0.key == "future_flag" })?.parentPath ?? "?") == "",
      "CM-D7 顶层未命中入选候选（parentPath 空）")
check(candKeys.contains("weird_sub") && (candidates.first(where: { $0.key == "weird_sub" })?.parentPath ?? "?") == "model_messages",
      "CM-D8 已文档化父内未知子键下钻入选")
check(!candKeys.contains("instructions_template"), "CM-D9 已知子键不进候选")

let mmKeys = MetaKnownShapes.orderedKeys([
    "zz_unknown": 1, "instructions_template": "s", "token_budget": ["enabled": false] as [String: Any],
] as [String: Any], path: "model_messages")
check(mmKeys.first == "instructions_template" && mmKeys.last == "zz_unknown",
      "CM-D10 model_messages 子键已知在前（文档序）、未命中沉底（路径化）")

let jsonText = "{\"b\":true,\"n\":1,\"s\":\"x\",\"null\":null,\"o\":{\"k\":1}}"
let parsed = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any] ?? [:]
check(mrIsBool(parsed["b"] ?? 0) && !mrIsBool(parsed["n"] ?? 0),
      "CM-D11 布尔/数字判定（__NSCFBoolean 区分，1 不误判 true）")
check(mrShapeSummary(parsed["o"] ?? 0).hasPrefix("对象 · 1 键")
      && mrShapeSummary(parsed["n"] ?? 0).hasPrefix("数字")
      && mrShapeSummary(parsed["null"] ?? 0) == "null · 未设置",
      "CM-D12 形态摘要（对象/数字/null）")

UserMetaDict.shared.remove(key: "reasoning_style", parentPath: nil)
check(!CodexMetadataWindow.isKnownParam("reasoning_style"), "CM-D14 增补删除后回到未命中")

// ───────────────────────── A：字典 51 条基准（已合入） ─────────────────────────

check(MetaParamDict.all.count == 51, "CM-A1 条数 51", "实为 \(MetaParamDict.all.count)")
check(Set(MetaParamDict.all.map(\.key)).count == 51, "CM-A2 无重复 key")
let nIgnored = MetaParamDict.all.filter { $0.status == .ignored }.count
let nLocal = MetaParamDict.all.filter { $0.status == .localOnly }.count
check(nIgnored == 6 && nLocal == 2, "CM-A3 status 分布 43/6/2", "ignored=\(nIgnored) localOnly=\(nLocal)")
let laggingKeys: Set<String> = ["available_in_plans", "minimal_client_version", "prefer_websockets",
                                "requires_sandboxed_review", "supports_parallel_tool_calls", "supports_reasoning_summaries"]
check(Set(MetaParamDict.all.filter { $0.status == .ignored }.map(\.key)) == laggingKeys, "CM-A4 滞后 6 精确集合")
check(Set(MetaParamDict.all.filter { $0.status == .localOnly }.map(\.key)) == ["base_instructions", "reasoning_summary_format"],
      "CM-A5 独有 2 精确集合")
check(MetaParamDict.all.contains { $0.key == "effective_context_window_percent" && $0.status == .active },
      "CM-A6 effective_context_window_percent 属可写 43（升格官方实有）")

func pickerOpts(_ k: String) -> [String]? {
    guard let p = MetaParamDict.all.first(where: { $0.key == k }),
          case .picker(let opts, _) = p.control else { return nil }
    return opts
}
check(pickerOpts("visibility") == ["list", "hide", "none"], "CM-A7 visibility 三值（修 hidden 错拼）")
check(pickerOpts("shell_type") == ["unified_exec", "disabled"], "CM-A8 shell_type 权威两值")
check(pickerOpts("apply_patch_tool_type") == ["freeform"], "CM-A9 apply_patch 仅 freeform（剔 function）")
check(pickerOpts("web_search_tool_type") == ["text", "text_and_image"], "CM-A10 web_search 枚举化")
check(pickerOpts("tool_mode") == ["direct", "code_mode", "code_mode_only"], "CM-A11 tool_mode 枚举化")
if let p = MetaParamDict.all.first(where: { $0.key == "truncation_policy" }),
   case .modeNumber(let opts, _, _) = p.control {
    check(opts == ["bytes", "tokens"], "CM-A12 truncation.mode 权威两值（剔 auto/rolling/none）")
} else {
    check(false, "CM-A12 truncation.mode", "控件形态缺失")
}
check(MetaParamDict.all.allSatisfy { MetaParamDict.groups.contains($0.group) }, "CM-A13 分组合法（全部条目）")

func isBasicControl(_ p: MetaParam) -> Bool {
    if case .basic = p.control { return true }
    return false
}
check(MetaParamDict.basicKeys.allSatisfy { k in
    MetaParamDict.all.contains { $0.key == k && isBasicControl($0) }
}, "CM-A14 basic 四项控件形态")
check(MetaParamDict.all.filter { $0.status == .active }.allSatisfy { !$0.zh.isEmpty && !$0.desc.isEmpty },
      "CM-A15 active 条目文案非空")
check(MetaParamDict.all.contains { $0.key == "service_tiers" } && MetaParamDict.all.contains { $0.key == "guardian" }
      && MetaParamDict.all.contains { $0.key == "additional_speed_tiers" },
      "CM-A16 新增三复杂字段入典（service_tiers/guardian/additional_speed_tiers）")

// ───────────────────────── I：R23 二轮·行内层级呈现（管理员呈现形式指正） ─────────────────────────

func controlKind(_ k: String) -> String {
    guard let p = MetaParamDict.all.first(where: { $0.key == k }) else { return "无条目" }
    switch p.control {
    case .stringList: return "stringList"
    case .structure: return "structure"
    case .structureList: return "structureList"
    case .text: return "text"
    case .longText: return "longText"
    case .basic: return "basic"
    case .toggle: return "toggle"
    case .number: return "number"
    case .picker: return "picker"
    case .modeNumber: return "modeNumber"
    }
}
check(controlKind("experimental_supported_tools") == "stringList", "CM-I1 实验工具＝字符串数组行内标签（不再结构化小窗）")
check(controlKind("additional_speed_tiers") == "stringList", "CM-I2 附加速度档＝字符串数组行内标签")
check(controlKind("model_messages") == "structure", "CM-I3 model_messages＝对象行内层级展开")
check(controlKind("guardian") == "structure" && controlKind("upgrade") == "structure"
      && controlKind("availability_nux") == "structure", "CM-I4 guardian/upgrade/NUX＝对象行内层级")
check(controlKind("service_tiers") == "structureList", "CM-I5 service_tiers＝对象数组行内递归")

func listVal(_ v: CodexMetadataWindow.ParamValue) -> [String]? { if case .list(let l) = v { return l }; return nil }
func objVal(_ v: CodexMetadataWindow.ParamValue) -> [String: Any]? { if case .object(let d) = v { return d }; return nil }
func CodexDictListEncodeEmpty() -> Any? {
    let p = MetaParamDict.all.first { $0.key == "experimental_supported_tools" }!
    return CodexMetadataWindow.encodeValue(p, .list(["a", "", "b"]))
}
let est = MetaParamDict.all.first { $0.key == "experimental_supported_tools" }!
check(listVal(CodexMetadataWindow.decodeValue(est, ["send_user_message_async", "clock"] as [Any]))
      == ["send_user_message_async", "clock"], "CM-I6 字符串数组识别回填落 .list（行内标签）")
let mm = MetaParamDict.all.first { $0.key == "model_messages" }!
let mmSample: [String: Any] = ["instructions_template": "You are…", "approvals": NSNull()]
let decodedMM = CodexMetadataWindow.decodeValue(mm, mmSample)
check(objVal(decodedMM) != nil, "CM-I7 对象识别回填落 .object（行内层级）")
let encodedBack = CodexMetadataWindow.encodeValue(mm, decodedMM)
check((encodedBack as? [String: Any])?["instructions_template"] as? String == "You are…",
      "CM-I8 对象编解码往返保真（生成原样写回）")
check((CodexMetadataWindow.encodeValue(est, .list(["a", "b"]))) as? [String] == ["a", "b"],
      "CM-I9 .list 编码直出 JSON 数组")
check((CodexDictListEncodeEmpty()) as? [String] == ["a", "b"],
      "CM-I13 逐项行留空＝未完成项，生成时剔除")
let defMM = CodexMetadataWindow.defaultParamValue(mm)
check(objVal(defMM) != nil, "CM-I10 .structure 默认值＝空对象（添加即行内展开）")
let deepOrder = MetaKnownShapes.orderedKeys(["rejection_instructions": 1, "policy": 2, "policy_template": 3] as [String: Any],
                                            path: "model_messages.auto_review")
check(deepOrder == ["policy", "policy_template", "rejection_instructions"],
      "CM-I11 二层路径已知序（model_messages.auto_review 文档序优先）")
let mmObj = (try? JSONSerialization.jsonObject(with: Data("{\"zz\":1,\"instructions_template\":\"s\"}".utf8))) as? [String: Any] ?? [:]
check(MetaKnownShapes.orderedKeys(mmObj, path: "model_messages") == ["instructions_template", "zz"],
      "CM-I12 未命中子键沉底不回归")

// ───────────────────────── J：R23 五轮·完备性（类型不符不偷换值） ─────────────────────────

func textOf(_ v: CodexMetadataWindow.ParamValue?) -> String? {
    guard let v = v else { return nil }
    if case .text(let s) = v { return s }
    return nil
}
func numOf(_ v: CodexMetadataWindow.ParamValue?) -> String? {
    guard let v = v else { return nil }
    if case .number(let s) = v { return s }
    return nil
}

let toolModeParam = MetaParamDict.all.first { $0.key == "tool_mode" }!
check(textOf(CodexMetadataWindow.decodeValue(toolModeParam, 5 as NSNumber)) == "5",
      "CM-J1 枚举遇数字→降级文本保真（不套默认）")
check(CodexMetadataWindow.encodeValue(toolModeParam, .text("5")) as? String == "5",
      "CM-J2 降级文本回写保真（不丢键）")
check({ if case .picker("code_mode") = CodexMetadataWindow.decodeValue(toolModeParam, "code_mode") { return true }; return false }(),
      "CM-J3 枚举遇字符串仍走枚举（正常值不回归）")
let preferParam = MetaParamDict.all.first { $0.key == "prefer_websockets" }!
check(textOf(CodexMetadataWindow.decodeValue(preferParam, "yes")) == "yes",
      "CM-J4 布尔遇字符串→降级文本保真")
check({ if case .toggle(true) = CodexMetadataWindow.decodeValue(preferParam, true as NSNumber) { return true }; return false }(),
      "CM-J5 布尔遇布尔仍走开关（正常值不回归）")
let maxCWParam = MetaParamDict.all.first { $0.key == "max_context_window" }!
check(textOf(CodexMetadataWindow.decodeValue(maxCWParam, "abc")) == "abc",
      "CM-J6 数字遇非数值→降级文本保真")
check(numOf(CodexMetadataWindow.decodeValue(maxCWParam, 872000 as NSNumber)) == "872000",
      "CM-J7 数字遇数字仍走数字框（正常值不回归）")
let truncParam = MetaParamDict.all.first { $0.key == "truncation_policy" }!
check(textOf(CodexMetadataWindow.decodeValue(truncParam, "auto")) == "auto",
      "CM-J8 模式+数值遇字符串→降级文本保真（不重建对象）")
check({ if case .object(let d) = CodexMetadataWindow.decodeValue(truncParam, ["mode": "bytes", "limit": 10000] as [String: Any]) {
        return (d["mode"] as? String) == "bytes" && (d["limit"] as? Int) == 10000
    }; return false }(),
      "CM-J9 模式+数值遇对象→行内结构保真（mode/limit 原样，退格行呈现）")

        XCTAssertTrue(fail == 0, "元数据编辑器套件存在失败项：\(fail)（共 \(pass + fail) check）")
    }
}
