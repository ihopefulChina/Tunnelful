import SwiftUI

struct UpdateView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var updateChecker: UpdateChecker

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: statusSymbol)
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(statusTitle)
                    .font(.title2.weight(.semibold))
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(updateChecker.state == .idle ? "检查更新" : "重新检查") {
                    Task { await updateChecker.check() }
                }
                .disabled(updateChecker.state.isChecking)

                if case let .updateAvailable(release) = updateChecker.state {
                    Button("打开下载页") {
                        openURL(release.downloadPageURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }

            Text("仅在你主动检查时访问 GitHub，不会上传配置或账户信息。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 390)
        .padding(.horizontal, 34)
        .padding(.vertical, 30)
        .task { await updateChecker.checkIfNeeded() }
    }

    private var statusSymbol: String {
        switch updateChecker.state {
        case .idle, .checking: return "arrow.triangle.2.circlepath.circle"
        case .upToDate: return "checkmark.circle"
        case .updateAvailable: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch updateChecker.state {
        case .failed: return AppPalette.statusOrange
        case .upToDate: return AppPalette.statusGreen
        default: return .accentColor
        }
    }

    private var statusTitle: String {
        switch updateChecker.state {
        case .idle: return "软件更新"
        case .checking: return "正在检查更新…"
        case .upToDate: return "已是最新版本"
        case .updateAvailable: return "有新版本可用"
        case .failed: return "无法检查更新"
        }
    }

    private var statusMessage: String {
        switch updateChecker.state {
        case .idle:
            return "当前版本 \(updateChecker.currentVersion)"
        case .checking:
            return "正在从 Tunnelful 官方 GitHub 仓库读取发布信息。"
        case let .upToDate(release):
            return "当前版本 \(updateChecker.currentVersion)，最新版本 \(release.version)。"
        case let .updateAvailable(release):
            let kind = release.isPrerelease ? "预览版本" : "正式版本"
            return "\(kind) \(release.version) 已发布。下载后由你决定何时安装。"
        case let .failed(error):
            return error.localizedDescription
        }
    }
}
