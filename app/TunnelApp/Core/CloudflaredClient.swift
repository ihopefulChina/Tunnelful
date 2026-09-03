import Foundation

struct CloudflaredClient: Sendable {
    let installation: CloudflaredInstallation
    private let runner: any CommandRunning
    private let listParser: TunnelListParser

    init(
        installation: CloudflaredInstallation,
        runner: any CommandRunning = CloudflaredCommandRunner(),
        listParser: TunnelListParser = TunnelListParser()
    ) {
        self.installation = installation
        self.runner = runner
        self.listParser = listParser
    }

    func listTunnels() async throws -> [CloudflaredTunnel] {
        let result = try await runner.run(
            executableURL: installation.executableURL,
            arguments: ["tunnel", "list", "--output", "json"]
        )
        let output = try result.requireSuccess().standardOutput
        return try listParser.parse(output)
    }

    func validate(configURL: URL) async throws -> String {
        let result = try await runner.run(
            executableURL: installation.executableURL,
            arguments: ["tunnel", "--config", configURL.path, "ingress", "validate"]
        )
        let successful = try result.requireSuccess()
        let output = successful.standardOutput.isEmpty ? successful.standardError : successful.standardOutput
        return SensitiveLogRedactor().redact(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matchingRule(configURL: URL, url: URL) async throws -> String {
        let result = try await runner.run(
            executableURL: installation.executableURL,
            arguments: ["tunnel", "--config", configURL.path, "ingress", "rule", url.absoluteString]
        )
        let successful = try result.requireSuccess()
        let output = successful.standardOutput.isEmpty ? successful.standardError : successful.standardOutput
        return SensitiveLogRedactor().redact(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dnsRoutePlan(tunnelName: String, hostname: String) -> DNSRoutePlan {
        DNSRoutePlan(tunnelName: tunnelName, hostname: hostname)
    }

    func routeDNS(_ plan: DNSRoutePlan) async throws -> String {
        let result = try await runner.run(
            executableURL: installation.executableURL,
            arguments: plan.arguments
        )
        let successful = try result.requireSuccess()
        let output = successful.standardOutput.isEmpty ? successful.standardError : successful.standardOutput
        return SensitiveLogRedactor().redact(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runArguments(tunnel: String, configURL: URL?) -> [String] {
        var arguments = ["tunnel"]
        if let configURL {
            arguments += ["--config", configURL.path]
        }
        arguments += ["run", tunnel]
        return arguments
    }
}
