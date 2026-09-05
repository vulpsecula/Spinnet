import AppKit
import Carbon
import SpinnetCore

enum RadialMenuPresentationMode {
    case runtime
    case editor
}

final class RadialMenuView: NSView {
    static let libraryPresetPasteboardType = NSPasteboard.PasteboardType(
        "com.spinnet.library-preset"
    )
    static let menuItemPasteboardType = NSPasteboard.PasteboardType(
        "com.spinnet.menu-item"
    )
    private static let textPasteboardType = NSPasteboard.PasteboardType.string

    private var layout: RadialMenuLayout
    private var slots: [MenuSlotPresentation]
    private let presentationMode: RadialMenuPresentationMode
    private var appearanceConfiguration = MenuAppearanceConfiguration()
    private var trackingArea: NSTrackingArea?
    private var editorMouseDownIndex: Int?
    private var editorDragStarted = false
    private var contextMenuIndex: Int?
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
    var onEditorEditRequested: ((Int) -> Void)?
    var onEditorSlotDeleteRequested: ((Int) -> Void)?
    var onPresetDrop: ((String, Int) -> Bool)?
    var onMenuItemDrop: ((Int, Int) -> Bool)?
    var editorAccentColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    init(
        slots: [MenuSlotPresentation],
        mode: RadialMenuPresentationMode = .runtime
    ) {
        self.slots = slots
        self.presentationMode = mode
        let layout = RadialMenuLayout(itemCount: max(slots.count, 1))
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
            setAccessibilityHelp(
                "Left-click a Menu Slot to focus it. Right-click for details and actions. "
                    + "Actions do not execute in Editor Mode."
            )
            registerForDraggedTypes([
                Self.libraryPresetPasteboardType,
                Self.textPasteboardType,
                Self.menuItemPasteboardType
            ])
        }
        setAccessibilityValue("No Menu Item selected")
    }

    convenience init(
        items: [MenuItemPresentation],
        mode: RadialMenuPresentationMode = .runtime
    ) {
        self.init(slots: items.map(MenuSlotPresentation.occupied), mode: mode)
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

    func reload(slots: [MenuSlotPresentation]) {
        self.slots = slots
        layout = appearanceConfiguration.layout(slotCount: slots.count)
        let diameter = (layout.outerRadius + 8) * 2
        setFrameSize(NSSize(width: diameter, height: diameter))
        clearSelection()
        needsDisplay = true
    }

    func reload(items: [MenuItemPresentation]) {
        reload(slots: items.map(MenuSlotPresentation.occupied))
    }

    func applyAppearance(_ appearance: MenuAppearanceConfiguration) {
        appearanceConfiguration = appearance
        editorAccentColor = appearance.accentColor
        layout = appearance.layout(slotCount: slots.count)
        let diameter = (layout.outerRadius + 8) * 2
        setFrameSize(NSSize(width: diameter, height: diameter))
        needsDisplay = true
    }

    func selectEditorItem(at index: Int) {
        guard presentationMode == .editor, slots.indices.contains(index) else { return }
        selectedIndex = index
        updateAccessibilityValue()
    }

    func updateRuntimeSelection(at point: CGPoint) {
        guard presentationMode == .runtime else { return }
        updateSelection(at: point)
    }

    func commitRuntimeSelection() {
        guard presentationMode == .runtime, let selectedIndex else { return }
        onPrimarySelection?(selectedIndex)
    }

    /// Resolves the payload emitted by both native AppKit drags and SwiftUI's
    /// `onDrag`, which uses the standard text pasteboard type for NSString data.
    static func libraryPresetID(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: Self.libraryPresetPasteboardType)
            ?? pasteboard.string(forType: Self.textPasteboardType)
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
        if presentationMode == .editor, let selectedIndex {
            onEditorSelection?(selectedIndex)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard presentationMode == .runtime else {
            beginEditorDrag(with: event)
            return
        }
        updateSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        updateSelection(at: convert(event.locationInWindow, from: nil))
        guard presentationMode == .runtime else {
            if let selectedIndex {
                onEditorSelection?(selectedIndex)
                editorMouseDownIndex = selectedIndex
                editorDragStarted = false
            }
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard presentationMode == .runtime else {
            super.rightMouseDown(with: event)
            return
        }
        updateSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard presentationMode == .editor else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = slotIndex(at: point) else { return nil }
        selectEditorItem(at: index)
        onEditorSelection?(index)
        return makeEditorContextMenu(for: index)
    }

    override func mouseExited(with event: NSEvent) {
        guard presentationMode == .runtime else { return }
        selectedIndex = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard presentationMode == .runtime else {
            defer {
                editorMouseDownIndex = nil
                editorDragStarted = false
            }
            guard !editorDragStarted, let editorMouseDownIndex,
                  slots[editorMouseDownIndex].item != nil else { return }
            onEditorEditRequested?(editorMouseDownIndex)
            return
        }
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
            let index = selectedIndex ?? (slots.isEmpty ? nil : 0)
            guard let index else { return }
            if presentationMode == .editor {
                onEditorSelection?(index)
                if slots[index].item != nil { onEditorEditRequested?(index) }
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
        return dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard presentationMode == .editor else { return [] }
        return dropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard presentationMode == .editor else { return }
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard presentationMode == .editor,
              let index = updateDropTarget(sender) else {
            return false
        }
        onEditorSelection?(index)
        if let pluginID = Self.libraryPresetID(from: sender.draggingPasteboard) {
            return onPresetDrop?(pluginID, index) ?? false
        }
        if let source = sender.draggingPasteboard.string(
            forType: Self.menuItemPasteboardType
        ).flatMap(Int.init) {
            return onMenuItemDrop?(source, index) ?? false
        }
        return false
    }

    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let target = updateDropTarget(sender) else { return [] }
        if Self.libraryPresetID(from: sender.draggingPasteboard) != nil {
            return .copy
        }
        if let source = sender.draggingPasteboard.string(
            forType: Self.menuItemPasteboardType
        ).flatMap(Int.init),
           source != target,
           slots[target].item == nil {
            return .move
        }
        return []
    }

    private func beginEditorDrag(with event: NSEvent) {
        guard !editorDragStarted,
              let sourceIndex = editorMouseDownIndex,
              slots.indices.contains(sourceIndex),
              slots[sourceIndex].item != nil else { return }
        editorDragStarted = true
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(
            String(sourceIndex),
            forType: Self.menuItemPasteboardType
        )
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = NSImage(
            systemSymbolName: "circle.grid.cross",
            accessibilityDescription: "Move Menu Item"
        ) ?? NSImage(size: NSSize(width: 28, height: 28))
        let origin = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            NSRect(x: origin.x - 14, y: origin.y - 14, width: 28, height: 28),
            contents: image
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func updateDropTarget(_ sender: NSDraggingInfo) -> Int? {
        let point = convert(sender.draggingLocation, from: nil)
        guard let index = slotIndex(at: point) else { return nil }
        if selectedIndex != index {
            selectedIndex = index
            updateAccessibilityValue()
        }
        return index
    }

    private func slotIndex(at point: CGPoint) -> Int? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return layout.hitTest(point: point, center: center)
    }

    private func makeEditorContextMenu(for index: Int) -> NSMenu {
        contextMenuIndex = index
        let slot = slots[index]
        let menu = NSMenu(title: "Slot \(index + 1)")

        let slotInfo = NSMenuItem(
            title: "Slot \(index + 1) — \(slot.isEmpty ? "Empty" : slot.title)",
            action: nil,
            keyEquivalent: ""
        )
        slotInfo.isEnabled = false
        menu.addItem(slotInfo)

        if let item = slot.item {
            let primaryInfo = NSMenuItem(
                title: "Primary Action: \(item.primaryAction.displayTitle)",
                action: nil,
                keyEquivalent: ""
            )
            primaryInfo.isEnabled = false
            menu.addItem(primaryInfo)

            for alternate in item.alternateActions {
                let alternateInfo = NSMenuItem(
                    title: "Alternate Action: \(alternate.displayTitle)",
                    action: nil,
                    keyEquivalent: ""
                )
                alternateInfo.isEnabled = false
                menu.addItem(alternateInfo)
            }

            menu.addItem(.separator())
            let editItem = NSMenuItem(
                title: "Edit Menu Item",
                action: #selector(editContextMenuSlot(_:)),
                keyEquivalent: ""
            )
            editItem.target = self
            menu.addItem(editItem)
        } else {
            menu.addItem(.separator())
        }

        let deleteItem = NSMenuItem(
            title: "Delete Slot",
            action: #selector(deleteContextMenuSlot(_:)),
            keyEquivalent: ""
        )
        deleteItem.target = self
        deleteItem.isEnabled = slots.count > 1
        deleteItem.toolTip = deleteItem.isEnabled
            ? "Delete this Slot from the Menu"
            : "A Menu must contain at least one Slot"
        menu.addItem(deleteItem)
        return menu
    }

    @objc private func editContextMenuSlot(_ sender: Any?) {
        guard let contextMenuIndex else { return }
        onEditorEditRequested?(contextMenuIndex)
    }

    @objc private func deleteContextMenuSlot(_ sender: Any?) {
        guard let contextMenuIndex else { return }
        onEditorSlotDeleteRequested?(contextMenuIndex)
    }

    private func updateSelection(at point: CGPoint) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        selectedIndex = layout.hitTest(point: point, center: center)
        updateAccessibilityValue()
    }

    private func moveSelection(by offset: Int) {
        guard !slots.isEmpty else { return }
        let count = slots.count
        let current = selectedIndex ?? (offset < 0 ? 0 : count - 1)
        selectedIndex = (current + offset + count) % count
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        if let selectedIndex, slots.indices.contains(selectedIndex) {
            if let item = slots[selectedIndex].item {
                setAccessibilityValue(item.primaryAction.accessibilityLabel)
            } else {
                setAccessibilityValue("Empty Slot \(selectedIndex + 1)")
            }
        } else {
            setAccessibilityValue("No Menu Item selected")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let step = 360 / CGFloat(layout.itemCount)

        for index in 0..<layout.itemCount where slots.indices.contains(index) {
            let slot = slots[index]
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
            if slot.isEmpty {
                fillColor = selectedIndex == index
                    ? editorAccentColor.withAlphaComponent(0.16)
                    : NSColor.controlBackgroundColor.withAlphaComponent(0.6)
            } else if slot.item?.primaryAction.isAvailable == false {
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
            if slot.isEmpty {
                let pattern: [CGFloat] = [6, 5]
                path.setLineDash(pattern, count: pattern.count, phase: 0)
            }
            path.stroke()

            let title = slot.isEmpty ? "+" : displayTitle(slot.title)
            let titleFontSize: CGFloat
            if slot.isEmpty {
                titleFontSize = 22
            } else if layout.itemCount >= 10 {
                titleFontSize = 10
            } else if layout.itemCount >= 8 {
                titleFontSize = 11
            } else {
                titleFontSize = 13
            }
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.lineBreakMode = .byTruncatingMiddle
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: titleFontSize, weight: .semibold),
                .paragraphStyle: paragraphStyle,
                .foregroundColor: selectedIndex == index && slot.item?.primaryAction.isAvailable != false
                    ? NSColor.white
                    : (slot.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor)
            ]
            let point = layout.itemCenter(index: index, center: center)
            let titleWidth = max(
                36,
                2 * layout.itemCenterRadius * sin(.pi / CGFloat(layout.itemCount)) - 8
            )
            let titleHeight: CGFloat = layout.itemCount >= 10 ? 28 : 18
            title.draw(
                in: NSRect(
                    x: point.x - titleWidth / 2,
                    y: point.y - titleHeight / 2 + (layout.itemCount >= 10 ? 4 : 0),
                    width: titleWidth,
                    height: titleHeight
                ),
                withAttributes: attributes
            )

            if presentationMode == .editor, selectedIndex == index {
                let hint = (slot.isEmpty ? "DROP HERE" : "EDIT") as NSString
                let hintAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: slot.isEmpty ? editorAccentColor : NSColor.white.withAlphaComponent(0.9)
                ]
                let hintSize = hint.size(withAttributes: hintAttributes)
                hint.draw(
                    at: CGPoint(x: point.x - hintSize.width / 2, y: point.y - hintSize.height / 2 - 20),
                    withAttributes: hintAttributes
                )
            }
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

        let centerLabel = presentationMode == .editor ? "MENU" as NSString : "Spinnet" as NSString
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

    private func displayTitle(_ title: String) -> String {
        guard layout.itemCount >= 10 else { return title }
        let words = title.split(whereSeparator: \Character.isWhitespace)
        guard let firstWord = words.first, words.count > 1 else { return title }
        return String(firstWord) + "\n" + words.dropFirst().joined(separator: " ")
    }
}

extension RadialMenuView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        editorMouseDownIndex = nil
        editorDragStarted = false
    }
}
