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
        XCTAssertEqual(
            plist["AssociatedBundleIdentifiers"] as? [String],
            [AppIdentity.bundleIdentifier]
        )
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

    func testManagerDoesNotTreatAnUnloadedLegacyPlistAsEnabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-login-stale-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentLoginItem.label).plist")
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: plistURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            serviceStatus: { .notFound },
            registerService: {},
            unregisterService: {},
            legacyPlistStatus: { _ in .notFound },
            runLaunchctl: { _ in 0 }
        )

        XCTAssertEqual(manager.currentState(), .disabled)
    }

    func testManagerDetectsAndDisablesPreviousBundleLaunchAgent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-old-login-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let oldLabel = try XCTUnwrap(LaunchAgentLoginItem.legacyLabels.first)
        let oldPlistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(oldLabel).plist")
        try FileManager.default.createDirectory(
            at: oldPlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: oldPlistURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldStatus = LockingBox<SMAppService.Status>(.enabled)
        let commands = LockingBox<[[String]]>([])
        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            uid: 501,
            serviceStatus: { .notFound },
            registerService: {},
            unregisterService: {},
            legacyPlistStatus: { url in
                url == oldPlistURL ? oldStatus.value : .notFound
            },
            runLaunchctl: { arguments in
                var recorded = commands.value
                recorded.append(arguments)
                commands.value = recorded
                if arguments == ["bootout", "gui/501/\(oldLabel)"] {
                    oldStatus.value = .notFound
                }
                return 0
            }
        )

        XCTAssertEqual(manager.currentState(), .enabled)
        try manager.setEnabled(false)
        XCTAssertEqual(manager.currentState(), .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPlistURL.path))
        XCTAssertTrue(commands.value.contains(["bootout", "gui/501/\(oldLabel)"]))
    }

    func testAutomaticMigrationReplacesPreviousBundleLaunchAgentAfterNewAgentIsReady() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-migrate-login-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let oldLabel = try XCTUnwrap(LaunchAgentLoginItem.legacyLabels.first)
        let oldPlistURL = launchAgents.appendingPathComponent("\(oldLabel).plist")
        let newPlistURL = launchAgents.appendingPathComponent("\(LaunchAgentLoginItem.label).plist")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: oldPlistURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let statuses = LockingBox<[String: SMAppService.Status]>([
            oldPlistURL.path: .enabled
        ])
        let commands = LockingBox<[[String]]>([])
        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            uid: 501,
            serviceStatus: { .notFound },
            registerService: { throw LaunchAtLoginError.registrationFailed("service unavailable") },
            unregisterService: {},
            legacyPlistStatus: { url in
                statuses.value[url.path] ?? .notFound
            },
            runLaunchctl: { arguments in
                var recorded = commands.value
                recorded.append(arguments)
                commands.value = recorded
                var currentStatuses = statuses.value
                if arguments.first == "bootstrap" {
                    currentStatuses[newPlistURL.path] = .enabled
                } else if arguments == ["bootout", "gui/501/\(oldLabel)"] {
                    currentStatuses[oldPlistURL.path] = .notFound
                }
                statuses.value = currentStatuses
                return 0
            }
        )

        try manager.migrateLegacyLaunchAgentIfNeeded()
        XCTAssertEqual(manager.currentState(), .enabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPlistURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPlistURL.path))
        let bootstrapIndex = try XCTUnwrap(
            commands.value.firstIndex { $0.first == "bootstrap" }
        )
        let oldBootoutIndex = try XCTUnwrap(
            commands.value.firstIndex { $0 == ["bootout", "gui/501/\(oldLabel)"] }
        )
        XCTAssertLessThan(bootstrapIndex, oldBootoutIndex)
    }

    func testFailedAutomaticMigrationLeavesPreviousBundleLaunchAgentEnabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-failed-login-migration-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let oldLabel = try XCTUnwrap(LaunchAgentLoginItem.legacyLabels.first)
        let oldPlistURL = launchAgents.appendingPathComponent("\(oldLabel).plist")
        let newPlistURL = launchAgents.appendingPathComponent("\(LaunchAgentLoginItem.label).plist")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: oldPlistURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            serviceStatus: { .notFound },
            registerService: { throw LaunchAtLoginError.registrationFailed("service unavailable") },
            unregisterService: {},
            legacyPlistStatus: { url in
                url == oldPlistURL ? .enabled : .notFound
            },
            runLaunchctl: { arguments in
                arguments.first == "bootstrap" ? 5 : 0
            }
        )

        XCTAssertThrowsError(try manager.migrateLegacyLaunchAgentIfNeeded())
        XCTAssertEqual(manager.currentState(), .enabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPlistURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newPlistURL.path))
    }

    func testAutomaticMigrationKeepsPreviousAgentWhileNewServiceNeedsApproval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-pending-login-migration-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let oldLabel = try XCTUnwrap(LaunchAgentLoginItem.legacyLabels.first)
        let oldPlistURL = launchAgents.appendingPathComponent("\(oldLabel).plist")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: oldPlistURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let serviceStatus = LockingBox<SMAppService.Status>(.notFound)
        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            serviceStatus: { serviceStatus.value },
            registerService: { serviceStatus.value = .requiresApproval },
            unregisterService: {},
            legacyPlistStatus: { url in
                url == oldPlistURL ? .enabled : .notFound
            },
            runLaunchctl: { _ in
                XCTFail("等待系统批准时不应移除或替换仍可用的旧登录项。")
                return 1
            }
        )

        try manager.migrateLegacyLaunchAgentIfNeeded()
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPlistURL.path))
        XCTAssertEqual(manager.currentState(), .requiresApproval)
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

        let legacyStatus = LockingBox<SMAppService.Status>(.notFound)
        let manager = SystemLaunchAtLoginManager(
            bundleURL: bundleURL,
            homeDirectory: home,
            serviceStatus: { .notFound },
            registerService: { throw LaunchAtLoginError.registrationFailed("service unavailable") },
            unregisterService: {},
            legacyPlistStatus: { _ in legacyStatus.value },
            runLaunchctl: { arguments in
                switch arguments.first {
                case "bootstrap": legacyStatus.value = .enabled
                case "bootout": legacyStatus.value = .notFound
                default: break
                }
                return 0
            }
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

    func testManagerRejectsFailedLaunchAgentBootstrapAndCleansUpPlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-login-bootstrap-failure-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            serviceStatus: { .notFound },
            registerService: { throw LaunchAtLoginError.registrationFailed("service unavailable") },
            unregisterService: {},
            legacyPlistStatus: { _ in .notFound },
            runLaunchctl: { arguments in
                arguments.first == "bootstrap" ? 5 : 0
            }
        )

        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            guard case let .registrationFailed(message) = error as? LaunchAtLoginError else {
                return XCTFail("Expected launchctl registration failure")
            }
            XCTAssertTrue(message.contains("bootstrap"), message)
            XCTAssertTrue(message.contains("5"), message)
        }
        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentLoginItem.label).plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
        XCTAssertEqual(manager.currentState(), .disabled)
    }

    func testManagerRejectsFailedLaunchAgentEnableAndCleansUpLoadedService() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-login-enable-failure-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyStatus = LockingBox<SMAppService.Status>(.notFound)
        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            serviceStatus: { .notFound },
            registerService: { throw LaunchAtLoginError.registrationFailed("service unavailable") },
            unregisterService: {},
            legacyPlistStatus: { _ in legacyStatus.value },
            runLaunchctl: { arguments in
                switch arguments.first {
                case "bootstrap":
                    legacyStatus.value = .enabled
                    return 0
                case "enable":
                    return 9
                case "bootout":
                    legacyStatus.value = .notFound
                    return 0
                default:
                    return 0
                }
            }
        )

        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            guard case let .registrationFailed(message) = error as? LaunchAtLoginError else {
                return XCTFail("Expected launchctl registration failure")
            }
            XCTAssertTrue(message.contains("enable"), message)
            XCTAssertTrue(message.contains("9"), message)
        }
        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentLoginItem.label).plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
        XCTAssertEqual(legacyStatus.value, .notFound)
        XCTAssertEqual(manager.currentState(), .disabled)
    }

    func testManagerRetainsExistingLaunchAgentWhenPreflightBootoutFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-login-preflight-bootout-failure-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentLoginItem.label).plist")
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("existing".utf8).write(to: plistURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            serviceStatus: { .notFound },
            registerService: { throw LaunchAtLoginError.registrationFailed("service unavailable") },
            unregisterService: {},
            legacyPlistStatus: { _ in .enabled },
            runLaunchctl: { arguments in
                arguments.first == "bootout" ? 11 : 0
            }
        )

        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            guard case let .registrationFailed(message) = error as? LaunchAtLoginError else {
                return XCTFail("Expected launchctl bootout failure")
            }
            XCTAssertTrue(message.contains("bootout"), message)
            XCTAssertTrue(message.contains("11"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
        XCTAssertEqual(manager.currentState(), .enabled)
    }

    func testManagerRetainsLaunchAgentWhenEnableFailureCannotBeCleanedUpAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-login-enable-cleanup-failure-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyStatus = LockingBox<SMAppService.Status>(.notFound)
        let bootoutAttempts = LockingBox(0)
        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            serviceStatus: { .notFound },
            registerService: { throw LaunchAtLoginError.registrationFailed("service unavailable") },
            unregisterService: {},
            legacyPlistStatus: { _ in legacyStatus.value },
            runLaunchctl: { arguments in
                switch arguments.first {
                case "bootstrap":
                    legacyStatus.value = .enabled
                    return 0
                case "enable":
                    return 9
                case "bootout":
                    bootoutAttempts.value += 1
                    if bootoutAttempts.value == 1 {
                        return 11
                    }
                    legacyStatus.value = .notFound
                    return 0
                default:
                    return 0
                }
            }
        )

        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            guard case let .registrationFailed(message) = error as? LaunchAtLoginError else {
                return XCTFail("Expected launchctl cleanup failure")
            }
            XCTAssertTrue(message.contains("enable"), message)
            XCTAssertTrue(message.contains("bootout"), message)
            XCTAssertTrue(message.contains("11"), message)
        }

        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentLoginItem.label).plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
        XCTAssertEqual(manager.currentState(), .enabled)

        try manager.setEnabled(false)
        XCTAssertEqual(bootoutAttempts.value, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
        XCTAssertEqual(manager.currentState(), .disabled)
    }

    func testManagerReportsFailedLegacyBootoutAndRetainsPlistForRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelful-login-bootout-failure-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentLoginItem.label).plist")
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("loaded".utf8).write(to: plistURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SystemLaunchAtLoginManager(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunnelful.app"),
            homeDirectory: home,
            serviceStatus: { .notFound },
            registerService: {},
            unregisterService: {},
            legacyPlistStatus: { _ in .enabled },
            runLaunchctl: { arguments in
                arguments.first == "bootout" ? 11 : 0
            }
        )

        XCTAssertThrowsError(try manager.setEnabled(false)) { error in
            guard case let .registrationFailed(message) = error as? LaunchAtLoginError else {
                return XCTFail("Expected launchctl bootout failure")
            }
            XCTAssertTrue(message.contains("bootout"), message)
            XCTAssertTrue(message.contains("11"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
        XCTAssertEqual(manager.currentState(), .enabled)
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
