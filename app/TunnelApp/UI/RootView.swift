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
            ApplicationActivation.showSystemMenu()
            consumeRequestedSection(model.requestedSection)
        }
        .alert("需要处理", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage.map { model.displayMessage($0) } ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.privacyMode.toggle()
                } label: {
                    Label(
                        model.privacyMode ? "关闭隐私遮罩" : "开启隐私遮罩",
                        systemImage: model.privacyMode ? "eye.slash" : "eye"
                    )
                }
                .help("遮罩路径、Tunnel ID、域名与服务，方便安全截图")
            }
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
