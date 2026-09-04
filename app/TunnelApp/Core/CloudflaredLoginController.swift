import Combine
import Darwin
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

    private let inspector: EnvironmentInspector
    private var process: Process?
    private var cancellationRequested = false
    private var shutdownCompletion: (() -> Void)?

    var isRunning: Bool { process != nil }

    init(inspector: EnvironmentInspector = EnvironmentInspector()) {
        self.inspector = inspector
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

        process.executableURL = executableURL
        process.arguments = ["tunnel", "login"]
        process.environment = CloudflaredProcessEnvironment.sanitized()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] finishedProcess in
            let terminationStatus = finishedProcess.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasCancelled = self.cancellationRequested
                self.process = nil
                self.cancellationRequested = false

                if wasCancelled {
                    self.state = .cancelled
                } else if terminationStatus == 0, self.inspector.hasUsableCertificate() {
                    self.state = .succeeded
                    completion()
                } else if terminationStatus == 0 {
                    self.state = .failed("浏览器登录尚未完成，未发现有效的 cert.pem。")
                } else {
                    self.state = .failed(
                        "官方登录未完成（退出状态 \(terminationStatus)）。" +
                        "请检查浏览器与网络后重试。"
                    )
                }
                if let completion = self.shutdownCompletion {
                    self.shutdownCompletion = nil
                    completion()
                }
            }
        }

        do {
            cancellationRequested = false
            self.process = process
            state = .running
            try process.run()
        } catch {
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
    }

    private func terminateWithFallback(_ ownedProcess: Process) {
        ownedProcess.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak ownedProcess] in
            guard let self,
                  let ownedProcess,
                  self.process === ownedProcess,
                  ownedProcess.isRunning else { return }
            kill(ownedProcess.processIdentifier, SIGKILL)
        }
    }
}
