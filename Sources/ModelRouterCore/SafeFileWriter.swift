import Foundation

// MARK: - 安全写盘收敛（T11/I36＋T4/I29）
/// 全部落盘路径共用的三件套：备份（同 reason 留最近 5 份，0600）→ 原子写 → 权限收紧。
/// 权限口径：newFileOnly＝仅新建设 0600、既有文件不动（Codex/Claude 用户文件）；always＝每次收紧
/// （ModelRouter 自有 config.json 的既有行为，拓扑文件保持原保证）。备份文件一律 0600（可能含密钥）。
enum SafeFileWriter {
    enum PinMode { case newFileOnly, always }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 备份：源文件不存在返回 nil。backupDir 缺省＝目标同目录；命名 <文件名>.<reason>-<时间戳>.bak。
    /// 顺带修正 ConfigStore 旧实现的保留判断（曾以全路径作前缀匹配目录内文件名，永不命中导致不剪枝）。
    @discardableResult
    static func backup(file: String, reason: String, to backupDir: String? = nil) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file), let data = fm.contents(atPath: file) else { return nil }
        let dir = backupDir ?? (file as NSString).deletingLastPathComponent
        let base = (file as NSString).lastPathComponent
        let bak = (dir as NSString)
            .appendingPathComponent("\(base).\(reason)-\(stamp.string(from: Date())).bak")
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: bak))
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bak)
        } catch {
            return nil
        }
        prune(prefix: "\(base).\(reason)-", in: dir)
        return bak
    }

    /// 同一 reason 只留最近 5 份（文件名排序＝时间序），超出的删最旧。
    private static func prune(prefix: String, in dir: String) {
        let fm = FileManager.default
        let olds = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }
            .sorted()
        if olds.count > 5 {
            for f in olds.prefix(olds.count - 5) {
                try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(f))
            }
        }
    }

    /// 原子写＋权限收紧。createTargetDirectory＝true 时代建目标目录（仅 config.json 使用）。
    @discardableResult
    static func write(_ data: Data, to path: String,
                      pinMode: PinMode = .newFileOnly,
                      createTargetDirectory: Bool = false) -> Bool {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if createTargetDirectory,
           !fm.fileExists(atPath: dir),
           (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) == nil {
            return false
        }
        let existed = fm.fileExists(atPath: path)
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            if pinMode == .always || !existed {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            return true
        } catch {
            return false
        }
    }
}
