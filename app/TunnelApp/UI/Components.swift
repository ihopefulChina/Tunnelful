import AppKit
import SwiftUI

enum AppMetrics {
    static let cornerRadius: CGFloat = 8
    static let pagePadding: CGFloat = 24
    static let pageTopPadding: CGFloat = 18
    static let pageBottomPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 12
    static let controlSpacing: CGFloat = 8
    static let maxReadableWidth: CGFloat = 920
}

enum AppMotion {
    static let ui = Animation.spring(duration: 0.35, bounce: 0)

    static func content(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : ui
    }
}

enum AppPalette {
    static let workspace = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)

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

    private static func dynamicColor(name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct AppSurfaceModifier: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: AppMetrics.cornerRadius, style: .continuous))
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
    func appSurface(padding: CGFloat = 14) -> some View {
        modifier(AppSurfaceModifier(padding: padding))
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.2)

            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.pulse, options: .repeating, isActive: isTransient && !reduceMotion)
                    .accessibilityHidden(true)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .opacity : .interpolate)
            }

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)。\(detail)")
    }
}

struct StatusBoard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            content
        }
        .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: AppMetrics.cornerRadius, style: .continuous))
    }
}

struct NoticeView: View {
    enum Kind {
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
    }

    let kind: Kind
    let title: String
    let message: String

    var body: some View {
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
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: AppMetrics.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key)，\(value)")
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .tracking(-0.2)
    }
}

struct WindowStatusBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var process: TunnelProcessController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            statusDot(processTint)
            Text(process.processState.label)
            separator
            Text("Edge \(process.edgeState.rawValue)")
                .foregroundStyle(edgeTint)
            separator
            Text("源站 \(model.originState.label)")
                .foregroundStyle(originTint)
            Spacer(minLength: 12)
            if let name = model.preferredTunnelName {
                Text(name)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
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

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var processTint: Color {
        if case .running = process.processState { return AppPalette.statusGreen }
        if case .failed = process.processState { return .red }
        if case .starting = process.processState { return .accentColor }
        return .secondary
    }

    private var edgeTint: Color {
        switch process.edgeState {
        case .connected: return AppPalette.statusGreen
        case .degraded: return AppPalette.statusOrange
        case .connecting: return .primary
        case .unreachable: return .red
        case .unknown: return .secondary
        }
    }

    private var originTint: Color {
        switch model.originState {
        case .reachable: return AppPalette.statusGreen
        case .unreachable: return .red
        case .checking: return .primary
        case .notChecked: return .secondary
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
