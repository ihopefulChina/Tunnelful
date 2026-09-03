import Foundation

struct OriginHealthResult: Equatable, Sendable {
    let state: OriginReachabilityState
    let latency: TimeInterval
}

struct OriginHealthChecker: Sendable {
    func check(_ url: URL) async -> OriginHealthResult {
        let startedAt = Date()
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return OriginHealthResult(
                state: .unreachable("仅支持对 HTTP 和 HTTPS 源站进行预检。"),
                latency: 0
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        let session = URLSession(configuration: configuration)

        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode
            return OriginHealthResult(
                state: .reachable(statusCode: code),
                latency: Date().timeIntervalSince(startedAt)
            )
        } catch {
            return OriginHealthResult(
                state: .unreachable(SensitiveLogRedactor().redact(error.localizedDescription)),
                latency: Date().timeIntervalSince(startedAt)
            )
        }
    }
}
