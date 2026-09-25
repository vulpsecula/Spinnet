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
        let editButtonRect: NSRect
    }

    static let libraryPresetPasteboardType = NSPasteboard.PasteboardType(
        "com.spinnet.library-preset"
    )
    static let slotPasteboardType = NSPasteboard.PasteboardType(
        "com.spinnet.menu-slot"
    )
    private static let textPasteboardType = NSPasteboard.PasteboardType.string

    private var layout: RadialMenuLayout
    private var slots: [MenuSlotPresentation]
    private var menuFontCache: [MenuFontCacheKey: NSFont] = [:]
    private var menuTitleLayoutCache: [MenuTitleLayoutCacheKey: MenuTitleLayout] = [:]
    private var cachedSlotPaths: [Int: NSBezierPath] = [:]
    private var cachedPathLayout: RadialMenuLayout?
    private var cachedPathCanvas: NSRect?
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
            if oldValue != selectedIndex {
                invalidateSlot(at: oldValue)
                invalidateSlot(at: selectedIndex)
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
    /// Fills an Empty Slot with a Library Preset dropped on it.
    var onPresetDrop: ((String, Int) -> Bool)?
    /// Adds a new Slot at the index for a Library Preset dropped on an
    /// occupied Slot.
    var onPresetInsert: ((String, Int) -> Bool)?
    var onSlotDrop: (([UUID], UUID) -> Bool)?
    /// Where a Library Preset being dragged over an occupied Slot would add
    /// its new Slot: on the side of that Slot the pointer is on.
    private(set) var libraryInsertionIndex: Int? {
        didSet { if libraryInsertionIndex != oldValue { needsDisplay = true } }
    }
    private(set) var editorSlots: [EditorMenuSlot] = []
    private var dragOriginalSlots: [EditorMenuSlot]?
    private var draggedSlotID: UUID?
    private var dragDirection: CircularSlotReorder.Direction?
    private var previousDragAngle: CGFloat?
    private var slotMotionOrigins: [UUID: CGFloat] = [:]
    private var slotMotionStarted: TimeInterval = 0
    private var slotMotionProgress: CGFloat = 0
    private var slotMotionTimer: Timer?
    private let slotMotionDuration: TimeInterval = 0.18

    var slotDragPlaceholderIndex: Int? {
        guard let draggedSlotID else { return nil }
        return editorSlots.firstIndex { $0.id == draggedSlotID }
    }

    /// Fractional positions animate complete Slots along the ring, not their labels separately.
    func displayedSlotPosition(at index: Int) -> CGFloat {
        guard editorSlots.indices.contains(index),
              let origin = slotMotionOrigins[editorSlots[index].id] else { return CGFloat(index) }
        let eased = 1 - pow(1 - slotMotionProgress, 3)
        return origin + (CGFloat(index) - origin) * eased
    }

    private func animateSlotDisplacement(from positions: [UUID: CGFloat]) {
        stopSlotMotion()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let count = CGFloat(editorSlots.count)
        slotMotionOrigins = Dictionary(uniqueKeysWithValues: editorSlots.indices.map { index in
            let id = editorSlots[index].id
            var origin = positions[id] ?? CGFloat(index)
            while origin - CGFloat(index) > count / 2 { origin -= count }
            while origin - CGFloat(index) < -count / 2 { origin += count }
            return (id, origin)
        })
        slotMotionStarted = ProcessInfo.processInfo.systemUptime
        slotMotionProgress = 0
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.slotMotionProgress = min(1, max(0,
                (ProcessInfo.processInfo.systemUptime - self.slotMotionStarted) / self.slotMotionDuration))
            if self.slotMotionProgress >= 1 { self.stopSlotMotion() }
            self.invalidateSlotPaths()
            self.layoutEditButtons()
            self.needsDisplay = true
        }
        slotMotionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func stopSlotMotion() {
        slotMotionTimer?.invalidate()
        slotMotionTimer = nil
        slotMotionOrigins.removeAll(keepingCapacity: true)
        invalidateSlotPaths()
    }

    func updateEditorSlots(_ slots: [EditorMenuSlot], appearance: MenuAppearanceConfiguration) {
        if let original = dragOriginalSlots {
            if slots == original, appearance == appearanceConfiguration { return }
            cancelSlotMovePreview()
        }
        editorSlots = slots
        update(slots: slots.map(\.presentation), appearance: appearance)
        // The initial configuration can compare equal before the view has
        // applied its fitted geometry or effective appearance.
        if self.appearance == nil { applyAppearance(appearance) }
    }

    /// Transient ordering is view state; only the drop commits to the model.
    @discardableResult
    func previewSlotMove(id: UUID, to target: Int) -> Bool {
        guard presentationMode == .editor, allowsEditing,
              editorSlots.indices.contains(target),
              editorSlots.contains(where: { $0.id == id }) else { return false }
        if dragOriginalSlots == nil { dragOriginalSlots = editorSlots }
        draggedSlotID = id
        guard let original = dragOriginalSlots,
              let source = original.firstIndex(where: { $0.id == id }) else { return false }
        let plan = CircularSlotReorder(count: original.count, source: source, target: target,
                                       preferredDirection: dragDirection ?? .clockwise)
        if source != target { dragDirection = plan.direction }
        let reordered = plan.order.map { original[$0] }
        guard editorSlots != reordered else {
            layoutEditButtons()
            needsDisplay = true
            return true
        }
        let positions = Dictionary(uniqueKeysWithValues: editorSlots.indices.map {
            (editorSlots[$0].id, displayedSlotPosition(at: $0))
        })
        editorSlots = reordered
        slots = editorSlots.map(\.presentation)
        selectedIndex = target
        animateSlotDisplacement(from: positions)
        invalidateSlotPaths()
        rebuildEditButtons()
        needsDisplay = true
        return true
    }

    func cancelSlotMovePreview() {
        guard let original = dragOriginalSlots else { return }
        stopSlotMotion()
        editorSlots = original
        slots = original.map(\.presentation)
        selectedIndex = original.firstIndex(where: { $0.id == draggedSlotID })
        dragOriginalSlots = nil
        draggedSlotID = nil
        dragDirection = nil
        previousDragAngle = nil
        invalidateSlotPaths()
        rebuildEditButtons()
        needsDisplay = true
    }
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
        // The Menu is drawn with the layout fitted to its canvas, so the Edit
        // controls have to start from that same layout rather than the
        // unfitted one the stored property needs before initialisation.
        self.layout = previewLayout(for: appearanceConfiguration)
        updateFrameSize(for: self.layout)
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
                    Self.slotPasteboardType
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
            invalidateSlotPaths()
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
            invalidateSlotPaths()
            clearSelection()
        }
        if appearanceChanged {
            if renderingAppearanceChanged {
                invalidateSlotPaths()
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
        invalidateSlotPaths()
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
            invalidateSlotPaths()
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

    private func invalidateSlotPaths() {
        cachedSlotPaths.removeAll(keepingCapacity: true)
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
              dragOriginalSlots == nil,
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
        guard pasteboard.data(forType: Self.slotPasteboardType) == nil else { return nil }
        return pasteboard.string(forType: Self.libraryPresetPasteboardType)
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
        if let sender, bounds.contains(convert(sender.draggingLocation, from: nil)) { return }
        libraryInsertionIndex = nil
        cancelSlotMovePreview()
        updateHover(at: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard presentationMode == .editor,
              allowsEditing,
              let index = updateDropTarget(sender) else {
            return false
        }
        if let pluginID = Self.libraryPresetID(from: sender.draggingPasteboard) {
            let insertion = libraryInsertionIndex
            libraryInsertionIndex = nil
            if let insertion { return onPresetInsert?(pluginID, insertion) ?? false }
            selectEditorItem(at: index)
            onEditorSelection?(index)
            return onPresetDrop?(pluginID, index) ?? false
        }
        selectEditorItem(at: index)
        onEditorSelection?(index)
        if sender.draggingSource as? RadialMenuView === self,
           let source = sender.draggingPasteboard.string(
            forType: Self.slotPasteboardType
        ).flatMap(UUID.init(uuidString:)) {
            _ = previewSlotMove(id: source, to: index)
            let finalIDs = editorSlots.map(\.id)
            cancelSlotMovePreview()
            return onSlotDrop?(finalIDs, source) ?? false
        }
        return false
    }

    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let target = updateDropTarget(sender) else {
            libraryInsertionIndex = nil
            return []
        }
        if Self.libraryPresetID(from: sender.draggingPasteboard) != nil {
            if slots[target].isEmpty {
                libraryInsertionIndex = nil
            } else {
                libraryInsertionIndex = insertionIndex(beside: target, at: convert(sender.draggingLocation, from: nil))
                updateHover(at: nil)
            }
            return .copy
        }
        if sender.draggingSource as? RadialMenuView === self,
           let id = sender.draggingPasteboard.string(
            forType: Self.slotPasteboardType
        ).flatMap(UUID.init(uuidString:)),
           let source = editorSlots.firstIndex(where: { $0.id == id }),
           editorSlots.indices.contains(source) {
            _ = previewSlotMove(id: id, to: target)
            return .move
        }
        return []
    }

    private func beginEditorDrag(with event: NSEvent) {
        guard !editorMouseDownIsEdit,
              !editorDragStarted,
              let sourceIndex = editorMouseDownIndex,
              slots.indices.contains(sourceIndex),
              editorSlots.indices.contains(sourceIndex) else { return }
        editorDragStarted = true
        dragOriginalSlots = editorSlots
        draggedSlotID = editorSlots[sourceIndex].id
        let point = convert(event.locationInWindow, from: nil)
        previousDragAngle = atan2(bounds.midY - point.y, point.x - bounds.midX)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(
            editorSlots[sourceIndex].id.uuidString,
            forType: Self.slotPasteboardType
        )
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let slotRect = slotPath(at: sourceIndex, using: layout, in: bounds).bounds
            .union(menuTitleRect(at: sourceIndex)).insetBy(dx: -4, dy: -4)
        let image = NSImage(size: slotRect.size)
        image.lockFocusFlipped(false)
        let transform = AffineTransform(translationByX: -slotRect.minX, byY: -slotRect.minY)
        (transform as NSAffineTransform).concat()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawSlot(at: sourceIndex, using: layout, in: bounds)
        }
        image.unlockFocus()
        draggingItem.setDraggingFrame(slotRect, contents: image)
        layoutEditButtons()
        needsDisplay = true
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func updateDropTarget(_ sender: NSDraggingInfo) -> Int? {
        let point = convert(sender.draggingLocation, from: nil)
        let isSlotDrag = sender.draggingSource as? RadialMenuView === self
            && sender.draggingPasteboard.data(forType: Self.slotPasteboardType) != nil
        if isSlotDrag {
            let angle = atan2(bounds.midY - point.y, point.x - bounds.midX)
            if let previousDragAngle, dragDirection == nil {
                let delta = atan2(sin(angle - previousDragAngle), cos(angle - previousDragAngle))
                if abs(delta) > 0.02 { dragDirection = delta > 0 ? .clockwise : .counterclockwise }
            }
            previousDragAngle = angle
        }
        guard let index = slotIndex(at: point) else {
            updateHover(at: nil)
            return nil
        }
        if isSlotDrag, let current = slotDragPlaceholderIndex, index != current {
            let step = 2 * CGFloat.pi / CGFloat(slots.count)
            let angle = CGFloat.pi / 2 - atan2(point.y - bounds.midY, point.x - bounds.midX)
            let centerAngle = CGFloat(current) * step
            let distance = abs(atan2(sin(angle - centerAngle), cos(angle - centerAngle)))
            // Require entering 12% of the next sector before moving the vacancy.
            if distance < step * 0.62 { return current }
        }
        updateHover(at: point)
        return index
    }

    /// The index a new Slot takes beside `target`: before it when the pointer
    /// is on its counter-clockwise half, after it otherwise.
    private func insertionIndex(beside target: Int, at point: CGPoint) -> Int {
        let step = 2 * CGFloat.pi / CGFloat(slots.count)
        let angle = CGFloat.pi / 2 - atan2(point.y - bounds.midY, point.x - bounds.midX)
        let centre = CGFloat(target) * step
        return atan2(sin(angle - centre), cos(angle - centre)) >= 0 ? target + 1 : target
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
            title: "Delete Slot",
            action: #selector(deleteContextMenuSlot(_:)),
            keyEquivalent: ""
        )
        slotAction.target = self
        slotAction.isEnabled = slots.count > 1
        slotAction.toolTip = slotAction.isEnabled
            ? "Delete this Slot after confirmation"
            : "A Menu must contain at least one Slot"
        menu.addItem(slotAction)
        return menu
    }

    private func rebuildEditButtons() {
        guard presentationMode == .editor, allowsEditing else { return }
        for index in Array(editButtons.keys) where !slots.indices.contains(index) {
            editButtons.removeValue(forKey: index)?.removeFromSuperview()
        }

        for index in slots.indices where editButtons[index] == nil {
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
                Self.slotPasteboardType
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
                guard let self, let window = self.window,
                      !self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
                self.cancelSlotMovePreview()
                self.updateHover(at: nil)
            }
            addSubview(button)
            editButtons[index] = button
        }
        layoutEditButtons()
    }

    /// The Edit controls are placed from the canvas, so a canvas that arrives
    /// after them leaves every control off its Slot. SwiftUI updates a hosted
    /// view before it sizes it, which is exactly that order.
    override func setFrameSize(_ newSize: NSSize) {
        let canvasChanged = newSize != frame.size
        super.setFrameSize(newSize)
        if canvasChanged { layoutEditButtons() }
    }

    private func layoutEditButtons() {
        // An empty canvas has no Slots to place anything in, and the frames it
        // would produce are kept until something lays the controls out again.
        guard presentationMode == .editor, allowsEditing, !bounds.isEmpty else { return }
        // A canvas change can arrive between losing a Slot and rebuilding the
        // controls, so only the Slots that are still there are placed here.
        for (index, button) in editButtons where slots.indices.contains(index) {
            button.isHidden = slots[index].item == nil || slotDragPlaceholderIndex == index
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
        return titleDrawingMetrics(at: index, using: layout, in: bounds).editButtonRect
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

    private func slotDrawingBounds(at index: Int) -> NSRect {
        var rect = slotPath(at: index, using: layout, in: bounds).bounds
            .union(menuTitleRect(at: index))
        let button = editorEditButtonRect(at: index)
        if !button.isEmpty { rect = rect.union(button) }
        // Room for the Slot rising out of the disc and its shadow.
        let margin = raise(for: layout) + 20 * layout.outerRadius / 142
        return rect.insetBy(dx: -margin, dy: -margin)
    }

    private func invalidateSlot(at index: Int?) {
        guard let index, slots.indices.contains(index) else { return }
        setNeedsDisplay(slotDrawingBounds(at: index))
    }

    private func updateHover(at point: CGPoint?) {
        let nextIndex = point.flatMap(slotIndex(at:))
        guard hoveredIndex != nextIndex else { return }
        let previous = hoveredIndex
        hoveredIndex = nextIndex
        invalidateSlot(at: previous)
        invalidateSlot(at: nextIndex)
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
        NSBezierPath(rect: dirtyRect.intersection(bounds)).addClip()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }

        NSColor.clear.setFill()
        dirtyRect.fill()
        if showsPreviewBackground {
            drawPreviewBackground()
        }
        drawMenuContents(using: layout, in: bounds, dirtyRect: dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateSlotPaths()
        needsDisplay = true
    }

    /// The colours of the Menu's frosted disc, taken from the Menu's own
    /// theme rather than the system's, so a Light Menu stays light in a Dark
    /// session.
    private struct MenuPalette {
        let disc: NSColor
        let discEdge: NSColor
        let discShadow: NSColor
        let separator: NSColor
        let raised: NSColor
        let raisedShadow: NSColor
        let hover: NSColor
        let empty: NSColor
        let hubTop: NSColor
        let hubBottom: NSColor
        let hubEdge: NSColor
        let label: NSColor
        let secondaryLabel: NSColor

        func withDisc(_ disc: NSColor) -> MenuPalette {
            MenuPalette(disc: disc, discEdge: discEdge, discShadow: discShadow, separator: separator,
                        raised: raised, raisedShadow: raisedShadow, hover: hover, empty: empty,
                        hubTop: hubTop, hubBottom: hubBottom, hubEdge: hubEdge,
                        label: label, secondaryLabel: secondaryLabel)
        }

        static let light = MenuPalette(
            disc: NSColor(white: 0.985, alpha: 0.86),
            discEdge: NSColor(white: 1, alpha: 0.9),
            discShadow: NSColor(white: 0, alpha: 0.18),
            separator: NSColor(white: 0, alpha: 0.07),
            raised: NSColor(white: 1, alpha: 0.98),
            raisedShadow: NSColor(white: 0, alpha: 0.16),
            hover: NSColor(white: 1, alpha: 0.55),
            empty: NSColor(white: 0, alpha: 0.03),
            hubTop: NSColor(white: 1, alpha: 1),
            hubBottom: NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.92, alpha: 1),
            hubEdge: NSColor(white: 1, alpha: 0.95),
            label: NSColor(white: 0.12, alpha: 1),
            secondaryLabel: NSColor(white: 0.12, alpha: 0.45)
        )

        static let dark = MenuPalette(
            disc: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 0.9),
            discEdge: NSColor(white: 1, alpha: 0.12),
            discShadow: NSColor(white: 0, alpha: 0.45),
            separator: NSColor(white: 1, alpha: 0.08),
            raised: NSColor(calibratedRed: 0.27, green: 0.28, blue: 0.31, alpha: 0.98),
            raisedShadow: NSColor(white: 0, alpha: 0.4),
            hover: NSColor(white: 1, alpha: 0.07),
            empty: NSColor(white: 1, alpha: 0.03),
            hubTop: NSColor(calibratedRed: 0.24, green: 0.25, blue: 0.28, alpha: 1),
            hubBottom: NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.2, alpha: 1),
            hubEdge: NSColor(white: 1, alpha: 0.14),
            label: NSColor(white: 0.96, alpha: 1),
            secondaryLabel: NSColor(white: 0.96, alpha: 0.45)
        )
    }

    private var palette: MenuPalette {
        let palette: MenuPalette = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        guard drawsOverGlass else { return palette }
        // Over the frosted glass the disc only tints it, so the blur shows.
        return palette.withDisc(palette.disc.withAlphaComponent(palette.disc.alphaComponent * 0.6))
    }

    /// Set when frosted glass sits behind the disc, as in the Runtime Mode
    /// overlay.
    var drawsOverGlass = false {
        didSet { needsDisplay = true }
    }

    /// The disc, in this view's coordinates.
    var discRect: NSRect {
        NSRect(x: bounds.midX - layout.outerRadius, y: bounds.midY - layout.outerRadius,
               width: layout.outerRadius * 2, height: layout.outerRadius * 2)
    }

    /// How far the focused Slot rises out of the disc, and the room its
    /// shadow needs around the Menu.
    private func raise(for menuLayout: RadialMenuLayout) -> CGFloat {
        8 * menuLayout.outerRadius / 142
    }

    private func drawMenuContents(
        using menuLayout: RadialMenuLayout,
        in canvas: NSRect,
        dirtyRect: NSRect
    ) {
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let palette = self.palette
        let scale = menuLayout.outerRadius / 142

        // The frosted disc, one piece, with a soft shadow beneath it.
        let disc = NSBezierPath(ovalIn: NSRect(
            x: center.x - menuLayout.outerRadius, y: center.y - menuLayout.outerRadius,
            width: menuLayout.outerRadius * 2, height: menuLayout.outerRadius * 2
        ))
        NSGraphicsContext.saveGraphicsState()
        let discShadow = NSShadow()
        discShadow.shadowColor = palette.discShadow
        discShadow.shadowBlurRadius = 18 * scale
        discShadow.shadowOffset = NSSize(width: 0, height: -5 * scale)
        discShadow.set()
        palette.disc.setFill()
        disc.fill()
        NSGraphicsContext.restoreGraphicsState()
        palette.discEdge.setStroke()
        disc.lineWidth = 1
        disc.stroke()

        let raised = slots.indices.filter { isRaised($0) && slotDragPlaceholderIndex != $0 }
        for index in slots.indices where !raised.contains(index) && slotDrawingBounds(at: index).intersects(dirtyRect) {
            if slotDragPlaceholderIndex == index {
                // This is an insertion gap, not an Empty Slot or a copy of the lifted Slot.
                let path = slotPath(at: index, using: menuLayout, in: canvas)
                editorAccentColor.withAlphaComponent(0.08).setFill()
                path.fill()
                editorAccentColor.withAlphaComponent(0.55).setStroke()
                path.lineWidth = 1
                path.setLineDash([3, 5], count: 2, phase: 0)
                path.stroke()
                continue
            }
            drawSlotBackground(at: index, using: menuLayout, in: canvas)
        }
        drawSeparators(using: menuLayout, in: canvas, skipping: Set(raised))
        for index in raised {
            drawRaisedSlot(at: index, using: menuLayout, in: canvas)
        }
        if let insertion = libraryInsertionIndex {
            drawInsertionMark(before: insertion, using: menuLayout, in: canvas)
        }
        for index in slots.indices where slotDragPlaceholderIndex != index
            && slotDrawingBounds(at: index).intersects(dirtyRect) {
            drawSlotLabel(at: index, using: menuLayout, in: canvas)
        }

        drawHub(using: menuLayout, in: canvas)
        drawHubLabel(in: canvas)
    }

    /// The focused Slot rises out of the disc: the Slot under the pointer in
    /// Runtime Mode, the focused one in Editor Mode.
    private func isRaised(_ index: Int) -> Bool {
        selectedIndex == index
    }

    private func drawSlotBackground(at index: Int, using menuLayout: RadialMenuLayout, in canvas: NSRect) {
        let slot = slots[index]
        let isHovered = presentationMode == .editor && hoveredIndex == index
        let path = slotPath(at: index, using: menuLayout, in: canvas)
        if isHovered {
            palette.hover.setFill()
            path.fill()
        } else if slot.isEmpty {
            palette.empty.setFill()
            path.fill()
        }
        if slot.isEmpty, presentationMode == .editor {
            let inset = wedgePath(
                at: slotDragPlaceholderIndex == index ? CGFloat(index) : displayedSlotPosition(at: index),
                from: menuLayout.innerRadius + 6, to: menuLayout.outerRadius - 6,
                itemCount: menuLayout.itemCount, in: canvas
            )
            (isHovered ? editorAccentColor.withAlphaComponent(0.6) : palette.secondaryLabel.withAlphaComponent(0.35))
                .setStroke()
            inset.lineWidth = 1
            inset.setLineDash([5, 4], count: 2, phase: 0)
            inset.stroke()
        }
    }

    /// Hairlines between neighbouring Slots, from the hub's edge to the rim.
    /// The lines on either side of a raised Slot are covered by it.
    private func drawSeparators(using menuLayout: RadialMenuLayout, in canvas: NSRect, skipping raised: Set<Int>) {
        guard menuLayout.itemCount > 1 else { return }
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let step = 2 * CGFloat.pi / CGFloat(menuLayout.itemCount)
        let path = NSBezierPath()
        for index in slots.indices {
            let position = slotDragPlaceholderIndex == index ? CGFloat(index) : displayedSlotPosition(at: index)
            let angle = CGFloat.pi / 2 - (position - 0.5) * step
            path.move(to: CGPoint(x: center.x + cos(angle) * menuLayout.innerRadius,
                                  y: center.y + sin(angle) * menuLayout.innerRadius))
            path.line(to: CGPoint(x: center.x + cos(angle) * menuLayout.outerRadius,
                                  y: center.y + sin(angle) * menuLayout.outerRadius))
        }
        palette.separator.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawRaisedSlot(at index: Int, using menuLayout: RadialMenuLayout, in canvas: NSRect) {
        let slot = slots[index]
        let path = raisedSlotPath(at: index, using: menuLayout, in: canvas)
        let scale = menuLayout.outerRadius / 142
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = palette.raisedShadow
        shadow.shadowBlurRadius = 14 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -3 * scale)
        shadow.set()
        // One layer, so the rounding stroke and the fill cast a single shadow.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let fill = slot.item?.primaryAction.isAvailable == false
            ? palette.raised.withAlphaComponent(0.8)
            : palette.raised
        fill.setFill()
        fill.setStroke()
        path.fill()
        path.lineWidth = 8 * scale
        path.lineJoinStyle = .round
        path.stroke()
        context.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()

        if presentationMode == .editor {
            let outline = raisedSlotPath(at: index, using: menuLayout, in: canvas)
            editorAccentColor.withAlphaComponent(slot.isEmpty ? 0.9 : 0.75).setStroke()
            outline.lineWidth = 1.5
            outline.lineJoinStyle = .round
            if slot.isEmpty { outline.setLineDash([5, 4], count: 2, phase: 0) }
            outline.stroke()
        }
    }

    /// The raised Slot: slightly narrower than its wedge, so the rounding
    /// stroke keeps it inside its neighbours, and reaching past the rim.
    private func raisedSlotPath(at index: Int, using menuLayout: RadialMenuLayout, in canvas: NSRect) -> NSBezierPath {
        let scale = menuLayout.outerRadius / 142
        let position = displayedSlotPosition(at: index)
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let step = 360 / CGFloat(menuLayout.itemCount)
        let inner = menuLayout.innerRadius + 4 * scale
        let outer = menuLayout.outerRadius + raise(for: menuLayout) - 4 * scale
        // Four points of rounding stroke on each side, in degrees at each radius.
        let innerInset = min(4 * scale / inner * 180 / .pi, step / 4)
        let outerInset = min(4 * scale / outer * 180 / .pi, step / 4)
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: outer,
                       startAngle: 90 - (position + 0.5) * step + outerInset,
                       endAngle: 90 - (position - 0.5) * step - outerInset)
        path.appendArc(withCenter: center, radius: inner,
                       startAngle: 90 - (position - 0.5) * step - innerInset,
                       endAngle: 90 - (position + 0.5) * step + innerInset,
                       clockwise: true)
        path.close()
        return path
    }

    /// Where a dropped Library Preset would add its Slot: an accent line on
    /// the boundary, with a plus at the rim.
    private func drawInsertionMark(before insertion: Int, using menuLayout: RadialMenuLayout, in canvas: NSRect) {
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let scale = menuLayout.outerRadius / 142
        let angle = CGFloat.pi / 2 - (CGFloat(insertion) - 0.5) * 2 * .pi / CGFloat(menuLayout.itemCount)
        func at(_ radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        let knobRadius = 9 * scale
        let knobCentre = at(menuLayout.outerRadius + raise(for: menuLayout))
        let line = NSBezierPath()
        line.move(to: at(menuLayout.innerRadius))
        line.line(to: at(menuLayout.outerRadius + raise(for: menuLayout) - knobRadius))
        line.lineWidth = 3 * scale
        line.lineCapStyle = .round
        editorAccentColor.setStroke()
        line.stroke()
        let knob = NSBezierPath(ovalIn: NSRect(x: knobCentre.x - knobRadius, y: knobCentre.y - knobRadius,
                                               width: knobRadius * 2, height: knobRadius * 2))
        editorAccentColor.setFill()
        knob.fill()
        let plus = NSBezierPath()
        let arm = knobRadius * 0.5
        plus.move(to: CGPoint(x: knobCentre.x - arm, y: knobCentre.y))
        plus.line(to: CGPoint(x: knobCentre.x + arm, y: knobCentre.y))
        plus.move(to: CGPoint(x: knobCentre.x, y: knobCentre.y - arm))
        plus.line(to: CGPoint(x: knobCentre.x, y: knobCentre.y + arm))
        plus.lineWidth = 2 * scale
        plus.lineCapStyle = .round
        NSColor.white.setStroke()
        plus.stroke()
    }

    /// One Slot on its own, raised, as the image a drag lifts.
    private func drawSlot(at index: Int, using menuLayout: RadialMenuLayout, in canvas: NSRect) {
        drawRaisedSlot(at: index, using: menuLayout, in: canvas)
        drawSlotLabel(at: index, using: menuLayout, in: canvas)
    }

    private func drawHub(using menuLayout: RadialMenuLayout, in canvas: NSRect) {
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let scale = menuLayout.outerRadius / 142
        let radius = max(menuLayout.innerRadius - 5 * scale, 4)
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
        let palette = self.palette
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = palette.raisedShadow
        shadow.shadowBlurRadius = 10 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -2 * scale)
        shadow.set()
        palette.hubBottom.setFill()
        hub.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: palette.hubTop, ending: palette.hubBottom)?.draw(in: hub, angle: -90)
        palette.hubEdge.setStroke()
        hub.lineWidth = 1
        hub.stroke()
    }

    private func slotPath(at index: Int, using menuLayout: RadialMenuLayout, in canvas: NSRect) -> NSBezierPath {
        if cachedPathLayout != menuLayout || cachedPathCanvas != canvas {
            cachedSlotPaths.removeAll(keepingCapacity: true)
            cachedPathLayout = menuLayout
            cachedPathCanvas = canvas
        }
        if let path = cachedSlotPaths[index] { return path }
        let position = slotDragPlaceholderIndex == index ? CGFloat(index) : displayedSlotPosition(at: index)
        let path = wedgePath(at: position, from: menuLayout.innerRadius, to: menuLayout.outerRadius,
                             itemCount: menuLayout.itemCount, in: canvas)
        cachedSlotPaths[index] = path
        return path
    }

    /// The wedge centred on a Slot position, which is fractional while Slots
    /// move. Position 0 is centred on 12 o'clock.
    private func wedgePath(at position: CGFloat, from innerRadius: CGFloat, to outerRadius: CGFloat,
                           itemCount: Int, in canvas: NSRect) -> NSBezierPath {
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let step = 360 / CGFloat(itemCount)
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: outerRadius,
            startAngle: 90 - (position + 0.5) * step,
            endAngle: 90 - (position - 0.5) * step
        )
        path.appendArc(
            withCenter: center,
            radius: innerRadius,
            startAngle: 90 - (position - 0.5) * step,
            endAngle: 90 - (position + 0.5) * step,
            clockwise: true
        )
        path.close()
        return path
    }

    private func drawSlotLabel(at index: Int, using menuLayout: RadialMenuLayout, in canvas: NSRect) {
        let slot = slots[index]
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
            .foregroundColor: slot.isEmpty || slot.item?.primaryAction.isAvailable == false
                ? palette.secondaryLabel
                : palette.label
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

    private func drawHubLabel(in canvas: NSRect) {
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let centerLabel = presentationMode == .editor ? "MENU" as NSString : "Spinnet" as NSString
        let centerAttributes: [NSAttributedString.Key: Any] = [
            .font: appearanceConfiguration.titleFont(ofSize: 10, weight: .semibold),
            .foregroundColor: palette.secondaryLabel
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
        let position = slotDragPlaceholderIndex == index ? CGFloat(index) : displayedSlotPosition(at: index)
        let angle = CGFloat.pi / 2 - position * 2 * .pi / CGFloat(menuLayout.itemCount)
        let point = CGPoint(x: center.x + cos(angle) * menuLayout.itemCenterRadius,
                            y: center.y + sin(angle) * menuLayout.itemCenterRadius)
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
        let baseTitleRect = NSRect(
            x: point.x - titleWidth / 2,
            y: point.y - titleHeight / 2 + verticalOffset,
            width: titleWidth,
            height: titleHeight
        )
        var titleRect = baseTitleRect
        var editButtonRect = NSRect.zero
        if presentationMode == .editor, allowsEditing, slots[index].item != nil {
            let radialX = point.x - center.x
            let radialY = point.y - center.y
            let radialDistance = max(hypot(radialX, radialY), 1)
            let buttonHeight: CGFloat = 20
            let gap: CGFloat = 8
            let buttonWidth = min(48, max(38, titleWidth))
            let path = slotPath(at: index, using: menuLayout, in: canvas)
            var bestOutsideCount = Int.max
            // Lay out title and control as one block within this Slot.
            // Prefer the outer band and test both boxes against its wedge.
            for fraction: CGFloat in [0.74, 0.76, 0.72, 0.78, 0.70, 0.80, 0.68, 0.82] {
                let radius = menuLayout.outerRadius * fraction
                let anchor = CGPoint(
                    x: center.x + radialX / radialDistance * radius,
                    y: center.y + radialY / radialDistance * radius
                )
                let candidateTitle = NSRect(
                    x: anchor.x - titleWidth / 2,
                    y: anchor.y + (buttonHeight + gap - titleHeight) / 2,
                    width: titleWidth, height: titleHeight
                )
                let candidateButton = NSRect(
                    x: anchor.x - buttonWidth / 2,
                    y: candidateTitle.minY - gap - buttonHeight,
                    width: buttonWidth, height: buttonHeight
                )
                let outside = [candidateTitle, candidateButton].flatMap { rect in
                    [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY),
                     CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)]
                }.filter { !path.contains($0) }.count
                if outside < bestOutsideCount {
                    bestOutsideCount = outside
                    titleRect = candidateTitle
                    editButtonRect = candidateButton
                }
                if outside == 0 { break }
            }
        }
        return MenuTitleDrawingMetrics(
            point: point,
            layout: layout,
            rect: titleRect,
            editButtonRect: editButtonRect
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
        cancelSlotMovePreview()
        editorMouseDownIndex = nil
        editorMouseDownIsEdit = false
        editorDragStarted = false
    }
}
