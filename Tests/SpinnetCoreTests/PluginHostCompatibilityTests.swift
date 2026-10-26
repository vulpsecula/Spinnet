import Foundation
import XCTest
@testable import SpinnetCore

final class PluginHostCompatibilityTests: XCTestCase {
    private let pluginID = PluginID("com.example.compatibility")

    private func manifest(_ range: String = HostCompatibility.current.rawValue, version: String = "1.0.0") throws -> PluginManifest {
        let command = CommandDeclaration(id: .init("compatibility.run"), title: "Run", execution: .javascript, script: "run.js")
        return try PluginManifest(hostCompatibility: HostCompatibility(range), id: pluginID, name: "Compatibility", version: version,
            capabilities: [.writeClipboard], capabilityScopes: [.init(capability: .writeClipboard, commandIDs: [command.id], dataTypes: ["text"])], commands: [command])
    }

    private func json(_ manifest: PluginManifest) throws -> [String: JSONValue] {
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(manifest)) else {
            throw ConfigurationError.invalidManifest("Expected manifest object")
        }
        return fields
    }

    private func data(_ fields: [String: JSONValue]) throws -> Data {
        try JSONEncoder().encode(JSONValue.object(fields))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func package(_ manifest: PluginManifest) throws -> URL {
        let root = try temporaryDirectory().appendingPathComponent("Compatibility.spinnetplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        try Data("null".utf8).write(to: root.appendingPathComponent("run.js"))
        return root
    }

    func testHostVersionBaselineAndNumericOrdering() throws {
        XCTAssertEqual(HostVersion.currentString, "1.0.0")
        XCTAssertEqual(HostVersion.current.rawValue, HostVersion.currentString)
        XCTAssertLessThan(try HostVersion("1.9.99"), try HostVersion("1.10.0"))
        XCTAssertLessThan(try HostVersion("1.10.99"), try HostVersion("2.0.0"))
        XCTAssertEqual(try JSONDecoder().decode(HostVersion.self, from: JSONEncoder().encode(HostVersion.current)), .current)
    }

    func testStrictHostVersionRejectsMalformedAndUnsupportedVersions() {
        for value in ["", "1", "1.0", "1.0.0.0", "01.0.0", "1.00.0", "1.0.01", "-1.0.0", "+1.0.0",
                      "1.0.0-beta.1", "1.0.0+build", "1.0.0 ", " 1.0.0", "1.0.0\n", "１.0.0", "١.0.0",
                      "18446744073709551616.0.0", "1.18446744073709551616.0", "1.0.18446744073709551616"] {
            XCTAssertThrowsError(try HostVersion(value), value)
        }
        XCTAssertNoThrow(try HostVersion("18446744073709551615.18446744073709551615.18446744073709551615"))
    }

    func testCaretRangeHasInclusiveMinimumAndExclusiveNextMajor() throws {
        let range = try HostCompatibility("^1.2.3")
        for value in ["1.2.3", "1.2.4", "1.99.0"] { XCTAssertTrue(range.contains(try HostVersion(value)), value) }
        for value in ["1.2.2", "0.99.99", "2.0.0", "2.1.0"] { XCTAssertFalse(range.contains(try HostVersion(value)), value) }
        XCTAssertEqual(try JSONDecoder().decode(HostCompatibility.self, from: JSONEncoder().encode(range)), range)
    }

    func testZeroMajorCaretBoundaries() throws {
        let minor = try HostCompatibility("^0.2.3")
        XCTAssertFalse(minor.contains(try HostVersion("0.2.2")))
        XCTAssertTrue(minor.contains(try HostVersion("0.2.3")))
        XCTAssertTrue(minor.contains(try HostVersion("0.2.999")))
        XCTAssertFalse(minor.contains(try HostVersion("0.3.0")))
        let patch = try HostCompatibility("^0.0.3")
        XCTAssertFalse(patch.contains(try HostVersion("0.0.2")))
        XCTAssertTrue(patch.contains(try HostVersion("0.0.3")))
        XCTAssertFalse(patch.contains(try HostVersion("0.0.4")))
        let zero = try HostCompatibility("^0.0.0")
        XCTAssertTrue(zero.contains(try HostVersion("0.0.0")))
        XCTAssertFalse(zero.contains(try HostVersion("0.0.1")))
    }

    func testExactRangeDoesNotAdmitOtherPatchOrMinorVersions() throws {
        let range = try HostCompatibility("1.2.3")
        XCTAssertTrue(range.contains(try HostVersion("1.2.3")))
        XCTAssertFalse(range.contains(try HostVersion("1.2.4")))
        XCTAssertFalse(range.contains(try HostVersion("1.3.0")))
        XCTAssertNil(range.exclusiveMaximum)
    }

    func testUnknownRangeSyntaxAndCaretOverflowAreRefused() {
        for value in ["*", "latest", ">=1.0.0", "~1.0.0", "^1", "^1.0", "^01.0.0", "^1.0.0-beta", "^1.0.0+build",
                      "1.x", "^1.0.0 || ^2.0.0", "1.0.0 - 2.0.0", "^ 1.0.0", " ^1.0.0", "^1.0.0 ",
                      "^18446744073709551615.0.0", "^0.18446744073709551615.0", "^0.0.18446744073709551615"] {
            XCTAssertThrowsError(try HostCompatibility(value), value)
        }
    }

    func testManifestDeclaresHostRangeAndRoundTripsWithoutLegacyKeys() throws {
        let original = try manifest()
        let fields = try json(original)
        XCTAssertEqual(original.hostCompatibility, .current)
        XCTAssertEqual(fields["engines"], .object(["spinnet": .string("^1.0.0")]))
        XCTAssertNil(fields["api_level"])
        XCTAssertNil(fields["candidate_contracts"])
        XCTAssertEqual(try PluginManifestLoader.decode(data(fields)), original)
    }

    func testManifestWithoutEnginesHasActionableMigrationMessage() throws {
        var fields = try json(manifest())
        fields.removeValue(forKey: "engines")
        XCTAssertThrowsError(try PluginManifestLoader.decode(data(fields))) {
            XCTAssertEqual($0 as? ConfigurationError, .invalidManifest(PluginManifest.compatibilityMigrationMessage))
            XCTAssertTrue($0.localizedDescription.contains("engines.spinnet"))
        }
    }

    func testLegacyDeclarationsAreRefusedEvenWhenNullEmptyOrAlongsideValidEngines() throws {
        for legacy in ["api_level", "candidate_contracts"] {
            for value in [JSONValue.null, .array([]), .object([:]), .string(""), .number(7)] {
                for keepEngines in [false, true] {
                    var fields = try json(manifest())
                    fields[legacy] = value
                    if !keepEngines { fields.removeValue(forKey: "engines") }
                    XCTAssertThrowsError(try PluginManifestLoader.decode(data(fields)), "\(legacy), \(value)") {
                        XCTAssertEqual($0 as? ConfigurationError, .invalidManifest(PluginManifest.compatibilityMigrationMessage))
                    }
                }
            }
        }
    }

    func testEnginesRequiresExactlyOneSupportedSpinnetRange() throws {
        for engines in [JSONValue.null, .array([]), .string("^1.0.0"), .object([:]),
                        .object(["spinnet": .null]), .object(["spinnet": .number(1)]),
                        .object(["spinnet": .string("* ")]), .object(["spinnet": .string("^1.0.0"), "other": .string("1.0.0")])] {
            var fields = try json(manifest()); fields["engines"] = engines
            XCTAssertThrowsError(try PluginManifestLoader.decode(data(fields)), "\(engines)")
        }
    }

    func testCompatibilityUsesInjectedHostVersionWithoutChoosingHistoricalMembers() throws {
        let current = PluginInterfaceContracts(hostVersion: try HostVersion("1.0.0"))
        let newer = PluginInterfaceContracts(hostVersion: try HostVersion("1.99.0"))
        let accepted = try manifest()
        try current.check(accepted, origin: .installed)
        try newer.check(accepted, origin: .bundled)
        XCTAssertEqual(current.members, newer.members)
        for member in current.members {
            XCTAssertEqual(current.permits(member, declaredBy: accepted), newer.permits(member, declaredBy: accepted))
        }
        XCTAssertThrowsError(try PluginInterfaceContracts(hostVersion: HostVersion("2.0.0")).check(accepted, origin: .installed))
    }

    func testIncompatibleReviewAndInstallFailBeforeCopyingOrRegistering() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Plugins")
        let registry = PluginRegistry()
        let store = PluginInstallationStore(directory: directory, registry: registry, grants: PluginCapabilityGrantStore(), persistGrants: {})
        let needed = try manifest("^2.0.0")
        let source = try package(needed)
        for operation in [{ _ = try store.review(source) }, { _ = try store.install(from: source) }] {
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual($0 as? UnsupportedPluginHostVersion, UnsupportedPluginHostVersion(requiredBy: needed))
            }
        }
        XCTAssertNil(registry.package(for: pluginID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCompatibleInstallSucceeds() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Plugins")
        let registry = PluginRegistry()
        let store = PluginInstallationStore(directory: directory, registry: registry, grants: PluginCapabilityGrantStore(), persistGrants: {})
        let accepted = try manifest()
        try store.install(from: package(accepted))
        XCTAssertEqual(registry.package(for: pluginID)?.manifest, accepted)
    }

    func testLegacyInstalledPackageIsRefusedAndItsStorageMenuAndGrantsSurviveReplacement() throws {
        let directory = try temporaryDirectory()
        let registry = PluginRegistry()
        let grants = PluginCapabilityGrantStore()
        let storage = PluginStorage(directory: directory.appendingPathComponent("Storage"))
        let installed = directory.appendingPathComponent("Plugins")
        let first = PluginInstallationStore(directory: installed, registry: registry, grants: grants, persistGrants: {}, storage: storage)
        let original = try manifest()
        let source = try package(original)
        try first.install(from: source)
        try storage.setValue(.number(3), forKey: "runs", of: pluginID)
        grants.setDecision(.granted, for: pluginID, pluginVersion: original.version, capability: .writeClipboard, scope: original.scope(for: .writeClipboard))
        let savedGrants = grants.allGrants
        let action = try ActionConfiguration(id: .init("saved-action"), pluginID: pluginID, command: original.commands[0], input: .string("saved input"))
        let item = try MenuItemConfiguration(primaryActionID: action.id, alias: "Saved alias")
        let configuration = try HostConfiguration(actions: [action], menu: MenuConfiguration(slots: [.empty, .occupied(item), .empty]))
        let savedMenu = try JSONEncoder().encode(configuration)
        let copies = try FileManager.default.contentsOfDirectory(at: installed, includingPropertiesForKeys: nil).filter { $0.pathExtension == "spinnetplugin" }
        let copy = try XCTUnwrap(copies.first)
        var fields = try json(original); fields.removeValue(forKey: "engines"); fields["api_level"] = .number(1)
        let legacyData = try data(fields)
        try legacyData.write(to: copy.appendingPathComponent("manifest.json"))
        let relaunched = PluginRegistry()
        let restored = PluginInstallationStore(directory: installed, registry: relaunched, grants: grants, persistGrants: {}, storage: storage)
        try restored.restore()
        let refusal = try XCTUnwrap(relaunched.refusedPlugin(pluginID))
        XCTAssertEqual(refusal.reason, ConfigurationError.invalidManifest(PluginManifest.compatibilityMigrationMessage).localizedDescription)
        XCTAssertNil(relaunched.package(for: pluginID))
        XCTAssertEqual(relaunched.availability(for: action), .unavailable(.pluginRefused(refusal.reason)))
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("manifest.json")), legacyData)
        XCTAssertEqual(try storage.value(forKey: "runs", of: pluginID), .number(3))
        XCTAssertEqual(grants.allGrants, savedGrants)
        XCTAssertEqual(try JSONDecoder().decode(HostConfiguration.self, from: savedMenu), configuration)
        try restored.install(from: source)
        XCTAssertEqual(try storage.value(forKey: "runs", of: pluginID), .number(3))
        XCTAssertEqual(relaunched.availability(for: action), .available)
        XCTAssertNil(relaunched.refusedPlugin(pluginID))
    }

    func testHistoricalBundledSnapshotsMigrateOnlyForEqualScopeGrantComparison() throws {
        let directory = try temporaryDirectory()
        let old = try manifest(version: "0.9.0"), current = try manifest(version: "1.0.0")
        var fields = try json(old); fields.removeValue(forKey: "engines"); fields["api_level"] = .number(1)
        fields["candidate_contracts"] = .array([])
        try data([pluginID.rawValue: .object(fields)]).write(to: directory.appendingPathComponent("bundled-manifests.json"))
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: pluginID, pluginVersion: old.version, capability: .writeClipboard, scope: old.scope(for: .writeClipboard))
        let registry = PluginRegistry()
        try registry.register(PluginPackage(rootURL: directory, manifest: current, origin: .bundled))
        var persisted = 0
        let store = PluginInstallationStore(directory: directory, registry: registry, grants: grants, persistGrants: { persisted += 1 })
        try store.restore()
        XCTAssertEqual(grants.decision(for: pluginID, pluginVersion: current.version, capability: .writeClipboard, scope: current.scope(for: .writeClipboard)), .granted)
        XCTAssertEqual(persisted, 1)
        let snapshots = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: directory.appendingPathComponent("bundled-manifests.json")))
        XCTAssertNil(snapshots[pluginID.rawValue]?.value(atPointer: "/api_level"))
        XCTAssertEqual(snapshots[pluginID.rawValue]?.value(atPointer: "/engines/spinnet"), .string("^1.0.0"))
        XCTAssertThrowsError(try PluginManifestLoader.decode(data(fields)), "The same old declaration remains forbidden as an executable package")
    }
}

extension PluginHostCompatibilityTests {
    private func savedAdapterConfiguration(_ adapter: HostCommand, input: JSONValue = .null,
                                           title: String = "Run", script: String? = nil,
                                           template: String? = nil) throws -> HostConfiguration {
        let command = CommandDeclaration(id: .init("saved.run"), title: title, execution: .host,
            isConfigurable: input != .null, hostCommand: adapter, script: script, deepLinkTemplate: template)
        let action = try ActionConfiguration(id: .init("saved-action"), pluginID: pluginID, command: command, input: input)
        let item = try MenuItemConfiguration(primaryActionID: action.id, alias: "My action")
        return try HostConfiguration(actions: [action], menu: MenuConfiguration(slots: [.empty, .occupied(item), .empty]))
    }
    private func currentAdapterManifest(_ service: String, fixedInput: JSONValue? = nil,
                                        title: String = "Run", template: String? = nil,
                                        pathKind: CommandConfigurationFieldKind? = nil) throws -> PluginManifest {
        let fields: [CommandConfigurationField] = template == nil ? [] : [
            .init(kind: .text, title: "Query", key: "query")
        ]
        let scopes: [PluginCapabilityScope] = template.map { template in [
            .init(capability: .controlExternalApp, commandIDs: [.init("saved.run")], externalApps: [
                .init(bundleID: "com.example.deep-links", name: "Example", deepLinkTemplates: [
                    .init(id: template, url: "example://open?q={query}", parameters: [.init(key: "query", kind: .text, maxLength: 100)])
                ])
            ])
        ] } ?? []
        return try PluginManifest(id: pluginID, name: "Compatibility", version: "1.0.0",
            capabilities: [.writeClipboard, .captureScreen] + (template == nil ? [] : [.controlExternalApp]), capabilityScopes: scopes,
            commands: [CommandDeclaration(id: .init("saved.run"), title: title, execution: .host,
                configurationField: pathKind.map { .init(kind: $0) },
                configurationFields: fields, deepLinkTemplate: template, hostServiceID: service, fixedInput: fixedInput)])
    }
    func testSavedAdapterMigrationPreservesBindingsInputAndIsIdempotent() throws {
        let folder = try temporaryDirectory()
        let file = folder.appendingPathComponent("saved-file.txt")
        try Data("saved file".utf8).write(to: file)
        let cases: [(HostCommand, JSONValue, String, JSONValue?)] = [
            (.copyText, .null, "selection.copy", nil),
            (.copyText, .string("saved text"), "clipboard.write", nil),
            (.openURL, .string("https://example.com"), "open.url", nil),
            (.openFile, .string(file.path), "open.path", nil),
            (.openFolder, .string(folder.path), "open.path", nil),
            (.openApplication, .string("com.apple.Safari"), "open.application", nil),
            (.invokeService, .string("Example Service"), "system.runService", nil),
            (.invokeShortcut, .string("Example Shortcut"), "system.runShortcut", nil),
            (.cutText, .null, "selection.cut", nil),
            (.pasteText, .null, "selection.paste", nil),
            (.presentFeedback, .string("Message"), "host.toast", nil),
            (.captureArea, .null, "screen.capture", .object(["source": .string("area")])),
            (.captureFullScreen, .null, "screen.capture", .object(["source": .string("fullscreen")])),
            (.captureWindow, .null, "screen.capture", .object(["source": .string("window")]))
        ]
        for (adapter, input, service, fixed) in cases {
            let saved = try savedAdapterConfiguration(adapter, input: input)
            let current = try currentAdapterManifest(service, fixedInput: fixed)
            XCTAssertFalse(current.commands[0].matchesExecutableDefinition(saved.actions[0].declaredCommand))
            let migrated = try XCTUnwrap(current.migrate(saved), adapter.rawValue)
            XCTAssertEqual(migrated.menu, saved.menu)
            XCTAssertEqual(migrated.actions.map(\.id), saved.actions.map(\.id))
            XCTAssertEqual(migrated.actions.map(\.input), saved.actions.map(\.input))
            XCTAssertEqual(migrated.actions[0].hostServiceID, service)
            XCTAssertTrue(current.commands[0].matchesExecutableDefinition(migrated.actions[0].declaredCommand))
            XCTAssertNil(try current.migrate(migrated), "\(adapter.rawValue) is migrated only once")
        }
    }
    func testSavedAdapterMigrationDoesNotSilentlyChangeTheOperationOrInput() throws {
        let selected = try savedAdapterConfiguration(.copyText)
        let fixedText = try currentAdapterManifest("clipboard.write", fixedInput: .object(["text": .string("new text")]))
        XCTAssertNil(try fixedText.migrate(selected), "Copying the selection cannot become copying a constant")
        let configured = try savedAdapterConfiguration(.copyText, input: .string("saved text"))
        XCTAssertNil(try currentAdapterManifest("selection.copy").migrate(configured), "A configured copy cannot start reading the selection")
        let screenshot = try savedAdapterConfiguration(.captureArea)
        XCTAssertNil(try currentAdapterManifest("screen.capture", fixedInput: .object(["source": .string("window")])).migrate(screenshot))
        XCTAssertNil(try currentAdapterManifest("open.url").migrate(screenshot))
        let url = try savedAdapterConfiguration(.openURL, input: .string("https://example.com"))
        XCTAssertNil(try currentAdapterManifest("open.url", title: "Different command").migrate(url))
        XCTAssertNil(try currentAdapterManifest("open.application").migrate(url))
    }
    func testDeepLinkAdapterMigrationRequiresTheSameDeclaredTemplateAndNoNewFixedInput() throws {
        let saved = try savedAdapterConfiguration(.openDeepLink, input: .object(["query": .string("saved")]), template: "open")
        XCTAssertNotNil(try currentAdapterManifest("apps.openDeepLink", template: "open").migrate(saved))
        XCTAssertNil(try currentAdapterManifest("apps.openDeepLink", template: "other").migrate(saved))
        XCTAssertNil(try currentAdapterManifest("apps.openDeepLink", fixedInput: .object(["parameters": .object(["query": .string("changed")])]),
            template: "open").migrate(saved))
    }
}

extension PluginHostCompatibilityTests {
    func testHistoricalRefusalMetadataCannotInheritFromAnotherIdentityOrInvalidManifest() throws {
        let original = try manifest(version: "0.9.0")
        let replacement = try manifest(version: "1.0.0")
        let invalid: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("changed identity", { $0["id"] = .string("com.example.other") }),
            ("empty identity", { $0["id"] = .string("") }),
            ("escaping script", { fields in
                guard case .array(var commands)? = fields["commands"], case .object(var command) = commands[0] else { return }
                command["script"] = .string("../escape.js"); commands[0] = .object(command); fields["commands"] = .array(commands)
            }),
            ("invalid engines retained", { $0["engines"] = .object(["spinnet": .string("*")]) })
        ]
        for (name, change) in invalid {
            let directory = try temporaryDirectory()
            let installed = directory.appendingPathComponent("Plugins")
            let root = installed.appendingPathComponent("legacy.spinnetplugin")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var fields = try json(original); fields["engines"] = nil; fields["api_level"] = .number(1)
            change(&fields)
            try data(fields).write(to: root.appendingPathComponent("manifest.json"))
            try JSONEncoder().encode([pluginID.rawValue: "legacy.spinnetplugin"]).write(to: installed.appendingPathComponent("installed.json"))
            let grants = PluginCapabilityGrantStore()
            grants.setDecision(.granted, for: pluginID, pluginVersion: original.version, capability: .writeClipboard, scope: original.scope(for: .writeClipboard))
            let registry = PluginRegistry()
            let store = PluginInstallationStore(directory: installed, registry: registry, grants: grants, persistGrants: {})
            try store.restore()
            XCTAssertNil(registry.package(for: pluginID), name)
            XCTAssertNil(registry.refusedPlugin(pluginID)?.manifest, name)
            XCTAssertEqual(try store.review(package(replacement)).requestedAccess, [.writeClipboard], name)
            XCTAssertEqual(grants.decision(for: pluginID, pluginVersion: original.version,
                capability: .writeClipboard, scope: original.scope(for: .writeClipboard)), .granted, name)
        }
    }
}


extension PluginHostCompatibilityTests {
    func testGenericPathMigrationRefusesWrongKindsAndMissingTargets() throws {
        let folder = try temporaryDirectory()
        let file = folder.appendingPathComponent("file.txt")
        try Data("file".utf8).write(to: file)
        let generic = try currentAdapterManifest("open.path")
        for (adapter, path) in [(HostCommand.openFile, folder.path), (.openFolder, file.path),
                                (.openFile, folder.appendingPathComponent("missing-file").path),
                                (.openFolder, folder.appendingPathComponent("missing-folder").path)] {
            let saved = try savedAdapterConfiguration(adapter, input: .string(path))
            XCTAssertNil(try generic.migrate(saved), "\(adapter.rawValue): \(path)")
            let registry = PluginRegistry()
            try registry.register(PluginPackage(rootURL: folder, manifest: generic))
            XCTAssertEqual(registry.availability(for: saved.actions[0]), .unavailable(.commandChanged),
                "An unproved conversion remains repairable and keeps the saved input")
        }
    }
    func testExplicitPathKindMigrationPreservesKindRefusalAndSavedInput() throws {
        let folder = try temporaryDirectory()
        let file = folder.appendingPathComponent("file.txt")
        try Data("file".utf8).write(to: file)
        for (adapter, kind, path) in [
            (HostCommand.openFile, CommandConfigurationFieldKind.file, folder.appendingPathComponent("missing-file").path),
            (.openFolder, .folder, folder.appendingPathComponent("missing-folder").path),
            (.openFile, .file, folder.path), (.openFolder, .folder, file.path)
        ] {
            let saved = try savedAdapterConfiguration(adapter, input: .string(path))
            let current = try currentAdapterManifest("open.path", pathKind: kind)
            let migrated = try XCTUnwrap(current.migrate(saved))
            XCTAssertEqual(migrated.menu, saved.menu)
            XCTAssertEqual(migrated.actions[0].id, saved.actions[0].id)
            XCTAssertEqual(migrated.actions[0].input, saved.actions[0].input)
            XCTAssertEqual(ActionResourceAvailability.missingReason(for: saved.actions[0]), .resourceMissing)
            XCTAssertEqual(ActionResourceAvailability.missingReason(for: migrated.actions[0], command: current.commands[0]), .resourceMissing)
            XCTAssertNil(try current.migrate(migrated))
        }
        let savedFile = try savedAdapterConfiguration(.openFile, input: .string(file.path))
        XCTAssertNil(try currentAdapterManifest("open.path", pathKind: .folder).migrate(savedFile))
        let savedFolder = try savedAdapterConfiguration(.openFolder, input: .string(folder.path))
        XCTAssertNil(try currentAdapterManifest("open.path", pathKind: .file).migrate(savedFolder))
    }
}
