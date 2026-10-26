import Foundation

// MARK: - 配置持久层（config.json 单一真源；App Support 下；原子写）
public final class ConfigStore {
    public let path: String

    /// 最近一次 loadOrSeed 的状态备注（降级/备份/迁移；启动横幅与无头验证读取）
    public private(set) var lastLoadNotes: [String] = []

    public init(path: String) {
        self.path = path
    }

    public static var defaultPath: String {
        // MR_CONFIG_PATH：隔离验证/调试用（与 MR_KEYSTORE_DIR 同一惯例）
        ProcessInfo.processInfo.environment["MR_CONFIG_PATH"]
            ?? "\(NSHomeDirectory())/Library/Application Support/ModelRouter/config.json"
    }

    /// 读已有配置并补齐访问 Key。安全规则（I5）：
    /// · 文件不存在 → seed；
    /// · 存在但不可读 → 临时降级配置（仅通用卡，不落盘、不动原文件）；
    /// · 解码失败 → 先备份原文件再 seed；备份失败 → 降级（绝不静默覆盖用户数据）。
    public func loadOrSeed() -> RouterConfig {
        lastLoadNotes = []
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path)
        let data = fm.contents(atPath: path)
        if let data, let cfg = try? JSONDecoder().decode(RouterConfig.self, from: data) {
            return migrated(cfg)
        }
        if !exists {
            return seed()
        }
        if data == nil {
            lastLoadNotes.append("config.json 存在但不可读：本次以临时降级配置（仅通用路由卡）运行，原文件未改动")
            return Self.degraded()
        }
        if let bak = backup(reason: "pre-seed-corrupt") {
            lastLoadNotes.append("config.json 解码失败，原文件已备份：\((bak as NSString).lastPathComponent)；已重建默认配置")
            return seed()
        }
        lastLoadNotes.append("config.json 解码失败且备份失败：本次以临时降级配置运行，原文件未改动")
        return Self.degraded()
    }

    /// 装载后置：补各卡访问 Key；旧配置缺通用卡时补齐（落盘前先备份，备份失败仅内存补齐）
    private func migrated(_ cfg: RouterConfig) -> RouterConfig {
        var cfg = cfg
        for h in cfg.harnesses {
            ensureAccessKey(ref: h.accessKeyRef)
        }
        let missingUniversal = !cfg.harnesses.contains(where: { $0.universal == true })
        let upgradedTiers = Self.upgradeDefaultClaudeTiers(&cfg)
        if missingUniversal {   // 旧配置迁移：补通用路由卡
            cfg.harnesses.append(Self.universalHarness())
            ensureAccessKey(ref: K.universalKeyRef)
        }
        if missingUniversal || upgradedTiers {
            let backedUp = backup(reason: "pre-migrate-config") != nil
            if backedUp, save(cfg) {
                lastLoadNotes.append("旧配置已迁移并落盘（原文件已备份）：通用路由卡补齐与默认档位升级按需执行")
            } else {
                lastLoadNotes.append("旧配置已内存迁移（备份或落盘失败，磁盘原文件未改动）：通用路由卡补齐与默认档位升级按需执行")
            }
        }
        return cfg
    }

    /// R28：存量旧原生默认档升级到当前官方默认 ID。只迁移未被用户添加标记的槽位，
    /// 目标 ID 已存在时不冲突迁移；slot 内映射与锁定字段原样保留，tierOrder 原位换键。
    static func upgradeDefaultClaudeTiers(_ cfg: inout RouterConfig) -> Bool {
        var changed = false
        for hi in cfg.harnesses.indices where cfg.harnesses[hi].tierOrder != nil {
            for (from, to) in K.claudeDefaultUpgrade {
                guard let si = cfg.harnesses[hi].slots.firstIndex(where: {
                    $0.clientModelField == from && $0.userAdded != true
                }), !cfg.harnesses[hi].slots.contains(where: { $0.clientModelField == to }) else { continue }
                cfg.harnesses[hi].slots[si].clientModelField = to
                if let ti = cfg.harnesses[hi].tierOrder?.firstIndex(of: from) {
                    cfg.harnesses[hi].tierOrder?[ti] = to
                } else if var tier = cfg.harnesses[hi].tierOrder {
                    let rank = Router.claudeTierRank(to)
                    tier.insert(to, at: tier.firstIndex { Router.claudeTierRank($0) > rank } ?? tier.count)
                    cfg.harnesses[hi].tierOrder = tier
                }
                changed = true
            }
        }
        return changed
    }

    /// 降级配置：仅通用路由卡（服务可起、UI 可用；无任何用户数据）
    static func degraded() -> RouterConfig {
        RouterConfig(endpoint: EndpointSpec(), vendors: [], harnesses: [universalHarness()])
    }

    /// 通用路由卡：无槽位、VENDOR/MODEL 直通、双协议一把 Key
    static func universalHarness() -> Harness {
        Harness(name: "通用路由", proto: .anthropic, accessKeyRef: K.universalKeyRef,
                tierOrder: nil, universal: true, slots: [])
    }

    /// 生成初始配置：Claude 卡（四档空槽）+ Codex 卡（空）+ 通用路由卡，各生成一把访问 Key。
    @discardableResult
    public func seed() -> RouterConfig {
        let claude = Harness(name: "Claude",
                             proto: .anthropic,
                             accessKeyRef: K.claudeKeyRef,
                             tierOrder: K.claudeTierOrder,
                             slots: K.claudeTierOrder.map { Slot(clientModelField: $0) })
        let codex = Harness(name: "Codex",
                            proto: .openai,
                            accessKeyRef: K.codexKeyRef,
                            tierOrder: nil,
                            slots: [])
        let cfg = RouterConfig(endpoint: EndpointSpec(), vendors: [],
                               harnesses: [claude, codex, Self.universalHarness()])
        ensureAccessKey(ref: K.claudeKeyRef)
        ensureAccessKey(ref: K.codexKeyRef)
        ensureAccessKey(ref: K.universalKeyRef)
        save(cfg)
        return cfg
    }

    /// 落盘（原子写，0600）。返回是否成功——失败由调用方横幅告警，不再静默吞错。
    @discardableResult
    public func save(_ cfg: RouterConfig) -> Bool {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(cfg)
            // always：config.json 为 ModelRouter 自有文件，维持每次收紧 0600 的既有保证
            return SafeFileWriter.write(data, to: path, pinMode: .always, createTargetDirectory: true)
        } catch {
            return false
        }
    }

    /// 任何改写性操作（repair/重建/迁移）前备份当前文件；返回备份路径，失败返回 nil。同一 reason 只留最近 5 份。
    @discardableResult
    public func backup(reason: String) -> String? {
        SafeFileWriter.backup(file: path, reason: reason)
    }

    /// 访问 Key 不存在时生成一把并落盘。
    public func ensureAccessKey(ref: String) {
        if KeychainStore.get(ref, domain: .access) == nil {
            KeychainStore.set(ref, value: KeychainStore.generateAccessKey(), domain: .access)
        }
    }
}

// MARK: - 供应商 Base URL 校验（致命项才拦截：scheme/主机名；后缀形态仅提示——官方 base 各异，以官方文档为准）
public enum VendorValidator {
    /// 校验单个 Base URL；空串返回 nil（由「至少一个端点」规则统一处理）；非法返回中文原因。
    public static func validateBaseURL(_ raw: String, kind: Proto) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.contains(" ") { return "地址不能含空格" }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return "需以 http:// 或 https:// 开头" }
        guard let host = url.host, !host.isEmpty else { return "缺少有效主机名" }
        return nil
    }

    /// 后缀约定的非阻断提示（不挡保存）
    public static func suffixHint(_ raw: String, kind: Proto) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let path = s.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        switch kind {
        case .anthropic:
            return path.lowercased().hasSuffix(K.anthropicSuffix)
                ? nil
                : "提示：Anthropic 端点通常以 /anthropic 结尾（以官方文档为准）"
        case .openai:
            return path.range(of: K.openaiVersionRegex, options: .regularExpression) != nil
                ? nil
                : "官方 base 可能不带版本段（如 DeepSeek 用 https://api.deepseek.com），按官方文档填即可"
        }
    }

    /// 归一化：去首尾空格、去尾部斜杠。
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
           .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    /// 端点语义比对（I7，2026-09-28，管理员指令：算法参考 CLI 配置脏判定的深层 isEqual 思路）：
    /// URL 先规范化为成分（scheme/host 小写、显式缺省端口归一、path 去重复尾斜杠、query 保留），
    /// 再做字典深层 isEqual——仅写法差异（尾斜杠/主机大小写/显式 443）不误判为变更，
    /// 真实差异（host/path/scheme/query/有无端点）必判变更。nil 与 nil 视为相等。
    public static func sameEndpoint(_ a: URL?, _ b: URL?) -> Bool {
        NSDictionary(dictionary: endpointParts(a) ?? [:]).isEqual(to: endpointParts(b) ?? [:])
    }

    private static func endpointParts(_ u: URL?) -> [String: String]? {
        guard let u, let c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        var path = c.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let scheme = (c.scheme ?? "").lowercased()
        var port = c.port.map(String.init) ?? ""
        if (port == "443" && scheme == "https") || (port == "80" && scheme == "http") { port = "" }
        return ["scheme": scheme,
                "host": (c.host ?? "").lowercased(),
                "port": port,
                "path": path,
                "query": c.query ?? ""]
    }
}
