import Foundation

// MARK: - Codex CLI 配置持久层（R8）
// ~/.codex/config.toml 受管区外科手术写入 + ~/.codex/model_modelrouter.json 目录生成。
// 写入纪律（沿 R7 与 DeepSeek 官方脚本标杆）：备份 → 副本编辑 → TOML 语法校验 → 原子覆盖；任一步失败不动原件。
// 用户自定义键/自定义区域永不触碰（区外逐字节保留）；既有 ~/.codex/models.json 不触碰（接管后由新目录文件取代其作用）。
// 线程模型与 ClaudeSettingsStore 一致：同步 IO，调用方保证主线程。
public final class CodexConfigStore {
    public let path: String
    public let catalogPath: String
    public let backupDir: String

    /// 最近一次 save/saveCatalog 的失败原因（供调用方提示；成功为 nil）
    public private(set) var lastError: String?

    public init(path: String = CodexConfigStore.defaultPath,
                catalogPath: String = CodexConfigStore.defaultCatalogPath,
                backupDir: String = CodexConfigStore.defaultBackupDir) {
        self.path = path
        self.catalogPath = catalogPath
        self.backupDir = backupDir
    }

    // MARK: - 默认位置（环境变量覆盖，供隔离验证/调试）

    /// config.toml 位置：MR_CODEX_CONFIG_PATH 覆盖，否则 ~/.codex/config.toml
    public static let defaultPath: String = {
        ProcessInfo.processInfo.environment["MR_CODEX_CONFIG_PATH"]
            ?? "\(NSHomeDirectory())/.codex/config.toml"
    }()

    /// 模型目录位置：MR_CODEX_CATALOG_PATH 覆盖，否则 ~/.codex/model_modelrouter.json
    public static let defaultCatalogPath: String = {
        ProcessInfo.processInfo.environment["MR_CODEX_CATALOG_PATH"]
            ?? "\(NSHomeDirectory())/.codex/model_modelrouter.json"
    }()

    /// 备份目录：MR_CODEX_BACKUP_DIR 覆盖，否则与 Claude 侧同目录（不放 ~/.codex，避免污染 Codex 自身目录）
    public static let defaultBackupDir: String = {
        ProcessInfo.processInfo.environment["MR_CODEX_BACKUP_DIR"]
            ?? "\(NSHomeDirectory())/Library/Application Support/ModelRouter"
    }()

    // MARK: - 读取

    /// 读取结果：ok 带全文 / missing 文件不存在 / unreadable 存在但不可读
    public enum LoadOutcome {
        case ok(String)
        case missing
        case unreadable
    }

    /// 读 config.toml 原文。不做任何补齐/迁移，只如实反映磁盘内容。
    public func loadText() -> LoadOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .missing }
        guard let data = fm.contents(atPath: path), let s = String(data: data, encoding: .utf8) else {
            return .unreadable
        }
        return .ok(s)
    }

    /// 读目录文件全文（供预览/比对）；文件不存在返回 nil。
    public func loadCatalogText() -> String? {
        guard let data = FileManager.default.contents(atPath: catalogPath) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 落盘（备份 + 校验 + 原子写）

    /// 把当前文件复制到备份目录。命名 <文件名>.<reason>-<yyyyMMdd-HHmmss>.bak，同一 reason 只留最近 5 份，0600。源不存在返回 nil。
    @discardableResult
    public func backup(file: String, reason: String) -> String? {
        SafeFileWriter.backup(file: file, reason: reason, to: backupDir)
    }

    /// config.toml 落盘：备份（pre-codexwrite）→ TOML 语法校验（失败中止不动原件）→ 原子写。
    /// 文件不存在时以 0600 新建（内容含访问密钥）；已存在则不改动权限。目标目录不存在直接失败（不代建）。
    @discardableResult
    public func save(_ text: String) -> Bool {
        lastError = nil
        do {
            _ = try TomlLite.parse(text)   // 写前语法校验，失败即中止
        } catch {
            lastError = (error as? TomlLite.ParseError).map { "\($0)" } ?? "TOML 语法校验失败"
            return false
        }
        _ = backup(file: path, reason: "pre-codexwrite")
        if SafeFileWriter.write(text.data(using: .utf8) ?? Data(), to: path) { return true }
        lastError = "原子写失败：\(path)"
        return false
    }

    /// 目录落盘：备份（pre-catalogwrite）→ pretty JSON 原子写；文件不存在时以 0600 新建。
    @discardableResult
    public func saveCatalog(_ models: [[String: Any]]) -> Bool {
        lastError = nil
        let obj: [String: Any] = ["models": models]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            lastError = "目录 JSON 序列化失败"
            return false
        }
        _ = backup(file: catalogPath, reason: "pre-catalogwrite")
        if SafeFileWriter.write(data, to: catalogPath) { return true }
        lastError = "原子写失败：\(catalogPath)"
        return false
    }
}
