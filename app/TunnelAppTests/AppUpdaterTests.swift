import XCTest
@testable import TunnelApp

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testUpdateFeedIsPinnedToGitHubPages() {
        XCTAssertEqual(
            AppUpdater.feedURL.absoluteString,
            "https://ihopefulchina.github.io/Tunnelful/appcast.xml"
        )
        XCTAssertEqual(AppUpdater.publicEDKey, "0hyxOLR9zBFNvSdozSz0hALE/wHrk72Vsad4KxqpyM0=")
    }

    func testAutomaticCheckPreferenceIsForwardedToTheUpdaterDriver() {
        let driver = RecordingUpdaterDriver()
        let updater = AppUpdater(driver: driver)

        updater.automaticallyChecksForUpdates = false

        XCTAssertFalse(driver.automaticallyChecksForUpdates)
    }

    func testManualCheckIsForwardedExactlyOnce() {
        let driver = RecordingUpdaterDriver()
        let updater = AppUpdater(driver: driver)

        updater.checkForUpdates()

        XCTAssertEqual(driver.checkCount, 1)
    }

    func testNumericBuildNumbersCompareAsIntegers() {
        XCTAssertTrue(AppUpdateVersion.isNewer("11", than: "9"))
        XCTAssertFalse(AppUpdateVersion.isNewer("5", than: "9"))
        XCTAssertFalse(AppUpdateVersion.isNewer("9", than: "9"))
    }

    func testMarketingVersionsCompareByNumericComponents() {
        XCTAssertTrue(AppUpdateVersion.isNewer("0.1.8", than: "0.1.7"))
        XCTAssertTrue(AppUpdateVersion.isNewer("0.1.5", than: "0.1.2"))
        XCTAssertFalse(AppUpdateVersion.isNewer("0.1.2", than: "0.1.4"))
        XCTAssertFalse(AppUpdateVersion.isNewer("0.1.8", than: "0.1.8"))
    }
}

@MainActor
private final class RecordingUpdaterDriver: AppUpdaterDriving {
    var automaticallyChecksForUpdates = true
    var canCheckForUpdates = true
    private(set) var checkCount = 0

    func checkForUpdates() {
        checkCount += 1
    }
}
