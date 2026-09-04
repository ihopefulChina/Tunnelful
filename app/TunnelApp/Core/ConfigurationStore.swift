import CryptoKit
import Darwin
import Foundation

struct ConfigurationSourceState: Equatable, Sendable {
    let requestedURL: URL
    let effectiveURL: URL
    let contentDigest: Data
    let deviceIdentifier: UInt64?
    let fileIdentifier: UInt64?
}

final class ConfigurationSourceSnapshot: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var state: ConfigurationSourceState

    init(state: ConfigurationSourceState) {
        self.state = state
    }

    func currentState() -> ConfigurationSourceState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func update(to newState: ConfigurationSourceState) {
        lock.lock()
        state = newState
        lock.unlock()
    }

    static func == (lhs: ConfigurationSourceSnapshot, rhs: ConfigurationSourceSnapshot) -> Bool {
        lhs === rhs || lhs.currentState() == rhs.currentState()
    }
}

struct ConfigurationLocator: @unchecked Sendable {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let systemDirectories: [URL]

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemDirectories: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/etc/cloudflared", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/etc/cloudflared", isDirectory: true),
            URL(fileURLWithPath: "/etc/cloudflared", isDirectory: true)
        ]
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.systemDirectories = systemDirectories
    }

    func discover() -> [URL] {
        var candidates = [
            homeDirectory.appendingPathComponent(".cloudflared/config.yml"),
            homeDirectory.appendingPathComponent(".cloudflared/config.yaml")
        ]
        candidates.append(contentsOf: systemDirectories.flatMap { directory in
            [
                directory.appendingPathComponent("config.yml"),
                directory.appendingPathComponent("config.yaml")
            ]
        })
        return candidates.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }
}

struct ConfigurationSaveResult: Equatable, Sendable {
    let destinationURL: URL
    let backupURL: URL?
}

enum ConfigurationStoreError: LocalizedError, Equatable {
    case validationFailed([String])
    case missingParentDirectory(URL)
    case symbolicLinkTargetUnavailable
    case fileChangedSinceLoad

    var errorDescription: String? {
        switch self {
        case let .validationFailed(messages):
            return messages.joined(separator: " ")
        case let .missingParentDirectory(url):
            return "配置文件夹不存在：\(url.path)"
        case .symbolicLinkTargetUnavailable:
            return "配置文件的符号链接目标不存在或不可用。请修复链接或重新选择配置文件。"
        case .fileChangedSinceLoad:
            return "配置文件已被其他应用修改。为避免覆盖新内容，保存已取消；请重新载入后再编辑。"
        }
    }
}

enum ConfigurationAtomicReplacementPhase: Equatable, Sendable {
    case beforeReplacement
    case beforeRollback
}

struct CloudflaredConfigurationStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let atomicReplacementObserver: @Sendable (ConfigurationAtomicReplacementPhase) -> Void
    private let parser = CloudflaredConfigParser()
    private let serializer = CloudflaredConfigSerializer()

    init(
        fileManager: FileManager = .default,
        atomicReplacementObserver: @escaping @Sendable (ConfigurationAtomicReplacementPhase) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.atomicReplacementObserver = atomicReplacementObserver
    }

    func load(from url: URL) throws -> CloudflaredConfigDocument {
        let requestedURL = url.standardizedFileURL
        let effectiveURL = try effectiveDestination(for: requestedURL)
        let bytes = try Data(contentsOf: effectiveURL)
        guard let contents = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        var document = try parser.parse(contents: contents, sourceURL: requestedURL)
        document.sourceSnapshot = ConfigurationSourceSnapshot(
            state: sourceState(
                requestedURL: requestedURL,
                effectiveURL: effectiveURL,
                identityURL: effectiveURL,
                bytes: bytes
            )
        )
        return document
    }

    func verifySourceUnchanged(for document: CloudflaredConfigDocument) throws {
        guard let requestedURL = document.sourceURL?.standardizedFileURL,
              let expectedState = document.sourceSnapshot?.currentState(),
              expectedState.requestedURL == requestedURL else {
            throw ConfigurationStoreError.fileChangedSinceLoad
        }

        let effectiveURL = try effectiveDestination(for: requestedURL)
        guard let bytes = try existingContents(at: effectiveURL) else {
            throw ConfigurationStoreError.fileChangedSinceLoad
        }
        let currentState = sourceState(
            requestedURL: requestedURL,
            effectiveURL: effectiveURL,
            identityURL: effectiveURL,
            bytes: bytes
        )
        guard currentState == expectedState else {
            throw ConfigurationStoreError.fileChangedSinceLoad
        }
    }

    @discardableResult
    func save(_ document: CloudflaredConfigDocument, to destinationURL: URL) throws -> ConfigurationSaveResult {
        let failures = document.validationIssues()
            .filter { $0.severity == .error }
            .map(\.message)
        guard failures.isEmpty else {
            throw ConfigurationStoreError.validationFailed(failures)
        }

        let requestedURL = destinationURL.standardizedFileURL
        let requestedParent = requestedURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: requestedParent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigurationStoreError.missingParentDirectory(requestedParent)
        }

        let effectiveURL = try effectiveDestination(for: requestedURL)
        let effectiveParent = effectiveURL.deletingLastPathComponent()
        isDirectory = false
        guard fileManager.fileExists(atPath: effectiveParent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigurationStoreError.missingParentDirectory(effectiveParent)
        }

        let existingBytes = try existingContents(at: effectiveURL)
        let stateBeforeSave = existingBytes.map {
            sourceState(
                requestedURL: requestedURL,
                effectiveURL: effectiveURL,
                identityURL: effectiveURL,
                bytes: $0
            )
        }
        let trackedSnapshot = document.sourceSnapshot
        let expectedState = trackedSnapshot?.currentState()
        if let expectedState, expectedState.requestedURL == requestedURL,
           stateBeforeSave != expectedState {
            throw ConfigurationStoreError.fileChangedSinceLoad
        }

        let bytes = Data(serializer.serialize(document).utf8)
        let stagingURL = try writeStagingFile(bytes, beside: effectiveURL)
        var stagingFileStillExists = true
        defer {
            if stagingFileStillExists {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        var accessorError: Error?
        var coordinationError: NSError?
        var backupURL: URL?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: effectiveURL,
            options: .forReplacing,
            error: &coordinationError
        ) { _ in
            do {
                let preparedBackupURL = try prepareBackupURLIfNeeded(
                    sourceURL: effectiveURL,
                    hasExistingContents: existingBytes != nil
                )
                if existingBytes != nil {
                    // Prepare the replacement's security metadata before the final
                    // content check. The displaced source is copied once more after
                    // the atomic swap so a last-moment ACL/xattr change is retained.
                    try copySecurityMetadata(from: effectiveURL, to: stagingURL)
                }

                let currentEffectiveURL = try effectiveDestination(for: requestedURL)
                let currentBytes = try existingContents(at: currentEffectiveURL)
                let currentState = currentBytes.map {
                    sourceState(
                        requestedURL: requestedURL,
                        effectiveURL: currentEffectiveURL,
                        identityURL: currentEffectiveURL,
                        bytes: $0
                    )
                }
                guard currentState == stateBeforeSave else {
                    throw ConfigurationStoreError.fileChangedSinceLoad
                }

                // This hook exists only to make the otherwise microscopic
                // check-to-replacement race deterministic in regression tests.
                atomicReplacementObserver(.beforeReplacement)
                if currentBytes != nil {
                    let installedState = sourceState(
                        requestedURL: requestedURL,
                        effectiveURL: currentEffectiveURL,
                        identityURL: stagingURL,
                        bytes: bytes
                    )
                    try swapAtomically(stagingURL, destinationURL: currentEffectiveURL)
                    do {
                        let displacedBytes = try Data(contentsOf: stagingURL)
                        let displacedState = sourceState(
                            requestedURL: requestedURL,
                            effectiveURL: currentEffectiveURL,
                            identityURL: stagingURL,
                            bytes: displacedBytes
                        )
                        let latestEffectiveURL = try effectiveDestination(for: requestedURL)
                        guard latestEffectiveURL == currentEffectiveURL,
                              displacedState == stateBeforeSave else {
                            throw ConfigurationStoreError.fileChangedSinceLoad
                        }

                        // The file at stagingURL is the exact inode displaced by the
                        // swap. Copy its latest metadata, then move that inode into the
                        // backup directory without reconstructing it.
                        try copySecurityMetadata(from: stagingURL, to: currentEffectiveURL)
                        if let preparedBackupURL {
                            try moveAtomically(stagingURL, destinationURL: preparedBackupURL)
                            backupURL = preparedBackupURL
                            stagingFileStillExists = false
                        }
                    } catch let replacementError {
                        atomicReplacementObserver(.beforeRollback)
                        let destinationBytes = try existingContents(at: currentEffectiveURL)
                        let destinationState = destinationBytes.map {
                            sourceState(
                                requestedURL: requestedURL,
                                effectiveURL: currentEffectiveURL,
                                identityURL: currentEffectiveURL,
                                bytes: $0
                            )
                        }
                        guard destinationState == installedState else {
                            do {
                                if let preparedBackupURL {
                                    try moveAtomically(stagingURL, destinationURL: preparedBackupURL)
                                    backupURL = preparedBackupURL
                                    stagingFileStillExists = false
                                } else {
                                    // The displaced source is more important than
                                    // removing a hidden recovery file.
                                    stagingFileStillExists = false
                                }
                            } catch {
                                // Leave stagingURL in place for manual recovery.
                                stagingFileStillExists = false
                                throw error
                            }
                            throw replacementError
                        }

                        do {
                            try swapAtomically(stagingURL, destinationURL: currentEffectiveURL)
                        } catch {
                            // Preserve the displaced source as a recovery file if even
                            // the atomic rollback cannot be completed.
                            stagingFileStillExists = false
                            throw error
                        }

                        let rolledOutBytes = try Data(contentsOf: stagingURL)
                        let rolledOutState = sourceState(
                            requestedURL: requestedURL,
                            effectiveURL: currentEffectiveURL,
                            identityURL: stagingURL,
                            bytes: rolledOutBytes
                        )
                        guard rolledOutState == installedState else {
                            do {
                                // A third-party version landed between the preflight
                                // check and rollback. Put it back at the destination.
                                try swapAtomically(stagingURL, destinationURL: currentEffectiveURL)
                            } catch {
                                // Never delete the unknown version now held at stagingURL.
                                stagingFileStillExists = false
                                throw error
                            }
                            do {
                                if let preparedBackupURL {
                                    try moveAtomically(stagingURL, destinationURL: preparedBackupURL)
                                    backupURL = preparedBackupURL
                                    stagingFileStillExists = false
                                } else {
                                    stagingFileStillExists = false
                                }
                            } catch {
                                stagingFileStillExists = false
                                throw error
                            }
                            throw replacementError
                        }
                        throw replacementError
                    }
                } else {
                    do {
                        try installAtomicallyIfAbsent(stagingURL, destinationURL: currentEffectiveURL)
                        stagingFileStillExists = false
                    } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == EEXIST {
                        throw ConfigurationStoreError.fileChangedSinceLoad
                    }
                }
            } catch {
                accessorError = error
            }
        }
        if let accessorError {
            throw accessorError
        }
        if let coordinationError {
            throw coordinationError
        }

        if let trackedSnapshot, expectedState?.requestedURL == requestedURL {
            trackedSnapshot.update(to: sourceState(
                requestedURL: requestedURL,
                effectiveURL: effectiveURL,
                identityURL: effectiveURL,
                bytes: bytes
            ))
        }

        return ConfigurationSaveResult(destinationURL: effectiveURL, backupURL: backupURL)
    }

    private func effectiveDestination(for requestedURL: URL) throws -> URL {
        let isFileSymbolicLink = (try? fileManager.destinationOfSymbolicLink(atPath: requestedURL.path)) != nil
        let effectiveURL = requestedURL.resolvingSymlinksInPath().standardizedFileURL
        guard isFileSymbolicLink else { return effectiveURL }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: effectiveURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ConfigurationStoreError.symbolicLinkTargetUnavailable
        }
        return effectiveURL
    }

    private func existingContents(at url: URL) throws -> Data? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue else { throw ConfigurationStoreError.symbolicLinkTargetUnavailable }
        return try Data(contentsOf: url)
    }

    private func sourceState(
        requestedURL: URL,
        effectiveURL: URL,
        identityURL: URL,
        bytes: Data
    ) -> ConfigurationSourceState {
        let attributes = try? fileManager.attributesOfItem(atPath: identityURL.path)
        return ConfigurationSourceState(
            requestedURL: requestedURL.standardizedFileURL,
            effectiveURL: effectiveURL.standardizedFileURL,
            contentDigest: Data(SHA256.hash(data: bytes)),
            deviceIdentifier: (attributes?[.systemNumber] as? NSNumber)?.uint64Value,
            fileIdentifier: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func writeStagingFile(_ bytes: Data, beside destinationURL: URL) throws -> URL {
        let stagingURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = stagingURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            try handle.close()
            return stagingURL
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private func copySecurityMetadata(from sourceURL: URL, to destinationURL: URL) throws {
        let replacementModificationDate = Date()
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                copyfile(
                    sourcePath,
                    destinationPath,
                    nil,
                    copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
                )
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try fileManager.setAttributes(
            [.modificationDate: replacementModificationDate],
            ofItemAtPath: destinationURL.path
        )
    }

    private func swapAtomically(_ stagingURL: URL, destinationURL: URL) throws {
        let result = stagingURL.path.withCString { stagingPath in
            destinationURL.path.withCString { destinationPath in
                renamex_np(stagingPath, destinationPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func installAtomicallyIfAbsent(_ stagingURL: URL, destinationURL: URL) throws {
        let result = stagingURL.path.withCString { stagingPath in
            destinationURL.path.withCString { destinationPath in
                renamex_np(stagingPath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func moveAtomically(_ sourceURL: URL, destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func prepareBackupURLIfNeeded(
        sourceURL: URL,
        hasExistingContents: Bool
    ) throws -> URL? {
        guard hasExistingContents else { return nil }

        let backupDirectory = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: backupDirectory.path
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return backupDirectory.appendingPathComponent(
            "\(sourceURL.lastPathComponent).\(stamp).\(UUID().uuidString.prefix(8)).bak"
        )
    }
}
