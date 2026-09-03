import Foundation
import XCTest
@testable import TunnelApp

final class CommandAndParserTests: XCTestCase {
    @MainActor
    func testAppearanceDefaultsToSystemAndPersistsSelection() {
        let suiteName = "app.tunnelful.mac.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建隔离的 UserDefaults。")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstModel = AppModel(
            processController: TunnelProcessController(),
            userDefaults: defaults
        )
        XCTAssertEqual(firstModel.appearance, .system)
        XCTAssertNil(firstModel.appearance.colorScheme)

        firstModel.appearance = .dark
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)

        firstModel.appearance = .system
        XCTAssertNil(NSApplication.shared.appearance)

        firstModel.appearance = .dark

        let restoredModel = AppModel(
            processController: TunnelProcessController(),
            userDefaults: defaults
        )
        XCTAssertEqual(restoredModel.appearance, .dark)
        XCTAssertEqual(restoredModel.appearance.colorScheme, .dark)
        XCTAssertEqual(AppAppearance.allCases.map(\.title), ["跟随系统", "浅色", "深色"])
    }

    func testCommandRunnerPassesArgumentsWithoutShellExpansion() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let payload = "literal; touch \(marker.path)"

        let result = try await CloudflaredCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", payload]
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCommandRunnerDrainsLargeStandardOutputAndErrorWithoutDeadlock() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-large-output-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        i=0
        while [ "$i" -lt 7000 ]; do
          printf 'stdout-line-%05d-abcdefghijklmnopqrstuvwxyz\\n' "$i"
          printf 'stderr-line-%05d-abcdefghijklmnopqrstuvwxyz\\n' "$i" >&2
          i=$((i + 1))
        done
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let result = try await CloudflaredCommandRunner().run(executableURL: scriptURL, arguments: [])

        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThan(result.standardOutput.utf8.count, 64 * 1024)
        XCTAssertGreaterThan(result.standardError.utf8.count, 64 * 1024)
        XCTAssertTrue(result.standardOutput.contains("stdout-line-06999"))
        XCTAssertTrue(result.standardError.contains("stderr-line-06999"))
    }

    func testCommandRunnerSupportsTaskCancellation() async {
        let runner = CloudflaredCommandRunner(timeout: 10, terminationGracePeriod: 0.1)
        let started = Date()
        let task = Task {
            try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"]
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? CloudflaredError, .commandCancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testCommandRunnerTimesOutAndStopsProcess() async {
        let runner = CloudflaredCommandRunner(timeout: 0.1, terminationGracePeriod: 0.1)
        let started = Date()
        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"]
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? CloudflaredError, .commandTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testDNSRouteTimeoutRequiresRemoteVerificationBeforeRetry() {
        let message = CloudflaredError.commandTimedOut.dnsRouteErrorDescription

        XCTAssertTrue(message.contains("远端结果未知"))
        XCTAssertTrue(message.contains("可能已生效"))
        XCTAssertTrue(message.contains("核对记录"))
        XCTAssertTrue(message.contains("再决定是否重试"))
    }

    func testDetectorContinuesPastInvalidExecutableAndReadsVersionFromStandardError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-detector-\(UUID().uuidString)", isDirectory: true)
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = firstDirectory.appendingPathComponent("cloudflared")
        let second = secondDirectory.appendingPathComponent("cloudflared")
        for url in [first, second] {
            FileManager.default.createFile(atPath: url.path, contents: Data())
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path
            )
        }

        let runner = DetectorStubRunner(validExecutablePath: second.path)
        let detector = CloudflaredExecutableDetector(
            runner: runner,
            environment: ["PATH": "\(firstDirectory.path):\(secondDirectory.path)"],
            standardPaths: []
        )

        let installation = try await detector.detect()

        XCTAssertEqual(installation.executableURL.path, second.path)
        XCTAssertEqual(installation.version, "2026.9.1")
    }

    func testDetectorPropagatesCommandCancellationWithoutTryingFallbacks() async throws {
        let runner = CancellingDetectorRunner()
        let detector = CloudflaredExecutableDetector(
            runner: runner,
            environment: [:],
            standardPaths: ["/usr/bin/printf", "/bin/echo"]
        )

        do {
            _ = try await detector.detect()
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? CloudflaredError, .commandCancelled)
        }
        let callCount = await runner.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testConfigurationLocatorIncludesInjectedSystemDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-locator-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let system = root.appendingPathComponent("etc-cloudflared", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let systemConfig = system.appendingPathComponent("config.yml")
        try Data("ingress:\n  - service: http_status:404\n".utf8).write(to: systemConfig)

        let discovered = ConfigurationLocator(
            homeDirectory: home,
            systemDirectories: [system]
        ).discover()

        XCTAssertEqual(discovered, [systemConfig])
    }

    func testEnvironmentInspectorUsesOnlyCredentialMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-environment-\(UUID().uuidString)", isDirectory: true)
        let cloudflaredDirectory = root.appendingPathComponent(".cloudflared", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudflaredDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let certificate = cloudflaredDirectory.appendingPathComponent("cert.pem")
        let credentials = cloudflaredDirectory.appendingPathComponent("tunnel.json")
        try Data("certificate-super-secret".utf8).write(to: certificate)
        try Data("credential-super-secret".utf8).write(to: credentials)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: certificate.path)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: credentials.path)

        let configURL = cloudflaredDirectory.appendingPathComponent("config.yml")
        try Data("placeholder".utf8).write(to: configURL)
        let document = CloudflaredConfigDocument(
            sourceURL: configURL,
            tunnel: "sample",
            credentialsFile: "$HOME/.cloudflared/tunnel.json",
            ingress: [IngressRule(service: "http_status:404")]
        )

        let report = EnvironmentInspector(homeDirectory: root).inspect(
            installation: CloudflaredInstallation(
                executableURL: URL(fileURLWithPath: "/usr/local/bin/cloudflared"),
                version: "2026.9.1",
                source: .officialPackage
            ),
            configDocument: document,
            tunnelState: .loaded(count: 1),
            launchAtLoginState: .disabled,
            startTunnelOnLaunch: false
        )

        XCTAssertTrue(report.hasCertificate)
        XCTAssertTrue(report.hasTunnelCredentials)
        XCTAssertTrue(report.isReadyToRun)
        let allDetails = report.items.map(\.detail).joined(separator: " ")
        XCTAssertFalse(allDetails.contains("certificate-super-secret"))
        XCTAssertFalse(allDetails.contains("credential-super-secret"))
        XCTAssertFalse(allDetails.contains(root.path))
    }

    @MainActor
    func testTunnelControlsRejectOptionLikeTunnelNames() throws {
        let suiteName = "app.tunnelful.mac.tunnel-name-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let processController = TunnelProcessController()
        let model = AppModel(
            processController: processController,
            initialInstallation: CloudflaredInstallation(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                version: "test",
                source: .custom
            ),
            userDefaults: defaults
        )

        model.startTunnel(named: "  --hello-world  ")
        XCTAssertEqual(model.alertMessage, "Tunnel 名称不能以连字符开头。")
        XCTAssertEqual(processController.processState, .stopped)

        model.alertMessage = nil
        model.restartTunnel(named: "--token")
        XCTAssertEqual(model.alertMessage, "Tunnel 名称不能以连字符开头。")
        XCTAssertEqual(processController.processState, .stopped)
    }

    @MainActor
    func testLoginFailureDoesNotExposeCommandOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("cloudflared")
        let secretURL = "https://example.com/authorize?token=secret-login-token"
        let script = "#!/bin/sh\nprintf '%s\\n' '\(secretURL)' >&2\nexit 7\n"
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path
        )

        let controller = CloudflaredLoginController(
            inspector: EnvironmentInspector(homeDirectory: root)
        )
        controller.start(executableURL: executable) {}

        for _ in 0..<100 where controller.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case let .failed(message) = controller.state else {
            return XCTFail("Expected a compact login failure")
        }
        XCTAssertFalse(message.contains(secretURL))
        XCTAssertFalse(message.contains("secret-login-token"))
        XCTAssertLessThan(message.count, 120)
        XCTAssertTrue(message.contains("7"))
    }

    func testTunnelListParserAcceptsCurrentJSONShape() throws {
        let json = """
        [
          {
            "id": "sample-tunnel-id",
            "name": "dev",
            "created_at": "2026-09-03T01:02:03.123456Z",
            "deleted_at": null,
            "connections": [{"colo_name":"SJC"}, {"colo_name":"LAX"}],
            "future_field": true
          }
        ]
        """

        let tunnels = try TunnelListParser().parse(json)
        XCTAssertEqual(tunnels.count, 1)
        XCTAssertEqual(tunnels[0].name, "dev")
        XCTAssertEqual(tunnels[0].connectionCount, 2)
        XCTAssertNotNil(tunnels[0].createdAt)
    }

    @MainActor
    func testConfiguredTunnelWinsOverDevForEveryControlSurface() {
        let tunnels = [
            CloudflaredTunnel(
                id: "dev-id",
                name: "dev",
                createdAt: nil,
                deletedAt: nil,
                connectionCount: 0
            ),
            CloudflaredTunnel(
                id: "production-id",
                name: "production",
                createdAt: nil,
                deletedAt: nil,
                connectionCount: 0
            )
        ]

        XCTAssertEqual(
            AppModel.resolvePreferredTunnelName(
                configuredTunnel: "production-id",
                tunnels: tunnels
            ),
            "production"
        )
        XCTAssertEqual(
            AppModel.resolvePreferredTunnelName(
                configuredTunnel: nil,
                tunnels: tunnels
            ),
            "dev"
        )
    }

    func testVersionAndInstallSourceDetection() {
        XCTAssertEqual(
            CloudflaredExecutableDetector.parseVersion("cloudflared version 2026.8.3 (built 2026-08-31)"),
            "2026.8.3"
        )
        XCTAssertEqual(
            CloudflaredExecutableDetector.source(for: URL(fileURLWithPath: "/opt/homebrew/bin/cloudflared")),
            .homebrew
        )
    }

    func testSensitiveLogRedaction() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fakeJWT = "eyJabcdefghijkl" + ".abcdefghijkl" + ".abcdefghijkl"
        let input = "Authorization: Bearer secret-value token=abc123 \(fakeJWT) \(home)/.cloudflared/secret.json"
        let result = SensitiveLogRedactor().redact(input)

        XCTAssertFalse(result.contains("secret-value"))
        XCTAssertFalse(result.contains("abc123"))
        XCTAssertFalse(result.contains("eyJabcdefghijkl"))
        XCTAssertFalse(result.contains(home))
        XCTAssertTrue(result.contains("<已隐藏>"))
    }

    func testDNSRouteBuildsAnArgumentPlan() {
        let plan = DNSRoutePlan(tunnelName: "dev", hostname: "preview.example.com")
        XCTAssertEqual(
            plan.arguments,
            ["tunnel", "route", "dns", "--overwrite-dns=false", "dev", "preview.example.com"]
        )
        XCTAssertEqual(
            plan.displayCommand,
            "cloudflared tunnel route dns --overwrite-dns=false dev preview.example.com"
        )
    }

    func testDNSRouteExecutesTheExactArgumentArray() async throws {
        let runner = DNSRouteRecordingRunner()
        let installation = CloudflaredInstallation(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            version: "test",
            source: .custom
        )
        let plan = DNSRoutePlan(tunnelName: "demo", hostname: "preview.example.com")
        let client = CloudflaredClient(installation: installation, runner: runner)

        let output = try await client.routeDNS(plan)
        let recordedArguments = await runner.recordedArguments()

        XCTAssertEqual(output, "DNS route configured")
        XCTAssertEqual(
            recordedArguments,
            [["tunnel", "route", "dns", "--overwrite-dns=false", "demo", "preview.example.com"]]
        )
    }

    func testCloudflaredRunnerRemovesHiddenControlEnvironment() async throws {
        let runner = CloudflaredCommandRunner(baseEnvironment: [
            "HOME": "/tmp/example-home",
            "HTTPS_PROXY": "http://127.0.0.1:8080",
            "TUNNEL_FORCE_PROVISIONING_DNS": "true",
            "TUNNEL_ORIGIN_CERT": "/tmp/other-account.pem",
            "TUNNEL_TOKEN": "secret-token",
            "CF_API_TOKEN": "secret-api-token",
            "CLOUDFLARED_EXPERIMENT": "enabled"
        ])

        let result = try await runner.run(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [])
        let output = try result.requireSuccess().standardOutput

        XCTAssertTrue(output.contains("HOME=/tmp/example-home"))
        XCTAssertTrue(output.contains("HTTPS_PROXY=http://127.0.0.1:8080"))
        XCTAssertFalse(output.contains("TUNNEL_"))
        XCTAssertFalse(output.contains("CF_API_TOKEN"))
        XCTAssertFalse(output.contains("CLOUDFLARED_"))
    }

}

private struct DetectorStubRunner: CommandRunning {
    let validExecutablePath: String

    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult {
        if executableURL.path == validExecutablePath {
            return CommandResult(
                executableURL: executableURL,
                arguments: arguments,
                terminationStatus: 0,
                standardOutput: "",
                standardError: "cloudflared version 2026.9.1"
            )
        }
        return CommandResult(
            executableURL: executableURL,
            arguments: arguments,
            terminationStatus: 0,
            standardOutput: "not cloudflared",
            standardError: ""
        )
    }
}

private actor CancellingDetectorRunner: CommandRunning {
    private var calls = 0

    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult {
        calls += 1
        throw CloudflaredError.commandCancelled
    }

    func callCount() -> Int { calls }
}

private actor DNSRouteRecordingRunner: CommandRunning {
    private var arguments: [[String]] = []

    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult {
        self.arguments.append(arguments)
        return CommandResult(
            executableURL: executableURL,
            arguments: arguments,
            terminationStatus: 0,
            standardOutput: "DNS route configured",
            standardError: ""
        )
    }

    func recordedArguments() -> [[String]] { arguments }
}
