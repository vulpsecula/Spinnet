import AppKit
import Carbon
import SpinnetCore

enum RadialMenuPresentationMode {
    case runtime
    case editor
}

private final class RadialMenuEditButton: NSButton {
    var contextMenuProvider: (() -> NSMenu?)?
    var draggingEnteredProvider: ((NSDraggingInfo) -> NSDragOperation)?
    var draggingUpdatedProvider: ((NSDraggingInfo) -> NSDragOperation)?
    var performDragProvider: ((NSDraggingInfo) -> Bool)?
    var draggingExitedProvider: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEnteredProvider?(sender) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdatedProvider?(sender) ?? super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performDragProvider?(sender) ?? super.performDragOperation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        draggingExitedProvider?()
        super.draggingExited(sender)
    }
}

final class RadialMenuView: NSView {
    private struct MenuFontCacheKey: Hashable {
        let font: MenuAppearanceConfiguration.MenuFont
        let weight: MenuAppearanceConfiguration.MenuFontWeight
        let baseSize: Int
    }

    private struct MenuTitleLayoutCacheKey: Hashable {
        let title: String
        let widthBucket: Int
        let baseSize: Int
        let font: MenuAppearanceConfiguration.MenuFont
        let weight: MenuAppearanceConfiguration.MenuFontWeight
    }

    private struct MenuTitleDrawingMetrics {
        let point: CGPoint
        let layout: MenuTitleLayout
        let rect: NSRect
    }

    static let libraryPresetPasteboardType = NSPasteboard.PasteboardType(
        "com.spinnet.library-preset"
    )
    static let menuItemPasteboardType = NSPasteboard.PasteboardType(
        "com.spinnet.menu-item"
    )
    private static let textPasteboardType = NSPasteboard.PasteboardType.string

    private var layout: RadialMenuLayout
    private var slots: [MenuSlotPresentation]
    private var menuFontCache: [MenuFontCacheKey: NSFont] = [:]
    private var menuTitleLayoutCache: [MenuTitleLayoutCacheKey: MenuTitleLayout] = [:]
    private var cachedPreviewImage: NSImage?
    private var lastPreviewBounds: NSRect?
    private let presentationMode: RadialMenuPresentationMode
    private let allowsEditing: Bool
    private let previewScale: CGFloat
    private let previewCanvasDiameter: CGFloat?
    private let showsPreviewBackground: Bool
    private var appearanceConfiguration = MenuAppearanceConfiguration()
    private var trackingArea: NSTrackingArea?
    private var editorMouseDownIndex: Int?
    private var editorMouseDownIsEdit = false
    private var editorDragStarted = false
    private var contextMenuIndex: Int?
    private(set) var hoveredIndex: Int?
    private var editButtons: [Int: NSButton] = [:]
    private(set) var selectedIndex: Int? {
        didSet {
            needsDisplay = true
            if oldValue != selectedIndex {
                invalidatePreviewImage()
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
        mode: RadialMenuPresentationMode = .runtime,
        allowsEditing: Bool = true,
        previewScale: CGFloat = 1,
        previewCanvasDiameter: CGFloat? = nil,
        showsPreviewBackground: Bool = false
    ) {
        self.slots = slots
        self.presentationMode = mode
        self.allowsEditing = allowsEditing
        self.previewScale = max(previewScale, 0.1)
        self.previewCanvasDiameter = previewCanvasDiameter.map { max($0, 1) }
        self.showsPreviewBackground = showsPreviewBackground
        let layout = RadialMenuLayout(
            itemCount: max(slots.count, 1),
            innerRadius: 38 * self.previewScale,
            outerRadius: 142 * self.previewScale,
            itemCenterRadius: 90 * self.previewScale
        )
        self.layout = layout
        super.init(
            frame: CGRect(
                x: 0,
                y: 0,
                width: self.previewCanvasDiameter ?? layout.contentDiameter,
                height: self.previewCanvasDiameter ?? layout.contentDiameter
            )
        )
        switch mode {
        case .runtime:
            setAccessibilityRole(.menu)
            setAccessibilityLabel("Spinnet Menu")
            setAccessibilityHelp(
                "Use the arrow keys and Return for a Primary Action. "
                    + "Right-click or Option-Return to choose from the configured Actions."
            )
        case .editor:
            setAccessibilityRole(.group)
            setAccessibilityLabel("Editor Mode Menu")
            if allowsEditing {
                setAccessibilityHelp(
                    "Left-click a Menu Slot to focus it. Use the in-slot Edit button to configure "
                        + "an occupied Slot, double-click an occupied Slot, or right-click for details "
                        + "and actions. Press Return, Space, or Command-E to edit the focused Slot. "
                        + "Actions do not execute in Editor Mode."
                )
                registerForDraggedTypes([
                    Self.libraryPresetPasteboardType,
                    Self.textPasteboardType,
                    Self.menuItemPasteboardType
                ])
                rebuildEditButtons()
            } else {
                setAccessibilityHelp(
                    "Move the pointer over a Menu Slot to inspect its Appearance. "
                        + "Actions and Menu edits are disabled in Editor Mode."
                )
            }
        }
        setAccessibilityValue(noSelectionAccessibilityValue)
    }

    convenience init(
        items: [MenuItemPresentation],
        mode: RadialMenuPresentationMode = .runtime,
        allowsEditing: Bool = true,
        previewScale: CGFloat = 1,
        previewCanvasDiameter: CGFloat? = nil,
        showsPreviewBackground: Bool = false
    ) {
        self.init(
            slots: items.map(MenuSlotPresentation.occupied),
            mode: mode,
            allowsEditing: allowsEditing,
            previewScale: previewScale,
            previewCanvasDiameter: previewCanvasDiameter,
            showsPreviewBackground: showsPreviewBackground
        )
    }

    required init?(coder: NSCoder) {
        fatalError("RadialMenuView is not decoded from a nib")
    }

    override var acceptsFirstResponder: Bool {
        presentationMode == .runtime || allowsEditing
    }

    override func cancelOperation(_ sender: Any?) {
        guard presentationMode == .runtime else { return }
        onCancel?()
    }

    func clearSelection() {
        selectedIndex = nil
        if hoveredIndex != nil {
            hoveredIndex = nil
            invalidatePreviewImage()
        }
        updateAccessibilityValue()
    }

    /// Applies the smallest update needed by the Editor Mode Menu. Appearance
    /// changes arrive for every Slider sample, so reloading unchanged Menu
    /// Slots here would unnecessarily clear selection and rebuild Edit buttons.
    func update(
        slots: [MenuSlotPresentation],
        appearance: MenuAppearanceConfiguration
    ) {
        let slotsChanged = self.slots != slots
        let oldAppearance = appearanceConfiguration
        let appearanceChanged = oldAppearance != appearance
        let renderingAppearanceChanged = appearanceAffectsRendering(
            from: oldAppearance,
            to: appearance
        )
        guard slotsChanged || appearanceChanged else { return }

        if slotsChanged {
            self.slots = slots
            invalidatePreviewImage()
            clearSelection()
        }
        if appearanceChanged {
            if renderingAppearanceChanged {
                invalidatePreviewImage()
            }
            appearanceConfiguration = appearance
            if appearance.accent != oldAppearance.accent {
                editorAccentColor = appearance.accentColor
            }
            if appearance.theme != oldAppearance.theme {
                self.appearance = appearance.appearance
            }
        }

        layout = previewLayout(for: appearanceConfiguration)
        updateFrameSize(for: layout)
        if slotsChanged {
            rebuildEditButtons()
        } else if presentationMode == .editor, allowsEditing {
            layoutEditButtons()
        }
        needsDisplay = true
    }

    func reload(slots: [MenuSlotPresentation]) {
        self.slots = slots
        invalidatePreviewImage()
        layout = previewLayout(for: appearanceConfiguration)
        updateFrameSize(for: layout)
        clearSelection()
        rebuildEditButtons()
        needsDisplay = true
    }

    func reload(items: [MenuItemPresentation]) {
        reload(slots: items.map(MenuSlotPresentation.occupied))
    }

    func applyAppearance(_ appearance: MenuAppearanceConfiguration) {
        if appearanceAffectsRendering(from: appearanceConfiguration, to: appearance) {
            invalidatePreviewImage()
        }
        appearanceConfiguration = appearance
        editorAccentColor = appearance.accentColor
        self.appearance = appearance.appearance
        layout = previewLayout(for: appearance)
        updateFrameSize(for: layout)
        layoutEditButtons()
        needsDisplay = true
    }

    private func appearanceAffectsRendering(
        from oldAppearance: MenuAppearanceConfiguration,
        to newAppearance: MenuAppearanceConfiguration
    ) -> Bool {
        oldAppearance.theme != newAppearance.theme
            || oldAppearance.accent != newAppearance.accent
            || oldAppearance.font != newAppearance.font
            || oldAppearance.fontWeight != newAppearance.fontWeight
    }

    private func invalidatePreviewImage() {
        cachedPreviewImage = nil
    }

    /// The complete drawing and hit-testing geometry currently used by this
    /// view. Runtime Mode exposes the same contract through its presentation
    /// snapshot so Editor and Runtime can be verified at their boundary.
    var geometryLayout: RadialMenuLayout {
        layout
    }

    private func previewLayout(for appearance: MenuAppearanceConfiguration) -> RadialMenuLayout {
        let baseLayout = appearance.layout(slotCount: slots.count)
        let fittingScale = previewFittingScale(for: appearance, baseLayout: baseLayout)
        guard fittingScale != 1 else { return baseLayout }
        return RadialMenuLayout(
            itemCount: baseLayout.itemCount,
            innerRadius: baseLayout.innerRadius * fittingScale,
            outerRadius: baseLayout.outerRadius * fittingScale,
            itemCenterRadius: baseLayout.itemCenterRadius * fittingScale
        )
    }

    private func previewFittingScale(
        for appearance: MenuAppearanceConfiguration,
        baseLayout: RadialMenuLayout
    ) -> CGFloat {
        guard let previewCanvasDiameter else { return previewScale }

        let minimumScale = MenuAppearanceConfiguration.menuSizeMinimumPercentage / 100
        let maximumScale = MenuAppearanceConfiguration.menuSizeMaximumPercentage / 100
        let normalizedScale = min(
            max((appearance.scale - minimumScale) / (maximumScale - minimumScale), 0),
            1
        )
        // Keep the complete Menu visible while retaining a monotonic visual
        // difference between ordinary and very large sizes.
        let previewFillRatio = 0.82 + 0.18 * sqrt(normalizedScale)
        let targetDiameter = previewCanvasDiameter * previewFillRatio
        let targetOuterRadius = max(
            (targetDiameter - 2 * RadialMenuLayout.defaultOverlayPadding) / 2,
            1
        )
        return min(previewScale, targetOuterRadius / baseLayout.outerRadius)
    }

    private func previewFrameSize(for layout: RadialMenuLayout) -> NSSize {
        let diameter = previewCanvasDiameter ?? layout.contentDiameter
        return NSSize(width: diameter, height: diameter)
    }

    private func updateFrameSize(for layout: RadialMenuLayout) {
        guard previewCanvasDiameter == nil else { return }
        setFrameSize(previewFrameSize(for: layout))
    }

    func selectEditorItem(at index: Int) {
        guard presentationMode == .editor,
              allowsEditing,
              slots.indices.contains(index),
              selectedIndex != index else { return }
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
        let point = convert(event.locationInWindow, from: nil)
        if presentationMode != .runtime {
            updateHover(at: point)
        } else {
            updateSelection(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard presentationMode == .runtime else {
            guard allowsEditing else { return }
            beginEditorDrag(with: event)
            return
        }
        updateSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard presentationMode == .editor else {
            updateSelection(at: convert(event.locationInWindow, from: nil))
            return
        }
        guard allowsEditing else {
            return
        }

        updateHover(at: point)
        guard let index = slotIndex(at: point) else {
            editorMouseDownIndex = nil
            editorMouseDownIsEdit = false
            editorDragStarted = false
            return
        }
        selectEditorItem(at: index)
        onEditorSelection?(index)
        editorMouseDownIndex = index
        editorMouseDownIsEdit = isEditButtonHit(at: point, index: index)
        editorDragStarted = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard presentationMode == .runtime else {
            guard allowsEditing else { return }
            super.rightMouseDown(with: event)
            return
        }
        updateSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard presentationMode == .editor, allowsEditing else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = slotIndex(at: point) else { return nil }
        updateHover(at: point)
        selectEditorItem(at: index)
        onEditorSelection?(index)
        return makeEditorContextMenu(for: index)
    }

    override func mouseExited(with event: NSEvent) {
        if presentationMode == .runtime {
            clearSelection()
        } else {
            updateHover(at: nil)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard presentationMode == .editor else {
            updateSelection(at: convert(event.locationInWindow, from: nil))
            guard let selectedIndex else { return }
            onPrimarySelection?(selectedIndex)
            return
        }
        guard allowsEditing else {
            return
        }
        defer {
            editorMouseDownIndex = nil
            editorMouseDownIsEdit = false
            editorDragStarted = false
        }
        guard !editorDragStarted,
              let editorMouseDownIndex,
              slots.indices.contains(editorMouseDownIndex),
              slots[editorMouseDownIndex].item != nil else { return }
        let clickedEditButton = isEditButtonHit(
            at: convert(event.locationInWindow, from: nil),
            index: editorMouseDownIndex
        )
        let shouldOpenEditor = editorMouseDownIsEdit
            || (event.clickCount >= 2 && !clickedEditButton)
        guard shouldOpenEditor else { return }
        onEditorEditRequested?(editorMouseDownIndex)
        return
    }

    override func rightMouseUp(with event: NSEvent) {
        guard presentationMode == .runtime else { return }
        updateSelection(at: convert(event.locationInWindow, from: nil))
        guard let selectedIndex else { return }
        onAlternateSelection?(selectedIndex)
    }

    override func keyDown(with event: NSEvent) {
        guard presentationMode == .runtime || allowsEditing else { return }
        if presentationMode == .editor,
           event.keyCode == UInt16(kVK_ANSI_E),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
           let selectedIndex,
           slots.indices.contains(selectedIndex),
           slots[selectedIndex].item != nil {
            onEditorEditRequested?(selectedIndex)
            return
        }

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
        guard presentationMode == .editor, allowsEditing else { return [] }
        return dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard presentationMode == .editor, allowsEditing else { return [] }
        return dropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard presentationMode == .editor, allowsEditing else { return }
        updateHover(at: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard presentationMode == .editor,
              allowsEditing,
              let index = updateDropTarget(sender) else {
            return false
        }
        selectEditorItem(at: index)
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
        guard !editorMouseDownIsEdit,
              !editorDragStarted,
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
        guard let index = slotIndex(at: point) else {
            updateHover(at: nil)
            return nil
        }
        updateHover(at: point)
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
                title: "Edit Slot…",
                action: #selector(editContextMenuSlot(_:)),
                keyEquivalent: ""
            )
            editItem.target = self
            editItem.toolTip = "Choose the Slot's Actions or give the Slot a custom name"
            menu.addItem(editItem)
        } else {
            menu.addItem(.separator())
        }

        let slotAction = NSMenuItem(
            title: slot.isEmpty ? "Delete Slot" : "Clear Slot",
            action: #selector(deleteContextMenuSlot(_:)),
            keyEquivalent: ""
        )
        slotAction.target = self
        slotAction.isEnabled = slot.isEmpty ? slots.count > 1 : true
        slotAction.toolTip = slot.isEmpty
            ? (slotAction.isEnabled
                ? "Delete this empty Slot from the Menu"
                : "A Menu must contain at least one Slot")
            : "Clear the Menu Item from this Slot"
        menu.addItem(slotAction)
        return menu
    }

    private func rebuildEditButtons() {
        guard presentationMode == .editor, allowsEditing else { return }
        for button in editButtons.values {
            button.removeFromSuperview()
        }
        editButtons.removeAll(keepingCapacity: true)

        for index in slots.indices where slots[index].item != nil {
            let button = RadialMenuEditButton(
                title: "Edit",
                target: self,
                action: #selector(editButtonClicked(_:))
            )
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
            button.alignment = .center
            button.setAccessibilityLabel("Edit Menu Item in Slot \(index + 1)")
            button.setAccessibilityHelp("Open the configuration for this Menu Item.")
            button.toolTip = "Edit Menu Item"
            button.registerForDraggedTypes([
                Self.libraryPresetPasteboardType,
                Self.textPasteboardType,
                Self.menuItemPasteboardType
            ])
            button.contextMenuProvider = { [weak self] in
                guard let self else { return nil }
                self.selectEditorItem(at: index)
                self.onEditorSelection?(index)
                return self.makeEditorContextMenu(for: index)
            }
            button.draggingEnteredProvider = { [weak self] sender in
                self?.dropOperation(for: sender) ?? []
            }
            button.draggingUpdatedProvider = { [weak self] sender in
                self?.dropOperation(for: sender) ?? []
            }
            button.performDragProvider = { [weak self] sender in
                self?.performDragOperation(sender) ?? false
            }
            button.draggingExitedProvider = { [weak self] in
                self?.updateHover(at: nil)
            }
            addSubview(button)
            editButtons[index] = button
        }
        layoutEditButtons()
    }

    private func layoutEditButtons() {
        guard presentationMode == .editor, allowsEditing else { return }
        for (index, button) in editButtons {
            button.frame = editorEditButtonRect(at: index)
        }
    }

    /// The hit region of the in-slot Edit button. Keeping this geometry in one
    /// place lets mouse-event fallbacks and UI tests follow the native button.
    func editorEditButtonRect(at index: Int) -> NSRect {
        guard presentationMode == .editor,
              allowsEditing,
              slots.indices.contains(index),
              slots[index].item != nil else {
            return .zero
        }
        let titleMetrics = titleDrawingMetrics(at: index, using: layout, in: bounds)
        let point = titleMetrics.point
        let sectorWidth = Self.menuTitleWidth(for: layout)
        let width = min(48, max(38, sectorWidth))
        let height: CGFloat = 20
        let titleToButtonGap: CGFloat = 8
        return NSRect(
            x: point.x - width / 2,
            y: titleMetrics.rect.minY - titleToButtonGap - height,
            width: width,
            height: height
        )
    }

    private func isEditButtonHit(at point: NSPoint, index: Int) -> Bool {
        guard let button = editButtons[index] else { return false }
        return button.frame.contains(point)
    }

    @objc private func editButtonClicked(_ sender: NSButton) {
        let index = sender.tag
        guard slots.indices.contains(index), slots[index].item != nil else { return }
        selectEditorItem(at: index)
        onEditorSelection?(index)
        onEditorEditRequested?(index)
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

    private func updateHover(at point: CGPoint?) {
        let nextIndex = point.flatMap(slotIndex(at:))
        guard hoveredIndex != nextIndex else { return }
        hoveredIndex = nextIndex
        invalidatePreviewImage()
        needsDisplay = true
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
            setAccessibilityValue(slots[selectedIndex].title)
        } else {
            setAccessibilityValue(noSelectionAccessibilityValue)
        }
    }

    private var noSelectionAccessibilityValue: String {
        presentationMode == .runtime ? "No Menu Item selected" : "No Slot selected"
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }

        NSColor.clear.setFill()
        dirtyRect.fill()
        if showsPreviewBackground {
            drawPreviewBackground()
        }
        if previewCanvasDiameter != nil {
            drawCachedPreviewMenu()
            drawMenuLabels(using: layout, in: bounds)
        } else {
            drawMenuContents(using: layout, in: bounds)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidatePreviewImage()
        needsDisplay = true
    }

    private func drawCachedPreviewMenu() {
        if lastPreviewBounds != bounds {
            lastPreviewBounds = bounds
            invalidatePreviewImage()
        }
        let previewAppearance = MenuAppearanceConfiguration(
            theme: appearanceConfiguration.theme,
            accent: appearanceConfiguration.accent,
            menuSize: MenuAppearanceConfiguration.Size.medium.rawValue,
            font: appearanceConfiguration.font,
            fontWeight: appearanceConfiguration.fontWeight
        )
        let previewLayout = previewLayout(for: previewAppearance)
        let image = cachedPreviewImage(for: previewLayout)
        let scale = layout.outerRadius / previewLayout.outerRadius
        let imageSize = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        image.draw(
            in: NSRect(
                x: bounds.midX - imageSize.width / 2,
                y: bounds.midY - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    private func cachedPreviewImage(for menuLayout: RadialMenuLayout) -> NSImage {
        if let cachedPreviewImage {
            return cachedPreviewImage
        }

        let imageSize = NSSize(
            width: menuLayout.contentDiameter,
            height: menuLayout.contentDiameter
        )
        let image = NSImage(size: imageSize)
        let drawImage = {
            // The cached geometry is composited into this ordinary, unflipped
            // NSView together with live labels and controls. Drawing it in a
            // flipped image would mirror the slot wedges vertically while
            // leaving the labels in their original positions.
            image.lockFocusFlipped(false)
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(
                rect: NSRect(origin: .zero, size: imageSize)
            ).addClip()
            self.drawMenuContents(
                using: menuLayout,
                in: NSRect(origin: .zero, size: imageSize),
                includesLabels: false
            )
            NSGraphicsContext.current?.restoreGraphicsState()
            image.unlockFocus()
        }

        if let appearance {
            appearance.performAsCurrentDrawingAppearance(drawImage)
        } else {
            drawImage()
        }
        cachedPreviewImage = image
        return image
    }

    private func drawMenuContents(
        using menuLayout: RadialMenuLayout,
        in canvas: NSRect,
        includesLabels: Bool = true
    ) {
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let step = 360 / CGFloat(menuLayout.itemCount)

        for index in 0..<menuLayout.itemCount where slots.indices.contains(index) {
            let slot = slots[index]
            let isFocused = selectedIndex == index
            let isHovered = presentationMode == .editor && hoveredIndex == index
            let path = NSBezierPath()
            path.appendArc(
                withCenter: center,
                radius: menuLayout.outerRadius,
                startAngle: 90 - CGFloat(index + 1) * step + 2,
                endAngle: 90 - CGFloat(index) * step - 2
            )
            path.appendArc(
                withCenter: center,
                radius: menuLayout.innerRadius,
                startAngle: 90 - CGFloat(index) * step - 2,
                endAngle: 90 - CGFloat(index + 1) * step + 2,
                clockwise: true
            )
            path.close()
            let fillColor: NSColor
            if slot.isEmpty {
                fillColor = isFocused
                    ? editorAccentColor.withAlphaComponent(0.16)
                    : isHovered
                    ? editorAccentColor.withAlphaComponent(0.08)
                    : NSColor.controlBackgroundColor.withAlphaComponent(0.6)
            } else if slot.item?.primaryAction.isAvailable == false {
                fillColor = NSColor.systemGray.withAlphaComponent(0.55)
            } else if isFocused {
                fillColor = editorAccentColor.withAlphaComponent(0.88)
            } else if isHovered {
                fillColor = editorAccentColor.withAlphaComponent(0.1)
            } else {
                fillColor = NSColor.controlBackgroundColor
            }
            fillColor.setFill()
            path.fill()
            (isFocused
                ? editorAccentColor
                : isHovered
                ? editorAccentColor.withAlphaComponent(0.72)
                : NSColor.separatorColor.withAlphaComponent(0.85)).setStroke()
            path.lineWidth = isFocused ? 2.5 : (isHovered ? 1.5 : 1)
            if slot.isEmpty {
                let pattern: [CGFloat] = [6, 5]
                path.setLineDash(pattern, count: pattern.count, phase: 0)
            }
            path.stroke()

        }

        let hubRect = NSRect(
            x: center.x - menuLayout.innerRadius + 8,
            y: center.y - menuLayout.innerRadius + 8,
            width: (menuLayout.innerRadius - 8) * 2,
            height: (menuLayout.innerRadius - 8) * 2
        )
        let hubPath = NSBezierPath(ovalIn: hubRect)
        NSColor.windowBackgroundColor.setFill()
        hubPath.fill()
        NSColor.separatorColor.withAlphaComponent(0.75).setStroke()
        hubPath.lineWidth = 1
        hubPath.stroke()

        if includesLabels {
            drawMenuLabels(using: menuLayout, in: canvas)
        }
    }

    private func drawMenuLabels(using menuLayout: RadialMenuLayout, in canvas: NSRect) {
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        for index in 0..<menuLayout.itemCount where slots.indices.contains(index) {
            let slot = slots[index]
            let isFocused = selectedIndex == index
            let metrics = titleDrawingMetrics(
                at: index,
                using: menuLayout,
                in: canvas
            )
            let titleLayout = metrics.layout
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.lineSpacing = 1
            let attributes: [NSAttributedString.Key: Any] = [
                .font: titleLayout.font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: isFocused && slot.item?.primaryAction.isAvailable != false
                    ? NSColor.white
                    : (slot.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor)
            ]
            titleLayout.text.draw(
                in: metrics.rect,
                withAttributes: attributes
            )

            if presentationMode == .editor, allowsEditing, selectedIndex == index, slot.isEmpty {
                let hint = "DROP HERE" as NSString
                let hintAttributes: [NSAttributedString.Key: Any] = [
                    .font: appearanceConfiguration.titleFont(ofSize: 9, weight: .bold),
                    .foregroundColor: editorAccentColor
                ]
                let hintSize = hint.size(withAttributes: hintAttributes)
                hint.draw(
                    at: CGPoint(
                        x: metrics.point.x - hintSize.width / 2,
                        y: metrics.point.y - hintSize.height / 2 - 20
                    ),
                    withAttributes: hintAttributes
                )
            }
        }

        let centerLabel = presentationMode == .editor ? "MENU" as NSString : "Spinnet" as NSString
        let centerAttributes: [NSAttributedString.Key: Any] = [
            .font: appearanceConfiguration.titleFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = centerLabel.size(withAttributes: centerAttributes)
        centerLabel.draw(
            at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            withAttributes: centerAttributes
        )
    }

    /// Returns the actual title frame used by the virtual Menu renderer. It
    /// is kept as a single geometry seam so edit controls can make room for
    /// wrapped titles instead of assuming every title is one line tall.
    func menuTitleRect(at index: Int) -> NSRect {
        guard slots.indices.contains(index) else { return .zero }
        return titleDrawingMetrics(at: index, using: layout, in: bounds).rect
    }

    private func titleDrawingMetrics(
        at index: Int,
        using menuLayout: RadialMenuLayout,
        in canvas: NSRect
    ) -> MenuTitleDrawingMetrics {
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let point = menuLayout.itemCenter(index: index, center: center)
        let titleFontSize: CGFloat
        if menuLayout.itemCount >= 10 {
            titleFontSize = 10
        } else if menuLayout.itemCount >= 8 {
            titleFontSize = 11
        } else {
            titleFontSize = 13
        }
        let titleWidth = Self.menuTitleWidth(for: menuLayout)
        let layout = titleLayout(
            for: slots[index].title,
            maxWidth: titleWidth,
            baseSize: titleFontSize
        )
        let fontLineHeight = layout.font.ascender
            - layout.font.descender
            + layout.font.leading
        let titleHeight = max(layout.size.height, fontLineHeight)
        let verticalOffset: CGFloat = menuLayout.itemCount >= 10 ? 4 : 0
        let titleRect = NSRect(
            x: point.x - titleWidth / 2,
            y: point.y - titleHeight / 2 + verticalOffset,
            width: titleWidth,
            height: titleHeight
        )
        return MenuTitleDrawingMetrics(
            point: point,
            layout: layout,
            rect: titleRect
        )
    }

    /// Returns the tangential text width available inside a Menu Slot. A
    /// one-slot Menu spans a full ring, so its half-sector angle is 90° for
    /// chord-width purposes rather than π radians (whose sine is zero).
    static func menuTitleWidth(for menuLayout: RadialMenuLayout) -> CGFloat {
        let halfSectorAngle = min(
            .pi / CGFloat(menuLayout.itemCount),
            .pi / 2
        )
        return max(
            36,
            2 * menuLayout.itemCenterRadius * sin(halfSectorAngle) - 8
        )
    }

    private func titleLayout(
        for title: String,
        maxWidth: CGFloat,
        baseSize: CGFloat
    ) -> MenuTitleLayout {
        // Width changes by fractions of a point while the size Slider moves.
        // Reusing a conservative four-point bucket avoids remeasuring every
        // title on every sample without allowing text to exceed its sector.
        let widthBucket = max(1, Int(maxWidth / 4) * 4)
        let key = MenuTitleLayoutCacheKey(
            title: title,
            widthBucket: widthBucket,
            baseSize: Int(baseSize.rounded()),
            font: appearanceConfiguration.menuFont,
            weight: appearanceConfiguration.menuFontWeight
        )
        if let cached = menuTitleLayoutCache[key] {
            return cached
        }

        let fontKey = MenuFontCacheKey(
            font: appearanceConfiguration.menuFont,
            weight: appearanceConfiguration.menuFontWeight,
            baseSize: Int(baseSize.rounded())
        )
        let baseFont = menuFontCache[fontKey] ?? {
            let font = appearanceConfiguration.menuFont.makeFont(
                ofSize: baseSize,
                weight: appearanceConfiguration.menuFontWeight
            )
            menuFontCache[fontKey] = font
            return font
        }()
        let layout = MenuTitleLayoutEngine.layout(
            title: title,
            maxWidth: CGFloat(widthBucket),
            baseFont: baseFont
        )
        menuTitleLayoutCache[key] = layout
        return layout
    }

    private func drawPreviewBackground() {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: min(28, rect.width / 2),
            yRadius: min(28, rect.height / 2)
        )
        previewBackgroundColor.setFill()
        path.fill()
        previewBorderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private var previewBackgroundColor: NSColor {
        switch MenuAppearanceConfiguration.Theme(rawValue: appearanceConfiguration.theme) ?? .system {
        case .system:
            return NSColor.controlBackgroundColor
        case .light:
            return NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.99, alpha: 1)
        case .dark:
            return NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.17, alpha: 1)
        }
    }

    private var previewBorderColor: NSColor {
        switch MenuAppearanceConfiguration.Theme(rawValue: appearanceConfiguration.theme) ?? .system {
        case .system:
            return NSColor.separatorColor
        case .light:
            return NSColor(calibratedRed: 0.55, green: 0.61, blue: 0.72, alpha: 0.7)
        case .dark:
            return NSColor(calibratedRed: 0.64, green: 0.70, blue: 0.82, alpha: 0.48)
        }
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
        editorMouseDownIsEdit = false
        editorDragStarted = false
    }
}
