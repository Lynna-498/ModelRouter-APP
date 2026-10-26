import Foundation
import Security
import CryptoKit

// MARK: - Key 存储（厂商真 Key 与本地访问 Key 永不进 config/日志；两域物理隔离）
//
// 分域布局：应用生成的访问 Key（access）与用户填写的供应商真 Key（vendor）分开存放——
//   文件后端 = keys/access/ 与 keys/vendor/ 两个子目录（目录 0700 / 文件 0600）；
//   Keychain 后端 account 前缀 = "access." / "vendor."（旧裸名条目读时兜底）。
// 默认走文件兜底（~/Library/Application Support/ModelRouter/keys/）：
//   未签名/ad-hoc 的 CLI/.app 在 macOS 27 上首次访问 Keychain 会弹授权框（非交互场景直接阻塞），
//   文件兜底保证启动不挂；签名 .app 想用 Keychain 时设 `MR_USE_KEYCHAIN=1`（签名后通常不弹）。
//   `MR_KEYSTORE_DIR=<dir>` 可覆盖文件目录（调试用）。
public enum KeychainStore {
    /// 存储域：应用生成的访问 Key 与用户填写的供应商真 Key 物理隔离
    public enum KeyDomain: String { case access, vendor }

    private static let service = "ModelRouter"
    private static let defaultFileDir =
        "\(NSHomeDirectory())/Library/Application Support/ModelRouter/keys"

    private static var useKeychain: Bool {
        ProcessInfo.processInfo.environment["MR_USE_KEYCHAIN"] == "1"
    }
    private static var fileDir: String {
        ProcessInfo.processInfo.environment["MR_KEYSTORE_DIR"] ?? defaultFileDir
    }

    // MARK: - 对外三件事：写 / 读 / 删
    public static func set(_ name: String, value: String, domain: KeyDomain) {
        if useKeychain { keychainSet(name, value, domain) } else { fileSet(fileDir, name, value, domain) }
    }

    public static func get(_ name: String, domain: KeyDomain) -> String? {
        if useKeychain { return keychainGet(name, domain) } else { return fileGet(fileDir, name, domain) }
    }

    public static func delete(_ name: String, domain: KeyDomain) {
        if useKeychain { keychainDelete(name, domain) } else { fileDelete(fileDir, name, domain) }
    }

    /// 一次性迁移旧平铺目录：vendor-*.key → vendor/，其余 → access/。
    /// 场景 A（旧→新首次升级）：平铺文件搬入子目录。
    /// 场景 B（升级后旧版本回访过——旧代码发现平铺 key 缺失会重新生成）：
    ///   平铺与子目录并存且值不同时，取 mtime 较新者为唯一真源（旧版生成的新 key 已被
    ///   用户粘贴进客户端，不能丢），旧文件删除——保证单一真源、无孤儿文件。
    /// 必须在 ConfigStore.loadOrSeed（ensureAccessKey）之前调用。幂等。
    public static func migrateFlatLayoutIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: fileDir) else { return }
        for f in files where f.hasSuffix(".key") {
            let src = URL(fileURLWithPath: fileDir).appendingPathComponent(f)
            let sub = f.hasPrefix("vendor-") ? KeyDomain.vendor.rawValue : KeyDomain.access.rawValue
            let dstDir = URL(fileURLWithPath: fileDir).appendingPathComponent(sub, isDirectory: true)
            try? fm.createDirectory(atPath: dstDir.path, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dstDir.path)
            let dst = dstDir.appendingPathComponent(f)
            if !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)   // 场景 A：直接搬入
                continue
            }
            // 场景 B：并存——值相同则删平铺；值不同则 mtime 新者胜
            let sameValue = (try? Data(contentsOf: src)) == (try? Data(contentsOf: dst))
            if sameValue {
                try? fm.removeItem(at: src)
                continue
            }
            let srcDate = (try? fm.attributesOfItem(atPath: src.path))?[.modificationDate] as? Date ?? .distantPast
            let dstDate = (try? fm.attributesOfItem(atPath: dst.path))?[.modificationDate] as? Date ?? .distantPast
            if srcDate > dstDate {
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: src, to: dst)   // 平铺较新（旧版本生成的新 key）→ 覆盖子目录
            } else {
                try? fm.removeItem(at: src)          // 子目录较新 → 删平铺孤儿
            }
        }
    }

    // MARK: - 本地访问 Key 生成与哈希（入站 Bearer Key 哈希后比对身份）
    public static func generateAccessKey() -> String {
        var bytes = [UInt8](repeating: 0, count: K.keyHexLen / 2)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return K.keyPrefix + bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func hashKey(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Keychain 后端（签名 .app / MR_USE_KEYCHAIN=1）
    private static func keychainAccount(_ name: String, _ domain: KeyDomain) -> String {
        "\(domain.rawValue).\(name)"
    }

    private static func keychainSet(_ name: String, _ value: String, _ domain: KeyDomain) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(name, domain),
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(attrs as CFDictionary, nil)
    }

    private static func keychainGet(_ name: String, _ domain: KeyDomain) -> String? {
        if let v = keychainRead(account: keychainAccount(name, domain)) { return v }
        return keychainRead(account: name)   // 旧裸名条目兜底（迁移前遗留）
    }

    private static func keychainRead(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete(_ name: String, _ domain: KeyDomain) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(name, domain),
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    // MARK: - 文件后端（默认；目录 0700 / 文件 0600，仅属主可读；按域分子目录）
    private static func fileURL(_ dir: String, _ name: String, _ domain: KeyDomain) -> URL {
        let sub = URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent(domain.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sub.path)
        return sub.appendingPathComponent("\(name).key")
    }

    /// 读路径专用：只拼路径，不建目录不改权限（get 在转发热路径与 UI body 里都会被调用）
    private static func fileReadURL(_ dir: String, _ name: String, _ domain: KeyDomain) -> URL {
        URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent(domain.rawValue, isDirectory: true)
            .appendingPathComponent("\(name).key")
    }

    private static func fileSet(_ dir: String, _ name: String, _ value: String, _ domain: KeyDomain) {
        let url = fileURL(dir, name, domain)
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path,
                                       contents: Data(value.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    private static func fileGet(_ dir: String, _ name: String, _ domain: KeyDomain) -> String? {
        guard let data = try? Data(contentsOf: fileReadURL(dir, name, domain)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func fileDelete(_ dir: String, _ name: String, _ domain: KeyDomain) {
        try? FileManager.default.removeItem(at: fileURL(dir, name, domain))
    }
}
