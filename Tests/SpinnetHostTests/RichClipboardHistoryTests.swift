import AppKit
import XCTest
import ImageIO
import SwiftUI
import SpinnetCore
@testable import SpinnetHost

final class RichClipboardHistoryTests: XCTestCase {
    final class Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        var grants = PluginCapabilityGrantStore()
        final class Clock {
            var now = Date()
            var readStep: TimeInterval = 0
            func read() -> Date {
                defer { now = now.addingTimeInterval(readStep) }
                return now
            }
        }
        let clock: Clock
        var store: ClipboardHistoryStore
        var collector: ClipboardCollector!
        var source = (name: "Preview", bundleID: "com.apple.Preview")
        let command = CommandDeclaration(id: CommandID("browse"), title: "Browse", execution: .javascript, script: "browse.js")
        init(clock: Clock = Clock(), writeFile: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
            self.clock = clock
            store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { clock.read() }, writeFile: writeFile)
            try store.configure(enabled: true, paused: false, retentionDays: 1)
            collector = ClipboardCollector(store: store, changeCount: { [unowned self] in self.board.changeCount },
                readContents: { [unowned self] in ClipboardCollector.readAll(from: self.board) },
                sourceApplication: { [unowned self] in self.source })
            try collector.resetBaseline()
        }
        deinit { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        func package(types: [String], version: String = "1") throws -> PluginPackage {
            let scope = PluginCapabilityScope(capability: .readClipboardHistory, commandIDs: [command.id], dataTypes: types, includesExistingHostData: true)
            return PluginPackage(rootURL: directory, manifest: try PluginManifest(id: PluginID("reader"), name: "Reader", version: version,
                capabilities: [.readClipboardHistory], capabilityScopes: [scope], commands: [command]))
        }
        func grant(_ package: PluginPackage, decision: PluginCapabilityGrantDecision = .granted) {
            grants.setDecision(decision, for: package.manifest.id, pluginVersion: package.manifest.version,
                capability: .readClipboardHistory, scope: package.manifest.scope(for: .readClipboardHistory))
        }
        func request(_ package: PluginPackage, service: PluginHostService = .readClipboardHistory, input: JSONValue = .null) throws -> JSONValue {
            let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false }, selectedTextProvider: { "" }, clipboardWriter: { _ in },
                clipboardHistoryProvider: { [self] in try store.query(dataTypes: $0, offset: $1) },
                clipboardHistoryContentProvider: { [self] in try store.readContent(entryID: $0, dataTypes: $1, offset: $2, length: $3) })
            let action = try ActionConfiguration(id: ActionID("browse"), pluginID: package.manifest.id, command: command, input: .null)
            return try broker.execute(request: .init(invocationID: "i", actionID: action.id, requestID: "r", service: service, input: input), for: package, action: action)
        }
        func query(_ package: PluginPackage, offset: Int = 0) throws -> ClipboardHistorySnapshot {
            try JSONDecoder().decode(ClipboardHistorySnapshot.self, from: JSONEncoder().encode(request(package, input: .object(["offset": .number(Double(offset))]))))
        }
        func chunk(_ package: PluginPackage, id: UUID, offset: Int = 0, length: Int = 196_608) throws -> ClipboardHistoryContentChunk {
            try JSONDecoder().decode(ClipboardHistoryContentChunk.self, from: JSONEncoder().encode(request(package, service: .readClipboardHistoryContent,
                input: .object(["entry_id": .string(id.uuidString), "offset": .number(Double(offset)), "length": .number(Double(length))]))))
        }
        func restart() throws {
            let clock = self.clock
            store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { clock.read() })
            collector = ClipboardCollector(store: store, changeCount: { [unowned self] in self.board.changeCount },
                readContents: { [unowned self] in ClipboardCollector.readAll(from: self.board) },
                sourceApplication: { [unowned self] in self.source })
            try collector.resetBaseline()
        }
    }

    func testSlowCopyExpiresAtomicallyAndRecopyRestoresEveryRepresentation() throws {
        let clock = Harness.Clock()
        let h = try Harness(clock: clock, writeFile: { data, url in
            try data.write(to: url, options: .atomic)
            // Deterministic elapsed I/O time, not a wall-clock sleep.
            clock.now = clock.now.addingTimeInterval(10)
        })
        let package = try h.package(types: ["text", "rich_text", "binary"]); h.grant(package)
        func copy() throws {
            let item = NSPasteboardItem()
            item.setString("message", forType: .string)
            item.setData(Data(#"{\rtf1\ansi message}"#.utf8), forType: .rtf)
            item.setData(Data([0, 255, 42]), forType: .init("org.telegram.message"))
            h.board.clearContents(); h.board.writeObjects([item]); try h.collector.poll()
        }
        clock.readStep = 1
        try copy()
        clock.readStep = 0
        let original = try h.query(package)
        XCTAssertEqual(Set(original.entries.map(\.copiedAt)).count, 1, "A copy samples its timestamp once, despite slow representation writes")
        let formats = original.entries.compactMap(\.format).sorted()
        let deadline = try XCTUnwrap(original.entries.map(\.copiedAt).min()).addingTimeInterval(86_400)
        clock.now = deadline.addingTimeInterval(-0.5)
        XCTAssertEqual(try h.query(package).entries.compactMap(\.format).sorted(), formats)
        clock.now = deadline
        XCTAssertEqual(try h.query(package).entries, [], "No representation may outlive its copy")
        try copy()
        let recopied = try h.query(package)
        XCTAssertEqual(recopied.copies.count, 1)
        XCTAssertEqual(recopied.entries.compactMap(\.format).sorted(), formats, "Recopy must not deduplicate against a partially expired copy")
        for entry in recopied.entries {
            XCTAssertFalse(try h.chunk(package, id: entry.id).data.isEmpty)
        }
        let binary = try XCTUnwrap(recopied.entries.first { $0.contentType == .binary })
        XCTAssertEqual(try h.chunk(package, id: binary.id).data, Data([0, 255, 42]))
    }

    func testLegacyUnevenCopyTimesUseEarliestExpiryAndRecopyKeepsAllFormats() throws {
        let h = try Harness()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        h.clock.now = base
        func copy() throws {
            let item = NSPasteboardItem()
            item.setString("legacy grouped text", forType: .string)
            item.setData(Data([7, 8, 9]), forType: .init("org.telegram.message"))
            h.board.clearContents(); h.board.writeObjects([item]); try h.collector.poll()
        }
        try copy()
        let all = try h.package(types: ["text", "binary"]); h.grant(all)
        let original = try h.query(all)
        // Synthetic archive in the previously written shape: a slow copy gave
        // its binary representation a later timestamp, retaining the full hash.
        let archiveURL = h.directory.appendingPathComponent("history.json")
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any])
        var entries = try XCTUnwrap(fixture["entries"] as? [[String: Any]])
        for index in entries.indices {
            entries[index]["copiedAt"] = base.addingTimeInterval(entries[index]["contentType"] as? String == "binary" ? 10 : 0).timeIntervalSinceReferenceDate
        }
        entries.append(["id": UUID().uuidString, "text": "ungrouped legacy entry", "contentType": "text",
            "sourceApplicationName": "Notes", "sourceBundleIdentifier": "notes",
            "copiedAt": base.addingTimeInterval(5).timeIntervalSinceReferenceDate])
        fixture["entries"] = entries
        try JSONSerialization.data(withJSONObject: fixture).write(to: archiveURL)
        let deadline = base.addingTimeInterval(86_400)
        h.clock.now = deadline.addingTimeInterval(-0.5)
        try h.restart()
        let binary = try h.package(types: ["binary"]); h.grant(binary)
        let binaryPage = try h.query(binary)
        XCTAssertEqual(binaryPage.expiresAt, deadline, "Type filtering must not extend a legacy copy's visible lifetime")
        XCTAssertEqual(binaryPage.entries.first?.copiedAt, base)
        h.clock.now = deadline
        XCTAssertThrowsError(try h.chunk(binary, id: XCTUnwrap(binaryPage.entries.first).id))
        h.grant(all)
        XCTAssertEqual(try h.query(all).entries.map(\.text), ["ungrouped legacy entry"], "Whole grouped copy expires; unrelated old singleton keeps its own deadline")
        try copy()
        let recopied = try h.query(all).entries.filter { $0.copyID != nil }
        XCTAssertEqual(recopied.compactMap(\.format).sorted(), original.entries.compactMap(\.format).sorted())
        XCTAssertEqual(try h.chunk(all, id: XCTUnwrap(recopied.first { $0.contentType == .text }).id).data, Data("legacy grouped text".utf8))
        XCTAssertEqual(try h.chunk(all, id: XCTUnwrap(recopied.first { $0.contentType == .binary }).id).data, Data([7, 8, 9]))
        try h.restart()
        XCTAssertEqual(try h.query(all).entries.count, 3)
    }

    func testRecopyRepairsAnAlreadyPartiallyExpiredLegacyGroup() throws {
        let h = try Harness()
        func copy() throws {
            let item = NSPasteboardItem()
            item.setString("restore this format", forType: .string)
            item.setData(Data([4, 5, 6]), forType: .init("org.telegram.message"))
            h.board.clearContents(); h.board.writeObjects([item]); try h.collector.poll()
        }
        try copy()
        let package = try h.package(types: ["text", "binary"]); h.grant(package)
        let original = try h.query(package)
        // Previous versions could already have committed a partial group while
        // retaining its original complete-copy fingerprint. Lost bytes cannot be
        // recovered on load, but a fresh copy supplies them again.
        let archiveURL = h.directory.appendingPathComponent("history.json")
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any])
        let entries = try XCTUnwrap(fixture["entries"] as? [[String: Any]])
        fixture["entries"] = entries.filter { $0["contentType"] as? String == "binary" }
        try JSONSerialization.data(withJSONObject: fixture).write(to: archiveURL)
        try h.restart()
        XCTAssertEqual(try h.query(package).entries.count, 1)
        try copy()
        let restored = try h.query(package)
        XCTAssertEqual(restored.copies.count, 1, "Replace the incomplete match, not append another visible copy")
        XCTAssertEqual(restored.entries.compactMap(\.format).sorted(), original.entries.compactMap(\.format).sorted())
        let text = try XCTUnwrap(restored.entries.first { $0.contentType == .text })
        XCTAssertEqual(try h.chunk(package, id: text.id).data, Data("restore this format".utf8))
        try h.restart()
        XCTAssertEqual(try h.query(package).entries.count, 2)
    }

    func testVSCodeAuxiliaryMetadataIsFilteredButTelegramOpaquePayloadSurvives() throws {
        let h = try Harness()
        h.source = ("Visual Studio Code", "com.microsoft.VSCode")
        let item = NSPasteboardItem()
        item.setString("let answer = 42", forType: .string)
        item.setString("https://private.example/document", forType: .init("org.chromium.source-url"))
        item.setData(Data([1, 2, 3]), forType: .init("org.chromium.source-rfh-token"))
        h.board.clearContents(); h.board.writeObjects([item])
        try h.collector.poll(); try h.restart()
        let package = try h.package(types: ["text", "binary"]); h.grant(package)
        XCTAssertEqual(try h.query(package).entries.map(\.text), ["let answer = 42"])
        let opaque = NSPasteboardItem()
        opaque.setData(Data([0, 255, 42]), forType: .init("org.telegram.message"))
        h.board.clearContents(); h.board.writeObjects([opaque])
        h.source = ("Telegram", "ru.keepcoder.Telegram")
        try h.collector.poll()
        let entry = try XCTUnwrap(h.query(package).entries.first)
        XCTAssertEqual(try h.chunk(package, id: entry.id).data, Data([0, 255, 42]))
    }

    func testTelegramCopyGroupsRepresentationsAndDeduplicatesOnlyTheCompletePayload() throws {
        let h = try Harness()
        h.source = ("Telegram", "ru.keepcoder.Telegram")
        func copy(_ byte: UInt8) throws {
            let item = NSPasteboardItem()
            item.setString("A bold word", forType: .string)
            item.setData(Data("{\\rtf1\\ansi A \\b bold\\b0 word}".utf8), forType: .rtf)
            item.setData(Data([byte]), forType: .init("org.telegram.message"))
            h.board.clearContents(); h.board.writeObjects([item]); try h.collector.poll()
        }
        let all = try h.package(types: ["text", "rich_text", "binary"]); h.grant(all)
        try copy(1)
        let first = try h.query(all)
        XCTAssertEqual(first.copies.count, 1)
        XCTAssertEqual(Set(first.copies.first?.representations.map(\.contentType.rawValue) ?? []), ["text", "rich_text", "binary"])
        try copy(2)
        XCTAssertEqual(try h.query(all).copies.count, 2, "Same text with different opaque bytes is a different copy")
        h.clock.now = h.clock.now.addingTimeInterval(10)
        h.source = ("Telegram Beta", "ru.keepcoder.TelegramBeta")
        try copy(1)
        let repeated = try h.query(all)
        XCTAssertEqual(repeated.copies.count, 2)
        XCTAssertEqual(repeated.copies.first?.id, first.copies.first?.id)
        XCTAssertEqual(repeated.entries.first?.copiedAt, h.clock.now)
        XCTAssertEqual(repeated.entries.first?.sourceBundleIdentifier, "ru.keepcoder.TelegramBeta")
        try h.restart()
        XCTAssertEqual(try h.query(all).copies.count, 2)
        h.clock.now = h.clock.now.addingTimeInterval(10)
        try copy(1)
        XCTAssertEqual(try h.query(all).copies.count, 2, "Persisted fingerprints still deduplicate after restart")
        XCTAssertEqual(try h.query(all).copies.first?.id, first.copies.first?.id)
        let text = try h.package(types: ["text"]); h.grant(text)
        XCTAssertEqual(try h.query(text).copies.count, 2)
        XCTAssertTrue(try h.query(text).entries.allSatisfy { $0.contentType == .text })
        let richID = try XCTUnwrap(repeated.entries.first { $0.contentType == .richText }?.id)
        XCTAssertThrowsError(try h.chunk(text, id: richID))
    }

    func testOfflineRichPreviewsClassifyMarkdownWithoutExposingResources() throws {
        let h = try Harness()
        let item = NSPasteboardItem()
        item.setData(Data(#"{\rtf1\ansi Hello \b world\b0\par {\*\objdata private-object}Done}"#.utf8), forType: .rtf)
        h.board.clearContents(); h.board.writeObjects([item]); try h.collector.poll()
        let rich = try h.package(types: ["rich_text"]); h.grant(rich)
        XCTAssertEqual(try h.query(rich).entries.first { $0.format == "public.rtf" }?.text, "Hello world\nDone")
        h.board.clearContents()
        h.board.setData(Data(#"<html><head><style>secret-style</style></head><body><p>Hello <b>world</b> &amp; friends</p><img src="https://remote.invalid/pixel"><script>secret-script</script></body></html>"#.utf8), forType: .html)
        try h.collector.poll()
        XCTAssertEqual(try h.query(rich).entries.first?.text, "Hello world & friends\n")
        let markdown = "# Title\n\n**bold** ![alt](https://remote.invalid/image)"
        h.board.clearContents(); h.board.setString(markdown, forType: .string); try h.collector.poll()
        let entry = try XCTUnwrap(h.query(rich).entries.first)
        XCTAssertEqual(try h.query(rich).copies.count, 3)
        XCTAssertEqual(entry.contentType, .richText)
        XCTAssertEqual(entry.format, "net.daringfireball.markdown")
        XCTAssertEqual(try h.chunk(rich, id: entry.id).data, Data(markdown.utf8))
        let text = try h.package(types: ["text"]); h.grant(text)
        XCTAssertFalse(try h.query(text).entries.contains { $0.text == markdown })
        XCTAssertThrowsError(try h.chunk(text, id: entry.id))
        XCTAssertEqual(ClipboardCollector.readCurrent(from: h.board)?.type, .text)
        XCTAssertEqual(ClipboardCollector.readCurrent(from: h.board)?.text, markdown)
    }

    func testMarkdownClassificationIsConservativeAndExplicitMarkdownKeepsCurrentClipboardTextContract() throws {
        let h = try Harness()
        let cases: [(String, ClipboardContent.ContentType)] = [
            ("# Heading", .richText), ("**bold**", .richText), ("```swift\nlet a = 1\n```", .richText),
            ("- ordinary list\n- another item", .text), ("a * b; 2 ** 3", .text),
            (#"\**escaped**"#, .text), ("**not bold **", .text), ("```unclosed", .text),
            (String(repeating: "x", count: 16_384) + "\n# Not scanned", .text)
        ]
        let all = try h.package(types: ["text", "rich_text"]); h.grant(all)
        for (source, expected) in cases {
            h.board.clearContents(); h.board.setString(source, forType: .string); try h.collector.poll()
            XCTAssertEqual(try h.query(all).entries.first?.contentType, expected)
        }
        for format in ["net.daringfireball.markdown", "public.markdown"] {
            h.board.clearContents(); h.board.setString("    **Explicit**\n", forType: .init(format)); try h.collector.poll()
            let entry = try XCTUnwrap(h.query(all).entries.first)
            XCTAssertEqual(entry.contentType, .richText)
            XCTAssertEqual(ClipboardCollector.readCurrent(from: h.board)?.type, .text)
            XCTAssertEqual(entry.text, "    **Explicit**\n", "Source indentation must not change Markdown semantics")
            XCTAssertEqual(ClipboardCollector.readCurrent(from: h.board)?.text, "    **Explicit**\n")
        }
    }

    func testAuthorizedPlainPreferenceNeverCrossesItemsOrTypeGrants() throws {
        let h = try Harness()
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setData(Data("<p>Decoded first</p>".utf8), forType: .html)
        second.setData(Data("<p>Decoded second</p>".utf8), forType: .html)
        second.setString("Authorized second\nnext\n", forType: .string)
        h.board.clearContents(); h.board.writeObjects([first, second]); try h.collector.poll()
        let all = try h.package(types: ["text", "rich_text"]); h.grant(all)
        let rich = try h.package(types: ["rich_text"]); h.grant(rich)
        let text = try h.package(types: ["text"]); h.grant(text)
        h.grant(all)
        let copy = try XCTUnwrap(h.query(all).copies.first)
        let presentation = ClipboardHistoryCopyPresentation(copy: copy)
        let firstEntry = try XCTUnwrap(copy.representations.first { $0.itemIndex == 0 })
        let secondEntry = try XCTUnwrap(copy.representations.first { $0.itemIndex == 1 && $0.contentType == .richText })
        XCTAssertEqual(presentation.text(for: firstEntry), "Decoded first\n")
        XCTAssertEqual(presentation.text(for: secondEntry), "Authorized second\nnext\n")
        h.grant(rich)
        let richCopy = try XCTUnwrap(h.query(rich).copies.first)
        let richPresentation = ClipboardHistoryCopyPresentation(copy: richCopy)
        XCTAssertEqual(richPresentation.text(for: secondEntry), "Decoded second\n")
        h.grant(text)
        XCTAssertTrue(try h.query(text).entries.allSatisfy { $0.contentType == .text })
        XCTAssertThrowsError(try h.chunk(text, id: firstEntry.id))
        let plain = try XCTUnwrap(copy.representations.first { $0.contentType == .text })
        h.grant(rich)
        XCTAssertThrowsError(try h.chunk(rich, id: plain.id))
    }

    func testBudgetTruncationPreservesValidEncodingPrefixesInNewAndLegacyPreviews() throws {
        let h = try Harness()
        let rich = try h.package(types: ["rich_text"]); h.grant(rich)
        let expected = String(repeating: "a", count: 2_048)
        let htmlUTF8 = Data(("<p>" + String(repeating: "a", count: 196_604) + "你</p>").utf8)
        let gbkHeader = Data("<meta charset=gbk><p>".utf8)
        let gbk = gbkHeader + Data(repeating: 97, count: 196_607 - gbkHeader.count) + Data([0xc4, 0xe3]) + Data("</p>".utf8)
        let utf16Source = "<p>" + String(repeating: "a", count: 98_299) + "😀</p>"
        let rtfHeader = #"{\rtf1\ansi\ansicpg936{\*\comment "#
        let rtfTailPrefix = #"}abc\'c4\'"#
        let rtfInputBoundary = Data((rtfHeader + String(repeating: " ", count: 196_608 - rtfHeader.utf8.count - rtfTailPrefix.utf8.count) + rtfTailPrefix + "e3}").utf8)
        let fixtures: [(NSPasteboard.PasteboardType, Data, String)] = [
            (.html, htmlUTF8, expected),
            (.rtf, rtfInputBoundary, "abc"),
            (.rtf, Data((#"{\rtf1 "# + String(repeating: "a", count: 8_191) + #"\u-10179?\u-8704?}"#).utf8), expected),
            (.rtf, Data(#"{\rtf1\ansi\ansicpg936 abc\'c4}"#.utf8), "Rich text"),
            (.rtf, Data(#"{\rtf1 abc\u-10179?}"#.utf8), "Rich text"),
            (.rtf, Data(#"{\rtf1\ansi\ansicpg65001 "#.utf8) + Data([0xff]) + Data(repeating: 97, count: 8_190) + Data("你}".utf8), "Rich text"),
            (.html, Data([0xef, 0xbb, 0xbf]) + Data(("<p>" + String(repeating: "a", count: 196_601) + "你</p>").utf8), expected),
            (.html, Data([0xff, 0xfe]) + utf16Source.data(using: .utf16LittleEndian)!, expected),
            (.html, Data([0xfe, 0xff]) + utf16Source.data(using: .utf16BigEndian)!, expected),
            (.html, gbk, expected),
            (.rtf, Data(#"{\rtf1\ansi\ansicpg65001 "#.utf8) + Data(repeating: 97, count: 8_191) + Data("你}".utf8), expected),
            (.rtf, Data(#"{\rtf1\ansi\ansicpg936 "#.utf8) + Data(repeating: 97, count: 8_191) + Data([0xc4, 0xe3, 125]), expected),
            (.rtf, Data((#"{\rtf1\ansi\ansicpg936 "# + String(repeating: "a", count: 8_191) + #"\'c4\'e3}"#).utf8), expected),
            // An internal malformed byte must not become acceptable merely because the input is capped.
            (.html, Data("<p>".utf8) + Data([0xff]) + Data(repeating: 97, count: 196_603) + Data("你</p>".utf8), "Rich text"),
            (.html, gbkHeader + Data([0xc4, 0x20]) + Data(repeating: 97, count: 196_605 - gbkHeader.count) + Data([0xc4, 0xe3]), "Rich text"),
            (.html, Data([0xff, 0xfe, 0x00, 0xdc]) + Data(repeating: 0x61, count: 196_602) + Data([0x3d, 0xd8, 0x00, 0xde]), "Rich text"),
            // Incomplete *original* inputs are corrupt, not budget truncations.
            (.html, Data("<p>valid".utf8) + Data([0xe4]), "Rich text"),
            (.html, Data([0xff, 0xfe, 0x61, 0x00, 0x3d, 0xd8]), "Rich text"),
            (.html, gbkHeader + Data([0xc4]), "Rich text")
        ]
        var expectations: [UUID: String] = [:]
        for (format, payload, text) in fixtures {
            h.board.clearContents(); h.board.setData(payload, forType: format); try h.collector.poll()
            let entry = try XCTUnwrap(h.query(rich).entries.first)
            XCTAssertEqual(entry.text, text, "format: \(format.rawValue), bytes: \(payload.count)")
            XCTAssertEqual(try h.chunk(rich, id: entry.id).data, Data(payload.prefix(196_608)))
            expectations[entry.id] = text
        }
        let url = h.directory.appendingPathComponent("history.json")
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(archive["entries"] as? [[String: Any]])
        for index in entries.indices { entries[index]["text"] = "Old preview" }
        archive["entries"] = entries
        archive.removeValue(forKey: "plainPreviewVersion")
        archive.removeValue(forKey: "markdownClassificationVersion")
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        try h.restart()
        var snapshot: ClipboardHistorySnapshot?
        for _ in 0..<200 {
            snapshot = try? h.query(rich)
            if snapshot != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let refreshed = try XCTUnwrap(snapshot)
        XCTAssertEqual(refreshed.entries.count, expectations.count)
        for entry in refreshed.entries { XCTAssertEqual(entry.text, expectations[entry.id]) }
    }

    func testRichOnlyDeterministicEncodingsAndLineBreaksRetainPayloads() throws {
        let h = try Harness()
        let rich = try h.package(types: ["rich_text"]); h.grant(rich)
        let html = "<p>你好😀<br>second</p><p>third</p>"
        let attributed = NSAttributedString(string: "你好😀\nsecond\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        let exportedRTF = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let fixtures: [(NSPasteboard.PasteboardType, Data, String)] = [
            (.rtf, exportedRTF, "你好😀\nsecond\n"),
            (.rtf, Data(#"{\rtf1\ansi\uc1\u20320\~\u22909\~\par}"#.utf8), "你好\n"),
            (.rtf, Data(#"{\rtf1\ansi{\fonttbl{\f0\fcharset134 SimSun;}}\f0 \'c4\'e3\'ba\'c3}"#.utf8), "Rich text"),
            (.html, Data([0xef, 0xbb, 0xbf]) + Data(html.utf8), "你好😀\nsecond\nthird\n"),
            (.html, Data([0xfe, 0xff]) + html.data(using: .utf16BigEndian)!, "你好😀\nsecond\nthird\n"),
            (.html, Data("<meta charset=gbk><p>".utf8) + Data([0xc4, 0xe3, 0xba, 0xc3]) + Data("</p>".utf8), "你好\n"),
            (.html, Data("<p>&#20320;&#x597d;&#x1F600;&amp;lt;</p><script src='https://remote.invalid'>hidden</script>".utf8), "你好😀&lt;\n"),
            (.rtf, Data(#"{\rtf1\ansi\ansicpg65001 "#.utf8) + Data("你好😀".utf8) + Data(#"\par}"#.utf8), "你好😀\n"),
            (.rtf, Data(#"{\rtf1\ansi\ansicpg99999 \'c4\'e3}"#.utf8), "Rich text"),
            (.html, Data(html.utf8), "你好😀\nsecond\nthird\n"),
            (.html, Data([0xff, 0xfe]) + html.data(using: .utf16LittleEndian)!, "你好😀\nsecond\nthird\n"),
            (.rtf, Data(#"{\rtf1\ansi\ansicpg936 \'c4\'e3\'ba\'c3\par second\line third\par}"#.utf8), "你好\nsecond\nthird\n"),
            (.rtf, Data(#"{\rtf1\ansi\uc2\u20320\'c4\'e3\u22909\'ba\'c3\uc1\u-10179?\u-8704?\par}"#.utf8), "你好😀\n"),
            (.html, Data([0xff, 0xfe, 0xff]), "Rich text")
        ]
        for (format, data, expected) in fixtures {
            h.board.clearContents(); h.board.setData(data, forType: format); try h.collector.poll()
            let copy = try XCTUnwrap(h.query(rich).copies.first)
            let entry = try XCTUnwrap(copy.representations.first)
            XCTAssertEqual(ClipboardHistoryCopyPresentation(copy: copy).text(for: entry), expected)
            XCTAssertEqual(try h.chunk(rich, id: entry.id).data, data)
        }
    }

    func testAuthorizedCopyPresentationUsesPlainTextAndStackedFiles() throws {
        let h = try Harness()
        let item = NSPasteboardItem()
        item.setString("A bold word", forType: .string)
        item.setData(Data(#"{\rtf1 A \b bold\b0  word}"#.utf8), forType: .rtf)
        item.setData(Data("<b>A bold word</b>".utf8), forType: .html)
        item.setData(Data([0, 1, 2]), forType: .rtfd)
        h.board.clearContents(); h.board.writeObjects([item]); try h.collector.poll()
        let all = try h.package(types: ["text", "rich_text", "file_reference"]); h.grant(all)
        let copy = try XCTUnwrap(h.query(all).copies.first)
        let primary = try XCTUnwrap(ClipboardHistoryCopyPresentation(copy: copy).primary)
        XCTAssertEqual(primary.contentType, .richText)
        XCTAssertEqual(primary.format, "public.rtf")
        let rich = ClipboardHistoryTextPresentation(entry: primary)
        XCTAssertEqual(rich.typeLabel, "Rich text")
        XCTAssertEqual(rich.text, "A bold word")
        XCTAssertNil(primary.richTextPreview)
        let plain = try XCTUnwrap(copy.representations.first { $0.contentType == .text })
        XCTAssertEqual(ClipboardHistoryTextPresentation(entry: plain).typeLabel, "Text")
        h.board.clearContents(); h.board.setString("**Markdown bold**", forType: .string); try h.collector.poll()
        let markdown = ClipboardHistoryTextPresentation(entry: try XCTUnwrap(h.query(all).entries.first))
        XCTAssertEqual(markdown.text, "**Markdown bold**")
        let files = [h.directory.appendingPathComponent("a.txt"), h.directory.appendingPathComponent("b.txt"), h.directory.appendingPathComponent("c.txt")]
        for file in files { try Data("fixture".utf8).write(to: file) }
        h.board.clearContents(); h.board.writeObjects(files.map { $0 as NSURL }); try h.collector.poll()
        let presentation = ClipboardHistoryCopyPresentation(copy: try XCTUnwrap(h.query(all).copies.first))
        XCTAssertEqual(presentation.fileCount, 3)
        XCTAssertEqual(presentation.fileTitle, "3 files")
        XCTAssertEqual(presentation.fileOverview, "a.txt\nb.txt\nc.txt")
        XCTAssertEqual(presentation.fileIcon, "doc.on.doc")
        XCTAssertEqual(presentation.expandedRepresentations.filter { $0.contentType == .fileReference }.map(\.text), ["a.txt", "b.txt", "c.txt"])
        XCTAssertTrue(presentation.shownSummary.hasPrefix("Shown:"))
        let textOnly = try h.package(types: ["text"]); h.grant(textOnly)
        XCTAssertFalse(try h.query(textOnly).copies.contains { ClipboardHistoryCopyPresentation(copy: $0).fileCount > 0 })
    }

    func testLegacyMarkdownUsesOriginalBoundedPayloadAndMigratesPermissionsIdempotently() throws {
        let h = try Harness()
        let sources = ["# Old heading", String(repeating: "x", count: 3_000) + "\n# Beyond preview",
            String(repeating: "x", count: 16_384) + "\n# Beyond classification", "a * b; 2 ** 3; ordinary prose"]
        for source in sources {
            h.board.clearContents(); h.board.setString(source, forType: .string); try h.collector.poll()
        }
        let url = h.directory.appendingPathComponent("history.json")
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(archive["entries"] as? [[String: Any]])
        for index in entries.indices {
            entries[index]["contentType"] = "text"
            entries[index]["format"] = "public.utf8-plain-text"
        }
        // Pre-payload archive: full source is stored inline, not a display preview.
        entries.append(["id": UUID().uuidString, "text": "**Inline bold**", "contentType": "text",
            "sourceApplicationName": "Fixture", "sourceBundleIdentifier": "fixture", "copiedAt": h.clock.now.timeIntervalSinceReferenceDate])
        archive["entries"] = entries
        archive.removeValue(forKey: "markdownClassificationVersion")
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        try h.restart()
        let rich = try h.package(types: ["rich_text"]); h.grant(rich)
        var snapshot: ClipboardHistorySnapshot?
        for _ in 0..<100 {
            snapshot = try? h.query(rich)
            if snapshot?.entries.count == 3 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let migrated = try XCTUnwrap(snapshot)
        XCTAssertEqual(migrated.entries.count, 3)
        for entry in migrated.entries { XCTAssertEqual(entry.format, "net.daringfireball.markdown") }
        let originals = try migrated.entries.map { String(decoding: try h.chunk(rich, id: $0.id).data, as: UTF8.self) }
        XCTAssertEqual(Set(originals), Set([sources[0], sources[1], "**Inline bold**"]))
        let text = try h.package(types: ["text"]); h.grant(text)
        XCTAssertEqual(try h.query(text).entries.count, 2)
        for entry in migrated.entries { XCTAssertThrowsError(try h.chunk(text, id: entry.id)) }
        try h.restart()
        h.grant(rich)
        XCTAssertEqual(Set(try h.query(rich).entries.map(\.id)), Set(migrated.entries.map(\.id)))
    }

    func testLegacyExplicitMarkdownCannotKeepAnOldBinaryPermissionAlias() throws {
        let h = try Harness()
        h.board.clearContents(); h.board.setString("explicit Markdown payload", forType: .init("public.markdown")); try h.collector.poll()
        let url = h.directory.appendingPathComponent("history.json")
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(archive["entries"] as? [[String: Any]])
        for index in entries.indices { entries[index]["contentType"] = "binary"; entries[index]["text"] = "Binary content" }
        archive["entries"] = entries; archive.removeValue(forKey: "markdownClassificationVersion")
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        try h.restart()
        let rich = try h.package(types: ["rich_text"]); h.grant(rich)
        var ready: ClipboardHistorySnapshot?
        for _ in 0..<100 {
            ready = try? h.query(rich)
            if ready != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let entry = try XCTUnwrap(ready?.entries.first)
        XCTAssertEqual(entry.text, "explicit Markdown payload")
        XCTAssertEqual(try h.chunk(rich, id: entry.id).data, Data("explicit Markdown payload".utf8))
        let binary = try h.package(types: ["binary"]); h.grant(binary)
        XCTAssertEqual(try h.query(binary).entries, [])
        XCTAssertThrowsError(try h.chunk(binary, id: entry.id))
    }

    func testEmojiRichPreviewsRespectByteAndCharacterBudgetsWithoutDroppingAnyCopyPayload() throws {
        let h = try Harness()
        let flags = String(repeating: "🇨🇳", count: 1_025) // 1025 Characters, 8200 UTF-8 bytes
        let html = Data(("<b>" + flags + "</b>").utf8)
        let rtfUnicode = flags.utf16.map { "\\u\(Int16(bitPattern: $0))?" }.joined()
        let rtf = Data((#"{\rtf1\ansi\uc1\b "# + rtfUnicode + "}").utf8)
        let package = try h.package(types: ["text", "rich_text"]); h.grant(package)
        for (format, payload, expected) in [(NSPasteboard.PasteboardType.html, html, String(repeating: "🇨🇳", count: 1_024)),
                                           (.rtf, rtf, String(repeating: "🇨🇳", count: 1_024))] {
            let item = NSPasteboardItem()
            item.setString(flags, forType: .string)
            item.setData(payload, forType: format)
            h.board.clearContents(); h.board.writeObjects([item])
            try h.collector.poll()
            let copy = try XCTUnwrap(h.query(package).copies.first)
            let rich = try XCTUnwrap(copy.representations.first { $0.format == format.rawValue })
            let plain = try XCTUnwrap(copy.representations.first { $0.contentType == .text })
            XCTAssertNil(rich.richTextPreview)
            let rendered = rich.text
            XCTAssertEqual(rendered, expected)
            XCTAssertLessThanOrEqual(rendered.utf8.count, 8_192)
            XCTAssertLessThanOrEqual(rendered.count, 2_048)
            XCTAssertFalse(rendered.contains("�"), "Do not cut an emoji inside its encoding")
            XCTAssertEqual(try h.chunk(package, id: rich.id).data, payload)
            XCTAssertEqual(try h.chunk(package, id: plain.id).data, Data(flags.utf8))
        }
        try h.restart()
        XCTAssertEqual(try h.query(package).copies.count, 2)
    }

    func testRichPreviewStyleFloodIsBoundedAndHiddenOrRemoteContentIsInert() throws {
        let h = try Harness()
        let rtf = Data((#"{\rtf1{\fonttbl\f0 Helvetica;}Visible {\b bold {\i italic}} plain \u20320?\u22909? {\*\objdata hidden-object}{\field{\*\fldinst HYPERLINK https://remote.invalid}{\fldrslt label}} "#
            + String(repeating: #"\b a\b0 b"#, count: 30_000) + "}").utf8)
        let items = (0..<30).map { _ -> NSPasteboardItem in
            let item = NSPasteboardItem(); item.setData(rtf, forType: .rtf); return item
        }
        h.board.clearContents(); h.board.writeObjects(items); try h.collector.poll()
        let rich = try h.package(types: ["rich_text"]); h.grant(rich)
        var offset = 0, count = 0
        repeat {
            let page = try h.query(rich, offset: offset)
            XCTAssertFalse(page.entries.isEmpty)
            XCTAssertLessThan(try JSONEncoder().encode(page).count, 1_048_576)
            for entry in page.entries {
                XCTAssertNil(entry.richTextPreview)
                let text = entry.text
                XCTAssertLessThanOrEqual(text.count, 2_048)
                XCTAssertTrue(text.contains("你好"))
                XCTAssertFalse(text.contains("hidden-object"))
                XCTAssertFalse(text.contains("https://"))
                XCTAssertTrue(text.contains("bold italic"))
                XCTAssertLessThanOrEqual(text.utf8.count, 8_192)
                let chunk = try h.chunk(rich, id: entry.id)
                XCTAssertEqual(chunk.data, Data(rtf.prefix(196_608)))
                XCTAssertLessThan(try JSONEncoder().encode(chunk).count, 524_288)
            }
            count += page.entries.count
            guard let next = page.nextOffset else { break }; offset = next
        } while true
        XCTAssertEqual(count, 30)
        let text = try h.package(types: ["text"]); h.grant(text)
        XCTAssertTrue(try h.query(text).entries.allSatisfy { $0.richTextPreview == nil })
    }

    func testFailedMigrationIsClosedToQueryAndChunksAndClearRecoversWithoutResidualPayloads() throws {
        let h = try Harness()
        h.board.clearContents(); h.board.setString("# Old secret", forType: .string); try h.collector.poll()
        let url = h.directory.appendingPathComponent("history.json")
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(archive["entries"] as? [[String: Any]])
        for index in entries.indices { entries[index]["contentType"] = "text" }
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(entries.first?["id"] as? String)))
        archive["entries"] = entries; archive.removeValue(forKey: "markdownClassificationVersion")
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        let failed = expectation(description: "migration disk failure")
        var writes = 0
        h.store = try ClipboardHistoryStore(fileURL: url, writeFile: { data, destination in
            writes += 1
            if writes == 1 { failed.fulfill(); throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: destination, options: .atomic)
        })
        wait(for: [failed], timeout: 2)
        let text = try h.package(types: ["text"]); h.grant(text)
        XCTAssertThrowsError(try h.query(text))
        XCTAssertThrowsError(try h.chunk(text, id: id))
        try h.store.clear()
        XCTAssertEqual(try h.query(text).entries, [])
        try h.restart()
        XCTAssertEqual(try h.query(text).entries, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.directory.appendingPathComponent("clipboard-payloads").path), [])
    }

    func testLegacyInlineRichPayloadRemainsReadableWithoutRewritingOriginalBytes() throws {
        let h = try Harness()
        let source = #"{\rtf1 old\par text}"#
        let id = UUID()
        let url = h.directory.appendingPathComponent("history.json")
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        archive["entries"] = [["id": id.uuidString, "text": source, "contentType": "rich_text", "format": "public.rtf",
            "sourceApplicationName": "Fixture", "sourceBundleIdentifier": "fixture", "copiedAt": h.clock.now.timeIntervalSinceReferenceDate]]
        archive.removeValue(forKey: "plainPreviewVersion")
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        try h.restart()
        let rich = try h.package(types: ["rich_text"]); h.grant(rich)
        var snapshot: ClipboardHistorySnapshot?
        for _ in 0..<100 {
            snapshot = try? h.query(rich)
            if snapshot != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let entry = try XCTUnwrap(snapshot?.entries.first)
        XCTAssertEqual(ClipboardHistoryTextPresentation(entry: entry).text, "old\ntext")
        XCTAssertEqual(try h.chunk(rich, id: id).data, Data(source.utf8))
    }

    func testLegacyRTFPreviewIsBackfilledFromBoundedRetainedBytes() throws {
        let h = try Harness()
        h.board.clearContents(); h.board.setData(Data(#"{\rtf1\ansi\ansicpg936 \'c4\'e3\'ba\'c3\par A \b bold\b0  word\par}"#.utf8), forType: .rtf)
        try h.collector.poll()
        let url = h.directory.appendingPathComponent("history.json")
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(archive["entries"] as? [[String: Any]])
        for index in entries.indices {
            entries[index]["text"] = "Old wrong preview"
            entries[index]["richTextPreview"] = ["runs": [["text": "Old styled preview", "bold": true, "italic": false, "underline": false]], "source": #"{\rtf1 old raw}"#]
        }
        archive["entries"] = entries; archive.removeValue(forKey: "plainPreviewVersion")
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        try h.restart()
        let package = try h.package(types: ["rich_text"]); h.grant(package)
        var snapshot: ClipboardHistorySnapshot?
        for _ in 0..<100 {
            snapshot = try? h.query(package)
            if snapshot != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(snapshot?.entries.first?.text, "你好\nA bold word\n")
        XCTAssertNil(snapshot?.entries.first?.richTextPreview)
        h.board.clearContents(); h.board.setData(Data(#"{\rtf1\ansi\ansicpg936 \'c4\'e3\'ba\'c3\par A \b bold\b0  word\par}"#.utf8), forType: .rtf)
        try h.collector.poll()
        XCTAssertEqual(try h.query(package).copies.count, 1, "Preview backfill must preserve unchanged copy deduplication")
    }

    func testSyntheticJPEGFileReferencesPreviewAtRealPathsAndRejectOversizedOrSymlinkSources() throws {
        let h = try Harness()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 127, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        var files: [URL] = []
        for name in ["sample.jpg", "sample.jpeg", "SAMPLE.JPG", "空 格.jpg"] {
            let file = h.directory.appendingPathComponent(name)
            try jpeg.write(to: file); files.append(file)
        }
        let large = h.directory.appendingPathComponent("over-20MiB.jpg")
        var padded = jpeg; padded.append(Data(repeating: 0, count: 20 * 1_024 * 1_024 + 1 - jpeg.count))
        try padded.write(to: large); files.append(large)
        let boundary = h.directory.appendingPathComponent("at-20MiB.jpg")
        try padded.prefix(20 * 1_024 * 1_024).write(to: boundary); files.append(boundary)
        // Change only SOF dimensions: ImageIO reads the advertised size before
        // decoding, exercising the 40MP guard without allocating a huge bitmap.
        var huge = jpeg
        let sof = try XCTUnwrap((0..<(huge.count - 9)).first { huge[$0] == 0xff && [0xc0, 0xc1, 0xc2].contains(huge[$0 + 1]) })
        huge[sof + 5] = 0x1b; huge[sof + 6] = 0x58 // height 7000
        huge[sof + 7] = 0x1b; huge[sof + 8] = 0x58 // width 7000: 49MP
        let oversizedSource = try XCTUnwrap(CGImageSourceCreateWithData(huge as CFData, nil))
        let dimensions = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(oversizedSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual(dimensions[kCGImagePropertyPixelWidth] as? Int, 7_000)
        XCTAssertEqual(dimensions[kCGImagePropertyPixelHeight] as? Int, 7_000)
        let pixels = h.directory.appendingPathComponent("over-40MP.jpg")
        try huge.write(to: pixels); files.append(pixels)
        let link = h.directory.appendingPathComponent("symlink.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: files[0]); files.append(link)
        h.board.clearContents(); h.board.writeObjects(files.map { $0 as NSURL }); try h.collector.poll()
        let package = try h.package(types: ["file_reference"]); h.grant(package)
        let entries = try h.query(package).entries
        XCTAssertEqual(entries.count, files.count)
        for name in ["sample.jpg", "sample.jpeg", "SAMPLE.JPG", "空 格.jpg", "at-20MiB.jpg"] {
            let entry = try XCTUnwrap(entries.first { $0.fileReference?.name == name })
            XCTAssertNil(entry.fileReference?.unavailableReason)
            let preview = try XCTUnwrap(entry.imagePreview, name)
            XCTAssertEqual(preview.pixelWidth, 32); XCTAssertEqual(preview.pixelHeight, 24)
            XCTAssertNotNil(NSImage(data: try XCTUnwrap(preview.thumbnail)))
            XCTAssertThrowsError(try h.chunk(package, id: entry.id))
        }
        for name in ["over-20MiB.jpg", "over-40MP.jpg", "symlink.jpg"] {
            XCTAssertNil(try XCTUnwrap(entries.first { $0.fileReference?.name == name }).imagePreview, name)
        }
    }

    func testFinderMultiFileCopyIsOneGroupWithControlledRasterThumbnailAndNoSourcePayload() throws {
        let h = try Harness()
        h.source = ("Finder", "com.apple.finder")
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        let png = h.directory.appendingPathComponent("sample.png")
        let note = h.directory.appendingPathComponent("note.txt")
        try image.write(to: png); try Data("never clone this source".utf8).write(to: note)
        h.board.clearContents(); h.board.writeObjects([png as NSURL, note as NSURL]); try h.collector.poll()
        let files = try h.package(types: ["file_reference"]); h.grant(files)
        let snapshot = try h.query(files)
        XCTAssertEqual(snapshot.copies.count, 1)
        XCTAssertEqual(Set(snapshot.entries.compactMap(\.itemIndex)), [0, 1])
        let entry = try XCTUnwrap(snapshot.entries.first { $0.fileReference?.name == "sample.png" })
        XCTAssertNotNil(entry.imagePreview?.thumbnail)
        XCTAssertThrowsError(try h.chunk(files, id: entry.id))
        let imageReader = try h.package(types: ["image", "text", "binary"]); h.grant(imageReader)
        XCTAssertEqual(try h.query(imageReader).entries, [])
        h.grant(files)
        try h.restart()
        XCTAssertEqual(try h.query(files).copies.count, 1)
        try FileManager.default.removeItem(at: png)
        let missing = try XCTUnwrap(h.query(files).entries.first { $0.id == entry.id })
        XCTAssertNil(missing.imagePreview, "Do not show a thumbnail for an unavailable reference")
        XCTAssertNotNil(missing.fileReference?.unavailableReason)
        XCTAssertEqual(try Data(contentsOf: note), Data("never clone this source".utf8))
        let payloadDirectory = h.directory.appendingPathComponent("clipboard-payloads")
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadDirectory.path))
    }

    func testMultiItemCopyDoesNotSplitAtTheLegacyFiftyRepresentationPageBoundary() throws {
        let h = try Harness()
        let items = (0..<51).map { index -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString("item \(index)", forType: .string)
            return item
        }
        h.board.clearContents(); h.board.writeObjects(items); try h.collector.poll()
        let package = try h.package(types: ["text"]); h.grant(package)
        let snapshot = try h.query(package)
        XCTAssertEqual(snapshot.copies.count, 1)
        XCTAssertEqual(snapshot.entries.count, 51)
        XCTAssertNil(snapshot.nextOffset)
        XCTAssertLessThan(try JSONEncoder().encode(snapshot).count, 1_048_576)
    }

    func testOversizedCopyContinuesWithOneStableIdentityWithinTheProtocolBudget() throws {
        let h = try Harness()
        let items = (0..<300).map { index -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString("\(index):" + String(repeating: "x", count: 2_048), forType: .string)
            return item
        }
        h.board.clearContents(); h.board.writeObjects(items); try h.collector.poll()
        h.board.clearContents(); h.board.setString("newer copy", forType: .string); try h.collector.poll()
        let package = try h.package(types: ["text"]); h.grant(package)
        let newest = try h.query(package)
        XCTAssertEqual(newest.entries.map(\.text), ["newer copy"], "Do not split the next copy merely to fill a page")
        var offset = try XCTUnwrap(newest.nextOffset)
        var ids = Set<UUID>(), copyIDs = Set<UUID>()
        repeat {
            let page = try h.query(package, offset: offset)
            XCTAssertEqual(page.copies.count, 1)
            XCTAssertLessThan(try JSONEncoder().encode(page).count, 1_048_576)
            XCTAssertFalse(page.entries.isEmpty)
            for entry in page.entries { XCTAssertTrue(ids.insert(entry.id).inserted) }
            copyIDs.insert(try XCTUnwrap(page.copies.first?.id))
            guard let next = page.nextOffset else { break }
            XCTAssertEqual(page.continuingCopyID, page.copies.first?.id)
            XCTAssertGreaterThan(next, offset)
            offset = next
        } while true
        XCTAssertEqual(ids.count, 300)
        XCTAssertEqual(copyIDs.count, 1)
    }

    func testFullTextBeyondPreviewAndOpaqueFormatIdentityAreNotCollapsed() throws {
        let h = try Harness()
        let prefix = String(repeating: "x", count: 4_000)
        for suffix in ["A", "B", "A"] {
            h.board.clearContents(); h.board.setString(prefix + suffix, forType: .string); try h.collector.poll()
        }
        let text = try h.package(types: ["text"]); h.grant(text)
        let snapshot = try h.query(text)
        XCTAssertEqual(snapshot.copies.count, 2)
        XCTAssertEqual(Set(snapshot.entries.map(\.text)).count, 1, "The previews are deliberately identical")
        XCTAssertEqual(try h.chunk(text, id: XCTUnwrap(snapshot.entries.first).id).data, Data((prefix + "A").utf8))
        for format in ["org.telegram.message", "org.telegram.other-message"] {
            let item = NSPasteboardItem()
            item.setString("identical", forType: .string)
            item.setData(Data([1, 2, 3]), forType: .init(format))
            h.board.clearContents(); h.board.writeObjects([item]); try h.collector.poll()
        }
        let all = try h.package(types: ["text", "binary"]); h.grant(all)
        XCTAssertEqual(try h.query(all).copies.count, 4, "Same bytes in different opaque formats are not the same payload")
    }

    func testRestartReclaimsAnInterruptedStagedIndexWithoutLosingCommittedHistory() throws {
        let h = try Harness()
        h.board.clearContents(); h.board.setString("committed", forType: .string)
        try h.collector.poll()
        // Filesystem fixture for a process interrupted after staging, before rename.
        let interrupted = h.directory.appendingPathComponent("history.json.pending-interrupted")
        try Data("stale preview from an interrupted index".utf8).write(to: interrupted)
        try h.restart()
        let package = try h.package(types: ["text"]); h.grant(package)
        XCTAssertEqual(try h.query(package).entries.map(\.text), ["committed"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
    }

    func testBackgroundCollectionKeepsMainResponsiveAndSerializesLargeCopies() throws {
        let h = try Harness()
        let reading = expectation(description: "payload read began")
        let stored = expectation(description: "large payload persisted")
        let gate = DispatchSemaphore(value: 0)
        let payload = Data(repeating: 0x51, count: 1_200_000)
        let collector = ClipboardCollector(store: h.store, changeCount: { h.board.changeCount }, readContents: {
            XCTAssertFalse(Thread.isMainThread, "Payload materialization and previews must leave the main thread")
            reading.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
            return [.init(text: "Binary content", type: .binary, data: payload, format: "com.example.binary")]
        }, sourceApplication: { h.source })
        h.board.clearContents(); h.board.setString("large copy", forType: .string)
        XCTAssertTrue(collector.schedulePoll { result in
            if case .failure(let error) = result { XCTFail("Collection failed: \(error)") }
            stored.fulfill()
        })
        wait(for: [reading], timeout: 2)
        // Main is free while a payload is being materialized. Further timer ticks
        // request a resample, not another concurrent read or an unbounded queue.
        XCTAssertFalse(collector.schedulePoll())
        let responsive = expectation(description: "main run loop continues")
        DispatchQueue.main.async { responsive.fulfill(); gate.signal() }
        wait(for: [responsive, stored], timeout: 4)
        let package = try h.package(types: ["binary"]); h.grant(package)
        let entries = try h.query(package).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.byteCount, 1_200_000)
        XCTAssertEqual(try h.chunk(package, id: XCTUnwrap(entries.first).id, offset: 1_100_000).data, Data(repeating: 0x51, count: 100_000))
    }

    func testCollectorRejectsInvalidObservedTypePayloadCombinationsAtomically() throws {
        let h = try Harness()
        let invalid: [ClipboardContent] = [
            .init(text: "disguised text", type: .binary, data: Data("secret".utf8), format: "public.utf16-plain-text"),
            .init(text: "missing image bytes", type: .image),
            .init(text: "text with a reference", type: .text, fileURL: URL(fileURLWithPath: "/tmp/private")),
            .init(text: "not a local reference", type: .fileReference, fileURL: URL(string: "https://example.com")),
            .init(text: "binary without bytes", type: .binary, format: "com.example.binary")
        ]
        var count = 0
        for content in invalid {
            count += 1
            let collector = ClipboardCollector(store: h.store, changeCount: { count }, readContents: {
                [.init(text: "must not partly commit", type: .text), content]
            }, sourceApplication: { h.source })
            XCTAssertThrowsError(try collector.poll())
        }
        let package = try h.package(types: ["text", "binary", "image", "file_reference"]); h.grant(package)
        XCTAssertEqual(try h.query(package).entries, [])
        try h.restart()
        XCTAssertEqual(try h.query(package).entries, [])
    }

    func testPayloadDeletionRetriesAfterIndexExpirationEvenWithoutAnotherExpiredEntry() throws {
        let h = try Harness()
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        h.board.clearContents(); h.board.setData(bytes, forType: .init("com.example.binary"))
        try h.collector.poll()
        let package = try h.package(types: ["binary"]); h.grant(package)
        // Fail the filesystem's deletion boundary, not the Store/index implementation.
        let files = FileManager.default.enumerator(at: h.directory, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        let payload = try XCTUnwrap(files.first { (try? Data(contentsOf: $0)) == bytes })
        let parent = payload.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        h.clock.now = h.clock.now.addingTimeInterval(86_400)
        XCTAssertThrowsError(try h.query(package))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        XCTAssertEqual(try h.query(package).entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path), "A later query must retry deletion even after the index committed")
    }

    func testTextAliasesAndMixedRepresentationsCannotBypassTypeGrants() throws {
        let h = try Harness()
        let item = NSPasteboardItem()
        item.setData("classified text".data(using: .utf16)!, forType: .init("public.utf16-external-plain-text"))
        item.setString("classified text", forType: .string)
        item.setData(Data([0x42]), forType: .init("com.example.binary"))
        item.setData(Data("<b>rich</b>".utf8), forType: .html)
        h.board.clearContents(); h.board.writeObjects([item])
        try h.collector.poll(); try h.restart()
        let binary = try h.package(types: ["binary"]); h.grant(binary)
        let binaryEntries = try h.query(binary).entries
        XCTAssertEqual(binaryEntries.count, 1)
        XCTAssertEqual(try h.chunk(binary, id: XCTUnwrap(binaryEntries.first).id).data, Data([0x42]))
        let text = try h.package(types: ["text"]); h.grant(text)
        let entries = try h.query(text).entries
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            XCTAssertEqual(entry.text, "classified text")
            XCTAssertEqual(try h.chunk(text, id: entry.id).data, Data("classified text".utf8))
        }
        let current = ClipboardCollector.readCurrent(from: h.board)
        XCTAssertEqual(current?.type, .text)
        XCTAssertEqual(current?.text, "classified text")
    }

    func testURLTitleMetadataIsNotRetainedAsEmbeddedBinary() throws {
        let h = try Harness()
        let item = NSPasteboardItem()
        item.setString("https://example.com", forType: .URL)
        item.setString("Private document title", forType: NSPasteboard.PasteboardType("public.url-name"))
        h.board.clearContents(); h.board.writeObjects([item])
        try h.collector.poll(); try h.restart()
        let package = try h.package(types: ["url", "binary"]); h.grant(package)
        let entries = try h.query(package).entries
        XCTAssertEqual(entries.map(\.text), ["https://example.com"])
        XCTAssertEqual(entries.map(\.contentType), [.url])
    }

    func testDeletedAndInaccessibleFileReferencesRemainVisibleAfterRestart() throws {
        let h = try Harness()
        let deleted = h.directory.appendingPathComponent("deleted.txt")
        let locked = h.directory.appendingPathComponent("locked.txt")
        try Data("deleted source".utf8).write(to: deleted)
        try Data("locked source".utf8).write(to: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        h.board.clearContents(); h.board.writeObjects([deleted as NSURL, locked as NSURL])
        try h.collector.poll()
        let package = try h.package(types: ["file_reference"]); h.grant(package)
        let originalIDs = Set(try h.query(package).entries.map(\.id))
        XCTAssertEqual(originalIDs.count, 2)
        try FileManager.default.removeItem(at: deleted)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: locked.path), "This filesystem boundary test requires a non-root test runner")
        try h.restart()
        let entries = try h.query(package).entries
        XCTAssertEqual(Set(entries.map(\.id)), originalIDs)
        for entry in entries {
            XCTAssertNotNil(entry.fileReference?.unavailableReason)
            XCTAssertThrowsError(try h.chunk(package, id: entry.id))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path)
        XCTAssertNil(try h.query(package).entries.first { $0.fileReference?.name == "locked.txt" }?.fileReference?.unavailableReason)
    }

    func testRetainedPayloadSurvivesPauseAndTurnOffButExpiresBeforeTheNextChunk() throws {
        let h = try Harness()
        let payload = Data(repeating: 0x42, count: 300_000)
        h.board.clearContents(); h.board.setData(payload, forType: NSPasteboard.PasteboardType("com.example.binary"))
        try h.collector.poll()
        let package = try h.package(types: ["binary"]); h.grant(package)
        let entry = try XCTUnwrap(h.query(package).entries.first)
        try h.store.configure(enabled: true, paused: true, retentionDays: 1)
        h.board.clearContents(); h.board.setData(Data([7]), forType: NSPasteboard.PasteboardType("com.example.binary"))
        try h.collector.poll()
        XCTAssertEqual(try h.query(package).state, .paused)
        XCTAssertEqual(try h.query(package).entries.map(\.id), [entry.id])
        try h.store.turnOff(deleteEntries: false); try h.restart()
        XCTAssertEqual(try h.query(package).state, .off)
        XCTAssertEqual(try h.chunk(package, id: entry.id, offset: 196_608).data.count, 103_392)
        h.clock.now = h.clock.now.addingTimeInterval(86_400)
        XCTAssertThrowsError(try h.chunk(package, id: entry.id, offset: 196_608))
        XCTAssertEqual(try h.query(package).entries, [])
        try h.restart()
        XCTAssertEqual(try h.query(package).entries, [])
    }

    func testFileURLRepresentationDoesNotLeakFileReferencesThroughURLGrant() throws {
        let h = try Harness()
        let file = h.directory.appendingPathComponent("private.txt")
        try Data("not a URL result".utf8).write(to: file)
        h.board.clearContents(); h.board.setString(file.absoluteString, forType: .URL)
        try h.collector.poll()
        let urlReader = try h.package(types: ["url", "binary"]); h.grant(urlReader)
        XCTAssertEqual(try h.query(urlReader).entries, [])
        let fileReader = try h.package(types: ["file_reference"]); h.grant(fileReader)
        XCTAssertEqual(try h.query(fileReader).entries.first?.fileReference?.name, "private.txt")
    }

    func testPreviousTextOnlyArchiveRemainsReadableWithBoundedMetadata() throws {
        let h = try Harness()
        let text = String(repeating: "legacy ", count: 9_000)
        // Issue #25's published archive shape, before rich content and payload files.
        let legacy: [String: Any] = ["enabled": true, "paused": false, "retentionDays": 1, "entries": [[
            "id": "11111111-1111-1111-1111-111111111111", "text": text, "contentType": "text",
            "sourceApplicationName": "Notes", "sourceBundleIdentifier": "com.apple.Notes", "copiedAt": h.clock.now.timeIntervalSinceReferenceDate
        ]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: h.directory.appendingPathComponent("history.json"))
        try h.restart()
        let package = try h.package(types: ["text"]); h.grant(package)
        var ready: ClipboardHistorySnapshot?
        for _ in 0..<100 {
            ready = try? h.query(package)
            if ready != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let snapshot = try XCTUnwrap(ready)
        XCTAssertLessThan(try JSONEncoder().encode(snapshot).count, 16_384)
        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(entry.byteCount, 63_000)
        XCTAssertEqual(try h.chunk(package, id: entry.id).data, Data(text.utf8))
    }

    func testFailedLocalPersistenceCanRetryTheSamePasteboardChange() throws {
        let h = try Harness()
        let backup = h.directory.appendingPathExtension("backup")
        defer { try? FileManager.default.removeItem(at: backup) }
        try FileManager.default.moveItem(at: h.directory, to: backup)
        try Data().write(to: h.directory)
        h.board.clearContents(); h.board.setData(Data([1, 3, 5]), forType: NSPasteboard.PasteboardType("com.example.binary"))
        XCTAssertThrowsError(try h.collector.poll())
        try FileManager.default.removeItem(at: h.directory)
        try FileManager.default.moveItem(at: backup, to: h.directory)
        try h.collector.poll(); try h.restart()
        let package = try h.package(types: ["binary"]); h.grant(package)
        let entry = try XCTUnwrap(h.query(package).entries.first)
        XCTAssertEqual(try h.chunk(package, id: entry.id).data, Data([1, 3, 5]))
    }

    func testApplicationSwitchDuringCollectionDiscardsTheAmbiguousCopy() throws {
        let h = try Harness()
        let collector = ClipboardCollector(store: h.store, changeCount: { h.board.changeCount }, readContents: {
            h.source = ("Passwords", "com.apple.Passwords")
            return ClipboardCollector.readAll(from: h.board)
        }, sourceApplication: { h.source })
        h.board.clearContents(); h.board.setString("ambiguous copy", forType: .string)
        try collector.poll()
        h.source = ("Preview", "com.apple.Preview")
        try collector.poll()
        let package = try h.package(types: ["text"]); h.grant(package)
        XCTAssertEqual(try h.query(package).entries, [])
    }

    func testStorageFailuresNeverDiscloseHostStorePathsThroughHistoryServices() throws {
        let h = try Harness()
        h.board.clearContents(); h.board.setString("expires", forType: .string)
        try h.collector.poll()
        let package = try h.package(types: ["text"]); h.grant(package)
        let entry = try XCTUnwrap(h.query(package).entries.first)
        // External filesystem failure: the archive's parent is no longer a directory.
        try FileManager.default.removeItem(at: h.directory)
        try Data().write(to: h.directory)
        h.clock.now = h.clock.now.addingTimeInterval(86_400)
        for operation in [{ try h.request(package) }, { try h.request(package, service: .readClipboardHistoryContent,
            input: .object(["entry_id": .string(entry.id.uuidString), "offset": .number(0), "length": .number(10)])) }] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(error as? PluginHostServiceError, .failed("Clipboard History could not be read"))
                XCTAssertFalse(error.localizedDescription.contains(h.directory.path))
            }
        }
    }

    func testImagePreviewMetadataIsBoundedAndDoesNotDiscloseToOtherTypes() throws {
        let h = try Harness()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        h.board.clearContents(); h.board.setData(png, forType: .png)
        try h.collector.poll(); try h.restart()
        let package = try h.package(types: ["image"])
        h.grant(package)
        let preview = try XCTUnwrap(h.query(package).entries.first { $0.format == "public.png" }?.imagePreview)
        XCTAssertEqual(preview.pixelWidth, 2)
        XCTAssertEqual(preview.pixelHeight, 3)
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(preview.thumbnail)))
        XCTAssertLessThan(try JSONEncoder().encode(h.query(package)).count, 65_536)
        let text = try h.package(types: ["text"]); h.grant(text)
        XCTAssertEqual(try h.query(text).entries, [])
    }

    func testBundledHistoryDisclosesAllTypesAndExpansionNeedsFreshMasterConsent() throws {
        let h = try Harness()
        h.board.clearContents(); h.board.setData(Data([9, 8, 7]), forType: .png)
        try h.collector.poll()
        let old = try h.package(types: ["text", "url"])
        h.grant(old)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Sources/SpinnetHost/Resources/ClipboardHistory.spinnetplugin")).manifest
        let types = try XCTUnwrap(bundled.scope(for: .readClipboardHistory)?.dataTypes)
        XCTAssertEqual(Set(types), ["text", "url", "image", "rich_text", "file_reference", "binary"])
        let updated = try h.package(types: types, version: "2")
        h.grants.prepareInstallation(of: updated.manifest, replacing: old.manifest)
        XCTAssertThrowsError(try h.query(updated))
        let disclosure = PluginPermissionDisclosure(manifest: updated.manifest).details(for: .reads)
        for type in types { XCTAssertTrue(disclosure.contains(type)) }
        XCTAssertTrue(disclosure.contains("retained before this grant"))
        h.grant(updated)
        let entry = try XCTUnwrap(h.query(updated).entries.first)
        XCTAssertEqual(try h.chunk(updated, id: entry.id).data, Data([9, 8, 7]))
        // Reusing the version does not make a changed scope inherit consent.
        let expandedAgain = try h.package(types: types + ["future_type"], version: "2")
        h.grants.prepareInstallation(of: expandedAgain.manifest, replacing: updated.manifest)
        XCTAssertThrowsError(try h.query(expandedAgain))
        XCTAssertThrowsError(try h.chunk(expandedAgain, id: entry.id))
    }

    func testConcealedTransientAndGeneratedMarkersExcludeEveryRepresentation() throws {
        let h = try Harness()
        let package = try h.package(types: ["text", "image", "rich_text", "binary"])
        h.grant(package)
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            let item = NSPasteboardItem()
            item.setData(Data([1, 2, 3]), forType: .png)
            item.setData(Data([4, 5]), forType: .rtf)
            item.setString("private", forType: .string)
            item.setString("", forType: NSPasteboard.PasteboardType(marker))
            h.board.clearContents(); h.board.writeObjects([item])
            try h.collector.poll()
        }
        try h.restart()
        XCTAssertEqual(try h.query(package).entries, [])
    }

    func testPasswordsAndKeychainAccessAreExcludedBeforePasteboardContentIsRead() throws {
        let h = try Harness()
        let package = try h.package(types: ["text", "binary", "image"])
        h.grant(package)
        var reads = 0
        let collector = ClipboardCollector(store: h.store, changeCount: { h.board.changeCount }, readContents: {
            reads += 1
            return ClipboardCollector.readAll(from: h.board)
        }, sourceApplication: { h.source })
        for bundleID in ["com.apple.Passwords", "com.apple.keychainaccess"] {
            h.source = ("Sensitive app", bundleID)
            h.board.clearContents(); h.board.setString("secret", forType: .string)
            try collector.poll()
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(try h.query(package).entries, [])
        h.source = ("Notes", "com.apple.Notes")
        try collector.poll()
        XCTAssertEqual(try h.query(package).entries, [], "Switching applications must not replay an excluded copy")
        h.board.clearContents(); h.board.setString("safe", forType: .string)
        try collector.poll()
        XCTAssertEqual(try h.query(package).entries.map(\.text), ["safe"])
    }

    func testFileReferencesRetainMetadataWithoutCloningAndBecomeUnavailableWhenMoved() throws {
        let h = try Harness()
        let file = h.directory.appendingPathComponent("sample.txt")
        try Data("source bytes never copied".utf8).write(to: file)
        h.source = ("Finder", "com.apple.finder")
        h.board.clearContents(); h.board.writeObjects([file as NSURL])
        try h.collector.poll(); try h.restart()
        let package = try h.package(types: ["file_reference"])
        h.grant(package)
        let entry = try XCTUnwrap(h.query(package).entries.first)
        let metadata = try XCTUnwrap(entry.fileReference)
        XCTAssertEqual(metadata.name, "sample.txt")
        XCTAssertEqual(metadata.byteCount, 25)
        XCTAssertEqual(metadata.typeIdentifier, "public.plain-text")
        XCTAssertEqual(metadata.previewIcon, "doc")
        XCTAssertNil(metadata.unavailableReason)
        XCTAssertThrowsError(try h.chunk(package, id: entry.id))
        let encoded = String(decoding: try JSONEncoder().encode(h.query(package)), as: UTF8.self)
        XCTAssertFalse(encoded.contains(h.directory.path))
        XCTAssertFalse(encoded.contains("source bytes never copied"))
        try FileManager.default.moveItem(at: file, to: h.directory.appendingPathComponent("moved.txt"))
        try h.restart()
        let stale = try XCTUnwrap(h.query(package).entries.first)
        XCTAssertEqual(stale.id, entry.id)
        XCTAssertEqual(stale.fileReference?.name, "sample.txt")
        XCTAssertNotNil(stale.fileReference?.unavailableReason)
        // Replacing the old path must not silently retarget the reference.
        try Data("replacement".utf8).write(to: file)
        XCTAssertNotNil(try h.query(package).entries.first?.fileReference?.unavailableReason)
    }

    func testLargeTextAndURLAreNotDroppedOrReturnedInlineInHistoryQueries() throws {
        let h = try Harness()
        let text = String(repeating: "🧶\\\"\n", count: 180_000)
        h.board.clearContents(); h.board.setString(text, forType: .string)
        try h.collector.poll()
        h.board.clearContents(); h.board.setString("https://example.com", forType: .URL)
        try h.collector.poll(); try h.restart()
        let package = try h.package(types: ["text", "url"])
        h.grant(package)
        let snapshot = try h.query(package)
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertLessThan(try JSONEncoder().encode(snapshot).count, 16_384)
        let entry = try XCTUnwrap(snapshot.entries.first { $0.contentType == .text })
        XCTAssertEqual(entry.byteCount, text.utf8.count)
        var bytes = Data(), offset = 0
        repeat {
            let chunk = try h.chunk(package, id: entry.id, offset: offset)
            bytes.append(chunk.data)
            guard let next = chunk.nextOffset else { break }; offset = next
        } while true
        XCTAssertEqual(String(data: bytes, encoding: .utf8), text)
        XCTAssertEqual(snapshot.entries.first { $0.contentType == .url }?.text, "https://example.com")
    }

    func testLargeEmbeddedBinaryAcrossPasteboardItemsUsesBoundedMetadataAndRevocableChunks() throws {
        let h = try Harness()
        let payload = Data(repeating: 0xa5, count: 1_100_000)
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setData(payload, forType: NSPasteboard.PasteboardType("com.example.embedded"))
        second.setString("second item", forType: .string)
        h.board.clearContents(); h.board.writeObjects([first, second])
        try h.collector.poll(); try h.restart()
        let package = try h.package(types: ["binary", "text"])
        h.grant(package)
        let snapshot = try h.query(package)
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertLessThan(try JSONEncoder().encode(snapshot).count, 16_384)
        let entry = try XCTUnwrap(snapshot.entries.first { $0.contentType.rawValue == "binary" })
        var received = Data(), offset = 0
        repeat {
            let chunk = try h.chunk(package, id: entry.id, offset: offset)
            XCTAssertLessThan(try JSONEncoder().encode(chunk).count, 524_288)
            received.append(chunk.data)
            guard let next = chunk.nextOffset else { break }
            offset = next
        } while true
        XCTAssertEqual(received, payload)
        XCTAssertThrowsError(try h.chunk(package, id: entry.id, length: 196_609))
        XCTAssertThrowsError(try h.chunk(package, id: entry.id, offset: -1))
        XCTAssertThrowsError(try h.chunk(package, id: entry.id, offset: payload.count + 1))
        h.grant(package, decision: .denied)
        XCTAssertThrowsError(try h.chunk(package, id: entry.id, offset: offset))
        h.grant(package)
        try h.store.clear()
        XCTAssertThrowsError(try h.chunk(package, id: entry.id))
    }

    func testRichTextRetainsFormattingAlongsideItsPlainTextRepresentation() throws {
        let h = try Harness()
        let rtf = Data(#"{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}\f0 A \b bold\b0  word}"#.utf8)
        h.board.clearContents()
        h.board.setData(rtf, forType: .rtf)
        h.board.setString("A bold word", forType: .string)
        try h.collector.poll()
        try h.restart()
        let package = try h.package(types: ["rich_text", "text"])
        h.grant(package)
        let entries = try h.query(package).entries
        XCTAssertEqual(Set(entries.map { $0.contentType.rawValue }), ["rich_text", "text"])
        let rich = try XCTUnwrap(entries.first { $0.contentType.rawValue == "rich_text" })
        XCTAssertEqual(try h.chunk(package, id: rich.id).data, rtf)
        XCTAssertNil(rich.richTextPreview)
        XCTAssertEqual(rich.text, "A bold word")
        XCTAssertEqual(entries.first { $0.contentType == .text }?.text, "A bold word")
    }

    func testImageIsRetainedLocallyAndReadOnlyThroughTypeScopedChunks() throws {
        let h = try Harness()
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        h.board.clearContents()
        h.board.setData(image, forType: .png)
        try h.collector.poll()
        try h.restart()
        let package = try h.package(types: ["image"])
        XCTAssertThrowsError(try h.query(package))
        h.grant(package)
        let entry = try XCTUnwrap(h.query(package).entries.first)
        XCTAssertEqual(entry.contentType.rawValue, "image")
        XCTAssertEqual(entry.byteCount, image.count)
        XCTAssertEqual(entry.sourceBundleIdentifier, "com.apple.Preview")
        XCTAssertEqual(try h.chunk(package, id: entry.id).data, image)
        let textReader = try h.package(types: ["text"])
        h.grant(textReader)
        XCTAssertEqual(try h.query(textReader).entries, [])
        XCTAssertThrowsError(try h.chunk(textReader, id: entry.id))
    }
}
