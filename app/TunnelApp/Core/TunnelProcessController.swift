import Combine
import Darwin
import Foundation

/// Interprets cloudflared logs into an Edge status.
/// cloudflared keeps several HA connections; one of them retrying is not a tunnel outage.
struct EdgeLogInterpreter: Equatable, Sendable {
    private var liveConnections: Set<Int> = []
    private var sawRegistration = false
    private var quicDialFailed = false
    private var http2EstablishFailed = false
    private var precheckHardFail = false
    private var switchedToHTTP2 = false
    private var forcedHTTP2 = false
    private(set) var diagnostic: String?

    mutating func reset() {
        liveConnections.removeAll(keepingCapacity: true)
        sawRegistration = false
        quicDialFailed = false
        http2EstablishFailed = false
        precheckHardFail = false
        switchedToHTTP2 = false
        forcedHTTP2 = false
        diagnostic = nil
    }

    /// `--protocol http2` (or config) skips QUIC; HTTP/2 handshake failure is then fatal.
    mutating func noteForcedHTTP2(_ forced: Bool) {
        forcedHTTP2 = forced
    }

    var suggestsHTTP2Protocol: Bool {
        quicDialFailed && !sawRegistration
    }

    /// TCP 7844 / HTTP/2 failed, but QUIC was never tried or never failed.
    var suggestsQUICProtocol: Bool {
        http2EstablishFailed && !quicDialFailed && !sawRegistration
    }

    mutating func consume(_ line: String) -> EdgeConnectionState {
        let normalized = line.lowercased()
        let index = Self.connectionIndex(in: normalized)

        if Self.isPrecheckHardFail(normalized) {
            precheckHardFail = true
        }
        if Self.isInitialProtocolHTTP2(normalized) {
            forcedHTTP2 = true
        }
        if Self.isQUICDialFailure(normalized) {
            quicDialFailed = true
        }
        if normalized.contains("switching to fallback protocol http2") {
            switchedToHTTP2 = true
        }
        if Self.isHTTP2EstablishFailure(normalized) {
            http2EstablishFailed = true
        }

        if Self.isRegistration(normalized) {
            liveConnections.insert(index ?? 0)
            sawRegistration = true
        } else if Self.isPerConnectionLoss(normalized) {
            removeConnection(index)
        } else if Self.isEstablishFailure(normalized) {
            // HA 日志偶尔没有 connIndex。有仍注册的连接时，不要把整条隧道清掉。
            if let index {
                liveConnections.remove(index)
            }
        }

        let state = currentState
        diagnostic = Self.makeDiagnostic(
            state: state,
            quicDialFailed: quicDialFailed,
            http2EstablishFailed: http2EstablishFailed,
            precheckHardFail: precheckHardFail,
            switchedToHTTP2: switchedToHTTP2,
            forcedHTTP2: forcedHTTP2
        )
        return state
    }

    private var currentState: EdgeConnectionState {
        if !liveConnections.isEmpty {
            return .connected
        }
        if sawRegistration {
            return .degraded
        }
        if precheckHardFail {
            return .unreachable
        }
        // HTTP/2 TLS 失败只有在确实走了 HTTP/2（强制、回退，或 QUIC 已失败）时
        // 才表示隧道连不上。预检对 TCP 7844 的探测失败不应把仍在用 QUIC 的隧道标红。
        if http2EstablishFailed && (forcedHTTP2 || switchedToHTTP2 || quicDialFailed) {
            return .unreachable
        }
        return .connecting
    }

    private mutating func removeConnection(_ index: Int?) {
        if let index {
            liveConnections.remove(index)
        } else if liveConnections.count <= 1 {
            liveConnections.removeAll(keepingCapacity: true)
        }
    }

    /// "unregistered" contains "registered"; "registering" is still in progress.
    private static func isRegistration(_ line: String) -> Bool {
        if line.contains("unregister") || line.contains("registering") {
            return false
        }
        if line.contains("registered tunnel connection")
            || line.contains("tunnel connection registered")
            || line.contains("connection registered") {
            return true
        }
        return line.range(
            of: #"connection\s+\S+\s+registered"#,
            options: .regularExpression
        ) != nil
    }

    private static func isPerConnectionLoss(_ line: String) -> Bool {
        line.contains("failed to serve tunnel connection")
            || line.contains("unregistered tunnel connection")
    }

    private static func isEstablishFailure(_ line: String) -> Bool {
        isQUICDialFailure(line) || isHTTP2EstablishFailure(line)
            || line.contains("failed to dial cloudflare edge")
    }

    private static func isQUICDialFailure(_ line: String) -> Bool {
        line.contains("failed to dial a quic connection")
            || line.contains("unable to connect to cloudflare network with `quic`")
            || line.contains("unable to connect to cloudflare network with quic")
    }

    private static func isHTTP2EstablishFailure(_ line: String) -> Bool {
        line.contains("unable to establish connection with cloudflare")
            || line.contains("tls handshake with edge error")
    }

    private static func isInitialProtocolHTTP2(_ line: String) -> Bool {
        line.contains("initial protocol http2")
            || line.range(
                of: #"initial protocol["\s:=]+http2"#,
                options: .regularExpression
            ) != nil
    }

    private static func isPrecheckHardFail(_ line: String) -> Bool {
        guard line.contains("precheck complete") else { return false }
        return line.range(
            of: #"hard_fail["\s:=]+true"#,
            options: .regularExpression
        ) != nil
    }

    private static func makeDiagnostic(
        state: EdgeConnectionState,
        quicDialFailed: Bool,
        http2EstablishFailed: Bool,
        precheckHardFail: Bool,
        switchedToHTTP2: Bool,
        forcedHTTP2: Bool
    ) -> String? {
        switch state {
        case .connected, .unknown:
            return nil
        case .degraded:
            return "已有 Edge 连接断开，cloudflared 正在重连。其中一条 HA 连接重试不等于整条隧道中断。"
        case .unreachable:
            if quicDialFailed && http2EstablishFailed {
                return "cloudflared 连不上 Cloudflare Edge：QUIC（UDP 7844）超时，HTTP/2 的 TLS 握手也被关闭。进程还在重试，但现在不能转发流量。请检查防火墙、公司网或 VPN 是否放行 Cloudflare 的 7844 端口。"
            }
            if http2EstablishFailed {
                return "HTTP/2（TCP 7844）到 Cloudflare Edge 的 TLS 握手失败。当前网络拦截了 TCP 7844，但 QUIC（UDP 7844）往往仍可用。命令行默认走 QUIC，所以能连上。请改用 QUIC 后重试。"
            }
            if precheckHardFail {
                return "cloudflared 启动预检失败：到 Cloudflare Edge 的 QUIC 与 HTTP/2 均不可用。请放行 7844 的 UDP/TCP，或关掉会拦截该端口的代理后再启动。"
            }
            return "还没有成功注册的 Edge 连接，隧道现在不能转发流量。"
        case .connecting:
            if switchedToHTTP2 {
                return "QUIC（UDP 7844）已被拦截，正在改用 HTTP/2。"
            }
            if quicDialFailed {
                return "QUIC（UDP 7844）连接超时，cloudflared 仍在重试，稍后可能回退到 HTTP/2。也可在设置里改用 HTTP/2 立即重试。"
            }
            if http2EstablishFailed && !forcedHTTP2 {
                return "预检显示 HTTP/2（TCP 7844）不可用，cloudflared 仍在用 QUIC 连接。这与命令行的 degraded transport 一致，不算隧道断开。"
            }
            return nil
        }
    }

    private static let connectionIndexExpression = try? NSRegularExpression(
        pattern: #"connindex["\s:=]+(\d+)"#
    )

    private static func connectionIndex(in line: String) -> Int? {
        guard let regex = connectionIndexExpression,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return Int(line[range])
    }
}

@MainActor
final class TunnelProcessController: ObservableObject {
    @Published private(set) var processState: ManagedProcessState = .stopped
    @Published private(set) var managedTunnelName: String?
    @Published private(set) var edgeState: EdgeConnectionState = .unknown
    @Published private(set) var edgeDiagnostic: String?
    @Published private(set) var suggestsHTTP2Protocol = false
    @Published private(set) var suggestsQUICProtocol = false
    @Published private(set) var logs: [LogEntry] = []
    private var edgeInterpreter = EdgeLogInterpreter()

    private struct LaunchRequest {
        let executableURL: URL
        let arguments: [String]
        let tunnelName: String?
    }

    private let redactor: any LogRedacting
    private let terminationGracePeriod: TimeInterval
    private var process: Process?
    private var pendingRestart: LaunchRequest?
    private var shutdownCompletion: (() -> Void)?
    private var expectedTerminationPID: Int32?
    private var isShuttingDown = false

    init(
        redactor: any LogRedacting = SensitiveLogRedactor(),
        terminationGracePeriod: TimeInterval = 5
    ) {
        self.redactor = redactor
        self.terminationGracePeriod = terminationGracePeriod
    }

    func start(
        executableURL: URL,
        arguments: [String],
        tunnelName: String? = nil
    ) throws {
        guard !isShuttingDown else { throw CloudflaredError.commandCancelled }
        guard process == nil else { throw CloudflaredError.processAlreadyRunning }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CloudflaredError.invalidExecutable(executableURL)
        }

        let newProcess = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let logDrainGroup = DispatchGroup()
        logDrainGroup.enter()
        logDrainGroup.enter()
        let outputReader = ProcessPipeReader(
            fileHandle: standardOutput.fileHandleForReading,
            label: "\(AppIdentity.bundleIdentifier).logs.stdout"
        )
        let errorReader = ProcessPipeReader(
            fileHandle: standardError.fileHandleForReading,
            label: "\(AppIdentity.bundleIdentifier).logs.stderr"
        )
        newProcess.executableURL = executableURL
        newProcess.arguments = arguments
        newProcess.environment = CloudflaredProcessEnvironment.sanitized()
        newProcess.standardInput = FileHandle.nullDevice
        newProcess.standardOutput = standardOutput
        newProcess.standardError = standardError

        managedTunnelName = tunnelName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        processState = .starting
        resetEdgeObservation(to: .connecting)
        edgeInterpreter.noteForcedHTTP2(Self.argumentsForceHTTP2(arguments))
        appendAppLog(Self.launchDescription(for: arguments))

        newProcess.terminationHandler = { [weak self, weak newProcess] terminated in
            let terminationStatus = terminated.terminationStatus
            let processIdentifier = terminated.processIdentifier
            logDrainGroup.notify(queue: .main) {
                Task { @MainActor [weak self, weak newProcess] in
                    guard let self, let newProcess, self.process === newProcess else { return }
                    self.finishProcess(
                        newProcess,
                        terminationStatus: terminationStatus,
                        processIdentifier: processIdentifier
                    )
                }
            }
        }

        do {
            try newProcess.run()
            process = newProcess
            processState = .running(pid: newProcess.processIdentifier)
            startReading(
                outputReader,
                stream: .standardOutput,
                process: newProcess,
                drainGroup: logDrainGroup
            )
            startReading(
                errorReader,
                stream: .standardError,
                process: newProcess,
                drainGroup: logDrainGroup
            )
        } catch {
            newProcess.terminationHandler = nil
            // The readers are started only after `run()` succeeds. Balance the
            // two registrations so this launch-failure path cannot retain a
            // dispatch group with unfinished work.
            logDrainGroup.leave()
            logDrainGroup.leave()
            try? standardOutput.fileHandleForReading.close()
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForReading.close()
            try? standardError.fileHandleForWriting.close()
            processState = .failed(exitCode: -1)
            managedTunnelName = nil
            resetEdgeObservation(to: .unknown)
            throw CloudflaredError.processCouldNotStart(error.localizedDescription)
        }
    }

    func stop() throws {
        guard let process else { throw CloudflaredError.noProcessRunning }
        pendingRestart = nil
        appendAppLog("正在正常停止托管隧道。")
        requestTermination(of: process)
    }

    func restart(
        executableURL: URL,
        arguments: [String],
        tunnelName: String? = nil
    ) throws {
        guard !isShuttingDown else { throw CloudflaredError.commandCancelled }
        guard let process else {
            try start(executableURL: executableURL, arguments: arguments, tunnelName: tunnelName)
            return
        }
        pendingRestart = LaunchRequest(
            executableURL: executableURL,
            arguments: arguments,
            tunnelName: tunnelName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        appendAppLog("已请求重启，正在等待当前进程停止。")
        requestTermination(of: process)
    }

    func clearLogs() {
        logs.removeAll(keepingCapacity: true)
    }

    func shutdown(completion: @escaping () -> Void) {
        isShuttingDown = true
        pendingRestart = nil
        guard let process else {
            completion()
            return
        }

        shutdownCompletion = completion
        let ownedProcess = process
        appendAppLog("应用已请求退出，正在向托管隧道发送 SIGTERM。")
        requestTermination(of: ownedProcess)
    }

    private func requestTermination(of ownedProcess: Process) {
        expectedTerminationPID = ownedProcess.processIdentifier
        ownedProcess.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + terminationGracePeriod) { [weak self, weak ownedProcess] in
            guard let self,
                  let ownedProcess,
                  self.process === ownedProcess,
                  ownedProcess.isRunning else { return }
            // This PID comes from the exact Process instance created by the app.
            kill(ownedProcess.processIdentifier, SIGKILL)
        }
    }

    private func startReading(
        _ reader: ProcessPipeReader,
        stream: LogEntry.Stream,
        process: Process,
        drainGroup: DispatchGroup
    ) {
        reader.start { [weak self, weak process] lines in
            drainGroup.enter()
            Task { @MainActor [weak self, weak process] in
                defer { drainGroup.leave() }
                guard let self, self.process === process else { return }
                self.consume(lines, stream: stream)
            }
        } onFinished: {
            drainGroup.leave()
        }
    }

    private func finishProcess(
        _ terminatedProcess: Process,
        terminationStatus: Int32,
        processIdentifier: Int32
    ) {
        let wasExpectedTermination = expectedTerminationPID == processIdentifier
        if wasExpectedTermination {
            expectedTerminationPID = nil
        }
        terminatedProcess.terminationHandler = nil
        process = nil
        managedTunnelName = nil
        resetEdgeObservation(to: .unknown)
        if terminationStatus == 0 || wasExpectedTermination {
            processState = .stopped
        } else {
            processState = .failed(exitCode: terminationStatus)
        }
        appendAppLog("隧道进程已退出，状态码为 \(terminationStatus)。")
        if let completion = shutdownCompletion {
            shutdownCompletion = nil
            completion()
            return
        }
        launchPendingRestartIfNeeded()
    }

    private func consume(_ completeLines: [String], stream: LogEntry.Stream) {
        for rawLine in completeLines where !rawLine.isEmpty {
            let message = redactor.redact(rawLine)
            logs.append(LogEntry(timestamp: Date(), stream: stream, message: message))
            applyEdgeInterpretation(edgeInterpreter.consume(message))
        }
        if logs.count > 2_000 {
            logs.removeFirst(logs.count - 2_000)
        }
    }

    private func resetEdgeObservation(to state: EdgeConnectionState) {
        edgeInterpreter.reset()
        edgeState = state
        edgeDiagnostic = nil
        suggestsHTTP2Protocol = false
        suggestsQUICProtocol = false
    }

    private func applyEdgeInterpretation(_ state: EdgeConnectionState) {
        edgeState = state
        edgeDiagnostic = edgeInterpreter.diagnostic
        suggestsHTTP2Protocol = edgeInterpreter.suggestsHTTP2Protocol
        suggestsQUICProtocol = edgeInterpreter.suggestsQUICProtocol
    }

    private static func argumentsForceHTTP2(_ arguments: [String]) -> Bool {
        protocolValue(in: arguments) == "http2"
    }

    private static func protocolValue(in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: "--protocol") else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex].lowercased()
    }

    private static func launchDescription(for arguments: [String]) -> String {
        switch protocolValue(in: arguments) {
        case "http2":
            return "正在启动托管隧道，传输协议为 HTTP/2（TCP 7844）。"
        case "quic":
            return "正在启动托管隧道，传输协议为 QUIC（UDP 7844）。"
        default:
            return "正在启动托管隧道，传输协议为自动（先 QUIC）。"
        }
    }

    private func appendAppLog(_ message: String) {
        logs.append(LogEntry(timestamp: Date(), stream: .app, message: message))
    }

    private func launchPendingRestartIfNeeded() {
        guard let request = pendingRestart else { return }
        pendingRestart = nil
        do {
            try start(
                executableURL: request.executableURL,
                arguments: request.arguments,
                tunnelName: request.tunnelName
            )
        } catch {
            processState = .failed(exitCode: -1)
            appendAppLog(redactor.redact(error.localizedDescription))
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private final class ProcessPipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let queue: DispatchQueue

    init(fileHandle: FileHandle, label: String) {
        self.fileHandle = fileHandle
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func start(
        onLines: @escaping @Sendable ([String]) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            let descriptor = fileHandle.fileDescriptor
            var accumulator = ProcessLineAccumulator()
            var buffer = [UInt8](repeating: 0, count: 4_096)

            defer {
                let trailingLines = accumulator.finish()
                if !trailingLines.isEmpty {
                    onLines(trailingLines)
                }
                try? fileHandle.close()
                onFinished()
            }

            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }

                if bytesRead > 0 {
                    let lines = accumulator.append(Data(buffer.prefix(bytesRead)))
                    if !lines.isEmpty {
                        onLines(lines)
                    }
                } else if bytesRead == 0 {
                    return
                } else if errno != EINTR {
                    return
                }
            }
        }
    }
}

private struct ProcessLineAccumulator {
    private var bufferedData = Data()

    mutating func append(_ data: Data) -> [String] {
        append(data, flushRemainder: false)
    }

    mutating func finish() -> [String] {
        append(Data(), flushRemainder: true)
    }

    private mutating func append(_ data: Data, flushRemainder: Bool) -> [String] {
        if !data.isEmpty {
            bufferedData.append(data)
        }

        var lines: [String] = []
        while let newlineIndex = bufferedData.firstIndex(of: 0x0A) {
            var lineData = bufferedData[..<newlineIndex]
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            lines.append(String(decoding: lineData, as: UTF8.self))
            bufferedData.removeSubrange(...newlineIndex)
        }

        if flushRemainder, !bufferedData.isEmpty {
            if bufferedData.last == 0x0D {
                bufferedData.removeLast()
            }
            lines.append(String(decoding: bufferedData, as: UTF8.self))
            bufferedData.removeAll(keepingCapacity: false)
        }
        return lines
    }
}
