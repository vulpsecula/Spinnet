import Foundation
import XCTest
@testable import SpinnetCore

/// Resizable pages and adaptive Grid columns (#80), appended to Plugin API
/// Level 2: a page declares whether its panel may be resized, and a Grid may
/// let the Host choose its columns from the width it has.
final class PageSizingTests: XCTestCase {
    private func page(_ members: [String: JSONValue] = [:], grid: [String: JSONValue]? = nil) -> JSONValue {
        var collection: [String: JSONValue] = ["kind": .string("grid"), "id": .string("results"),
                                               "items": .array((0..<30).map { .object(["id": .string("i\($0)"),
                                                                                       "title": .string("\($0)")]) })]
        for (key, value) in grid ?? [:] { collection[key] = value }
        var page: [String: JSONValue] = ["id": .string("p"), "title": .string("P"), "content": .array([.object(collection)])]
        for (key, value) in members { page[key] = value }
        return .object(["page": .object(page)])
    }

    private func parse(_ answer: JSONValue, permits: (PluginInterfaceMember) -> Bool = CollectionsFixtures.permits) throws -> PluginPage {
        try XCTUnwrap(try PluginScriptAnswer(parsing: answer, permits: permits).page)
    }

    private func refusal(_ answer: JSONValue, permits: (PluginInterfaceMember) -> Bool = CollectionsFixtures.permits) -> String? {
        do {
            _ = try PluginScriptAnswer(parsing: answer, permits: permits)
            return nil
        } catch PluginRuntimeError.protocolViolation(let message) {
            return message
        } catch {
            return "\(error)"
        }
    }

    // MARK: The contract

    func testTheAdditionIsLevelTwosAndNotLevelOnes() {
        for member in PageSizing.members {
            XCTAssertTrue(CollectionsFixtures.permits(member), "\(member)")
            XCTAssertFalse(CollectionsFixtures.levelOne(member), "\(member)")
        }
        XCTAssertTrue(Set(PageSizing.members).isSubset(of: PluginInterfaceContracts.levelTwoMembers))
    }

    /// A Plugin the addition is not offered to has neither member.
    func testWithoutTheAdditionTheMembersAreUnknown() {
        let earlier = Set(PluginInterfaceContracts.levelTwoMembers).subtracting(PageSizing.members)
        let permits: (PluginInterfaceMember) -> Bool = { earlier.contains($0) }
        XCTAssertEqual(refusal(page(["resizable": .bool(true)]), permits: permits), "The page has unknown member resizable")
        XCTAssertEqual(refusal(page(grid: ["columns": .string("auto")]), permits: permits),
                       "The grid results's columns is not a whole number from 2 to 12")
    }

    /// The published fixtures read as the schema says.
    func testThePublishedFixturesAgree() throws {
        let fixtures = PagesContractTests.pluginAPI.appendingPathComponent("fixtures/pages")
        func answer(_ file: String) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtures.appendingPathComponent(file)))
        }
        let emoji = try parse(answer("answers/emoji-resizable.json"))
        XCTAssertEqual(emoji.resizing, PluginPageResizing(minimumHeight: 240))
        XCTAssertEqual(emoji.collection?.minimumCellSize, 44)
        XCTAssertEqual(refusal(try answer("answers/resizable-too-narrow.json")),
                       "The page search's resizable min_width is not a number from 440 to 1200")
        XCTAssertEqual(refusal(try answer("answers/min-cell-size-fixed-columns.json")),
                       "The grid results gives min_cell_size without columns \"auto\"")
    }

    // MARK: Resizable pages

    func testAPageIsNotResizableUnlessItSaysSo() throws {
        XCTAssertNil(try parse(page()).resizing)
        XCTAssertNil(try parse(page(["resizable": .bool(false)])).resizing)
        XCTAssertEqual(try parse(page(["resizable": .bool(true)])).resizing,
                       PluginPageResizing(minimumWidth: 440, minimumHeight: 160))
        XCTAssertEqual(try parse(page(["resizable": .object(["min_width": .number(520), "min_height": .number(300)])])).resizing,
                       PluginPageResizing(minimumWidth: 520, minimumHeight: 300))
        XCTAssertEqual(try parse(page(["resizable": .object(["min_height": .number(240)])])).resizing,
                       PluginPageResizing(minimumWidth: 440, minimumHeight: 240))
    }

    func testTheMinimumSizeIsBounded() {
        XCTAssertEqual(refusal(page(["resizable": .object(["min_width": .number(300)])])),
                       "The page p's resizable min_width is not a number from 440 to 1200")
        XCTAssertEqual(refusal(page(["resizable": .object(["min_height": .number(2000)])])),
                       "The page p's resizable min_height is not a number from 120 to 900")
        XCTAssertEqual(refusal(page(["resizable": .object(["max_width": .number(600)])])),
                       "The page p's resizable has unknown member max_width")
        XCTAssertEqual(refusal(page(["resizable": .string("yes")])),
                       "The page p's resizable is neither true, false nor an object")
    }

    // MARK: Adaptive Grid columns

    func testAnAdaptiveGridStartsWithTheColumnsTheDefaultWidthHolds() throws {
        let collection = try XCTUnwrap(try parse(page(grid: ["columns": .string("auto")])).collection)
        XCTAssertEqual(collection.minimumCellSize, PageSizing.defaultMinimumCellSize)
        XCTAssertEqual(collection.columns, PageSizing.columns(fitting: PageSizing.defaultItemsWidth,
                                                              minimumCellSize: PageSizing.defaultMinimumCellSize))
        XCTAssertEqual(collection.columns, 8)
        let larger = try XCTUnwrap(try parse(page(grid: ["columns": .string("auto"), "min_cell_size": .number(64)])).collection)
        XCTAssertEqual(larger.columns, 6)
        let fixed = try XCTUnwrap(try parse(page(grid: ["columns": .number(5)])).collection)
        XCTAssertNil(fixed.minimumCellSize)
        XCTAssertEqual(fixed.columns, 5)
    }

    func testTheMinimumCellSizeIsBoundedAndNeedsAdaptiveColumns() {
        XCTAssertEqual(refusal(page(grid: ["columns": .string("auto"), "min_cell_size": .number(20)])),
                       "The grid results's min_cell_size is not a number from 32 to 128")
        XCTAssertEqual(refusal(page(grid: ["columns": .number(8), "min_cell_size": .number(48)])),
                       "The grid results gives min_cell_size without columns \"auto\"")
        XCTAssertEqual(refusal(page(grid: ["min_cell_size": .number(48)])),
                       "The grid results gives min_cell_size without columns \"auto\"")
    }

    func testColumnsFollowTheWidthWithinBounds() {
        XCTAssertEqual(PageSizing.columns(fitting: 400, minimumCellSize: 48), 8)
        XCTAssertEqual(PageSizing.columns(fitting: 800, minimumCellSize: 48), 16)
        XCTAssertEqual(PageSizing.columns(fitting: 50, minimumCellSize: 48), PageSizing.adaptiveColumns.lowerBound)
        XCTAssertEqual(PageSizing.columns(fitting: 5_000, minimumCellSize: 32), PageSizing.adaptiveColumns.upperBound)
    }

    // MARK: The window

    func testAnAdaptiveWindowTakesTheColumnsItsWidthHolds() throws {
        let collection = try XCTUnwrap(try parse(page(grid: ["columns": .string("auto"), "rows": .number(3)])).collection)
        var window = PluginCollectionWindow(collection)
        XCTAssertEqual(window.columns, 8)
        XCTAssertTrue(window.fit(itemsWidth: 800, visibleRows: 5))
        XCTAssertEqual(window.columns, 16)
        XCTAssertEqual(window.rows, 5)
        XCTAssertEqual(window.screen, 80)
        XCTAssertFalse(window.fit(itemsWidth: 800, visibleRows: 5), "Nothing changed")
        // Moving down a row moves by the columns there are now.
        XCTAssertEqual(window.index(moving: .down, from: 0), 16)

        // A later answer for the same Grid keeps what the width holds.
        window.merge(collection, answersRange: false)
        XCTAssertEqual(window.columns, 16)
        XCTAssertEqual(window.rows, 5)
    }

    func testAFixedWindowKeepsItsColumnsAtAnyWidth() throws {
        let collection = try XCTUnwrap(try parse(page(grid: ["columns": .number(6)])).collection)
        var window = PluginCollectionWindow(collection)
        XCTAssertTrue(window.fit(itemsWidth: 900, visibleRows: 9))
        XCTAssertEqual(window.columns, 6)
        XCTAssertEqual(window.rows, 9)
    }
}
