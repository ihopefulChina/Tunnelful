import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "概览"
    case tunnels = "Tunnel"
    case publish = "发布服务"
    case configuration = "Ingress 配置"
    case environment = "环境检查"
    case logs = "日志"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .tunnels: return "point.3.connected.trianglepath.dotted"
        case .publish: return "arrow.up.forward.app"
        case .configuration: return "slider.horizontal.3"
        case .environment: return "checklist.checked"
        case .logs: return "text.alignleft"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
                    .accessibilityLabel(section.rawValue)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 188, ideal: 212, max: 244)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.requestedSection) { _, section in
            consumeRequestedSection(section)
        }
        .onAppear {
            TunnelfulWindowActions.openMainWindow = {
                model.openMainWindow(openWindow: openWindow)
            }
            ApplicationActivation.showSystemMenu()
            consumeRequestedSection(model.requestedSection)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tunnelfulOpenMainWindow)) { _ in
            model.openMainWindow(openWindow: openWindow)
        }
        .alert("需要处理", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .overview {
        case .overview: OverviewView()
        case .tunnels: TunnelsView()
        case .publish: PublishView()
        case .configuration: ConfigurationEditorView()
        case .environment: EnvironmentView()
        case .logs: LogsView()
        }
    }

    private func consumeRequestedSection(_ section: AppSection?) {
        guard let section else { return }
        selection = section
        model.requestedSection = nil
    }

}
