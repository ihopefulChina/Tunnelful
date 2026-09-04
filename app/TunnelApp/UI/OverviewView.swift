import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var process: TunnelProcessController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var runnableTunnel: String? {
        switch process.processState {
        case .running, .starting:
            return process.managedTunnelName
        default:
            return model.preferredTunnelName
        }
    }

    private var displayedTunnelName: String {
        guard let runnableTunnel else { return "尚未选择 Tunnel" }
        return runnableTunnel
    }

    private var currentOriginState: OriginReachabilityState {
        model.originState(for: model.currentOriginService)
    }

    private var visibleStartupAutomationMessage: String? {
        guard let message = model.startupAutomationMessage else { return nil }
        guard message == "已按设置启动当前 Tunnel。" else { return message }
        switch process.processState {
        case .starting, .running: return message
        case .stopped, .failed: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
                statusBoard

                if let diagnostic = process.edgeDiagnostic {
                    diagnosticBanner(diagnostic)
                }

                managedTunnelSection
                environmentSection

                if let message = visibleStartupAutomationMessage {
                    NoticeView(kind: .info, title: "自动启动", message: message)
                }

                if model.configDocument == nil {
                    NoticeView(
                        kind: .warning,
                        title: "尚未导入配置",
                        message: "导入 config.yml 后即可编辑 Ingress 规则并运行命名 Tunnel。"
                    )
                } else if let message = model.lastValidationMessage {
                    NoticeView(
                        kind: .success,
                        title: "配置校验通过",
                        message: message
                    )
                }
            }
            .padding(.horizontal, AppMetrics.pagePadding)
            .padding(.top, AppMetrics.pageTopPadding)
            .padding(.bottom, AppMetrics.pageBottomPadding)
            .frame(maxWidth: AppMetrics.maxContentWidth, alignment: .leading)
        }
        .appPageBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AppToolbarProgressButton(
                    title: "刷新",
                    systemImage: "arrow.clockwise",
                    help: "刷新 cloudflared、配置与 Tunnel 列表",
                    accessibilityLabel: "刷新运行状态",
                    isBusy: model.isRefreshing
                ) {
                    Task { await model.bootstrap() }
                }
            }
        }
        .animation(AppMotion.content(reduceMotion), value: process.processState)
        .animation(AppMotion.content(reduceMotion), value: process.edgeState)
        .animation(AppMotion.content(reduceMotion), value: currentOriginState)
    }

    private var statusBoard: some View {
        StatusBoard(metrics: [
            StatusMetric(
                title: "本地进程",
                value: process.processState.label,
                detail: processDetail,
                symbol: StatusAppearance.processSymbol(process.processState),
                tint: StatusAppearance.processTint(process.processState),
                isTransient: {
                    if case .starting = process.processState { return true }
                    return false
                }()
            ),
            StatusMetric(
                title: "Cloudflare Edge",
                value: process.edgeState.rawValue,
                detail: edgeDetail,
                symbol: StatusAppearance.edgeSymbol(process.edgeState),
                tint: StatusAppearance.edgeTint(process.edgeState),
                isTransient: process.edgeState == .connecting || process.edgeState == .degraded
            ),
            StatusMetric(
                title: "本地源站",
                value: currentOriginState.label,
                detail: originDetail,
                symbol: StatusAppearance.originSymbol(currentOriginState),
                tint: StatusAppearance.originTint(currentOriginState),
                isTransient: {
                    if case .checking = currentOriginState { return true }
                    return false
                }()
            )
        ])
    }

    @ViewBuilder
    private func diagnosticBanner(_ diagnostic: String) -> some View {
        let isUnreachable = process.edgeState == .unreachable
        let showHTTP2Retry = process.suggestsHTTP2Protocol && model.transportProtocol != .http2
        let showQUICRetry = process.suggestsQUICProtocol && model.transportProtocol != .quic
        let kind: NoticeKind = isUnreachable ? .warning : .info
        let title = isUnreachable ? "Cloudflare Edge 连不上" : "正在连接 Cloudflare Edge"

        if showHTTP2Retry || showQUICRetry {
            NoticeView(kind: kind, title: title, message: diagnostic) {
                HStack(spacing: AppMetrics.controlSpacing) {
                    if showHTTP2Retry {
                        Button("跳过 QUIC，使用 HTTP/2 重试") {
                            model.retryTunnelUsingHTTP2()
                        }
                    }
                    if showQUICRetry {
                        Button("改用 QUIC 重试") {
                            model.retryTunnelUsingQUIC()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.regular)
            }
        } else {
            NoticeView(kind: kind, title: title, message: diagnostic)
        }
    }

    private var managedTunnelSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.controlSpacing) {
            SectionHeader(title: "本 App 管理的 Tunnel")

            HStack(spacing: AppMetrics.rowSpacing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayedTunnelName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .help(displayedTunnelName)
                    Text("这里只控制由本 App 启动的进程。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: AppMetrics.controlSpacing) {
                    if case .running = process.processState {
                        Button {
                            if let runnableTunnel { model.restartTunnel(named: runnableTunnel) }
                        } label: {
                            Label("重新启动", systemImage: "arrow.clockwise")
                        }
                        .help("停止后立即重新启动当前 Tunnel")

                        Button(role: .destructive) {
                            model.stopTunnel()
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                        }
                        .help("停止由本 App 启动的 Tunnel 进程")
                    } else {
                        Button {
                            if let runnableTunnel { model.startTunnel(named: runnableTunnel) }
                        } label: {
                            Label("启动 Tunnel", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(runnableTunnel == nil || model.installation == nil)
                        .help(startTunnelHelp)
                    }
                }
            }
            .padding(.horizontal, AppMetrics.panelPadding)
            .padding(.vertical, AppMetrics.compactPadding)
            .frame(minHeight: 64)
            .appSurface(padding: 0)
        }
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.controlSpacing) {
            SectionHeader(title: "运行环境")

            VStack(spacing: 0) {
                if let installation = model.installation {
                    KeyValueRow(key: "可执行文件", value: installation.executableURL.path, style: .path)
                        .padding(.vertical, 9)
                    Divider().padding(.leading, AppMetrics.keyValueDividerInset)
                    KeyValueRow(key: "版本", value: installation.version)
                        .padding(.vertical, 9)
                    Divider().padding(.leading, AppMetrics.keyValueDividerInset)
                    KeyValueRow(key: "安装来源", value: installation.source.rawValue)
                        .padding(.vertical, 9)
                    Divider().padding(.leading, AppMetrics.keyValueDividerInset)
                    KeyValueRow(key: "传输协议", value: model.transportProtocol.title)
                        .padding(.vertical, 9)
                } else {
                    Text("未找到 cloudflared。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                }
                Divider().padding(.leading, AppMetrics.keyValueDividerInset)
                KeyValueRow(
                    key: "配置文件",
                    value: model.selectedConfigURL?.path ?? "尚未导入",
                    style: model.selectedConfigURL == nil ? .text : .path
                )
                .padding(.vertical, 9)
            }
            .padding(.horizontal, AppMetrics.panelPadding)
            .padding(.vertical, 4)
            .appSurface(padding: 0)
        }
    }

    private var startTunnelHelp: String {
        if model.installation == nil {
            return "未检测到 cloudflared，请先完成环境检查"
        }
        if runnableTunnel == nil {
            return "请先导入配置或选择命名 Tunnel"
        }
        return "启动当前命名 Tunnel"
    }

    private var processDetail: String {
        if case let .running(pid) = process.processState {
            if let tunnelName = process.managedTunnelName {
                return "本 App 管理 \(tunnelName)，PID \(pid)。"
            }
            return "本 App 管理的 PID \(pid)。"
        }
        return "此状态不代表系统中不存在其他后台服务。"
    }

    private var originDetail: String {
        guard let service = model.currentOriginService else {
            return "当前配置没有可独立检查的源站。"
        }
        if let failure = currentOriginState.failureMessage {
            return failure
        }
        switch currentOriginState {
        case .notChecked:
            return "尚未独立检查 \(service)。"
        case .checking:
            return "正在独立检查 \(service)。"
        case .reachable:
            if let latency = model.originLatency(for: service) {
                return "已独立检查 \(service)，耗时 \(formattedLatency(latency))。"
            }
            return "已独立检查 \(service)。"
        case .unreachable:
            return "源站当前无法访问。"
        }
    }

    private func formattedLatency(_ latency: TimeInterval) -> String {
        if latency < 1 {
            return "\(Int((latency * 1_000).rounded())) 毫秒"
        }
        return "\(latency.formatted(.number.precision(.fractionLength(1)))) 秒"
    }

    private var edgeDetail: String {
        switch process.edgeState {
        case .connected:
            return "按已注册的 Edge 连接判断；其中一条重连不等于隧道断开。"
        case .degraded:
            return "部分 Edge 连接已断开，cloudflared 正在重连。"
        case .connecting:
            return "进程已启动，正在与 Cloudflare Edge 建立连接。"
        case .unreachable:
            return "进程仍在运行，但还没有注册成功的 Edge 连接。"
        case .unknown:
            return "尚未从托管进程的日志判断 Edge 状态。"
        }
    }
}
