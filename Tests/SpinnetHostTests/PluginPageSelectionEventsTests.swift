import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// A Collection declaring `selection_events`, as the Host's page model
/// handles it (ADR 0025): `selection_changed` once the user's selection has
/// settled, never for what an answer does to it.
final class PluginPageSelectionEventsTests: XCTestCase {
    private var harness: PageHarness!
    private let settle = ScriptedActionBudgets.selectionChangeSettle

    override func setUp() {
        harness = try! PageHarness()
    }

    private var model: PluginPageModel { harness.windows.pageModel(for: PageHarness.pluginID)! }

    /// A note field and a list of `ids` with Open as its default.
    private static func page(_ ids: [String] = ["a", "b", "c", "d", "e"], id: String = "clips", events: Bool = true,
                             multiple: Bool = false, reset: [String]? = nil) -> JSONValue {
        var list: [String: JSONValue] = [
            "kind": .string("list"), "id": .string("results"),
            "actions": .array([.object(["id": .string("open"), "title": .string("Open"), "default": .bool(true)])]),
            "items": .array(ids.map { .object(["id": .string($0), "title": .string("Item \($0)"),
                                               "text": .string($0.uppercased())]) })
        ]
        if events { list["selection_events"] = .bool(true) }
        if multiple { list["selection"] = .string("multiple") }
        var page: [String: JSONValue] = ["id": .string(id), "title": .string("Clips"), "content": .array([
            .object(["kind": .string("text_field"), "id": .string("note"), "title": .string("Note")]),
            .object(list)
        ])]
        if let reset { page["reset"] = .array(reset.map(JSONValue.string)) }
        return .object(page)
    }

    private var sent: [[String]] {
        harness.events.compactMap { held in
            guard case .selectionChanged(_, _, let items, _)? = held.event else { return nil }
            return items.map(\.id)
        }
    }

    /// The event waits until the selection has been stable for the pause;
    /// a move during it starts the pause again.
    func testItWaitsForTheSelectionToSettle() throws {
        try harness.open(Self.page())
        model.click("b")
        harness.clock.advance(by: settle * 0.8)
        XCTAssertEqual(sent, [])
        model.moveSelection(.down)
        harness.clock.advance(by: settle * 0.8)
        XCTAssertEqual(sent, [], "The move started the pause again")
        harness.clock.advance(by: settle * 0.2)
        XCTAssertEqual(sent, [["c"]])
        guard case .selectionChanged("clips", "results", let items, let values)? = harness.events.last?.event else {
            return XCTFail("No selection_changed")
        }
        XCTAssertEqual(items, [PluginPageItemSnapshot(id: "c", section: nil, text: "C")])
        XCTAssertEqual(values, .object(["note": .string("")]))
        XCTAssertFalse(try XCTUnwrap(harness.events.last?.event).isGesture)
    }

    /// Holding an arrow key sends nothing until it is released, then one
    /// event.
    func testHoldingAnArrowKeySendsOneEventAfterRelease() throws {
        try harness.open(Self.page())
        var held = true
        model.moveKeyIsHeld = { held }
        for _ in 0..<3 {
            model.moveSelection(.down)
            harness.clock.advance(by: 0.03)
        }
        harness.clock.advance(by: settle * 4)
        XCTAssertEqual(sent, [], "Nothing while the key is held")
        held = false
        harness.clock.advance(by: settle)
        XCTAssertEqual(sent, [["d"]])
        harness.clock.advance(by: settle * 4)
        XCTAssertEqual(sent, [["d"]], "One event for the whole hold")
    }

    /// Without `selection_events` nothing is ever sent; a selection that
    /// came back to where it was sends nothing either.
    func testNothingIsSentWithoutOptInOrWithoutAChange() throws {
        try harness.open(Self.page(events: false))
        model.click("c")
        model.moveSelection(.down)
        harness.clock.advance(by: settle * 4)
        XCTAssertTrue(harness.events.isEmpty)

        harness = try PageHarness()
        try harness.open(Self.page())
        model.click("c")
        model.click("a")
        harness.clock.advance(by: settle * 4)
        XCTAssertEqual(sent, [], "Back where the Plugin last heard it was")
    }

    /// A multiple Collection's event carries every selected item in
    /// Collection order.
    func testAMultipleCollectionSendsTheWholeSelection() throws {
        try harness.open(Self.page(multiple: true))
        model.click("d", modifier: .command)
        model.click("b", modifier: .command)
        harness.clock.advance(by: settle)
        XCTAssertEqual(sent, [["a", "b", "d"]])
        try harness.answer(nil)
        XCTAssertTrue(model.selectAll())
        harness.clock.advance(by: settle)
        XCTAssertEqual(sent, [["a", "b", "d"], ["a", "b", "c", "d", "e"]])
    }

    /// Answers never cause the event: not the selected item leaving, not a
    /// reset, and not when they move a selection the user was still
    /// settling.
    func testAnswersNeverCauseTheEvent() throws {
        try harness.open(Self.page())
        model.textChanged("note", to: "x", caret: nil)
        harness.clock.advance(by: ScriptedActionBudgets.fieldChangeDebounce)
        try harness.answer(Self.page(["b", "c"]))
        XCTAssertEqual(model.selectedItem, "b", "The item now at its place")
        harness.clock.advance(by: settle * 4)
        XCTAssertEqual(sent, [])

        model.textChanged("note", to: "xy", caret: nil)
        harness.clock.advance(by: ScriptedActionBudgets.fieldChangeDebounce)
        model.click("c")
        try harness.answer(Self.page(["b", "d"]))
        harness.clock.advance(by: settle * 4)
        XCTAssertEqual(sent, [], "The answer moved the selection the user was settling")

        model.textChanged("note", to: "xyz", caret: nil)
        harness.clock.advance(by: ScriptedActionBudgets.fieldChangeDebounce)
        XCTAssertEqual(model.selectedItem, "d")
        model.click("b")
        try harness.answer(Self.page(["b", "d"], reset: ["results"]))
        harness.clock.advance(by: settle * 4)
        XCTAssertEqual(sent, [], "A reset starts the selection again")
    }

    /// A change the user made that an answer leaves alone is still sent.
    func testAnAnswerThatKeepsTheSelectionKeepsTheChange() throws {
        try harness.open(Self.page())
        model.textChanged("note", to: "x", caret: nil)
        harness.clock.advance(by: ScriptedActionBudgets.fieldChangeDebounce)
        model.click("c")
        try harness.answer(Self.page(["a", "b", "c", "f"]))
        harness.clock.advance(by: settle)
        XCTAssertEqual(sent, [["c"]])
    }

    /// Another page drops a change still settling.
    func testAnotherPageDropsIt() throws {
        try harness.open(Self.page())
        model.textChanged("note", to: "x", caret: nil)
        harness.clock.advance(by: ScriptedActionBudgets.fieldChangeDebounce)
        model.click("c")
        try harness.answer(Self.page(id: "other"))
        harness.clock.advance(by: settle * 4)
        XCTAssertEqual(sent, [])
    }

    /// A gesture on a selection still settling comes after its
    /// `selection_changed`.
    func testAPendingChangeGoesBeforeAGesture() throws {
        try harness.open(Self.page())
        model.click("c")
        model.returnPressedInCollection()
        guard harness.events.count == 1, case .selectionChanged? = harness.events.first?.event else {
            return XCTFail("selection_changed did not go first: \(harness.events.map(\.event))")
        }
        try harness.answer(nil)
        guard case .itemAction(_, _, "open", let item, _, _)? = harness.events.last?.event else {
            return XCTFail("No item action")
        }
        XCTAssertEqual(item.id, "c")
        harness.clock.advance(by: settle * 4)
        XCTAssertEqual(sent, [["c"]], "Sent once")
    }
}
