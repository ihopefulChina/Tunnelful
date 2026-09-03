import Combine
import Darwin
import Foundation

@MainActor
final class TunnelProcessController: ObservableObject {
    @Published private(set) var processState: ManagedProcessState = .stopped
    @Published private(set) var edgeState: EdgeConnectionState = .unknown
    @Published private(set) var logs: [LogEntry] = []

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
            updateEdgeState(from: message)
        }
        if logs.count > 2_000 {
            logs.removeFirst(logs.count - 2_000)
        }
    }

    private func updateEdgeState(from line: String) {
        let normalized = line.lowercased()
        if normalized.contains("registered tunnel connection") ||
            normalized.contains("connection registered") {
            edgeState = .connected
        } else if normalized.contains("failed to serve tunnel connection") ||
                    normalized.contains("connection error") ||
                    normalized.contains("unable to establish") {
            edgeState = .degraded
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
