import AppKit
import Carbon
import SpinnetCore

enum RadialMenuPresentationMode {
    case runtime
    case editor
}

final class RadialMenuView: NSView {
    private var layout: RadialMenuLayout
    private var items: [MenuItemPresentation]
    private let presentationMode: RadialMenuPresentationMode
    private var trackingArea: NSTrackingArea?
    private(set) var selectedIndex: Int? {
        didSet {
            needsDisplay = true
            if oldValue != selectedIndex {
                NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
            }
        }
    }

    var onPrimarySelection: ((Int) -> Void)?
    var onAlternateSelection: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var onEditorSelection: ((Int) -> Void)?
    var onPresetDrop: ((String, Int) -> Bool)?
    var editorAccentColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    init(
        items: [MenuItemPresentation],
        mode: RadialMenuPresentationMode = .runtime
    ) {
        self.items = items
        self.presentationMode = mode
        let layout = RadialMenuLayout(itemCount: max(items.count, 1))
        self.layout = layout
        let diameter = (layout.outerRadius + 8) * 2
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        switch mode {
        case .runtime:
            setAccessibilityRole(.menu)
            setAccessibilityLabel("Spinnet Menu")
            setAccessibilityHelp(
                "Use the arrow keys and Return for a Primary Action. "
                    + "Right-click or Option-Return to show Alternate Actions."
            )
        case .editor:
            setAccessibilityRole(.group)
            setAccessibilityLabel("Editor Mode Menu")
            setAccessibilityHelp("Select a Menu Slot to edit it. Actions do not execute in Editor Mode.")
            registerForDraggedTypes([.string])
        }
        setAccessibilityValue("No Menu Item selected")
    }

    required init?(coder: NSCoder) {
        fatalError("RadialMenuView is not decoded from a nib")
    }

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        guard presentationMode == .runtime else { return }
        onCancel?()
    }

    func clearSelection() {
        selectedIndex = nil
    }

    func reload(items: [MenuItemPresentation]) {
        self.items = items
        layout = RadialMenuLayout(itemCount: max(items.count, 1))
        let diameter = (layout.outerRadius + 8) * 2
        setFrameSize(NSSize(width: diameter, height: diameter))
        clearSelection()
        needsDisplay = true
    }

    func selectEditorItem(at index: Int) {
        guard presentationMode == .editor, items.indices.contains(index) else { return }
        selectedIndex = index
        updateAccessibilityValue()
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        guard presentationMode == .runtime else { return }
        updateSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard presentationMode == .runtime else { return }
        updateSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        updateSelection(at: convert(event.locationInWindow, from: nil))
        guard presentationMode == .runtime else {
            if let selectedIndex { onEditorSelection?(selectedIndex) }
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard presentationMode == .runtime else { return }
        updateSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard presentationMode == .runtime else { return }
        selectedIndex = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard presentationMode == .runtime else { return }
        updateSelection(at: convert(event.locationInWindow, from: nil))
        guard let selectedIndex else { return }
        onPrimarySelection?(selectedIndex)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard presentationMode == .runtime else { return }
        updateSelection(at: convert(event.locationInWindow, from: nil))
        guard let selectedIndex else { return }
        onAlternateSelection?(selectedIndex)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case UInt16(kVK_LeftArrow), UInt16(kVK_UpArrow):
            moveSelection(by: -1)
            if presentationMode == .editor, let selectedIndex { onEditorSelection?(selectedIndex) }
        case UInt16(kVK_RightArrow), UInt16(kVK_DownArrow):
            moveSelection(by: 1)
            if presentationMode == .editor, let selectedIndex { onEditorSelection?(selectedIndex) }
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter), UInt16(kVK_Space):
            let index = selectedIndex ?? (items.isEmpty ? nil : 0)
            guard let index else { return }
            if presentationMode == .editor {
                onEditorSelection?(index)
            } else if event.modifierFlags.contains(.option) {
                onAlternateSelection?(index)
            } else {
                onPrimarySelection?(index)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard presentationMode == .editor else { return [] }
        return updateDropTarget(sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard presentationMode == .editor else { return [] }
        return updateDropTarget(sender) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard presentationMode == .editor else { return }
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard presentationMode == .editor,
              let index = updateDropTarget(sender),
              let pluginID = sender.draggingPasteboard.string(forType: .string) else {
            return false
        }
        onEditorSelection?(index)
        return onPresetDrop?(pluginID, index) ?? false
    }

    private func updateDropTarget(_ sender: NSDraggingInfo) -> Int? {
        let point = convert(sender.draggingLocation, from: nil)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let index = layout.hitTest(point: point, center: center)
        if selectedIndex != index {
            selectedIndex = index
            updateAccessibilityValue()
        }
        return index
    }

    private func updateSelection(at point: CGPoint) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        selectedIndex = layout.hitTest(point: point, center: center)
        updateAccessibilityValue()
    }

    private func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        let current = selectedIndex ?? (offset < 0 ? 0 : count - 1)
        selectedIndex = (current + offset + count) % count
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        if let selectedIndex, items.indices.contains(selectedIndex) {
            setAccessibilityValue(items[selectedIndex].primaryAction.accessibilityLabel)
        } else {
            setAccessibilityValue("No Menu Item selected")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let step = 360 / CGFloat(layout.itemCount)

        for index in 0..<layout.itemCount where items.indices.contains(index) {
            let item = items[index]
            let path = NSBezierPath()
            path.appendArc(
                withCenter: center,
                radius: layout.outerRadius,
                startAngle: 90 - CGFloat(index + 1) * step + 2,
                endAngle: 90 - CGFloat(index) * step - 2
            )
            path.appendArc(
                withCenter: center,
                radius: layout.innerRadius,
                startAngle: 90 - CGFloat(index) * step - 2,
                endAngle: 90 - CGFloat(index + 1) * step + 2,
                clockwise: true
            )
            path.close()
            let fillColor: NSColor
            if !item.primaryAction.isAvailable {
                fillColor = NSColor.systemGray.withAlphaComponent(0.55)
            } else if selectedIndex == index {
                fillColor = editorAccentColor.withAlphaComponent(0.88)
            } else {
                fillColor = NSColor.controlBackgroundColor
            }
            fillColor.setFill()
            path.fill()
            (selectedIndex == index
                ? editorAccentColor
                : NSColor.separatorColor.withAlphaComponent(0.85)).setStroke()
            path.lineWidth = selectedIndex == index ? 2.5 : 1
            path.stroke()

            let title = item.title
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: selectedIndex == index && item.primaryAction.isAvailable
                    ? NSColor.white
                    : NSColor.labelColor
            ]
            let point = layout.itemCenter(index: index, center: center)
            let size = title.size(withAttributes: attributes)
            title.draw(
                at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                withAttributes: attributes
            )
        }

        let hubRect = NSRect(
            x: center.x - layout.innerRadius + 8,
            y: center.y - layout.innerRadius + 8,
            width: (layout.innerRadius - 8) * 2,
            height: (layout.innerRadius - 8) * 2
        )
        let hubPath = NSBezierPath(ovalIn: hubRect)
        NSColor.windowBackgroundColor.setFill()
        hubPath.fill()
        NSColor.separatorColor.withAlphaComponent(0.75).setStroke()
        hubPath.lineWidth = 1
        hubPath.stroke()

        let centerLabel = presentationMode == .editor ? "SELECT SLOT" as NSString : "Spinnet" as NSString
        let centerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = centerLabel.size(withAttributes: centerAttributes)
        centerLabel.draw(
            at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            withAttributes: centerAttributes
        )
    }
}
