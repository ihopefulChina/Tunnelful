import AppKit
import SwiftUI

struct EnvironmentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        EnvironmentContent(loginController: model.loginController)
            .environmentObject(model)
    }
}

private struct EnvironmentContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var loginController: CloudflaredLoginController
    @State private var showLoginConfirmation = false
    @State private var copiedInstallCommand = false

    private var report: EnvironmentReport { model.environmentReport }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(
                    title: "让这台 Mac 准备就绪。",
                    subtitle: "只检查必要条件；不会读取、展示或上传凭据内容。"
                )

                summary
                setupSection
                checksSection

                Text("账户登录由官方 cloudflared 打开浏览器完成。Tunnelful 不会接收 Cloudflare 密码、Token 或证书内容。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .background(AppPalette.workspaceBackground)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.bootstrap(reportErrors: true) }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("重新检查", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
                .help("重新检查 cloudflared、配置与账户连接")
                .accessibilityLabel("重新检查运行环境")
                .accessibilityValue(model.isRefreshing ? "正在检查" : "")
            }
        }
        .confirmationDialog(
            "通过官方 cloudflared 登录？",
            isPresented: $showLoginConfirmation,
            titleVisibility: .visible
        ) {
            Button("打开浏览器并登录") {
                model.startOfficialLogin()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将直接运行 cloudflared tunnel login。登录在 Cloudflare 官方网页完成，成功后会在本机保存 cert.pem。")
        }
    }

    private var summary: some View {
        let kind: NoticeView.Kind = report.blockingIssueCount == 0
            ? (report.attentionIssueCount == 0 ? .success : .info)
            : .warning
        let title: String
        let message: String
        if report.isReadyToRun {
            title = "已具备运行条件"
            message = report.attentionIssueCount == 0
                ? "cloudflared、配置与 Tunnel 凭据均已就绪。"
                : "Tunnel 可以运行；另有 \(report.attentionIssueCount) 项账户或权限提示可继续处理。"
        } else {
            title = "还需要完成设置"
            message = "有 \(report.blockingIssueCount) 项必要条件尚未满足，按下面的顺序处理即可。"
        }
        return NoticeView(kind: kind, title: title, message: message)
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("首次设置")
                .font(.headline)

            VStack(spacing: 0) {
                SetupRow(
                    number: "1",
                    title: "安装 cloudflared",
                    detail: model.installation == nil
                        ? "推荐使用 Homebrew；也可从 Cloudflare 官方页面下载安装包。"
                        : "已检测到 \(model.installation?.version ?? "可用版本")。"
                ) {
                    if model.installation == nil {
                        Button(copiedInstallCommand ? "已复制" : "复制安装命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install cloudflared", forType: .string)
                            copiedInstallCommand = true
                        }
                        Button("官方下载") {
                            NSWorkspace.shared.open(AppActions.cloudflaredInstallURL)
                        }
                    } else {
                        Button("选择其他版本…") {
                            model.chooseCloudflaredExecutable()
                        }
                    }
                }

                Divider().padding(.leading, 48)

                SetupRow(
                    number: "2",
                    title: "连接 Cloudflare 账户",
                    detail: accountSetupDetail
                ) {
                    switch loginController.state {
                    case .running:
                        ProgressView().controlSize(.small)
                        Button("取消") { loginController.cancel() }
                    default:
                        if report.hasCertificate {
                            Button("验证账户") {
                                Task { await model.verifyCloudflareAccount() }
                            }
                            .disabled(model.tunnelDiscoveryState == .loading)
                        } else {
                            Button("开始官方登录…") {
                                showLoginConfirmation = true
                            }
                            .disabled(model.installation == nil)
                        }
                    }
                }

                Divider().padding(.leading, 48)

                SetupRow(
                    number: "3",
                    title: "导入本地配置",
                    detail: model.configDocument == nil
                        ? "选择现有的 config.yml；导入本身不会修改文件。"
                        : "配置已导入，可继续检查 Ingress 与 Tunnel 凭据。"
                ) {
                    Button(model.configDocument == nil ? "导入配置…" : "更换配置…") {
                        model.chooseConfiguration()
                    }
                    .disabled(model.isApplyingConfiguration || model.isRoutingDNS)
                }
            }
            .background(AppPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("检查结果")
                    .font(.headline)
                Spacer()
                Text("\(report.items.filter { $0.state == .ready }.count) / \(report.items.count) 就绪")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(report.items.enumerated()), id: \.element.id) { index, item in
                    EnvironmentCheckRow(item: item)
                    if index < report.items.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .background(AppPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var accountSetupDetail: String {
        switch loginController.state {
        case .idle:
            return report.hasCertificate
                ? "已发现账户凭据；可主动验证账户与网络是否可用。"
                : "登录在 Cloudflare 官方网页完成，Tunnelful 不接触密码。"
        case .running:
            return "请在浏览器完成登录；等待期间可以取消。"
        case .succeeded:
            return "官方登录已完成，正在刷新账户状态。"
        case .cancelled:
            return "登录已取消，本机凭据没有被修改。"
        case let .failed(message):
            return message
        }
    }
}

private struct SetupRow<Actions: View>: View {
    let number: String
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    init(
        number: String,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.number = number
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(number)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                actions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }
}

private struct EnvironmentCheckRow: View {
    let item: EnvironmentCheckItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .fontWeight(.medium)
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(stateLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title)，\(stateLabel)。\(item.detail)")
    }

    private var symbol: String {
        switch item.state {
        case .ready: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .actionRequired: return "xmark.circle.fill"
        case .information: return "circle.dotted"
        }
    }

    private var tint: Color {
        switch item.state {
        case .ready: return AppPalette.statusGreen
        case .attention: return AppPalette.statusOrange
        case .actionRequired: return .red
        case .information: return .secondary
        }
    }

    private var stateLabel: String {
        switch item.state {
        case .ready: return "就绪"
        case .attention: return "需留意"
        case .actionRequired: return "待处理"
        case .information: return "可选"
        }
    }
}
