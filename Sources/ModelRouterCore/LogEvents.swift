import Foundation
import Network

// MARK: - 分级日志事件（监视器唯一数据源；Core 埋点，App 层渲染/导出）

/// 日志等级：数值升序，选中某档 = 显示该级及更严重
public enum LogLevel: Int, Codable, Comparable, CaseIterable {
    case verbose = 0, debug = 1, info = 2, warning = 3, error = 4

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .verbose: return "VERBOSE"
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }
}

/// 请求生命周期环节；一个请求 3~6 条事件，connID 串联
public enum LogPhase: String, Codable {
    case request       // 下游请求收齐
    case decision      // 路由判定：转发目标/降级/模型发现/拒绝
    case upstreamHead  // 上游响应头到达
    case progress      // 流式回传心跳（verbose）
    case finish        // 完成/中断
}

/// 元数据级事件：只记环节事实，不记流过的数据内容
public struct LogEvent: Codable {
    public let ts: Date
    public let level: LogLevel
    public let phase: LogPhase
    public let connID: UInt64           // 同一请求的多条事件共享
    public let harnessID: UUID?
    public let method: String?
    public let path: String
    public let modelField: String?      // 请求的 model
    public let targetModel: String?     // 实际出站 model
    public let vendor: String?          // 供应商名
    public let status: Int?
    public let bytesIn: Int?            // 请求体字节数
    public let bytesOut: Int?           // 已回传响应字节数
    public let durationMs: Int?
    public let message: String?

    public init(ts: Date = Date(),
                level: LogLevel,
                phase: LogPhase,
                connID: UInt64 = 0,
                harnessID: UUID? = nil,
                method: String? = nil,
                path: String = "",
                modelField: String? = nil,
                targetModel: String? = nil,
                vendor: String? = nil,
                status: Int? = nil,
                bytesIn: Int? = nil,
                bytesOut: Int? = nil,
                durationMs: Int? = nil,
                message: String? = nil) {
        self.ts = ts
        self.level = level
        self.phase = phase
        self.connID = connID
        self.harnessID = harnessID
        self.method = method
        self.path = path
        self.modelField = modelField
        self.targetModel = targetModel
        self.vendor = vendor
        self.status = status
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.durationMs = durationMs
        self.message = message
    }
}

public typealias LogFn = (LogEvent) -> Void

// MARK: - HTTP 服务器错误
public enum HTTPServerError: Error {
    case invalidPort(Int)
}
