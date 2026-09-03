import Darwin
import Foundation
import ServiceManagement

protocol LaunchAtLoginManaging: Sendable {
    func currentState() -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
}

enum AppBundleLocation: Equatable, Sendable {
    case applications
    case translocated
    case diskImage
    case other

    var blocker: LaunchAtLoginBlocker? {
        switch self {
        case .applications: return nil
        case .translocated: return .translocated
        case .diskImage: return .diskImage
        case .other: return .notInApplications
        }
    }

    static func classify(bundleURL: URL, homeDirectory: URL) -> AppBundleLocation {
        let bundlePath = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let pathComponents = bundleURL.resolvingSymlinksInPath().pathComponents
        if pathComponents.contains("AppTranslocation") {
            return .translocated
        }
        if bundlePath.hasPrefix("/Volumes/") {
            return .diskImage
        }

        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplications = homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        if isInsideApplicationsDirectory(bundlePath, applicationsDirectory: systemApplications)
            || isInsideApplicationsDirectory(bundlePath, applicationsDirectory: userApplications) {
            return .applications
        }
        return .other
    }

    private static func isInsideApplicationsDirectory(_ bundlePath: String, applicationsDirectory: URL) -> Bool {
        let directoryPath = applicationsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        return bundlePath == directoryPath || bundlePath.hasPrefix(directoryPath + "/")
    }
}

enum LaunchAgentLoginItem {
    static let label = "app.tunnelful.mac.login"

    static func propertyListData(opening bundleURL: URL) throws -> Data {
        let contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", bundleURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": ["app.tunnelful.mac"]
        ]
        return try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
    }
}

enum LaunchAtLoginError: LocalizedError, Equatable {
    case translocated
    case diskImage
    case notInApplications
    case registrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .translocated:
            return LaunchAtLoginBlocker.translocated.guidance
        case .diskImage:
            return LaunchAtLoginBlocker.diskImage.guidance
        case .notInApplications:
            return LaunchAtLoginBlocker.notInApplications.guidance
        case let .registrationFailed(message):
            return message.isEmpty ? "无法注册登录项。" : "无法注册登录项：\(message)"
        }
    }
}

struct SystemLaunchAtLoginManager: LaunchAtLoginManaging, @unchecked Sendable {
    private let bundleURL: URL
    private let homeDirectory: URL
    private let fileManager: FileManager
    private let uid: uid_t
    private let serviceStatus: @Sendable () -> SMAppService.Status
    private let registerService: @Sendable () throws -> Void
    private let unregisterService: @Sendable () throws -> Void
    private let legacyPlistStatus: @Sendable (URL) -> SMAppService.Status
    private let runLaunchctl: @Sendable ([String]) throws -> Int32

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        uid: uid_t = getuid(),
        serviceStatus: @escaping @Sendable () -> SMAppService.Status = { SMAppService.mainApp.status },
        registerService: @escaping @Sendable () throws -> Void = { try SMAppService.mainApp.register() },
        unregisterService: @escaping @Sendable () throws -> Void = { try SMAppService.mainApp.unregister() },
        legacyPlistStatus: @escaping @Sendable (URL) -> SMAppService.Status = { SMAppService.statusForLegacyPlist(at: $0) },
        runLaunchctl: @escaping @Sendable ([String]) throws -> Int32 = { try invokeLaunchctl($0) }
    ) {
        self.bundleURL = bundleURL
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.uid = uid
        self.serviceStatus = serviceStatus
        self.registerService = registerService
        self.unregisterService = unregisterService
        self.legacyPlistStatus = legacyPlistStatus
        self.runLaunchctl = runLaunchctl
    }

    func currentState() -> LaunchAtLoginState {
        if let blocker = AppBundleLocation.classify(bundleURL: bundleURL, homeDirectory: homeDirectory).blocker {
            return .unavailable(blocker)
        }

        switch serviceStatus() {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }

        guard fileManager.fileExists(atPath: launchAgentPlistURL.path) else {
            return .disabled
        }

        switch legacyPlistStatus(launchAgentPlistURL) {
        case .requiresApproval:
            return .requiresApproval
        case .enabled, .notRegistered, .notFound:
            return .enabled
        @unknown default:
            return .enabled
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try registerFromCurrentLocation()
        } else {
            try unregisterAll()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func registerFromCurrentLocation() throws {
        if let blocker = AppBundleLocation.classify(bundleURL: bundleURL, homeDirectory: homeDirectory).blocker {
            switch blocker {
            case .translocated: throw LaunchAtLoginError.translocated
            case .diskImage: throw LaunchAtLoginError.diskImage
            case .notInApplications: throw LaunchAtLoginError.notInApplications
            }
        }

        var serviceError: Error?
        do {
            let status = serviceStatus()
            if status == .notRegistered || status == .notFound {
                try registerService()
            }
            switch serviceStatus() {
            case .enabled, .requiresApproval:
                try? removeLaunchAgent()
                return
            case .notRegistered, .notFound:
                break
            @unknown default:
                break
            }
        } catch {
            serviceError = error
        }

        do {
            try installLaunchAgent()
        } catch {
            let details = [serviceError?.localizedDescription, error.localizedDescription]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            throw LaunchAtLoginError.registrationFailed(details)
        }
    }

    private func unregisterAll() throws {
        let status = serviceStatus()
        if status != .notRegistered && status != .notFound {
            try unregisterService()
        }
        try removeLaunchAgent()
    }

    private var launchAgentPlistURL: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(LaunchAgentLoginItem.label).plist")
    }

    private func installLaunchAgent() throws {
        let plistURL = launchAgentPlistURL
        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try LaunchAgentLoginItem.propertyListData(opening: bundleURL)
        try data.write(to: plistURL, options: .atomic)

        let domain = "gui/\(uid)"
        let serviceTarget = "\(domain)/\(LaunchAgentLoginItem.label)"
        _ = try? runLaunchctl(["bootout", serviceTarget])
        _ = try? runLaunchctl(["bootstrap", domain, plistURL.path])
        _ = try? runLaunchctl(["enable", serviceTarget])
    }

    private func removeLaunchAgent() throws {
        let plistURL = launchAgentPlistURL
        let domain = "gui/\(uid)"
        _ = try? runLaunchctl(["bootout", "\(domain)/\(LaunchAgentLoginItem.label)"])
        if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }
    }

    private static func invokeLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
