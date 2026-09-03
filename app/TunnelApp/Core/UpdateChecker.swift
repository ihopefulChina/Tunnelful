import Combine
import Foundation

struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    private enum PrereleaseIdentifier: Equatable, Sendable {
        case numeric(String)
        case alphanumeric(String)
    }

    private let core: [String]
    private let prerelease: [PrereleaseIdentifier]?
    private let prereleaseText: String?
    private let buildMetadata: String?

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }

        let buildParts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        let versionAndPrerelease = String(buildParts[0])
        let parsedBuildMetadata = buildParts.count == 2 ? String(buildParts[1]) : nil
        if let parsedBuildMetadata,
           !Self.validDotSeparatedIdentifiers(parsedBuildMetadata, numericLeadingZeroAllowed: true) {
            return nil
        }

        let prereleaseParts = versionAndPrerelease.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !prereleaseParts[0].isEmpty else { return nil }
        let parsedPrereleaseText = prereleaseParts.count == 2 ? String(prereleaseParts[1]) : nil
        if let parsedPrereleaseText,
           !Self.validDotSeparatedIdentifiers(parsedPrereleaseText, numericLeadingZeroAllowed: false) {
            return nil
        }

        let coreParts = prereleaseParts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard coreParts.count == 3,
              coreParts.allSatisfy(Self.validCoreNumber) else {
            return nil
        }

        core = coreParts
        prereleaseText = parsedPrereleaseText
        prerelease = parsedPrereleaseText.map { text in
            text.split(separator: ".").map { part in
                let identifier = String(part)
                return identifier.allSatisfy(Self.isASCIIDigit)
                    ? .numeric(identifier)
                    : .alphanumeric(identifier)
            }
        }
        buildMetadata = parsedBuildMetadata
    }

    var isPrerelease: Bool { prerelease != nil }

    var description: String {
        var value = core.joined(separator: ".")
        if let prereleaseText {
            value += "-\(prereleaseText)"
        }
        if let buildMetadata {
            value += "+\(buildMetadata)"
        }
        return value
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        compareCore(lhs.core, rhs.core) == .orderedSame
            && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let coreComparison = compareCore(lhs.core, rhs.core)
        if coreComparison != .orderedSame {
            return coreComparison == .orderedAscending
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(lhsIdentifiers), .some(rhsIdentifiers)):
            for index in 0..<min(lhsIdentifiers.count, rhsIdentifiers.count) {
                let comparison = compare(lhsIdentifiers[index], rhsIdentifiers[index])
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            }
            return lhsIdentifiers.count < rhsIdentifiers.count
        }
    }

    private static func validCoreNumber(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy(Self.isASCIIDigit)
            && (value == "0" || value.first != "0")
    }

    private static func validDotSeparatedIdentifiers(
        _ value: String,
        numericLeadingZeroAllowed: Bool
    ) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.unicodeScalars.allSatisfy({ scalar in
                      (48...57).contains(scalar.value)
                          || (65...90).contains(scalar.value)
                          || (97...122).contains(scalar.value)
                          || scalar.value == 45
                  }) else {
                return false
            }
            return numericLeadingZeroAllowed
                || !identifier.allSatisfy(Self.isASCIIDigit)
                || identifier == "0"
                || identifier.first != "0"
        }
    }

    private static func compareCore(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for index in 0..<3 {
            let result = compareNumericStrings(lhs[index], rhs[index])
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }

    private static func compare(_ lhs: PrereleaseIdentifier, _ rhs: PrereleaseIdentifier) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.numeric(lhsValue), .numeric(rhsValue)):
            return compareNumericStrings(lhsValue, rhsValue)
        case (.numeric, .alphanumeric):
            return .orderedAscending
        case (.alphanumeric, .numeric):
            return .orderedDescending
        case let (.alphanumeric(lhsValue), .alphanumeric(rhsValue)):
            if lhsValue == rhsValue { return .orderedSame }
            return lhsValue < rhsValue ? .orderedAscending : .orderedDescending
        }
    }

    private static func compareNumericStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1
            && character.unicodeScalars.first.map { (48...57).contains($0.value) } == true
    }
}

struct AppRelease: Equatable, Sendable {
    let version: SemanticVersion
    let tagName: String
    let downloadPageURL: URL
    let isPrerelease: Bool
}

enum UpdateCheckError: LocalizedError, Equatable {
    case invalidCurrentVersion
    case networkUnavailable
    case rateLimited
    case server(Int)
    case invalidResponse
    case noRelease

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion:
            return "当前应用版本无法识别，请从官方发布页重新下载。"
        case .networkUnavailable:
            return "无法连接 GitHub，请检查网络后重试。"
        case .rateLimited:
            return "GitHub 暂时拒绝了检查请求，请稍后再试。"
        case let .server(statusCode):
            return "GitHub 返回了异常状态（\(statusCode)），请稍后再试。"
        case .invalidResponse:
            return "GitHub 返回的数据无法识别，请稍后再试。"
        case .noRelease:
            return "官方仓库暂时没有可用的发布版本。"
        }
    }
}

struct UpdateHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol UpdateHTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> UpdateHTTPResponse
}

struct URLSessionUpdateTransport: UpdateHTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func response(for request: URLRequest) async throws -> UpdateHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        return UpdateHTTPResponse(data: data, statusCode: httpResponse.statusCode)
    }
}

protocol UpdateReleaseFetching: Sendable {
    func latestRelease() async throws -> AppRelease
}

struct GitHubUpdateService: UpdateReleaseFetching {
    static let repositoryURL = URL(string: "https://github.com/ihopefulChina/Tunnelful")!
    static let releasesAPIURL = URL(string: "https://api.github.com/repos/ihopefulChina/Tunnelful/releases?per_page=20")!

    private struct ReleaseDTO: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease
        }
    }

    private let transport: any UpdateHTTPTransport
    private let userAgentVersion: String
    private let includePrereleases: Bool

    init(
        transport: any UpdateHTTPTransport = URLSessionUpdateTransport(),
        userAgentVersion: String = "unknown",
        includePrereleases: Bool = false
    ) {
        self.transport = transport
        self.userAgentVersion = userAgentVersion
        self.includePrereleases = includePrereleases
    }

    func latestRelease() async throws -> AppRelease {
        var request = URLRequest(url: Self.releasesAPIURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tunnelful/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")

        let response: UpdateHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch let error as UpdateCheckError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff:
                throw UpdateCheckError.networkUnavailable
            default:
                throw UpdateCheckError.networkUnavailable
            }
        } catch {
            throw UpdateCheckError.networkUnavailable
        }

        switch response.statusCode {
        case 200..<300:
            break
        case 403, 429:
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.server(response.statusCode)
        }

        let releases: [ReleaseDTO]
        do {
            releases = try JSONDecoder().decode([ReleaseDTO].self, from: response.data)
        } catch {
            throw UpdateCheckError.invalidResponse
        }

        let candidates = releases.compactMap { release -> AppRelease? in
            guard !release.draft,
                  let version = SemanticVersion(release.tagName),
                  includePrereleases || (!release.prerelease && !version.isPrerelease) else {
                return nil
            }
            let releaseURL = Self.repositoryURL
                .appendingPathComponent("releases", isDirectory: true)
                .appendingPathComponent("tag", isDirectory: true)
                .appendingPathComponent(release.tagName, isDirectory: false)
            return AppRelease(
                version: version,
                tagName: release.tagName,
                downloadPageURL: releaseURL,
                isPrerelease: release.prerelease || version.isPrerelease
            )
        }

        guard let latest = candidates.max(by: { $0.version < $1.version }) else {
            throw UpdateCheckError.noRelease
        }
        return latest
    }
}

enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate(AppRelease)
    case updateAvailable(AppRelease)
    case failed(UpdateCheckError)

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var state: UpdateCheckState = .idle

    let currentVersion: String
    private let releaseFetcher: any UpdateReleaseFetching

    init(
        currentVersion: String,
        releaseFetcher: (any UpdateReleaseFetching)? = nil
    ) {
        self.currentVersion = currentVersion
        self.releaseFetcher = releaseFetcher
            ?? GitHubUpdateService(
                userAgentVersion: currentVersion,
                includePrereleases: SemanticVersion(currentVersion)?.isPrerelease == true
            )
    }

    func checkIfNeeded() async {
        guard case .idle = state else { return }
        await check()
    }

    func check() async {
        guard !state.isChecking else { return }
        guard let currentVersion = SemanticVersion(currentVersion) else {
            state = .failed(.invalidCurrentVersion)
            return
        }

        state = .checking
        do {
            let latestRelease = try await releaseFetcher.latestRelease()
            guard !Task.isCancelled else {
                state = .idle
                return
            }
            state = currentVersion < latestRelease.version
                ? .updateAvailable(latestRelease)
                : .upToDate(latestRelease)
        } catch is CancellationError {
            state = .idle
        } catch let error as UpdateCheckError {
            state = .failed(error)
        } catch {
            state = .failed(.networkUnavailable)
        }
    }
}
