import AppKit
import SwiftUI

enum AppPalette {
    static let workspaceBackground = dynamicColor(
        name: "TunnelfulWorkspaceBackground",
        light: NSColor(calibratedRed: 0.995, green: 0.993, blue: 0.988, alpha: 1),
        dark: NSColor(calibratedRed: 0.105, green: 0.102, blue: 0.098, alpha: 1)
    )

    static let panelBackground = dynamicColor(
        name: "TunnelfulPanelBackground",
        light: NSColor(calibratedRed: 0.958, green: 0.956, blue: 0.950, alpha: 1),
        dark: NSColor(calibratedRed: 0.155, green: 0.151, blue: 0.146, alpha: 1)
    )

    static let statusGreen = dynamicColor(
        name: "TunnelfulStatusGreen",
        light: NSColor(calibratedRed: 0.28, green: 0.50, blue: 0.33, alpha: 1),
        dark: NSColor(calibratedRed: 0.46, green: 0.68, blue: 0.50, alpha: 1)
    )

    static let statusOrange = dynamicColor(
        name: "TunnelfulStatusOrange",
        light: NSColor(calibratedRed: 0.60, green: 0.396, blue: 0.133, alpha: 1),
        dark: NSColor(calibratedRed: 0.80, green: 0.60, blue: 0.33, alpha: 1)
    )

    private static func dynamicColor(name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct StatusTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)

            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(value)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .padding(14)
            .background(AppPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)。\(detail)")
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
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(12)
        .background(AppPalette.panelBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        LabeledContent(key) {
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
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
