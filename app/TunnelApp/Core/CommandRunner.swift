import Darwin
import Foundation

protocol CommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult
}

enum CloudflaredProcessEnvironment {
    private static let blockedPrefixes = ["TUNNEL_", "CF_", "CLOUDFLARED_"]

    static func sanitized(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        environment.filter { key, _ in
            !blockedPrefixes.contains(where: { key.hasPrefix($0) })
        }
    }
}

struct CloudflaredCommandRunner: CommandRunning {
    private let timeout: TimeInterval
    private let terminationGracePeriod: TimeInterval
    private let environment: [String: String]

    init(
        timeout: TimeInterval = 30,
        terminationGracePeriod: TimeInterval = 1,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        environment = CloudflaredProcessEnvironment.sanitized(baseEnvironment)
    }

    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CloudflaredError.invalidExecutable(executableURL)
        }

        let execution = CommandExecution(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod,
            environment: environment
        )
        return try await withTaskCancellationHandler {
            try await execution.run()
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class CommandExecution: @unchecked Sendable {
    private enum StopReason {
        case none
        case cancelled
        case timedOut
    }

    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let terminationGracePeriod: TimeInterval
    private let environment: [String: String]
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var stopReason: StopReason = .none
    private var completed = false

    init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval,
        environment: [String: String]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.environment = environment
    }

    func run() async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if stopReason == .cancelled {
                completed = true
                lock.unlock()
                continuation.resume(throwing: CloudflaredError.commandCancelled)
                return
            }
            self.continuation = continuation
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).async { [self] in
                startAndWait()
            }
        }
    }

    func cancel() {
        requestStop(reason: .cancelled)
    }

    private func startAndWait() {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = FileHandle.nullDevice

        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        self.process = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            finish(.failure(CloudflaredError.processCouldNotStart(error.localizedDescription)))
            return
        }

        scheduleTimeoutIfNeeded()
        stopRunningProcessIfRequested()

        let reads = DispatchGroup()
        let outputData = LockedDataCapture()
        let errorData = LockedDataCapture()

        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData.set(standardOutput.fileHandleForReading.readDataToEndOfFile())
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.set(standardError.fileHandleForReading.readDataToEndOfFile())
            reads.leave()
        }

        process.waitUntilExit()
        reads.wait()
        let result = CommandResult(
            executableURL: executableURL,
            arguments: arguments,
            terminationStatus: process.terminationStatus,
            standardOutput: String(decoding: outputData.value, as: UTF8.self),
            standardError: String(decoding: errorData.value, as: UTF8.self)
        )
        finish(.success(result))
    }

    private func scheduleTimeoutIfNeeded() {
        guard timeout > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.requestStop(reason: .timedOut)
        }
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        timeoutWorkItem = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func requestStop(reason: StopReason) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        if stopReason == .none || reason == .cancelled {
            stopReason = reason
        }
        let ownedProcess = process
        lock.unlock()
        terminateWithFallback(ownedProcess)
    }

    private func stopRunningProcessIfRequested() {
        lock.lock()
        let shouldStop = stopReason != .none
        let ownedProcess = process
        lock.unlock()
        if shouldStop {
            terminateWithFallback(ownedProcess)
        }
    }

    private func terminateWithFallback(_ ownedProcess: Process?) {
        guard let ownedProcess, ownedProcess.isRunning else { return }
        ownedProcess.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGracePeriod) {
            if ownedProcess.isRunning {
                kill(ownedProcess.processIdentifier, SIGKILL)
            }
        }
    }

    private func finish(_ result: Result<CommandResult, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let reason = stopReason
        let continuation = continuation
        self.continuation = nil
        process = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        lock.unlock()

        switch reason {
        case .cancelled:
            continuation?.resume(throwing: CloudflaredError.commandCancelled)
        case .timedOut:
            continuation?.resume(throwing: CloudflaredError.commandTimedOut)
        case .none:
            continuation?.resume(with: result)
        }
    }
}

private final class LockedDataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

extension CommandResult {
    func requireSuccess(redactor: LogRedacting = SensitiveLogRedactor()) throws -> CommandResult {
        guard succeeded else {
            let rawMessage = standardError.isEmpty ? standardOutput : standardError
            throw CloudflaredError.commandFailed(
                status: terminationStatus,
                message: redactor.redact(rawMessage).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return self
    }
}
