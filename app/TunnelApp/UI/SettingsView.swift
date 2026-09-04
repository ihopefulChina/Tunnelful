import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Form {
            Section("外观") {
                Picker("显示模式", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.appearance.description)
                    .foregroundStyle(.secondary)
            }

            Section("自动启动") {
                Toggle("登录 Mac 时自动打开 Tunnelful", isOn: Binding(
                    get: { model.launchAtLoginState.isRequested },
                    set: { model.setLaunchAtLoginEnabled($0) }
                ))
                .disabled(model.launchAtLoginState.isUnavailable)

                Toggle("打开 Tunnelful 后自动启动当前 Tunnel", isOn: $model.startTunnelOnLaunch)

                if model.launchAtLoginState == .requiresApproval {
                    LabeledContent("等待 macOS 批准") {
                        Button("打开登录项设置…") {
                            model.openLoginItemsSettings()
                        }
                    }
                } else if let guidance = model.launchAtLoginState.guidance {
                    Text(guidance)
                        .foregroundStyle(.secondary)
                } else {
                    Text("两个选项可以独立使用；只有条件完整时才会启动 Tunnel。")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Edge 连接协议") {
                Picker("传输协议", selection: $model.transportProtocol) {
                    ForEach(TunnelTransportProtocol.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Text(model.transportProtocol.description)
                    .foregroundStyle(.secondary)
                Text("更改后会在下次启动或重新启动 Tunnel 时生效。")
                    .foregroundStyle(.secondary)
            }

            Section("cloudflared") {
                LabeledContent("可执行文件") {
                    Text(model.installation?.executableURL.path ?? "未检测到")
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(model.installation?.executableURL.path ?? "未检测到 cloudflared")
                }
                LabeledContent("版本", value: model.installation?.version ?? "未知")
                LabeledContent("来源", value: model.installation?.source.rawValue ?? "未知")
                Button("重新检测") {
                    Task { await model.bootstrap() }
                }
                Button("选择其他可执行文件…") {
                    model.chooseCloudflaredExecutable()
                }
            }

            Section("本地配置") {
                LabeledContent("当前文件") {
                    Text(model.selectedConfigURL?.path ?? "尚未导入")
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(model.selectedConfigURL?.path ?? "尚未导入配置")
                }
                Button("导入配置…") { model.chooseConfiguration() }
                    .disabled(model.isApplyingConfiguration || model.isRoutingDNS)
            }

            Section("更新") {
                LabeledContent("当前版本", value: AppIdentity.releaseVersion)
                Toggle("自动检查更新", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                Button("检查更新…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
                Text("发现新版本后会显示官方安装界面；安装完成后 Tunnelful 会重新打开。")
                    .foregroundStyle(.secondary)
            }

            Section("安全") {
                Text("命令通过参数数组直接启动，不经过 shell。DNS 路由会先预览，并且仅在你单独确认后执行；每次覆盖配置前都会在本地备份。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .padding(12)
        .onAppear { model.refreshLaunchAtLoginState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLaunchAtLoginState()
        }
        .presentModelAlerts(from: model)
    }
}
