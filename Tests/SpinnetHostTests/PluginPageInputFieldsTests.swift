import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// A page's `multiline_text_field` and `toggle_field` (#127), as the Host's
/// page model handles them: both are focus stops, the multi-line field keeps
/// the user's text under the `text_field` rules, and a toggle is delivered at
/// once.
final class PluginPageInputFieldsTests: XCTestCase {
    private var harness: PageHarness!

    override func setUp() {
        harness = try! PageHarness()
    }

    private var model: PluginPageModel { harness.windows.pageModel(for: PageHarness.pluginID)! }

    /// A subject, a body, an urgent toggle, a Send button and a list.
    private static func page(body: String = "Hi", reset: [String]? = nil) -> JSONValue {
        var page: [String: JSONValue] = ["id": .string("compose"), "title": .string("Compose"), "content": .array([
            .object(["kind": .string("text_field"), "id": .string("subject"), "title": .string("Subject")]),
            .object(["kind": .string("multiline_text_field"), "id": .string("body"), "title": .string("Body"),
                     "value": .string(body)]),
            .object(["kind": .string("row"), "id": .string("options"), "content": .array([
                .object(["kind": .string("toggle_field"), "id": .string("urgent"), "title": .string("Urgent")]),
                .object(["kind": .string("actions"), "id": .string("buttons"), "actions": .array([
                    .object(["id": .string("send"), "title": .string("Send")])
                ])])
            ])]),
            .object(["kind": .string("list"), "id": .string("recent"), "items": .array([
                .object(["id": .string("a"), "title": .string("A")])
            ])])
        ])]
        if let reset { page["reset"] = .array(reset.map(JSONValue.string)) }
        return .object(page)
    }

    private var fieldChanges: [(field: String, values: JSONValue)] {
        harness.events.compactMap { held in
            guard case .pageFieldChanged(_, let field, let values)? = held.event else { return nil }
            return (field, values)
        }
    }

    func testBothFieldsAreFocusStopsInPageOrder() throws {
        try harness.open(Self.page())
        XCTAssertEqual(model.focusStops, ["subject", "body", "urgent", "recent"])
        model.moveFocus(from: "subject", forward: true)
        XCTAssertEqual(model.focused, "body")
        model.moveFocus(from: "body", forward: true)
        XCTAssertEqual(model.focused, "urgent", "Tab leaves the multi-line field")
        model.moveFocus(from: "urgent", forward: false)
        model.moveFocus(from: "body", forward: false)
        XCTAssertEqual(model.focused, "subject", "Shift-Tab goes back")
    }

    /// Typed lines are sent after the pause and kept across answers; only a
    /// reset writes into the field.
    func testTypedLinesAreKeptAcrossAnswersUntilAReset() throws {
        try harness.open(Self.page())
        let revision = model.textRevisions["body"]
        model.textChanged("body", to: "Hi\nthere", caret: PluginPageCaret(location: 8))
        XCTAssertTrue(fieldChanges.isEmpty, "Typing waits out the pause")
        harness.clock.advance(by: 0.2)
        XCTAssertEqual(fieldChanges.last?.field, "body")
        XCTAssertEqual(fieldChanges.last?.values.value(atPointer: "/body"), .string("Hi\nthere"))
        try harness.answer(Self.page(body: "Plugin's"))
        XCTAssertEqual(model.text(of: "body"), "Hi\nthere")
        XCTAssertEqual(model.caret(of: "body"), PluginPageCaret(location: 8))
        XCTAssertEqual(model.textRevisions["body"], revision, "The field is not written")
        model.textChanged("body", to: "Hi\nthere!", caret: nil)
        harness.clock.advance(by: 0.2)
        try harness.answer(Self.page(body: "Plugin's", reset: ["body"]))
        XCTAssertEqual(model.text(of: "body"), "Plugin's")
        XCTAssertNotEqual(model.textRevisions["body"], revision, "A reset writes the field")
    }

    func testACompositionIsNeitherSentNorReset() throws {
        try harness.open(Self.page())
        model.textChanged("body", to: "Hi ", caret: nil)
        harness.clock.advance(by: 0.2)
        model.compositionChanged("body", isComposing: true)
        harness.clock.advance(by: 0.2)
        XCTAssertEqual(fieldChanges.count, 1, "Marked text sends nothing")
        let revision = model.textRevisions["body"]
        try harness.answer(Self.page(body: "New", reset: ["body"]))
        XCTAssertEqual(model.textRevisions["body"], revision, "The composing field's reset is dropped")
        XCTAssertEqual(model.text(of: "body"), "Hi ")
        model.textChanged("body", to: "Hi 猫", caret: nil)
        harness.clock.advance(by: 0.2)
        XCTAssertEqual(fieldChanges.last?.values.value(atPointer: "/body"), .string("Hi 猫"), "The committed text is sent")
    }

    /// A click delivers `field_changed` at once, after a text change still
    /// waiting out its pause.
    func testAToggleIsDeliveredAtOnce() throws {
        try harness.open(Self.page())
        model.textChanged("subject", to: "Lunch", caret: nil)
        model.setToggle(true, in: "urgent")
        XCTAssertEqual(fieldChanges.map(\.field), ["subject"], "The typing goes first, without its pause")
        try harness.answer(Self.page())
        XCTAssertEqual(fieldChanges.map(\.field), ["subject", "urgent"], "The toggle follows with no pause")
        XCTAssertEqual(fieldChanges.last?.values, .object([
            "subject": .string("Lunch"), "body": .string("Hi"), "urgent": .bool(true)
        ]))
        XCTAssertTrue(model.isOn("urgent"))
        try harness.answer(Self.page())
        XCTAssertTrue(model.isOn("urgent"), "An answer keeps the toggle")
        model.setToggle(true, in: "urgent")
        XCTAssertEqual(fieldChanges.count, 2, "Nothing changed, nothing sent")
    }

    /// The field takes no edit past the byte bound.
    func testTheFieldTakesNoTextPastTheBound() throws {
        try harness.open(Self.page(body: ""))
        let bound = CollectionsContract.maximumMultilineTextBytes
        XCTAssertTrue(model.takes(String(repeating: "a", count: bound), in: "body"))
        XCTAssertFalse(model.takes(String(repeating: "a", count: bound + 1), in: "body"))
        XCTAssertTrue(model.takes(String(repeating: "a", count: bound + 1), in: "subject"), "A text_field has no such bound")
    }
}

/// The two fields in the Host's real panel, driven by key events sent
/// through AppKit: Return types a new line in the multi-line field, Tab and
/// Shift-Tab move through both, and Space flips the toggle. Input-method
/// composition needs a real input method and is checked by hand.
final class PluginPageInputFieldsPanelTests: XCTestCase {
    private var harness: PageHarness!
    private var window: PluginViewPanelWindow!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        harness = try PageHarness()
    }

    override func tearDown() {
        window?.close()
        window = nil
    }

    private var model: PluginPageModel { harness.windows.pageModel(for: PageHarness.pluginID)! }
    private var panel: NSWindow { window.contentView!.window! }

    private func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                   windowNumber: panel.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        panel.sendEvent(event)
        settle(0.02)
    }

    private func firstResponderComponent() -> String? {
        var responder = panel.firstResponder
        if let text = responder as? NSText, !(text is PluginPageFocusTarget), let owner = text.delegate as? NSResponder {
            responder = owner
        }
        return (responder as? PluginPageFocusTarget)?.component
    }

    func testReturnTypesANewLineAndTabMovesThroughBothFields() throws {
        try harness.open(.object(["id": .string("compose"), "title": .string("Compose"), "content": .array([
            .object(["kind": .string("multiline_text_field"), "id": .string("body"), "title": .string("Body")]),
            .object(["kind": .string("toggle_field"), "id": .string("urgent"), "title": .string("Urgent")])
        ])]))
        window = PluginViewPanelWindow(pageModel: model)
        window.show(near: NSPoint(x: 500, y: 700))
        settle()
        XCTAssertEqual(firstResponderComponent(), "body", "The multi-line field has the keyboard when the page opens")
        try key(0, "a")
        try key(36, "\r")
        try key(11, "b")
        XCTAssertEqual(model.text(of: "body"), "a\nb", "Return started a new line")
        XCTAssertNil(harness.events.first { if case .pageSubmitted? = $0.event { return true }; return false },
                     "Return submits nothing")
        try key(48, "\t")
        XCTAssertEqual(firstResponderComponent(), "urgent")
        try key(49, " ")
        XCTAssertTrue(model.isOn("urgent"), "Space flipped the toggle")
        try key(48, "\u{19}", modifiers: .shift)
        XCTAssertEqual(firstResponderComponent(), "body")
        XCTAssertEqual(model.text(of: "body"), "a\nb", "Tab typed nothing")
    }
}
