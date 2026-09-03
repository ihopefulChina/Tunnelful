import Darwin
import Foundation

enum EnvironmentCheckState: Equatable, Sendable {
    case ready
    case attention
    case actionRequired
    case information
}

struct EnvironmentCheckItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let state: EnvironmentCheckState
}

struct EnvironmentReport: Equatable, Sendable {
    let items: [EnvironmentCheckItem]
    let hasCertificate: Bool
    let hasTunnelCredentials: Bool

    var blockingIssueCount: Int {
        items.filter { $0.state == .actionRequired }.count
    }

    var attentionIssueCount: Int {
        items.filter { $0.state == .attention }.count
    }

    var isReadyToRun: Bool {
        blockingIssueCount == 0 && hasTunnelCredentials
    }
}

struct EnvironmentInspector: @unchecked Sendable {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func inspect(
        installation: CloudflaredInstallation?,
        configDocument: CloudflaredConfigDocument?,
        tunnelState: TunnelDiscoveryState,
        launchAtLoginState: LaunchAtLoginState,
        startTunnelOnLaunch: Bool
    ) -> EnvironmentReport {
        let certificate = firstUsableFile(in: certificateCandidates)
        let credentialsURL = resolvedCredentialsURL(for: configDocument)
        let credentials = credentialsURL.flatMap(fileSnapshot(at:))
        let hasCredentials = credentials?.isUsable == true

        var items: [EnvironmentCheckItem] = [
            EnvironmentCheckItem(
                id: "system",
                title: "这台 Mac",
                detail: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(architectureDescription)",
                state: .ready
            )
        ]

        if let installation {
            items.append(EnvironmentCheckItem(
                id: "cloudflared",
                title: "cloudflared",
                detail: "已安装 \(installation.version) · \(installation.source.rawValue)",
                state: .ready
            ))
        } else {
            items.append(EnvironmentCheckItem(
                id: "cloudflared",
                title: "cloudflared",
                detail: "尚未找到可用的 cloudflared，可通过 Homebrew 安装或手动选择。",
                state: .actionRequired
            ))
        }

        let brewURLs = [
            URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            URL(fileURLWithPath: "/usr/local/bin/brew")
        ]
        let hasHomebrew = brewURLs.contains { fileManager.isExecutableFile(atPath: $0.path) }
        items.append(EnvironmentCheckItem(
            id: "homebrew",
            title: "Homebrew",
            detail: hasHomebrew ? "已就绪，可用来安装和更新 cloudflared。" : "未检测到；也可以使用 Cloudflare 官方安装包。",
            state: hasHomebrew ? .ready : .information
        ))

        if let configDocument, let sourceURL = configDocument.sourceURL {
            let readable = fileManager.isReadableFile(atPath: sourceURL.path)
            items.append(EnvironmentCheckItem(
                id: "configuration",
                title: "配置文件",
                detail: readable ? "已导入并可读取。" : "文件已选择，但当前不可读取。",
                state: readable ? .ready : .actionRequired
            ))
        } else {
            items.append(EnvironmentCheckItem(
                id: "configuration",
                title: "配置文件",
                detail: "尚未导入 config.yml 或 config.yaml。",
                state: .actionRequired
            ))
        }

        if credentialsURL != nil {
            if let credentials, credentials.isUsable {
                items.append(EnvironmentCheckItem(
                    id: "tunnel-credentials",
                    title: "Tunnel 凭据",
                    detail: credentials.permissionsArePrivate
                        ? "凭据文件存在且权限受限，可以运行对应 Tunnel。"
                        : "凭据文件存在，但其他本地用户也可能读取；建议检查文件权限。",
                    state: credentials.permissionsArePrivate ? .ready : .attention
                ))
            } else {
                items.append(EnvironmentCheckItem(
                    id: "tunnel-credentials",
                    title: "Tunnel 凭据",
                    detail: "配置引用的凭据文件不存在、为空或不可读取。",
                    state: .actionRequired
                ))
            }
        } else {
            items.append(EnvironmentCheckItem(
                id: "tunnel-credentials",
                title: "Tunnel 凭据",
                detail: "当前配置没有 credentials-file；运行命名 Tunnel 前需要补充。",
                state: .actionRequired
            ))
        }

        if let certificate {
            items.append(EnvironmentCheckItem(
                id: "account-certificate",
                title: "Cloudflare 账户凭据",
                detail: certificate.permissionsArePrivate
                    ? "已发现 cert.pem；仅在创建 Tunnel、查看账户列表或配置 DNS 时使用。"
                    : "已发现 cert.pem，但文件权限可能过宽；请先检查后再执行账户操作。",
                state: certificate.permissionsArePrivate ? .ready : .attention
            ))
        } else {
            items.append(EnvironmentCheckItem(
                id: "account-certificate",
                title: "Cloudflare 账户凭据",
                detail: hasCredentials
                    ? "未发现 cert.pem；仍可运行已有 Tunnel，但创建 Tunnel、查看账户列表和配置 DNS 需要登录。"
                    : "尚未登录；通过官方 cloudflared 登录后才能执行账户与 DNS 操作。",
                state: hasCredentials ? .information : .attention
            ))
        }

        items.append(accountVerificationItem(for: tunnelState))

        let launchDetail: String
        let launchState: EnvironmentCheckState
        switch launchAtLoginState {
        case .enabled:
            launchDetail = startTunnelOnLaunch
                ? "登录 Mac 后打开应用，并在条件完整时启动当前 Tunnel。"
                : "登录 Mac 后只打开应用，不会自动启动 Tunnel。"
            launchState = .ready
        case .requiresApproval:
            launchDetail = "已请求开机启动，请在系统设置的“登录项”中允许。"
            launchState = .attention
        case .disabled:
            launchDetail = startTunnelOnLaunch
                ? "打开应用时会自动启动 Tunnel，但应用不会随 Mac 登录自动打开。"
                : "未启用；可在设置中分别开启应用与 Tunnel 的自动启动。"
            launchState = .information
        case .unavailable:
            launchDetail = launchAtLoginState.guidance
                ?? "当前运行位置无法注册登录项。请将 Tunnelful 移到“应用程序”文件夹后重试。"
            launchState = .attention
        }
        items.append(EnvironmentCheckItem(
            id: "startup",
            title: "自动启动",
            detail: launchDetail,
            state: launchState
        ))

        return EnvironmentReport(
            items: items,
            hasCertificate: certificate != nil,
            hasTunnelCredentials: hasCredentials
        )
    }

    func hasUsableCertificate() -> Bool {
        firstUsableFile(in: certificateCandidates) != nil
    }

    private var certificateCandidates: [URL] {
        [
            homeDirectory.appendingPathComponent(".cloudflared/cert.pem"),
            URL(fileURLWithPath: "/etc/cloudflared/cert.pem"),
            URL(fileURLWithPath: "/usr/local/etc/cloudflared/cert.pem")
        ]
    }

    private func accountVerificationItem(for state: TunnelDiscoveryState) -> EnvironmentCheckItem {
        switch state {
        case .notChecked:
            return EnvironmentCheckItem(
                id: "account-verification",
                title: "账户连接",
                detail: "尚未向 Cloudflare 请求 Tunnel 列表。",
                state: .information
            )
        case .loading:
            return EnvironmentCheckItem(
                id: "account-verification",
                title: "账户连接",
                detail: "正在通过官方 cloudflared 验证账户连接…",
                state: .information
            )
        case let .loaded(count):
            return EnvironmentCheckItem(
                id: "account-verification",
                title: "账户连接",
                detail: count == 0 ? "账户连接有效，当前没有 Tunnel。" : "账户连接有效，已发现 \(count) 个 Tunnel。",
                state: .ready
            )
        case let .failed(message):
            return EnvironmentCheckItem(
                id: "account-verification",
                title: "账户连接",
                detail: message,
                state: .attention
            )
        }
    }

    private func resolvedCredentialsURL(for document: CloudflaredConfigDocument?) -> URL? {
        guard let rawValue = document?.credentialsFile?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        let expanded = rawValue
            .replacingOccurrences(of: "${HOME}", with: homeDirectory.path)
            .replacingOccurrences(of: "$HOME", with: homeDirectory.path)
        if expanded == "~" {
            return homeDirectory
        }
        if expanded.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(expanded.dropFirst(2))).standardizedFileURL
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        guard let sourceURL = document?.sourceURL else { return nil }
        return sourceURL.deletingLastPathComponent().appendingPathComponent(expanded).standardizedFileURL
    }

    private func firstUsableFile(in urls: [URL]) -> FileSnapshot? {
        urls.lazy.compactMap(fileSnapshot(at:)).first(where: \.isUsable)
    }

    private func fileSnapshot(at url: URL) -> FileSnapshot? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        return FileSnapshot(
            isReadable: fileManager.isReadableFile(atPath: url.path),
            byteCount: size,
            permissions: permissions
        )
    }

    private var architectureDescription: String {
#if arch(arm64)
        return "Apple Silicon（arm64）"
#elseif arch(x86_64)
        if isRunningUnderRosetta {
            return "Apple Silicon（Rosetta）"
        }
        return "Intel（x86_64）"
#else
        return "未知架构"
#endif
    }

    private var isRunningUnderRosetta: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }
}

private struct FileSnapshot: Equatable {
    let isReadable: Bool
    let byteCount: UInt64
    let permissions: UInt16

    var isUsable: Bool {
        isReadable && byteCount > 0
    }

    var permissionsArePrivate: Bool {
        permissions & 0o077 == 0
    }
}
