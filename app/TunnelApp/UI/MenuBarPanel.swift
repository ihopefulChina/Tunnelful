import SwiftUI

enum MenuBarStatusPresentation {
    static func text(
        process: ManagedProcessState,
        edge: EdgeConnectionState,
        tunnelName: String?
    ) -> String {
        let state: String
        switch (process, edge) {
        case (.running, .connected): state = "已连接 Cloudflare Edge"
        case (.running, .degraded): state = "运行中，正在重连 Edge"
        case (.running, .unreachable): state = "无法连接 Cloudflare Edge"
        case (.running, .connecting): state = "正在连接 Cloudflare Edge"
        case (.running, _): state = "Tunnel 运行中"
        case (.starting, _): state = "Tunnel 启动中"
        case (.failed, _): state = "Tunnel 启动失败"
        default: state = "Tunnel 已停止"
        }

        guard let tunnelName, !tunnelName.isEmpty else { return state }
        return "\(tunnelName)：\(state)"
    }
}

struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var process: TunnelProcessController
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Group {
            Button(action: {}) {
                Label(statusText, systemImage: statusSymbol)
            }
            .disabled(true)

            Divider()

            Button {
                TunnelfulWindowActions.openMainWindow = {
                    model.openMainWindow(openWindow: openWindow)
                }
                model.openMainWindow(openWindow: openWindow)
            } label: {
                Label("打开 \(AppIdentity.displayName)", systemImage: "macwindow")
            }

            Divider()

            if hasActiveProcess {
                Button {
                    performTunnelAction {
                        model.stopTunnel()
                    }
                } label: {
                    Label("停止 Tunnel", systemImage: "stop.fill")
                }
            } else {
                Button {
                    guard let name = model.preferredTunnelName else { return }
                    performTunnelAction {
                        model.startTunnel(named: name)
                    }
                } label: {
                    Label("启动 Tunnel", systemImage: "play.fill")
                }
                .disabled(!canControlTunnel)
            }

            Button {
                guard let name = restartTunnelName else { return }
                performTunnelAction {
                    model.restartTunnel(named: name)
                }
            } label: {
                Label("重新启动 Tunnel", systemImage: "arrow.clockwise")
            }
            .disabled(!canRestartTunnel)

            Divider()

            Button {
                model.openMainWindow(section: .logs, openWindow: openWindow)
            } label: {
                Label("日志", systemImage: "text.alignleft")
            }

            Button {
                model.openMainWindow(section: .environment, openWindow: openWindow)
            } label: {
                Label("环境检查", systemImage: "checklist.checked")
            }

            Button {
                updater.checkForUpdates()
            } label: {
                Label("检查更新…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!updater.canCheckForUpdates)

            Button {
                ApplicationActivation.openWindow {
                    openSettings()
                }
            } label: {
                Label("设置…", systemImage: "gearshape")
            }

            Button {
                AppActions.showAboutPanel()
            } label: {
                Label("关于 \(AppIdentity.displayName)", systemImage: "info.circle")
            }

            Divider()

            Button {
                model.quitApplication()
            } label: {
                Label("退出 \(AppIdentity.displayName)", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
    }

    private var canControlTunnel: Bool {
        model.installation != nil && model.preferredTunnelName != nil
    }

    private var canRestartTunnel: Bool {
        model.installation != nil && hasActiveProcess && restartTunnelName != nil
    }

    private var restartTunnelName: String? {
        process.managedTunnelName ?? model.preferredTunnelName
    }

    private var hasActiveProcess: Bool {
        switch process.processState {
        case .starting, .running:
            return true
        case .stopped, .failed:
            return false
        }
    }

    private var statusText: String {
        MenuBarStatusPresentation.text(
            process: process.processState,
            edge: process.edgeState,
            tunnelName: process.managedTunnelName ?? model.preferredTunnelName
        )
    }

    private var statusSymbol: String {
        switch (process.processState, process.edgeState) {
        case (.running, .connected): return "checkmark.circle"
        case (.running, .degraded), (.running, .unreachable), (.failed, _):
            return "exclamationmark.triangle"
        case (.running, _), (.starting, _): return "arrow.clockwise.circle"
        default: return "stop.circle"
        }
    }

    private func performTunnelAction(_ action: () -> Void) {
        model.alertMessage = nil
        action()
        if model.alertMessage != nil {
            model.openMainWindow(openWindow: openWindow)
        }
    }
}
