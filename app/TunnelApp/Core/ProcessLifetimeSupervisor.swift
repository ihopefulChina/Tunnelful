import Darwin
import Foundation

struct SupervisedProcessLaunch: Equatable, Sendable {
    var parentPID: pid_t
    var executablePath: String
    var arguments: [String]
}

enum ProcessLifetimeSupervisor {
    static let marker = "--tunnelful-supervise-child"
    private static let parentFlag = "--parent-pid"
    private static let terminationGracePeriod: TimeInterval = 5

    static var canSuperviseCurrentApp: Bool {
        Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier
            && Bundle.main.executableURL != nil
    }

    static func takeOverIfRequested() {
        let arguments = CommandLine.arguments
        guard let markerIndex = arguments.firstIndex(of: marker) else { return }
        let payload = Array(arguments[(markerIndex + 1)...])
        guard let launch = parseArguments(payload, fallbackParentPID: getppid()) else {
            FileHandle.standardError.write(Data("Tunnelful 看门狗参数无效。\n".utf8))
            exit(2)
        }
        exit(supervise(launch))
    }

    static func wrapIfNeeded(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) -> (executableURL: URL, arguments: [String], environment: [String: String]) {
        guard canSuperviseCurrentApp, let supervisor = Bundle.main.executableURL else {
            return (executableURL, arguments, environment)
        }
        let wrapped = [
            marker,
            parentFlag, String(getpid()),
            "--",
            executableURL.path
        ] + arguments
        return (supervisor, wrapped, environment)
    }

    static func parseArguments(
        _ arguments: [String],
        fallbackParentPID: pid_t
    ) -> SupervisedProcessLaunch? {
        var parentPID = fallbackParentPID
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let item = arguments[index]
            if item == parentFlag {
                let valueIndex = arguments.index(after: index)
                guard valueIndex < arguments.endIndex, let parsed = pid_t(arguments[valueIndex]) else {
                    return nil
                }
                parentPID = parsed
                index = arguments.index(after: valueIndex)
                continue
            }
            if item == "--" {
                index = arguments.index(after: index)
                break
            }
            break
        }
        guard index < arguments.endIndex else { return nil }
        let executablePath = arguments[index]
        guard !executablePath.isEmpty else { return nil }
        let childArguments = Array(arguments[arguments.index(after: index)...])
        return SupervisedProcessLaunch(
            parentPID: parentPID,
            executablePath: executablePath,
            arguments: childArguments
        )
    }

    /// Ends the watchdog and the process group it leads.
    ///
    /// When this binary is supervising a child, the watchdog calls `setsid()` so
    /// its PID is the process-group ID. Killing the group reaps `cloudflared`
    /// even if the watchdog itself is SIGKILL'd. Tests that do not wrap keep
    /// the launched process in the test runner's group; those paths only signal
    /// the given PID.
    static func killSupervisedProcessTree(_ pid: pid_t) {
        if canSuperviseCurrentApp {
            _ = kill(-pid, SIGKILL)
        }
        _ = kill(pid, SIGKILL)
    }

    private static func supervise(_ launch: SupervisedProcessLaunch) -> Int32 {
        detachFromParentProcessGroup()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: launch.executablePath)
        child.arguments = launch.arguments
        child.environment = CloudflaredProcessEnvironment.sanitized()
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError

        do {
            try child.run()
        } catch {
            FileHandle.standardError.write(
                Data("Tunnelful 看门狗无法启动子进程：\(error.localizedDescription)\n".utf8)
            )
            return 1
        }

        let childPID = child.processIdentifier
        let stopLock = NSLock()
        var didRequestStop = false
        let requestStop: (Bool) -> Void = { escalate in
            stopLock.lock()
            defer { stopLock.unlock() }
            guard child.isRunning else { return }
            if escalate {
                kill(childPID, SIGKILL)
                return
            }
            guard !didRequestStop else { return }
            didRequestStop = true
            child.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGracePeriod) {
                if child.isRunning {
                    kill(childPID, SIGKILL)
                }
            }
        }

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signalQueue = DispatchQueue(label: "\(AppIdentity.bundleIdentifier).watchdog.signals")
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        termSource.setEventHandler { requestStop(false) }
        termSource.resume()
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        intSource.setEventHandler { requestStop(false) }
        intSource.resume()

        var parentSource: DispatchSourceProcess?
        if launch.parentPID > 0, kill(launch.parentPID, 0) != 0 {
            requestStop(false)
        } else if launch.parentPID > 0 {
            let source = DispatchSource.makeProcessSource(
                identifier: launch.parentPID,
                eventMask: .exit,
                queue: signalQueue
            )
            source.setEventHandler { requestStop(false) }
            source.resume()
            parentSource = source
        }

        child.waitUntilExit()
        parentSource?.cancel()
        termSource.cancel()
        intSource.cancel()
        return child.terminationStatus
    }

    private static func detachFromParentProcessGroup() {
        // Leave the GUI process group before spawning cloudflared. Force Quit of
        // the app group must not kill the watchdog before kqueue can run.
        // The child inherits this session/group; do not setpgid after exec.
        if setsid() != -1 {
            return
        }
        _ = setpgid(0, 0)
    }
}
