import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

final class ClipboardHistoryBrowsingTests: XCTestCase {
    private func copy(_ text: String, _ type: ClipboardContent.ContentType, app: String) -> ClipboardHistoryCopy {
        let entry = ClipboardHistoryEntry(id: UUID(), text: text, contentType: type, sourceApplicationName: app,
                                          sourceBundleIdentifier: app.lowercased(), copiedAt: Date())
        return ClipboardHistoryCopy(id: entry.id, representations: [entry])
    }

    func testFiltersByTextTypeAndApplicationTogether() {
        let copies = [copy("hello world", .text, app: "Notes"), copy("https://hello.example", .url, app: "Safari"),
                      copy("Hello again", .text, app: "Safari"), copy("unrelated", .text, app: "Notes")]
        var browsing = ClipboardHistoryBrowsing(text: "HELLO")
        XCTAssertEqual(browsing.apply(to: copies).map(\.id), [copies[0].id, copies[1].id, copies[2].id])
        browsing.kind = .text
        XCTAssertEqual(browsing.apply(to: copies).map(\.id), [copies[0].id, copies[2].id])
        browsing.application = "Safari"
        XCTAssertEqual(browsing.apply(to: copies).map(\.id), [copies[2].id])
        XCTAssertTrue(browsing.needsEveryPage)
        XCTAssertEqual(ClipboardHistoryBrowsing.applications(in: copies), ["Notes", "Safari"])
    }

    func testSortsKeepNewestFirstWithinEachGroup() {
        let copies = [copy("a", .url, app: "Safari"), copy("b", .text, app: "Notes"),
                      copy("c", .url, app: "Notes"), copy("d", .text, app: "Safari")]
        XCTAssertFalse(ClipboardHistoryBrowsing().needsEveryPage)
        XCTAssertEqual(ClipboardHistoryBrowsing(sort: .oldest).apply(to: copies).map(\.id), copies.reversed().map(\.id))
        XCTAssertEqual(ClipboardHistoryBrowsing(sort: .application).apply(to: copies).map(\.id),
                       [copies[1].id, copies[2].id, copies[0].id, copies[3].id])
        XCTAssertEqual(ClipboardHistoryBrowsing(sort: .type).apply(to: copies).map(\.id),
                       [copies[1].id, copies[3].id, copies[0].id, copies[2].id])
    }

    func testAgeLabelsStopAtMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ClipboardHistoryAge.label(for: now.addingTimeInterval(-42), now: now), "Just now")
        XCTAssertFalse(ClipboardHistoryAge.label(for: now.addingTimeInterval(-125), now: now).contains("sec"))
        let old = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(ClipboardHistoryAge.label(for: old, now: now), old.formatted(date: .abbreviated, time: .shortened))
    }
}
