import Foundation
import XCTest
@testable import SpinnetCore

/// Builds page answers for the tests: an Emoji-like search page by default.
enum PageBuilder {
    static func item(_ id: String, _ title: String? = nil) -> JSONValue {
        .object(["id": .string(id), "title": .string(title ?? "item \(id)"), "symbol": .string("★")])
    }

    static func grid(_ id: String = "results", items: [String]? = nil, sections: [(String, [String])]? = nil,
                     selected: String? = nil, kind: String = "grid", columns: Int = 8,
                     rows: Int = 6) -> JSONValue {
        var members: [String: JSONValue] = [
            "kind": .string(kind), "id": .string(id),
            "actions": .array([
                .object(["id": .string("insert"), "title": .string("Insert"), "default": .bool(true)]),
                .object(["id": .string("copy"), "title": .string("Copy"), "perform": .string("clipboard.write")])
            ])
        ]
        if kind == "grid" { members["columns"] = .number(Double(columns)) }
        members["rows"] = .number(Double(rows))
        if let sections {
            members["sections"] = .array(sections.map { .object(["id": .string($0.0), "items": .array($0.1.map { item($0) })]) })
        } else {
            members["items"] = .array((items ?? []).map { item($0) })
        }
        if let selected { members["selected"] = .string(selected) }
        return .object(members)
    }

    static func field(_ id: String = "query", value: String = "", status: String? = nil,
                      searching collection: String? = "results") -> JSONValue {
        var members: [String: JSONValue] = ["kind": .string("text_field"), "id": .string(id), "title": .string("Search"),
                                            "value": .string(value)]
        if let collection { members["collection"] = .string(collection) }
        if let status { members["status"] = .string(status) }
        return .object(members)
    }

    static func choice(_ id: String = "category", value: String = "all") -> JSONValue {
        .object(["kind": .string("choice_field"), "id": .string(id), "title": .string("Category"),
                 "choices": .array(["all", "animals", "food"].map(JSONValue.string)), "value": .string(value)])
    }

    static func row(_ content: [JSONValue], id: String = "bar") -> JSONValue {
        .object(["kind": .string("row"), "id": .string(id), "content": .array(content)])
    }

    static func buttons(_ ids: [String]) -> JSONValue {
        .object(["kind": .string("actions"), "id": .string("buttons"),
                 "actions": .array(ids.map { .object(["id": .string($0), "title": .string($0.capitalized)]) })])
    }

    static func pageJSON(_ id: String = "search", _ content: [JSONValue], reset: JSONValue? = nil,
                         focus: String? = nil, showsTarget: Bool = true) -> JSONValue {
        var members: [String: JSONValue] = ["id": .string(id), "title": .string("Emoji"), "content": .array(content)]
        if let reset { members["reset"] = reset }
        if let focus { members["focus"] = .string(focus) }
        if showsTarget { members["shows_insertion_target"] = .bool(true) }
        return .object(members)
    }

    static func page(_ id: String = "search", _ content: [JSONValue], reset: JSONValue? = nil,
                     focus: String? = nil) throws -> PluginPage {
        try PluginPage(parsing: pageJSON(id, content, reset: reset, focus: focus), permits: permits)
    }

    /// What a Level 2 Plugin's pages may use.
    static var permits: (PluginInterfaceMember) -> Bool { CollectionsFixtures.permits }

    /// The Emoji search page: a row with the query and category, and a grid.
    static func search(query: String = "", items: [String] = ["A", "B", "C", "D"], reset: JSONValue? = nil,
                       status: String? = nil, selected: String? = nil) throws -> PluginPage {
        try page("search", [row([field(value: query, status: status), choice()]),
                            grid(items: items, selected: selected)], reset: reset)
    }

    static let resetResults = JSONValue.array([.string("results")])
}

/// The Host's immediate-state rules (ADR 0019) as `PluginPageMemory` applies
/// them for the renderer and the test kit alike.
final class PluginPageMemoryTests: XCTestCase {
    private typealias B = PageBuilder

    /// Scenario 01: an answer to another event while the user types keeps
    /// the text, caret, focus, selection and scroll; the new status is the
    /// Plugin's and shows.
    func testARefreshKeepsWhatTheUserIsDoing() throws {
        var memory = PluginPageMemory()
        let opened = memory.show(try B.search(query: "cat"))
        XCTAssertTrue(opened.pageChanged)
        XCTAssertEqual(memory.state.focus, "query", "The first text field is focused on a new page")
        memory.setText("cat f", of: "query", caret: PluginPageCaret(location: 5))
        memory.select("B")
        memory.state.scrollAnchors["results"] = "B"

        let refreshed = memory.show(try B.search(query: "cat", items: ["A", "B", "C", "D", "E"], status: "21 matches"))
        XCTAssertFalse(refreshed.pageChanged)
        XCTAssertEqual(refreshed.renewed, [])
        XCTAssertEqual(memory.state.texts["query"], "cat f", "value is an initial value only")
        XCTAssertEqual(memory.state.carets["query"], PluginPageCaret(location: 5))
        XCTAssertEqual(memory.state.focus, "query")
        XCTAssertEqual(memory.selectedItem?.id, "B")
        XCTAssertEqual(memory.state.scrollAnchors["results"], "B")
        guard case .textField(let field)? = memory.page?.component("query") else { return XCTFail("No field") }
        XCTAssertEqual(field.status, "21 matches")
    }

    /// Scenario 02: moving a component keeps its state; removing it discards
    /// it, and when it comes back it is new.
    func testComponentsAreKnownByIDAndKindWhereverTheyAre() throws {
        var memory = PluginPageMemory()
        memory.show(try B.search())
        memory.setText("cat", of: "query", caret: PluginPageCaret(location: 1))
        memory.setChoice("animals", of: "category")
        memory.show(try B.page("search", [B.field(), B.grid(items: ["A"])]))
        XCTAssertEqual(memory.state.texts["query"], "cat")
        XCTAssertEqual(memory.state.carets["query"], PluginPageCaret(location: 1))
        XCTAssertNil(memory.state.choices["category"])
        memory.show(try B.search())
        XCTAssertEqual(memory.state.choices["category"], "all", "A component that comes back starts from its value")
        XCTAssertEqual(memory.state.texts["query"], "cat")
    }

    /// Scenario 03: the same ID with another kind is a new component.
    func testAnotherKindIsANewComponent() throws {
        var memory = PluginPageMemory()
        memory.show(try B.search())
        memory.select("C")
        let applied = memory.show(try B.page("search", [B.row([B.field(), B.choice()]), B.grid(items: ["A", "B", "C"], kind: "list")]))
        XCTAssertEqual(applied.renewed, ["results"])
        XCTAssertEqual(memory.selectedItem?.id, "A", "A new collection selects its first item")
    }

    /// Scenario 04: reset is explicit and one-shot, and never interrupts a
    /// composition.
    func testResetIsExplicitOneShotAndSparesAComposition() throws {
        var memory = PluginPageMemory()
        memory.show(try B.search())
        memory.setText("cat", of: "query")
        memory.select("D")
        memory.state.scrollAnchors["results"] = "D"
        memory.show(try B.search(query: "", items: ["C", "D"], reset: B.resetResults))
        XCTAssertEqual(memory.selectedItem?.id, "C", "The new search starts on its first result")
        XCTAssertNil(memory.state.scrollAnchors["results"], "and at the top")
        XCTAssertEqual(memory.state.texts["query"], "cat", "The field was not reset")

        memory.show(try B.search(query: "other", items: ["C", "D"]))
        XCTAssertEqual(memory.state.texts["query"], "cat", "An answer without reset resets nothing")

        let applied = memory.show(try B.search(query: "", items: [], reset: .array([.string("query"), .string("results")])),
                                  composing: ["query"])
        XCTAssertEqual(applied.keptComposing, ["query"])
        XCTAssertEqual(memory.state.texts["query"], "cat", "The composing field's reset is dropped")
        XCTAssertNil(memory.selectedItem, "The rest of the reset applies")

        memory.state.focus = "results"
        memory.show(try B.search(query: "", items: ["A"], reset: .string("page")))
        XCTAssertEqual(memory.state.texts["query"], "")
        XCTAssertEqual(memory.state.focus, "query", "A reset page focuses as a new one does")
    }

    /// Scenario 05: another page ID is remembered with its state; returning
    /// to it restores what the user left; the fifth page forgets the
    /// oldest; a Level 1 view counts as a page change; reset "page" clears
    /// the memory.
    func testPageMemoryRemembersTheLastFourPages() throws {
        var memory = PluginPageMemory()
        memory.show(try B.search())
        memory.setText("py", of: "query", caret: PluginPageCaret(location: 2))
        memory.select("C")
        memory.state.focus = "query"
        let detail = memory.show(try B.page("detail:C", [B.buttons(["back"])]))
        XCTAssertTrue(detail.pageChanged)
        XCTAssertFalse(detail.restored)
        XCTAssertEqual(memory.rememberedPages, ["search"])
        let back = memory.show(try B.search())
        XCTAssertTrue(back.restored)
        XCTAssertEqual(memory.state.texts["query"], "py")
        XCTAssertEqual(memory.state.carets["query"], PluginPageCaret(location: 2))
        XCTAssertEqual(memory.selectedItem?.id, "C")
        XCTAssertEqual(memory.state.focus, "query")
        XCTAssertEqual(memory.rememberedPages, ["detail:C"])

        for id in ["one", "two", "three", "four", "five"] { memory.show(try B.page(id, [B.buttons(["back"])])) }
        XCTAssertEqual(memory.rememberedPages, ["four", "three", "two", "one"])
        memory.show(try B.search())
        XCTAssertEqual(memory.state.texts["query"], "", "search was not among the last 4 pages, so it is new")

        memory.setText("py", of: "query")
        memory.showLevelOneView()
        XCTAssertNil(memory.page)
        memory.show(try B.search())
        XCTAssertEqual(memory.state.texts["query"], "py", "A Level 1 view is a page change, not a reset")
        memory.show(try B.search(reset: .string("page")))
        XCTAssertEqual(memory.rememberedPages, [])
    }

    /// Scenario 15: without a reset the selection follows its item, else
    /// its position clamped to the last, else the first.
    func testSelectionFollowsItsItemThenItsPlace() throws {
        var memory = PluginPageMemory()
        memory.show(try B.search(items: ["A", "B", "C", "D"]))
        memory.select("C")
        memory.show(try B.search(items: ["C", "A", "B", "D"]))
        XCTAssertEqual(memory.selectedItem?.id, "C", "The selected item moved")
        memory.show(try B.search(items: ["A", "B", "D", "E"]))
        XCTAssertEqual(memory.selectedItem?.id, "A", "The item now at its place (0)")
        memory.select("E")
        memory.show(try B.search(items: ["A", "B"]))
        XCTAssertEqual(memory.selectedItem?.id, "B", "Clamped to the last")
        memory.show(try B.search(items: []))
        XCTAssertNil(memory.selectedItem)
        XCTAssertEqual(memory.selection, .object(["results": .null]))
        memory.show(try B.search(items: ["X", "Y"]))
        XCTAssertEqual(memory.selectedItem?.id, "X", "Items again: the first")
        memory.show(try B.search(items: ["X", "Y"], reset: B.resetResults, selected: "Y"))
        XCTAssertEqual(memory.selectedItem?.id, "Y", "A reset collection selects `selected`")
    }

    func testSnapshotsCarryEveryInputAndTheSelection() throws {
        var memory = PluginPageMemory()
        memory.show(try B.search())
        memory.setText("cat", of: "query")
        memory.setChoice("animals", of: "category")
        memory.setChoice("nonsense", of: "category")
        memory.select("B")
        XCTAssertEqual(memory.values, .object(["query": .string("cat"), "category": .string("animals")]))
        XCTAssertEqual(memory.selection, .object(["results": .string("B")]))
        memory.show(try B.page("detail", [B.buttons(["back"])]))
        XCTAssertEqual(memory.values, .object([:]))
        XCTAssertEqual(memory.selection, .object([:]), "A page without a collection selects nothing")
    }

    // MARK: Navigation

    /// Scenario 10: Up and Down move a grid row in the same column, Left and
    /// Right one item wrapping rows, and arrows cross sections with the
    /// column clamped.
    func testArrowsMoveThroughGridRowsAndSections() throws {
        // Section a: 10 items in rows of 4 (4, 4, 2); section b: 3 items.
        let ids = (0..<10).map { "a\($0)" }
        let page = try B.page("search", [B.field(), B.grid(sections: [("a", ids), ("b", ["b0", "b1", "b2"])], columns: 4, rows: 2)])
        let grid = PluginCollectionWindow(try XCTUnwrap(page.collection))
        func move(_ move: PluginPageCollection.Move, from id: String) -> String? {
            grid.index(moving: move, from: grid.position(of: id)).flatMap { grid.item(at: $0)?.id }
        }
        XCTAssertEqual(move(.down, from: "a1"), "a5")
        XCTAssertEqual(move(.down, from: "a7"), "a9", "The last row is shorter: the column is clamped")
        XCTAssertEqual(move(.down, from: "a9"), "b1", "Into the next section, same column")
        XCTAssertEqual(move(.down, from: "a8"), "b0")
        XCTAssertEqual(move(.up, from: "b2"), "a9", "Into the previous section's last row, column clamped")
        XCTAssertEqual(move(.up, from: "b0"), "a8")
        XCTAssertEqual(move(.up, from: "a2"), "a2", "Nothing above the first row")
        XCTAssertEqual(move(.down, from: "b1"), "b1")
        XCTAssertEqual(move(.right, from: "a3"), "a4", "Right wraps to the next row")
        XCTAssertEqual(move(.right, from: "a9"), "b0", "and into the next section")
        XCTAssertEqual(move(.left, from: "a0"), "a0")
        XCTAssertEqual(move(.pageDown, from: "a0"), "a8", "A screenful is `rows` rows")
        XCTAssertEqual(move(.home, from: "b1"), "a0")
        XCTAssertEqual(move(.end, from: "a0"), "b2")
        XCTAssertEqual(grid.index(moving: .down, from: nil), 0, "From no selection any move selects the first")

        let list = PluginCollectionWindow(try XCTUnwrap(try B.page("p", [B.grid(items: ["x", "y", "z"], kind: "list")]).collection))
        XCTAssertEqual(list.columns, 1)
        XCTAssertEqual(list.index(moving: .down, from: 0), 1)
        XCTAssertEqual(list.index(moving: .up, from: 1), 0)
        XCTAssertNil(PluginCollectionWindow(try XCTUnwrap(try B.page("p", [B.grid(items: [])]).collection))
            .index(moving: .down, from: nil))
    }

    func testMovingTheSelectionSelects() throws {
        var memory = PluginPageMemory()
        memory.show(try B.search(items: ["A", "B", "C", "D", "E", "F", "G", "H", "I"]))
        XCTAssertEqual(memory.moveSelection(.down), 8, "One grid row of 8 down from A")
        XCTAssertEqual(memory.selectedItem?.id, "I")
        XCTAssertEqual(memory.moveSelection(.left), 7)
        XCTAssertEqual(memory.selectedItem?.id, "H")
    }
}
