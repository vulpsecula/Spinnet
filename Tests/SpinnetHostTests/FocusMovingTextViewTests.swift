import AppKit
import SwiftUI
import XCTest
@testable import SpinnetHost

/// A Plugin View's multiline field is one field of a form: Tab and
/// Shift-Tab move to the next and previous field instead of typing a tab,
/// and Escape closes the view as it does from any other field.
final class FocusMovingTextViewTests: XCTestCase {
    func testTabAndShiftTabMoveFocusAndEscapeReachesTheWindow() {
        var text = "Note"
        let coordinator = FocusMovingTextView.Coordinator(text: Binding(get: { text }, set: { text = $0 }))
        let window = RecordingWindow()
        let textView = NSTextView()
        window.contentView = NSView()
        window.contentView?.addSubview(textView)
        textView.string = text

        XCTAssertTrue(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertTrue(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertTrue(coordinator.textView(textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(window.moves, ["next", "previous"])
        XCTAssertEqual(window.cancels, 1)
        XCTAssertEqual(textView.string, "Note", "Tab types nothing")

        XCTAssertFalse(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))),
                       "Return still starts a new line")
        XCTAssertFalse(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTabIgnoringFieldEditor(_:))),
                       "Option-Tab still types a tab")
    }

    /// The placeholder is drawn by the text view itself, where its text
    /// starts, so the two line up whatever the insets.
    func testThePlaceholderStartsWhereTheTextDoes() throws {
        let scrollView = FocusMovingTextView.makeScrollView(text: "", placeholder: "Anything else", delegate: nil)
        let textView = try XCTUnwrap(scrollView.documentView as? FocusMovingTextView.PlaceholderTextView)
        XCTAssertEqual(textView.placeholder, "Anything else")
        XCTAssertEqual(textView.accessibilityPlaceholderValue(), "Anything else")
        let padding = try XCTUnwrap(textView.textContainer).lineFragmentPadding
        XCTAssertEqual(textView.placeholderOrigin,
                       NSPoint(x: textView.textContainerOrigin.x + padding, y: textView.textContainerOrigin.y))
    }

    func testTypingUpdatesTheBinding() {
        var text = ""
        let coordinator = FocusMovingTextView.Coordinator(text: Binding(get: { text }, set: { text = $0 }))
        let textView = NSTextView()
        textView.string = "Hello"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(text, "Hello")
    }
}

private final class RecordingWindow: NSWindow {
    var moves: [String] = []
    var cancels = 0

    override func selectNextKeyView(_ sender: Any?) { moves.append("next") }
    override func selectPreviousKeyView(_ sender: Any?) { moves.append("previous") }
    override func cancelOperation(_ sender: Any?) { cancels += 1 }
}
