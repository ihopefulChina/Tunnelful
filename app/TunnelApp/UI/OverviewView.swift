import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var process: TunnelProcessController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var runnableTunnel: String? {
        model.preferredTunnelName
    }

    private var displayedTunnelName: String {
        guard let runnableTunnel else { return "尚未选择 Tunnel" }
        return runnableTunnel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
                statusBoard

                if let diagnostic = process.edgeDiagnostic {
                    VStack(alignment: .leading, spacing: AppMetrics.controlSpacing) {
                        NoticeView(
                            kind: process.edgeState == .unreachable ? .warning : .info,
                            title: process.edgeState == .unreachable
                                ? "Cloudflare Edge 连不上"
                                : "正在连接 Cloudflare Edge",
                            message: diagnostic
                        )
                        if process.suggestsHTTP2Protocol, model.transportProtocol != .http2 {
                            Button("跳过 QUIC，使用 HTTP/2 重试") {
                                model.retryTunnelUsingHTTP2()
                            }
                        }
                        if process.suggestsQUICProtocol, model.transportProtocol != .quic {
                            Button("改用 QUIC 重试") {
                                model.retryTunnelUsingQUIC()
                            }
                        }
                    }
                }

                managedTunnelSection
                environmentSection

                if let message = model.startupAutomationMessage {
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
            .frame(maxWidth: 1_080, alignment: .leading)
        }
        .appPageBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.bootstrap() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .help("刷新 cloudflared、配置与 Tunnel 列表")
                .disabled(model.isRefreshing)
                .accessibilityLabel("刷新运行状态")
                .accessibilityValue(model.isRefreshing ? "正在刷新" : "")
            }
        }
        .animation(AppMotion.content(reduceMotion), value: process.processState)
        .animation(AppMotion.content(reduceMotion), value: process.edgeState)
        .animation(AppMotion.content(reduceMotion), value: model.originState)
    }

    private var statusBoard: some View {
        StatusBoard {
            StatusMetric(
                title: "本地进程",
                value: process.processState.label,
                detail: processDetail,
                symbol: processSymbol,
                tint: processTint,
                isTransient: {
                    if case .starting = process.processState { return true }
                    return false
                }()
            )
            Divider()
            StatusMetric(
                title: "Cloudflare Edge",
                value: process.edgeState.rawValue,
                detail: edgeDetail,
                symbol: edgeSymbol,
                tint: edgeTint,
                isTransient: process.edgeState == .connecting || process.edgeState == .degraded
            )
            Divider()
            StatusMetric(
                title: "本地源站",
                value: model.originState.label,
                detail: "独立探测，避免 Tunnel 已连接却掩盖源站故障。",
                symbol: originSymbol,
                tint: originTint,
                isTransient: {
                    if case .checking = model.originState { return true }
                    return false
                }()
            )
        }
    }

    private var managedTunnelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "本 App 管理的 Tunnel")

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayedTunnelName)
                        .font(.title3.weight(.semibold))
                    Text("这里只控制由本 App 启动的进程。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if case .running = process.processState {
                    Button {
                        if let runnableTunnel { model.restartTunnel(named: runnableTunnel) }
                    } label: {
                        Label("重新启动", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        model.stopTunnel()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        if let runnableTunnel { model.startTunnel(named: runnableTunnel) }
                    } label: {
                        Label("启动 Tunnel", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runnableTunnel == nil || model.installation == nil)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 64)
            .appSurface(padding: 0)
        }
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "运行环境")

            VStack(spacing: 0) {
                if let installation = model.installation {
                    KeyValueRow(key: "可执行文件", value: installation.executableURL.path)
                        .padding(.vertical, 9)
                    Divider().padding(.leading, 100)
                    KeyValueRow(key: "版本", value: installation.version)
                        .padding(.vertical, 9)
                    Divider().padding(.leading, 100)
                    KeyValueRow(key: "安装来源", value: installation.source.rawValue)
                        .padding(.vertical, 9)
                    Divider().padding(.leading, 100)
                    KeyValueRow(key: "传输协议", value: model.transportProtocol.title)
                        .padding(.vertical, 9)
                } else {
                    Text("未找到 cloudflared。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                }
                Divider().padding(.leading, 100)
                KeyValueRow(
                    key: "配置文件",
                    value: model.selectedConfigURL?.path ?? "尚未导入"
                )
                .padding(.vertical, 9)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .appSurface(padding: 0)
        }
    }

    private var processDetail: String {
        if case let .running(pid) = process.processState {
            return "本 App 管理的 PID \(pid)。"
        }
        return "此状态不代表系统中不存在其他后台服务。"
    }

    private var processSymbol: String {
        if case .running = process.processState { return "play.circle.fill" }
        if case .failed = process.processState { return "xmark.octagon.fill" }
        if case .starting = process.processState { return "arrow.clockwise.circle" }
        return "stop.circle"
    }

    private var processTint: Color {
        if case .running = process.processState { return AppPalette.statusGreen }
        if case .failed = process.processState { return .red }
        if case .starting = process.processState { return .accentColor }
        return .secondary
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

    private var edgeSymbol: String {
        switch process.edgeState {
        case .connected: return "checkmark.icloud.fill"
        case .degraded: return "exclamationmark.icloud.fill"
        case .connecting: return "icloud.and.arrow.up"
        case .unreachable: return "xmark.icloud.fill"
        case .unknown: return "icloud"
        }
    }

    private var edgeTint: Color {
        switch process.edgeState {
        case .connected: return AppPalette.statusGreen
        case .degraded: return AppPalette.statusOrange
        case .connecting: return .accentColor
        case .unreachable: return .red
        case .unknown: return .secondary
        }
    }

    private var originSymbol: String {
        switch model.originState {
        case .reachable: return "checkmark.circle.fill"
        case .unreachable: return "xmark.circle.fill"
        case .checking: return "clock.arrow.circlepath"
        case .notChecked: return "circle.dashed"
        }
    }

    private var originTint: Color {
        switch model.originState {
        case .reachable: return AppPalette.statusGreen
        case .unreachable: return .red
        case .checking: return .accentColor
        case .notChecked: return .secondary
        }
    }
}
