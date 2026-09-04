import AppKit
import SwiftUI

enum AppMetrics {
    static let cornerRadius: CGFloat = 8
    static let pagePadding: CGFloat = 24
    static let pageTopPadding: CGFloat = 16
    static let pageBottomPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 12
    static let controlSpacing: CGFloat = 8
    static let stackSpacing: CGFloat = 16
    static let panelPadding: CGFloat = 14
    static let compactPadding: CGFloat = 12
    static let keyColumnWidth: CGFloat = 88
    static let keyValueSpacing: CGFloat = 12
    static let accessoryColumnWidth: CGFloat = 24
    static let iconHitSize: CGFloat = 28
    static let hairlineOpacity: Double = 0.55
    static let maxReadableWidth: CGFloat = 920
    static let maxContentWidth: CGFloat = 1_080
    static let statusMetricMinWidth: CGFloat = 180

    static var keyValueDividerInset: CGFloat { keyColumnWidth + keyValueSpacing }
    static var accessoryDividerInset: CGFloat { accessoryColumnWidth + keyValueSpacing }
    static var listDividerInset: CGFloat { panelPadding + accessoryDividerInset }
}

enum AppShape {
    static var panel: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppMetrics.cornerRadius, style: .continuous)
    }
}

enum AppMotion {
    static let ui = Animation.spring(duration: 0.35, bounce: 0)

    static func content(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : ui
    }
}

enum AppPalette {
    /// Light: window-like wash, not Preview's under-page desk gray.
    /// Dark: slightly below the lifted panels so groups still separate.
    static let workspace = dynamicColor(
        name: "TunnelfulWorkspaceBackground",
        light: NSColor(calibratedWhite: 0.96, alpha: 1),
        dark: NSColor(calibratedWhite: 0.12, alpha: 1)
    )

    static let panel = dynamicColor(
        name: "TunnelfulPanelBackground",
        light: NSColor.white,
        dark: NSColor(calibratedWhite: 0.18, alpha: 1)
    )

    static let hairline = Color(nsColor: .separatorColor)

    static let statusGreen = dynamicColor(
        name: "TunnelfulStatusGreen",
        light: NSColor(calibratedRed: 0.22, green: 0.55, blue: 0.34, alpha: 1),
        dark: NSColor(calibratedRed: 0.48, green: 0.78, blue: 0.56, alpha: 1)
    )

    static let statusOrange = dynamicColor(
        name: "TunnelfulStatusOrange",
        light: NSColor(calibratedRed: 0.72, green: 0.45, blue: 0.12, alpha: 1),
        dark: NSColor(calibratedRed: 0.92, green: 0.68, blue: 0.30, alpha: 1)
    )

    static let statusRed = dynamicColor(
        name: "TunnelfulStatusRed",
        light: NSColor(calibratedRed: 0.72, green: 0.20, blue: 0.18, alpha: 1),
        dark: NSColor(calibratedRed: 0.96, green: 0.54, blue: 0.50, alpha: 1)
    )

    private static func dynamicColor(name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum StatusAppearance {
    static func processSymbol(_ state: ManagedProcessState) -> String {
        switch state {
        case .running: return "play.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .starting: return "arrow.clockwise.circle"
        case .stopped: return "stop.circle"
        }
    }

    static func processTint(_ state: ManagedProcessState) -> Color {
        switch state {
        case .running: return AppPalette.statusGreen
        case .failed: return AppPalette.statusRed
        case .starting: return .accentColor
        case .stopped: return .secondary
        }
    }

    static func edgeSymbol(_ state: EdgeConnectionState) -> String {
        switch state {
        case .connected: return "checkmark.icloud.fill"
        case .degraded: return "exclamationmark.icloud.fill"
        case .connecting: return "icloud.and.arrow.up"
        case .unreachable: return "xmark.icloud.fill"
        case .unknown: return "icloud"
        }
    }

    static func edgeTint(_ state: EdgeConnectionState) -> Color {
        switch state {
        case .connected: return AppPalette.statusGreen
        case .degraded: return AppPalette.statusOrange
        case .connecting: return .accentColor
        case .unreachable: return AppPalette.statusRed
        case .unknown: return .secondary
        }
    }

    static func originSymbol(_ state: OriginReachabilityState) -> String {
        switch state {
        case .reachable: return "checkmark.circle.fill"
        case .unreachable: return "xmark.circle.fill"
        case .checking: return "clock.arrow.circlepath"
        case .notChecked: return "circle.dashed"
        }
    }

    static func originTint(_ state: OriginReachabilityState) -> Color {
        switch state {
        case .reachable: return AppPalette.statusGreen
        case .unreachable: return AppPalette.statusRed
        case .checking: return .accentColor
        case .notChecked: return .secondary
        }
    }
}

struct AppSurfaceModifier: ViewModifier {
    var padding: CGFloat = AppMetrics.panelPadding
    var fill: Color = AppPalette.panel
    var tint: Color = .clear
    var borderColor: Color = AppPalette.hairline.opacity(AppMetrics.hairlineOpacity)

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                AppShape.panel.fill(fill)
                AppShape.panel.fill(tint)
            }
            .overlay {
                AppShape.panel.strokeBorder(borderColor, lineWidth: 1)
            }
    }
}

struct AppPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppPalette.workspace)
    }
}

struct AppChromeBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Rectangle().fill(AppPalette.workspace)
                } else {
                    Rectangle().fill(.bar)
                }
            }
            .overlay(alignment: .top) {
                Divider()
            }
    }
}

extension View {
    func appSurface(
        padding: CGFloat = AppMetrics.panelPadding,
        fill: Color = AppPalette.panel,
        tint: Color = .clear,
        borderColor: Color = AppPalette.hairline.opacity(AppMetrics.hairlineOpacity)
    ) -> some View {
        modifier(AppSurfaceModifier(padding: padding, fill: fill, tint: tint, borderColor: borderColor))
    }

    func appPageBackground() -> some View {
        modifier(AppPageBackground())
    }

    func appChromeBackground() -> some View {
        modifier(AppChromeBackground())
    }
}

struct StatusMetric: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    var isTransient: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.controlSpacing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.2)

            HStack(alignment: .center, spacing: AppMetrics.controlSpacing) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.pulse, options: .repeating, isActive: isTransient && !reduceMotion)
                    .accessibilityHidden(true)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .contentTransition(reduceMotion ? .opacity : .interpolate)
            }

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(AppMetrics.panelPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)。\(detail)")
    }
}

struct StatusBoard: View {
    let metrics: [StatusMetric]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            board(axis: .horizontal)
            board(axis: .vertical)
        }
        .background(AppPalette.panel, in: AppShape.panel)
        .overlay {
            AppShape.panel.strokeBorder(AppPalette.hairline.opacity(AppMetrics.hairlineOpacity), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func board(axis: Axis) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))

        layout {
            ForEach(Array(metrics.enumerated()), id: \.element.title) { index, metric in
                metric
                    .frame(
                        minWidth: axis == .horizontal ? AppMetrics.statusMetricMinWidth : 0,
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
                if index < metrics.count - 1 {
                    if axis == .horizontal {
                        Divider().padding(.vertical, AppMetrics.panelPadding)
                    } else {
                        Divider().padding(.horizontal, AppMetrics.panelPadding)
                    }
                }
            }
        }
    }
}

enum NoticeKind {
    case info
    case warning
    case success

    var symbol: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: return .accentColor
        case .warning: return AppPalette.statusOrange
        case .success: return AppPalette.statusGreen
        }
    }

    var wash: Color {
        color.opacity(0.08)
    }
}

struct NoticeView<Actions: View>: View {
    let kind: NoticeKind
    let title: String
    let message: String
    let actionContent: Actions

    init(
        kind: NoticeKind,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actionContent = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(kind.color)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }

            if Actions.self != EmptyView.self {
                actionContent
            }
        }
        .appSurface(
            padding: AppMetrics.compactPadding,
            tint: kind.wash,
            borderColor: kind.color.opacity(0.28)
        )
        .accessibilityElement(children: .contain)
    }
}

extension NoticeView where Actions == EmptyView {
    init(kind: NoticeKind, title: String, message: String) {
        self.init(kind: kind, title: title, message: message) { EmptyView() }
    }
}

struct FieldErrorText: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(AppPalette.statusRed)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityLabel("错误：\(message)")
        }
    }
}

struct KeyValueRow: View {
    enum ValueStyle {
        case text
        case path
    }

    let key: String
    let value: String
    var style: ValueStyle = .text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppMetrics.keyValueSpacing) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: AppMetrics.keyColumnWidth, alignment: .trailing)
            Text(value)
                .font(style == .path ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(value)
        }
        .font(.body)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key)，\(value)")
        .accessibilityHint(style == .path ? "完整路径可复制" : "")
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .tracking(-0.2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct IconToolButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var helpText: String
    var role: ButtonRole?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: AppMetrics.iconHitSize, height: AppMetrics.iconHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct AppToolbarProgressButton: View {
    let title: String
    let systemImage: String
    let help: String
    let accessibilityLabel: String
    var isBusy = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                ZStack {
                    Image(systemName: systemImage)
                        .opacity(isBusy ? 0 : 1)
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .disabled(disabled || isBusy)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isBusy ? "正在处理" : "")
    }
}

struct WindowStatusBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var process: TunnelProcessController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: AppMetrics.controlSpacing) {
            statusChip(process.processState.label, tint: StatusAppearance.processTint(process.processState))
            separator
            statusChip("Edge \(process.edgeState.rawValue)", tint: StatusAppearance.edgeTint(process.edgeState))
            separator
            statusChip("源站 \(model.originState.label)", tint: StatusAppearance.originTint(model.originState))
            Spacer(minLength: 12)
            if let name = model.preferredTunnelName {
                Text(name)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
            }
        }
        .font(.caption.weight(.medium))
        .tracking(0.15)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appChromeBackground()
        .animation(AppMotion.content(reduceMotion), value: process.processState)
        .animation(AppMotion.content(reduceMotion), value: process.edgeState)
        .animation(AppMotion.content(reduceMotion), value: model.originState)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func statusChip(_ label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private var accessibilitySummary: String {
        let tunnel = model.preferredTunnelName.map { "，当前 Tunnel \($0)" } ?? ""
        return "本地进程 \(process.processState.label)，Edge \(process.edgeState.rawValue)，源站 \(model.originState.label)\(tunnel)"
    }
}

enum AppActions {
    static let projectURL = URL(string: "https://github.com/ihopefulChina/Tunnelful")!
    static let issuesURL = projectURL.appendingPathComponent("issues", isDirectory: true)
    static let cloudflaredInstallURL = URL(
        string: "https://developers.cloudflare.com/tunnel/advanced/local-management/create-local-tunnel/"
    )!

    @MainActor
    static func showAboutPanel() {
        ApplicationActivation.openWindow {
            NSApplication.shared.orderFrontStandardAboutPanel(options: [
                .applicationName: AppIdentity.displayName,
                .applicationVersion: AppIdentity.releaseVersion,
                .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            ])
        }
    }

    static func openProjectPage() {
        NSWorkspace.shared.open(projectURL)
    }

    static func openIssuesPage() {
        NSWorkspace.shared.open(issuesURL)
    }
}
