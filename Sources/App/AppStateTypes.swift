import SwiftUI
import AppKit
import Network
import ModelRouterCore
import os

// MARK: - 模型接入的三条 API 线（模型管理的检测/徽标维度；与供应商的端点维度相互独立）
enum ModelAPI: String {
    case messages, responses, completions

    var label: String {
        switch self {
        case .messages:    return "Messages"
        case .responses:   return "Responses"
        case .completions: return "Completions"
        }
    }

    /// 协议全称（路由卡兼容标签行与默认来源编辑器用）
    var fullName: String {
        switch self {
        case .messages:    return "Anthropic Messages API"
        case .responses:   return "OpenAI Responses API"
        case .completions: return "OpenAI Chat Completions API"
        }
    }
}

// MARK: - 网络连通性预检（所有网络测试的前置步骤；未联网直接报网络错误，不发请求）
enum NetCheck {
    /// 同步版：仅供后台队列调用（等待 NWPathMonitor 首回调，最长 1.5s）。
    static func isOnline() -> Bool {
        let monitor = NWPathMonitor()
        let sem = DispatchSemaphore(value: 0)
        var online = false
        monitor.pathUpdateHandler = { path in
            online = path.status == .satisfied
            sem.signal()
        }
        monitor.start(queue: DispatchQueue(label: "mr.netcheck"))
        _ = sem.wait(timeout: .now() + 1.5)
        monitor.cancel()
        return online
    }

    /// 主线程安全版（T3/I28）：后台队列复用同步实现，结论回主线程。
    static func isOnlineAsync(_ completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let online = isOnline()
            DispatchQueue.main.async { completion(online) }
        }
    }
}

// MARK: - 监视器事件（Core 埋点的 LogEvent + 本进程单调序号；导出即按此结构落盘）
struct MonitorEvent: Codable, Identifiable {
    let seq: Int
    let event: LogEvent
    var id: Int { seq }
}

// MARK: - 菜单栏状态点等级（R5；idle = 空窗无事件）
enum MenuDotLevel: Hashable {
    case ok, warn, err, idle
}

// MARK: - 端口弹窗状态（R1 自定义端口；conflict 由监听失败自动弹出，settings 由侧栏状态行主动打开）
struct PortSheetState: Identifiable {
    enum Mode {
        case settings                            // 主动打开：改端口
        case conflict(port: Int, detail: String) // 监听失败自动弹出：重试 / 改端口 / 稍后
    }
    let id = "portSheet"   // 恒定 id：conflict 目标更新（新端口也被占）时原地刷新，不关窗重开
    var mode: Mode
}

// MARK: - 导出文件结构（脱敏：不含 Key/Key 引用名/请求正文，可直接外发排障）
struct LogExport: Codable {
    struct ExportVendor: Codable {
        let name: String
        let anthropicBase: String?
        let openaiBase: String?
    }
    struct ExportSlot: Codable {
        let slot: String
        let model: String?
        let vendor: String?
    }
    struct ExportHarness: Codable {
        let name: String
        let proto: String
        let universal: Bool
        let slots: [ExportSlot]
    }
    struct ExportModel: Codable {
        let model: String
        let vendor: String
        let displayName: String?
        let tested: Bool?
        let probeResults: [String: Bool]?
    }
    let app: String
    let exportedAt: Date
    let retention: String
    let vendors: [ExportVendor]
    let harnesses: [ExportHarness]
    let models: [ExportModel]
    let events: [MonitorEvent]
}

// MARK: - 状态辅助类型集中（自 AppState.swift 拆分·T8/B4 安全部分，纯移动）
