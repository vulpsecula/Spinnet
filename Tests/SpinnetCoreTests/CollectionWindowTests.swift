import Foundation
import XCTest
@testable import SpinnetCore

/// Candidate Contract `collections` r3's windows, as `PluginPageMemory`
/// keeps them for the Host and the test kit alike: a collection gives its
/// total and a slice, the Host holds only the items around the screen, asks
/// for what the screen lacks, keeps the selection by ID while its item is
/// let go, and refreshes what an answer to something else may have
/// outdated.
final class CollectionWindowTests: XCTestCase {
    private typealias B = PageBuilder

    /// A grid of `total` items `i0`, `i1`, … of which the answer gives
    /// `start..<start + count`, 8 columns by 6 rows.
    private static func page(total: Int, start: Int = 0, count: Int = 200, sections: [(String, Int)]? = nil,
                             marked: Set<Int> = [], reset: Bool = false, prefix: String = "i") throws -> PluginPage {
        let end = min(start + count, total)
        var grid: [String: JSONValue] = [
            "kind": .string("grid"), "id": .string("results"), "columns": .number(8), "rows": .number(6),
            "total": .number(Double(total)), "start": .number(Double(start)),
            "items": .array((start..<end).map { index in
                var item: [String: JSONValue] = ["id": .string("\(prefix)\(index)"), "title": .string("item \(index)"),
                                                 "symbol": .string("★")]
                if marked.contains(index) { item["marks"] = .array([.string("favourite")]) }
                return .object(item)
            }),
            "actions": .array([
                .object(["id": .string("insert"), "title": .string("Insert"), "default": .bool(true)]),
                .object(["id": .string("favourite"), "title": .string("Favourite"), "toggle": .string("favourite")])
            ])
        ]
        if let sections {
            grid["sections"] = .array(sections.map { .object(["id": .string($0.0), "title": .string($0.0),
                                                              "count": .number(Double($0.1))]) })
        }
        return try PluginPage(parsing: B.pageJSON("search", [B.field(), .object(grid)],
                                                  reset: reset ? .array([.string("results")]) : nil),
                              permits: CollectionsFixtures.permits)
    }

    func testANewWindowHoldsTheScreenAndTwoMoreAndAsksForNothing() throws {
        var memory = PluginPageMemory()
        memory.show(try Self.page(total: 1906))
        let window = try XCTUnwrap(memory.window)
        XCTAssertTrue(window.isWindowed)
        XCTAssertEqual(window.total, 1906)
        XCTAssertEqual(window.heldPositions, Array(0..<144), "One screen of 48 and two below it")
        XCTAssertNil(memory.missingRange)
        XCTAssertEqual(memory.selectedItem?.id, "i0")
        XCTAssertEqual(memory.selectedPosition, 0)
    }

    /// Scrolling lets go of what is far and asks for what the screen lacks,
    /// within the window, at most 600 positions.
    func testScrollingAsksForTheRangeTheScreenLacks() throws {
        var memory = PluginPageMemory()
        memory.show(try Self.page(total: 1906))
        memory.setViewport(48..<96)
        XCTAssertNil(memory.missingRange, "Held up to a screen below")
        memory.setViewport(144..<192)
        XCTAssertEqual(memory.missingRange, 144..<288, "What is missing within two screens")
        XCTAssertEqual(memory.window?.heldPositions.first, 48, "Two screens above are kept")

        memory.setViewport(1000..<1048)
        XCTAssertEqual(memory.window?.heldCount, 0, "Nothing near is held")
        XCTAssertEqual(memory.missingRange, 904..<1144)
        memory.show(try Self.page(total: 1906, start: 904, count: 240), answersRange: true)
        XCTAssertNil(memory.missingRange)
        XCTAssertEqual(memory.window?.item(at: 1000)?.id, "i1000")
        XCTAssertEqual(memory.selectedItem?.id, "i0", "The selection is kept by ID while its item is let go")
        XCTAssertNil(memory.window?.item(at: 0))
    }

    func testTheWindowHoldsAtMostSixHundred() throws {
        var memory = PluginPageMemory()
        var grid = try Self.page(total: 2000, count: 2000)
        memory.show(grid)
        XCTAssertEqual(memory.window?.heldCount, 144)
        // Twelve columns of twelve rows: five screens are 720 positions.
        let wide = try PluginPage(parsing: B.pageJSON("search", [B.field(), .object([
            "kind": .string("grid"), "id": .string("results"), "columns": .number(12), "rows": .number(12),
            "total": .number(2000), "items": .array((0..<2000).map { .object(["id": .string("w\($0)"), "title": .string("w")]) })
        ])]), permits: CollectionsFixtures.permits)
        grid = wide
        var other = PluginPageMemory()
        other.show(grid)
        other.setViewport(1000..<1144)
        XCTAssertEqual(other.window?.heldCount, 0)
        let range = try XCTUnwrap(other.missingRange)
        XCTAssertEqual(range.count, CollectionsContract.maximumWindowItems)
        XCTAssertTrue(range.contains(1000) && range.contains(1143))
        other.show(try PluginPage(parsing: B.pageJSON("search", [B.field(), .object([
            "kind": .string("grid"), "id": .string("results"), "columns": .number(12), "rows": .number(12),
            "total": .number(2000), "start": .number(0),
            "items": .array((0..<2000).map { .object(["id": .string("w\($0)"), "title": .string("w")]) })
        ])]), permits: CollectionsFixtures.permits), answersRange: true)
        XCTAssertEqual(other.window?.heldCount, CollectionsContract.maximumWindowItems)
    }

    /// Moving onto a position the Host does not hold selects the position
    /// and asks for it; the item there is selected when it comes.
    func testASelectionOnAPlaceholderTakesItsItemWhenItComes() throws {
        var memory = PluginPageMemory()
        memory.show(try Self.page(total: 1906))
        XCTAssertEqual(memory.moveSelection(.end), 1905)
        XCTAssertNil(memory.selectedItem, "Nothing to act on yet")
        XCTAssertEqual(memory.selection, .object(["results": .null]))
        memory.setViewport(1864..<1906)
        let range = try XCTUnwrap(memory.missingRange)
        XCTAssertEqual(range.upperBound, 1906)
        memory.show(try Self.page(total: 1906, start: range.lowerBound, count: range.count), answersRange: true)
        XCTAssertEqual(memory.selectedItem?.id, "i1905")
        XCTAssertEqual(memory.selectedSnapshot, PluginPageItemSnapshot(id: "i1905", section: nil, text: "★"))
    }

    /// An answer to anything but `load_range` that keeps the layout leaves
    /// the items it does not give shown but outdated, so the Host asks for
    /// the screen again; one that changes the total drops them.
    func testAnswersToOtherEventsRefreshWhatTheyDoNotGive() throws {
        var memory = PluginPageMemory()
        memory.show(try Self.page(total: 1906))
        memory.setViewport(1000..<1048)
        memory.show(try Self.page(total: 1906, start: 904, count: 240), answersRange: true)
        XCTAssertNil(memory.missingRange)

        // A favourite toggled from the menu: the answer gives the first 200.
        memory.show(try Self.page(total: 1906, marked: [1001]))
        XCTAssertEqual(memory.window?.item(at: 1000)?.id, "i1000", "Still shown")
        XCTAssertEqual(memory.window?.isStale(1000), true)
        XCTAssertEqual(memory.missingRange, 904..<1144)
        memory.show(try Self.page(total: 1906, start: 904, count: 240, marked: [1001]), answersRange: true)
        XCTAssertEqual(memory.window?.item(at: 1001)?.marks, ["favourite"])
        XCTAssertNil(memory.missingRange)

        // A favourite added above: positions mean something else now.
        let layout = memory.window?.layoutRevision
        let applied = memory.show(try Self.page(total: 1907, prefix: "j"))
        XCTAssertTrue(applied.layoutChanged)
        XCTAssertNotEqual(memory.window?.layoutRevision, layout)
        XCTAssertNil(memory.window?.item(at: 1000), "Dropped")
        XCTAssertEqual(memory.missingRange, 904..<1144)
    }

    /// The selection follows its item by ID, else its place once an answer
    /// shows what is there.
    func testTheSelectionFollowsItsItemAcrossRanges() throws {
        var memory = PluginPageMemory()
        memory.show(try Self.page(total: 1906))
        memory.setViewport(1000..<1048)
        memory.show(try Self.page(total: 1906, start: 904, count: 240), answersRange: true)
        memory.select("i1010")
        // Something was added above: i1010 is now at 1011.
        memory.show(try Self.page(total: 1907, prefix: "i"))
        XCTAssertEqual(memory.selectedItem?.id, "i1010", "Kept by ID")
        XCTAssertEqual(memory.selectedPosition, 1010)
        let shifted = try PluginPage(parsing: B.pageJSON("search", [B.field(), .object([
            "kind": .string("grid"), "id": .string("results"), "columns": .number(8), "rows": .number(6),
            "total": .number(1907), "start": .number(1000),
            "items": .array((1000..<1100).map { .object(["id": .string("i\($0 - 1)"), "title": .string("t")]) })
        ])]), permits: CollectionsFixtures.permits)
        memory.show(shifted, answersRange: true)
        XCTAssertEqual(memory.selectedPosition, 1011, "Found at its new place")

        // Its item left: the item now at its place is selected.
        let gone = try PluginPage(parsing: B.pageJSON("search", [B.field(), .object([
            "kind": .string("grid"), "id": .string("results"), "columns": .number(8), "rows": .number(6),
            "total": .number(1907), "start": .number(1000),
            "items": .array((1000..<1100).map { .object(["id": .string("k\($0)"), "title": .string("t")]) })
        ])]), permits: CollectionsFixtures.permits)
        memory.show(gone, answersRange: true)
        XCTAssertEqual(memory.selectedItem?.id, "k1011")
    }

    /// A range asked for that did not come is not asked for again until
    /// the layout changes or the user moves onto it.
    func testARangeThatDidNotComeIsNotAskedAgain() throws {
        var memory = PluginPageMemory()
        memory.show(try Self.page(total: 1906))
        memory.setViewport(1000..<1048)
        let range = try XCTUnwrap(memory.missingRange)
        memory.settleRange(range)
        XCTAssertNil(memory.missingRange)
        memory.select(position: 1020)
        XCTAssertEqual(memory.missingRange, 1020..<1021, "Moving onto it asks again")
        memory.show(try Self.page(total: 1905), answersRange: false)
        memory.setViewport(1000..<1048)
        XCTAssertNotNil(memory.missingRange, "A new layout asks again")
    }

    /// Sections are headers counting their items; navigation crosses them
    /// by position, items held or not.
    func testSectionHeadersAndNavigationByPosition() throws {
        var memory = PluginPageMemory()
        memory.show(try Self.page(total: 30, count: 10, sections: [("a", 10), ("b", 20)]))
        let window = try XCTUnwrap(memory.window)
        XCTAssertEqual(window.sections.map(\.range), [0..<10, 10..<30])
        XCTAssertEqual(window.index(moving: .down, from: 9), 11, "Into b's first row, same column")
        XCTAssertEqual(window.index(moving: .end, from: 0), 29)
        XCTAssertEqual(window.snapshot(at: 3)?.section, "a")
        XCTAssertNil(window.snapshot(at: 12), "Not held")
    }

    /// A whole collection is the window it gives: everything held, nothing
    /// asked, revision 2's appending unchanged.
    func testAWholeCollectionIsHeldEntire() throws {
        var memory = PluginPageMemory()
        memory.show(try B.search(items: (0..<300).map { "x\($0)" }))
        let window = try XCTUnwrap(memory.window)
        XCTAssertFalse(window.isWindowed)
        XCTAssertEqual(window.heldCount, 300)
        memory.setViewport(250..<298)
        XCTAssertEqual(memory.window?.heldCount, 300)
        XCTAssertNil(memory.missingRange)
    }
}
