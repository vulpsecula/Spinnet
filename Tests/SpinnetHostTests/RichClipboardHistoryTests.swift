import AppKit
import XCTest
import SpinnetCore
@testable import SpinnetHost

final class RichClipboardHistoryTests: XCTestCase {
    final class Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        var grants = PluginCapabilityGrantStore()
        final class Clock { var now = Date() }
        let clock = Clock()
        var store: ClipboardHistoryStore
        var collector: ClipboardCollector!
        var source = (name: "Preview", bundleID: "com.apple.Preview")
        let command = CommandDeclaration(id: CommandID("browse"), title: "Browse", execution: .javascript, script: "browse.js")
        init(writeFile: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
            let clock = self.clock
            store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { clock.now }, writeFile: writeFile)
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
        func query(_ package: PluginPackage) throws -> ClipboardHistorySnapshot {
            try JSONDecoder().decode(ClipboardHistorySnapshot.self, from: JSONEncoder().encode(request(package)))
        }
        func chunk(_ package: PluginPackage, id: UUID, offset: Int = 0, length: Int = 196_608) throws -> ClipboardHistoryContentChunk {
            try JSONDecoder().decode(ClipboardHistoryContentChunk.self, from: JSONEncoder().encode(request(package, service: .readClipboardHistoryContent,
                input: .object(["entry_id": .string(id.uuidString), "offset": .number(Double(offset)), "length": .number(Double(length))]))))
        }
        func restart() throws {
            let clock = self.clock
            store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { clock.now })
        }
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
        let snapshot = try h.query(package)
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
        let rtf = Data("{\\rtf1\\ansi A \\b bold\\b0 word}".utf8)
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
