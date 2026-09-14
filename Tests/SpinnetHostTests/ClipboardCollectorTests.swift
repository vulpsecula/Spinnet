import AppKit
import Combine
import XCTest
import SpinnetCore
@testable import SpinnetHost

final class ClipboardCollectorTests: XCTestCase {
    func testPasteboardCollectionSkipsBaselinePausedChangesAndConcealedItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        var reads = 0
        var changeDuringRead = false
        let collector = ClipboardCollector(store: store, changeCount: { board.changeCount }, readContent: {
            reads += 1
            let content = ClipboardCollector.readCurrent(from: board)
            if changeDuringRead {
                changeDuringRead = false
                board.clearContents()
                board.setString("stable replacement", forType: .string)
            }
            return content
        }, sourceApplication: { ("Notes", "com.apple.Notes") })
        func copy(_ text: String) { board.clearContents(); board.setString(text, forType: .string) }
        copy("before opt-in")
        try collector.poll()
        XCTAssertEqual(reads, 0)
        try collector.resetBaseline()
        try store.configure(enabled: true, paused: false, retentionDays: 1)
        try collector.poll()
        XCTAssertEqual(reads, 0)
        copy("https://example.com")
        try collector.poll()
        try collector.poll()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try store.query(dataTypes: ["url"]).entries.first?.text, "https://example.com")
        try store.configure(enabled: true, paused: true, retentionDays: 1)
        copy("during pause")
        try collector.poll()
        copy("just before resume")
        try collector.resetBaseline()
        try store.configure(enabled: true, paused: false, retentionDays: 1)
        try collector.poll()
        XCTAssertEqual(reads, 1)
        copy("password")
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        try collector.poll()
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries, [])
        XCTAssertEqual(try store.query(dataTypes: ["url"]).entries.first?.sourceBundleIdentifier, "com.apple.Notes")
        copy("racing clipboard")
        changeDuringRead = true
        try collector.poll()
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries, [])
        try collector.poll()
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries.map(\.text), ["stable replacement"])
    }

    func testHistoryWindowRefreshDoesNotBlockMainOnPersistenceOrPublishAfterClose() throws {
        let writing = expectation(description: "slow payload write")
        let sampled = expectation(description: "sample completed")
        let queried = expectation(description: "authorized query completed")
        let gate = DispatchSemaphore(value: 0)
        let bytes = Data(repeating: 0x61, count: 1_100_000)
        let h = try RichClipboardHistoryTests.Harness(writeFile: { data, url in
            if data == bytes { writing.fulfill(); _ = gate.wait(timeout: .now() + 2) }
            try data.write(to: url, options: .atomic)
        })
        let package = try h.package(types: ["binary"]); h.grant(package)
        let model = ClipboardHistoryWindowModel(query: { _ in
            let result = try h.query(package)
            queried.fulfill()
            return result
        })
        h.board.clearContents(); h.board.setData(bytes, forType: .init("com.example.binary"))
        h.collector.schedulePoll { _ in sampled.fulfill() }
        wait(for: [writing], timeout: 2)
        let start = Date()
        model.refresh()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
        model.discardSnapshot() // closing the window invalidates the pending response
        gate.signal()
        wait(for: [sampled, queried], timeout: 4)
        let settled = expectation(description: "main has delivered query result")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertNil(model.snapshot)
    }

    func testClipboardHistoryWindowDiscardsSnapshotWhenClosedOrExpired() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { Date().addingTimeInterval(-86_398.5) })
        try store.configure(enabled: true, paused: false, retentionDays: 1)
        try store.observe(changeCount: 1, content: .init(text: "expires soon", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        let window = ClipboardHistoryWindow(grants: PluginCapabilityGrantStore(), query: { try store.query(dataTypes: ["text"], offset: $0) }, openPrivacy: {}, openPluginSettings: {}, openIgnoredApplications: {}, clearHistory: { $0(nil) })
        let loaded = expectation(description: "history snapshot loaded")
        var delivered = false
        let subscription = window.model.$snapshot.sink { snapshot in
            if snapshot?.entries.count == 1, !delivered { delivered = true; loaded.fulfill() }
        }
        defer { subscription.cancel() }
        window.present()
        wait(for: [loaded], timeout: 2)
        XCTAssertEqual(window.model.snapshot?.entries.count, 1)
        let expired = expectation(description: "Visible clipboard data expires without a Plugin query")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { expired.fulfill() }
        wait(for: [expired], timeout: 3)
        XCTAssertNil(window.model.snapshot)
        window.present()
        window.close()
        XCTAssertNil(window.model.snapshot)
    }
}
