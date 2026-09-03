import Foundation

struct CloudflaredExecutableDetector: Sendable {
    private let runner: any CommandRunning
    private let environment: [String: String]
    private let standardPaths: [String]

    init(
        runner: any CommandRunning = CloudflaredCommandRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardPaths: [String] = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared"
        ]
    ) {
        self.runner = runner
        self.environment = environment
        self.standardPaths = standardPaths
    }

    func detect(
        preferredURL: URL? = nil,
        allowFallback: Bool = true
    ) async throws -> CloudflaredInstallation {
        let candidates: [URL]
        if let preferredURL, !allowFallback {
            candidates = [preferredURL.standardizedFileURL]
        } else {
            candidates = candidateURLs(preferredURL: preferredURL)
        }
        var didTimeOut = false
        for executableURL in candidates where FileManager.default.isExecutableFile(atPath: executableURL.path) {
            try Task.checkCancellation()
            do {
                let result = try await runner.run(executableURL: executableURL, arguments: ["--version"])
                let successful = try result.requireSuccess()
                let output = [successful.standardOutput, successful.standardError]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let version = Self.parseVersion(output)
                guard !version.isEmpty else { continue }

                return CloudflaredInstallation(
                    executableURL: executableURL,
                    version: version,
                    source: Self.source(for: executableURL)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CloudflaredError where error == .commandCancelled {
                throw error
            } catch let error as CloudflaredError where error == .commandTimedOut {
                didTimeOut = true
                continue
            } catch {
                // Keep looking: an earlier PATH entry may be stale or may not be cloudflared.
                continue
            }
        }
        if didTimeOut {
            throw CloudflaredError.commandTimedOut
        }
        throw CloudflaredError.executableNotFound
    }

    func candidateURLs(preferredURL: URL?) -> [URL] {
        var paths: [String] = []
        if let preferredURL { paths.append(preferredURL.path) }
        paths.append(contentsOf: standardPaths)
        if let path = environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("cloudflared").path
            })
        }

        var seen = Set<String>()
        return paths.compactMap { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    static func parseVersion(_ output: String) -> String {
        let pattern = #"(?:cloudflared\s+version\s+)?([0-9]{4}\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range(at: 1), in: output) else {
            return ""
        }
        return String(output[range])
    }

    static func source(for url: URL) -> CloudflaredInstallation.Source {
        let originalPath = url.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        if originalPath.hasPrefix("/opt/homebrew/") ||
            resolvedPath.hasPrefix("/opt/homebrew/") ||
            resolvedPath.contains("/Cellar/") {
            return .homebrew
        }
        if originalPath == "/usr/local/bin/cloudflared", resolvedPath == originalPath {
            return .officialPackage
        }
        return .custom
    }
}
