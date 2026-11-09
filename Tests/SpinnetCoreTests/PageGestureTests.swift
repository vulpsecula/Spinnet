import Foundation
import XCTest
@testable import SpinnetCore

/// The user's gestures on a page's Collection, as `PluginPageMemory` handles
/// them for the Host and the test kit alike: how each changes the Selection,
/// what the drawing should do about it, which event or operation follows,
/// and when `selection_changed` is due (ADR 0025).
final class PageGestureTests: XCTestCase {
    private typealias Handled = PluginPageMemory.Handled

    private static func item(_ id: String, marks: [String] = []) -> JSONValue {
        var item: [String: JSONValue] = ["id": .string(id), "title": .string("Item \(id)"), "text": .string(id.uppercased())]
        if !marks.isEmpty { item["marks"] = .array(marks.map(JSONValue.string)) }
        return .object(item)
    }

    private static let actions: [JSONValue] = [
        .object(["id": .string("open"), "title": .string("Open"), "default": .bool(true)]),
        .object(["id": .string("rename"), "title": .string("Rename"), "single": .bool(true)]),
        .object(["id": .string("pin"), "title": .string("Pin"), "toggle": .string("pinned")]),
        .object(["id": .string("copy"), "title": .string("Copy"), "perform": .string("clipboard.write")])
    ]

    /// A note field and a List of `ids`, multiple unless told otherwise.
    private func memory(_ ids: [String] = ["a", "b", "c", "d", "e"], multiple: Bool = true, events: Bool = false,
                        pinned: Set<String> = [], actions: [JSONValue]? = nil) throws -> PluginPageMemory {
        var list: [String: JSONValue] = [
            "kind": .string("list"), "id": .string("results"),
            "items": .array(ids.map { Self.item($0, marks: pinned.contains($0) ? ["pinned"] : []) }),
            "actions": .array(actions ?? (multiple ? Self.actions : Self.actions.filter { $0.value(atPointer: "/single") == nil }))
        ]
        if multiple { list["selection"] = .string("multiple") }
        if events { list["selection_events"] = .bool(true) }
        var memory = PluginPageMemory()
        memory.show(try page(.object(list)))
        return memory
    }

    private func page(_ list: JSONValue, id: String = "clips") throws -> PluginPage {
        try PluginPage(parsing: .object(["id": .string(id), "title": .string("Clips"), "content": .array([
            .object(["kind": .string("text_field"), "id": .string("note"), "title": .string("Note")]),
            list
        ])]), permits: CollectionsFixtures.permits)
    }

    private func at(_ id: String, _ memory: PluginPageMemory) -> Int { memory.window?.position(of: id) ?? -1 }

    private func ids(_ memory: PluginPageMemory) -> [String] { memory.selectedItems.map(\.id) }

    private func snapshot(_ id: String, marks: [String] = []) -> PluginPageItemSnapshot {
        PluginPageItemSnapshot(id: id, section: nil, text: id.uppercased(), marks: marks)
    }

    private func itemAction(_ action: String, on item: String, items: [String]?) -> PluginPageMemory.ItemGesture {
        .deliver(.itemAction(page: "clips", collection: "results", action: action, item: snapshot(item),
                             values: .object(["note": .string("")]), items: items?.map { snapshot($0) }))
    }

    // MARK: Clicks

    /// ⌘ adds or removes an item, Shift selects from the anchor, a plain
    /// click selects one item; each focuses the Collection and redraws it.
    func testClicksWithModifiersChangeAMultipleSelection() throws {
        var memory = try memory()
        let handled = memory.click(at: at("c", memory), modifier: .command)
        XCTAssertEqual(ids(memory), ["a", "c"])
        XCTAssertEqual(memory.selectedItem?.id, "c", "The ⌘-clicked item is focused")
        XCTAssertEqual(handled.focus, "results")
        XCTAssertEqual(handled.redraw, .all)
        memory.click(at: at("a", memory), modifier: .command)
        XCTAssertEqual(ids(memory), ["c"])
        memory.click(at: at("c", memory), modifier: .command)
        XCTAssertEqual(ids(memory), ["c"], "The last selected item stays selected")
        memory.click(at: at("e", memory), modifier: .shift)
        XCTAssertEqual(ids(memory), ["c", "d", "e"])
        memory.click(at: at("b", memory), modifier: .shift)
        XCTAssertEqual(ids(memory), ["b", "c"], "The range runs from the anchor, c")
        memory.click(at: at("d", memory))
        XCTAssertEqual(ids(memory), ["d"])
    }

    /// A single Collection ignores the modifiers: a click moves its
    /// selection, redrawing the two cells.
    func testASingleCollectionsClickMovesItsSelection() throws {
        var memory = try memory(multiple: false)
        let handled = memory.click(at: 2, modifier: .command)
        XCTAssertEqual(ids(memory), ["c"])
        XCTAssertEqual(handled.redraw, .moved(from: 0, to: 2))
        XCTAssertEqual(handled.focus, "results")
        XCTAssertNil(handled.gesture)
        XCTAssertEqual(memory.click(at: 9), Handled(), "No cell there")
    }

    // MARK: Double-click

    /// The first click of a double-click on an item of the selection reduces
    /// the selection to it; the second restores the selection it had and
    /// runs the default once for all of it, starting on that item.
    func testADoubleClickActsOnTheSelectionItsFirstClickReduced() throws {
        var memory = try memory()
        memory.click(at: at("b", memory))
        memory.click(at: at("d", memory), modifier: .command)
        memory.click(at: at("b", memory))
        XCTAssertEqual(ids(memory), ["b"])
        let handled = memory.doubleClick(at: at("b", memory))
        XCTAssertEqual(ids(memory), ["b", "d"])
        XCTAssertEqual(memory.selectedItem?.id, "b")
        XCTAssertEqual(handled.gesture, itemAction("open", on: "b", items: ["b", "d"]))
        memory.click(at: at("b", memory), modifier: .shift)
        XCTAssertEqual(ids(memory), ["b", "c", "d"], "The anchor is d again, as before the first click")
    }

    /// On an item outside the selection, the first click selected it and
    /// the default runs on it alone.
    func testADoubleClickElsewhereActsOnThatItem() throws {
        var memory = try memory()
        memory.click(at: at("d", memory), modifier: .command)
        memory.click(at: at("e", memory))
        XCTAssertEqual(memory.doubleClick(at: at("e", memory)).gesture, itemAction("open", on: "e", items: ["e"]))
        XCTAssertEqual(ids(memory), ["e"])
    }

    /// A single item default does nothing while several items are selected.
    func testADoubleClickRunsNoSingleItemDefaultForSeveral() throws {
        var memory = try memory(actions: [.object(["id": .string("open"), "title": .string("Open"),
                                                   "default": .bool(true), "single": .bool(true)])])
        memory.click(at: at("c", memory), modifier: .shift)
        XCTAssertNil(memory.doubleClick(at: at("c", memory)).gesture)
        XCTAssertNil(memory.pressReturn().gesture)
    }

    // MARK: Right click and the context menu

    /// A right click within the selection keeps it and focuses the item;
    /// elsewhere it selects the item, as a click does.
    func testARightClickKeepsTheSelectionItIsIn() throws {
        var memory = try memory()
        memory.click(at: at("b", memory))
        memory.click(at: at("d", memory), modifier: .command)
        let handled = memory.rightClick(at: at("b", memory))
        XCTAssertEqual(ids(memory), ["b", "d"])
        XCTAssertEqual(memory.selectedItem?.id, "b")
        XCTAssertEqual(handled.redraw, .all)
        memory.rightClick(at: at("e", memory))
        XCTAssertEqual(ids(memory), ["e"])
    }

    /// The menu is the selection's only while more than one item is
    /// selected: what every selected item offers, a single item action
    /// disabled, a toggle checked when every one carries its mark.
    /// Otherwise it is the item's own.
    func testTheContextMenuIsTheSelectionsOnlyForSeveralItems() throws {
        var memory = try memory(pinned: ["a", "b"])
        let own = memory.contextMenu(at: at("a", memory))
        XCTAssertEqual(own.map(\.action.id), ["open", "rename", "pin", "copy"])
        XCTAssertEqual(own.map(\.isEnabled), [true, true, true, true])
        XCTAssertEqual(own.map(\.isChecked), [false, false, true, false])
        XCTAssertEqual(memory.contextMenu(at: at("c", memory)).map(\.isChecked), [false, false, false, false],
                       "Another item's own menu")
        memory.click(at: at("b", memory), modifier: .shift)
        let both = memory.contextMenu(at: at("b", memory))
        XCTAssertEqual(both.map(\.isEnabled), [true, false, true, true])
        XCTAssertEqual(both.map(\.isChecked), [false, false, true, false])
        memory.click(at: at("c", memory), modifier: .shift)
        XCTAssertEqual(memory.contextMenu(at: at("c", memory)).map(\.isChecked), [false, false, false, false],
                       "c does not carry the mark")
        XCTAssertEqual(memory.itemMenu(at: at("a", memory)).map(\.isChecked), [false, false, true, false],
                       "An item's own menu, whatever is selected")
    }

    /// An item action chosen on an item of the selection acts on all of it;
    /// on another item it selects that item first.
    func testChoosingFromTheMenuActsOnTheSelectionOrTheItem() throws {
        var memory = try memory()
        memory.click(at: at("b", memory))
        memory.click(at: at("d", memory), modifier: .command)
        let pin = try XCTUnwrap(memory.page?.collection?.actions.first { $0.id == "pin" })
        XCTAssertEqual(memory.choose(pin, at: at("b", memory)).gesture, itemAction("pin", on: "b", items: ["b", "d"]))
        XCTAssertEqual(memory.choose(pin, at: at("e", memory)).gesture, itemAction("pin", on: "e", items: ["e"]))
        XCTAssertEqual(ids(memory), ["e"])
    }

    /// A row's toggle acts on its row alone, which it selects.
    func testARowsToggleActsOnItsRowAlone() throws {
        var memory = try memory()
        memory.click(at: at("b", memory), modifier: .shift)
        let pin = try XCTUnwrap(memory.page?.collection?.actions.first { $0.id == "pin" })
        let handled = memory.chooseAlone(pin, at: at("b", memory))
        XCTAssertEqual(ids(memory), ["b"])
        XCTAssertEqual(handled.redraw, .all)
        XCTAssertEqual(handled.gesture, itemAction("pin", on: "b", items: ["b"]))
    }

    // MARK: Return and ⌘C

    /// Return in a field that searches nothing submits it with the
    /// selection; in the Collection it runs the default on the selection.
    func testReturnSubmitsAFieldOrRunsTheDefault() throws {
        var memory = try memory()
        memory.click(at: at("c", memory), modifier: .command)
        XCTAssertEqual(memory.pressReturn(in: "note").submitted, .pageSubmitted(
            page: "clips", field: "note", values: .object(["note": .string("")]),
            selection: .object(["results": .array([.string("a"), .string("c")])])))
        XCTAssertEqual(memory.pressReturn().gesture, itemAction("open", on: "c", items: ["a", "c"]))
    }

    /// ⌘C performs the sole `clipboard.write` item action on the selection,
    /// the texts one per line; nothing without one.
    func testCopyPerformsTheSoleCopyAction() throws {
        var memory = try memory()
        memory.click(at: at("d", memory), modifier: .command)
        guard case .perform(let copy)? = memory.copySelection()?.gesture else { return XCTFail("No copy") }
        XCTAssertEqual(copy.input, .object(["text": .string("A\nD")]))
        var plain = try self.memory(actions: [Self.actions[0]])
        XCTAssertNil(plain.copySelection())
    }

    // MARK: Keys

    /// An arrow moves the selection and keeps it in view; Shift extends a
    /// multiple one; ⌘A selects every item and a single Collection has no
    /// ⌘A.
    func testKeysMoveExtendAndSelectAll() throws {
        var memory = try memory()
        let moved = try XCTUnwrap(memory.press(.down))
        XCTAssertEqual(ids(memory), ["b"])
        XCTAssertEqual(moved.redraw, .moved(from: 0, to: 1))
        XCTAssertEqual(moved.reveal, 1)
        let extended = try XCTUnwrap(memory.press(.down, extending: true))
        XCTAssertEqual(ids(memory), ["b", "c"])
        XCTAssertEqual(extended.redraw, .all)
        XCTAssertEqual(memory.press(.down)?.redraw, .all, "A group gives way to one item")
        XCTAssertEqual(memory.selectAll()?.redraw, .all)
        XCTAssertEqual(ids(memory), ["a", "b", "c", "d", "e"])
        var single = try self.memory(multiple: false)
        XCTAssertNil(single.selectAll())
        XCTAssertEqual(single.press(.down, extending: true)?.redraw, .moved(from: 0, to: 1))
    }

    // MARK: selection_changed

    /// A change the user makes settles into one `selection_changed`, sent
    /// only when the selection is somewhere the Plugin has not heard of.
    func testAUsersChangeSettlesIntoOneEvent() throws {
        var memory = try memory(multiple: false, events: true)
        XCTAssertFalse(memory.isSettlingSelection, "The initial selection is the Plugin's")
        XCTAssertTrue(memory.click(at: 2).settling)
        XCTAssertTrue(memory.isSettlingSelection)
        XCTAssertEqual(memory.settleSelection(), .selectionChanged(page: "clips", collection: "results",
                                                                     items: [snapshot("c")], values: .object(["note": .string("")])))
        XCTAssertNil(memory.settleSelection(), "Settled once")
        memory.click(at: 3)
        memory.click(at: 2)
        XCTAssertNil(memory.settleSelection(), "Back where the Plugin last heard it was")
        var silent = try self.memory(multiple: false)
        XCTAssertFalse(silent.click(at: 2).settling, "Without selection_events nothing settles")
    }

    /// A gesture on a selection still settling delivers its
    /// `selection_changed` first.
    func testAGestureDeliversTheSettlingSelectionFirst() throws {
        var memory = try memory(multiple: false, events: true)
        memory.click(at: 2)
        let handled = memory.pressReturn()
        XCTAssertEqual(handled.selectionChanged?.json.value(atPointer: "/items/0/id"), .string("c"))
        XCTAssertEqual(handled.gesture, itemAction("open", on: "c", items: nil))
        XCTAssertFalse(memory.isSettlingSelection)
    }

    /// What an answer does to the selection is the Plugin's own: it never
    /// causes the event, and an answer that moves a selection the user was
    /// settling drops the change. One that leaves it keeps it.
    func testAnswersNeverCauseTheEvent() throws {
        var memory = try memory(multiple: false, events: true)
        let list = { (ids: [String]) -> JSONValue in
            .object(["kind": .string("list"), "id": .string("results"), "selection_events": .bool(true),
                     "items": .array(ids.map { Self.item($0) })])
        }
        memory.show(try page(list(["b", "c"])))
        XCTAssertFalse(memory.isSettlingSelection)
        memory.click(at: 1)
        memory.show(try page(list(["b", "c", "d"])))
        XCTAssertEqual(memory.settleSelection()?.json.value(atPointer: "/items/0/id"), .string("c"), "Left alone")
        memory.click(at: 0)
        memory.show(try page(list(["c", "d"])))
        XCTAssertFalse(memory.isSettlingSelection, "The answer moved it")
        XCTAssertNil(memory.settleSelection())
        memory.click(at: 1)
        memory.show(try page(list(["c", "d"]), id: "other"))
        XCTAssertNil(memory.settleSelection(), "Another page drops it")
    }

    /// A selection the user moved onto a position whose item is still to
    /// come settles once an answer brings it.
    func testASelectionWaitingForItsItemSettlesWhenItComes() throws {
        let grid = { (start: Int) -> JSONValue in
            .object(["kind": .string("grid"), "id": .string("results"), "columns": .number(8), "rows": .number(6),
                     "selection_events": .bool(true), "total": .number(1906), "start": .number(Double(start)),
                     "items": .array((start..<(start + 200)).map { Self.item("i\($0)") })])
        }
        var memory = PluginPageMemory()
        memory.show(try page(grid(0)))
        let moved = try XCTUnwrap(memory.press(.end))
        XCTAssertEqual(moved.reveal, 1905)
        memory.reveal(1905)
        XCTAssertEqual(memory.missingRange?.upperBound, 1906, "The screen around it is asked for")
        XCTAssertNil(memory.settleSelection(), "It waits for its item")
        XCTAssertTrue(memory.isSettlingSelection)
        let applied = memory.show(try page(grid(1706)), answersRange: true)
        XCTAssertTrue(applied.selectionSettlesAgain)
        XCTAssertEqual(memory.settleSelection()?.json.value(atPointer: "/items/0/id"), .string("i1905"))
    }
}
