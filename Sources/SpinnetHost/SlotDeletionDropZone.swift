import AppKit
import SwiftUI

/// Accepts only editor Slot drags. Dropping requests confirmation; it never
/// mutates the Menu through the pasteboard or removes content on drag-end.
struct SlotDeletionDropZone: NSViewRepresentable {
    let onDrop: (UUID) -> Bool

    func makeNSView(context: Context) -> SlotDeletionDropView {
        let view = SlotDeletionDropView()
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: SlotDeletionDropView, context: Context) {
        view.onDrop = onDrop
    }
}

final class SlotDeletionDropView: NSView {
    var onDrop: ((UUID) -> Bool)?
    private var targeted = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 32))
        registerForDraggedTypes([RadialMenuView.slotPasteboardType])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drop Slot here to delete")
        setAccessibilityHelp("Dropping opens a confirmation. You can also right-click a Slot to delete it.")
    }

    required init?(coder: NSCoder) { fatalError("Not decoded from a nib") }

    override var intrinsicContentSize: NSSize { NSSize(width: 190, height: 32) }

    private func slotID(_ sender: NSDraggingInfo) -> UUID? {
        guard sender.draggingSource is RadialMenuView else { return nil }
        return sender.draggingPasteboard.string(forType: RadialMenuView.slotPasteboardType)
            .flatMap(UUID.init(uuidString:))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        targeted = slotID(sender) != nil
        return targeted ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false
        guard let id = slotID(sender) else { return false }
        return onDrop?(id) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        (targeted ? NSColor.systemRed.withAlphaComponent(0.16) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (targeted ? NSColor.systemRed : NSColor.separatorColor).setStroke()
        path.stroke()
        let title = "Drop Slot to Delete…" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: targeted ? NSColor.systemRed : NSColor.secondaryLabelColor
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                   withAttributes: attributes)
    }
}
