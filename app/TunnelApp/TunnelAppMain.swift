import AppKit
import Foundation
import SwiftUI

enum AppIdentity {
    static let bundleIdentifier = "app.ihopeful.Tunnelful"
    static let legacyBundleIdentifier = "app.tunnelful.mac"
    static let launchAgentLabel = "\(bundleIdentifier).login"
    static let legacyLaunchAgentLabels = ["\(legacyBundleIdentifier).login"]
    static let releaseSmokeTestEnvironmentKey = "TUNNELFUL_RELEASE_SMOKE_TEST"
    static let releaseSmokeTestDefaultsSuite = "\(bundleIdentifier).release-smoke-test"

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Tunnelful"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    static var releaseVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "TunnelfulReleaseVersion") as? String ?? version
    }
}

extension Notification.Name {
    static let tunnelfulOpenMainWindow = Notification.Name("\(AppIdentity.bundleIdentifier).openMainWindow")
}

enum AppDomainMigration {
    private static let completionKey = "bundleIdentifierMigrationFromAppTunnelfulMacCompleted"

    static func isReleaseSmokeTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[AppIdentity.releaseSmokeTestEnvironmentKey] == "1"
    }

    static func applicationUserDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        smokeTestSuiteName: String = AppIdentity.releaseSmokeTestDefaultsSuite
    ) -> UserDefaults {
        if isReleaseSmokeTest(environment: environment) {
            guard let isolatedDefaults = UserDefaults(
                suiteName: smokeTestSuiteName
            ) else {
                preconditionFailure("无法创建发布 smoke-test 的隔离偏好域。")
            }
            isolatedDefaults.removePersistentDomain(
                forName: smokeTestSuiteName
            )
            return isolatedDefaults
        }

        migrateLegacyDefaultsIfNeeded(environment: environment)
        return .standard
    }

    @discardableResult
    static func migrateLegacyDefaultsIfNeeded(
        userDefaults: UserDefaults = .standard,
        legacyDomain: String = AppIdentity.legacyBundleIdentifier,
        currentDomain: String = AppIdentity.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard !isReleaseSmokeTest(environment: environment),
              legacyDomain != currentDomain else {
            return false
        }

        var currentValues = userDefaults.persistentDomain(forName: currentDomain) ?? [:]
        guard currentValues[completionKey] as? Bool != true else { return false }

        if let legacyValues = userDefaults.persistentDomain(forName: legacyDomain) {
            for (key, value) in legacyValues where currentValues[key] == nil {
                currentValues[key] = value
            }
        }
        currentValues[completionKey] = true
        userDefaults.setPersistentDomain(currentValues, forName: currentDomain)
        return true
    }
}

@MainActor
enum TunnelfulWindowActions {
    static var openMainWindow: (() -> Void)?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var processController: TunnelProcessController?
    weak var loginController: CloudflaredLoginController?
    weak var model: AppModel?
    var isAwaitingProcessShutdown = false
    var terminationRiskConfirmationOverride: ((Bool, Bool) -> Bool)?
    private var didStartBootstrap = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        // A SwiftUI Window can become key before these observers are installed.
        // Promote the LSUIElement app on first launch so its visible main window
        // gets the normal active title bar, Dock icon, and system menu.
        ApplicationActivation.showSystemMenu()
        startBootstrapIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ApplicationActivation.showSystemMenu()
        if let window = sender.windows.first(where: { window in
            (window.isVisible || window.isMiniaturized) && window.canBecomeKey
        }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return true
        }
        if let openMainWindow = TunnelfulWindowActions.openMainWindow {
            openMainWindow()
        } else {
            NotificationCenter.default.post(name: .tunnelfulOpenMainWindow, object: nil)
        }
        return true
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.canBecomeKey else { return }
        if NativeWindowAppearance.isMainWindow(window) {
            NativeWindowAppearance.apply(to: window)
        }
        ApplicationActivation.showSystemMenu()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow
        DispatchQueue.main.async {
            ApplicationActivation.hideDockWhenWindowsAreClosed(excluding: closingWindow)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isAwaitingProcessShutdown else { return .terminateLater }

        if requiresTerminationConfirmation,
           !confirmTerminationRisks() {
            return .terminateCancel
        }

        let configurationIsRunning = model?.beginTermination() == true
        let tunnelIsRunning: Bool
        if let processController {
            switch processController.processState {
            case .starting, .running: tunnelIsRunning = true
            case .stopped, .failed: tunnelIsRunning = false
            }
        } else {
            tunnelIsRunning = false
        }
        let loginIsRunning = loginController?.isRunning == true
        guard tunnelIsRunning || loginIsRunning || configurationIsRunning else {
            return .terminateNow
        }
        isAwaitingProcessShutdown = true

        var pendingCompletions = 3
        let finishOne: () -> Void = { [weak self, weak sender] in
            pendingCompletions -= 1
            guard pendingCompletions == 0 else { return }
            self?.isAwaitingProcessShutdown = false
            sender?.reply(toApplicationShouldTerminate: true)
        }
        if let processController {
            processController.shutdown(completion: finishOne)
        } else {
            finishOne()
        }
        if let loginController {
            loginController.shutdown(completion: finishOne)
        } else {
            finishOne()
        }
        if let model {
            model.waitForConfigurationShutdown(completion: finishOne)
        } else {
            finishOne()
        }
        return .terminateLater
    }

    private var requiresTerminationConfirmation: Bool {
        model?.hasUnsavedConfigurationDraft == true || model?.isRoutingDNS == true
    }

    private func confirmTerminationRisks() -> Bool {
        guard let model else { return true }

        let hasUnsavedDraft = model.hasUnsavedConfigurationDraft
        let isRoutingDNS = model.isRoutingDNS
        if let terminationRiskConfirmationOverride {
            return terminationRiskConfirmationOverride(hasUnsavedDraft, isRoutingDNS)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = terminationConfirmationTitle(
            hasUnsavedDraft: hasUnsavedDraft,
            isRoutingDNS: isRoutingDNS
        )

        var details: [String] = []
        if hasUnsavedDraft {
            details.append("Ingress 配置中有尚未保存的更改，退出后这些更改会丢失。")
        }
        if isRoutingDNS {
            details.append(
                "Cloudflare DNS 路由仍在配置。退出会停止本地等待，但远端结果未知且可能已经生效；退出后请先到 Cloudflare DNS 核对记录。"
            )
        }
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: "取消退出")
        alert.addButton(withTitle: hasUnsavedDraft ? "放弃更改并退出" : "仍然退出")

        ApplicationActivation.showSystemMenu()
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func terminationConfirmationTitle(
        hasUnsavedDraft: Bool,
        isRoutingDNS: Bool
    ) -> String {
        switch (hasUnsavedDraft, isRoutingDNS) {
        case (true, true): return "放弃更改并中断 DNS 配置？"
        case (true, false): return "放弃未保存的更改并退出？"
        case (false, true): return "DNS 配置尚未结束，仍然退出？"
        case (false, false): return "退出 Tunnelful？"
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func startBootstrapIfNeeded() {
        guard !didStartBootstrap, let model else { return }
        didStartBootstrap = true
        Task { await model.bootstrap() }
    }
}

@MainActor
enum ApplicationActivation {
    static func openWindow(_ action: () -> Void) {
        showSystemMenu()
        action()
        DispatchQueue.main.async {
            NSApplication.shared.activate()
        }
    }

    static func showSystemMenu() {
        let application = NSApplication.shared
        if application.activationPolicy() != .regular {
            application.setActivationPolicy(.regular)
        }
        application.activate()
    }

    static func hideDockWhenWindowsAreClosed(excluding closingWindow: NSWindow? = nil) {
        let hasOpenWindow = NSApplication.shared.windows.contains { window in
            guard window !== closingWindow else { return false }
            return (window.isVisible || window.isMiniaturized) && (window.canBecomeKey || window.isMiniaturized)
        }
        guard !hasOpenWindow else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@main
struct TunnelAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var processController: TunnelProcessController
    @StateObject private var model: AppModel
    @StateObject private var updater: AppUpdater

    init() {
        let environment = ProcessInfo.processInfo.environment
        let isReleaseSmokeTest = AppDomainMigration.isReleaseSmokeTest(environment: environment)
        let userDefaults = AppDomainMigration.applicationUserDefaults(environment: environment)
        let controller = TunnelProcessController()
        let launchAtLoginManager = SystemLaunchAtLoginManager()
        var launchAgentMigrationError: String?
        if !isReleaseSmokeTest {
            do {
                try launchAtLoginManager.migrateLegacyLaunchAgentIfNeeded()
            } catch {
                launchAgentMigrationError =
                    "旧版登录项仍被保留，自动迁移未完成：\(error.localizedDescription)"
            }
        }
        let appModel = AppModel(
            processController: controller,
            launchAtLoginManager: launchAtLoginManager,
            userDefaults: userDefaults
        )
        appModel.alertMessage = launchAgentMigrationError
        _processController = StateObject(wrappedValue: controller)
        _model = StateObject(wrappedValue: appModel)
        _updater = StateObject(
            wrappedValue: AppUpdater(releaseSmokeTest: isReleaseSmokeTest)
        )
        appDelegate.processController = controller
        appDelegate.loginController = appModel.loginController
        appDelegate.model = appModel
    }

    var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(processController)
                .environmentObject(updater)
                .frame(minWidth: 980, minHeight: 680)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1_120, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            TunnelfulCommands(model: model, updater: updater)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
                .environmentObject(processController)
                .environmentObject(updater)
        } label: {
            Image(systemName: menuBarSymbol)
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel(AppIdentity.displayName)
                .accessibilityValue(menuBarAccessibilityValue)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(width: 600, height: 620)
        }
    }

    private var menuBarSymbol: String {
        MenuBarStatusSymbol.name(
            process: processController.processState,
            edge: processController.edgeState
        )
    }

    private var menuBarAccessibilityValue: String {
        MenuBarStatusPresentation.text(
            process: processController.processState,
            edge: processController.edgeState,
            tunnelName: processController.managedTunnelName ?? model.preferredTunnelName
        )
    }
}

private struct TunnelfulCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 \(AppIdentity.displayName)") {
                AppActions.showAboutPanel()
            }
        }

        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(after: .appSettings) {
            OpenMainSectionCommand(model: model, section: .environment, title: "环境检查")

            Button("刷新运行环境") {
                Task { await model.bootstrap() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .newItem) {
            OpenMainSectionCommand(model: model, section: .overview, title: "打开主窗口")
                .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button("Tunnelful 使用帮助") {
                AppActions.openProjectPage()
            }

            Button("报告问题…") {
                AppActions.openIssuesPage()
            }
        }

        SidebarCommands()
        ToolbarCommands()
    }
}

private struct OpenMainSectionCommand: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    let section: AppSection
    let title: String

    var body: some View {
        Button(title) {
            model.openMainWindow(section: section, openWindow: openWindow)
        }
    }
}
