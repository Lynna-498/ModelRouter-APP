import SwiftUI
import AppKit
import Network
import ModelRouterCore
import os
// MARK: - 应用状态（启动即载 config/keys、后台起服务；配置改动即存盘并热换路由表）
final class AppState: ObservableObject {
    /// 事件滚动窗口：最多保留过去 1 小时，且全局不超过 2000 条（先按时间丢，再按条数丢）
    static let eventWindowSeconds: TimeInterval = 3600
    static let eventCap = 2000
    /// Toast 自动消失延时
    private static let toastDuration: TimeInterval = 2.6
    /// 警告横幅自动收起延时
    private static let bannerDuration: TimeInterval = 24

    @Published var config: RouterConfig
    @Published var selected: NavView = .routes
    @Published var status: String = "starting…"
    @Published var statusOK: Bool = false
    @Published var claudeKey: String = ""
    @Published var codexKey: String = ""
    @Published var universalKey: String = ""
    @Published var toast: String = ""
    @Published var toastDetail: String = ""
    @Published var banner: (text: String, copyValue: String)? = nil
    @Published var showGuide: Bool = false
    @Published var portSheet: PortSheetState? = nil   // 端口弹窗（settings/conflict 双模；同一时刻至多一个）
    @Published var accessOpen: [UUID: Bool] = [:]     // 每卡「访问配置」面板开关
    @Published var monitorOpen: [UUID: Bool] = [:]    // 每卡「监视器」面板开关
    @Published var monitorPaused: [UUID: Bool] = [:]  // 暂停只冻结该面板显示；记录永不停，恢复后历史完整
    @Published private(set) var events: [MonitorEvent] = []   // 全量事件环（时间升序）；监视器按卡过滤显示，档位只过滤显示
    @Published var entryProbe: [UUID: [String: Bool]] = [:]  // 模型条目 API 检测结论（键 messages/responses/completions；启动时从磁盘灌入）
    @Published var vendorProbe: [UUID: [Proto: ProbePhase]] = [:]  // 供应商连通性测试结果（内存）
    @Published private(set) var menuDot: MenuDotLevel = .idle        // R5/R17：菜单栏状态点＝「当前」口径（最近 1 条）
    @Published private(set) var menuDotEvent: LogEvent? = nil        // R17：当前口径代表事件（「当前」行文案来源）
    @Published private(set) var menuRecent: MenuDotLevel = .idle     // R17：「近期」行等级（200 条窗口聚合＝原状态点口径）
    @Published private(set) var menuRecentEvent: LogEvent? = nil     // R17：近期口径代表事件（「近期」行报错文案来源）
    private var eventSeq = 0
    private var toastGen = 0      // Toast 自动消失的世代计数（新 toast 不被旧定时器清掉）
    private var bannerGen = 0     // 横幅自动收起的世代计数
    private var authFailures: [Date] = []   // 鉴权失败时间戳（1 分钟窗口内高频 → 横幅告警）
    private var announcedPort: Int? = nil   // 最近一次进入 running 的端口（端口改动成功后驱动「请更新 Base URL」横幅）
    private var announceRecovery = false    // 最近一次监听失败被重试挽回 → 成功时横幅「监听已恢复」

    private let store: ConfigStore
    private let router: Router
    private var server: HTTPServer?
    private var menuBarController: MenuBarController?   // R5：菜单栏状态项（强持有；MR_HEADLESS=1 的无头验证进程不创建）

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // 下发给客户端的 baseURL 用字面 IP 而非 localhost：部分客户端沙箱（如 Claude Desktop 的
    // VM egress 沙箱）DNS 解析不可用或 localhost 优先解析到 ::1，字面 127.0.0.1 永不依赖解析
    var endpointText: String { "http://127.0.0.1:\(config.endpoint.port)" }

    /// 服务器监听相位（由既有 status/statusOK 派生，无第二份状态）：
    /// 侧栏状态行渲染、setPort/retryServer 防重入的唯一判定源
    enum ServerPhase { case starting, running, failed }
    var serverPhase: ServerPhase {
        if statusOK { return .running }
        return status == "failed" ? .failed : .starting
    }

    init() {
        KeychainStore.migrateFlatLayoutIfNeeded()   // 旧平铺 Key 先迁移（必须先于 loadOrSeed，否则 ensureAccessKey 会读不到旧 Key）
        let store = ConfigStore(path: ConfigStore.defaultPath)
        var config = store.loadOrSeed()
        // I5：装载即修复存量配置（ConfigRepair 幂等纯函数；写盘前先备份，备份/写盘失败则维持磁盘态、仅告警）
        var bannerText: [String] = store.lastLoadNotes
        var bannerCopy = store.path
        let (repaired, repairNotes) = ConfigRepair.repair(config)
        if !repairNotes.isEmpty {
            if let bak = store.backup(reason: "pre-repair"), store.save(repaired) {
                config = repaired
                let logPath = Self.writeRepairLog(notes: repairNotes, backupPath: bak, configPath: store.path)
                Self.logRepairToConsole(notes: repairNotes)
                bannerText.append("已自动修复配置 \(repairNotes.count) 项（备份与明细见日志，点「复制」取路径）")
                bannerCopy = logPath
            } else {
                Self.logRepairToConsole(notes: repairNotes)
                bannerText.append("检测到 \(repairNotes.count) 项配置残留，但备份/写盘失败，本次未自动修复（明细见控制台）")
            }
        }
        Self.migrateUserAddedIfNeeded(&config, store: store)   // R16①：一次性豁免迁移（存量非原生档补「用户添加」标）
        self.store = store
        self.config = config
        claudeKey = KeychainStore.get(K.claudeKeyRef, domain: .access) ?? "(missing — run set-key)"
        codexKey = KeychainStore.get(K.codexKeyRef, domain: .access) ?? "(missing)"
        universalKey = KeychainStore.get(K.universalKeyRef, domain: .access) ?? "(missing)"
        router = Router(table: HarnessTable(config: config))
        for m in config.models { entryProbe[m.id] = m.probeResults }   // 磁盘检测结论 → 内存（repair 在此之前完成，无脏键）
        if !bannerText.isEmpty {
            banner = (text: bannerText.joined(separator: "；"), copyValue: bannerCopy)
        }
        startServer(with: config)
        recomputeMenuDot()   // R5：初始状态点（刚启动通常 idle）
    }

    /// I5：修复明细 sidecar 日志（config.json.repair-<时间戳>.log，0600）；返回日志路径
    private static func writeRepairLog(notes: [ConfigRepair.RepairNote], backupPath: String, configPath: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let logPath = configPath + ".repair-" + f.string(from: Date()) + ".log"
        let text = """
        ModelRouter 配置修复
        时间：\(Date())
        备份：\(backupPath)
        明细：
        \(notes.map(\.description).joined(separator: "\n"))
        """
        try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: logPath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
        return logPath
    }

    private static let repairLogger = Logger(subsystem: "ModelRouter", category: "repair")

    private static func logRepairToConsole(notes: [ConfigRepair.RepairNote]) {
        for n in notes { repairLogger.info("\(n.description, privacy: .public)") }
    }

    /// 后台起服务，不卡主线程；Key 存储默认走文件兜底，启动不弹授权框。
    /// 状态灯只认监听器真实状态：.ready 才置绿，.failed（端口被旧实例占用等）置红并横幅指引。
    private func startServer(with config: RouterConfig) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let server = try HTTPServer(port: config.endpoint.port, router: self.router, onLog: { [weak self] event in
                    DispatchQueue.main.async {
                        self?.ingest(event)   // 序号分配与窗口清理都在主线程，天然串行
                    }
                })
                DispatchQueue.main.async { self.server = server }
                server.onLifecycle = { [weak self] ok, detail in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let port = self.config.endpoint.port
                        if ok {
                            let recovered = self.announceRecovery
                            self.status = self.endpointText
                            self.statusOK = true
                            self.portSheet = nil                       // 监听成功即关弹窗
                            self.announceRecovery = false
                            if let prev = self.announcedPort, prev != port {
                                // 端口改动成功：客户端 Base URL 需跟随（横幅带复制按钮；
                                // 访问配置面板/引导页由 endpointText 同源派生自动更新）
                                self.banner = (text: "端口已改为 \(port) — 请把客户端 Base URL 更新为 \(self.endpointText)",
                                               copyValue: self.endpointText)
                                self.scheduleBannerHide()
                            } else if recovered {
                                // 最近一次失败被挽回（重试/改端口后恢复监听）
                                self.banner = (text: "监听已恢复：\(self.endpointText)（配置未变，客户端无需改动）",
                                               copyValue: self.endpointText)
                                self.scheduleBannerHide()
                            }
                            self.announcedPort = port
                        } else {
                            self.status = "failed"
                            self.statusOK = false
                            self.announceRecovery = true
                            self.banner = (text: "端口 \(port) 监听失败（\(detail)），可能被旧实例占用：lsof -i :\(port) 查占用",
                                           copyValue: "")
                            self.scheduleBannerHide()
                            // R1：冲突不再只有横幅——自动弹交互弹窗（重试 / 改端口 / 稍后）
                            self.portSheet = PortSheetState(mode: .conflict(port: port, detail: detail))
                        }
                    }
                }
                server.start()
            } catch {
                // HTTPServer.init 异常兜底（invalidPort；UI 校验应先挡住，理论不可达）
                DispatchQueue.main.async {
                    self.status = "failed"
                    self.statusOK = false
                    self.announceRecovery = true
                    self.portSheet = PortSheetState(mode: .conflict(port: config.endpoint.port, detail: "\(error)"))
                }
            }
        }
    }

    // MARK: - 监视器事件流

    private var pendingEvents: [MonitorEvent] = []
    private var flushScheduled = false

    /// 全量入环：显示档位只过滤渲染，这里一条不丢。
    /// 发布做 250ms 合流——长流式响应期间 verbose 心跳每 2s/64KB 一条，逐条触发
    /// @Published 会让监视器每心跳重建整页富文本（实测主线程卡顿）。
    private func ingest(_ e: LogEvent) {
        // 高频鉴权失败 = 本地有进程在探测；但客户端不带 Key 的连通性预检（missingKey）
        // 属正常行为，不计入风暴（否则 Desktop 预检即可触发安全误报）
        if e.phase == .decision, e.status == 401, e.message != RouterError.missingKey.description {
            authFailures.append(Date())
            authFailures.removeAll { Date().timeIntervalSince($0) > 60 }
            if authFailures.count == 20 {
                // 编辑 sheet 打开期间不打断用户（横幅悬浮不推挤布局，但仍会遮内容）：
                // 计数已到阈值的事实记录在 pendingBanner，sheet 关闭后补弹
                let text = "检测到高频鉴权失败（1 分钟内 20 次），本地可能有进程在探测 ModelRouter"
                if banner == nil {
                    banner = (text: text, copyValue: "")
                    scheduleBannerHide()
                }
            }
        }
        eventSeq += 1
        pendingEvents.append(MonitorEvent(seq: eventSeq, event: e))
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushEvents()
        }
    }

    /// 合流批次入环并做窗口/条数清理
    private func flushEvents() {
        guard !pendingEvents.isEmpty else { return }
        events.append(contentsOf: pendingEvents)
        pendingEvents = []
        trimEvents()
        recomputeMenuDot()
    }

    private func trimEvents() {
        let cutoff = Date().addingTimeInterval(-Self.eventWindowSeconds)
        if let keep = events.firstIndex(where: { $0.event.ts >= cutoff }) {
            if keep > 0 { events.removeFirst(keep) }
        } else {
            events.removeAll()   // 全部过期（空转期后大量堆积的兜底）
        }
        if events.count > Self.eventCap {
            events.removeFirst(events.count - Self.eventCap)
        }
    }

    /// 某卡监视器当前应显示的事件（最新在顶）：按卡过滤 + 档位下限过滤。
    func monitorEvents(harnessID: UUID, minimum level: LogLevel) -> [MonitorEvent] {
        events.filter { $0.event.harnessID == harnessID && $0.event.level >= level }.reversed()
    }

    /// 清空某卡的事件（显示与导出同步消失）。
    func clearEvents(harnessID: UUID) {
        flushEvents()
        events.removeAll { $0.event.harnessID == harnessID }
        recomputeMenuDot()
    }

    // MARK: - 菜单栏状态点（R5）

    /// 「近期」口径判定（纯函数，无头可测）：R17 起专职菜单「近期」行（原状态点口径，不再驱动状态点）。
    /// 降噪剔除 401 预检噪声（message 含 "missing Authorization" 的 error 级 .decision 事件，
    /// 参照 ingest 的 missingKey 排除先例）后取末尾 200 条窗口聚合。空 → idle；含 error → err
    /// （窗口内最后一条 error）；否则含 warning → warn（最后一条 warning）；否则 ok。
    static func menuRecentState(_ events: [MonitorEvent]) -> (level: MenuDotLevel, latest: LogEvent?) {
        var cleaned = events.filter { e in
            !(e.event.level == .error
              && e.event.phase == .decision
              && (e.event.message?.contains("missing Authorization") ?? false))
        }
        if cleaned.count > 200 { cleaned = Array(cleaned.suffix(200)) }
        if cleaned.isEmpty { return (.idle, nil) }
        if let last = cleaned.last(where: { $0.event.level == .error }) { return (.err, last.event) }
        if let last = cleaned.last(where: { $0.event.level == .warning }) { return (.warn, last.event) }
        return (.ok, nil)
    }

    /// 「当前」口径判定（纯函数，无头可测）：S9/R17 起驱动状态点——降噪后只看最后一条事件，
    /// 不按 200 条窗口聚合（历史错误不压当前状态）。空 → idle；末条 error → err；
    /// 末条 warning → warn；其余（info/verbose 心跳等）→ ok。
    static func menuDotState(_ events: [MonitorEvent]) -> (level: MenuDotLevel, latest: LogEvent?) {
        let cleaned = events.filter { e in
            !(e.event.level == .error
              && e.event.phase == .decision
              && (e.event.message?.contains("missing Authorization") ?? false))
        }
        guard let last = cleaned.last else { return (.idle, nil) }
        switch last.event.level {
        case .error:   return (.err, last.event)
        case .warning: return (.warn, last.event)
        default:       return (.ok, nil)
        }
    }

    /// 把双口径结论写入发布属性（挂接：flushEvents / clearEvents / init 三处）
    func recomputeMenuDot() {
        let cur = Self.menuDotState(events)
        menuDot = cur.level
        menuDotEvent = cur.latest
        let rec = Self.menuRecentState(events)
        menuRecent = rec.level
        menuRecentEvent = rec.latest
    }

    /// R5：菜单栏状态项——主窗出现后创建（应用启动完成），避免启动早期注册导致菜单跟踪异常
    func attachMenuBar() {
        guard menuBarController == nil,
              ProcessInfo.processInfo.environment["MR_HEADLESS"] == nil else { return }
        menuBarController = MenuBarController(state: self)
    }

    /// 导出数据：事件全量（不受显示档位过滤）+ 脱敏配置快照。
    /// 不含任何 Key、Key 引用名、请求/响应正文——可直接发给排障方。
    func exportLogData() -> Data? {
        flushEvents()
        let vendorNames = Dictionary(uniqueKeysWithValues: config.vendors.map { ($0.id, $0.name) })
        let export = LogExport(
            app: "ModelRouter",
            exportedAt: Date(),
            retention: "最近 \(Int(Self.eventWindowSeconds / 60)) 分钟 · 上限 \(Self.eventCap) 条",
            vendors: config.vendors.map {
                .init(name: $0.name,
                      anthropicBase: $0.anthropicBase?.absoluteString,
                      openaiBase: $0.openaiBase?.absoluteString)
            },
            harnesses: config.harnesses.map { h in
                .init(name: h.name, proto: h.proto.rawValue, universal: h.universal ?? false,
                      slots: h.slots.map {
                          .init(slot: $0.clientModelField, model: $0.modelID,
                                vendor: $0.vendorID.flatMap { vendorNames[$0] })
                      })
            },
            models: config.models.map {
                .init(model: $0.modelID, vendor: vendorNames[$0.vendorID] ?? "?",
                      displayName: $0.displayName, tested: $0.tested, probeResults: $0.probeResults)
            },
            events: events)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(export)
    }

    static func tierDisplay(_ field: String) -> String {
        Router.tierDisplay(field)   // 唯一实现下沉在 Core，避免两处逻辑漂移
    }

    // MARK: - 路由开关
    /// 访问 Key 缓存文本（访问配置面板用；body 里不再读 Key 文件）
    func accessKeyText(for ref: String) -> String {
        switch ref {
        case K.claudeKeyRef: return claudeKey
        case K.codexKeyRef: return codexKey
        case K.universalKeyRef: return universalKey
        default: return KeychainStore.get(ref, domain: .access) ?? "(missing)"
        }
    }

    func setHarnessEnabled(harnessID: UUID, _ on: Bool) {
        guard let hi = config.harnesses.firstIndex(where: { $0.id == harnessID }) else { return }
        config.harnesses[hi].enabled = on
        persist()
    }

    // MARK: - 写操作（落 config.json + 热换路由表，下次请求生效）
    func persist() {
        if !store.save(config) {
            banner = (text: "配置写入失败：磁盘不可写或权限异常，本次改动仅在内存生效", copyValue: store.path)
        }
        router.swapTable(HarnessTable(config: config))
    }

    // MARK: - 自定义端口（R1）
    /// 端口校验：纯数字且在 1024–65535（避开系统服务段）。返回错误文案，nil = 合法。
    static func validatePort(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "请填写端口号" }
        guard t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return "端口须为纯数字" }
        guard let p = Int(t) else { return "端口号过大" }
        guard (1024...65535).contains(p) else { return "端口须在 1024–65535 之间" }
        return nil
    }

    /// 改端口（弹窗「确认」调用）：校验不过返回错误文案（零副作用）；通过则落盘并重启监听。
    /// 与当前端口相同时：running 视为 no-op（返回提示，不重启），failed 等效重试。
    /// 成功与否由 onLifecycle 异步收敛（running → 关弹窗；failed → 弹窗转 conflict）。
    func setPort(_ raw: String) -> String? {
        guard serverPhase != .starting else { return "正在重启监听，请稍候…" }   // 防重入
        if let err = Self.validatePort(raw) { return err }
        let p = Int(raw.trimmingCharacters(in: .whitespaces))!
        guard p != config.endpoint.port else {
            if serverPhase == .failed {
                // F8：failed 态填回当前端口 ≠ 重试（被占端口重试必败 → 冲突循环）；
                // 返回说明性红字、零副作用；重试仅由弹窗「重试」按钮显式触发
                return "端口 \(p) 即当前端口且正被占用：终端 lsof -i :\(p) 杀掉占用者（可能是旧 ModelRouter 实例）后点「重试」，或改填新端口"
            }
            return "与当前端口相同，无需修改"
        }
        config.endpoint.port = p
        persist()
        restartServer()
        return nil
    }

    /// 重试当前 config 端口（不改配置、不落盘）：用于冲突弹窗「重试」——用户已 kill 占用者后。
    func retryServer() {
        guard serverPhase != .starting else { return }   // 防重入
        restartServer()
    }

    func dismissPortSheet() {
        portSheet = nil
    }

    /// 停旧起新（I6：任一时刻至多一个活跃 listener）。旧 server 先摘 onLifecycle 再 stop，
    /// 防其残留 .failed/.cancelled 回调污染新实例状态；新实例沿用同一 Router（表与端口无关）。
    /// announceRecovery 不在此清零：失败 → 重试成功要靠它出「监听已恢复」横幅，成功分支统一消费。
    private func restartServer() {
        statusOK = false
        status = "starting…"
        let old = server
        server = nil
        if let old {
            old.onLifecycle = nil
            old.stop()
        }
        startServer(with: config)
    }

    func regenerateAccessKey(ref: String, harnessName: String) {
        let key = KeychainStore.generateAccessKey()
        KeychainStore.set(ref, value: key, domain: .access)
        if ref == K.claudeKeyRef { claudeKey = key }
        if ref == K.codexKeyRef { codexKey = key }
        if ref == K.universalKeyRef { universalKey = key }
        persist()
        let other = ref == K.claudeKeyRef ? "Codex" : "Claude"
        banner = (text: "\(harnessName) 的访问 Key 已重新生成，请到 \(harnessName) 客户端重新粘贴", copyValue: key)
        toast = "\(harnessName) 访问 Key 已重新生成"
        toastDetail = "仅 \(harnessName) 使用，与 \(other) 不通用"
        flashToast()
        scheduleBannerHide()
    }

    private func scheduleBannerHide() {
        bannerGen += 1
        let g = bannerGen
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerDuration) { [weak self] in
            guard let self, self.bannerGen == g else { return }   // 已有新横幅则不收
            self.banner = nil
        }
    }

    /// 手动关闭横幅（P1：✕ 按钮）；递增世代使在途自动收起定时器失效
    func dismissBanner() {
        bannerGen += 1
        banner = nil
    }

    /// 某供应商的模型库条目数（「N 个模型入库」语义；F5：原误统计路由槽位引用数）
    func modelCount(for vendorID: UUID) -> Int {
        config.models.filter { $0.vendorID == vendorID }.count
    }

    /// 删供应商：级联删掉它的模型、清掉引用它的槽位绑定与默认来源指向，并删掉它的 Key（对齐原型语义）
    func deleteVendor(_ v: Vendor) {
        config.vendors.removeAll { $0.id == v.id }
        for m in config.models where m.vendorID == v.id { entryProbe[m.id] = nil }   // I5：内存检测结论随模型级联清理（原遗漏）
        config.models.removeAll { $0.vendorID == v.id }
        for (groupKey, line) in config.defaultSourcesByAPI {
            let cleaned = line.filter { $0.value != v.id }
            if cleaned.isEmpty { config.defaultSourcesByAPI.removeValue(forKey: groupKey) }
            else if cleaned.count != line.count { config.defaultSourcesByAPI[groupKey] = cleaned }
        }
        // 披露：清空前统计被影响的槽位总数与其中锁定行数（locked 标志保留不清——用户显式状态，仅披露）
        var total = 0
        var lockedN = 0
        for h in config.harnesses {
            for s in h.slots where s.vendorID == v.id {
                total += 1
                if s.locked == true { lockedN += 1 }
            }
        }
        for hi in config.harnesses.indices {
            for si in config.harnesses[hi].slots.indices where config.harnesses[hi].slots[si].vendorID == v.id {
                config.harnesses[hi].slots[si].vendorID = nil
                config.harnesses[hi].slots[si].modelID = nil
            }
        }
        KeychainStore.delete(v.keyRef, domain: .vendor)
        persist()
        if total > 0 && lockedN > 0 {
            toast = "已删除供应商及其模型；清除 \(total) 个映射（含 \(lockedN) 个锁定行）"
        } else if total > 0 {
            toast = "已删除供应商及其模型；清除 \(total) 个映射"
        } else {
            toast = "已删除供应商及其模型"
        }
        flashToast()
    }

    /// 某供应商被哪些卡·模型位引用（删除确认里的提示文案）
    func harnessUsage(vendorID: UUID) -> [String] {
        var out: [String] = []
        for h in config.harnesses {
            for s in h.slots where s.vendorID == vendorID {
                out.append("\(h.name) · \(h.tierOrder == nil ? s.clientModelField : Self.tierDisplay(s.clientModelField))")
            }
        }
        return out
    }

    /// 某模型条目被哪些卡·模型位引用
    func harnessUsage(modelID: String, vendorID: UUID) -> [String] {
        var out: [String] = []
        for h in config.harnesses {
            for s in h.slots where s.modelID == modelID && s.vendorID == vendorID {
                out.append("\(h.name) · \(h.tierOrder == nil ? s.clientModelField : Self.tierDisplay(s.clientModelField))")
            }
        }
        return out
    }

    // MARK: - Codex 槽位增删（R8：行＝「添加的模型」，键＝模型名称；slug=display_name=名称字面直用）

    /// 模型名称合规（Codex slug 口径）：仅 ASCII 且不含空白；不合规名称不可添加（存量保留、界面标记提醒）
    static func isCodexCompliantName(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && !$0.isWhitespace }
    }

    /// 把模型名称添加到 Codex 卡：建槽（键＝名称）＋按名称级解析链绑定
    /// （responses 线默认来源 → 保留 → 唯一 → 首现；名称在当前线无可用条目时保留为未映射行）。
    /// 名称不合规或已添加 → false（不落盘）。
    @discardableResult
    func addCodexModel(harnessID: UUID, name: String) -> Bool {
        guard Self.isCodexCompliantName(name) else { return false }
        guard let hi = config.harnesses.firstIndex(where: { $0.id == harnessID }) else { return false }
        guard !config.harnesses[hi].slots.contains(where: { $0.clientModelField == name }) else { return false }
        config.harnesses[hi].slots.append(Slot(clientModelField: name))
        setSlotModel(harnessID: harnessID, field: name, groupName: name)
        return true
    }

    func removeSlot(harnessID: UUID, field: String) {
        guard let hi = config.harnesses.firstIndex(where: { $0.id == harnessID }) else { return }
        config.harnesses[hi].slots.removeAll(where: { $0.clientModelField == field })
        if var tier = config.harnesses[hi].tierOrder, let i = tier.firstIndex(of: field) {
            tier.remove(at: i)
            config.harnesses[hi].tierOrder = tier
        }
        persist()
        toast = "已删除模型位 \(field)"
        flashToast()
    }

    /// 模型锁定（仅单行生效）：锁定后该行「请求的模型」不可改，供应商仍可改
    func setSlotLocked(harnessID: UUID, field: String, _ on: Bool) {
        guard let hi = config.harnesses.firstIndex(where: { $0.id == harnessID }),
              let si = config.harnesses[hi].slots.firstIndex(where: { $0.clientModelField == field }) else { return }
        config.harnesses[hi].slots[si].locked = on
        persist()
        toast = on ? "已锁定 \(field) 的模型" : "已解锁 \(field) 的模型"
        flashToast()
    }

    // MARK: - 默认来源（模型名称组 × API 线 → 默认供应商；路由选模型时按线自动填入）

    /// 某名称组某 API 线上的默认来源供应商；来源已被删除时视为未设置
    /// （I5：组键由调用方按条目自身 groupKey 给出，不再由 modelID 反查全库猜测）
    func defaultVendor(groupKey: String, api: ModelAPI) -> UUID? {
        guard let vid = config.defaultSourcesByAPI[groupKey]?[api.rawValue] else { return nil }
        return config.vendors.contains(where: { $0.id == vid }) ? vid : nil
    }

    /// 某名称组三条线的默认来源现状（默认来源编辑器用）
    func defaults(for groupKey: String) -> [String: UUID] {
        config.defaultSourcesByAPI[groupKey] ?? [:]
    }

    /// 设置/清除某组某线的默认来源（nil = 清除）；立即落盘
    func setDefault(groupKey: String, api: ModelAPI, vendorID: UUID?) {
        var line = config.defaultSourcesByAPI[groupKey] ?? [:]
        if let vendorID { line[api.rawValue] = vendorID } else { line.removeValue(forKey: api.rawValue) }
        if line.isEmpty { config.defaultSourcesByAPI.removeValue(forKey: groupKey) }
        else { config.defaultSourcesByAPI[groupKey] = line }
        persist()
    }

    /// 重命名名称组：全组条目改名 + 组键按线迁移（新名撞已有组 = 合并，新键既有值优先；旧键仍有存活条目不迁移）。
    /// R8 级联联动链（slug=display_name=模型名称）：codexSlug 随改名；Codex 槽位键随改名；
    /// 受管态下 config.toml 受管区 model 键与 model_modelrouter.json 条目即时同步（备份→校验→原子写阶梯）。
    func renameGroup(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, !newKey.isEmpty else { return }
        for i in config.models.indices where config.models[i].groupKey == oldKey {
            config.models[i].displayName = newKey
            if config.models[i].codexSlug != nil { config.models[i].codexSlug = newKey }   // slug 随名称（派生口径）
        }
        _ = ModelLibraryRules.renameGroupKey(&config, from: oldKey, to: newKey)
        // Codex 槽位键级联：新名已有槽（改名并组）→ 弃旧槽（首占优先），toast 披露
        var slotTouched = false
        var conflictDropped = false
        for hi in config.harnesses.indices
        where config.harnesses[hi].proto == .openai && (config.harnesses[hi].universal ?? false) == false {
            guard config.harnesses[hi].slots.contains(where: { $0.clientModelField == oldKey }) else { continue }
            slotTouched = true
            if config.harnesses[hi].slots.contains(where: { $0.clientModelField == newKey }) {
                config.harnesses[hi].slots.removeAll { $0.clientModelField == oldKey }
                conflictDropped = true
            } else {
                for si in config.harnesses[hi].slots.indices
                where config.harnesses[hi].slots[si].clientModelField == oldKey {
                    config.harnesses[hi].slots[si].clientModelField = newKey
                }
            }
        }
        persist()
        // I23 意图核实（2026-10-03）：slotTouched/conflictDropped 原拟 toast 披露（见上注释）但从未实现——现补齐。
        // 弃槽是用户应知晓的数据变更，静默级联与注释承诺不符。
        if conflictDropped {
            toast = "已级联改名 \(oldKey) → \(newKey)"
            toastDetail = "部分 Codex 卡新名已有同名槽位，旧名槽已弃用（首占优先）"
            flashToast()
        } else if slotTouched {
            toast = "已级联改名 \(oldKey) → \(newKey)（Codex 槽位）"
            flashToast()
        }
        // 复验 12 定案：~/.codex 两文件的变更只经 B 窗保存键落盘（改名不再即时写盘）——
        // 目录在下次保存时由当前槽位重生成；受管区 model 键若仍指旧名，B 窗快速配置会亮起引导重写
    }

    /// 注册 Claude 兼容模型位：ID = claude + 定位段 + 自定义后缀，按档序秩插入 tierOrder。
    /// 自定义定位不含 Haiku；官方 Haiku 预设经同一入口生成 ID。
    /// （同定位保持注册先后），并追加空 Slot；立即落盘生效。返回新 ID，非法/重复返回 nil。
    func registerClaudeTier(harnessID: UUID, position: String, suffix: String) -> String? {
        guard K.claudeCustomPositions.contains(position) else { return nil }
        let part = suffix.hasPrefix("-") ? suffix : "-" + suffix
        guard part.count > 1, part.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        let id = "claude" + position + part
        guard let hi = config.harnesses.firstIndex(where: { $0.id == harnessID }) else { return nil }
        var tier = config.harnesses[hi].tierOrder ?? []
        guard !tier.contains(id) else { return nil }
        let rank = Router.claudeTierRank(id)
        tier.insert(id, at: tier.firstIndex { Router.claudeTierRank($0) > rank } ?? tier.count)
        config.harnesses[hi].tierOrder = tier
        config.harnesses[hi].slots.append(Slot(clientModelField: id, userAdded: true))   // R16①：注册即「用户添加」（豁免检查）
        persist()
        return id
    }

    // MARK: - R16① 弃用检查与 ID 更新通道（S8①）

    struct DeprecatedSlot: Identifiable {
        let harnessID: UUID
        let field: String
        var id: String { "\(harnessID.uuidString)#\(field)" }
    }

    /// 启动检查结果（主窗弹窗用）
    @Published var launchDeprecated: [DeprecatedSlot] = []

    /// 单档判定：Claude 卡、无「用户添加」标、ID（剥日期）未命中固化集 → 不受支持
    func isDeprecatedSlot(_ h: Harness, _ s: Slot) -> Bool {
        Self.slotDeprecated(harnessIsClaude: h.tierOrder != nil, slot: s)
    }

    static func slotDeprecated(harnessIsClaude: Bool, slot: Slot) -> Bool {
        harnessIsClaude && slot.userAdded != true && !Router.isSupportedClaudeID(slot.clientModelField)
    }

    /// 不受支持档清单（纯函数，断言直驱）
    static func deprecatedSlots(in config: RouterConfig) -> [DeprecatedSlot] {
        var out: [DeprecatedSlot] = []
        for h in config.harnesses where h.tierOrder != nil {
            for s in h.slots where slotDeprecated(harnessIsClaude: true, slot: s) {
                out.append(DeprecatedSlot(harnessID: h.id, field: s.clientModelField))
            }
        }
        return out
    }

    /// 启动弃用检查（RootView onAppear 调用；存在不受支持档 → 主窗弹窗）
    func runStartupDeprecationCheck() {
        launchDeprecated = Self.deprecatedSlots(in: config)
    }

    /// ID 更新（R16① 唯一改档位键通道）：保留映射与锁定态，仅替换档位键；tierOrder 旧删新插按新秩；
    /// 目标查重；目标若未命中固化集则补「用户添加」标（防后续检查自陷循环）。
    @discardableResult
    func renameSlot(harnessID: UUID, from: String, to: String) -> Bool {
        let ok = Self.renameSlotInConfig(&config, harnessID: harnessID, from: from, to: to)
        if ok {
            persist()
            toast = "已更新模型 ID：\(from) → \(to)（映射保留）"
            toastDetail = "旧 ID 的后续请求不再命中；新 ID 即刻生效。"
            flashToast()
        }
        return ok
    }

    /// 纯函数核心（断言直驱）
    @discardableResult
    static func renameSlotInConfig(_ config: inout RouterConfig, harnessID: UUID, from: String, to: String) -> Bool {
        guard let hi = config.harnesses.firstIndex(where: { $0.id == harnessID }),
              let si = config.harnesses[hi].slots.firstIndex(where: { $0.clientModelField == from }),
              from != to,
              !config.harnesses[hi].slots.contains(where: { $0.clientModelField == to })
        else { return false }
        config.harnesses[hi].slots[si].clientModelField = to
        if !Router.isSupportedClaudeID(to) {
            config.harnesses[hi].slots[si].userAdded = true
        }
        if var tier = config.harnesses[hi].tierOrder {
            tier.removeAll { $0 == from }
            let rank = Router.claudeTierRank(to)
            tier.insert(to, at: tier.firstIndex { Router.claudeTierRank($0) > rank } ?? tier.count)
            config.harnesses[hi].tierOrder = tier
        }
        return true
    }

    /// 一次性豁免迁移：功能上线首启，原生四档之外的存量档补「用户添加」标
    /// （它们注册时还没有提示机制，视同自定义宽恕，避免升级即弹屏）
    static func migrateUserAddedIfNeeded(_ config: inout RouterConfig, store: ConfigStore) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "mr.claude.userAddedMigrationDone") else { return }
        d.set(true, forKey: "mr.claude.userAddedMigrationDone")
        var changed = false
        for hi in config.harnesses.indices where config.harnesses[hi].tierOrder != nil {
            for si in config.harnesses[hi].slots.indices {
                let f = config.harnesses[hi].slots[si].clientModelField
                if !K.claudeTierOrder.contains(f) && config.harnesses[hi].slots[si].userAdded != true {
                    config.harnesses[hi].slots[si].userAdded = true
                    changed = true
                }
            }
        }
        if changed { _ = store.save(config) }
    }

    // MARK: - 槽位双下拉（请求的模型 → 供应商；联动规则对齐原型）
    /// 某 API 线下可路由（端点在、URL 未挂、检测未判负）的模型条目
    private func entriesOK(_ api: ModelAPI) -> [ModelEntry] {
        config.models.filter { routable($0, api) }
    }

    /// 模型下拉选项：某 API 线下可用条目按「名称」（groupKey）聚合去重——一个名称一个选项。
    /// 修订3：选择单元为名称（管理员确认），不按 modelID 拆分（撤销修订2 后缀实现）。
    func modelPool(_ api: ModelAPI) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for m in entriesOK(api) where !seen.contains(m.groupKey) {
            seen.insert(m.groupKey)
            out.append(m.groupKey)
        }
        return out
    }

    /// 供应商下拉选项：某名称下全部可用供应商（跨该名称下所有 modelID 合并；按不变量每家至多一条，防御性去重）。
    /// groupName == nil（未选模型）→ 空池（防半绑定：先选供应商无法解析 ID）
    func vendorPool(groupName: String?, _ api: ModelAPI) -> [Vendor] {
        guard let groupName else { return [] }
        var ids: Set<UUID> = []
        for m in entriesOK(api) where m.groupKey == groupName { ids.insert(m.vendorID) }
        return config.vendors.filter { ids.contains($0.id) }
    }

    /// (模型 ID, 供应商) 配对在某 API 线下是否可路由
    func pairOK(modelID: String, vendorID: UUID, _ api: ModelAPI) -> Bool {
        config.models.contains { $0.modelID == modelID && $0.vendorID == vendorID && routable($0, api) }
    }

    /// 槽位当前绑定是否失效（有绑定但配对不可用）
    func slotInvalid(_ slot: Slot, _ api: ModelAPI) -> Bool {
        guard let mid = slot.modelID, let vid = slot.vendorID else { return false }
        return !pairOK(modelID: mid, vendorID: vid, api)
    }

    /// 槽位当前绑定条目的名称：精确配对 → 该 modelID 任一条目 groupKey → modelID 本身（孤儿兜底）
    func slotGroupName(_ slot: Slot) -> String? {
        guard let mid = slot.modelID else { return nil }
        if let exact = config.models.first(where: { $0.modelID == mid && $0.vendorID == slot.vendorID }) {
            return exact.groupKey
        }
        if let any = config.models.first(where: { $0.modelID == mid }) { return any.groupKey }
        return mid
    }

    /// 改「请求的模型」（名称级）：在该名称的可用条目中按 默认来源 → 保留当前供应商 → 首现 顺序解析完整绑定
    func setSlotModel(harnessID: UUID, field: String, groupName: String?) {
        guard let hi = config.harnesses.firstIndex(where: { $0.id == harnessID }),
              let si = config.harnesses[hi].slots.firstIndex(where: { $0.clientModelField == field }) else { return }
        let api: ModelAPI = config.harnesses[hi].proto == .anthropic ? .messages : .responses
        if config.harnesses[hi].slots[si].locked == true { return }   // 模型锁定：本行模型不可改
        guard let groupName, !groupName.isEmpty else {
            config.harnesses[hi].slots[si].modelID = nil
            config.harnesses[hi].slots[si].vendorID = nil
            persist()
            if api == .messages {
                toast = "\(Self.tierDisplay(field)) 已设为未映射"
                toastDetail = "该模型位未映射，请求将返回 404；未改动客户端配置。"
            } else {
                toast = "\(field) 已清除"
            }
            flashToast()
            return
        }
        let cands = entriesOK(api).filter { $0.groupKey == groupName }
        guard !cands.isEmpty else {
            toast = "该名称在当前线已无可用条目，未改动"
            flashToast()
            return
        }
        var pick = cands[0]
        var note = "该名称下首个可用供应商（无默认来源）"
        let dv = defaultVendor(groupKey: groupName, api: api)
        if let dv, let hit = cands.first(where: { $0.vendorID == dv }) {
            pick = hit
            note = "已按该名称 \(api.label) 线的默认来源填入供应商"
        } else if let cur = config.harnesses[hi].slots[si].vendorID,
                  let hit = cands.first(where: { $0.vendorID == cur }) {
            pick = hit
            note = "保留当前供应商"
            if dv != nil { note += "（默认来源在该线不可用，已跳过）" }   // 默认来源未命中池：本行保旧供应商
        } else if Set(cands.map(\.vendorID)).count == 1 {
            note = "该名称下唯一可用供应商"
        }
        config.harnesses[hi].slots[si].modelID = pick.modelID
        config.harnesses[hi].slots[si].vendorID = pick.vendorID
        persist()
        notifySlotMapped(harnessIndex: hi, slotIndex: si, note: note)
    }

    /// 改供应商（名称级）：按「名称 + 供应商」精确解析出可用条目并写完整绑定；nil = 双侧同清（锁定行拒绝）
    func setSlotVendor(harnessID: UUID, field: String, vendorID: UUID?) {
        guard let hi = config.harnesses.firstIndex(where: { $0.id == harnessID }),
              let si = config.harnesses[hi].slots.firstIndex(where: { $0.clientModelField == field }) else { return }
        let api: ModelAPI = config.harnesses[hi].proto == .anthropic ? .messages : .responses
        guard let vendorID else {
            if config.harnesses[hi].slots[si].locked == true {
                toast = "该行已锁定：需先解锁才能清除映射"
                flashToast()
                return   // 零写入
            }
            config.harnesses[hi].slots[si].vendorID = nil
            config.harnesses[hi].slots[si].modelID = nil
            config.harnesses[hi].slots[si].locked = nil
            persist()
            return
        }
        guard let name = slotGroupName(config.harnesses[hi].slots[si]) else {
            toast = "请先选择模型名称，再选供应商"
            flashToast()
            return
        }
        guard let e = entriesOK(api).first(where: { $0.groupKey == name && $0.vendorID == vendorID }) else {
            toast = "该供应商在此名称下没有可用条目，未改动"
            flashToast()
            return
        }
        let old = config.harnesses[hi].slots[si].modelID
        config.harnesses[hi].slots[si].vendorID = vendorID
        config.harnesses[hi].slots[si].modelID = e.modelID
        persist()
        notifySlotMapped(harnessIndex: hi, slotIndex: si,
                         note: old != e.modelID ? "已换绑到该供应商的模型 ID \(e.modelID)（原 \(old ?? "—")）" : "")
    }

    private func notifySlotMapped(harnessIndex hi: Int, slotIndex si: Int, note: String = "") {
        let h = config.harnesses[hi], s = h.slots[si]
        guard let mid = s.modelID, let vid = s.vendorID,
              let v = config.vendors.first(where: { $0.id == vid }) else { return }
        let name = slotGroupName(s) ?? mid
        toast = "\(h.tierOrder == nil ? s.clientModelField : Self.tierDisplay(s.clientModelField)) → \(name) · \(v.name)"
        let notePart = note.isEmpty ? "" : "\(note)；"
        toastDetail = "出站模型 \(mid)；\(notePart)下一次请求生效，未改动客户端配置。"
        flashToast()
    }

    // MARK: - 模型库写操作（语义在 ModelLibraryRules；此处只做 entryProbe / persist / toast 编排）

    /// 删模型条目（批量）：槽位清引用跳过锁定行、组空清默认来源、内存检测结论同步清；一次 persist
    func deleteEntries(_ ids: [UUID]) {
        let report = ModelLibraryRules.deleteEntries(&config, ids: ids)
        guard !report.removedEntryIDs.isEmpty else { return }
        for id in report.removedEntryIDs { entryProbe[id] = nil }
        persist()
        var parts: [String] = []
        if !report.clearedSlots.isEmpty { parts.append("\(report.clearedSlots.count) 个模型位回到未映射") }
        if !report.skippedLockedSlots.isEmpty { parts.append("\(report.skippedLockedSlots.count) 个锁定模型位已保留映射") }
        toast = "已删除 \(report.removedEntryIDs.count) 条模型条目" + (parts.isEmpty ? "" : "（\(parts.joined(separator: "；"))）")
        flashToast()
    }

    /// ModelSheet 保存（删除集合 + 精确 upsert + 组键迁移全在 Core）；一次 persist
    @discardableResult
    func applyModelSave(_ req: ModelLibraryRules.SaveRequest) -> ModelLibraryRules.SaveReport {
        let report = ModelLibraryRules.applySave(&config, req)
        if let d = report.deletion {
            for id in d.removedEntryIDs { entryProbe[id] = nil }
        }
        for s in report.swapUpdates { entryProbe[s.entryID] = nil }   // 修订3：换 ID 后旧探测结论必清（availability 先读内存）
        persist()
        return report
    }

    /// 探测/手动设置路径的条目写入：禁改非空名称（I5）；返回该条目
    @discardableResult
    func upsertEntry(modelID: String, vendorID: UUID, displayName: String?,
                     codexSlug: String?, codexMetaJSON: String?) -> ModelEntry {
        let r = ModelLibraryRules.upsertEntry(&config, modelID: modelID, vendorID: vendorID,
                                              displayName: displayName, codexSlug: codexSlug,
                                              codexMetaJSON: codexMetaJSON, overwriteName: false)
        return config.models.first(where: { $0.id == r.entryID })!
    }

    /// 组级元数据（组头 ⋯ 菜单第二入口专用）：名称下全部条目（不分模型 ID）统一写/清官方元数据，
    /// 有变化才落盘。独立于 upsertEntry——后者对已有条目只写非空元数据、无法实现「清空」语义。
    func setGroupMeta(groupKey: String, slug: String?, meta: String?) {
        let newMeta = (meta?.isEmpty == false) ? meta : nil
        let newSlug = (newMeta == nil) ? nil : slug
        var changed = false
        for i in config.models.indices where config.models[i].groupKey == groupKey {
            if config.models[i].codexMetaJSON != newMeta || config.models[i].codexSlug != newSlug {
                config.models[i].codexMetaJSON = newMeta
                config.models[i].codexSlug = newSlug
                changed = true
            }
        }
        if changed { persist() }
    }

    // MARK: - 接入可用性判定
    // 模型徽标（严格）：仅 APISupport == true 亮起；nil = 未检测（灰）
    // 供应商门禁：baseURL 存在且 URLSupport 检查未失败；URLSupport == false 时该 API 线探测也会被跳过
    func availability(_ m: ModelEntry, _ api: ModelAPI) -> Avail {
        guard let v = config.vendors.first(where: { $0.id == m.vendorID }) else { return .off("未配置") }
        guard !urlFailed(v, api) else { return .off("URL 未通过") }
        guard endpointExists(v, api) else { return .off("未配置") }
        guard m.tested == true else { return .untested }          // 未检测 → 黄
        return probe(m, api) == true ? .ok : .off("未通过")       // 已认定 → 亮 / 灰
    }

    /// 路由可用（槽位下拉/配对有效性）：端点在、URL 检查未失败、检测未判负——未检测也算可用
    func routable(_ m: ModelEntry, _ api: ModelAPI) -> Bool {
        guard let v = config.vendors.first(where: { $0.id == m.vendorID }) else { return false }
        guard endpointExists(v, api), !urlFailed(v, api) else { return false }
        return probe(m, api) != false
    }

    private func endpointExists(_ v: Vendor, _ api: ModelAPI) -> Bool {
        api == .messages ? v.anthropicBase != nil : v.openaiBase != nil
    }

    private func urlFailed(_ v: Vendor, _ api: ModelAPI) -> Bool {
        (api == .messages ? v.anthropicURLSupport : v.openaiURLSupport) == false
    }

    /// 检测结论：优先内存（本会话检测），回落磁盘（上次会话持久化的 probeResults）
    private func probe(_ m: ModelEntry, _ api: ModelAPI) -> Bool? {
        if let v = entryProbe[m.id]?[api.rawValue] { return v }
        return m.probeResults?[api.rawValue]
    }

    // MARK: - 通用路由（VENDOR/MODEL 直通）
    var universalHarness: Harness? { config.harnesses.first { $0.universal == true } }

    /// 供应商 → 通用路由 ID 前缀（纯英文名照抄，中文转全拼大写）
    func universalLabel(_ vendorID: UUID) -> String {
        PinYinLabel.label(for: config.vendors.first(where: { $0.id == vendorID })?.name ?? "?")
    }

    /// 模型条目的通用路由 ID：ZHIPU/GLM-5.3-Flash 形态
    func universalID(_ m: ModelEntry) -> String {
        "\(universalLabel(m.vendorID))/\(m.modelID)"
    }

    /// 某组某线默认来源的通用 ID（组头灯牌复制用）：
    /// 默认供应商在该名称组的条目中，取该线探测通过者，回落首条
    func defaultSourceUniversalID(groupKey: String, api: ModelAPI) -> String? {
        guard let vid = config.defaultSourcesByAPI[groupKey]?[api.rawValue],
              let v = config.vendors.first(where: { $0.id == vid }) else { return nil }
        let entries = config.models.filter { $0.vendorID == vid && $0.groupKey == groupKey }
        guard let e = entries.first(where: { $0.probeResults?[api.rawValue] == true }) ?? entries.first else { return nil }
        return "\(PinYinLabel.label(for: v.name))/\(e.modelID)"
    }

    // MARK: - 条目级真实连通性测试（S2/R10③：模型管理条目行 ECG 按键；与模型窗探测同一判定，产生真实消费）

    /// 条目测试进行中标记（ECG 按键禁用与图标反馈）
    @Published var entryRealProbe: [UUID: Bool] = [:]

    /// 条目测试作业数＝该条目 × 供应商开放线（messages 线＋responses/completions 两线；确认弹窗展示与实际一致）
    func entryRealProbeJobCount(_ e: ModelEntry) -> Int {
        guard let v = config.vendors.first(where: { $0.id == e.vendorID }) else { return 0 }
        var lines = 0
        if v.anthropicBase != nil && v.anthropicURLSupport != false { lines += 1 }
        if v.openaiBase != nil && v.openaiURLSupport != false { lines += 2 }
        return lines
    }

    /// 对该条目 × 供应商开放线发最小真实请求（与模型窗「探测」同一套检查器与判定）；
    /// 结论写 probeResults 落盘 → 路由表热换：判负即停止转发与下放，复测通过自动恢复。
    func probeEntryReal(_ e: ModelEntry) {
        guard let v = config.vendors.first(where: { $0.id == e.vendorID }) else { return }
        var apis: [ModelAPI] = []
        if v.anthropicBase != nil && v.anthropicURLSupport != false { apis.append(.messages) }
        if v.openaiBase != nil && v.openaiURLSupport != false {
            apis.append(.responses)
            apis.append(.completions)
        }
        guard !apis.isEmpty else {
            toast = "「\(e.displayLabel)」无可测试的开放端点（端点未配置或存在性检查失败）"
            flashToast()
            return
        }
        entryRealProbe[e.id] = true
        var finished = 0
        for api in apis {
            DispatchQueue.global().async { [weak self] in
                let (ph, _) = ModelSheet.checkEndpoint(v, api, e.modelID)
                DispatchQueue.main.async {
                    guard let self else { return }
                    var probe = self.entryProbe[e.id] ?? [:]
                    probe[api.rawValue] = ph.passed
                    self.entryProbe[e.id] = probe
                    finished += 1
                    if finished == apis.count { self.finishEntryRealProbe(entryID: e.id) }
                }
            }
        }
    }

    /// 收尾：内存结论合并落盘（tested/probedAt），一次 persist（表热换→停发/恢复即时生效）＋汇总 toast
    private func finishEntryRealProbe(entryID: UUID) {
        entryRealProbe[entryID] = nil
        guard let mi = config.models.firstIndex(where: { $0.id == entryID }),
              let probe = entryProbe[entryID], !probe.isEmpty else { return }
        var merged = config.models[mi].probeResults ?? [:]
        for (k, val) in probe { merged[k] = val }
        config.models[mi].probeResults = merged
        config.models[mi].probedAt = ISO8601DateFormatter().string(from: Date())
        config.models[mi].tested = true
        let okLines = probe.values.filter { $0 }.count
        let label = config.models[mi].displayLabel
        persist()
        toast = "「\(label)」真实测试完成：\(okLines)/\(probe.count) 条线可路由"
        toastDetail = okLines < probe.count ? "判负线已停止转发与下放；复测通过自动恢复。" : ""
        flashToast()
    }

    // MARK: - 供应商连通性测试（先查本机网络；只确认端点地址真实存在，不发 API 请求、不消耗 Token）
    func probeVendor(_ v: Vendor) {
        var running: [Proto: ProbePhase] = [:]
        if v.anthropicBase != nil { running[.anthropic] = .running }
        if v.openaiBase != nil { running[.openai] = .running }
        vendorProbe[v.id] = running
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            guard NetCheck.isOnline() else {
                DispatchQueue.main.async {
                    var offline = running
                    for k in offline.keys { offline[k] = .offline }
                    self.vendorProbe[v.id] = offline
                    self.toast = "网络未连接，无法检查「\(v.name)」的端点"
                    self.flashToast()
                }
                return
            }
            var result: [Proto: ProbePhase] = [:]
            var notes: [String] = []
            func presence(_ base: URL) -> Bool {
                if case .exists = EndpointPresenceCheck.check(base: base) { return true }
                return false
            }
            if let base = v.anthropicBase {
                let ok = presence(base)
                result[.anthropic] = ok ? .ok : .unreachable
                notes.append("Anthropic \(ok ? "✓ 端点存在" : "✗ 不可达")")
            }
            if let base = v.openaiBase {
                let ok = presence(base)
                result[.openai] = ok ? .ok : .unreachable
                notes.append("OpenAI \(ok ? "✓ 端点存在" : "✗ 不可达")")
            }
            DispatchQueue.main.async {
                self.vendorProbe[v.id] = result
                // 结论写进供应商的持久化布尔（跟随供应商走；端点变更时会重置）
                if let vi = self.config.vendors.firstIndex(where: { $0.id == v.id }) {
                    if self.config.vendors[vi].anthropicBase != nil {
                        self.config.vendors[vi].anthropicURLSupport = (result[.anthropic] == .ok)
                    }
                    if self.config.vendors[vi].openaiBase != nil {
                        self.config.vendors[vi].openaiURLSupport = (result[.openai] == .ok)
                    }
                    self.persist()
                }
                self.toast = "「\(v.name)」端点检查：" + notes.joined(separator: " · ")
                self.flashToast()
            }
        }
    }

    // MARK: - 剪贴板与 Toast
    /// 复制进剪贴板；flash=false 不触发主窗 toast（调用方自行呈现反馈，如配置窗内本地 toast）
    func copy(_ text: String, flash: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard flash else { return }
        if text.hasPrefix(K.keyPrefix) {   // 访问 Key 进剪贴板：提醒其他应用可读
            toast = "已复制访问 Key"
            toastDetail = "注意：剪贴板可被其他应用读取，用完及时覆盖"
        } else {
            toast = "已复制"
        }
        flashToast()
    }

    func flashToast() {
        toastGen += 1
        let g = toastGen
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastDuration) { [weak self] in
            guard let self, self.toastGen == g else { return }   // 已有新 toast 则不清
            self.toast = ""
            self.toastDetail = ""
        }
    }
}
