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
    func testRestorationRebuildsEveryShownItemInItsOriginalFormats() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        let rtf = Data(#"{\rtf1 Hello}"#.utf8)
        try store.observe(changeCount: 1, contents: [
            .init(text: "Hello", type: .richText, data: rtf, format: "public.rtf", itemIndex: 0),
            .init(text: "Hello", type: .text, itemIndex: 0),
            .init(text: "https://example.com", type: .url, itemIndex: 1)
        ], sourceName: "TextEdit", sourceBundleID: "com.apple.TextEdit")
        let copyID = try XCTUnwrap(store.query(dataTypes: ["text", "url", "rich_text"]).copies.first?.id)

        let items = try store.restoration(copyID: copyID, dataTypes: ["text", "url", "rich_text"])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items[0].representations.map(\.format)), ["public.rtf", "public.utf8-plain-text"])
        XCTAssertEqual(items[0].representations.first { $0.format == "public.rtf" }?.data, rtf)
        XCTAssertEqual(items[1].representations.map(\.format), ["public.utf8-plain-text", "public.url"])

        // Types outside the Plugin's scope are never restored.
        let plain = try store.restoration(copyID: copyID, dataTypes: ["text"])
        XCTAssertEqual(plain.map { $0.representations.map(\.format) }, [["public.utf8-plain-text"]])
        XCTAssertThrowsError(try store.restoration(copyID: copyID, dataTypes: ["image"]))
        XCTAssertThrowsError(try store.restoration(copyID: UUID(), dataTypes: ["text"]))
    }

    func testDeleteRemovesWholeCopiesAndTheirPayloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        for (count, text) in ["one", "two", "three"].enumerated() {
            try store.observe(changeCount: count + 1, contents: [
                .init(text: text, type: .text, itemIndex: 0),
                .init(text: text, type: .richText, data: Data(text.utf8), format: "public.html", itemIndex: 0)
            ], sourceName: "Notes", sourceBundleID: "com.apple.Notes")
        }
        let copies = try store.query(dataTypes: ["text", "rich_text"]).copies
        XCTAssertEqual(copies.count, 3)
        let payloads = directory.appendingPathComponent("clipboard-payloads")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: payloads.path).count, 6)

        try store.applyControl(.delete(copyIDs: [copies[0].id, copies[2].id]))
        let remaining = try store.query(dataTypes: ["text", "rich_text"]).copies
        XCTAssertEqual(remaining.map(\.id), [copies[1].id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: payloads.path).count, 2)
        XCTAssertThrowsError(try store.restoration(copyID: copies[0].id, dataTypes: ["text"]))

        // Copying a deleted value again records it as a new copy.
        try store.observe(changeCount: 4, contents: [
            .init(text: "three", type: .text, itemIndex: 0),
            .init(text: "three", type: .richText, data: Data("three".utf8), format: "public.html", itemIndex: 0)
        ], sourceName: "Notes", sourceBundleID: "com.apple.Notes")
        XCTAssertEqual(try store.query(dataTypes: ["text"]).copies.count, 2)
    }

    /// Saving an edit replaces the copy with one plain-text representation in
    /// the same place, from the same App at the same time.
    func testSavingAnEditReplacesTheCopyWithPlainTextInPlace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { now })
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        try store.observe(changeCount: 1, content: .init(text: "older", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        try store.observe(changeCount: 2, contents: [
            .init(text: "Hello", type: .richText, data: Data(#"{\rtf1 Hello}"#.utf8), format: "public.rtf", itemIndex: 0),
            .init(text: "Hello", type: .text, itemIndex: 0)
        ], sourceName: "TextEdit", sourceBundleID: "com.apple.TextEdit")
        try store.observe(changeCount: 3, content: .init(text: "newer", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        let types = ["text", "url", "rich_text"]
        let before = try store.query(dataTypes: types).copies
        let edited = before[1]
        let payloads = directory.appendingPathComponent("clipboard-payloads")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: payloads.path).count, 4)

        now = now.addingTimeInterval(60)
        try store.applyControl(.replaceText(copyID: edited.id, text: "Hello, edited"))

        let after = try store.query(dataTypes: types).copies
        XCTAssertEqual(after.map(\.id), before.map(\.id), "the copy keeps its place")
        let entry = try XCTUnwrap(after[1].representations.first)
        XCTAssertEqual(after[1].representations.count, 1)
        XCTAssertEqual(entry.text, "Hello, edited")
        XCTAssertEqual(entry.contentType, .text)
        XCTAssertEqual(entry.sourceApplicationName, "TextEdit")
        XCTAssertEqual(entry.copiedAt, edited.representations[0].copiedAt)
        XCTAssertEqual(try store.restoration(copyID: edited.id, dataTypes: types).map { $0.representations.map(\.format) },
                       [["public.utf8-plain-text"]])
        XCTAssertEqual(try store.restoration(copyID: edited.id, dataTypes: types).first?.representations.first?.data,
                       Data("Hello, edited".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: payloads.path).count, 3,
                       "the rich text payload is gone")

        // Copying the edited text again finds the edited copy.
        try store.observe(changeCount: 4, content: .init(text: "Hello, edited", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        XCTAssertEqual(try store.query(dataTypes: types).copies.map(\.id), [edited.id, before[0].id, before[2].id])

        XCTAssertThrowsError(try store.applyControl(.replaceText(copyID: edited.id, text: "  \n")), "blank text is refused")
        XCTAssertThrowsError(try store.applyControl(.replaceText(copyID: UUID(), text: "gone")))
    }

    /// Saving an edit as new adds a copy in front and leaves the original.
    func testSavingAnEditAsNewAddsACopyInFront() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { now })
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        try store.observe(changeCount: 1, content: .init(text: "original", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        try store.observe(changeCount: 2, content: .init(text: "newer", type: .text), sourceName: "Safari", sourceBundleID: "safari")
        let before = try store.query(dataTypes: ["text"]).copies

        now = now.addingTimeInterval(60)
        try store.applyControl(.addText("original, edited", editedFrom: before[1].id))

        let after = try store.query(dataTypes: ["text"]).copies
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(Array(after.dropFirst()).map(\.id), before.map(\.id), "the original stays")
        let entry = try XCTUnwrap(after.first?.representations.first)
        XCTAssertEqual(entry.text, "original, edited")
        XCTAssertEqual(entry.sourceApplicationName, "Notes", "attributed to the copy it was edited from")
        XCTAssertEqual(entry.copiedAt, now)
        XCTAssertEqual(try store.restoration(copyID: after[0].id, dataTypes: ["text"]).first?.representations.first?.data,
                       Data("original, edited".utf8))

        // Text the history already holds brings that copy to the front instead.
        try store.applyControl(.addText("original", editedFrom: before[0].id))
        XCTAssertEqual(try store.query(dataTypes: ["text"]).copies.map(\.id), [before[1].id, after[0].id, before[0].id])
        XCTAssertThrowsError(try store.applyControl(.addText("", editedFrom: before[0].id)))
    }

    /// Images the pasteboard does not name are numbered in the order they
    /// were copied, one number per image whatever formats it came in, and a
    /// number is never given twice.
    func testUnnamedImagesAreNumberedOnceInTheOrderTheyWereCopied() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = try ClipboardHistoryStore(fileURL: url)
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        let unnamed = ClipboardContent.unnamedImageText
        func image(_ byte: UInt8, _ name: String = ClipboardContent.unnamedImageText) -> [ClipboardContent] {
            [.init(text: name, type: .image, data: Data([byte]), format: "public.png", itemIndex: 0),
             .init(text: name, type: .image, data: Data([byte, byte]), format: "public.tiff", itemIndex: 0)]
        }
        func names() throws -> [String] {
            try store.query(dataTypes: ["image"]).copies.map { Set($0.representations.map(\.text)).sorted().joined(separator: "|") }
        }
        try store.observe(changeCount: 1, contents: image(1), sourceName: "A", sourceBundleID: "a")
        try store.observe(changeCount: 2, contents: image(2, "Cat.png"), sourceName: "A", sourceBundleID: "a")
        try store.observe(changeCount: 3, contents: image(3), sourceName: "A", sourceBundleID: "a")
        XCTAssertEqual(try names(), ["\(unnamed) 2", "Cat.png", "\(unnamed) 1"])

        // Copying an image again keeps its number.
        try store.observe(changeCount: 4, contents: image(1), sourceName: "A", sourceBundleID: "a")
        XCTAssertEqual(try names(), ["\(unnamed) 1", "\(unnamed) 2", "Cat.png"])

        // A number is not given again after its image is gone.
        let first = try XCTUnwrap(store.query(dataTypes: ["image"]).copies.first?.id)
        try store.applyControl(.delete(copyIDs: [first]))
        try store.observe(changeCount: 5, contents: image(4), sourceName: "A", sourceBundleID: "a")
        XCTAssertEqual(try names(), ["\(unnamed) 3", "\(unnamed) 2", "Cat.png"])
        XCTAssertEqual(try ClipboardHistoryStore(fileURL: url).query(dataTypes: ["image"]).copies.first?.representations.first?.text,
                       "\(unnamed) 3", "numbers are kept across launches")
    }

    /// History kept before images were numbered is numbered once, oldest first.
    func testImagesKeptBeforeNumberingAreNumberedOldestFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = try ClipboardHistoryStore(fileURL: url, now: { now })
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        for byte in UInt8(1)...3 {
            now = now.addingTimeInterval(60)
            try store.observe(changeCount: Int(byte), contents: [
                .init(text: "Image", type: .image, data: Data([byte]), format: "public.png", itemIndex: 0)
            ], sourceName: "A", sourceBundleID: "a")
        }
        // Rewrite the archive as an older version left it: plain "Image" names
        // and no numbering record.
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        archive["lastImageNumber"] = nil
        archive["imageNumberingVersion"] = nil
        archive["entries"] = (archive["entries"] as? [[String: Any]])?.map { entry in
            var entry = entry
            entry["text"] = "Image"
            return entry
        }
        try JSONSerialization.data(withJSONObject: archive).write(to: url)

        let reopened = try ClipboardHistoryStore(fileURL: url, now: { now })
        XCTAssertEqual(try reopened.query(dataTypes: ["image"]).entries.map(\.text), ["Image 3", "Image 2", "Image 1"])
        now = now.addingTimeInterval(60)
        try reopened.observe(changeCount: 9, contents: [
            .init(text: "Image", type: .image, data: Data([9]), format: "public.png", itemIndex: 0)
        ], sourceName: "A", sourceBundleID: "a")
        XCTAssertEqual(try reopened.query(dataTypes: ["image"]).entries.first?.text, "Image 4")
    }

    func testAppendedPagesBrowseAsOneList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        for index in 0..<(ClipboardHistoryBudgets.maximumCopiesPerPage + 5) {
            try store.observe(changeCount: index + 1, content: .init(text: "copy \(index)", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        }
        let first = try store.query(dataTypes: ["text"])
        let next = try store.query(dataTypes: ["text"], offset: XCTUnwrap(first.nextOffset))
        let joined = first.appending(next)
        XCTAssertEqual(joined.copies.count, ClipboardHistoryBudgets.maximumCopiesPerPage + 5)
        XCTAssertNil(joined.nextOffset)
        XCTAssertEqual(joined.expiresAt, [first.expiresAt, next.expiresAt].compactMap { $0 }.min())
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
