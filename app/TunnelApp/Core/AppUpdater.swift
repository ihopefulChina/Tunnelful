import AppKit
import Combine
import Sparkle

enum AppUpdateVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftParts = numericParts(lhs)
        let rightParts = numericParts(rhs)
        let count = max(leftParts.count, rightParts.count)
        for index in 0..<count {
            let left = index < leftParts.count ? leftParts[index] : 0
            let right = index < rightParts.count ? rightParts[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericParts(_ version: String) -> [Int] {
        version
            .split { !$0.isNumber && $0 != "." }
            .flatMap { $0.split(separator: ".") }
            .compactMap { Int($0) }
    }
}

@MainActor
protocol AppUpdaterDriving: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

private final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in
            ApplicationActivation.showSystemMenu()
        }
    }
}

private final class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? ""
        guard AppUpdateVersion.isNewer(updateItem.versionString, than: currentVersion) else {
            throw NSError(
                domain: "\(AppIdentity.bundleIdentifier).update",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "更新源提供的版本不高于当前已安装版本，已忽略。"
                ]
            )
        }
    }
}

@MainActor
private final class ReleaseSmokeTestUpdaterDriver: AppUpdaterDriving {
    var automaticallyChecksForUpdates = false
    let canCheckForUpdates = false

    func checkForUpdates() {}
}

@MainActor
private final class SparkleUpdaterDriver: AppUpdaterDriving {
    private let userDriverDelegate: SparkleUserDriverDelegate
    private let updateDelegate: SparkleUpdateDelegate
    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?
    var onCanCheckChange: (() -> Void)?

    init() {
        let userDriverDelegate = SparkleUserDriverDelegate()
        let updateDelegate = SparkleUpdateDelegate()
        self.userDriverDelegate = userDriverDelegate
        self.updateDelegate = updateDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updateDelegate,
            userDriverDelegate: userDriverDelegate
        )
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { _, _ in
            Task { @MainActor [weak self] in
                self?.onCanCheckChange?()
            }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    static let feedURL = URL(string: "https://ihopefulchina.github.io/Tunnelful/appcast.xml")!
    static let publicEDKey = "0hyxOLR9zBFNvSdozSz0hALE/wHrk72Vsad4KxqpyM0="

    private var storedDriver: (any AppUpdaterDriving)?

    init(
        driver: (any AppUpdaterDriving)? = nil,
        releaseSmokeTest: Bool = false
    ) {
        if releaseSmokeTest {
            storedDriver = ReleaseSmokeTestUpdaterDriver()
        } else {
            storedDriver = driver
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { driver.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            driver.automaticallyChecksForUpdates = newValue
        }
    }

    var canCheckForUpdates: Bool {
        driver.canCheckForUpdates
    }

    func checkForUpdates() {
        ApplicationActivation.showSystemMenu()
        driver.checkForUpdates()
    }

    private var driver: any AppUpdaterDriving {
        if let storedDriver {
            return storedDriver
        }
        let driver = SparkleUpdaterDriver()
        driver.onCanCheckChange = { [weak self] in
            self?.objectWillChange.send()
        }
        storedDriver = driver
        objectWillChange.send()
        return driver
    }
}
