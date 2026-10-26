import Foundation

// MARK: - 路由表（不可变快照；配置变更时整体重建，在途请求持旧表跑完）
public struct HarnessTable {
    public let byKeyHash: [String: UUID]                 // sha256(入站 Bearer Key) → harnessID
    public let protoOf: [UUID: Proto]                    // Key 与路径协议的交叉校验表
    public let enabledOf: [UUID: Bool]                   // 路由开关（nil = true）
    public let tierOrderOf: [UUID: [String]]             // 下位替代档序（Claude 卡）
    public let universalOf: [UUID: Bool]                 // 通用路由卡（双协议一把 Key）
    public let modelsByVendor: [UUID: [ModelEntry]]      // 模型库按供应商聚合（通用路由只下发已入库模型）
    public let slotKeysOf: [UUID: [String]]              // 每卡全部槽位键（含未映射；模型发现用）
    public let slotsOf: [UUID: [String: (UUID, String)]] // [harness][clientModelField] → (vendorID, modelID)，仅已映射槽
    public let vendorsByID: [UUID: Vendor]

    public init(config: RouterConfig) {
        var byHash: [String: UUID] = [:]
        var proto: [UUID: Proto] = [:]
        var enabled: [UUID: Bool] = [:]
        var tier: [UUID: [String]] = [:]
        var universal: [UUID: Bool] = [:]
        var modelsByVendor: [UUID: [ModelEntry]] = [:]
        var slotKeys: [UUID: [String]] = [:]
        var slots: [UUID: [String: (UUID, String)]] = [:]
        var vendors: [UUID: Vendor] = [:]

        for v in config.vendors { vendors[v.id] = v }
        for m in config.models { modelsByVendor[m.vendorID, default: []].append(m) }
        for h in config.harnesses {
            proto[h.id] = h.proto
            enabled[h.id] = h.enabled ?? true
            // Codex 卡（tierOrder nil）恒直查映射、不走档位降级；R8 起槽位键＝模型名称
            tier[h.id] = h.tierOrder ?? []
            universal[h.id] = h.universal ?? false
            slotKeys[h.id] = h.slots.map { $0.clientModelField }
            var m: [String: (UUID, String)] = [:]
            for s in h.slots where s.isMapped {
                m[s.clientModelField] = (s.vendorID!, s.modelID!)
            }
            slots[h.id] = m
            if let key = KeychainStore.get(h.accessKeyRef, domain: .access) {
                byHash[KeychainStore.hashKey(key)] = h.id
            }
        }

        self.byKeyHash = byHash
        self.protoOf = proto
        self.enabledOf = enabled
        self.tierOrderOf = tier
        self.universalOf = universal
        self.modelsByVendor = modelsByVendor
        self.slotKeysOf = slotKeys
        self.slotsOf = slots
        self.vendorsByID = vendors
    }
}

// MARK: - 路由器（路径定协议 → Key 定卡 → 查映射 → 构造上游请求）
public final class Router {
    private var table: HarnessTable   // 配置变更后热换；在途请求持旧表跑完
    private let queue = DispatchQueue(label: "mr.router.swap")

    public init(table: HarnessTable) {
        self.table = table
    }

    /// 热换路由表。
    public func swapTable(_ newTable: HarnessTable) {
        queue.sync { self.table = newTable }
    }

    /// 每次读取取一份一致快照，避免读到换表途中的半新半旧状态。
    private func currentTable() -> HarnessTable {
        queue.sync { table }
    }

    /// 按路径前缀定协议（Claude=/claude，Codex=/codex，通用路由=/v1 与 /anthropic；旧路径兼容）。
    public static func classify(path: String) -> Proto? {
        if path.hasPrefix("/claude")    { return .anthropic }
        if path.hasPrefix("/anthropic") { return .anthropic }   // 旧路径兼容 + 通用路由 Anthropic 面
        if path.hasPrefix("/codex")     { return .openai }
        if path == "/v1/messages"       { return .anthropic }   // 旧版兼容：messages 走 Anthropic
        if path.hasPrefix("/v1")        { return .openai }      // 通用路由 OpenAI 面（responses + chat/completions 共用）
        return nil
    }

    /// Claude 卡档位的展示名（Mythos/Fable/Opus/Sonnet/Haiku）；其余原样
    public static func tierDisplay(_ field: String) -> String {
        if field.contains("mythos") { return "Mythos" }
        if field.contains("fable") { return "Fable" }
        if field.contains("opus") { return "Opus" }
        if field.contains("sonnet") { return "Sonnet" }
        if field.contains("haiku") { return "Haiku" }
        return field
    }

    /// Claude 兼容 ID 的档序秩（注册新模型位时按秩插入 tierOrder；同秩保持注册先后）。
    /// 定位段取自 K.claudePositions；haiku 与无法识别的旧档垫底，保证既有档序稳定。
    public static func claudeTierRank(_ field: String) -> Int {
        let ordered: [(String, Int)] = [("-mythos", 0), ("-fable", 1), ("-opus", 2), ("-sonnet", 3), ("-haiku", 4)]
        for (pos, r) in ordered where field.contains(pos) { return r }
        return 5
    }

    /// R16③：官方预设 ID →（定位段, 后缀）分解，注册通路复用（如 claude-opus-5-5 → ("-opus", "-5-5")）。
    public static func claudeDecompose(_ id: String) -> (position: String, suffix: String)? {
        for p in K.claudePositions where id.hasPrefix("claude" + p) {
            let suffix = String(id.dropFirst(("claude" + p).count))
            return suffix.isEmpty ? nil : (p, suffix)
        }
        return nil
    }

    /// R16①：剥尾部日期段（-\d{8}，如 claude-haiku-4-5-20251001 → claude-haiku-4-5；日期可忽略口径）
    public static func normalizedClaudeID(_ field: String) -> String {
        if let r = field.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(field[..<r.lowerBound])
        }
        return field
    }

    /// R16① 弃用判定：档位 ID（剥日期段）命中固化集＝官方支持
    public static func isSupportedClaudeID(_ field: String) -> Bool {
        K.anthropicSupported.contains(normalizedClaudeID(field))
    }

    /// R16① 显示名表：固化命中→写死名（Tier＋去连字符版本号）；未命中（自定义 ID）→只显示档位名
    public static let claudeDisplayNames: [String: String] = [
        "claude-fable-5-1": "Fable5.1", "claude-opus-5-5": "Opus5.5", "claude-sonnet-5-5": "Sonnet5.5",
        "claude-haiku-5-5": "Haiku5.5", "claude-haiku-4-5": "Haiku4.5",
        "claude-mythos-5-1": "Mythos5.1", "claude-mythos-5": "Mythos5",
        "claude-fable-5": "Fable5", "claude-opus-5": "Opus5", "claude-sonnet-5": "Sonnet5",
        "claude-opus-4-8": "Opus4.8", "claude-opus-4-7": "Opus4.7", "claude-opus-4-6": "Opus4.6",
        "claude-sonnet-4-6": "Sonnet4.6", "claude-opus-4-5": "Opus4.5",
    ]

    public static func claudeDisplayName(_ field: String) -> String {
        claudeDisplayNames[normalizedClaudeID(field)] ?? tierDisplay(field)
    }

    /// 路由开关是否打开（缺失视为开）。
    public func isRoutingEnabled(harnessID: UUID) -> Bool {
        currentTable().enabledOf[harnessID] ?? true
    }

    /// Key → Harness，并做协议与 baseURL 交叉校验。
    /// R3 隔离（2026-09-17）：各卡 Key 仅在其下发 baseURL 前缀上生效——Claude 卡=/claude、Codex 卡=/codex、
    /// 通用路由=/v1 与 /anthropic（双面一把 Key）；其余组合一律 401，baseURL 之间不互通。
    public func identify(bearer: String?, path: String, proto: Proto) -> Result<UUID, RouterError> {
        let table = currentTable()
        guard let bearer = bearer, bearer.hasPrefix("Bearer ") else { return .failure(.missingKey) }
        let token = String(bearer.dropFirst("Bearer ".count))
        guard let hid = table.byKeyHash[KeychainStore.hashKey(token)] else { return .failure(.unknownKey) }
        if table.universalOf[hid] == true {
            guard path.hasPrefix("/v1") || path.hasPrefix("/anthropic") else { return .failure(.baseURLMismatch) }
            return .success(hid)
        }
        guard table.protoOf[hid] == proto else { return .failure(.protoMismatch) }
        guard path.hasPrefix(table.protoOf[hid] == .anthropic ? "/claude" : "/codex") else { return .failure(.baseURLMismatch) }
        return .success(hid)
    }

    /// 槽位解析结果。fellBackFrom 非空 = Claude 卡发生了档位降级（请求档 → 实际命中的更低位档）
    public struct ResolvedRoute {
        public let vendor: Vendor
        public let modelID: String
        public let fellBackFrom: String?
    }

    /// S2/R10 转发闸门·绑定存活性（App 层 routable 的 Core 镜像，未检测视为活）：
    /// 供应商存在 + 条目存在 + 该面 URL 检查未失败 + 探测未判负。绑定与槽位数据不因此出表
    /// （保留绑定）；测试通过 → 表热换 → 自动恢复转发。face 依卡型：Claude 卡＝anthropic 面
    /// （messages 线）；Codex 卡＝responses 线；通用卡两面合并（任一面活即转发）。
    public enum BindingFace { case anthropic, responses, universalBoth }

    public static func bindingLive(table: HarnessTable, vendorID: UUID, modelID: String, face: BindingFace) -> Bool {
        guard let v = table.vendorsByID[vendorID],
              let e = table.modelsByVendor[vendorID]?.first(where: { $0.modelID == modelID }) else { return false }
        switch face {
        case .anthropic:
            return v.anthropicBase != nil && v.anthropicURLSupport != false && e.probeResults?["messages"] != false
        case .responses:
            return v.openaiBase != nil && v.openaiURLSupport != false && e.probeResults?["responses"] != false
        case .universalBoth:
            let anth = v.anthropicBase != nil && v.anthropicURLSupport != false && e.probeResults?["messages"] != false
            let open = v.openaiBase != nil && v.openaiURLSupport != false
                && !(e.probeResults?["responses"] == false && e.probeResults?["completions"] == false)
            return anth || open
        }
    }

    /// 槽位解析。Claude 卡走下位替代（沿档序向下找最近一个已映射档，到底没有则 nil）；
    /// Codex 卡按请求 model 直查，不降级；通用路由卡按 VENDOR/MODEL 解析（只下发已入库模型）。
    /// S2/R10：绑定失效（供应商测试判负/URL 挂）的档不再转发，Claude 卡沿档序继续降级。
    public func resolve(harnessID: UUID, modelField: String) -> ResolvedRoute? {
        let table = currentTable()
        if table.universalOf[harnessID] == true {
            guard let (v, m) = resolveUniversal(table: table, modelField: modelField) else { return nil }
            return ResolvedRoute(vendor: v, modelID: m, fellBackFrom: nil)
        }
        let mapped = table.slotsOf[harnessID] ?? [:]
        var binding: (UUID, String)?
        var hitTier: String?
        if let tier = table.tierOrderOf[harnessID], !tier.isEmpty {
            guard let start = tier.firstIndex(of: modelField) else { return nil }   // 非已知档 → 无映射
            for i in start..<tier.count {
                // 绑定供应商已删或测试失效（S2/R10）的档视为无效，继续向下降级（否则会短路下位降级）
                if let b = mapped[tier[i]],
                   Self.bindingLive(table: table, vendorID: b.0, modelID: b.1, face: .anthropic) {
                    binding = b; hitTier = tier[i]; break
                }
            }
        } else {
            binding = mapped[modelField]
        }
        guard let b = binding,
              let v = table.vendorsByID[b.0],
              Self.bindingLive(table: table, vendorID: b.0, modelID: b.1,
                               face: (table.tierOrderOf[harnessID] ?? []).isEmpty ? .responses : .anthropic) else { return nil }
        return ResolvedRoute(vendor: v, modelID: b.1,
                             fellBackFrom: (hitTier != nil && hitTier != modelField) ? modelField : nil)
    }

    /// 通用路由：模型 ID = 供应商标签/模型名（标签 = 纯英文名照抄或中文全拼大写）
    private func resolveUniversal(table: HarnessTable, modelField: String) -> (vendor: Vendor, modelID: String)? {
        guard let slash = modelField.firstIndex(of: "/"),
              slash > modelField.startIndex,
              modelField.index(after: slash) < modelField.endIndex else { return nil }
        let label = String(modelField[modelField.startIndex..<slash])
        let modelPart = String(modelField[modelField.index(after: slash)...])
        for v in table.vendorsByID.values where PinYinLabel.matches(vendorName: v.name, label: label) {
            if let entries = table.modelsByVendor[v.id],
               let e = entries.first(where: { $0.modelID == modelPart })
                   ?? entries.first(where: { $0.modelID.lowercased() == modelPart.lowercased() }) {
                // S2/R10：双面全判死的条目不再转发（测试通过后热换表自动恢复），换下家同标签供应商
                guard Self.bindingLive(table: table, vendorID: v.id, modelID: e.modelID, face: .universalBoth) else { continue }
                return (v, e.modelID)
            }
        }
        return nil
    }

    /// 模型发现（GET */v1/models）：按卡的语义给出客户端可请求的模型清单。
    /// 通用路由 = 库内按面过滤：Anthropic 面须 Messages 探测通过，OpenAI 面须 Responses 或
    /// Completions 探测通过（未检测视为不支持，不下发）；Claude 卡 = 已映射的档位（未映射
    /// 不进发现入口，但硬编码该 ID 的请求仍按直通处理）；Codex 卡 = 全部槽位键。
    public func modelList(harnessID: UUID, proto: Proto) -> [(id: String, name: String?)] {
        let table = currentTable()
        if table.universalOf[harnessID] == true {
            var out: [(String, String?)] = []
            for (vid, entries) in table.modelsByVendor {
                guard let v = table.vendorsByID[vid] else { continue }
                let faceOK = proto == .anthropic ? v.anthropicBase != nil : v.openaiBase != nil
                guard faceOK else { continue }
                for m in entries where Self.entrySupports(m, proto: proto) {
                    out.append(("\(PinYinLabel.label(for: v.name))/\(m.modelID)", m.displayName))
                }
            }
            return out.map { (id: $0.0, name: $0.1) }.sorted { $0.id < $1.id }
        }
        if let tier = table.tierOrderOf[harnessID], !tier.isEmpty {
            let mapped = table.slotsOf[harnessID] ?? [:]
            return tier.filter { mapped[$0] != nil }
                       .map { (id: $0, name: Optional(Self.tierDisplay($0))) }
        }
        return (table.slotKeysOf[harnessID] ?? []).sorted().map { (id: $0, name: nil) }
    }

    /// 通用路由发现边界：该面的协议线探测结论为 true 才下发
    static func entrySupports(_ m: ModelEntry, proto: Proto) -> Bool {
        switch proto {
        case .anthropic:
            return m.probeResults?["messages"] == true
        case .openai:
            return m.probeResults?["responses"] == true || m.probeResults?["completions"] == true
        }
    }

    /// 构造上游请求的成功载荷：request + 监视器埋点所需的路由事实（目标模型/供应商/是否降级）
    public struct UpstreamPlan {
        public let request: URLRequest
        public let targetModel: String
        public let vendorName: String
        public let fellBackFrom: String?
    }

    /// 构造上游请求：model 改写 + 换 auth + 换地址；其余头原样透传。
    /// payload 是下游请求已解析的 body JSON（只改写 model 一个键后重新序列化）。
    public func buildUpstream(path: String,
                              headers: [(String, String)],
                              payload: [String: Any],
                              harnessID: UUID,
                              proto: Proto,
                              modelField: String) -> Result<UpstreamPlan, RouterError> {
        guard let route = resolve(harnessID: harnessID, modelField: modelField) else {
            if currentTable().universalOf[harnessID] == true {
                return .failure(modelField.contains("/")
                                ? .universalNotFound(modelField)
                                : .universalBadModel)
            }
            return .failure(.noMapping)
        }
        let vendor = route.vendor
        let outModelID = route.modelID
        let base: URL
        let outPath: String
        switch proto {
        case .anthropic:
            guard let anthropicBase = vendor.anthropicBase else { return .failure(.noAnthropicBase) }
            base = anthropicBase
            outPath = Self.stripLeadAny(["/claude", "/anthropic"], path)    // 剥 /claude 或 /anthropic 前缀（保留 /v1 段）
        case .openai:
            guard let openaiBase = vendor.openaiBase else { return .failure(.noOpenAIBase) }
            base = openaiBase
            outPath = Self.stripVersion(Self.stripLeadAny(["/codex", "/v1"], path))     // 剥 /codex 或 /v1 前缀 + 版本段
        }
        // 路径操纵防御：拒绝点段与编码变体，防止 ../ 跳出供应商 base 路径
        let lowerOut = outPath.lowercased()
        if lowerOut.contains("..") || lowerOut.contains("%2e") || lowerOut.contains("%2f") || lowerOut.contains("%5c") {
            return .failure(.pathTraversal)
        }
        let trimmedBase = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast())
            : base.absoluteString
        guard let url = URL(string: trimmedBase + outPath) else { return .failure(.noMapping) }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: K.upstreamIdleTimeout)
        req.httpMethod = "POST"
        for (k, v) in headers {
            let lk = k.lowercased()
            // accept-encoding 一并丢弃：让 URLSession 自行协商编码——响应侧会剥 content-encoding
            // 并原样透传字节（HTTPServer），只有本端自主协商时两者才自洽（T2/I27）。
            if lk == "authorization" || lk == "x-api-key" || lk == "host" ||
               lk == "content-length" || lk == "content-encoding" || lk == "transfer-encoding" ||
               lk == "accept-encoding" { continue }
            req.setValue(v, forHTTPHeaderField: k)
        }
        guard let vendorKey = KeychainStore.get(vendor.keyRef, domain: .vendor) else { return .failure(.noVendorKey) }
        switch proto {
        case .anthropic: req.setValue(vendorKey, forHTTPHeaderField: "x-api-key")
        case .openai:    req.setValue("Bearer \(vendorKey)", forHTTPHeaderField: "Authorization")
        }

        var payload = payload
        payload["model"] = outModelID   // 模型 ID 隔离（内部 slug → 供应商真实 ID）
        if proto == .openai {
            // 供应商方言归一化（I14 隔离第四件）：按目标 host 改写体差异（如 DeepSeek web_search queries）；
            // Anthropic 线上游全为兼容端点，零改动
            payload = CodexDialect.normalize(payload, host: url.host ?? "")
        }
        guard let newBody = try? JSONSerialization.data(withJSONObject: payload) else { return .failure(.badBody) }
        req.httpBody = newBody
        req.setValue(String(newBody.count), forHTTPHeaderField: "Content-Length")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return .success(UpstreamPlan(request: req, targetModel: outModelID,
                                     vendorName: vendor.name, fellBackFrom: route.fellBackFrom))
    }

    /// 剥路径开头前缀：/anthropic/v1/messages → /v1/messages
    public static func stripLead(_ prefix: String, _ path: String) -> String {
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    /// 剥路径开头前缀（多候选，命中第一个）：/codex/v1/… 或 /v1/… → 剩余路径
    public static func stripLeadAny(_ prefixes: [String], _ path: String) -> String {
        for p in prefixes where path.hasPrefix(p) {
            return String(path.dropFirst(p.count))
        }
        return path
    }

    /// 剥路径开头版本段：/v1/responses → /responses
    public static func stripVersion(_ path: String) -> String {
        if let r = path.range(of: #"^/v\d+"#, options: .regularExpression) {
            return String(path[r.upperBound...])
        }
        return path
    }
}
