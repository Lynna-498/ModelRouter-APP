import Foundation

// MARK: - 接入协议（全局仅此两种，由请求路径前缀决定）
public enum Proto: String, Codable {
    case anthropic  // /anthropic/*（Claude 侧，对应 /v1/messages）
    case openai     // /codex/*（Codex 侧，对应 /v1/responses；chat/completions 一律拒绝）
}

// MARK: - 持久层模型（config.json 单一真源；厂商真 Key 只存 Keychain/Key 文件，keyRef 指向）
public struct Vendor: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var keyRef: String              // Key 存储条目名；两种协议共用同一把厂商真 Key
    public var anthropicBase: URL?         // 有值须以 /anthropic 结尾
    public var openaiBase: URL?            // 有值须以 /v1 等版本段结尾
    public var anthropicURLSupport: Bool?  // Anthropic baseURL 存在性检查结论（nil=未检测；false=不可达）
    public var openaiURLSupport: Bool?     // OpenAI baseURL 存在性检查结论（同上）；跟随供应商走

    public init(id: UUID = UUID(),
                name: String,
                keyRef: String,
                anthropicBase: URL? = nil,
                openaiBase: URL? = nil,
                anthropicURLSupport: Bool? = nil,
                openaiURLSupport: Bool? = nil) {
        self.id = id
        self.name = name
        self.keyRef = keyRef
        self.anthropicBase = anthropicBase
        self.openaiBase = openaiBase
        self.anthropicURLSupport = anthropicURLSupport
        self.openaiURLSupport = openaiURLSupport
    }
}

public struct Slot: Codable {
    public var clientModelField: String    // 客户端请求 body.model 的原值（查映射的键）
    public var vendorID: UUID?             // 与 modelID 同生同灭；均 nil = 未映射
    public var modelID: String?            // 厂商真实模型 ID（出站 model）
    public var locked: Bool?               // 模型锁定（仅单行生效）：锁定后该行「请求的模型」不可改，供应商仍可改
    public var userAdded: Bool?            // R16①：经添加模型位注册＝用户添加（豁免启动弃用检查）；nil＝原生

    public init(clientModelField: String, vendorID: UUID? = nil, modelID: String? = nil, locked: Bool? = nil,
                userAdded: Bool? = nil) {
        self.clientModelField = clientModelField
        self.vendorID = vendorID
        self.modelID = modelID
        self.locked = locked
        self.userAdded = userAdded
    }

    public var isMapped: Bool { vendorID != nil && modelID != nil }
}

public struct Harness: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var proto: Proto
    public var accessKeyRef: String        // Key 存储条目名（本地访问 Key，每卡一把）
    public var tierOrder: [String]?        // Claude 卡：原生模型 ID 从高到低（下位替代档序）；Codex 卡：nil
    public var enabled: Bool?              // 路由开关，nil 视为 true
    public var universal: Bool?            // 通用路由卡（无槽位、VENDOR/MODEL 直通、双协议一把 Key），nil = false
    public var slots: [Slot]               // Codex 卡：clientModelField = 模型名称（slug=display_name；R8 纯派生架构）

    public init(id: UUID = UUID(),
                name: String,
                proto: Proto,
                accessKeyRef: String,
                tierOrder: [String]? = nil,
                enabled: Bool? = true,
                universal: Bool? = nil,
                slots: [Slot] = []) {
        self.id = id
        self.name = name
        self.proto = proto
        self.accessKeyRef = accessKeyRef
        self.tierOrder = tierOrder
        self.enabled = enabled
        self.universal = universal
        self.slots = slots
    }
}

public struct EndpointSpec: Codable {
    public var host: String = "127.0.0.1"   // 固定回环，不对外监听
    public var port: Int = K.defaultPort

    public init(host: String = "127.0.0.1", port: Int = K.defaultPort) {
        self.host = host
        self.port = port
    }
}

// MARK: - 模型库条目（模型 ID × 供应商；codexMetaJSON 是 Codex 接入的元数据凭证）
public struct ModelEntry: Codable, Identifiable {
    public let id: UUID
    public var modelID: String              // 厂商真实模型 ID（出站 model）
    public var vendorID: UUID
    public var displayName: String?         // 展示名，nil 回落 modelID
    public var codexSlug: String?           // Codex 请求的 model 字段（从 codexMetaJSON 提取）；有值 → OpenAI 侧可用
    public var codexMetaJSON: String?       // models.json 单条原始 JSON（无损保存，生成 models.json 时原样回吐）
    public var probeResults: [String: Bool]? // 最近一次 API 检测结论（键：messages / responses / completions；true=测通）
    public var probedAt: String?            // 检测时间（ISO8601）
    public var tested: Bool?                // 是否跑过真实检测/手动认定；nil/false=未检测（黄），true=已认定（灰/亮）

    public init(id: UUID = UUID(),
                modelID: String,
                vendorID: UUID,
                displayName: String? = nil,
                codexSlug: String? = nil,
                codexMetaJSON: String? = nil,
                probeResults: [String: Bool]? = nil,
                probedAt: String? = nil,
                tested: Bool? = nil) {
        self.id = id
        self.modelID = modelID
        self.vendorID = vendorID
        self.displayName = displayName
        self.codexSlug = codexSlug
        self.codexMetaJSON = codexMetaJSON
        self.probeResults = probeResults
        self.probedAt = probedAt
        self.tested = tested
    }

    public var displayLabel: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return modelID
    }

    /// 名称组键（默认来源存储/模型管理分组共用此规则；I5：身份即条目自身，禁止由 modelID 反查他条目猜测）
    public var groupKey: String { displayLabel }

    // MARK: - 三条 API 线的支持布尔（徽标只在 true 时亮起；存储载体是 probeResults）
    public var messagesAPISupport: Bool? {
        get { probeResults?["messages"] }
        set { setSupport("messages", newValue) }
    }
    public var responsesAPISupport: Bool? {
        get { probeResults?["responses"] }
        set { setSupport("responses", newValue) }
    }
    public var completionsAPISupport: Bool? {
        get { probeResults?["completions"] }
        set { setSupport("completions", newValue) }
    }

    private mutating func setSupport(_ key: String, _ v: Bool?) {
        var r = probeResults ?? [:]
        r[key] = v   // 可选下标：赋 nil 即删除该键
        probeResults = r.isEmpty ? nil : r
    }
}

public struct RouterConfig: Codable {
    public var version: Int = 1
    public var endpoint: EndpointSpec
    public var vendors: [Vendor]
    public var harnesses: [Harness]
    public var models: [ModelEntry]         // 模型库
    /// 模型名称组键（displayName ?? modelID）→ 每条 API 线独立的默认来源供应商
    /// （内层键：messages / responses / completions）
    public var defaultSourcesByAPI: [String: [String: UUID]] = [:]

    enum CodingKeys: String, CodingKey {
        case version, endpoint, vendors, harnesses, models
        case defaultSourcesByAPI
        case legacyDefaultSources = "defaultSources"   // 旧版单值布局，仅解码迁移用
    }

    public init(version: Int = 1,
                endpoint: EndpointSpec = EndpointSpec(),
                vendors: [Vendor] = [],
                harnesses: [Harness] = [],
                models: [ModelEntry] = [],
                defaultSourcesByAPI: [String: [String: UUID]] = [:]) {
        self.version = version
        self.endpoint = endpoint
        self.vendors = vendors
        self.harnesses = harnesses
        self.models = models
        self.defaultSourcesByAPI = defaultSourcesByAPI
    }

    // 兼容旧 config：任一字段缺失不报错，回落默认值（models 缺失 → 空模型库）。
    // 旧版 defaultSources（组键 → 单供应商）迁移为三线同值，保持既有自动填行为。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.endpoint = try c.decodeIfPresent(EndpointSpec.self, forKey: .endpoint) ?? EndpointSpec()
        self.vendors = try c.decodeIfPresent([Vendor].self, forKey: .vendors) ?? []
        self.harnesses = try c.decodeIfPresent([Harness].self, forKey: .harnesses) ?? []
        self.models = try c.decodeIfPresent([ModelEntry].self, forKey: .models) ?? []
        if let byAPI = try c.decodeIfPresent([String: [String: UUID]].self, forKey: .defaultSourcesByAPI) {
            self.defaultSourcesByAPI = byAPI
        } else if let legacy = try c.decodeIfPresent([String: UUID].self, forKey: .legacyDefaultSources) {
            self.defaultSourcesByAPI = legacy.mapValues {
                ["messages": $0, "responses": $0, "completions": $0]
            }
        } else {
            self.defaultSourcesByAPI = [:]
        }
    }

    /// 只写新键；legacyDefaultSources 仅用于解码迁移
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(vendors, forKey: .vendors)
        try c.encode(harnesses, forKey: .harnesses)
        try c.encode(models, forKey: .models)
        try c.encode(defaultSourcesByAPI, forKey: .defaultSourcesByAPI)
    }
}

// MARK: - 全局常量
public enum K {
    public static let defaultPort = 21201
    public static let keyPrefix = "mr-"           // 本地访问 Key 前缀
    public static let keyHexLen = 32              // 随机段长度（32 个十六进制字符）
    public static let anthropicSuffix = "/anthropic"
    public static let openaiVersionRegex = #"/v\d+$"#
    public static let upstreamIdleTimeout: TimeInterval = 300      // 上游空闲超时（首包等待/思考时间；SSE 数据到达会重置）
    public static let upstreamResourceTimeout: TimeInterval = 3600 // 上游总时长上限（长对话流式生成可远超 60s，不可用短超时）
    public static let maxHeaderBytes = 65_536              // 请求头部缓冲上限（未见到头结束符前）
    public static let maxBodyBytes = 50 * 1_048_576        // 请求体上限 50MB（万 Token 级对话远小于此）
    public static let maxConnections = 64                  // 并发下游连接上限
    public static let requestAbsoluteDeadline: TimeInterval = 600  // 请求收齐阶段绝对时限（防滴漏式慢速占用）
    public static let claudeKeyRef = "modelrouter-claude"   // Claude 卡访问 Key 的存储条目名
    public static let codexKeyRef = "modelrouter-codex"     // Codex 卡访问 Key 的存储条目名
    public static let universalKeyRef = "modelrouter-universal" // 通用路由卡访问 Key（两个 baseURL 共用一把）
    // Claude 四个原生默认模型 ID（R28：Mythos 仍只经「添加模型位」注册，不进默认档）
    public static let claudeTierOrder = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    // 存量默认档一次性升级映射：仅迁移未被用户添加标记的旧原生档，映射/锁定保留
    public static let claudeDefaultUpgrade = [
        "claude-fable-5": "claude-fable-5-1",
        "claude-opus-5": "claude-opus-5-5",
        "claude-sonnet-5": "claude-sonnet-5-5",
        "claude-haiku-4-5": "claude-haiku-5-5",
    ]
    // 自定义注册可选定位段（高→低）。Haiku 只经官方预设直选，不开放自定义定位。
    public static let claudeCustomPositions = ["-mythos", "-fable", "-opus", "-sonnet"]
    // ID 解析需要的全定位段（含 -haiku，用于官方 Haiku 预设复用注册通路）
    public static let claudePositions = ["-mythos", "-fable", "-opus", "-sonnet", "-haiku"]
    public static let claudeSuffixExample = "-5-1"
    // R16① 固化数据：官方支持模型 ID 集（扁平无分组；日期段剥离；sonnet-4-5 已弃用不入集）。
    // 弃用判定唯一事实源：档位 ID（剥尾部日期段）未命中＝不受支持。
    public static let anthropicSupported: Set<String> = [
        "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5",
        "claude-haiku-5-5", "claude-haiku-4-5",
        "claude-mythos-5-1", "claude-mythos-5",
        "claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8",
        "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-4-5",
    ]
    // 「添加模型位」预设清单（扁平；4.8 之后；Haiku 5.5/4.5 提供删除后的官方恢复入口）
    public static let anthropicOfferable = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5",
                                            "claude-haiku-5-5", "claude-haiku-4-5",
                                            "claude-mythos-5-1", "claude-mythos-5",
                                            "claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8"]
}

// MARK: - 路由错误（描述文本原样回传给客户端，透明失败）
public enum RouterError: Error, CustomStringConvertible {
    case unknownPath                 // 路径前缀不合法
    case missingKey                  // 请求无 Authorization 头
    case unknownKey                  // Key 不命中任何 Harness
    case protoMismatch               // Key 与路径协议不匹配
    case baseURLMismatch             // Key 与 baseURL 不匹配（R3：各卡 Key 仅在其下发 baseURL 生效）
    case noMapping                   // 未映射且下位无可降
    case noAnthropicBase             // 供应商无 Anthropic 端点
    case noOpenAIBase                // 供应商无 OpenAI 端点
    case noVendorKey                 // Key 存取不到厂商真 Key
    case badBody                     // body 非 JSON 或无 model 字段
    case upstream(String)            // 上游连接失败（DNS/拒连/超时）
    case routingDisabled             // 该 Harness 路由开关已关
    case universalBadModel           // 通用路由：model 不是 VENDOR/MODEL 形态
    case universalNotFound(String)   // 通用路由：供应商或模型未在 ModelRouter 配置
    case pathTraversal               // 请求路径含路径穿越段（.. 及编码变体），已拒绝
    case methodNotAllowed            // 方法不在白名单（GET 模型发现 / POST 转发之外）
    case bodyTooLarge                // 请求体超过上限
    case badFraming                  // Content-Length/Transfer-Encoding 冲突或非法
    case badHost                     // Host 头非本地回环地址

    public var description: String {
        switch self {
        case .unknownPath:    return "path not recognized (expect /anthropic/* or /codex/*)"
        case .missingKey:     return "missing Authorization: Bearer <key>"
        case .unknownKey:     return "unknown access key"
        case .protoMismatch:  return "key/endpoint protocol mismatch"
        case .baseURLMismatch: return "key/baseURL mismatch (Claude key → /claude, Codex key → /codex, universal key → /v1 & /anthropic)"
        case .noMapping:      return "model not mapped and no lower-tier fallback"
        case .noAnthropicBase: return "vendor has no Anthropic base URL"
        case .noOpenAIBase:   return "vendor has no OpenAI base URL"
        case .noVendorKey:    return "vendor key not found in Keychain"
        case .badBody:        return "request body is not valid JSON or has no model field"
        case .upstream(let m): return "upstream error: \(m)"
        case .routingDisabled: return "routing disabled for this harness"
        case .universalBadModel: return "universal routing expects model as VENDOR/MODEL (e.g. ZHIPU/GLM-5.3-Flash)"
        case .universalNotFound(let m): return "vendor or model not configured: \(m)"
        case .pathTraversal:  return "request path contains traversal segments"
        case .methodNotAllowed: return "method not allowed (expect GET for model list or POST)"
        case .bodyTooLarge:   return "request body exceeds limit"
        case .badFraming:     return "malformed request framing (Content-Length/Transfer-Encoding conflict or invalid)"
        case .badHost:        return "Host header not permitted"
        }
    }
}
