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

    /// An image the pasteboard did not name goes by a link copied with it,
    /// or else by the number the store gave it.
    func testImageTitlesPreferANameThenALinkThenTheNumber() {
        func image(_ text: String = "Image 3", format: String = "public.png", bundleID: String = "notes") -> ClipboardHistoryEntry {
            var entry = ClipboardHistoryEntry(id: UUID(), text: text, contentType: .image, sourceApplicationName: "App",
                                              sourceBundleIdentifier: bundleID, copiedAt: Date())
            entry.format = format
            entry.itemIndex = 0
            return entry
        }
        func title(_ entries: [ClipboardHistoryEntry]) -> String {
            let presentation = ClipboardHistoryCopyPresentation(copy: ClipboardHistoryCopy(id: UUID(), representations: entries))
            return presentation.title(for: entries[0])
        }
        var link = ClipboardHistoryEntry(id: UUID(), text: "https://example.com/photos/Beach%20Day.jpg?s=2", contentType: .url,
                                         sourceApplicationName: "Safari", sourceBundleIdentifier: "safari", copiedAt: Date())
        link.itemIndex = 0

        XCTAssertEqual(title([image("Cat Nap.png"), link]), "Cat Nap.png")
        XCTAssertEqual(title([image(), link]), "Beach Day.jpg")
        XCTAssertEqual(title([image()]), "Image 3")
        XCTAssertEqual(title([image("Image 12 of the tour"), link]), "Image 12 of the tour", "a name that only starts like a number")
        let text = copy("hello", .text, app: "Notes")
        XCTAssertEqual(ClipboardHistoryCopyPresentation(copy: text).title(for: text.representations[0]), "hello")
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
