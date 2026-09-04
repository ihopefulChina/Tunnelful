import AppKit
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var process: TunnelProcessController
    @State private var searchText = ""
    @State private var stream: StreamFilter = .all
    @State private var isConfirmingClear = false

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
        Group {
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
                            .lineLimit(3)
                            .help(entry.message)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .appPageBackground()
        .searchable(text: $searchText, prompt: "搜索日志")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("来源", selection: $stream) {
                    ForEach(StreamFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .help("按来源筛选日志")
            }

            ToolbarItem {
                Button {
                    copyLogs()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .disabled(filteredLogs.isEmpty)
                .help("复制当前筛选后的日志")
            }

            ToolbarItem {
                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .disabled(process.logs.isEmpty)
                .help("清空本窗口中的日志")
                .confirmationDialog(
                    "清空全部日志？",
                    isPresented: $isConfirmingClear,
                    titleVisibility: .visible
                ) {
                    Button("清空日志", role: .destructive) {
                        process.clearLogs()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("只清除 Tunnelful 窗口中的记录，不会影响 cloudflared 进程。")
                }
            }
        }
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
