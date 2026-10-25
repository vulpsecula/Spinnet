import AppKit
import SwiftUI

/// A read-only transcript, not a terminal input surface. Keep native selection
/// and scroll position when a one-second source supplies another output frame.
struct PluginCommandOutputView: NSViewRepresentable {
    let text: String
    private static var outputFont: NSFont { .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeOutputView()
    }

    static func makeOutputView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        // Keep overflow discoverable even with a mouse and no scroll gesture.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true; scroll.borderType = .lineBorder
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = outputFont
        view.usesFontPanel = false
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = view.maxSize
        view.textContainer?.widthTracksTextView = false
        view.setAccessibilityLabel("Command output")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        Self.updateOutput(text, in: scroll)
    }

    static func updateOutput(_ text: String, in scroll: NSScrollView) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let selection = view.selectedRange(), origin = scroll.contentView.bounds.origin
        let followsTail = selection.length == 0 && (view.string.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.maxY - 8)
        if view.string != text {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: outputFont, .foregroundColor: NSColor.textColor]))
        }
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        if let container = view.textContainer, let layout = view.layoutManager {
            let used = layout.usedRect(for: container)
            view.setFrameSize(NSSize(width: max(scroll.contentSize.width, used.maxX + 16), height: max(scroll.contentSize.height, used.maxY + 16)))
        }
        view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: min(selection.length, max(0, view.string.utf16.count - selection.location))))
        // Follow new rows vertically; scrolling the insertion point into view
        // also jumps horizontally to the end of a long progress bar.
        let maximumX = max(0, view.frame.width - scroll.contentSize.width)
        let maximumY = max(0, view.frame.height - scroll.contentSize.height)
        let target = NSPoint(x: min(max(0, origin.x), maximumX),
            y: followsTail ? maximumY : min(max(0, origin.y), maximumY))
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
