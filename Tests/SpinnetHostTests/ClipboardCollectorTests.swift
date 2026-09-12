import AppKit
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

    func testClipboardHistoryWindowDiscardsSnapshotWhenClosedOrExpired() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { Date().addingTimeInterval(-86_399.7) })
        try store.configure(enabled: true, paused: false, retentionDays: 1)
        try store.observe(changeCount: 1, content: .init(text: "expires soon", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        let window = ClipboardHistoryWindow(grants: PluginCapabilityGrantStore(), query: { try store.query(dataTypes: ["text"], offset: $0) }, openPrivacy: {}, openPluginSettings: {})
        window.present()
        XCTAssertEqual(window.model.snapshot?.entries.count, 1)
        let expired = expectation(description: "Visible clipboard data expires without a Plugin query")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expired.fulfill() }
        wait(for: [expired], timeout: 2)
        XCTAssertNil(window.model.snapshot)
        window.present()
        window.close()
        XCTAssertNil(window.model.snapshot)
    }
}
