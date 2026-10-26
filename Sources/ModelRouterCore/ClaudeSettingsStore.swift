import Foundation

// MARK: - Claude Code 用户设置持久层（~/.claude/settings.json；备份落 App Support；原子写）
// 供「代劳写 Claude Code 接入配置」使用：只写接入文档写明的事，用户自定义键一律原样保留。
// 线程模型与 ConfigStore 一致：同步 IO，调用方保证主线程。
public final class ClaudeSettingsStore {
    public let path: String
    public let backupDir: String

    /// 最近一次 save 的失败原因（供调用方横幅提示；成功为 nil）
    public private(set) var lastError: String?

    public init(path: String = ClaudeSettingsStore.defaultPath,
                backupDir: String = ClaudeSettingsStore.defaultBackupDir) {
        self.path = path
        self.backupDir = backupDir
    }

    // MARK: - 默认位置（环境变量覆盖，供隔离验证/调试）

    /// 设置文件位置：MR_CLAUDE_SETTINGS_PATH 覆盖，否则 ~/.claude/settings.json
    public static let defaultPath: String = {
        ProcessInfo.processInfo.environment["MR_CLAUDE_SETTINGS_PATH"]
            ?? "\(NSHomeDirectory())/.claude/settings.json"
    }()

    /// 备份目录：MR_CLAUDE_BACKUP_DIR 覆盖，否则 ~/Library/Application Support/ModelRouter
    /// （备份**不放 ~/.claude**，避免污染 Claude Code 自身读取的目录）
    public static let defaultBackupDir: String = {
        ProcessInfo.processInfo.environment["MR_CLAUDE_BACKUP_DIR"]
            ?? "\(NSHomeDirectory())/Library/Application Support/ModelRouter"
    }()

    /// 本类统一管理的 7 个 env 键（前代键清理与半复原均以此为准）
    public static let managedEnvKeys: [String] = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
        "CLAUDE_CODE_SUBAGENT_MODEL",
        "CLAUDE_CODE_EFFORT_LEVEL",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
    ]

    // MARK: - 读取

    /// 读取结果：ok 带顶层字典 / missing 文件不存在 / badJSON 解析失败或顶层非对象
    public enum LoadOutcome {
        case ok([String: Any])
        case missing
        case badJSON(detail: String)
    }

    /// 读设置文件。不做任何补齐/迁移，只如实反映磁盘内容。
    public func load() -> LoadOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .missing }
        guard let data = fm.contents(atPath: path) else {
            return .badJSON(detail: "文件存在但不可读")
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = obj as? [String: Any] else {
                return .badJSON(detail: "顶层不是 JSON 对象（实际为 \(type(of: obj))）")
            }
            return .ok(dict)
        } catch {
            return .badJSON(detail: "JSON 解析失败：\((error as NSError).localizedDescription)")
        }
    }

    // MARK: - 接入配置纯函数（无 IO；dict 为 settings.json 顶层字典）

    /// 模型选择器一项：model 为槽位纯 ID（[1m] 后缀由本类统一拼接）
    public struct PickerOption {
        public var model: String
        public var label: String
        public var description: String
        public var oneM: Bool

        public init(model: String, label: String, description: String, oneM: Bool) {
            self.model = model
            self.label = label
            self.description = description
            self.oneM = oneM
        }
    }

    /// 快速接入参数：四固定（baseURL/token/两开关）＋三选择（子代理模型/思考强度/压缩窗口）＋模型选择器
    public struct QuickConfig {
        public var baseURL: String
        public var authToken: String
        public var subModel: String
        public var effort: String
        public var compactWindow: String
        public var options: [PickerOption]

        public init(baseURL: String, authToken: String, subModel: String,
                    effort: String, compactWindow: String, options: [PickerOption]) {
            self.baseURL = baseURL
            self.authToken = authToken
            self.subModel = subModel
            self.effort = effort
            self.compactWindow = compactWindow
            self.options = options
        }
    }

    /// Haiku 定位判定：ID 前缀 "claude-haiku"（平台约束——haiku 位不参与 [1m] 后缀）
    public static func isHaikuModel(_ id: String) -> Bool {
        id.hasPrefix("claude-haiku")
    }

    /// 快速配置预填（R7 追加 2026-09-27）：按双锚匹配文件中既有 modelPicker.options——
    /// 每个档位先按内部槽位 ID、未命中再按该槽位当前映射的供应商模型 ID 比对（两锚均剥 [1m]）。
    /// 命中内容统一归到槽位 ID 键下返回；model 为空/非字符串的条目跳过；同一纯 ID 多条取后条。
    /// 纯函数无 IO；写出侧 model 恒为内部槽位 ID（confirm/applyQuick 既有规则），供应商 ID 条目写出时自动改回。
    public static func pickerPrefill(
        existing: [[String: Any]],
        anchors: [(slotID: String, vendorModelID: String?)]
    ) -> [String: (label: String, description: String, oneM: Bool)] {
        var fileIndex: [String: (label: String, description: String, oneM: Bool)] = [:]
        for o in existing {
            guard let m = o["model"] as? String, !m.isEmpty else { continue }
            let pure = m.replacingOccurrences(of: "[1m]", with: "")
            fileIndex[pure] = ((o["label"] as? String) ?? "",
                               (o["description"] as? String) ?? "",
                               m.contains("[1m]"))
        }
        var result: [String: (label: String, description: String, oneM: Bool)] = [:]
        for a in anchors {
            if let hit = fileIndex[a.slotID] {
                result[a.slotID] = hit
            } else if let vid = a.vendorModelID, let hit = fileIndex[vid] {
                result[a.slotID] = hit
            }
        }
        return result
    }

    /// 快速接入：写入受管 env 键与 modelPicker，并清理前代接入键；其余键原样不动（不排序、不重编码）。
    /// 返回被清理的前代遗留键名列表（顶层键与 env 键混排，供调用方提示）。
    @discardableResult
    public static func applyQuick(_ spec: QuickConfig, to dict: inout [String: Any]) -> [String] {
        var removed: [String] = []

        // 1) 顶层前代键清理
        for key in ["model", "modelOverrides"] {
            if dict.removeValue(forKey: key) != nil { removed.append(key) }
        }

        // 2) env 段：非字典值视为缺失而重建（不保留脏值）
        var env = dict["env"] as? [String: Any] ?? [:]
        // env 段前代键：ANTHROPIC_MODEL 与 ANTHROPIC_DEFAULT_*_MODEL_NAME（先收集再删，避免边遍历边改）
        if env.removeValue(forKey: "ANTHROPIC_MODEL") != nil { removed.append("ANTHROPIC_MODEL") }
        for key in env.keys.filter({ isLegacyDefaultModelKey($0) }).sorted() {
            env.removeValue(forKey: key)
            removed.append(key)
        }
        // 四固定＋三选择（值一律字符串）
        env["ANTHROPIC_BASE_URL"] = spec.baseURL
        env["ANTHROPIC_AUTH_TOKEN"] = spec.authToken
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] = "1"
        env["CLAUDE_CODE_SUBAGENT_MODEL"] = spec.subModel
        env["CLAUDE_CODE_EFFORT_LEVEL"] = spec.effort
        env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = spec.compactWindow
        dict["env"] = env

        // 3) modelPicker 整体替换（旧后缀先剥，haiku 恒不加）
        let options: [[String: Any]] = spec.options.map { opt in
            let base = opt.model.replacingOccurrences(of: "[1m]", with: "")
            let model = (opt.oneM && !isHaikuModel(base)) ? base + "[1m]" : base
            return ["model": model, "label": opt.label, "description": opt.description]
        }
        dict["modelPicker"] = ["options": options, "replaceBuiltInOptions": true]

        return removed
    }

    /// 半复原：仅移除本类接入相关的键（env 7 键＋ANTHROPIC_MODEL＋默认模型名键；顶层 model/modelPicker/modelOverrides），
    /// 保留用户自定义键；env 清空则删除 env 键；其余键不动。
    public static func applyHalfRestore(to dict: inout [String: Any]) {
        if var env = dict["env"] as? [String: Any] {
            for key in managedEnvKeys { env.removeValue(forKey: key) }
            env.removeValue(forKey: "ANTHROPIC_MODEL")
            for key in env.keys.filter({ isLegacyDefaultModelKey($0) }) { env.removeValue(forKey: key) }
            if env.isEmpty {
                dict.removeValue(forKey: "env")
            } else {
                dict["env"] = env
            }
        }
        for key in ["model", "modelPicker", "modelOverrides"] {
            dict.removeValue(forKey: key)
        }
    }

    /// 彻底复原：清空为初始形态（仅空 env），供「清空后重写」场景作基底
    public static func emptyFullRestore() -> [String: Any] {
        ["env": [String: Any]()]
    }

    // MARK: - 落盘（备份 + 原子写）

    /// 把当前设置文件复制到备份目录（目录不存在则建）。命名 settings.json.<reason>-<yyyyMMdd-HHmmss>.bak，
    /// 同一 reason 只留最近 5 份（按文件名排序 = 时间序），超出的删最旧；备份文件设 0600。源文件不存在返回 nil。
    @discardableResult
    public func backup(reason: String) -> String? {
        SafeFileWriter.backup(file: path, reason: reason, to: backupDir)
    }

    /// 落盘：先备份现有文件（pre-cliwrite），再以 JSONSerialization(.prettyPrinted) 原子写 path。
    /// 不加 .sortedKeys——保持字典解析序，不改动用户自定义键的排列。任何失败返回 false 并置 lastError。
    /// 目标目录不存在时直接失败（不代建）；既有文件权限不动，新建文件 0600（T4/I29 修复：内容含访问密钥）。
    @discardableResult
    public func save(_ dict: [String: Any]) -> Bool {
        lastError = nil
        _ = backup(reason: "pre-cliwrite")   // 源文件存在才产生备份
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
            if SafeFileWriter.write(data, to: path) { return true }
            lastError = "原子写失败：\(path)"
            return false
        } catch {
            lastError = (error as NSError).localizedDescription
            return false
        }
    }

    /// 前代默认模型名键：ANTHROPIC_DEFAULT_<定位>_MODEL_NAME
    private static func isLegacyDefaultModelKey(_ key: String) -> Bool {
        key.range(of: legacyDefaultModelPattern, options: .regularExpression) != nil
    }

    private static let legacyDefaultModelPattern = #"^ANTHROPIC_DEFAULT_.*_MODEL_NAME$"#
}
