import Foundation

// MARK: - 用户增补元数据字典（R23：字典可增补、持久有效）
// 存储＝Application Support/ModelRouter/user-metaparam-dict.json（应用自有配置，非目标配置文件——
// 不适用单写盘路径原则，增删改即时落盘）。全局生效：跨模型、跨窗口、重启保留。
// 条目形态＝MetaParam（parentPath 记层级挂靠）；控件恒 .text（结构化 JSON 经 structuralOrString 往返）。
// 隔离口径＝与 AppState 同（不标 @MainActor，仅 UI 主线程使用；断言台直驱）。
final class UserMetaDict: ObservableObject {
    static let shared = UserMetaDict()

    @Published private(set) var entries: [MetaParam] = []

    /// 断言台用：置 false 后增删改不落盘（真机恒 true；不影响读取）
    var persist = true

    static var storageURL: URL {
        // MR_USER_DICT_PATH：测试/隔离用覆盖（与 MR_CONFIG_PATH 等同一惯例）
        if let p = ProcessInfo.processInfo.environment["MR_USER_DICT_PATH"] {
            return URL(fileURLWithPath: p)
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModelRouter", isDirectory: true)
        return dir.appendingPathComponent("user-metaparam-dict.json")
    }

    private init() { load() }

    // MARK: 载入/保存

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let arr = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else { return }
        entries = arr.compactMap(Self.decode)
    }

    private func save() {
        guard persist else { return }
        let arr = entries.map(Self.encode)
        guard let d = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = Self.storageURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    private static func decode(_ raw: [String: Any]) -> MetaParam? {
        guard let key = raw["key"] as? String, !key.isEmpty else { return nil }
        let control: MetaParam.Control
        if let prefill = raw["prefill"] as? String, !prefill.isEmpty { control = .text(prefill) }
        else { control = .text("") }
        return MetaParam(key: key,
                         zh: (raw["zh"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key,
                         group: "用户增补",
                         desc: (raw["desc"] as? String) ?? "",
                         inferred: false,
                         control: control,
                         howTo: (raw["howTo"] as? String) ?? "",
                         status: .active,
                         parentPath: raw["parentPath"] as? String)
    }

    private static func encode(_ e: MetaParam) -> [String: Any] {
        var raw: [String: Any] = ["key": e.key, "zh": e.zh, "desc": e.desc, "howTo": e.howTo]
        if case .text(let prefill) = e.control, !prefill.isEmpty { raw["prefill"] = prefill }
        if let p = e.parentPath, !p.isEmpty { raw["parentPath"] = p }
        return raw
    }

    // MARK: 增删改

    /// 判定键是否「已知」：parentPath 层级上命中（nil/空＝按条目顶层与内置字典判）
    static func isKnown(_ key: String, parentPath: String?) -> Bool {
        let pp = parentPath ?? ""
        if pp.isEmpty { return MetaParamDict.all.contains { $0.key == key } || shared.entries.contains { $0.key == key && ($0.parentPath ?? "").isEmpty } }
        return shared.entries.contains { $0.key == key && ($0.parentPath ?? "") == pp }
    }

    /// 同层级下不允许重名（key＋parentPath 唯一）
    func canAdd(key: String, parentPath: String?) -> Bool {
        let pp = parentPath ?? ""
        if pp.isEmpty, MetaParamDict.all.contains(where: { $0.key == key }) { return false }
        return !entries.contains { $0.key == key && ($0.parentPath ?? "") == pp }
    }

    func add(_ e: MetaParam) {
        guard canAdd(key: e.key, parentPath: e.parentPath) else { return }
        entries.append(e)
        entries.sort { $0.key < $1.key }
        save()
    }

    /// 同（key＋parentPath）存在则替换、否则新增（自动解析确认与字典条目编辑共用）
    func upsert(_ e: MetaParam) {
        let pp = e.parentPath ?? ""
        if let i = entries.firstIndex(where: { $0.key == e.key && ($0.parentPath ?? "") == pp }) {
            entries[i] = e
        } else if canAdd(key: e.key, parentPath: e.parentPath) {
            entries.append(e)
        } else {
            return
        }
        entries.sort { $0.key < $1.key }
        save()
    }

    func remove(key: String, parentPath: String?) {
        let pp = parentPath ?? ""
        entries.removeAll { $0.key == key && ($0.parentPath ?? "") == pp }
        save()
    }

    /// 顶层条目（供参数行/已添加判定与内置合并渲染）
    var topLevel: [MetaParam] { entries.filter { ($0.parentPath ?? "").isEmpty } }
}
