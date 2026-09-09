import Foundation

struct OriginHealthResult: Equatable, Sendable {
    let state: OriginReachabilityState
    let latency: TimeInterval
}

final class OriginHealthSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = OriginHealthSession()

    private var session: URLSession!

    private override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        configuration.httpShouldSetCookies = false
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

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

        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            let code = (response as? HTTPURLResponse)?.statusCode
            let latency = Date().timeIntervalSince(startedAt)
            if let code, (500...599).contains(code) {
                return OriginHealthResult(
                    state: .unreachable("源站返回 HTTP \(code)。"),
                    latency: latency
                )
            }
            return OriginHealthResult(
                state: .reachable(statusCode: code),
                latency: latency
            )
        } catch {
            return OriginHealthResult(
                state: .unreachable(Self.failureMessage(for: error)),
                latency: Date().timeIntervalSince(startedAt)
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func failureMessage(for error: Error) -> String {
        let redacted = SensitiveLogRedactor.shared.redact(error.localizedDescription)
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return "源站证书不被系统信任。若这是本机自签证书，cloudflared 仍可能转发；预检使用系统信任存储。"
            case .httpTooManyRedirects:
                return "源站预检重定向次数过多。"
            default:
                break
            }
        }
        return redacted
    }
}

struct OriginHealthChecker: Sendable {
    func check(_ url: URL) async -> OriginHealthResult {
        await OriginHealthSession.shared.check(url)
    }
}
