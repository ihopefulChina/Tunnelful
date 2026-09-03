import SwiftUI

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateChecker: UpdateChecker

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

            Section("cloudflared") {
                KeyValueRow(key: "可执行文件", value: model.installation?.executableURL.path ?? "未检测到")
                KeyValueRow(key: "版本", value: model.installation?.version ?? "未知")
                KeyValueRow(key: "来源", value: model.installation?.source.rawValue ?? "未知")
                Button("重新检测") {
                    Task { await model.bootstrap() }
                }
                Button("选择其他可执行文件…") {
                    model.chooseCloudflaredExecutable()
                }
            }

            Section("本地配置") {
                KeyValueRow(key: "当前文件", value: model.selectedConfigURL?.path ?? "尚未导入")
                Button("导入配置…") { model.chooseConfiguration() }
                    .disabled(model.isApplyingConfiguration || model.isRoutingDNS)
            }

            Section("软件更新") {
                KeyValueRow(key: "当前版本", value: AppIdentity.releaseVersion)
                LabeledContent {
                    Button("检查更新…") {
                        ApplicationActivation.openWindow {
                            openWindow(id: "updates")
                        }
                    }
                } label: {
                    Text(updateSummary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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
    }

    private var updateSummary: String {
        switch updateChecker.state {
        case .idle:
            return "仅在主动检查时联网"
        case .checking:
            return "正在连接 GitHub…"
        case .upToDate:
            return "已是最新版本"
        case let .updateAvailable(release):
            return "新版本 \(release.version) 可用"
        case .failed:
            return "上次检查失败"
        }
    }
}
