import AppKit
import SwiftUI

/// A multiline text field that behaves as one field of a form: Tab and
/// Shift-Tab move to the next and previous field instead of typing a tab,
/// and Escape goes to the window, so a Plugin View closes from it as from any
/// other field. Return starts a new line and Option-Tab still types a tab.
/// SwiftUI's `TextEditor` types a tab, and macOS 13 has no way to intercept
/// the key.
struct FocusMovingTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""

    /// Draws its placeholder itself, where the first line of text starts.
    final class PlaceholderTextView: NSTextView {
        var placeholder = "" {
            didSet {
                setAccessibilityPlaceholderValue(placeholder)
                needsDisplay = true
            }
        }

        var placeholderOrigin: NSPoint {
            NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
            (placeholder as NSString).draw(at: placeholderOrigin, withAttributes: [
                .font: font ?? .preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }

    static func makeScrollView(text: String, placeholder: String, delegate: NSTextViewDelegate?) -> NSScrollView {
        // Laid out as `NSTextView.scrollableTextView()` lays out its own:
        // as wide as the scroll view, as tall as its text.
        let textView = PlaceholderTextView()
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = delegate
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.string = text
        textView.placeholder = placeholder
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(text: text, placeholder: placeholder, delegate: context.coordinator)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        // Text being composed with an input method is not in the binding yet.
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        if textView.placeholder != placeholder { textView.placeholder = placeholder }
        guard !textView.hasMarkedText(), textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
            case #selector(NSResponder.cancelOperation(_:)):
                textView.window?.cancelOperation(nil)
            default:
                return false
            }
            return true
        }
    }
}
