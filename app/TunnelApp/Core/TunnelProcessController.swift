import Combine
import Darwin
import Foundation

/// Interprets cloudflared logs into an Edge status.
/// cloudflared keeps several HA connections; one of them retrying is not a tunnel outage.
struct EdgeLogInterpreter: Equatable, Sendable {
    private var liveConnections: Set<Int> = []
    private var sawRegistration = false

    mutating func reset() {
        liveConnections.removeAll(keepingCapacity: true)
        sawRegistration = false
    }

    mutating func consume(_ line: String) -> EdgeConnectionState {
        let normalized = line.lowercased()
        let index = Self.connectionIndex(in: normalized)

        if Self.isRegistration(normalized) {
            liveConnections.insert(index ?? 0)
            sawRegistration = true
        } else if Self.isPerConnectionLoss(normalized) {
            if let index {
                liveConnections.remove(index)
            } else if liveConnections.count <= 1 {
                liveConnections.removeAll(keepingCapacity: true)
            }
        } else if Self.isGlobalEstablishFailure(normalized) {
            liveConnections.removeAll(keepingCapacity: true)
        }

        if !liveConnections.isEmpty {
            return .connected
        }
        if sawRegistration {
            return .degraded
        }
        return .connecting
    }

    private static func isRegistration(_ line: String) -> Bool {
        line.contains("registered tunnel connection")
            || line.contains("tunnel connection registered")
    }

    private static func isPerConnectionLoss(_ line: String) -> Bool {
        line.contains("failed to serve tunnel connection")
            || line.contains("unregistered tunnel connection")
    }

    private static func isGlobalEstablishFailure(_ line: String) -> Bool {
        line.contains("unable to establish connection with cloudflare")
            || line.contains("failed to dial a quic connection")
            || line.contains("failed to dial cloudflare edge")
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
    @Published private(set) var edgeState: EdgeConnectionState = .unknown
    @Published private(set) var logs: [LogEntry] = []
    private var edgeInterpreter = EdgeLogInterpreter()

    private struct LaunchRequest {
        let executableURL: URL
        let arguments: [String]
    }

    private let redactor: any LogRedacting
    private let terminationGracePeriod: TimeInterval
    private var process: Process?
    private var pendingRestart: LaunchRequest?
    private var shutdownCompletion: (() -> Void)?
    private var expectedTerminationPID: Int32?

    init(
        redactor: any LogRedacting = SensitiveLogRedactor(),
        terminationGracePeriod: TimeInterval = 5
    ) {
        self.redactor = redactor
        self.terminationGracePeriod = terminationGracePeriod
    }

    func start(executableURL: URL, arguments: [String]) throws {
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
            label: "app.tunnelful.mac.logs.stdout"
        )
        let errorReader = ProcessPipeReader(
            fileHandle: standardError.fileHandleForReading,
            label: "app.tunnelful.mac.logs.stderr"
        )
        newProcess.executableURL = executableURL
        newProcess.arguments = arguments
        newProcess.environment = CloudflaredProcessEnvironment.sanitized()
        newProcess.standardInput = FileHandle.nullDevice
        newProcess.standardOutput = standardOutput
        newProcess.standardError = standardError

        processState = .starting
        edgeInterpreter.reset()
        edgeState = .connecting
        appendAppLog("正在启动托管隧道。")

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
            edgeInterpreter.reset()
            edgeState = .unknown
            throw CloudflaredError.processCouldNotStart(error.localizedDescription)
        }
    }

    func stop() throws {
        guard let process else { throw CloudflaredError.noProcessRunning }
        pendingRestart = nil
        appendAppLog("正在正常停止托管隧道。")
        requestTermination(of: process)
    }

    func restart(executableURL: URL, arguments: [String]) throws {
        guard let process else {
            try start(executableURL: executableURL, arguments: arguments)
            return
        }
        pendingRestart = LaunchRequest(executableURL: executableURL, arguments: arguments)
        appendAppLog("已请求重启，正在等待当前进程停止。")
        requestTermination(of: process)
    }

    func clearLogs() {
        logs.removeAll(keepingCapacity: true)
    }

    func shutdown(completion: @escaping () -> Void) {
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
        edgeInterpreter.reset()
        edgeState = .unknown
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
            edgeState = edgeInterpreter.consume(message)
        }
        if logs.count > 2_000 {
            logs.removeFirst(logs.count - 2_000)
        }
    }

    private func appendAppLog(_ message: String) {
        logs.append(LogEntry(timestamp: Date(), stream: .app, message: message))
    }

    private func launchPendingRestartIfNeeded() {
        guard let request = pendingRestart else { return }
        pendingRestart = nil
        do {
            try start(executableURL: request.executableURL, arguments: request.arguments)
        } catch {
            processState = .failed(exitCode: -1)
            appendAppLog(redactor.redact(error.localizedDescription))
        }
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
