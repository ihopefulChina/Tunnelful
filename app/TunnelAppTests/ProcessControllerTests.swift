import Combine
import Foundation
import XCTest
@testable import TunnelApp

@MainActor
final class ProcessControllerTests: XCTestCase {
    func testShutdownPermanentlyRejectsLaterStartsAndRestarts() throws {
        let controller = TunnelProcessController()
        var shutdownCompleted = false

        controller.shutdown {
            shutdownCompleted = true
        }

        XCTAssertTrue(shutdownCompleted)
        XCTAssertThrowsError(try controller.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            tunnelName: "late-start"
        )) { error in
            XCTAssertEqual(error as? CloudflaredError, .commandCancelled)
        }
        XCTAssertThrowsError(try controller.restart(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            tunnelName: "late-restart"
        )) { error in
            XCTAssertEqual(error as? CloudflaredError, .commandCancelled)
        }
        XCTAssertEqual(controller.processState, .stopped)
        XCTAssertNil(controller.managedTunnelName)
    }

    func testManagedTunnelIdentityFollowsStartAndRestart() throws {
        let controller = TunnelProcessController(terminationGracePeriod: 0.1)
        try controller.start(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            tunnelName: "first"
        )
        XCTAssertEqual(controller.managedTunnelName, "first")

        let restarted = expectation(description: "replacement process started")
        var observation: AnyCancellable?
        observation = controller.$managedTunnelName.dropFirst().sink { name in
            guard name == "second" else { return }
            restarted.fulfill()
            observation?.cancel()
        }
        try controller.restart(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            tunnelName: "second"
        )
        wait(for: [restarted], timeout: 2)
        XCTAssertEqual(controller.managedTunnelName, "second")

        let stopped = expectation(description: "cleanup")
        controller.shutdown { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertNil(controller.managedTunnelName)
    }

    func testUnexpectedSignalIsReportedAsFailure() throws {
        let controller = TunnelProcessController()
        try controller.start(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -SEGV $$"]
        )

        let finished = expectation(description: "crashed process observed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finished.fulfill() }
        wait(for: [finished], timeout: 1)

        guard case .failed = controller.processState else {
            return XCTFail("An unexpected signal must be reported as a failure")
        }
    }

    func testStopForceKillsOwnedProcessThatIgnoresTermination() throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-ignore-term-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        trap '' TERM
        while :; do :; done
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let controller = TunnelProcessController(terminationGracePeriod: 0.1)
        try controller.start(executableURL: scriptURL, arguments: [])
        try controller.stop()

        let stopped = expectation(description: "SIGKILL fallback completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { stopped.fulfill() }
        wait(for: [stopped], timeout: 1)

        XCTAssertEqual(controller.processState, .stopped)
    }

    func testShutdownStopsOnlyTheOwnedProcess() throws {
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/bin/sleep")
        external.arguments = ["30"]
        try external.run()
        defer {
            if external.isRunning { external.terminate() }
            external.waitUntilExit()
        }

        let controller = TunnelProcessController()
        try controller.start(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )
        guard case .running = controller.processState else {
            return XCTFail("Expected the owned process to be running")
        }

        let stopped = expectation(description: "Owned process stopped")
        controller.shutdown { stopped.fulfill() }
        wait(for: [stopped], timeout: 6)

        XCTAssertEqual(controller.processState, .stopped)
        XCTAssertTrue(external.isRunning, "An unrelated process must never be terminated")
    }

    func testSecondStartIsRejected() throws {
        let controller = TunnelProcessController()
        try controller.start(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )
        defer {
            let stopped = expectation(description: "cleanup")
            controller.shutdown { stopped.fulfill() }
            wait(for: [stopped], timeout: 6)
        }

        XCTAssertThrowsError(try controller.start(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )) { error in
            XCTAssertEqual(error as? CloudflaredError, .processAlreadyRunning)
        }
    }

    func testExecutableThatCannotBeLaunchedFailsWithoutStartingReaders() throws {
        let executableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-invalid-executable-\(UUID().uuidString)")
        try Data("not a valid executable".utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executableURL.path
        )
        defer { try? FileManager.default.removeItem(at: executableURL) }

        let controller = TunnelProcessController()
        XCTAssertThrowsError(try controller.start(executableURL: executableURL, arguments: [])) { error in
            guard case .processCouldNotStart = error as? CloudflaredError else {
                return XCTFail("Expected the launch failure to be reported")
            }
        }
        XCTAssertEqual(controller.processState, .failed(exitCode: -1))
        XCTAssertEqual(controller.edgeState, .unknown)
        XCTAssertNil(controller.managedTunnelName)
    }

    func testLogsAreBufferedByLineAndRedactedBeforeProcessExit() throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-split-log-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        printf '%s' 'Authorization: Bearer sample'
        sleep 0.05
        printf '%s\n' '-token'
        printf '%s' 'registered tunnel '
        sleep 0.05
        printf '%s\n' 'connection'
        sleep 3 &
        sleeper=$!
        trap 'kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0' TERM INT
        wait "$sleeper"
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let controller = TunnelProcessController()
        let startedAt = Date()
        try controller.start(executableURL: scriptURL, arguments: [])
        defer {
            if case .running = controller.processState {
                let stopped = expectation(description: "cleanup")
                controller.shutdown { stopped.fulfill() }
                wait(for: [stopped], timeout: 6)
            }
        }

        let emittedCompleteLines = expectation(description: "complete lines emitted")
        var edgeObservation: AnyCancellable?
        edgeObservation = controller.$edgeState.sink { state in
            guard state == .connected else { return }
            emittedCompleteLines.fulfill()
            edgeObservation?.cancel()
        }
        wait(for: [emittedCompleteLines], timeout: 1)

        guard case .running = controller.processState else {
            return XCTFail("Complete lines must be delivered before the process exits")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1,
            "Complete lines must be delivered well before the process's three-second exit"
        )
        let visibleLogs = controller.logs.map(\.message).joined(separator: "\n")
        XCTAssertFalse(visibleLogs.contains("sample-token"))
        XCTAssertTrue(visibleLogs.contains("Authorization: <已隐藏>"))
    }

    func testTrailingLogTextWithoutNewlineIsFlushedAtExit() throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-trailing-log-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        printf '%s' 'stdout-without-newline'
        printf '%s' 'stderr-without-newline' >&2
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let controller = TunnelProcessController()
        try controller.start(executableURL: scriptURL, arguments: [])

        let finished = expectation(description: "trailing text flushed")
        var processObservation: AnyCancellable?
        processObservation = controller.$processState.sink { state in
            guard state == .stopped else { return }
            finished.fulfill()
            processObservation?.cancel()
        }
        // This verifies drain ordering, not a 1.5-second process-launch SLA.
        // Foundation and GCD delivery can be delayed by concurrent release builds.
        wait(for: [finished], timeout: 5)

        XCTAssertTrue(controller.logs.contains {
            $0.stream == .standardOutput && $0.message == "stdout-without-newline"
        })
        XCTAssertTrue(controller.logs.contains {
            $0.stream == .standardError && $0.message == "stderr-without-newline"
        })
    }

    func testStartLogMentionsForcedHTTP2Protocol() throws {
        let controller = TunnelProcessController()
        try controller.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["--protocol", "http2"]
        )
        XCTAssertTrue(controller.logs.contains {
            $0.stream == .app && $0.message.contains("HTTP/2（TCP 7844）")
        })
        let stopped = expectation(description: "cleanup")
        controller.shutdown { stopped.fulfill() }
        wait(for: [stopped], timeout: 6)
    }
}
