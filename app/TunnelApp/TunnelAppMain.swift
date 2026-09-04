import AppKit
import SwiftUI

enum AppIdentity {
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
    static let tunnelfulOpenMainWindow = Notification.Name("app.tunnelful.mac.openMainWindow")
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
    private var isAwaitingProcessShutdown = false
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
        ApplicationActivation.showSystemMenu()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow
        DispatchQueue.main.async {
            ApplicationActivation.hideDockWhenWindowsAreClosed(excluding: closingWindow)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        guard !isAwaitingProcessShutdown else { return .terminateLater }
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
        let controller = TunnelProcessController()
        let appModel = AppModel(processController: controller)
        _processController = StateObject(wrappedValue: controller)
        _model = StateObject(wrappedValue: appModel)
        _updater = StateObject(wrappedValue: AppUpdater())
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
