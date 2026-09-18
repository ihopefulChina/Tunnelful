import AppKit
import SwiftUI

struct PublishView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var process: TunnelProcessController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tunnelName: String { model.publishDraft.tunnelName }
    private var hostname: String { model.publishDraft.hostname }
    private var service: String { model.publishDraft.service }
    private var path: String { model.publishDraft.path }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
                NoticeView(
                    kind: .info,
                    title: "远端 DNS 需要确认",
                    message: "保存本地 Ingress 后会立刻弹出 DNS 确认；只有你确认后，才会执行 tunnel route dns。若 Tunnel 已在运行，确认后还会询问是否重启连接器。"
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
            model.ensurePublishDraft()
        }
        .onChange(of: model.configDocument) { _, _ in
            if !model.publishDraftMatchesPendingPlanAndSavedConfiguration(
                tunnelName: tunnelName,
                hostname: hostname,
                service: service,
                path: path
            ) {
                model.resetPublishDraftFromConfiguration()
            }
        }
        .onChange(of: model.availableTunnels) { _, _ in
            normalizeTunnelSelection()
        }
        .onChange(of: model.publishDraft.tunnelName) { _, _ in
            invalidatePublishPlanForCurrentDraft(resetOrigin: false)
        }
        .onChange(of: model.publishDraft.hostname) { _, _ in
            invalidatePublishPlanForCurrentDraft(resetOrigin: false)
        }
        .onChange(of: model.publishDraft.service) { _, _ in
            invalidatePublishPlanForCurrentDraft()
        }
        .onChange(of: model.publishDraft.path) { _, _ in invalidatePublishPlanForCurrentDraft(resetOrigin: false) }
        .animation(AppMotion.content(reduceMotion), value: model.lastValidationMessage)
        .animation(AppMotion.content(reduceMotion), value: model.lastDNSRouteMessage)
        .animation(AppMotion.content(reduceMotion), value: model.pendingDNSPlan?.displayCommand)
    }

    private var tunnelSection: some View {
        stepPanel(
            title: "选择命名 Tunnel",
            subtitle: "它将用于 DNS 路由计划和连接器进程，且必须与当前配置及专属凭据一致。"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tunnel")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if model.availableTunnels.isEmpty {
                    TextField("Tunnel 名称", text: $model.publishDraft.tunnelName, prompt: Text("dev"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityHint(visibleTunnelError ?? "输入要发布的命名 Tunnel")
                } else {
                    Picker("Tunnel", selection: $model.publishDraft.tunnelName) {
                        if !model.availableTunnels.contains(where: {
                            $0.matchesSelection(tunnelName)
                        }), !tunnelName.isEmpty {
                            Text("\(tunnelName)（未验证）").tag(tunnelName)
                        }
                        ForEach(model.availableTunnels) { tunnel in
                            Text(tunnel.name).tag(
                                tunnel.matchesSelection(tunnelName) ? tunnelName : tunnel.name
                            )
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Tunnel")
                }
            }
            FieldErrorText(message: visibleTunnelError)
        }
        .disabled(model.isRoutingDNS)
    }

    private var routeSection: some View {
        stepPanel(
            title: "将域名映射到源站",
            subtitle: "域名是公开访问地址，源站 URL 是本地转发目标。"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                labeledField(
                    title: "域名",
                    text: $model.publishDraft.hostname,
                    prompt: "preview.example.com",
                    error: visibleHostnameError,
                    contentType: .URL
                )

                labeledField(
                    title: "本地源站",
                    text: $model.publishDraft.service,
                    prompt: "http://127.0.0.1:3000",
                    error: visibleServiceError,
                    helper: "支持 HTTP/HTTPS、unix: 路径或 http_status。只有 HTTP(S) 可以预检。",
                    contentType: .URL
                )

                labeledField(
                    title: "路径匹配",
                    text: $model.publishDraft.path,
                    prompt: "^/api/.*",
                    helper: "可选。留空表示匹配该域名下的所有路径。"
                )
            }

            HStack(spacing: 10) {
                Button {
                    Task { await model.checkOrigin(service) }
                } label: {
                    Label("检查源站", systemImage: "waveform.path.ecg")
                }
                .disabled(!OriginServiceKind.classify(service).supportsOriginProbe)

                Label(publishOriginState.label, systemImage: StatusAppearance.originSymbol(publishOriginState))
                    .foregroundStyle(StatusAppearance.originTint(publishOriginState))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityLabel("源站状态：\(publishOriginState.label)")
                Spacer(minLength: 0)
            }

            if let message = publishOriginState.failureMessage {
                FieldErrorText(message: message)
            } else if let latency = model.originLatency(for: service) {
                Text("响应耗时 \(formattedLatency(latency))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                previewRow(label: "Ingress", value: ingressPreview)
                previewRow(
                    label: "配置文件",
                    value: model.selectedConfigURL?.path ?? "尚未导入配置"
                )
                previewRow(label: "DNS 计划", value: routePlan.displayCommand)
            }

            VStack(alignment: .leading, spacing: AppMetrics.controlSpacing) {
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
                        BusyLabel(
                            title: "保存本地配置",
                            systemImage: "checkmark.shield",
                            isBusy: model.isApplyingConfiguration
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !isFormValid || model.configDocument == nil ||
                            model.isApplyingConfiguration || model.isRoutingDNS
                    )
                    .help(saveHelp)
                    .accessibilityLabel("保存本地配置")
                    .accessibilityValue(model.isApplyingConfiguration ? "正在保存" : "")

                    Spacer(minLength: 8)

                    if model.isManagedConnectorActive {
                        Button("重新启动 Tunnel") { model.restartTunnel(named: tunnelName) }
                            .disabled(model.isRoutingDNS || model.isApplyingConfiguration)
                            .help("使用当前命名 Tunnel 重新启动托管进程")
                    } else {
                        Button("启动 Tunnel") { model.startTunnel(named: tunnelName) }
                            .disabled(!model.canStartTunnel(named: tunnelName))
                            .help(startTunnelHelp)
                    }
                }

                if let plan = model.pendingDNSPlan {
                    HStack(spacing: 10) {
                        CopyConfirmationButton(
                            title: "复制 DNS 命令",
                            help: "复制将要执行的 cloudflared DNS 命令",
                            confirmedHelp: "已复制到剪贴板",
                            disabled: model.isRoutingDNS
                        ) {
                            ClipboardCopy.string(plan.displayCommand)
                        }

                        Button {
                            model.presentPendingDNSConfirmation()
                        } label: {
                            BusyLabel(
                                title: "配置 DNS 路由…",
                                systemImage: "network",
                                isBusy: model.isRoutingDNS
                            )
                        }
                        .disabled(model.isRoutingDNS)
                        .help("再次确认后才会在 Cloudflare 账户中创建 DNS CNAME 记录")

                        Spacer(minLength: 0)
                    }
                }
            }

            if model.lastValidationSucceeded, let message = model.lastValidationMessage {
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
                    .help(backup.path)
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
        VStack(alignment: .leading, spacing: AppMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .tracking(-0.2)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .appSurface(padding: AppMetrics.stackSpacing)
    }

    private func labeledField(
        title: String,
        text: Binding<String>,
        prompt: String,
        error: String? = nil,
        helper: String? = nil,
        contentType: NSTextContentType? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .textContentType(contentType)
                .accessibilityLabel(title)
                .accessibilityHint(error ?? helper ?? "")
            FieldErrorText(message: error)
            if let helper, error == nil {
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func previewRow(label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .help(value)
        }
    }

    private var ingressPreview: String {
        let host = hostname.isEmpty ? "域名" : hostname
        let origin = service.isEmpty ? "源站" : service
        let pathValue = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = pathValue.isEmpty ? host : "\(host) \(pathValue)"
        return "\(route) → \(origin)"
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
        if let knownTunnel = model.tunnels.first(where: { $0.matchesSelection(value) }),
           !knownTunnel.isAvailable {
            return "这个 Tunnel 已删除，请改选一个可用 Tunnel。"
        }
        if model.configDocument != nil, !model.configurationSupportsTunnelSelection(value) {
            return "所选 Tunnel 与当前配置的 tunnel / credentials-file 不匹配，请先导入这个 Tunnel 的本地配置。"
        }
        return nil
    }

    private var serviceError: String? {
        let value = service.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard OriginServiceKind.classify(value).isPublishable else {
            return "请输入 HTTP/HTTPS URL、unix: 路径或 http_status 源站。"
        }
        return nil
    }

    private var startTunnelHelp: String {
        if !model.canStartTunnel(named: tunnelName) {
            return "请先导入与该 Tunnel 对应的本地配置"
        }
        return "启动当前命名 Tunnel"
    }

    private var visibleTunnelError: String? {
        tunnelError
    }

    private var visibleHostnameError: String? {
        hostnameError
    }

    private var visibleServiceError: String? {
        serviceError
    }

    private var publishOriginState: OriginReachabilityState {
        model.originState(for: service)
    }

    private var isFormValid: Bool {
        !tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tunnelError == nil
            && hostnameError == nil
            && serviceError == nil
    }

    private var saveHelp: String {
        if model.configDocument == nil { return "请先导入配置文件" }
        if !isFormValid { return "请先填写有效的 Tunnel、域名和源站" }
        if model.isApplyingConfiguration { return "正在保存并校验" }
        return "校验后写入本地 Ingress，并立刻请你确认 DNS 路由"
    }

    private func resetDefaultsFromCurrentConfiguration() {
        model.resetPublishDraftFromConfiguration()
    }

    private func invalidatePublishPlanForCurrentDraft(resetOrigin: Bool = true) {
        model.invalidatePublishPlanIfDraftChanged(
            tunnelName: tunnelName,
            hostname: hostname,
            service: service,
            path: path,
            resetOrigin: resetOrigin
        )
    }

    private func normalizeTunnelSelection() {
        let value = model.publishDraft.tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesDeletedTunnel = model.tunnels.contains {
            !$0.isAvailable && $0.matchesSelection(value)
        }
        if value.isEmpty || matchesDeletedTunnel {
            model.publishDraft.tunnelName = model.preferredTunnelName ?? ""
        }
    }

    private func formattedLatency(_ latency: TimeInterval) -> String {
        if latency < 1 {
            return "\(Int((latency * 1_000).rounded())) 毫秒"
        }
        return "\(latency.formatted(.number.precision(.fractionLength(1)))) 秒"
    }
}
