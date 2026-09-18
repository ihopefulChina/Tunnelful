import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Exclusive `flock` held for the lifetime of the object.
final class ExclusiveFileLock: @unchecked Sendable {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    static func tryAcquire(at url: URL) -> ExclusiveFileLock? {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileDescriptor = url.path.withCString { path in
            open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard fileDescriptor >= 0 else { return nil }
        if flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            close(fileDescriptor)
            return nil
        }
        return ExclusiveFileLock(fileDescriptor: fileDescriptor)
    }
}

enum TunnelRunLock {
    static func tryAcquire(tunnelName: String) -> ExclusiveFileLock? {
        let sanitized = sanitize(tunnelName)
        guard !sanitized.isEmpty else { return nil }
        return ExclusiveFileLock.tryAcquire(at: supportDirectory.appendingPathComponent("\(sanitized).lock"))
    }

    private static var supportDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("run-locks", isDirectory: true)
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let compact = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(compact.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}

enum AppInstanceCoordination {
    private static var retainedLock: ExclusiveFileLock?

    static var isRunningUnderTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    /// Returns false when another GUI instance owns the lock and has been asked to reopen.
    @discardableResult
    static func claimPrimaryInstanceOrActivateExisting() -> Bool {
        if shouldSkipInstanceLock {
            return true
        }
        let url = instanceLockURL
        if let lock = ExclusiveFileLock.tryAcquire(at: url) {
            retainedLock = lock
            return true
        }
        activateExistingInstance()
        return false
    }

    private static var shouldSkipInstanceLock: Bool {
        isRunningUnderTest
            || AppDomainMigration.isReleaseSmokeTest()
            || CommandLine.arguments.contains(ProcessLifetimeSupervisor.marker)
    }

    private static var instanceLockURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
        #if DEBUG
        return directory.appendingPathComponent("instance-debug.lock")
        #else
        return directory.appendingPathComponent("instance.lock")
        #endif
    }

    private static func activateExistingInstance() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: AppIdentity.bundleIdentifier
        ).filter { $0.processIdentifier != currentPID && !$0.isTerminated }

        if let existing = others.first(where: { $0.activationPolicy == .regular }) ?? others.first {
            existing.activate()
            sendReopenEvent(to: existing.processIdentifier)
            return
        }
        NSApp.activate()
    }

    private static func sendReopenEvent(to pid: pid_t) {
        var address = AEAddressDesc()
        var pidRecord = pid
        guard AECreateDesc(
            DescType(typeKernelProcessID),
            &pidRecord,
            MemoryLayout<pid_t>.size,
            &address
        ) == noErr else { return }
        defer { AEDisposeDesc(&address) }

        var event = AppleEvent()
        guard AECreateAppleEvent(
            AEEventClass(kCoreEventClass),
            AEEventID(kAEReopenApplication),
            &address,
            AEReturnID(Int16(kAutoGenerateReturnID)),
            AETransactionID(Int32(kAnyTransactionID)),
            &event
        ) == noErr else { return }
        defer { AEDisposeDesc(&event) }

        var reply = AppleEvent()
        _ = AESendMessage(&event, &reply, AESendMode(kAENoReply), 60)
        AEDisposeDesc(&reply)
    }
}
