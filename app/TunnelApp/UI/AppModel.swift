import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var description: String {
        switch self {
        case .system: return "外观会随 macOS 的显示设置自动切换。"
        case .light: return "始终使用清晰明亮的浅色外观。"
        case .dark: return "始终使用柔和克制的深色外观。"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var applicationAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

protocol ConfigurationValidating: Sendable {
    func validate(installation: CloudflaredInstallation, configURL: URL) async throws -> String
}

struct OfficialConfigurationValidator: ConfigurationValidating {
    func validate(installation: CloudflaredInstallation, configURL: URL) async throws -> String {
        try await CloudflaredClient(installation: installation).validate(configURL: configURL)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var installation: CloudflaredInstallation?
    @Published private(set) var discoveredConfigURLs: [URL] = []
    @Published private(set) var configDocument: CloudflaredConfigDocument?
    @Published var configurationDraft: CloudflaredConfigDocument?
    @Published private(set) var tunnels: [CloudflaredTunnel] = []
    @Published private(set) var tunnelDiscoveryState: TunnelDiscoveryState = .notChecked
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingTunnels = false
    @Published private(set) var isApplyingConfiguration = false
    @Published private(set) var originState: OriginReachabilityState = .notChecked
    @Published private(set) var lastValidationMessage: String?
    @Published private(set) var lastBackupURL: URL?
    @Published private(set) var pendingDNSPlan: DNSRoutePlan?
    @Published private(set) var isRoutingDNS = false
    @Published private(set) var lastDNSRouteMessage: String?
    @Published private(set) var launchAtLoginState: LaunchAtLoginState
    @Published private(set) var startupAutomationMessage: String?
    @Published var alertMessage: String?
    @Published var requestedSection: AppSection?
    @Published var appearance: AppAppearance {
        didSet {
            userDefaults.set(appearance.rawValue, forKey: Self.appearanceKey)
            applyAppearance()
        }
    }
    @Published var startTunnelOnLaunch: Bool {
        didSet { userDefaults.set(startTunnelOnLaunch, forKey: Self.startTunnelOnLaunchKey) }
    }
    @Published var transportProtocol: TunnelTransportProtocol {
        didSet { userDefaults.set(transportProtocol.rawValue, forKey: Self.transportProtocolKey) }
    }

    let processController: TunnelProcessController
    let loginController: CloudflaredLoginController

    private static let appearanceKey = "appearance"
    private static let preferredExecutablePathKey = "preferredExecutablePath"
    private static let startTunnelOnLaunchKey = "startTunnelOnLaunch"
    private static let transportProtocolKey = "transportProtocol"

    private let detector: CloudflaredExecutableDetector
    private let locator: ConfigurationLocator
    private let store: CloudflaredConfigurationStore
    private let originChecker: OriginHealthChecker
    private let environmentInspector: EnvironmentInspector
    private let launchAtLoginManager: any LaunchAtLoginManaging
    private let configurationValidator: any ConfigurationValidating
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private var preferredExecutableURL: URL?
    private var hasEvaluatedStartupAutomation = false
    private var tunnelRefreshGeneration = 0
    private var originCheckGeneration = 0
    private var isTerminating = false
    private var activeConfigurationPreviewURL: URL?
    private var activeConfigurationValidationTask: Task<String, Error>?
    private var activeDNSRouteTask: Task<String, Error>?

    init(
        processController: TunnelProcessController,
        detector: CloudflaredExecutableDetector = CloudflaredExecutableDetector(),
        locator: ConfigurationLocator = ConfigurationLocator(),
        store: CloudflaredConfigurationStore = CloudflaredConfigurationStore(),
        originChecker: OriginHealthChecker = OriginHealthChecker(),
        environmentInspector: EnvironmentInspector = EnvironmentInspector(),
        launchAtLoginManager: any LaunchAtLoginManaging = SystemLaunchAtLoginManager(),
        configurationValidator: any ConfigurationValidating = OfficialConfigurationValidator(),
        loginController: CloudflaredLoginController? = nil,
        fileManager: FileManager = .default,
        initialInstallation: CloudflaredInstallation? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        installation = initialInstallation
        self.processController = processController
        self.detector = detector
        self.locator = locator
        self.store = store
        self.originChecker = originChecker
        self.environmentInspector = environmentInspector
        self.launchAtLoginManager = launchAtLoginManager
        self.configurationValidator = configurationValidator
        self.fileManager = fileManager
        self.loginController = loginController ?? CloudflaredLoginController(inspector: environmentInspector)
        self.userDefaults = userDefaults
        launchAtLoginState = launchAtLoginManager.currentState()
        configurationDraft = nil
        startTunnelOnLaunch = userDefaults.bool(forKey: Self.startTunnelOnLaunchKey)
        transportProtocol = TunnelTransportProtocol(
            rawValue: userDefaults.string(forKey: Self.transportProtocolKey) ?? ""
        ) ?? .auto
        if let path = userDefaults.string(forKey: Self.preferredExecutablePathKey), !path.isEmpty {
            preferredExecutableURL = URL(fileURLWithPath: path).standardizedFileURL
        }
        appearance = AppAppearance(rawValue: userDefaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        applyAppearance()
    }

    var selectedConfigURL: URL? { configDocument?.sourceURL }

    var hasUnsavedConfigurationDraft: Bool {
        guard let configurationDraft else { return false }
        return configurationDraft != configDocument
    }

    var preferredTunnelName: String? {
        Self.resolvePreferredTunnelName(
            configuredTunnel: configDocument?.tunnel,
            tunnels: tunnels
        )
    }

    static func resolvePreferredTunnelName(
        configuredTunnel: String?,
        tunnels: [CloudflaredTunnel]
    ) -> String? {
        if let configured = configuredTunnel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return tunnels.first(where: {
                $0.id == configured || $0.name.caseInsensitiveCompare(configured) == .orderedSame
            })?.name ?? configured
        }
        if let dev = tunnels.first(where: { $0.name.caseInsensitiveCompare("dev") == .orderedSame }) {
            return dev.name
        }
        return tunnels.first?.name
    }

    var runtimeStatus: RuntimeStatus {
        RuntimeStatus(
            process: processController.processState,
            edge: processController.edgeState,
            origin: originState
        )
    }

    var environmentReport: EnvironmentReport {
        environmentInspector.inspect(
            installation: installation,
            configDocument: configDocument,
            tunnelState: tunnelDiscoveryState,
            launchAtLoginState: launchAtLoginState,
            startTunnelOnLaunch: startTunnelOnLaunch
        )
    }

    func bootstrap(reportErrors: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        refreshLaunchAtLoginState()

        do {
            installation = try await detector.detect(preferredURL: preferredExecutableURL)
        } catch is CancellationError {
            return
        } catch let error as CloudflaredError where error == .commandCancelled {
            return
        } catch {
            installation = nil
            tunnels = []
            tunnelDiscoveryState = .failed(error.localizedDescription)
            if reportErrors {
                alertMessage = error.localizedDescription
            }
        }

        discoveredConfigURLs = locator.discover()
        if configDocument == nil, let first = discoveredConfigURLs.first {
            importConfiguration(at: first)
        }

        if installation != nil {
            await refreshTunnels(reportErrors: reportErrors)
        }
        guard !Task.isCancelled else { return }
        evaluateStartupAutomationIfNeeded()
    }

    func refreshTunnels(reportErrors: Bool = true) async {
        tunnelRefreshGeneration &+= 1
        let generation = tunnelRefreshGeneration
        let previousDiscoveryState = tunnelDiscoveryState
        isRefreshingTunnels = true
        defer {
            if generation == tunnelRefreshGeneration {
                isRefreshingTunnels = false
            }
        }
        guard let installation else {
            guard generation == tunnelRefreshGeneration else { return }
            tunnels = []
            tunnelDiscoveryState = .failed(CloudflaredError.executableNotFound.localizedDescription)
            if reportErrors {
                alertMessage = CloudflaredError.executableNotFound.localizedDescription
            }
            return
        }
        tunnelDiscoveryState = .loading
        do {
            let refreshedTunnels = try await CloudflaredClient(installation: installation).listTunnels()
            guard generation == tunnelRefreshGeneration else { return }
            tunnels = refreshedTunnels
            tunnelDiscoveryState = .loaded(count: refreshedTunnels.count)
        } catch is CancellationError {
            if generation == tunnelRefreshGeneration {
                tunnelDiscoveryState = previousDiscoveryState
            }
            return
        } catch let error as CloudflaredError where error == .commandCancelled {
            if generation == tunnelRefreshGeneration {
                tunnelDiscoveryState = previousDiscoveryState
            }
            return
        } catch {
            guard generation == tunnelRefreshGeneration else { return }
            tunnels = []
            let message = SensitiveLogRedactor().redact(error.localizedDescription)
            tunnelDiscoveryState = .failed(message)
            if reportErrors {
                alertMessage = message
            }
        }
    }

    func importConfiguration(at url: URL) {
        guard !isApplyingConfiguration else {
            alertMessage = "正在校验并保存配置，请完成后再更换配置文件。"
            return
        }
        guard !isRoutingDNS else {
            alertMessage = "正在配置 DNS 路由，请完成后再更换配置文件。"
            return
        }
        guard !hasUnsavedConfigurationDraft else {
            alertMessage = "Ingress 配置还有未保存的更改。请先保存或放弃更改，再导入其他文件。"
            return
        }
        do {
            configDocument = try store.load(from: url)
            configurationDraft = configDocument
            if !discoveredConfigURLs.contains(url) {
                discoveredConfigURLs.append(url)
            }
            lastValidationMessage = nil
            pendingDNSPlan = nil
            lastDNSRouteMessage = nil
            originCheckGeneration &+= 1
            originState = .notChecked
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func chooseConfiguration() {
        guard !isApplyingConfiguration else {
            alertMessage = "正在校验并保存配置，请完成后再更换配置文件。"
            return
        }
        guard !isRoutingDNS else {
            alertMessage = "正在配置 DNS 路由，请完成后再更换配置文件。"
            return
        }
        guard !hasUnsavedConfigurationDraft else {
            alertMessage = "Ingress 配置还有未保存的更改。请先保存或放弃更改，再导入其他文件。"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "导入 cloudflared 配置"
        panel.message = "请选择 config.yml 或 config.yaml；导入过程不会修改文件。"
        panel.allowedContentTypes = [.yaml, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importConfiguration(at: url)
    }

    func chooseCloudflaredExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 cloudflared"
        panel.message = "请选择可信来源的 cloudflared 可执行文件。Tunnelful 会先运行 --version 验证它。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let selected = try await detector.detect(preferredURL: url, allowFallback: false)
                preferredExecutableURL = selected.executableURL
                userDefaults.set(selected.executableURL.path, forKey: Self.preferredExecutablePathKey)
                await bootstrap(reportErrors: true)
            } catch {
                alertMessage = "所选文件不是可用的 cloudflared：\(error.localizedDescription)"
            }
        }
    }

    func startOfficialLogin() {
        guard let installation else {
            alertMessage = CloudflaredError.executableNotFound.localizedDescription
            return
        }
        loginController.start(executableURL: installation.executableURL) { [weak self] in
            guard let self else { return }
            Task { await self.bootstrap(reportErrors: true) }
        }
    }

    func verifyCloudflareAccount() async {
        await refreshTunnels(reportErrors: true)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLoginManager.setEnabled(enabled)
            launchAtLoginState = launchAtLoginManager.currentState()
            if launchAtLoginState == .requiresApproval {
                alertMessage = "macOS 需要你在“系统设置 → 通用 → 登录项”中允许 Tunnelful。"
            }
        } catch let error as LaunchAtLoginError {
            launchAtLoginState = launchAtLoginManager.currentState()
            alertMessage = error.localizedDescription
        } catch {
            launchAtLoginState = launchAtLoginManager.currentState()
            alertMessage = "无法更新开机启动设置：\(error.localizedDescription)"
        }
    }

    func refreshLaunchAtLoginState() {
        launchAtLoginState = launchAtLoginManager.currentState()
    }

    func openLoginItemsSettings() {
        SystemLaunchAtLoginManager.openSystemSettings()
    }

    func checkOrigin(_ service: String) async {
        originCheckGeneration &+= 1
        let generation = originCheckGeneration
        let normalized = service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized) else {
            originState = .unreachable("请输入有效的 HTTP 或 HTTPS 源站 URL。")
            return
        }
        originState = .checking
        let result = await originChecker.check(url).state
        guard generation == originCheckGeneration else { return }
        originState = result
    }

    func invalidatePublishPlan() {
        pendingDNSPlan = nil
        lastValidationMessage = nil
        lastDNSRouteMessage = nil
        originCheckGeneration &+= 1
        originState = .notChecked
    }

    func discardConfigurationDraft() {
        configurationDraft = configDocument
    }

    @discardableResult
    func beginTermination() -> Bool {
        let hadActiveOperation = activeConfigurationValidationTask != nil || activeDNSRouteTask != nil
        isTerminating = true
        activeConfigurationValidationTask?.cancel()
        activeDNSRouteTask?.cancel()
        if let previewURL = activeConfigurationPreviewURL {
            removeConfigurationPreview(at: previewURL)
        }
        return hadActiveOperation
    }

    func waitForConfigurationShutdown(completion: @escaping () -> Void) {
        let validationTask = activeConfigurationValidationTask
        let dnsRouteTask = activeDNSRouteTask
        guard validationTask != nil || dnsRouteTask != nil else {
            completion()
            return
        }
        Task {
            if let validationTask {
                _ = try? await validationTask.value
            }
            if let dnsRouteTask {
                _ = try? await dnsRouteTask.value
            }
            if let previewURL = activeConfigurationPreviewURL {
                removeConfigurationPreview(at: previewURL)
            }
            completion()
        }
    }

    func applyLocalPublish(
        tunnelName: String,
        hostname: String,
        service: String,
        path: String? = nil
    ) async {
        guard !isTerminating else { return }
        guard !isApplyingConfiguration else { return }
        guard !isRoutingDNS else { return }
        pendingDNSPlan = nil
        lastDNSRouteMessage = nil
        guard !hasUnsavedConfigurationDraft else {
            alertMessage = "Ingress 配置还有未保存的更改。请先处理这些更改，再发布服务。"
            return
        }
        guard let installation, var document = configDocument, let destinationURL = document.sourceURL else {
            alertMessage = "请先导入配置并检测 cloudflared，再发布服务。"
            return
        }

        isApplyingConfiguration = true
        defer { isApplyingConfiguration = false }

        document.upsert(hostname: hostname, path: path, service: service)
        let localErrors = document.validationIssues().filter { $0.severity == .error }
        guard localErrors.isEmpty else {
            alertMessage = localErrors.map(\.message).joined(separator: " ")
            return
        }

        let previewURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).preview")
        defer { removeConfigurationPreview(at: previewURL) }

        do {
            try writeConfigurationPreview(document, to: previewURL)

            let client = CloudflaredClient(installation: installation)
            let validation = try await validateConfiguration(
                installation: installation,
                previewURL: previewURL
            )
            guard canContinueConfigurationOperation(for: previewURL) else { return }
            let saveResult = try store.save(document, to: destinationURL)
            document.sourceURL = destinationURL
            configDocument = document
            configurationDraft = document
            lastBackupURL = saveResult.backupURL
            lastValidationMessage = validation.isEmpty ? "官方校验通过。" : validation
            pendingDNSPlan = client.dnsRoutePlan(
                tunnelName: tunnelName.trimmingCharacters(in: .whitespacesAndNewlines),
                hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch is CancellationError {
            return
        } catch let error as CloudflaredError where error == .commandCancelled {
            return
        } catch {
            guard !isTerminating else { return }
            alertMessage = error.localizedDescription
        }
    }

    func routeDNS(_ plan: DNSRoutePlan) async {
        guard !isTerminating else { return }
        guard !isRoutingDNS else { return }
        let tunnelName = plan.tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = plan.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tunnelName.isEmpty, !hostname.isEmpty,
              !tunnelName.hasPrefix("-"), !hostname.hasPrefix("-") else {
            alertMessage = "Tunnel 名称与域名不能为空，也不能以连字符开头。"
            return
        }
        guard pendingDNSPlan == plan else {
            alertMessage = "发布内容已经变化，请重新保存本地配置后再配置 DNS 路由。"
            return
        }
        guard let installation else {
            alertMessage = "请先检测 cloudflared，再配置 DNS 路由。"
            return
        }
        guard let document = configDocument else {
            pendingDNSPlan = nil
            alertMessage = "请先重新导入并保存本地配置，再配置 DNS 路由。"
            return
        }
        do {
            try store.verifySourceUnchanged(for: document)
        } catch ConfigurationStoreError.fileChangedSinceLoad {
            pendingDNSPlan = nil
            lastDNSRouteMessage = nil
            alertMessage = "配置文件已在本地保存后被其他应用修改。DNS 路由未执行；请重新导入并保存后再试。"
            return
        } catch {
            pendingDNSPlan = nil
            lastDNSRouteMessage = nil
            alertMessage = "无法重新核对本地配置，DNS 路由未执行：\(error.localizedDescription)"
            return
        }

        isRoutingDNS = true
        lastDNSRouteMessage = nil
        let routeTask = Task {
            try await CloudflaredClient(installation: installation).routeDNS(plan)
        }
        activeDNSRouteTask = routeTask
        defer {
            activeDNSRouteTask = nil
            isRoutingDNS = false
        }

        do {
            let output = try await routeTask.value
            guard !isTerminating else { return }
            lastDNSRouteMessage = output.isEmpty ? "DNS 路由已配置。" : output
        } catch is CancellationError {
            return
        } catch let error as CloudflaredError where error == .commandCancelled {
            return
        } catch let error as CloudflaredError {
            guard !isTerminating else { return }
            alertMessage = error.dnsRouteErrorDescription
        } catch {
            guard !isTerminating else { return }
            alertMessage = error.localizedDescription
        }
    }

    func saveStructuredConfiguration(_ document: CloudflaredConfigDocument) async {
        guard !isTerminating else { return }
        guard !isApplyingConfiguration else { return }
        guard !isRoutingDNS else {
            alertMessage = "正在配置 DNS 路由，请完成后再保存配置。"
            return
        }
        guard let installation, let destinationURL = document.sourceURL else {
            alertMessage = "请先导入配置并检测 cloudflared，再保存。"
            return
        }

        isApplyingConfiguration = true
        defer { isApplyingConfiguration = false }

        let errors = document.validationIssues().filter { $0.severity == .error }
        guard errors.isEmpty else {
            alertMessage = errors.map(\.message).joined(separator: " ")
            return
        }

        let previewURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).preview")
        defer { removeConfigurationPreview(at: previewURL) }

        do {
            try writeConfigurationPreview(document, to: previewURL)
            let output = try await validateConfiguration(
                installation: installation,
                previewURL: previewURL
            )
            guard canContinueConfigurationOperation(for: previewURL) else { return }
            let result = try store.save(document, to: destinationURL)
            configDocument = document
            configurationDraft = document
            lastBackupURL = result.backupURL
            lastValidationMessage = output.isEmpty ? "官方校验通过。" : output
        } catch is CancellationError {
            return
        } catch let error as CloudflaredError where error == .commandCancelled {
            return
        } catch {
            guard !isTerminating else { return }
            alertMessage = error.localizedDescription
        }
    }

    private func validateConfiguration(
        installation: CloudflaredInstallation,
        previewURL: URL
    ) async throws -> String {
        let validator = configurationValidator
        let validationTask = Task {
            try await validator.validate(installation: installation, configURL: previewURL)
        }
        activeConfigurationValidationTask = validationTask
        defer { activeConfigurationValidationTask = nil }
        return try await withTaskCancellationHandler {
            try await validationTask.value
        } onCancel: {
            validationTask.cancel()
        }
    }

    private func canContinueConfigurationOperation(for previewURL: URL) -> Bool {
        !isTerminating && !Task.isCancelled && activeConfigurationPreviewURL == previewURL
    }

    private func writeConfigurationPreview(
        _ document: CloudflaredConfigDocument,
        to previewURL: URL
    ) throws {
        let descriptor = previewURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        activeConfigurationPreviewURL = previewURL
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let bytes = Data(CloudflaredConfigSerializer().serialize(document).utf8)
            try handle.write(contentsOf: bytes)
            try handle.close()
        } catch {
            try? handle.close()
            removeConfigurationPreview(at: previewURL)
            throw error
        }
    }

    private func removeConfigurationPreview(at previewURL: URL) {
        guard activeConfigurationPreviewURL == previewURL else { return }
        do {
            try fileManager.removeItem(at: previewURL)
            activeConfigurationPreviewURL = nil
        } catch {
            if !fileManager.fileExists(atPath: previewURL.path) {
                activeConfigurationPreviewURL = nil
            }
        }
    }

    func validateCurrentConfiguration() async {
        guard let installation, let url = selectedConfigURL else {
            alertMessage = "请先导入配置并检测 cloudflared。"
            return
        }
        do {
            let output = try await CloudflaredClient(installation: installation).validate(configURL: url)
            lastValidationMessage = output.isEmpty ? "官方校验通过。" : output
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func testMatchingRule(urlText: String) async {
        guard let installation, let configURL = selectedConfigURL, let url = URL(string: urlText) else {
            alertMessage = "请先输入有效 URL 并导入配置。"
            return
        }
        do {
            lastValidationMessage = try await CloudflaredClient(installation: installation)
                .matchingRule(configURL: configURL, url: url)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func startTunnel(named tunnelName: String) {
        guard let installation else {
            alertMessage = CloudflaredError.executableNotFound.localizedDescription
            return
        }
        let name = tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            alertMessage = "请选择要运行的 Tunnel。"
            return
        }
        guard !name.hasPrefix("-") else {
            alertMessage = "Tunnel 名称不能以连字符开头。"
            return
        }
        do {
            let client = CloudflaredClient(installation: installation)
            try processController.start(
                executableURL: installation.executableURL,
                arguments: client.runArguments(
                    tunnel: name,
                    configURL: selectedConfigURL,
                    transportProtocol: transportProtocol
                )
            )
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func stopTunnel() {
        do {
            try processController.stop()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func restartTunnel(named tunnelName: String) {
        guard let installation else {
            alertMessage = CloudflaredError.executableNotFound.localizedDescription
            return
        }
        let name = tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            alertMessage = "请选择要运行的 Tunnel。"
            return
        }
        guard !name.hasPrefix("-") else {
            alertMessage = "Tunnel 名称不能以连字符开头。"
            return
        }
        let client = CloudflaredClient(installation: installation)
        do {
            try processController.restart(
                executableURL: installation.executableURL,
                arguments: client.runArguments(
                    tunnel: name,
                    configURL: selectedConfigURL,
                    transportProtocol: transportProtocol
                )
            )
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func retryTunnelUsingHTTP2() {
        transportProtocol = .http2
        guard let name = preferredTunnelName else { return }
        switch processController.processState {
        case .running, .starting:
            restartTunnel(named: name)
        default:
            startTunnel(named: name)
        }
    }

    func openMainWindow(section: AppSection? = nil, openWindow: OpenWindowAction) {
        if let section { requestedSection = section }
        ApplicationActivation.openWindow {
            openWindow(id: "main")
        }
    }

    func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func evaluateStartupAutomationIfNeeded() {
        guard !hasEvaluatedStartupAutomation else { return }
        hasEvaluatedStartupAutomation = true
        guard startTunnelOnLaunch else {
            startupAutomationMessage = nil
            return
        }
        guard installation != nil else {
            startupAutomationMessage = "已启用自动启动 Tunnel，但尚未检测到 cloudflared。"
            return
        }
        guard let tunnelName = preferredTunnelName else {
            startupAutomationMessage = "已启用自动启动 Tunnel，但尚未找到可运行的 Tunnel 或配置。"
            return
        }
        guard processController.processState == .stopped else { return }
        startupAutomationMessage = "正在按设置启动当前 Tunnel。"
        startTunnel(named: tunnelName)
        if case .running = processController.processState {
            startupAutomationMessage = "已按设置启动当前 Tunnel。"
        }
    }

    private func applyAppearance() {
        NSApplication.shared.appearance = appearance.applicationAppearance
    }
}

extension UTType {
    static var yaml: UTType {
        UTType(filenameExtension: "yml") ?? .plainText
    }
}
