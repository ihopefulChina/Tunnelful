import Foundation

struct CloudflaredInstallation: Equatable, Sendable {
    enum Source: String, Sendable {
        case homebrew = "Homebrew"
        case officialPackage = "官方安装包"
        case custom = "自定义"
    }

    let executableURL: URL
    let version: String
    let source: Source
}

struct CloudflaredTunnel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let createdAt: Date?
    let deletedAt: Date?
    let connectionCount: Int
}

struct CommandResult: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { terminationStatus == 0 }
}

enum CloudflaredError: LocalizedError, Equatable {
    case executableNotFound
    case invalidExecutable(URL)
    case processCouldNotStart(String)
    case commandCancelled
    case commandTimedOut
    case commandFailed(status: Int32, message: String)
    case invalidTunnelList(String)
    case processAlreadyRunning
    case noProcessRunning

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "未找到 cloudflared。请通过 Homebrew 安装，或在“设置”中选择可执行文件。"
        case let .invalidExecutable(url):
            return "所选文件不可执行：\(url.path)"
        case let .processCouldNotStart(message):
            return "cloudflared 无法启动：\(message)"
        case .commandCancelled:
            return "操作已取消。"
        case .commandTimedOut:
            return "cloudflared 响应超时，请检查网络与账户状态后重试。"
        case let .commandFailed(status, message):
            return "cloudflared 已退出，状态码为 \(status)：\(message)"
        case let .invalidTunnelList(message):
            return "隧道列表响应无效：\(message)"
        case .processAlreadyRunning:
            return "已有一个托管隧道正在运行。请先将其停止，再启动其他隧道。"
        case .noProcessRunning:
            return "当前没有托管隧道进程在运行。"
        }
    }

    var dnsRouteErrorDescription: String {
        switch self {
        case .commandTimedOut:
            return "DNS 路由请求已超时，远端结果未知且可能已生效。请先到 Cloudflare DNS 核对记录，再决定是否重试。"
        default:
            return errorDescription ?? "DNS 路由配置失败。"
        }
    }
}

enum ManagedProcessState: Equatable, Sendable {
    case stopped
    case starting
    case running(pid: Int32)
    case failed(exitCode: Int32)

    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .failed: return "失败"
        }
    }
}

enum EdgeConnectionState: String, Equatable, Sendable {
    case unknown = "未知"
    case connecting = "连接中"
    case connected = "已连接"
    case degraded = "连接降级"
}

enum OriginReachabilityState: Equatable, Sendable {
    case notChecked
    case checking
    case reachable(statusCode: Int?)
    case unreachable(String)

    var label: String {
        switch self {
        case .notChecked: return "未检查"
        case .checking: return "检查中"
        case let .reachable(statusCode):
            return statusCode.map { "可访问（HTTP \($0)）" } ?? "可访问"
        case .unreachable: return "无法访问"
        }
    }
}

struct RuntimeStatus: Equatable, Sendable {
    var process: ManagedProcessState = .stopped
    var edge: EdgeConnectionState = .unknown
    var origin: OriginReachabilityState = .notChecked
}

enum TunnelDiscoveryState: Equatable, Sendable {
    case notChecked
    case loading
    case loaded(count: Int)
    case failed(String)
}

enum LaunchAtLoginState: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var isRequested: Bool {
        self == .enabled || self == .requiresApproval
    }
}

struct LogEntry: Identifiable, Equatable, Sendable {
    enum Stream: String, Sendable {
        case standardOutput = "输出"
        case standardError = "错误"
        case app = "应用"
    }

    let id = UUID()
    let timestamp: Date
    let stream: Stream
    let message: String
}

struct DNSRoutePlan: Equatable, Sendable {
    let tunnelName: String
    let hostname: String

    var arguments: [String] {
        ["tunnel", "route", "dns", "--overwrite-dns=false", tunnelName, hostname]
    }

    var displayCommand: String {
        (["cloudflared"] + arguments).map(Self.shellQuotedForDisplay).joined(separator: " ")
    }

    private static func shellQuotedForDisplay(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:="))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
