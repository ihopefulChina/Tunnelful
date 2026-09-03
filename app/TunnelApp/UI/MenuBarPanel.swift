import SwiftUI

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
                    model.stopTunnel()
                } label: {
                    Label("停止 Tunnel", systemImage: "stop.fill")
                }
            } else {
                Button {
                    guard let name = model.preferredTunnelName else { return }
                    model.startTunnel(named: name)
                } label: {
                    Label("启动 Tunnel", systemImage: "play.fill")
                }
                .disabled(!canControlTunnel)
            }

            Button {
                guard let name = model.preferredTunnelName else { return }
                model.restartTunnel(named: name)
            } label: {
                Label("重新启动 Tunnel", systemImage: "arrow.clockwise")
            }
            .disabled(!canControlTunnel || !hasActiveProcess)

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

    private var hasActiveProcess: Bool {
        switch process.processState {
        case .starting, .running:
            return true
        case .stopped, .failed:
            return false
        }
    }

    private var statusText: String {
        switch (process.processState, process.edgeState) {
        case (.running, .connected): return "已连接 Cloudflare Edge"
        case (.running, .degraded): return "运行中，正在重连 Edge"
        case (.running, .unreachable): return "无法连接 Cloudflare Edge"
        case (.running, .connecting): return "正在连接 Cloudflare Edge"
        case (.running, _): return "Tunnel 运行中"
        case (.starting, _): return "Tunnel 启动中"
        case (.failed, _): return "Tunnel 启动失败"
        default: return "Tunnel 已停止"
        }
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
}
