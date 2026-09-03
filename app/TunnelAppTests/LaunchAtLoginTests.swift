import Foundation
import ServiceManagement
import XCTest
@testable import TunnelApp

final class LaunchAtLoginTests: XCTestCase {
    func testBundleLocationClassifiesApplicationsAndUnsafeCopies() {
        let home = URL(fileURLWithPath: "/var/tmp/tunnelful-home", isDirectory: true)

        XCTAssertEqual(
            AppBundleLocation.classify(
                bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
                homeDirectory: home
            ),
            .applications
        )
        XCTAssertEqual(
            AppBundleLocation.classify(
                bundleURL: home.appendingPathComponent("Applications/Tunnelful.app"),
                homeDirectory: home
            ),
            .applications
        )
        XCTAssertEqual(
            AppBundleLocation.classify(
                bundleURL: URL(
                    fileURLWithPath: "/private/var/folders/n9/abc/T/AppTranslocation/1234-ABCD/d/Tunnelful.app"
                ),
                homeDirectory: home
            ),
            .translocated
        )
        XCTAssertEqual(
            AppBundleLocation.classify(
                bundleURL: URL(fileURLWithPath: "/Volumes/Tunnelful/Tunnelful.app"),
                homeDirectory: home
            ),
            .diskImage
        )
        XCTAssertEqual(
            AppBundleLocation.classify(
                bundleURL: URL(fileURLWithPath: "/var/tmp/tunnelful-downloads/Tunnelful.app"),
                homeDirectory: home
            ),
            .other
        )
    }

    func testLaunchAgentPropertyListOpensTheInstalledBundle() throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/Tunnelful.app")
        let data = try LaunchAgentLoginItem.propertyListData(opening: bundleURL)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let plist = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(plist["Label"] as? String, LaunchAgentLoginItem.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/usr/bin/open", bundleURL.path])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], ["app.tunnelful.mac"])
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("/Users/") == true)
    }

    func testManagerTreatsApplicationBundleWithUnknownServiceAsDisabled() {
        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            serviceStatus: { .notFound },
            registerService: {},
            unregisterService: {},
            legacyPlistStatus: { _ in .notFound },
            runLaunchctl: { _ in 0 }
        )

        XCTAssertEqual(manager.currentState(), .disabled)
    }

    func testManagerReportsTranslocatedAndDiskImageBundles() {
        let translocated = SystemLaunchAtLoginManager(
            bundleURL: URL(
                fileURLWithPath: "/private/var/folders/zz/abc/T/AppTranslocation/1234-ABCD/d/Tunnelful.app"
            ),
            serviceStatus: { .notFound },
            registerService: {},
            unregisterService: {},
            legacyPlistStatus: { _ in .notFound },
            runLaunchctl: { _ in 0 }
        )
        XCTAssertEqual(translocated.currentState(), .unavailable(.translocated))

        let diskImage = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Volumes/Tunnelful/Tunnelful.app"),
            serviceStatus: { .notFound },
            registerService: {},
            unregisterService: {},
            legacyPlistStatus: { _ in .notFound },
            runLaunchctl: { _ in 0 }
        )
        XCTAssertEqual(diskImage.currentState(), .unavailable(.diskImage))
    }

    func testManagerFallsBackToLaunchAgentWhenServiceRegistrationFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-login-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bundleURL = URL(fileURLWithPath: "/Applications/Tunnelful.app")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SystemLaunchAtLoginManager(
            bundleURL: bundleURL,
            homeDirectory: home,
            serviceStatus: { .notFound },
            registerService: { throw LaunchAtLoginError.registrationFailed("service unavailable") },
            unregisterService: {},
            legacyPlistStatus: { _ in .notFound },
            runLaunchctl: { _ in 0 }
        )

        XCTAssertEqual(manager.currentState(), .disabled)
        try manager.setEnabled(true)
        XCTAssertEqual(manager.currentState(), .enabled)

        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentLoginItem.label).plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
        let data = try Data(contentsOf: plistURL)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let plist = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/usr/bin/open", bundleURL.path])

        try manager.setEnabled(false)
        XCTAssertEqual(manager.currentState(), .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
    }

    func testManagerDoesNotWriteLaunchAgentWhenServiceRegisterSucceeds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-login-service-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let status = LockingBox<SMAppService.Status>(.notFound)
        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            serviceStatus: { status.value },
            registerService: { status.value = .enabled },
            unregisterService: { status.value = .notRegistered },
            legacyPlistStatus: { _ in .notFound },
            runLaunchctl: { _ in 0 }
        )

        try manager.setEnabled(true)
        XCTAssertEqual(manager.currentState(), .enabled)
        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentLoginItem.label).plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
    }

    func testEnablingFromDiskImageFailsWithoutWritingAgent() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-login-dmg-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Volumes/Tunnelful/Tunnelful.app"),
            homeDirectory: home,
            serviceStatus: { .notFound },
            registerService: {},
            unregisterService: {},
            legacyPlistStatus: { _ in .notFound },
            runLaunchctl: { _ in 0 }
        )

        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            XCTAssertEqual(error as? LaunchAtLoginError, .diskImage)
        }
        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentLoginItem.label).plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
    }

    func testEnvironmentInspectorUsesSpecificLaunchGuidance() {
        let inspector = EnvironmentInspector(
            homeDirectory: URL(fileURLWithPath: "/var/tmp/tunnelful-home", isDirectory: true)
        )

        let translocated = inspector.inspect(
            installation: nil,
            configDocument: nil,
            tunnelState: .notChecked,
            launchAtLoginState: .unavailable(.translocated),
            startTunnelOnLaunch: false
        )
        let diskImage = inspector.inspect(
            installation: nil,
            configDocument: nil,
            tunnelState: .notChecked,
            launchAtLoginState: .unavailable(.diskImage),
            startTunnelOnLaunch: false
        )

        let translocatedDetail = translocated.items.first { $0.id == "startup" }?.detail ?? ""
        let diskImageDetail = diskImage.items.first { $0.id == "startup" }?.detail ?? ""
        XCTAssertTrue(translocatedDetail.contains("临时副本"))
        XCTAssertTrue(diskImageDetail.contains("安装盘"))
        XCTAssertFalse(translocatedDetail.contains("移到“应用程序”文件夹后重试"))
        XCTAssertFalse(translocatedDetail.contains("tunnelful-home"))
        XCTAssertFalse(diskImageDetail.contains("/Volumes/"))
    }
}

private final class LockingBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
