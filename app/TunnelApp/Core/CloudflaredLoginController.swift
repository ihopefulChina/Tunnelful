import Combine
import Foundation

@MainActor
final class CloudflaredLoginController: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case succeeded
        case cancelled
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var progressMessage: String?

    private let inspector: EnvironmentInspector
    private let redactor: any LogRedacting
    private let timeout: TimeInterval
    private let terminationGracePeriod: TimeInterval
    private var process: Process?
    private var cancellationRequested = false
    private var timedOut = false
    private var shutdownCompletion: (() -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var killWorkItem: DispatchWorkItem?

    var isRunning: Bool { process != nil }

    init(
        inspector: EnvironmentInspector = EnvironmentInspector(),
        redactor: any LogRedacting = SensitiveLogRedactor.shared,
        timeout: TimeInterval = 600,
        terminationGracePeriod: TimeInterval = 5
    ) {
        self.inspector = inspector
        self.redactor = redactor
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
    }

    func start(executableURL: URL, completion: @escaping @MainActor @Sendable () -> Void) {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            state = .failed("所选 cloudflared 不可执行。")
            return
        }
        guard !inspector.hasUsableCertificate() else {
            state = .failed("已发现 cert.pem。为避免覆盖账户凭据，请先使用“验证账户”。")
            return
        }
        do {
            _ = try inspector.backupInvalidUserCertificateIfNeeded()
        } catch {
            state = .failed("无法备份无效的 cert.pem：\(error.localizedDescription)")
            return
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputCapture = LockedDataCapture()
        let errorCapture = LockedDataCapture()
        let drainGroup = DispatchGroup()
        let launch = ProcessLifetimeSupervisor.wrapIfNeeded(
            executableURL: executableURL,
            arguments: ["tunnel", "login"],
            environment: CloudflaredProcessEnvironment.sanitized()
        )

        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        process.terminationHandler = { [weak self] finishedProcess in
            let terminationStatus = finishedProcess.terminationStatus
            drainGroup.notify(queue: .main) {
                Task { @MainActor [weak self] in
                    self?.finishLogin(
                        ownedProcess: finishedProcess,
                        terminationStatus: terminationStatus,
                        stdout: outputCapture.value,
                        stderr: errorCapture.value,
                        completion: completion
                    )
                }
            }
        }

        do {
            cancellationRequested = false
            timedOut = false
            progressMessage = nil
            drainGroup.enter()
            drainGroup.enter()
            try process.run()
            if let statusURL = launch.statusURL {
                defer { try? FileManager.default.removeItem(at: statusURL) }
                if case let .failed(message) = ProcessLifetimeSupervisor.waitForChildStatus(at: statusURL) {
                    process.terminationHandler = nil
                    if process.isRunning {
                        ProcessLifetimeSupervisor.killSupervisedProcessTree(process.processIdentifier)
                    }
                    throw CloudflaredError.processCouldNotStart(message)
                }
            }
            self.process = process
            state = .running
            scheduleTimeout()
            startReading(
                standardOutput.fileHandleForReading,
                into: outputCapture,
                drainGroup: drainGroup,
                label: "\(AppIdentity.bundleIdentifier).login.stdout"
            )
            startReading(
                standardError.fileHandleForReading,
                into: errorCapture,
                drainGroup: drainGroup,
                label: "\(AppIdentity.bundleIdentifier).login.stderr"
            )
        } catch {
            process.terminationHandler = nil
            drainGroup.leave()
            drainGroup.leave()
            try? standardOutput.fileHandleForReading.close()
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForReading.close()
            try? standardError.fileHandleForWriting.close()
            self.process = nil
            state = .failed("无法启动官方登录：\(error.localizedDescription)")
        }
    }

    func cancel() {
        guard let process else { return }
        cancellationRequested = true
        terminateWithFallback(process)
    }

    func shutdown(completion: @escaping () -> Void) {
        guard let process else {
            completion()
            return
        }
        cancellationRequested = true
        shutdownCompletion = completion
        terminateWithFallback(process)
    }

    func reset() {
        guard process == nil else { return }
        state = .idle
        progressMessage = nil
    }

    private func startReading(
        _ handle: FileHandle,
        into capture: LockedDataCapture,
        drainGroup: DispatchGroup,
        label: String
    ) {
        let reader = ProcessPipeReader(fileHandle: handle, label: label)
        reader.start { [weak self] chunk in
            capture.append(chunk)
            let snippet = CloudflaredLoginController.firstHTTPURL(
                in: String(decoding: capture.value, as: UTF8.self)
            )
            guard let snippet else { return }
            Task { @MainActor [weak self] in
                guard let self, self.process != nil else { return }
                if self.progressMessage == nil {
                    self.progressMessage = snippet
                }
            }
        } onFinished: {
            drainGroup.leave()
        }
    }

    private func finishLogin(
        ownedProcess: Process,
        terminationStatus: Int32,
        stdout: Data,
        stderr: Data,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard process === ownedProcess else { return }
        let wasCancelled = cancellationRequested
        let didTimeOut = timedOut
        process = nil
        cancellationRequested = false
        timedOut = false
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        killWorkItem?.cancel()
        killWorkItem = nil

        let captured = Self.combinedOutput(stdout: stdout, stderr: stderr)
        let redacted = redactor.redact(captured).trimmingCharacters(in: .whitespacesAndNewlines)
        let loginURL = Self.firstHTTPURL(in: redacted)

        if didTimeOut {
            var message = "官方登录等待超时。请检查浏览器后重试。"
            if let loginURL {
                message += " 可打开：\(loginURL)"
            }
            state = .failed(message)
            progressMessage = loginURL
        } else if wasCancelled {
            state = .cancelled
            progressMessage = nil
        } else if terminationStatus == 0, inspector.hasUsableCertificate() {
            state = .succeeded
            progressMessage = nil
            completion()
        } else if terminationStatus == 0 {
            state = .failed("浏览器登录尚未完成，未发现有效的 cert.pem。")
            progressMessage = loginURL
        } else {
            var message = "官方登录未完成（退出状态 \(terminationStatus)）。请检查浏览器与网络后重试。"
            if let loginURL {
                message += " 可打开：\(loginURL)"
            }
            state = .failed(message)
            progressMessage = loginURL
        }
        if let shutdownCompletion {
            self.shutdownCompletion = nil
            shutdownCompletion()
        }
    }

    private func scheduleTimeout() {
        timeoutWorkItem?.cancel()
        guard timeout > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.process != nil else { return }
                self.timedOut = true
                self.cancellationRequested = true
                if let process = self.process {
                    self.terminateWithFallback(process)
                }
            }
        }
        timeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func terminateWithFallback(_ ownedProcess: Process) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        killWorkItem?.cancel()
        ownedProcess.terminate()
        let item = DispatchWorkItem { [weak self, weak ownedProcess] in
            guard let self,
                  let ownedProcess,
                  self.process === ownedProcess,
                  ownedProcess.isRunning else { return }
            ProcessLifetimeSupervisor.killSupervisedProcessTree(ownedProcess.processIdentifier)
        }
        killWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + terminationGracePeriod, execute: item)
    }

    nonisolated static func firstHTTPURL(in text: String) -> String? {
        let pattern = #"https?://[^\s"']+"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);"))
    }

    private static func combinedOutput(stdout: Data, stderr: Data) -> String {
        [stdout, stderr]
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
