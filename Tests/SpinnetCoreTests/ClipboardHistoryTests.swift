import XCTest
@testable import SpinnetCore

final class ClipboardHistoryTests: XCTestCase {
    func testCollectionRequiresConsentAndPersistsOnlySubsequentChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = try ClipboardHistoryStore(fileURL: url, now: { now })
        try store.observe(changeCount: 1, content: .init(text: "before", type: .text), sourceName: "Notes", sourceBundleID: "com.apple.Notes")
        XCTAssertEqual(try store.query(dataTypes: ["text", "url"]).entries, [])
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        try store.observe(changeCount: 1, content: .init(text: "before", type: .text), sourceName: "Notes", sourceBundleID: "com.apple.Notes")
        try store.observe(changeCount: 2, content: .init(text: "https://example.com", type: .url), sourceName: "Safari", sourceBundleID: "com.apple.Safari")
        let restored = try ClipboardHistoryStore(fileURL: url, now: { now })
        let result = try restored.query(dataTypes: ["text", "url"])
        XCTAssertEqual(result.state, .collecting)
        XCTAssertEqual(result.entries.map(\.text), ["https://example.com"])
        XCTAssertEqual(result.entries.first?.sourceApplicationName, "Safari")
        XCTAssertEqual(result.entries.first?.sourceBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(result.entries.first?.copiedAt, now)
        XCTAssertEqual(result.entries.first?.contentType, .url)
    }
    func testQueryRechecksGrantAndFiltersDataWithoutControllingCollection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { now })
        let command = CommandDeclaration(id: CommandID("browse"), title: "Browse", execution: .javascript, script: "browse.js")
        let scope = PluginCapabilityScope(capability: .readClipboardHistory, commandIDs: [command.id], dataTypes: ["text"], includesExistingHostData: true)
        let manifest = try PluginManifest(id: PluginID("history"), name: "History", version: "1.0", capabilities: [.readClipboardHistory], capabilityScopes: [scope], commands: [command])
        let package = PluginPackage(rootURL: directory, manifest: manifest)
        let action = try ActionConfiguration(id: ActionID("browse"), pluginID: manifest.id, command: command, input: .null)
        let grants = PluginCapabilityGrantStore()
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false }, selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, clipboardHistoryProvider: { try store.query(dataTypes: $0, offset: $1) })
        let request = PluginRuntimeHostServiceRequest(invocationID: "i", actionID: action.id, requestID: "r", service: .readClipboardHistory, input: .null)
        func query() throws -> ClipboardHistorySnapshot {
            try JSONDecoder().decode(ClipboardHistorySnapshot.self, from: JSONEncoder().encode(broker.execute(request: request, for: package, action: action)))
        }
        XCTAssertThrowsError(try query())
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        try store.observe(changeCount: 1, content: .init(text: "retained before grant", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        try store.observe(changeCount: 2, content: .init(text: "https://example.com", type: .url), sourceName: "Safari", sourceBundleID: "safari")
        XCTAssertThrowsError(try query())
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .readClipboardHistory, scope: scope)
        XCTAssertEqual(try query().entries.map(\.text), ["retained before grant"])
        try store.applyControl(.configure(enabled: false, paused: false, retentionDays: 1))
        XCTAssertEqual(try query().state, .off)
        XCTAssertEqual(try query().entries.count, 1)
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version, capability: .readClipboardHistory, scope: scope)
        XCTAssertThrowsError(try query())
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .readClipboardHistory, scope: scope)
        now = now.addingTimeInterval(86_400)
        XCTAssertEqual(try query().entries, [])
    }

    func testPauseClearAndTurnOffDeleteDoNotReplayUncollectedClipboard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        func copy(_ count: Int) throws {
            try store.observe(changeCount: count, content: .init(text: "entry \(count)", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        }
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 7))
        try copy(1)
        try store.applyControl(.configure(enabled: true, paused: true, retentionDays: 7))
        try copy(2)
        XCTAssertEqual(try store.query(dataTypes: ["text"]).state, .paused)
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 7))
        try copy(2)
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries.map(\.text), ["entry 1"])
        try store.applyControl(.clear)
        try copy(2)
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries, [])
        try copy(3)
        try store.applyControl(.turnOff(deleteEntries: true))
        let restarted = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        XCTAssertEqual(try restarted.query(dataTypes: ["text"]).state, .off)
        XCTAssertEqual(try restarted.query(dataTypes: ["text"]).entries, [])
    }

    func testCurrentClipboardGrantDoesNotAuthorizeHistoryAndHistoryDoesNotReadCurrentClipboard() throws {
        let command = CommandDeclaration(id: CommandID("read"), title: "Read", execution: .javascript, script: "read.js")
        let currentScope = PluginCapabilityScope(capability: .readCurrentClipboard, commandIDs: [command.id], dataTypes: ["text"])
        let historyScope = PluginCapabilityScope(capability: .readClipboardHistory, commandIDs: [command.id], dataTypes: ["text"], includesExistingHostData: true)
        let manifest = try PluginManifest(id: PluginID("reader"), name: "Reader", version: "1", capabilities: [.readCurrentClipboard, .readClipboardHistory], capabilityScopes: [currentScope, historyScope], commands: [command])
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/reader"), manifest: manifest)
        let action = try ActionConfiguration(id: ActionID("read"), pluginID: manifest.id, command: command, input: .null)
        let grants = PluginCapabilityGrantStore()
        var reads = 0
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false }, selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, currentClipboardProvider: { reads += 1; return .init(text: "current", type: .text) })
        func request(_ service: PluginHostService) throws -> JSONValue {
            try broker.execute(request: .init(invocationID: "i", actionID: action.id, requestID: "r", service: service, input: .null), for: package, action: action)
        }
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .readCurrentClipboard, scope: currentScope)
        XCTAssertEqual(try request(.readCurrentClipboard), .object(["text": .string("current"), "type": .string("text")]))
        XCTAssertThrowsError(try request(.readClipboardHistory)) { XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.readClipboardHistory)) }
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version, capability: .readCurrentClipboard, scope: currentScope)
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .readClipboardHistory, scope: historyScope)
        XCTAssertThrowsError(try request(.readCurrentClipboard)) { XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.readCurrentClipboard)) }
        XCTAssertEqual(reads, 1)
    }

    func testLargeHistoryPagesRemainWithinThePublicProtocolLimitAndShorterRetentionExpiresImmediately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { now })
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 7))
        for count in 1...51 {
            try store.observe(changeCount: count, content: .init(text: String(repeating: "x", count: 65_536) + String(count), type: .text), sourceName: "Notes", sourceBundleID: "notes")
        }
        let first = try store.query(dataTypes: ["text"])
        XCTAssertLessThan(try JSONEncoder().encode(first).count, 1_048_576)
        let next = try XCTUnwrap(first.nextOffset)
        XCTAssertEqual(first.entries.count + (try store.query(dataTypes: ["text"], offset: next)).entries.count, 51)
        now = now.addingTimeInterval(2 * 86_400)
        XCTAssertFalse(try store.query(dataTypes: ["text"]).entries.isEmpty)
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries, [])
    }

    func testBundledHistoryCannotBeOverwrittenAndWinsOverAnOlderInstalledCopyAtStartup() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Plugins/ClipboardHistory.spinnetplugin")
        let loaded = try PluginManifestLoader.load(packageAt: source)
        let bundled = PluginPackage(rootURL: source, manifest: loaded.manifest, origin: .bundled)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grants = PluginCapabilityGrantStore()
        let oldRegistry = PluginRegistry()
        try PluginInstallationStore(directory: directory, registry: oldRegistry, grants: grants, persistGrants: {}).install(from: source)
        let registry = PluginRegistry()
        try registry.register(bundled)
        let installer = PluginInstallationStore(directory: directory, registry: registry, grants: grants, persistGrants: {})
        XCTAssertThrowsError(try installer.install(from: source))
        try installer.restore()
        XCTAssertEqual(registry.package(for: loaded.manifest.id)?.rootURL, source)
    }

}
