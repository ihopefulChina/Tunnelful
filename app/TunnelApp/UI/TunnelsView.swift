import SwiftUI

struct TunnelsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.tunnels.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptySymbol)
                } description: {
                    Text(emptyMessage)
                } actions: {
                    Button("刷新") {
                        Task { await model.refreshTunnels() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRefreshingTunnels)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.tunnels) {
                    TableColumn("名称") { tunnel in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tunnel.name).fontWeight(.medium)
                            Text(tunnel.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                    TableColumn("连接数") { tunnel in
                        Text(tunnel.connectionCount.formatted())
                            .monospacedDigit()
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("创建时间") { tunnel in
                        Text(tunnel.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 150, ideal: 180)
                    TableColumn("状态") { tunnel in
                        Label(
                            tunnel.deletedAt == nil ? "可用" : "已删除",
                            systemImage: tunnel.deletedAt == nil ? "checkmark.circle" : "trash"
                        )
                        .foregroundStyle(tunnel.deletedAt == nil ? Color.secondary : Color.red)
                    }
                    .width(min: 90, ideal: 110)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .appPageBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshTunnels() }
                } label: {
                    if model.isRefreshingTunnels {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新 Tunnel", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing || model.isRefreshingTunnels)
                .accessibilityLabel("刷新 Tunnel 列表")
                .accessibilityValue(model.isRefreshingTunnels ? "正在刷新" : "")
            }
        }
    }

    private var emptyTitle: String {
        switch model.tunnelDiscoveryState {
        case .loading: return "正在读取 Tunnel"
        case .failed: return "无法读取 Tunnel"
        case let .loaded(count) where count == 0: return "账户中没有 Tunnel"
        case .notChecked, .loaded: return "尚未发现 Tunnel"
        }
    }

    private var emptyMessage: String {
        switch model.tunnelDiscoveryState {
        case .loading:
            return "正在通过官方 cloudflared 检查账户连接。"
        case let .failed(message):
            return message
        case let .loaded(count) where count == 0:
            return "账户连接有效，但当前没有命名 Tunnel；本地配置仍可继续导入和查看。"
        case .notChecked, .loaded:
            return "前往“环境检查”完成安装或登录，然后重新刷新。"
        }
    }

    private var emptySymbol: String {
        switch model.tunnelDiscoveryState {
        case .failed: return "exclamationmark.triangle"
        case .loading: return "arrow.clockwise"
        case .notChecked, .loaded: return "point.3.connected.trianglepath.dotted"
        }
    }
}
