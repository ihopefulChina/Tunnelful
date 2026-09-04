import Foundation
import XCTest
@testable import TunnelApp

final class ConfigurationTests: XCTestCase {
    private let sample = """
    tunnel: sample-tunnel-id
    credentials-file: $HOME/.cloudflared/credentials.json
    protocol: auto

    ingress:
      - hostname: dev.example.com
        service: http://127.0.0.1:3000
        originRequest:
          connectTimeout: 5s
      - service: http_status:404
    """

    func testParsesAndPreservesAdvancedFields() throws {
        let document = try CloudflaredConfigParser().parse(contents: sample)

        XCTAssertEqual(document.tunnel, "sample-tunnel-id")
        XCTAssertEqual(document.ingress.count, 2)
        XCTAssertEqual(document.ingress[0].hostname, "dev.example.com")
        XCTAssertTrue(document.ingress[0].preservedLines.contains("    originRequest:"))
        XCTAssertTrue(document.ingress[1].isCatchAll)

        let serialized = CloudflaredConfigSerializer().serialize(document)
        XCTAssertTrue(serialized.contains("protocol: auto"))
        XCTAssertTrue(serialized.contains("originRequest:"))
        XCTAssertTrue(serialized.contains("connectTimeout: 5s"))
    }

    func testSerializerReplacesSupportedTopLevelTunnelKeySpellingsWithoutDuplicates() throws {
        let spellings = [
            "tunnel : old-tunnel # keep this comment",
            "'tunnel': old-tunnel # keep this comment",
            "\"tunnel\" : old-tunnel # keep this comment"
        ]

        for spelling in spellings {
            let input = """
            \(spelling)
            credentials-file: credentials.json
            ingress:
              - service: http_status:404
            """
            var document = try CloudflaredConfigParser().parse(contents: input)
            XCTAssertEqual(document.tunnel, "old-tunnel", spelling)

            document.tunnel = "selected-tunnel"
            let serialized = CloudflaredConfigSerializer().serialize(document)
            let tunnelLines = serialized.components(separatedBy: "\n").filter {
                $0.contains("tunnel")
            }

            XCTAssertEqual(tunnelLines, ["tunnel: 'selected-tunnel' # keep this comment"], spelling)
            XCTAssertEqual(
                try CloudflaredConfigParser().parse(contents: serialized).tunnel,
                "selected-tunnel",
                spelling
            )
        }

        let similarlyNamedKey = """
        tunnel-name: keep-this-field
        ingress:
          - service: http_status:404
        """
        var document = try CloudflaredConfigParser().parse(contents: similarlyNamedKey)
        XCTAssertNil(document.tunnel)
        document.tunnel = "selected-tunnel"
        let serialized = CloudflaredConfigSerializer().serialize(document)
        XCTAssertTrue(serialized.contains("tunnel-name: keep-this-field"))
        XCTAssertTrue(serialized.contains("tunnel: 'selected-tunnel'"))
    }

    func testUpsertInsertsBeforeCatchAll() throws {
        var document = try CloudflaredConfigParser().parse(contents: sample)
        document.upsert(hostname: "admin.example.com", service: "http://127.0.0.1:4000")

        XCTAssertEqual(document.ingress.map(\.hostname), ["dev.example.com", "admin.example.com", nil])
        XCTAssertTrue(document.ingress.last?.isCatchAll == true)
        XCTAssertTrue(document.validationIssues().isEmpty)
    }

    func testInvalidCatchAllOrderIsRejected() {
        let document = CloudflaredConfigDocument(ingress: [
            IngressRule(service: "http_status:404"),
            IngressRule(hostname: "dev.example.com", service: "http://127.0.0.1:3000")
        ])

        XCTAssertTrue(document.validationIssues().contains(where: {
            $0.message.contains("兜底规则必须位于最后")
        }))
    }

    func testRE2NamedCapturePathIsLeftToCloudflaredValidation() {
        let document = CloudflaredConfigDocument(ingress: [
            IngressRule(
                hostname: "api.example.com",
                path: "^/users/(?P<id>[0-9]+)$",
                service: "http://127.0.0.1:3000"
            ),
            IngressRule(service: "http_status:404")
        ])

        XCTAssertTrue(document.validationIssues().isEmpty)
    }

    func testCRLFInputDoesNotGainBlankLinesWhenSerialized() throws {
        let crlf = sample.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"

        let document = try CloudflaredConfigParser().parse(contents: crlf)
        let serialized = CloudflaredConfigSerializer().serialize(document)

        XCTAssertFalse(serialized.contains("\r"))
        XCTAssertEqual(
            serialized.components(separatedBy: "\n").filter(\.isEmpty).count,
            2,
            "Only the original separator and the trailing newline should remain empty."
        )
        let reparsed = try CloudflaredConfigParser().parse(contents: serialized)
        XCTAssertEqual(reparsed.ingress.map(\.hostname), document.ingress.map(\.hostname))
        XCTAssertEqual(reparsed.ingress.map(\.path), document.ingress.map(\.path))
        XCTAssertEqual(reparsed.ingress.map(\.service), document.ingress.map(\.service))
        XCTAssertEqual(reparsed.ingress.map(\.preservedLines), document.ingress.map(\.preservedLines))
    }

    func testStoreCreatesBackupAndKeepsPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: configURL.path)

        var document = try CloudflaredConfigurationStore().load(from: configURL)
        document.upsert(hostname: "admin.example.com", service: "http://127.0.0.1:4000")
        let result = try CloudflaredConfigurationStore().save(document, to: configURL)

        XCTAssertNotNil(result.backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.backupURL!.path))
        let mode = try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertTrue(try String(contentsOf: configURL).contains("admin.example.com"))
    }

    func testStorePreservesSecurityMetadataOnConfigurationAndBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: configURL.path
        )
        XCTAssertEqual(
            try runTool(
                executable: "/usr/bin/xattr",
                arguments: ["-w", "app.ihopeful.Tunnelful.tests", "preserve-me", configURL.path]
            ).status,
            0
        )
        XCTAssertEqual(
            try runTool(
                executable: "/bin/chmod",
                arguments: ["+a", "user:nobody deny read", configURL.path]
            ).status,
            0
        )

        let store = CloudflaredConfigurationStore()
        var document = try store.load(from: configURL)
        document.upsert(hostname: "metadata.example.com", service: "http://127.0.0.1:4000")
        let result = try store.save(document, to: configURL)
        let backupURL = try XCTUnwrap(result.backupURL)

        for url in [configURL, backupURL] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o640)
            let xattr = try runTool(
                executable: "/usr/bin/xattr",
                arguments: ["-p", "app.ihopeful.Tunnelful.tests", url.path]
            )
            XCTAssertEqual(xattr.status, 0)
            XCTAssertEqual(xattr.output.trimmingCharacters(in: .whitespacesAndNewlines), "preserve-me")
            let listing = try runTool(executable: "/bin/ls", arguments: ["-le", url.path])
            XCTAssertEqual(listing.status, 0)
            XCTAssertTrue(listing.output.contains("deny read"), listing.output)
        }
    }

    func testStoreRollsBackChangeMadeAfterFinalVerificationBeforeAtomicReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        let externalContents = sample.replacingOccurrences(
            of: "dev.example.com",
            with: "changed-immediately-before-write.example.com"
        )
        let store = CloudflaredConfigurationStore(atomicReplacementObserver: { phase in
            guard phase == .beforeReplacement else { return }
            try! Data(externalContents.utf8).write(to: configURL, options: .atomic)
        })
        var document = try store.load(from: configURL)
        document.upsert(hostname: "local-edit.example.com", service: "http://127.0.0.1:4000")

        XCTAssertThrowsError(try store.save(document, to: configURL)) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .fileChangedSinceLoad)
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), externalContents)
        let stagedFiles = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix(".config.yml.") && $0.hasSuffix(".tmp")
        }
        XCTAssertTrue(stagedFiles.isEmpty)
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
        XCTAssertTrue(backups.isEmpty)
    }

    func testStoreDoesNotDeleteNewerWriteThatArrivesBeforeConflictRollback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        let firstExternalContents = sample.replacingOccurrences(
            of: "dev.example.com",
            with: "first-external.example.com"
        )
        let latestExternalContents = sample.replacingOccurrences(
            of: "dev.example.com",
            with: "latest-external.example.com"
        )
        let store = CloudflaredConfigurationStore(atomicReplacementObserver: { phase in
            switch phase {
            case .beforeReplacement:
                try! Data(firstExternalContents.utf8).write(to: configURL, options: .atomic)
            case .beforeRollback:
                try! Data(latestExternalContents.utf8).write(to: configURL, options: .atomic)
            }
        })
        var document = try store.load(from: configURL)
        document.upsert(hostname: "local-edit.example.com", service: "http://127.0.0.1:4000")

        XCTAssertThrowsError(try store.save(document, to: configURL)) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .fileChangedSinceLoad)
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), latestExternalContents)

        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        let backupURLs = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backupURLs.count, 1)
        XCTAssertEqual(
            try String(contentsOf: XCTUnwrap(backupURLs.first), encoding: .utf8),
            firstExternalContents
        )
        let stagedFiles = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix(".config.yml.") && $0.hasSuffix(".tmp")
        }
        XCTAssertTrue(stagedFiles.isEmpty)
    }

    func testParserUsesTheTopLevelListIndentAndPreservesNestedLists() throws {
        let input = """
        ingress:
            - hostname: dev.example.com
              service: http://127.0.0.1:3000
              originRequest:
                access:
                  audTag:
                    - first-audience
                    - second-audience
                ports:
                  - 443
                  - 8443
            - service: http_status:404
        """

        let document = try CloudflaredConfigParser().parse(contents: input)

        XCTAssertEqual(document.ingress.count, 2)
        XCTAssertEqual(document.ingress[0].hostname, "dev.example.com")
        XCTAssertEqual(document.ingress[0].service, "http://127.0.0.1:3000")
        XCTAssertTrue(document.ingress[0].preservedLines.contains("            - first-audience"))
        XCTAssertTrue(document.ingress[0].preservedLines.contains("            - second-audience"))
        XCTAssertTrue(document.ingress[0].preservedLines.contains("          - 443"))
        XCTAssertTrue(document.ingress[0].preservedLines.contains("          - 8443"))

        let serialized = CloudflaredConfigSerializer().serialize(document)
        XCTAssertTrue(serialized.contains("audTag:"))
        XCTAssertTrue(serialized.contains("- first-audience"))
        XCTAssertTrue(serialized.contains("- second-audience"))
        XCTAssertTrue(serialized.contains("ports:"))
        XCTAssertTrue(serialized.contains("- 8443"))
        XCTAssertTrue(serialized.contains("    - hostname: 'dev.example.com'"))
        XCTAssertTrue(serialized.contains("      service: 'http://127.0.0.1:3000'"))

        let reparsed = try CloudflaredConfigParser().parse(contents: serialized)
        XCTAssertEqual(reparsed.ingress.count, 2)
        XCTAssertTrue(reparsed.ingress[0].preservedLines.contains("          - 443"))
    }

    func testParserAndSerializerPreserveIngressAndRuleComments() throws {
        let input = """
        tunnel: sample-tunnel-id
        ingress: # 路由规则
          - hostname: dev.example.com # 预览域名
            service: 'http://127.0.0.1:3000#fragment' # 本地服务
          - service: http_status:404 # 兜底
        """

        let document = try CloudflaredConfigParser().parse(contents: input)
        XCTAssertEqual(document.ingress[0].service, "http://127.0.0.1:3000#fragment")

        let serialized = CloudflaredConfigSerializer().serialize(document)
        XCTAssertTrue(serialized.contains("ingress: # 路由规则"))
        XCTAssertTrue(serialized.contains("'dev.example.com' # 预览域名"))
        XCTAssertTrue(serialized.contains("'http://127.0.0.1:3000#fragment' # 本地服务"))
        XCTAssertTrue(serialized.contains("'http_status:404' # 兜底"))
    }

    func testUnknownFirstFieldRemainsInTheSameIngressRule() throws {
        let input = """
        ingress:
          - originRequest:
              connectTimeout: 5s
            hostname: advanced.example.com
            service: http://127.0.0.1:3000
          - service: http_status:404
        """

        let document = try CloudflaredConfigParser().parse(contents: input)
        XCTAssertEqual(document.ingress.count, 2)
        XCTAssertEqual(document.ingress[0].hostname, "advanced.example.com")
        XCTAssertEqual(document.ingress[0].service, "http://127.0.0.1:3000")

        let serialized = CloudflaredConfigSerializer().serialize(document)
        XCTAssertTrue(serialized.contains("  - hostname: 'advanced.example.com'"))
        XCTAssertTrue(serialized.contains("    service: 'http://127.0.0.1:3000'"))
        XCTAssertTrue(serialized.contains("    originRequest:"))
        XCTAssertFalse(serialized.contains("  - originRequest:"))

        let reparsed = try CloudflaredConfigParser().parse(contents: serialized)
        XCTAssertEqual(reparsed.ingress.count, 2)
        XCTAssertEqual(reparsed.ingress[0].hostname, "advanced.example.com")
        XCTAssertEqual(reparsed.ingress[0].service, "http://127.0.0.1:3000")
        XCTAssertTrue(reparsed.ingress[0].preservedLines.contains("    originRequest:"))
    }

    func testUnsupportedListItemAnchorIsRejectedInsteadOfBeingCorrupted() {
        let input = """
        ingress:
          - &route
            hostname: anchored.example.com
            service: http://127.0.0.1:3000
          - service: http_status:404
        """

        XCTAssertThrowsError(try CloudflaredConfigParser().parse(contents: input)) { error in
            guard case let ConfigParsingError.malformedIngress(message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("YAML 锚点"))
        }
    }

    func testDoubleQuotedYAMLEscapesKeepTheirMeaningAfterRoundTrip() throws {
        let input = #"""
        ingress:
          - hostname: "preview\u002Eexample.com"
            path: "^/items/\\d+\\.json$"
            service: "http:\/\/127.0.0.1:3000"
          - service: http_status:404
        """#

        let document = try CloudflaredConfigParser().parse(contents: input)
        XCTAssertEqual(document.ingress[0].hostname, "preview.example.com")
        XCTAssertEqual(document.ingress[0].path, "^/items/\\d+\\.json$")
        XCTAssertEqual(document.ingress[0].service, "http://127.0.0.1:3000")

        let serialized = CloudflaredConfigSerializer().serialize(document)
        let reparsed = try CloudflaredConfigParser().parse(contents: serialized)
        XCTAssertEqual(reparsed.ingress[0].hostname, document.ingress[0].hostname)
        XCTAssertEqual(reparsed.ingress[0].path, document.ingress[0].path)
        XCTAssertEqual(reparsed.ingress[0].service, document.ingress[0].service)
    }

    func testControlCharacterEscapesAreReencodedWithoutRawControlBytes() throws {
        let input = #"""
        ingress:
          - path: "^line\nbreak\0$"
            service: "http://127.0.0.1:3000/a\tb"
          - service: http_status:404
        """#

        let document = try CloudflaredConfigParser().parse(contents: input)
        XCTAssertEqual(document.ingress[0].path, "^line\nbreak\0$")
        XCTAssertEqual(document.ingress[0].service, "http://127.0.0.1:3000/a\tb")

        let serialized = CloudflaredConfigSerializer().serialize(document)
        XCTAssertFalse(serialized.contains("\0"))
        XCTAssertTrue(serialized.contains(#"path: "^line\nbreak\0$""#))
        XCTAssertTrue(serialized.contains(#"service: "http://127.0.0.1:3000/a\tb""#))

        let reparsed = try CloudflaredConfigParser().parse(contents: serialized)
        XCTAssertEqual(reparsed.ingress[0].path, document.ingress[0].path)
        XCTAssertEqual(reparsed.ingress[0].service, document.ingress[0].service)
    }

    func testStoreFollowsFileSymlinkWithoutReplacingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let targetDirectory = root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetURL = targetDirectory.appendingPathComponent("cloudflared.yml")
        let linkURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: targetURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: targetURL.path
        )
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: "actual/cloudflared.yml"
        )

        let store = CloudflaredConfigurationStore()
        var document = try store.load(from: linkURL)
        document.upsert(hostname: "admin.example.com", service: "http://127.0.0.1:4000")
        let result = try store.save(document, to: linkURL)

        let resourceValues = try linkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(resourceValues.isSymbolicLink, true)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
            "actual/cloudflared.yml"
        )
        XCTAssertEqual(result.destinationURL.standardizedFileURL, targetURL.standardizedFileURL)
        XCTAssertEqual(result.backupURL?.deletingLastPathComponent().lastPathComponent, "backups")
        XCTAssertEqual(try String(contentsOf: result.backupURL!), sample)
        XCTAssertTrue(try String(contentsOf: targetURL).contains("admin.example.com"))
        let mode = try FileManager.default.attributesOfItem(atPath: targetURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o640)
    }

    func testStoreRejectsChangesMadeAfterLoading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        let store = CloudflaredConfigurationStore()
        var document = try store.load(from: configURL)
        document.upsert(hostname: "admin.example.com", service: "http://127.0.0.1:4000")

        let externallyEdited = sample.replacingOccurrences(
            of: "dev.example.com",
            with: "changed-elsewhere.example.com"
        )
        try Data(externallyEdited.utf8).write(to: configURL, options: .atomic)

        XCTAssertThrowsError(try store.save(document, to: configURL)) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .fileChangedSinceLoad)
        }
        XCTAssertEqual(try String(contentsOf: configURL), externallyEdited)
    }

    func testStoreRefreshesSnapshotAfterItsOwnSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        let store = CloudflaredConfigurationStore()
        var document = try store.load(from: configURL)
        document.upsert(hostname: "first.example.com", service: "http://127.0.0.1:4000")
        try store.save(document, to: configURL)

        document.upsert(hostname: "second.example.com", service: "http://127.0.0.1:5000")
        try store.save(document, to: configURL)

        let saved = try String(contentsOf: configURL)
        XCTAssertTrue(saved.contains("first.example.com"))
        XCTAssertTrue(saved.contains("second.example.com"))
    }

    func testStoreRejectsBrokenConfigurationSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let linkURL = root.appendingPathComponent("config.yml")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: "missing.yml"
        )

        XCTAssertThrowsError(try CloudflaredConfigurationStore().load(from: linkURL)) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .symbolicLinkTargetUnavailable)
        }
    }

    @MainActor
    func testFailedPublishSurfacesValidationDetails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)

        let publishHostname = "private-publish.example.com"
        let publishService = "http://private-invalid-service.local:4321"
        let failureMessage = "Validation failed for \(publishHostname): \(publishService) is invalid"
        let defaultsName = "app.ihopeful.Tunnelful.publish-failure-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: FailingConfigurationValidator(message: failureMessage),
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)
        model.discardConfigurationDraft()
        await model.applyLocalPublish(
            tunnelName: "sample-tunnel-id",
            hostname: publishHostname,
            service: publishService
        )

        let rawAlert = try XCTUnwrap(model.alertMessage)
        XCTAssertTrue(rawAlert.contains(publishHostname))
        XCTAssertTrue(rawAlert.contains(publishService))
    }

    @MainActor
    func testLocalPublishUpdatesPathSpecificRuleWithoutAddingBroadHostnameRule() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        let pathSpecificConfiguration = """
        tunnel: previous-tunnel
        credentials-file: $HOME/.cloudflared/credentials.json

        ingress:
          - hostname: api.example.com
            path: ^/v1/(.*)$
            service: http://127.0.0.1:3000
          - service: http_status:404
        """
        try Data(pathSpecificConfiguration.utf8).write(to: configURL)

        let defaultsName = "app.ihopeful.Tunnelful.path-publish-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: SuccessfulConfigurationValidator(),
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)

        await model.applyLocalPublish(
            tunnelName: "previous-tunnel",
            hostname: "api.example.com",
            service: "http://127.0.0.1:4000",
            path: "^/v1/(.*)$"
        )

        let saved = try CloudflaredConfigurationStore().load(from: configURL)
        let matchingRules = saved.ingress.filter {
            $0.hostname?.caseInsensitiveCompare("api.example.com") == .orderedSame
        }
        XCTAssertEqual(saved.tunnel, "previous-tunnel")
        XCTAssertEqual(matchingRules.count, 1)
        XCTAssertEqual(matchingRules.first?.path, "^/v1/(.*)$")
        XCTAssertEqual(matchingRules.first?.service, "http://127.0.0.1:4000")
        XCTAssertFalse(saved.ingress.contains {
            $0.hostname?.caseInsensitiveCompare("api.example.com") == .orderedSame && $0.path == nil
        })
    }

    @MainActor
    func testLocalPublishRejectsTunnelThatDoesNotMatchConfigurationCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        let originalContents = try Data(contentsOf: configURL)
        let defaultsName = "app.ihopeful.Tunnelful.tunnel-credential-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: SuccessfulConfigurationValidator(),
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)

        await model.applyLocalPublish(
            tunnelName: "other-tunnel",
            hostname: "route.example.com",
            service: "http://127.0.0.1:3000"
        )

        XCTAssertEqual(try Data(contentsOf: configURL), originalContents)
        XCTAssertNil(model.pendingDNSPlan)
        XCTAssertNil(model.lastBackupURL)
        XCTAssertEqual(
            model.alertMessage,
            "所选 Tunnel 与当前配置的 tunnel / credentials-file 不匹配。请导入这个 Tunnel 的本地配置，避免把专属凭据配给其他 Tunnel。"
        )
    }

    @MainActor
    func testConsecutiveSavesCanChangeTunnelAndThenRestoreOriginalTunnel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        let defaultsName = "app.ihopeful.Tunnelful.tunnel-rebaseline-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: SuccessfulConfigurationValidator(),
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)

        var changedDocument = try XCTUnwrap(model.configDocument)
        changedDocument.tunnel = "replacement-tunnel"
        await model.saveStructuredConfiguration(changedDocument)
        XCTAssertEqual(try CloudflaredConfigurationStore().load(from: configURL).tunnel, "replacement-tunnel")

        var restoredDocument = try XCTUnwrap(model.configDocument)
        restoredDocument.tunnel = "sample-tunnel-id"
        await model.saveStructuredConfiguration(restoredDocument)

        let savedContents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(try CloudflaredConfigurationStore().load(from: configURL).tunnel, "sample-tunnel-id")
        XCTAssertEqual(
            savedContents.components(separatedBy: "\n").filter { $0.hasPrefix("tunnel:") }.count,
            1
        )
        XCTAssertEqual(model.configDocument?.tunnel, "sample-tunnel-id")
        XCTAssertNil(model.alertMessage)
    }

    @MainActor
    func testSynchronizingPublishFormFromSavedConfigurationKeepsDNSPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        let defaultsName = "app.ihopeful.Tunnelful.publish-sync-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: SuccessfulConfigurationValidator(),
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)

        await model.applyLocalPublish(
            tunnelName: "sample-tunnel-id",
            hostname: "route.example.com",
            service: "http://127.0.0.1:3000",
            path: "^/api/.*"
        )
        let plan = try XCTUnwrap(model.pendingDNSPlan)

        model.invalidatePublishPlanIfDraftChanged(
            tunnelName: "sample-tunnel-id",
            hostname: "route.example.com",
            service: "http://127.0.0.1:3000",
            path: "^/api/.*"
        )
        XCTAssertEqual(model.pendingDNSPlan, plan)

        model.invalidatePublishPlanIfDraftChanged(
            tunnelName: "sample-tunnel-id",
            hostname: "route.example.com",
            service: "http://127.0.0.1:4000",
            path: "^/api/.*"
        )
        XCTAssertNil(model.pendingDNSPlan)
    }

    @MainActor
    func testEditingOrSavingConfigurationInvalidatesPendingDNSPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        let markerURL = root.appendingPathComponent("dns-command-ran")
        let executableURL = root.appendingPathComponent("cloudflared-test")
        try Data(sample.utf8).write(to: configURL)
        try Data("#!/bin/sh\n/usr/bin/touch \"\(markerURL.path)\"\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executableURL.path
        )

        let defaultsName = "app.ihopeful.Tunnelful.dns-invalidation-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let installation = CloudflaredInstallation(
            executableURL: executableURL,
            version: "test",
            source: .custom
        )
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: SuccessfulConfigurationValidator(),
            initialInstallation: installation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)

        await model.applyLocalPublish(
            tunnelName: "sample-tunnel-id",
            hostname: "draft.example.com",
            service: "http://127.0.0.1:3000"
        )
        let draftPlan = try XCTUnwrap(model.pendingDNSPlan)
        var editedDraft = try XCTUnwrap(model.configurationDraft)
        editedDraft.upsert(hostname: "draft.example.com", service: "http://127.0.0.1:4000")
        model.configurationDraft = editedDraft

        XCTAssertNil(model.pendingDNSPlan)
        await model.routeDNS(draftPlan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        model.discardConfigurationDraft()
        await model.applyLocalPublish(
            tunnelName: "sample-tunnel-id",
            hostname: "saved.example.com",
            service: "http://127.0.0.1:5000"
        )
        let savePlan = try XCTUnwrap(model.pendingDNSPlan)
        var savedDocument = try XCTUnwrap(model.configDocument)
        savedDocument.upsert(hostname: "saved.example.com", service: "http://127.0.0.1:6000")
        await model.saveStructuredConfiguration(savedDocument)

        XCTAssertNil(model.pendingDNSPlan)
        await model.routeDNS(savePlan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @MainActor
    func testConfirmedDNSRouteRunsOnlyForTheCurrentSavedPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        let defaultsName = "app.ihopeful.Tunnelful.dns-route-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: SuccessfulConfigurationValidator(),
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)

        await model.applyLocalPublish(
            tunnelName: "sample-tunnel-id",
            hostname: "route.example.com",
            service: "http://127.0.0.1:3000"
        )
        let plan = try XCTUnwrap(model.pendingDNSPlan)
        XCTAssertTrue(plan.displayCommand.contains("route.example.com"))

        await model.routeDNS(plan)

        XCTAssertEqual(model.lastDNSRouteMessage, "DNS 路由已配置。")
        XCTAssertFalse(model.isRoutingDNS)

        model.invalidatePublishPlan()
        await model.routeDNS(plan)
        XCTAssertEqual(model.alertMessage, "发布内容已经变化，请重新保存本地配置后再配置 DNS 路由。")
    }

    @MainActor
    func testDNSRouteDoesNotRunAfterSavedConfigurationChangesOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        let markerURL = root.appendingPathComponent("dns-command-ran")
        let executableURL = root.appendingPathComponent("cloudflared-test")
        try Data(sample.utf8).write(to: configURL)
        try Data("#!/bin/sh\n/usr/bin/touch \"\(markerURL.path)\"\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executableURL.path
        )

        let defaultsName = "app.ihopeful.Tunnelful.dns-stale-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let installation = CloudflaredInstallation(
            executableURL: executableURL,
            version: "test",
            source: .custom
        )
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: SuccessfulConfigurationValidator(),
            initialInstallation: installation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)

        await model.applyLocalPublish(
            tunnelName: "sample-tunnel-id",
            hostname: "stale.example.com",
            service: "http://127.0.0.1:3000"
        )
        let plan = try XCTUnwrap(model.pendingDNSPlan)

        let externallyEdited = sample.replacingOccurrences(
            of: "dev.example.com",
            with: "changed-outside.example.com"
        )
        try Data(externallyEdited.utf8).write(to: configURL, options: .atomic)

        await model.routeDNS(plan)

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertNil(model.pendingDNSPlan)
        XCTAssertNil(model.lastDNSRouteMessage)
        XCTAssertEqual(
            model.alertMessage,
            "配置文件已在本地保存后被其他应用修改。DNS 路由未执行；请重新导入并保存后再试。"
        )
    }

    @MainActor
    func testTerminationRemovesOnlyActivePreviewAndNeverSavesLateValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        let unrelatedPreviewURL = root.appendingPathComponent(".unrelated.preview")
        try Data(sample.utf8).write(to: configURL)
        try Data("keep".utf8).write(to: unrelatedPreviewURL)

        let started = expectation(description: "official validation started")
        let validator = ControlledConfigurationValidator { started.fulfill() }
        let defaultsName = "app.ihopeful.Tunnelful.preview-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: validator,
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)
        var document = try XCTUnwrap(model.configDocument)
        document.upsert(hostname: "late.example.com", service: "http://127.0.0.1:4000")

        let saveTask = Task { await model.saveStructuredConfiguration(document) }
        await fulfillment(of: [started], timeout: 2)
        let previewURL = try XCTUnwrap(validator.previewURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path))
        let previewMode = try FileManager.default.attributesOfItem(atPath: previewURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(previewMode?.intValue, 0o600)

        XCTAssertTrue(model.beginTermination())

        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPreviewURL.path))

        let shutdownFinished = expectation(description: "configuration validation stopped")
        model.waitForConfigurationShutdown { shutdownFinished.fulfill() }
        validator.complete(with: .success("官方校验通过"))
        await fulfillment(of: [shutdownFinished], timeout: 2)
        await saveTask.value

        XCTAssertEqual(try String(contentsOf: configURL), sample)
        XCTAssertNil(model.alertMessage)
        XCTAssertNil(model.lastValidationMessage)
        XCTAssertFalse(model.isApplyingConfiguration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPreviewURL.path))
    }

    @MainActor
    func testTerminationRejectsNewTunnelRestartAndLoginWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultsName = "app.ihopeful.Tunnelful.termination-fence-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let processController = TunnelProcessController()
        let loginController = CloudflaredLoginController(
            inspector: EnvironmentInspector(homeDirectory: root)
        )
        let model = AppModel(
            processController: processController,
            loginController: loginController,
            initialInstallation: testInstallation,
            userDefaults: defaults
        )

        XCTAssertFalse(model.beginTermination())
        model.startTunnel(named: "late-start")
        model.restartTunnel(named: "late-restart")
        model.startOfficialLogin()

        XCTAssertEqual(processController.processState, .stopped)
        XCTAssertNil(processController.managedTunnelName)
        XCTAssertEqual(loginController.state, .idle)
        XCTAssertFalse(loginController.isRunning)
    }

    @MainActor
    func testTerminationPreventsLateStartupAutomationAfterBootstrap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markerURL = root.appendingPathComponent("tunnel-started")
        let executableURL = root.appendingPathComponent("cloudflared-test")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s\\n' 'cloudflared version 2026.9.1'
        elif [ "$1" = "tunnel" ] && [ "$2" = "list" ]; then
          printf '%s\\n' '[{"id":"demo-id","name":"demo","created_at":"2026-01-01T00:00:00Z","deleted_at":null,"connections":[]}]'
        else
          /usr/bin/touch "\(markerURL.path)"
        fi
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executableURL.path
        )

        let defaultsName = "app.ihopeful.Tunnelful.startup-termination-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: "startTunnelOnLaunch")
        defaults.set(executableURL.path, forKey: "preferredExecutablePath")

        let processController = TunnelProcessController()
        let model = AppModel(
            processController: processController,
            locator: ConfigurationLocator(homeDirectory: root, systemDirectories: []),
            environmentInspector: EnvironmentInspector(homeDirectory: root),
            userDefaults: defaults
        )

        XCTAssertFalse(model.beginTermination())
        await model.bootstrap(reportErrors: true)

        XCTAssertEqual(processController.processState, .stopped)
        XCTAssertNil(processController.managedTunnelName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @MainActor
    func testRepeatedTerminationSkipsASecondRiskConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)
        let defaultsName = "app.ihopeful.Tunnelful.repeated-termination-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let model = AppModel(
            processController: TunnelProcessController(),
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)
        var draft = try XCTUnwrap(model.configurationDraft)
        draft.upsert(hostname: "unsaved.example.com", service: "http://127.0.0.1:4000")
        model.configurationDraft = draft
        XCTAssertTrue(model.hasUnsavedConfigurationDraft)

        let delegate = AppDelegate()
        delegate.model = model
        delegate.isAwaitingProcessShutdown = true
        var confirmationCount = 0
        delegate.terminationRiskConfirmationOverride = { _, _ in
            confirmationCount += 1
            return false
        }

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        XCTAssertEqual(confirmationCount, 0)
    }

    @MainActor
    func testSuccessfulConfigurationSaveStillRemovesItsExactPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)

        let started = expectation(description: "official validation started")
        let validator = ControlledConfigurationValidator { started.fulfill() }
        let defaultsName = "app.ihopeful.Tunnelful.preview-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: validator,
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)
        var document = try XCTUnwrap(model.configDocument)
        document.upsert(hostname: "saved.example.com", service: "http://127.0.0.1:4000")

        let saveTask = Task { await model.saveStructuredConfiguration(document) }
        await fulfillment(of: [started], timeout: 2)
        let previewURL = try XCTUnwrap(validator.previewURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path))

        validator.complete(with: .success("官方校验完成"))
        await saveTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path))
        XCTAssertTrue(try String(contentsOf: configURL).contains("saved.example.com"))
        XCTAssertEqual(model.lastValidationMessage, "官方校验完成")
        XCTAssertNil(model.alertMessage)
        XCTAssertFalse(model.isApplyingConfiguration)
    }

    @MainActor
    func testTerminationSuppressesLateValidationFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.yml")
        try Data(sample.utf8).write(to: configURL)

        let started = expectation(description: "official validation started")
        let validator = ControlledConfigurationValidator { started.fulfill() }
        let defaultsName = "app.ihopeful.Tunnelful.preview-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: validator,
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: configURL)
        var document = try XCTUnwrap(model.configDocument)
        document.upsert(hostname: "never-saved.example.com", service: "http://127.0.0.1:4000")

        let saveTask = Task { await model.saveStructuredConfiguration(document) }
        await fulfillment(of: [started], timeout: 2)
        let previewURL = try XCTUnwrap(validator.previewURL)

        XCTAssertTrue(model.beginTermination())
        validator.complete(with: .failure(NSError(
            domain: "app.ihopeful.Tunnelful.preview-tests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "late validation failure"]
        )))
        await saveTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path))
        XCTAssertEqual(try String(contentsOf: configURL), sample)
        XCTAssertNil(model.alertMessage)
        XCTAssertFalse(model.isApplyingConfiguration)
    }

    @MainActor
    func testImportCannotReplaceConfigurationDuringValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstConfigURL = root.appendingPathComponent("first.yml")
        let secondConfigURL = root.appendingPathComponent("second.yml")
        let secondConfig = sample.replacingOccurrences(of: "dev.example.com", with: "second.example.com")
        try Data(sample.utf8).write(to: firstConfigURL)
        try Data(secondConfig.utf8).write(to: secondConfigURL)

        let started = expectation(description: "official validation started")
        let validator = ControlledConfigurationValidator { started.fulfill() }
        let defaultsName = "app.ihopeful.Tunnelful.import-lock-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            processController: TunnelProcessController(),
            configurationValidator: validator,
            initialInstallation: testInstallation,
            userDefaults: defaults
        )
        model.importConfiguration(at: firstConfigURL)
        var document = try XCTUnwrap(model.configDocument)
        document.upsert(hostname: "saved.example.com", service: "http://127.0.0.1:4000")

        let saveTask = Task { await model.saveStructuredConfiguration(document) }
        await fulfillment(of: [started], timeout: 2)
        model.importConfiguration(at: secondConfigURL)

        XCTAssertEqual(model.selectedConfigURL?.standardizedFileURL, firstConfigURL.standardizedFileURL)
        XCTAssertEqual(model.alertMessage, "正在校验并保存配置，请完成后再更换配置文件。")

        validator.complete(with: .success("官方校验完成"))
        await saveTask.value

        XCTAssertEqual(model.selectedConfigURL?.standardizedFileURL, firstConfigURL.standardizedFileURL)
        XCTAssertTrue(try String(contentsOf: firstConfigURL).contains("saved.example.com"))
        XCTAssertEqual(try String(contentsOf: secondConfigURL), secondConfig)
    }

    private var testInstallation: CloudflaredInstallation {
        CloudflaredInstallation(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            version: "test",
            source: .custom
        )
    }
}

private extension ConfigurationTests {
    func runTool(executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let combined = output.fileHandleForReading.readDataToEndOfFile()
            + error.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: combined, as: UTF8.self))
    }
}

private struct FailingConfigurationValidator: ConfigurationValidating {
    let message: String

    func validate(installation: CloudflaredInstallation, configURL: URL) async throws -> String {
        throw NSError(
            domain: "app.ihopeful.Tunnelful.privacy-tests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private struct SuccessfulConfigurationValidator: ConfigurationValidating {
    func validate(installation: CloudflaredInstallation, configURL: URL) async throws -> String {
        "官方校验完成"
    }
}

private final class ControlledConfigurationValidator: ConfigurationValidating, @unchecked Sendable {
    private let lock = NSLock()
    private let onStart: () -> Void
    private var continuation: CheckedContinuation<String, Error>?
    private var capturedPreviewURL: URL?

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
    }

    var previewURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return capturedPreviewURL
    }

    func validate(installation: CloudflaredInstallation, configURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            capturedPreviewURL = configURL
            self.continuation = continuation
            lock.unlock()
            onStart()
        }
    }

    func complete(with result: Result<String, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
