import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// A page's Collection with multiple selection, as the Host's page model
/// handles it (ADR 0025): ⌘-click, Shift ranges, ⌘A, the selection kept and
/// dropped across answers, single item actions disabled, and one gesture for
/// the whole selection.
final class PluginPageMultipleSelectionTests: XCTestCase {
    private var harness: PageHarness!

    override func setUp() {
        harness = try! PageHarness()
    }

    private var model: PluginPageModel { harness.windows.pageModel(for: PageHarness.pluginID)! }

    /// A list of `ids` with Open (the default), a single Rename, a Pin
    /// toggle and Copy.
    private static func page(_ ids: [String] = ["a", "b", "c", "d", "e"], selection: String? = "multiple",
                             defaultIsSingle: Bool = false, pinned: Set<String> = []) -> JSONValue {
        var open: [String: JSONValue] = ["id": .string("open"), "title": .string("Open"), "default": .bool(true)]
        if defaultIsSingle { open["single"] = .bool(true) }
        var actions: [JSONValue] = [.object(open),
            .object(["id": .string("pin"), "title": .string("Pin"), "toggle": .string("pinned")]),
            .object(["id": .string("copy"), "title": .string("Copy"), "perform": .string("clipboard.write")])]
        if selection == "multiple" {
            actions.insert(.object(["id": .string("rename"), "title": .string("Rename"), "single": .bool(true)]), at: 1)
        }
        var list: [String: JSONValue] = [
            "kind": .string("list"), "id": .string("results"), "actions": .array(actions),
            "items": .array(ids.map { id in
                var item: [String: JSONValue] = ["id": .string(id), "title": .string("Item \(id)"), "text": .string(id.uppercased())]
                if pinned.contains(id) { item["marks"] = .array([.string("pinned")]) }
                return .object(item)
            })
        ]
        if let selection { list["selection"] = .string(selection) }
        return PageHarness.page("clips", [.object(list)])
    }

    private func position(_ id: String) -> Int { model.window?.position(of: id) ?? -1 }

    // MARK: Selecting

    func testCommandClickShiftRangesAndSelectAll() throws {
        try harness.open(Self.page())
        XCTAssertTrue(model.selectsMultiple)
        XCTAssertEqual(model.selectedItems, ["a"])
        model.click("c", modifier: .command)
        XCTAssertEqual(model.selectedItems, ["a", "c"])
        XCTAssertEqual(model.selectedItem, "c", "The ⌘-clicked item is focused")
        XCTAssertTrue(model.isSelected(position("a")))
        XCTAssertFalse(model.isSelected(position("b")))
        model.click("a", modifier: .command)
        XCTAssertEqual(model.selectedItems, ["c"])
        model.click("e", modifier: .shift)
        XCTAssertEqual(model.selectedItems, ["c", "d", "e"])
        model.click("b")
        XCTAssertEqual(model.selectedItems, ["b"])
        XCTAssertTrue(model.extendSelection(.down))
        XCTAssertTrue(model.extendSelection(.down))
        XCTAssertEqual(model.selectedItems, ["b", "c", "d"])
        XCTAssertTrue(model.extendSelection(.up))
        XCTAssertEqual(model.selectedItems, ["b", "c"], "Shift-Up shrinks the range toward the anchor")
        XCTAssertEqual(model.selectionAccessibilityValue, "2 items selected")
        XCTAssertTrue(model.selectAll())
        XCTAssertEqual(model.selectedItems, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(model.focused, "results")
        XCTAssertTrue(harness.events.isEmpty, "Selecting sends nothing")
        model.moveSelection(.down)
        XCTAssertEqual(model.selectedItems, ["d"], "A plain arrow selects one item")
    }

    /// A single Collection behaves as before: modifiers click, Shift-arrows
    /// move, ⌘A selects nothing more.
    func testASingleCollectionIgnoresTheMultipleGestures() throws {
        try harness.open(Self.page(selection: nil))
        XCTAssertFalse(model.selectsMultiple)
        model.click("c", modifier: .command)
        XCTAssertEqual(model.selectedItems, ["c"])
        model.extendSelection(.down)
        XCTAssertEqual(model.selectedItems, ["d"])
        XCTAssertFalse(model.selectAll())
        XCTAssertNil(model.selectionAccessibilityValue)
        model.returnPressedInCollection()
        XCTAssertNil(harness.events.last?.event?.json.value(atPointer: "/items"), "No items on a single Collection's event")
    }

    /// The selection is kept by item ID across answers; IDs that leave drop
    /// out; an empty selection falls back to one item.
    func testTheSelectionIsKeptAndDroppedAcrossAnswers() throws {
        try harness.open(Self.page())
        model.click("b")
        model.click("d", modifier: .shift)
        model.returnPressedInCollection()
        try harness.answer(Self.page(["d", "x", "b", "c"]))
        XCTAssertEqual(model.selectedItems, ["d", "b", "c"])
        model.returnPressedInCollection()
        try harness.answer(Self.page(["x", "c"]))
        XCTAssertEqual(model.selectedItems, ["c"])
        model.returnPressedInCollection()
        try harness.answer(Self.page(["x", "y"]))
        XCTAssertEqual(model.selectedItems, ["y"], "The item now at the focused place")
    }

    // MARK: Acting on the selection

    /// Return, double-click and the context menu each send one
    /// `item_action` with every selected item and the item the gesture
    /// started on.
    func testOneItemActionCarriesTheWholeSelection() throws {
        try harness.open(Self.page())
        model.click("b")
        model.click("d", modifier: .command)
        model.returnPressedInCollection()
        guard case .itemAction("clips", "results", "open", let item, _, let items?)? = harness.events.last?.event else {
            return XCTFail("No group item action: \(harness.events.map(\.event))")
        }
        XCTAssertEqual(item.id, "d", "Return starts on the focused item")
        XCTAssertEqual(items.map(\.id), ["b", "d"])
        try harness.answer(nil)

        // The first click of a double-click on a selected item reduces the
        // selection; the second acts on the selection it had.
        model.click(at: position("b"))
        model.doubleClick(at: position("b"))
        guard case .itemAction(_, _, "open", let clicked, _, let again?)? = harness.events.last?.event else {
            return XCTFail("No double-click")
        }
        XCTAssertEqual(clicked.id, "b")
        XCTAssertEqual(again.map(\.id), ["b", "d"])
        XCTAssertEqual(model.selectedItems, ["b", "d"])
        try harness.answer(nil)

        model.rightClick(at: position("d"))
        XCTAssertEqual(model.selectedItems, ["b", "d"], "A right click within the selection keeps it")
        let pin = try XCTUnwrap(model.contextMenu(at: position("d")).first { $0.action.id == "pin" })
        model.choose(pin.action, at: position("d"))
        guard case .itemAction(_, _, "pin", let menuItem, _, let pinned?)? = harness.events.last?.event else {
            return XCTFail("No context menu action")
        }
        XCTAssertEqual(menuItem.id, "d")
        XCTAssertEqual(pinned.map(\.id), ["b", "d"])
    }

    /// A right click outside the selection selects that item alone.
    func testARightClickOutsideTheSelectionSelectsTheItem() throws {
        try harness.open(Self.page())
        model.click("b", modifier: .command)
        model.rightClick(at: position("e"))
        XCTAssertEqual(model.selectedItems, ["e"])
    }

    /// A single item action is disabled in the context menu and ignored for
    /// Return and double-click while several items are selected; a toggle is
    /// checked only when every selected item carries its mark.
    func testSingleItemActionsAreDisabledForSeveralItems() throws {
        try harness.open(Self.page(defaultIsSingle: true, pinned: ["a", "b"]))
        XCTAssertEqual(model.contextMenu(at: position("a")).map(\.isEnabled), [true, true, true, true])
        model.click("b", modifier: .shift)
        let menu = model.contextMenu(at: position("b"))
        XCTAssertEqual(menu.map(\.action.id), ["open", "rename", "pin", "copy"])
        XCTAssertEqual(menu.map(\.isEnabled), [false, false, true, true])
        XCTAssertEqual(menu.map(\.isChecked), [false, false, true, false], "Both carry the mark")
        model.returnPressedInCollection()
        model.doubleClick(at: position("b"))
        XCTAssertTrue(harness.events.isEmpty, "Return and double-click do nothing for a single default action")
        model.click("c", modifier: .shift)
        XCTAssertEqual(model.contextMenu(at: position("c")).map(\.isChecked), [false, false, false, false],
                       "c does not carry the mark")
    }

    /// ⌘C and Copy on several items copy their texts, one per line in
    /// Collection order, under the same Capability.
    func testCopyJoinsTheSelectedTextsByNewlines() throws {
        try harness.open(Self.page())
        model.click("d", modifier: .command)
        model.click("b", modifier: .command)
        XCTAssertTrue(model.copySelection())
        let copy = try XCTUnwrap(harness.performer.performed.last?.operation)
        XCTAssertEqual(copy.perform, "clipboard.write")
        XCTAssertEqual(copy.input, .object(["text": .string("A\nB\nD")]))
    }
}
