import AppKit
import SwiftUI

/// A read-only transcript, not a terminal input surface. Keep native selection
/// and scroll position when a one-second source supplies another output frame.
struct PluginCommandOutputView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeOutputView()
    }

    static func makeOutputView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .lineBorder
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
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
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let selection = view.selectedRange(), origin = scroll.contentView.bounds.origin
        let followsTail = selection.length == 0 && (view.string.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.maxY - 8)
        view.string = text
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        if let container = view.textContainer, let layout = view.layoutManager {
            let used = layout.usedRect(for: container)
            view.setFrameSize(NSSize(width: max(scroll.contentSize.width, used.maxX + 16), height: max(scroll.contentSize.height, used.maxY + 16)))
        }
        view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: min(selection.length, max(0, view.string.utf16.count - selection.location))))
        if followsTail { view.scrollRangeToVisible(NSRange(location: view.string.utf16.count, length: 0)) }
        else {
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
