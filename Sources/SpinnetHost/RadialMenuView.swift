import AppKit
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
    var onCancel: (() -> Void)?

    init(items: [MenuItemPresentation]) {
        self.items = items
        let layout = RadialMenuLayout(itemCount: max(items.count, 1))
        self.layout = layout
        let diameter = (layout.outerRadius + 8) * 2
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Spinnet Menu")
        setAccessibilityHelp("Move the pointer over a Menu Item and release to run it")
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

    private func updateSelection(at point: CGPoint) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        selectedIndex = layout.hitTest(point: point, center: center)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let step = 360 / CGFloat(layout.itemCount)

        for index in 0..<layout.itemCount {
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
            (selectedIndex == index
                ? NSColor.controlAccentColor.withAlphaComponent(0.94)
                : NSColor.windowBackgroundColor.withAlphaComponent(0.94)).setFill()
            path.fill()

            let title = items[index].title
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: selectedIndex == index ? NSColor.white : NSColor.labelColor
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
