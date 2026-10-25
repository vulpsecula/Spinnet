import AppKit
import SwiftUI

/// A multiline text field that behaves as one field of a form: Tab and
/// Shift-Tab move to the next and previous field instead of typing a tab,
/// and Escape goes to the window, so a Plugin View closes from it as from any
/// other field. Return starts a new line, unless the form submits on Return,
/// where Shift-Return and Option-Return do; Option-Tab still types a tab.
/// The field is as tall as its text up to `maximumHeight`, then scrolls.
/// SwiftUI's `TextEditor` types a tab, and macOS 13 has no way to intercept
/// the key.
struct FocusMovingTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    /// Called for Return without Shift when the form submits on Return.
    var onReturn: (() -> Void)?

    static let font = NSFont.preferredFont(forTextStyle: .body)
    static let inset = NSSize(width: 0, height: 4)
    /// Past this the field scrolls rather than grows.
    static let maximumHeight: CGFloat = 240

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
        textView.font = font
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = inset
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

    /// The height of `text` laid out at `width`, from one line up to
    /// `maximumHeight`. A new line at the end counts, as the cursor is there.
    static func idealHeight(of text: String, width: CGFloat) -> CGFloat {
        let padding = NSTextContainer().lineFragmentPadding
        let measured = (text.isEmpty || text.hasSuffix("\n") ? text + " " : text) as NSString
        let bounds = measured.boundingRect(with: NSSize(width: max(width - 2 * padding, 1), height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(ceil(bounds.height) + 2 * inset.height, maximumHeight)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: Self.idealHeight(of: text, width: width))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onReturn = onReturn
        // Text being composed with an input method is not in the binding yet.
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        if textView.placeholder != placeholder { textView.placeholder = placeholder }
        guard !textView.hasMarkedText(), textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onReturn: onReturn) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onReturn: (() -> Void)?
        /// The modifier keys held for the key being handled.
        private let modifiers: () -> NSEvent.ModifierFlags

        init(text: Binding<String>, onReturn: (() -> Void)? = nil,
             modifiers: @escaping () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }) {
            self.text = text
            self.onReturn = onReturn
            self.modifiers = modifiers
        }

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
            case #selector(NSResponder.insertNewline(_:)) where onReturn != nil && !modifiers().contains(.shift):
                // Text being composed with an input method takes Return first.
                guard !textView.hasMarkedText() else { return false }
                onReturn?()
            default:
                return false
            }
            return true
        }
    }
}
