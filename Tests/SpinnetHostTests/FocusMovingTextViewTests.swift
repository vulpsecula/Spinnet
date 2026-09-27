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

    /// In a form that submits on Return, Return submits and Shift-Return or
    /// Option-Return starts a new line.
    func testReturnSubmitsWhenTheFormSaysSo() {
        var text = "Note"
        var submits = 0
        var modifiers: NSEvent.ModifierFlags = []
        let coordinator = FocusMovingTextView.Coordinator(text: Binding(get: { text }, set: { text = $0 }),
                                                          onReturn: { submits += 1 }, modifiers: { modifiers })
        let textView = NSTextView()

        XCTAssertTrue(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submits, 1)
        modifiers = .shift
        XCTAssertFalse(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))),
                       "Shift-Return starts a new line")
        modifiers = []
        XCTAssertFalse(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))),
                       "Option-Return starts a new line")
        XCTAssertEqual(submits, 1)
    }

    /// The field is as tall as its text, from one line up to a limit, and
    /// scrolls beyond it, so a long text shows in full where it fits.
    func testTheFieldGrowsWithItsText() {
        let width: CGFloat = 400
        let one = FocusMovingTextView.idealHeight(of: "Hello", width: width)
        let three = FocusMovingTextView.idealHeight(of: "One\nTwo\nThree", width: width)
        let many = FocusMovingTextView.idealHeight(of: String(repeating: "Line\n", count: 100), width: width)
        XCTAssertGreaterThan(three, one * 2)
        XCTAssertEqual(many, FocusMovingTextView.maximumHeight)
        XCTAssertEqual(FocusMovingTextView.idealHeight(of: "", width: width), one, "An empty field is one line tall")
        XCTAssertGreaterThan(FocusMovingTextView.idealHeight(of: "One\n", width: width), one,
                             "A new line at the end shows at once")
    }

    /// Text starts at the top of the field, however tall the field is.
    func testTheTextStartsAtTheTopOfTheField() throws {
        let scrollView = FocusMovingTextView.makeScrollView(text: "Hi", placeholder: "", delegate: nil)
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(scrollView.documentView)
        XCTAssertEqual(textView.frame.maxY, scrollView.contentView.bounds.maxY, accuracy: 0.5,
                       "The text view fills the field, so its first line is at the top")
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
