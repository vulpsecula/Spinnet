import AppKit
import Carbon
import SpinnetCore

final class RadialMenuView: NSView {
    private let layout: RadialMenuLayout
    private let items: [MenuItemPresentation]
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

    init(items: [MenuItemPresentation]) {
        self.items = items
        let layout = RadialMenuLayout(itemCount: max(items.count, 1))
        self.layout = layout
        let diameter = (layout.outerRadius + 8) * 2
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Spinnet Menu")
        setAccessibilityHelp(
            "Use the arrow keys and Return for a Primary Action. "
                + "Right-click or Option-Return to show Alternate Actions."
        )
        setAccessibilityValue("No Menu Item selected")
    }

    required init?(coder: NSCoder) {
        fatalError("RadialMenuView is not decoded from a nib")
    }

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func clearSelection() {
        selectedIndex = nil
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
        updateSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        selectedIndex = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let selectedIndex else { return }
        onPrimarySelection?(selectedIndex)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let selectedIndex else { return }
        onAlternateSelection?(selectedIndex)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case UInt16(kVK_LeftArrow), UInt16(kVK_UpArrow):
            moveSelection(by: -1)
        case UInt16(kVK_RightArrow), UInt16(kVK_DownArrow):
            moveSelection(by: 1)
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter), UInt16(kVK_Space):
            let index = selectedIndex ?? (items.isEmpty ? nil : 0)
            guard let index else { return }
            if event.modifierFlags.contains(.option) {
                onAlternateSelection?(index)
            } else {
                onPrimarySelection?(index)
            }
        default:
            super.keyDown(with: event)
        }
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
                fillColor = NSColor.controlAccentColor.withAlphaComponent(0.94)
            } else {
                fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94)
            }
            fillColor.setFill()
            path.fill()

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

        let centerLabel = "Spinnet" as NSString
        let centerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = centerLabel.size(withAttributes: centerAttributes)
        centerLabel.draw(
            at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            withAttributes: centerAttributes
        )
    }
}
