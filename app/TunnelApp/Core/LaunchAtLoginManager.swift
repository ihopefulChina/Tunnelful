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
    static let label = AppIdentity.launchAgentLabel
    static let legacyLabels = AppIdentity.legacyLaunchAgentLabels

    static func propertyListData(opening bundleURL: URL) throws -> Data {
        let contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", bundleURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": [AppIdentity.bundleIdentifier]
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

        var hasEnabledLaunchAgent = false
        for label in allLaunchAgentLabels {
            let plistURL = launchAgentPlistURL(for: label)
            guard fileManager.fileExists(atPath: plistURL.path) else { continue }
            switch legacyPlistStatus(plistURL) {
            case .requiresApproval:
                return .requiresApproval
            case .enabled:
                hasEnabledLaunchAgent = true
            case .notRegistered, .notFound:
                continue
            @unknown default:
                continue
            }
        }
        return hasEnabledLaunchAgent ? .enabled : .disabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try registerFromCurrentLocation()
        } else {
            try unregisterAll()
        }
    }

    func migrateLegacyLaunchAgentIfNeeded() throws {
        guard AppBundleLocation.classify(
            bundleURL: bundleURL,
            homeDirectory: homeDirectory
        ).blocker == nil else {
            return
        }

        let existingLegacyLabels = LaunchAgentLoginItem.legacyLabels.filter {
            fileManager.fileExists(atPath: launchAgentPlistURL(for: $0).path)
        }
        guard !existingLegacyLabels.isEmpty else { return }

        let legacyRequestsLaunch = existingLegacyLabels.contains { label in
            let status = legacyPlistStatus(launchAgentPlistURL(for: label))
            return status == .enabled || status == .requiresApproval
        }
        guard legacyRequestsLaunch else {
            try removeLaunchAgents(labels: existingLegacyLabels)
            return
        }

        switch serviceStatus() {
        case .enabled:
            try removeLaunchAgents(labels: existingLegacyLabels)
            return
        case .requiresApproval:
            // Keep the working previous agent until macOS approves the new item.
            return
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }

        var serviceError: Error?
        do {
            try registerService()
        } catch {
            serviceError = error
        }
        switch serviceStatus() {
        case .enabled:
            try removeLaunchAgents(labels: existingLegacyLabels)
            return
        case .requiresApproval:
            return
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }

        let currentPlistStatus = legacyPlistStatus(launchAgentPlistURL)
        if currentPlistStatus == .enabled {
            try removeLaunchAgents(labels: existingLegacyLabels)
            return
        }
        if currentPlistStatus == .requiresApproval {
            return
        }

        do {
            try installLaunchAgent()
            try removeLaunchAgents(labels: existingLegacyLabels)
        } catch {
            let details = [serviceError?.localizedDescription, error.localizedDescription]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            throw LaunchAtLoginError.registrationFailed(details)
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
        } catch {
            serviceError = error
        }
        switch serviceStatus() {
        case .enabled, .requiresApproval:
            try removeLaunchAgents(labels: allLaunchAgentLabels)
            return
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }

        do {
            try installLaunchAgent()
            try removeLaunchAgents(labels: LaunchAgentLoginItem.legacyLabels)
        } catch {
            let details = [serviceError?.localizedDescription, error.localizedDescription]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            throw LaunchAtLoginError.registrationFailed(details)
        }
    }

    private func unregisterAll() throws {
        var failures: [String] = []
        let status = serviceStatus()
        if status != .notRegistered && status != .notFound {
            do {
                try unregisterService()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        do {
            try removeLaunchAgents(labels: allLaunchAgentLabels)
        } catch {
            failures.append(error.localizedDescription)
        }
        if !failures.isEmpty {
            throw LaunchAtLoginError.registrationFailed(failures.joined(separator: " "))
        }
    }

    private var launchAgentPlistURL: URL {
        launchAgentPlistURL(for: LaunchAgentLoginItem.label)
    }

    private var allLaunchAgentLabels: [String] {
        [LaunchAgentLoginItem.label] + LaunchAgentLoginItem.legacyLabels
    }

    private func launchAgentPlistURL(for label: String) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private func installLaunchAgent() throws {
        let plistURL = launchAgentPlistURL
        let previousLegacyStatus = legacyPlistStatus(plistURL)
        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try LaunchAgentLoginItem.propertyListData(opening: bundleURL)
        try data.write(to: plistURL, options: .atomic)

        let domain = "gui/\(uid)"
        let serviceTarget = "\(domain)/\(LaunchAgentLoginItem.label)"
        var didBootstrap = false
        var serviceMayRemainLoaded = previousLegacyStatus == .enabled
            || previousLegacyStatus == .requiresApproval
        do {
            if serviceMayRemainLoaded {
                let bootoutStatus = try runLaunchctl(["bootout", serviceTarget])
                guard bootoutStatus == 0 else {
                    throw launchctlFailure(command: "bootout", status: bootoutStatus)
                }
                serviceMayRemainLoaded = false
            }

            let bootstrapStatus = try runLaunchctl(["bootstrap", domain, plistURL.path])
            guard bootstrapStatus == 0 else {
                throw launchctlFailure(command: "bootstrap", status: bootstrapStatus)
            }
            didBootstrap = true
            serviceMayRemainLoaded = true

            let enableStatus = try runLaunchctl(["enable", serviceTarget])
            guard enableStatus == 0 else {
                throw launchctlFailure(command: "enable", status: enableStatus)
            }
        } catch {
            var reportedError = error
            if didBootstrap {
                do {
                    let cleanupStatus = try runLaunchctl(["bootout", serviceTarget])
                    if cleanupStatus != 0 {
                        reportedError = LaunchAtLoginError.registrationFailed(
                            "\(error.localizedDescription) launchctl bootout 清理失败（状态码 \(cleanupStatus)）。"
                        )
                    } else {
                        serviceMayRemainLoaded = false
                    }
                } catch {
                    reportedError = LaunchAtLoginError.registrationFailed(
                        "\(reportedError.localizedDescription) launchctl bootout 清理失败：\(error.localizedDescription)"
                    )
                }
            }
            if !serviceMayRemainLoaded {
                try? fileManager.removeItem(at: plistURL)
            }
            throw reportedError
        }
    }

    private func removeLaunchAgents(labels: [String]) throws {
        var failures: [String] = []
        for label in labels {
            do {
                try removeLaunchAgent(label: label)
            } catch {
                failures.append("\(label)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw LaunchAtLoginError.registrationFailed(failures.joined(separator: " "))
        }
    }

    private func removeLaunchAgent(label: String) throws {
        let plistURL = launchAgentPlistURL(for: label)
        let domain = "gui/\(uid)"
        if fileManager.fileExists(atPath: plistURL.path) {
            let status = legacyPlistStatus(plistURL)
            if status == .enabled || status == .requiresApproval {
                let bootoutStatus = try runLaunchctl([
                    "bootout",
                    "\(domain)/\(label)"
                ])
                guard bootoutStatus == 0 else {
                    // Keep the plist when launchd still owns the service so status
                    // remains observable and a later disable can retry bootout.
                    throw launchctlFailure(command: "bootout", status: bootoutStatus)
                }
            }
        }
        if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }
    }

    private static func invokeLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func launchctlFailure(
        command: String,
        status: Int32
    ) -> LaunchAtLoginError {
        .registrationFailed("launchctl \(command) 失败（状态码 \(status)）。")
    }
}
