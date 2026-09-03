import AppKit
import Combine
import Sparkle

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

@MainActor
private final class SparkleUpdaterDriver: AppUpdaterDriving {
    private let userDriverDelegate: SparkleUserDriverDelegate
    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?
    var onCanCheckChange: (() -> Void)?

    init() {
        let userDriverDelegate = SparkleUserDriverDelegate()
        self.userDriverDelegate = userDriverDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
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

    init(driver: (any AppUpdaterDriving)? = nil) {
        storedDriver = driver
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
