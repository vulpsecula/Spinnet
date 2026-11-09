import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// A page's Collection with multiple selection, as the Host's page model
/// adapts the page memory's gestures (ADR 0025) to AppKit and its View
/// Session: the keyboard and VoiceOver follow the selection, selecting sends
/// nothing, and one gesture sends one event for the whole selection. The
/// rules themselves are `PageGestureTests`'.
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

    func testSelectingFocusesTheCollectionAndSendsNothing() throws {
        try harness.open(Self.page())
        XCTAssertTrue(model.selectsMultiple)
        model.click("c", modifier: .command)
        model.click("e", modifier: .shift)
        XCTAssertEqual(model.selectedItems, ["c", "d", "e"])
        XCTAssertTrue(model.isSelected(position("d")))
        XCTAssertFalse(model.isSelected(position("b")))
        XCTAssertEqual(model.selectionAccessibilityValue, "3 items selected")
        XCTAssertTrue(model.extendSelection(.up))
        XCTAssertTrue(model.selectAll())
        XCTAssertEqual(model.selectedItems, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(model.focused, "results")
        XCTAssertTrue(harness.events.isEmpty, "Selecting sends nothing")

        harness = try PageHarness()
        try harness.open(Self.page(selection: nil))
        XCTAssertFalse(model.selectAll(), "A single Collection has no ⌘A")
        XCTAssertNil(model.selectionAccessibilityValue)
    }

    // MARK: Acting on the selection

    /// Return, double-click and the context menu each send one
    /// `item_action` with every selected item and the item the gesture
    /// started on; a double-click comes as AppKit sends it, a click then the
    /// second click.
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

    /// ⌘C on several items is performed by the Host, their texts one per
    /// line in Collection order.
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
