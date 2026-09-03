import CryptoKit
import Foundation

struct ConfigurationSourceState: Equatable, Sendable {
    let requestedURL: URL
    let effectiveURL: URL
    let contentDigest: Data
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

struct CloudflaredConfigurationStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let parser = CloudflaredConfigParser()
    private let serializer = CloudflaredConfigSerializer()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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
            state: sourceState(requestedURL: requestedURL, effectiveURL: effectiveURL, bytes: bytes)
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
            sourceState(requestedURL: requestedURL, effectiveURL: effectiveURL, bytes: $0)
        }
        let trackedSnapshot = document.sourceSnapshot
        let expectedState = trackedSnapshot?.currentState()
        if let expectedState, expectedState.requestedURL == requestedURL,
           stateBeforeSave != expectedState {
            throw ConfigurationStoreError.fileChangedSinceLoad
        }

        let existingAttributes = try? fileManager.attributesOfItem(atPath: effectiveURL.path)
        let permissions = existingAttributes?[.posixPermissions] as? NSNumber ?? NSNumber(value: 0o600)
        let backupURL = try backupIfNeeded(
            sourceURL: effectiveURL,
            contents: existingBytes,
            permissions: permissions
        )

        if let stateBeforeSave {
            let currentEffectiveURL = try effectiveDestination(for: requestedURL)
            guard let currentBytes = try existingContents(at: currentEffectiveURL),
                  sourceState(
                    requestedURL: requestedURL,
                    effectiveURL: currentEffectiveURL,
                    bytes: currentBytes
                  ) == stateBeforeSave else {
                throw ConfigurationStoreError.fileChangedSinceLoad
            }
        }

        let bytes = Data(serializer.serialize(document).utf8)
        try bytes.write(to: effectiveURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: effectiveURL.path)

        if let trackedSnapshot, expectedState?.requestedURL == requestedURL {
            trackedSnapshot.update(to: sourceState(
                requestedURL: requestedURL,
                effectiveURL: effectiveURL,
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

    private func sourceState(requestedURL: URL, effectiveURL: URL, bytes: Data) -> ConfigurationSourceState {
        ConfigurationSourceState(
            requestedURL: requestedURL.standardizedFileURL,
            effectiveURL: effectiveURL.standardizedFileURL,
            contentDigest: Data(SHA256.hash(data: bytes))
        )
    }

    private func backupIfNeeded(
        sourceURL: URL,
        contents: Data?,
        permissions: NSNumber
    ) throws -> URL? {
        guard let contents else { return nil }

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
        var backupURL = backupDirectory.appendingPathComponent("\(sourceURL.lastPathComponent).\(stamp).bak")
        if fileManager.fileExists(atPath: backupURL.path) {
            backupURL = backupDirectory.appendingPathComponent(
                "\(sourceURL.lastPathComponent).\(stamp).\(UUID().uuidString.prefix(8)).bak"
            )
        }
        try contents.write(to: backupURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: backupURL.path)
        return backupURL
    }
}
