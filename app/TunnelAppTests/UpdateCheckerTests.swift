import Foundation
import XCTest
@testable import TunnelApp

final class UpdateCheckerTests: XCTestCase {
    func testSemanticVersionFollowsSemVerPrecedence() throws {
        let ordered = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0"
        ].compactMap(SemanticVersion.init)

        XCTAssertEqual(ordered.count, 8)
        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }
        XCTAssertEqual(SemanticVersion("1.0.0+build.1"), SemanticVersion("1.0.0+build.2"))
        XCTAssertLessThan(
            try XCTUnwrap(SemanticVersion("999999999999999999999.0.0")),
            try XCTUnwrap(SemanticVersion("1000000000000000000000.0.0"))
        )
    }

    func testSemanticVersionRejectsInvalidInput() {
        [
            "1", "1.0", "01.0.0", "1.00.0", "1.0.00", "1.0.0-01",
            "1.0.0-", "1.0.0+", "1.0.0-alpha..1", "1.0.0-测试"
        ].forEach { XCTAssertNil(SemanticVersion($0), $0) }
    }

    func testGitHubServiceIncludesPrereleasesIgnoresDraftsAndUsesFixedURL() async throws {
        let data = Data(
            """
            [
              {"tag_name":"v99.0.0","draft":true,"prerelease":false,"html_url":"https://example.com/evil"},
              {"tag_name":"v0.1.1","draft":false,"prerelease":false,"html_url":"https://example.com/evil"},
              {"tag_name":"v0.2.0-beta.1","draft":false,"prerelease":true,"html_url":"https://example.com/evil"}
            ]
            """.utf8
        )
        let transport = StubUpdateTransport(result: .success(UpdateHTTPResponse(data: data, statusCode: 200)))
        let service = GitHubUpdateService(
            transport: transport,
            userAgentVersion: "0.1.0-alpha.1",
            includePrereleases: true
        )

        let release = try await service.latestRelease()

        XCTAssertEqual(release.version, SemanticVersion("0.2.0-beta.1"))
        XCTAssertTrue(release.isPrerelease)
        XCTAssertEqual(
            release.downloadPageURL.absoluteString,
            "https://github.com/ihopefulChina/Tunnelful/releases/tag/v0.2.0-beta.1"
        )
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url, GitHubUpdateService.releasesAPIURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Tunnelful/0.1.0-alpha.1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testGitHubServiceKeepsStableUsersOnStableReleases() async throws {
        let data = Data(
            """
            [
              {"tag_name":"v0.1.1","draft":false,"prerelease":false},
              {"tag_name":"v0.2.0-beta.1","draft":false,"prerelease":true}
            ]
            """.utf8
        )
        let service = GitHubUpdateService(
            transport: StubUpdateTransport(
                result: .success(UpdateHTTPResponse(data: data, statusCode: 200))
            ),
            userAgentVersion: "0.1.0"
        )

        let release = try await service.latestRelease()

        XCTAssertEqual(release.version, SemanticVersion("0.1.1"))
        XCTAssertFalse(release.isPrerelease)
    }

    func testGitHubServiceHandlesRateLimitBadJSONAndOffline() async {
        await assertServiceError(
            transportResult: .success(UpdateHTTPResponse(data: Data(), statusCode: 403)),
            expected: .rateLimited
        )
        await assertServiceError(
            transportResult: .success(UpdateHTTPResponse(data: Data("not-json".utf8), statusCode: 200)),
            expected: .invalidResponse
        )
        await assertServiceError(
            transportResult: .failure(URLError(.notConnectedToInternet)),
            expected: .networkUnavailable
        )
    }

    @MainActor
    func testCheckerIgnoresDuplicateRequestAndFindsUpdate() async throws {
        let release = AppRelease(
            version: try XCTUnwrap(SemanticVersion("0.2.0")),
            tagName: "v0.2.0",
            downloadPageURL: URL(string: "https://github.com/ihopefulChina/Tunnelful/releases/tag/v0.2.0")!,
            isPrerelease: false
        )
        let fetcher = SlowReleaseFetcher(release: release)
        let checker = UpdateChecker(currentVersion: "0.1.0-alpha.1", releaseFetcher: fetcher)

        let first = Task { await checker.check() }
        await Task.yield()
        let duplicate = Task { await checker.check() }
        await first.value
        await duplicate.value

        let callCount = await fetcher.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(checker.state, .updateAvailable(release))
    }

    private func assertServiceError(
        transportResult: Result<UpdateHTTPResponse, Error>,
        expected: UpdateCheckError
    ) async {
        let service = GitHubUpdateService(transport: StubUpdateTransport(result: transportResult))
        do {
            _ = try await service.latestRelease()
            XCTFail("预期检查失败。")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("返回了非预期错误：\(error)")
        }
    }
}

private actor StubUpdateTransport: UpdateHTTPTransport {
    private let result: Result<UpdateHTTPResponse, Error>
    private var request: URLRequest?

    init(result: Result<UpdateHTTPResponse, Error>) {
        self.result = result
    }

    func response(for request: URLRequest) async throws -> UpdateHTTPResponse {
        self.request = request
        return try result.get()
    }

    func lastRequest() -> URLRequest? { request }
}

private actor SlowReleaseFetcher: UpdateReleaseFetching {
    private let release: AppRelease
    private var calls = 0

    init(release: AppRelease) {
        self.release = release
    }

    func latestRelease() async throws -> AppRelease {
        calls += 1
        try await Task.sleep(nanoseconds: 80_000_000)
        return release
    }

    func callCount() -> Int { calls }
}
