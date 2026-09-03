import AppKit
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var process: TunnelProcessController
    @State private var searchText = ""
    @State private var stream: StreamFilter = .all

    private enum StreamFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case app = "应用"
        case output = "输出"
        case error = "错误"

        var id: Self { self }
    }

    private var filteredLogs: [LogEntry] {
        process.logs.filter { entry in
            let streamMatches: Bool
            switch stream {
            case .all: streamMatches = true
            case .app: streamMatches = entry.stream == .app
            case .output: streamMatches = entry.stream == .standardOutput
            case .error: streamMatches = entry.stream == .standardError
            }
            return streamMatches && (
                searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "日志",
                subtitle: "实时显示本 App 启动的进程输出，并自动遮罩常见凭据。"
            )

            HStack(spacing: 12) {
                Picker("来源", selection: $stream) {
                    ForEach(StreamFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)

                TextField("搜索日志", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    copyLogs()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .disabled(filteredLogs.isEmpty)

                Button(role: .destructive) {
                    process.clearLogs()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .disabled(process.logs.isEmpty)
            }

            if filteredLogs.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? "暂无日志" : "没有匹配的日志", systemImage: "doc.text")
                } description: {
                    Text(searchText.isEmpty ? "启动 Tunnel 后，这里会实时显示已脱敏的进程输出。" : "请调整搜索或来源筛选。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredLogs) {
                    TableColumn("时间") { entry in
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 92, max: 110)

                    TableColumn("来源") { entry in
                        Label(entry.stream.rawValue, systemImage: streamSymbol(entry.stream))
                            .foregroundStyle(streamTint(entry.stream))
                    }
                    .width(min: 72, ideal: 82, max: 100)

                    TableColumn("消息") { entry in
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 34)
        .padding(.bottom, 30)
        .background(AppPalette.workspaceBackground)
    }

    private func copyLogs() {
        let text = filteredLogs.map {
            "\($0.timestamp.formatted(.iso8601)) [\($0.stream.rawValue)] \($0.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func streamSymbol(_ stream: LogEntry.Stream) -> String {
        switch stream {
        case .app: return "app.badge"
        case .standardOutput: return "arrow.right.circle"
        case .standardError: return "exclamationmark.triangle"
        }
    }

    private func streamTint(_ stream: LogEntry.Stream) -> Color {
        switch stream {
        case .standardError: return AppPalette.statusOrange
        case .app, .standardOutput: return .secondary
        }
    }
}
