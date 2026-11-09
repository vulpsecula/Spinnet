import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// A Collection declaring `selection_events`, as the Host's page model
/// handles it (ADR 0025): `selection_changed` once the user's selection has
/// been stable for the pause and no move key is held. Which selection is
/// due, and that answers never cause one, is the page memory's
/// (`PageGestureTests`).
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

    /// A selection the user moved onto an item still to come settles once
    /// the answer brings it.
    func testASelectionWaitingForItsItemSettlesWhenItComes() throws {
        try harness.open(Self.windowed(start: 0))
        XCTAssertTrue(model.moveSelection(.end))
        harness.clock.advance(by: settle * 4)
        XCTAssertEqual(sent, [], "It waits for its item")
        try harness.answer(Self.windowed(start: 100))
        XCTAssertEqual(sent, [], "The pause starts again")
        harness.clock.advance(by: settle)
        XCTAssertEqual(sent, [["i199"]])
    }

    /// A List of 200 items `i0`, `i1`, … of which the answer gives 100 from
    /// `start`.
    private static func windowed(start: Int) -> JSONValue {
        .object(["id": .string("clips"), "title": .string("Clips"), "content": .array([
            .object(["kind": .string("list"), "id": .string("results"), "selection_events": .bool(true),
                     "total": .number(200), "start": .number(Double(start)),
                     "items": .array((start..<(start + 100)).map { .object(["id": .string("i\($0)"), "title": .string("Item \($0)")]) })])
        ])])
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
