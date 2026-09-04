import AppKit
import SwiftUI

struct PublishView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var process: TunnelProcessController

    @State private var tunnelName = ""
    @State private var hostname = ""
    @State private var service = ""
    @State private var path = ""
    @State private var isShowingDNSConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
                NoticeView(
                    kind: .info,
                    title: "远端 DNS 需要确认",
                    message: "Tunnelful 会先保存并校验本地 Ingress；只有你再次确认后，才会执行 tunnel route dns。"
                )

                tunnelSection
                routeSection
                applySection
            }
            .padding(.horizontal, AppMetrics.pagePadding)
            .padding(.top, AppMetrics.pageTopPadding)
            .padding(.bottom, AppMetrics.pageBottomPadding)
            .frame(maxWidth: AppMetrics.maxReadableWidth, alignment: .leading)
        }
        .appPageBackground()
        .onAppear {
            applyDefaultsFromCurrentConfiguration()
        }
        .onChange(of: model.configDocument) { _, _ in
            applyDefaultsFromCurrentConfiguration()
        }
        .onChange(of: tunnelName) { _, _ in model.invalidatePublishPlan() }
        .onChange(of: hostname) { _, _ in model.invalidatePublishPlan() }
        .onChange(of: service) { _, _ in model.invalidatePublishPlan() }
        .onChange(of: path) { _, _ in model.invalidatePublishPlan() }
    }

    private var tunnelSection: some View {
        stepPanel(
            title: "选择命名 Tunnel",
            subtitle: "它将用于 DNS 路由计划和连接器进程。"
        ) {
            if model.tunnels.isEmpty {
                TextField("Tunnel 名称", text: $tunnelName, prompt: Text("dev"))
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("Tunnel", selection: $tunnelName) {
                    ForEach(model.tunnels) { tunnel in
                        Text(tunnel.name).tag(tunnel.name)
                    }
                }
                .pickerStyle(.menu)
            }
            if let tunnelError {
                Text(tunnelError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .disabled(model.isRoutingDNS)
    }

    private var routeSection: some View {
        stepPanel(
            title: "将域名映射到源站",
            subtitle: "域名是公开访问地址，源站 URL 是本地转发目标。"
        ) {
            Form {
                TextField("域名", text: $hostname, prompt: Text("preview.example.com"))
                    .textContentType(.URL)
                if let hostnameError {
                    Text(hostnameError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                TextField("本地源站", text: $service, prompt: Text("http://127.0.0.1:3000"))
                    .textContentType(.URL)
                if let serviceError {
                    Text(serviceError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                TextField("路径匹配", text: $path, prompt: Text("可选，例如 ^/api/.*"))
            }
            .formStyle(.columns)
            .scrollDisabled(true)
            .frame(minHeight: 116)

            HStack(spacing: 10) {
                Button {
                    Task { await model.checkOrigin(service) }
                } label: {
                    Label("检查源站", systemImage: "waveform.path.ecg")
                }
                .disabled(serviceError != nil)

                Label(model.originState.label, systemImage: originSymbol)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .disabled(model.isRoutingDNS)
    }

    private var applySection: some View {
        stepPanel(
            title: "检查并应用",
            subtitle: "替换前先校验新配置，并自动备份原文件。"
        ) {
            VStack(alignment: .leading, spacing: 9) {
                previewRow(label: "Ingress", value: "\(hostname) → \(service)")
                previewRow(
                    label: "配置文件",
                    value: model.selectedConfigURL?.path ?? "尚未导入配置"
                )
                previewRow(label: "DNS 计划", value: routePlan.displayCommand)
            }

            HStack(spacing: 10) {
                if model.configDocument == nil {
                    Button("导入配置…") { model.chooseConfiguration() }
                        .disabled(model.isApplyingConfiguration || model.isRoutingDNS)
                }

                Button {
                    Task {
                        await model.applyLocalPublish(
                            tunnelName: tunnelName,
                            hostname: hostname,
                            service: service,
                            path: path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : path
                        )
                    }
                } label: {
                    if model.isApplyingConfiguration {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("保存本地配置", systemImage: "checkmark.shield")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !isFormValid || model.configDocument == nil ||
                        model.isApplyingConfiguration || model.isRoutingDNS
                )
                .accessibilityLabel("保存本地配置")
                .accessibilityValue(model.isApplyingConfiguration ? "正在保存" : "")

                if let plan = model.pendingDNSPlan {
                    Button {
                        copy(plan.displayCommand)
                    } label: {
                        Label("复制 DNS 命令", systemImage: "doc.on.doc")
                    }
                    .disabled(model.isRoutingDNS)

                    Button {
                        isShowingDNSConfirmation = true
                    } label: {
                        if model.isRoutingDNS {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("配置 DNS 路由…", systemImage: "network")
                        }
                    }
                    .disabled(model.isRoutingDNS)
                    .confirmationDialog(
                        "配置 Cloudflare DNS 路由？",
                        isPresented: $isShowingDNSConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("确认配置 DNS 路由") {
                            Task { await model.routeDNS(plan) }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将执行 \(plan.displayCommand)。这会在你的 Cloudflare 账户中创建 DNS CNAME 记录。")
                    }
                }

                Spacer()

                if case .running = process.processState {
                    Button("重新启动 Tunnel") { model.restartTunnel(named: tunnelName) }
                } else {
                    Button("启动 Tunnel") { model.startTunnel(named: tunnelName) }
                        .disabled(model.pendingDNSPlan == nil)
                }
            }

            if let message = model.lastValidationMessage {
                NoticeView(
                    kind: .success,
                    title: "本地配置已就绪",
                    message: message
                )
            }
            if let backup = model.lastBackupURL {
                Text("备份：\(backup.path)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let message = model.lastDNSRouteMessage {
                NoticeView(
                    kind: .success,
                    title: "DNS 路由已配置",
                    message: message
                )
            }
        }
    }

    @ViewBuilder
    private func stepPanel<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .tracking(-0.2)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .appSurface(padding: 16)
    }

    private func previewRow(label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private var routePlan: DNSRoutePlan {
        DNSRoutePlan(tunnelName: tunnelName, hostname: hostname)
    }

    private var hostnameError: String? {
        let value = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value.contains("://") || value.contains(where: \.isWhitespace) {
            return "域名不要包含协议或空格。"
        }
        if value.hasPrefix("-") { return "域名不能以连字符开头。" }
        if !value.contains(".") { return "请输入完整域名。" }
        return nil
    }

    private var tunnelError: String? {
        let value = tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value.hasPrefix("-") { return "Tunnel 名称不能以连字符开头。" }
        return nil
    }

    private var serviceError: String? {
        let value = service.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "请输入包含 HTTP 或 HTTPS 协议的源站 URL。"
        }
        return nil
    }

    private var isFormValid: Bool {
        !tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tunnelError == nil
            && hostnameError == nil
            && serviceError == nil
    }

    private var originSymbol: String {
        switch model.originState {
        case .notChecked: return "circle.dashed"
        case .checking: return "clock.arrow.circlepath"
        case .reachable: return "checkmark.circle.fill"
        case .unreachable: return "xmark.circle.fill"
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func applyDefaultsFromCurrentConfiguration() {
        if tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let preferred = model.preferredTunnelName {
            tunnelName = preferred
        }
        if hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let firstHostname = model.configDocument?.ingress
            .compactMap(\.hostname)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            hostname = firstHostname
        }
        if service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let firstService = model.configDocument?.ingress
            .first(where: { !$0.isCatchAll && !$0.service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .service {
            service = firstService
        }
    }
}
