import AppKit
import Carbon
import SpinnetCore
import SwiftUI
import XCTest
@testable import SpinnetHost

/// The radial Menu as the Menu Editor presents it: selecting a Slot without
/// running its Action, drag previews that displace Slots before anything is
/// committed, the edit affordances on a Slot, and how a Slot titles itself.
final class EditorModeMenuTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testEditorMenuSurfaceIsVisiblyDistinctFromSettingsBackground() throws {
        let controller = try makeController()
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Settings window has no content view")
        }

        controller.window?.appearance = NSAppearance(named: .aqua)
        contentView.layoutSubtreeIfNeeded()
        let image = try render(contentView)

        // Both probes are placed from the Menu's own frame. Fixed coordinates
        // drift as the page is laid out again, and they did: the pair this test
        // used to carry had ended up on two shades of the same page background.
        //
        // colorAt also takes pixels while the frame is in view coordinates, so
        // a Retina backing needs the scale applied or every probe lands at half
        // the intended point.
        let menu = try XCTUnwrap(findRadialMenu(in: contentView), "No Editor Mode Menu in the window")
        let menuFrame = menu.convert(menu.bounds, to: contentView)
        let scale = CGFloat(image.pixelsWide) / contentView.bounds.width
        func sample(x: CGFloat, y: CGFloat) throws -> NSColor {
            try XCTUnwrap(image.colorAt(x: Int(x * scale), y: Int(y * scale)),
                          "No pixel at view point (\(x), \(y))")
        }

        // Just inside the Menu's disc, clear of the ring of Slots at its centre.
        let menuSurface = try sample(x: menuFrame.midX + menuFrame.width * 0.45, y: menuFrame.midY)
        // Well clear of the Menu, on the Settings page itself.
        let background = try sample(x: menuFrame.minX / 2, y: menuFrame.midY)

        XCTAssertGreaterThan(
            colorDistance(background, menuSurface),
            0.12,
            "The Editor Mode Menu should remain clearly visible against the Settings background"
        )
    }

    func testVirtualMenuPreviewUsesThemeSpecificBackgroundAndLargerScale() throws {
        let view = RadialMenuView(
            items: [],
            mode: .editor,
            allowsEditing: false,
            previewScale: 1.16,
            showsPreviewBackground: true
        )
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        let lightAppearance = MenuAppearanceConfiguration(theme: "Light", menuSize: "100")
        let darkAppearance = MenuAppearanceConfiguration(theme: "Dark", menuSize: "100")
        view.applyAppearance(lightAppearance)
        let light = try render(view).colorAt(
            x: Int(view.bounds.midX),
            y: 2
        )
        view.applyAppearance(darkAppearance)
        let dark = try render(view).colorAt(
            x: Int(view.bounds.midX),
            y: 2
        )

        XCTAssertGreaterThan(colorDistance(try XCTUnwrap(light), try XCTUnwrap(dark)), 0.2)

        view.applyAppearance(MenuAppearanceConfiguration(menuSize: "Medium"))
        XCTAssertGreaterThan(view.geometryLayout.outerRadius, 142)

        let largePreview = RadialMenuView(
            slots: [],
            mode: .editor,
            allowsEditing: false,
            previewScale: 1.16,
            previewCanvasDiameter: 376,
            showsPreviewBackground: true
        )
        largePreview.applyAppearance(MenuAppearanceConfiguration(menuSize: "200"))
        let largeOuterRadius = largePreview.geometryLayout.outerRadius
        XCTAssertEqual(largePreview.bounds.width, 376, accuracy: 0.1)
        XCTAssertLessThanOrEqual(largePreview.geometryLayout.contentDiameter, 376)

        largePreview.applyAppearance(MenuAppearanceConfiguration(menuSize: "Medium"))
        XCTAssertLessThan(largePreview.geometryLayout.outerRadius, largeOuterRadius)
    }

    func testAppearanceOnlyMenuUpdateDoesNotReloadEditorModeMenuSlots() throws {
        let actionID = ActionID("appearance-update-action")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: actionID),
            primaryAction: MenuActionPresentation(
                actionID: actionID,
                title: "Open URL",
                availability: .available
            ),
            alternateActions: []
        )
        let slots = [MenuSlotPresentation.occupied(item)]
        let view = RadialMenuView(slots: slots, mode: .editor)
        view.selectEditorItem(at: 0)

        view.update(
            slots: slots,
            appearance: MenuAppearanceConfiguration(menuSize: "Large")
        )

        XCTAssertEqual(
            view.selectedIndex,
            0,
            "Changing Menu Appearance should not reload unchanged Menu Slots"
        )
    }

    func testEditorMenuSelectsSlotsWithoutExecutingActions() throws {
        let actionID = ActionID("editor-action")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: actionID),
            primaryAction: MenuActionPresentation(
                actionID: actionID,
                title: "Open URL",
                availability: .available
            ),
            alternateActions: []
        )
        let view = RadialMenuView(items: [item], mode: .editor)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        var selectedIndex: Int?
        var editedIndex: Int?
        var primaryExecutionCount = 0
        var alternateExecutionCount = 0
        view.onEditorSelection = { selectedIndex = $0 }
        view.onEditorEditRequested = { editedIndex = $0 }
        view.onPrimarySelection = { _ in primaryExecutionCount += 1 }
        view.onAlternateSelection = { _ in alternateExecutionCount += 1 }

        let location = NSPoint(x: view.bounds.midX, y: view.bounds.midY + 90)
        let hover = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        view.mouseMoved(with: hover)
        XCTAssertNil(selectedIndex, "Hovering a Slot must not change the focused Slot")
        XCTAssertNil(view.selectedIndex, "Hovering a Slot must not commit focus")

        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            if type == .leftMouseDown {
                view.mouseDown(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }

        XCTAssertEqual(selectedIndex, 0, "Clicking a Slot should focus it")
        XCTAssertNil(editedIndex, "Clicking the Slot body must not open editing")

        let editButton = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(editButton.title, "Edit")
        XCTAssertEqual(editButton.accessibilityLabel(), "Edit Menu Item in Slot 1")

        let editLocation = NSPoint(
            x: view.editorEditButtonRect(at: 0).midX,
            y: view.editorEditButtonRect(at: 0).midY
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: editLocation,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            if type == .leftMouseDown {
                view.mouseDown(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }

        XCTAssertEqual(editedIndex, 0, "Only the in-slot Edit button should open editing")
        XCTAssertEqual(primaryExecutionCount, 0)
        XCTAssertEqual(alternateExecutionCount, 0)
    }

    func testVirtualMenuPreviewKeepsSelectionWithItsSlotGeometry() throws {
        let view = RadialMenuView(
            slots: Array(repeating: .empty, count: 8),
            mode: .editor,
            allowsEditing: true,
            previewScale: 1.16,
            previewCanvasDiameter: 376,
            showsPreviewBackground: true
        )
        view.applyAppearance(MenuAppearanceConfiguration(theme: "Dark"))
        view.editorAccentColor = .systemRed
        view.selectEditorItem(at: 3)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let image = try render(view)
        let scale = CGFloat(image.pixelsWide) / view.bounds.width
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let radius = view.geometryLayout.outerRadius - 24

        func accentRed(at index: Int, invertY: Bool) throws -> CGFloat {
            let itemCenter = view.geometryLayout.itemCenter(index: index, center: center)
            let distance = hypot(itemCenter.x - center.x, itemCenter.y - center.y)
            let point = CGPoint(
                x: center.x + (itemCenter.x - center.x) * radius / distance,
                y: center.y + (itemCenter.y - center.y) * radius / distance
            )
            let color = try XCTUnwrap(image.colorAt(
                x: Int((point.x * scale).rounded()),
                y: Int(((invertY ? view.bounds.height - point.y : point.y) * scale).rounded())
            )).usingColorSpace(.deviceRGB)
            return try XCTUnwrap(color).redComponent
        }

        XCTAssertGreaterThan(
            try accentRed(at: 3, invertY: true),
            try accentRed(at: 0, invertY: true) + 0.1,
            "The selected Slot's highlight must stay with its label and wedge"
        )
    }

    func testEditorMenuKeepsWrappedTitleAboveItsEditButtonInEverySlot() throws {
        let title = "Copy Selected Text"
        let actionID = ActionID("wrapped-title-layout")
        let configuration = try MenuItemConfiguration(
            primaryActionID: actionID,
            alias: title
        )
        let item = MenuItemPresentation(
            configuration: configuration,
            primaryAction: MenuActionPresentation(
                actionID: actionID,
                title: title,
                availability: .available
            ),
            alternateActions: []
        )
        let slots = Array(repeating: MenuSlotPresentation.occupied(item), count: 9)
        let view = RadialMenuView(slots: slots, mode: .editor)
        let titleRect = view.menuTitleRect(at: 7)

        for index in slots.indices {
            let slotTitleRect = view.menuTitleRect(at: index)
            XCTAssertLessThanOrEqual(
                view.editorEditButtonRect(at: index).maxY,
                slotTitleRect.minY - 4,
                "A wrapped title must not overlap its Edit control"
            )
        }

        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let titleCenter = CGPoint(x: titleRect.midX, y: titleRect.midY)
        let titleDistanceFromHub = hypot(
            titleCenter.x - center.x,
            titleCenter.y - center.y
        )
        XCTAssertGreaterThan(
            titleDistanceFromHub,
            view.geometryLayout.itemCenterRadius + 6,
            "An editable title should sit outward from the Slot's geometry center"
        )
    }

    func testSlotDragPreviewMovesEmptyAndOccupiedSlotsWithoutCommitting() throws {
        let names: [String?] = [nil, nil, "Bob", nil, "BiliBili", nil, "Paste", "Copy Selected Text", "Cut"]
        let slots = try names.enumerated().map { index, title -> EditorMenuSlot in
            guard let title else {
                return EditorMenuSlot(id: UUID(), presentation: .empty)
            }
            let actionID = ActionID("preview-" + String(index))
            let item = MenuItemPresentation(
                configuration: try MenuItemConfiguration(primaryActionID: actionID, alias: title),
                primaryAction: MenuActionPresentation(actionID: actionID, title: title, availability: .available),
                alternateActions: []
            )
            return EditorMenuSlot(id: UUID(), presentation: .occupied(item))
        }
        let view = RadialMenuView(
            slots: slots.map(\.presentation), mode: .editor,
            previewScale: 1.24, previewCanvasDiameter: 432, showsPreviewBackground: true
        )
        let appearance = MenuAppearanceConfiguration(theme: "Dark", menuSize: "150", font: "SF Mono")
        view.updateEditorSlots(slots, appearance: appearance)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        var committed = false
        view.onSlotDrop = { _, _ in committed = true; return true }

        func capture(_ filename: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["SPINNET_UI_ARTIFACT_DIR"] else { return }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let bitmap = try render(view)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: url.appendingPathComponent(filename))
        }
        try capture("slots-before.png")
        let buttonIdentities = view.subviews.compactMap { $0 as? NSButton }.map(ObjectIdentifier.init)
        XCTAssertTrue(view.previewSlotMove(id: slots[7].id, to: 2))
        XCTAssertEqual(view.subviews.compactMap { $0 as? NSButton }.map(ObjectIdentifier.init), buttonIdentities)
        XCTAssertEqual(view.editorSlots[2], slots[7])
        XCTAssertEqual(view.editorSlots[1], slots[2])
        XCTAssertFalse(committed)
        XCTAssertEqual(view.slotDragPlaceholderIndex, 2)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(view.displayedSlotPosition(at: 1), 2, accuracy: 0.01)
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            XCTAssertGreaterThan(view.displayedSlotPosition(at: 1), 1)
            XCTAssertLessThan(view.displayedSlotPosition(at: 1), 2)
            try capture("slots-mid-displacement.png")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        XCTAssertEqual(view.displayedSlotPosition(at: 1), 1, accuracy: 0.01)
        try capture("slots-during-drag.png")
        view.cancelSlotMovePreview()
        XCTAssertEqual(view.editorSlots, slots)
        XCTAssertTrue(view.previewSlotMove(id: slots[0].id, to: 4))
        XCTAssertEqual(view.editorSlots[4], slots[0])
        XCTAssertTrue(view.editorSlots[4].presentation.isEmpty)
        view.cancelSlotMovePreview()
        XCTAssertEqual(view.editorSlots, slots)
        XCTAssertFalse(view.previewSlotMove(id: UUID(), to: 0))
        XCTAssertFalse(view.previewSlotMove(id: slots[0].id, to: 99))
        XCTAssertTrue(view.previewSlotMove(id: slots[7].id, to: 2))
        view.updateEditorSlots(slots, appearance: appearance)
        view.selectEditorItem(at: 7)
        XCTAssertEqual(view.editorSlots[2], slots[7], "An unchanged model refresh must preserve the preview")
        XCTAssertEqual(view.selectedIndex, 2, "A model selection refresh must keep highlighting the dragged Slot")
        let refreshed = Array(slots.reversed())
        view.updateEditorSlots(refreshed, appearance: appearance)
        view.cancelSlotMovePreview()
        XCTAssertEqual(view.editorSlots, refreshed, "Cancellation must not restore stale authoritative state")
        XCTAssertFalse(committed)
    }

    func testNativeSlotDragDisplacesEmptySlotAndReservesGapWithoutReplacement() throws {
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: ActionID("drag"), alias: "Moving"),
            primaryAction: MenuActionPresentation(actionID: ActionID("drag"), title: "Moving", availability: .available),
            alternateActions: []
        )
        let slots = [EditorMenuSlot(id: UUID(), presentation: .occupied(item)),
                     EditorMenuSlot(id: UUID(), presentation: .empty),
                     EditorMenuSlot(id: UUID(), presentation: .empty)]
        let view = RadialMenuView(slots: slots.map(\.presentation), mode: .editor)
        view.updateEditorSlots(slots, appearance: MenuAppearanceConfiguration())
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(slots[0].id.uuidString, forType: RadialMenuView.slotPasteboardType)
        let targetRect = view.menuTitleRect(at: 1)
        let sender = SlotDraggingInfo(source: view, pasteboard: pasteboard,
                                      location: view.convert(NSPoint(x: targetRect.midX, y: targetRect.midY), to: nil))
        var committedTarget: Int?
        var replacementRequested = false
        view.onSlotDrop = { order, id in
            XCTAssertEqual(id, slots[0].id)
            XCTAssertEqual(order, [slots[1].id, slots[0].id, slots[2].id])
            committedTarget = order.firstIndex(of: id)
            return true
        }
        view.onPresetDrop = { _, _ in replacementRequested = true; return true }
        XCTAssertEqual(view.draggingEntered(sender), .move)
        XCTAssertEqual(view.editorSlots.map(\.id), [slots[1].id, slots[0].id, slots[2].id])
        XCTAssertNil(committedTarget)
        XCTAssertFalse(view.subviews.compactMap { $0 as? NSButton }.contains { $0.tag == 1 && !$0.isHidden },
                       "The lifted Slot must leave a gap, not another rendered item under the drag image")
        // Extra text representations must never turn an internal move into a Library copy.
        pasteboard.setString("not-a-library-preset", forType: .string)
        XCTAssertEqual(view.draggingUpdated(sender), .move)
        for _ in 0..<5 {
            XCTAssertEqual(view.draggingUpdated(sender), .move)
            XCTAssertEqual(view.editorSlots.map(\.id), [slots[1].id, slots[0].id, slots[2].id])
        }
        XCTAssertTrue(view.performDragOperation(sender))
        XCTAssertEqual(committedTarget, 1)
        XCTAssertFalse(replacementRequested)

        pasteboard.clearContents()
        pasteboard.setString(slots[1].id.uuidString, forType: RadialMenuView.slotPasteboardType)
        let firstRect = view.menuTitleRect(at: 0)
        sender.draggingLocation = view.convert(NSPoint(x: firstRect.midX, y: firstRect.midY), to: nil)
        XCTAssertEqual(view.draggingEntered(sender), .move)
        XCTAssertEqual(view.editorSlots.map(\.id), [slots[1].id, slots[0].id, slots[2].id],
                       "Dragging an Empty Slot must displace the occupied Slot too")
        view.draggingExited(sender)
        XCTAssertEqual(view.slotDragPlaceholderIndex, 0, "Crossing a child view must not cancel the drag")
        sender.draggingLocation = NSPoint(x: -100, y: -100)
        view.draggingExited(sender)
        XCTAssertNil(view.slotDragPlaceholderIndex)
        XCTAssertEqual(view.editorSlots, slots)
    }

    func testCircularDragLocksOppositeDirectionBuffersBoundaryAndCommitsPreview() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        for _ in 0..<7 { model.menuEditor.addEmptySlot() }
        let original = model.menuEditor.editorSlots
        let configuration = model.editor.configuration
        let view = RadialMenuView(slots: original.map(\.presentation), mode: .editor)
        view.updateEditorSlots(original, appearance: MenuAppearanceConfiguration())
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString(original[0].id.uuidString, forType: RadialMenuView.slotPasteboardType)
        func point(_ position: CGFloat) -> NSPoint {
            let angle = CGFloat.pi / 2 - position * 2 * .pi / 8
            let radius = view.bounds.width * 0.38
            return view.convert(NSPoint(x: view.bounds.midX + cos(angle) * radius,
                                        y: view.bounds.midY + sin(angle) * radius), to: nil)
        }
        let sender = SlotDraggingInfo(source: view, pasteboard: board, location: point(0.5))
        XCTAssertEqual(view.draggingEntered(sender), .move)
        sender.draggingLocation = point(7.5)
        XCTAssertEqual(view.draggingUpdated(sender), .move)
        XCTAssertEqual(view.editorSlots.map(\.id), [7, 1, 2, 3, 4, 5, 6, 0].map { original[$0].id })
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(view.displayedSlotPosition(at: 0), -1, accuracy: 0.01)
        }
        sender.draggingLocation = point(4.5)
        XCTAssertEqual(view.draggingUpdated(sender), .move)
        let oppositeOrder = [7, 1, 2, 3, 0, 4, 5, 6].map { original[$0].id }
        XCTAssertEqual(view.editorSlots.map(\.id), oppositeOrder)
        sender.draggingLocation = point(3.95)
        XCTAssertEqual(view.draggingUpdated(sender), .move)
        XCTAssertEqual(view.editorSlots.map(\.id), oppositeOrder, "Small boundary motion must not reverse the arc")
        view.onSlotDrop = { ids, selectedID in model.menuEditor.reorderSlots(ids: ids, selectedID: selectedID) }
        XCTAssertTrue(view.performDragOperation(sender))
        XCTAssertEqual(model.menuEditor.slotIDs, oppositeOrder)
        XCTAssertEqual(model.editor.configuration.menu.slots,
                       [7, 1, 2, 3, 0, 4, 5, 6].map { configuration.menu.slots[$0] })
        model.menuEditor.undoSlotEdit()
        XCTAssertEqual(model.editor.configuration, configuration)
        XCTAssertEqual(model.menuEditor.slotIDs, original.map(\.id))
        model.menuEditor.redoSlotEdit()
        XCTAssertEqual(model.menuEditor.slotIDs, oppositeOrder)

        view.updateEditorSlots(original, appearance: MenuAppearanceConfiguration())
        sender.draggingLocation = point(0.5)
        XCTAssertEqual(view.draggingEntered(sender), .move)
        sender.draggingLocation = point(3.5)
        XCTAssertEqual(view.draggingUpdated(sender), .move)
        sender.draggingLocation = point(4.5)
        XCTAssertEqual(view.draggingUpdated(sender), .move)
        XCTAssertEqual(view.editorSlots.map(\.id), [1, 2, 3, 4, 0, 5, 6, 7].map { original[$0].id })
        sender.draggingLocation = point(5.05)
        XCTAssertEqual(view.draggingUpdated(sender), .move)
        XCTAssertEqual(view.slotDragPlaceholderIndex, 4)
        sender.draggingLocation = point(5.2)
        XCTAssertEqual(view.draggingUpdated(sender), .move)
        XCTAssertEqual(view.slotDragPlaceholderIndex, 5)
        XCTAssertEqual(view.editorSlots.map(\.id), [7, 1, 2, 3, 4, 0, 5, 6].map { original[$0].id })
        view.cancelSlotMovePreview()
    }

    func testAppearanceEditorModeDoesNotExecuteOrEditSlots() throws {
        let actionID = ActionID("appearance-editor-action")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: actionID),
            primaryAction: MenuActionPresentation(
                actionID: actionID,
                title: "Open URL",
                availability: .available
            ),
            alternateActions: []
        )
        let view = RadialMenuView(items: [item], mode: .editor, allowsEditing: false)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        var selectionCount = 0
        var editCount = 0
        var primaryExecutionCount = 0
        var alternateExecutionCount = 0
        view.onEditorSelection = { _ in selectionCount += 1 }
        view.onEditorEditRequested = { _ in editCount += 1 }
        view.onPrimarySelection = { _ in primaryExecutionCount += 1 }
        view.onAlternateSelection = { _ in alternateExecutionCount += 1 }

        let location = NSPoint(x: view.bounds.midX, y: view.bounds.midY + 90)
        let hover = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        view.mouseMoved(with: hover)
        XCTAssertEqual(view.hoveredIndex, 0)
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertNil(view.menu(for: hover))

        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        ))
        view.mouseDown(with: click)
        view.mouseUp(with: click)

        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: UInt16(kVK_Return)
        ))
        view.keyDown(with: key)

        XCTAssertNil(view.selectedIndex)
        XCTAssertEqual(selectionCount, 0)
        XCTAssertEqual(editCount, 0)
        XCTAssertEqual(primaryExecutionCount, 0)
        XCTAssertEqual(alternateExecutionCount, 0)
    }

    func testDoubleClickingAnOccupiedEditorSlotRequestsEdit() throws {
        let actionID = ActionID("editor-action")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: actionID),
            primaryAction: MenuActionPresentation(
                actionID: actionID,
                title: "Open URL",
                availability: .available
            ),
            alternateActions: []
        )
        let view = RadialMenuView(items: [item], mode: .editor)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        var editedIndex: Int?
        view.onEditorEditRequested = { editedIndex = $0 }

        let location = NSPoint(x: view.bounds.midX, y: view.bounds.midY + 90)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 2,
                pressure: 1
            ))
            if type == .leftMouseDown {
                view.mouseDown(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }

        XCTAssertEqual(editedIndex, 0)
    }

    func testCommandEOpensTheFocusedEditorSlotConfiguration() throws {
        let actionID = ActionID("editor-action")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: actionID),
            primaryAction: MenuActionPresentation(
                actionID: actionID,
                title: "Open URL",
                availability: .available
            ),
            alternateActions: []
        )
        let view = RadialMenuView(items: [item], mode: .editor)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.selectEditorItem(at: 0)
        var editedIndex: Int?
        view.onEditorEditRequested = { editedIndex = $0 }

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "e",
            charactersIgnoringModifiers: "e",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_E)
        ))
        view.keyDown(with: event)

        XCTAssertEqual(editedIndex, 0)
    }

    func testEditorContextMenuRequestsDeletionForAnOccupiedSlot() throws {
        let editor = try makeEditor()
        try editor.addEmptySlot()
        let slots = MenuPresentationFactory.makeSlots(configuration: editor.configuration) {
            editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
        }
        let view = RadialMenuView(slots: slots, mode: .editor)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        var selectedIndex: Int?
        var deletedIndex: Int?
        view.onEditorSelection = { selectedIndex = $0 }
        view.onEditorSlotDeleteRequested = { deletedIndex = $0 }

        let location = NSPoint(x: view.bounds.midX, y: view.bounds.midY + 90)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try XCTUnwrap(view.menu(for: event))

        XCTAssertEqual(selectedIndex, 0)
        XCTAssertTrue(menu.items.contains { $0.title == "Slot 1 — Open URL" })
        XCTAssertTrue(menu.items.contains { $0.title == "Primary Action: Open URL" })
        XCTAssertTrue(menu.items.contains { $0.title == "Edit Slot…" })
        XCTAssertFalse(menu.items.contains { $0.title == "Move to Slot" })
        let deleteItem = try XCTUnwrap(menu.items.first { $0.title == "Delete Slot" })
        XCTAssertTrue(deleteItem.isEnabled)

        _ = NSApp.sendAction(
            try XCTUnwrap(deleteItem.action),
            to: deleteItem.target,
            from: deleteItem
        )

        XCTAssertEqual(deletedIndex, 0)
    }

    func testMenuSlotTitleFollowsPresetUntilItIsRenamed() throws {
        let editor = try makeEditor()
        let presetName: (PluginID) -> String? = { pluginID in
            editor.pluginManifests.first { $0.id == pluginID }?.name
        }
        var slots = MenuPresentationFactory.makeSlots(
            configuration: editor.configuration,
            availability: {
                editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
            },
            presetName: presetName
        )
        XCTAssertEqual(slots[0].title, "Fixture")

        try editor.configureMenuItem(
            at: 0,
            pluginID: PluginID("com.spinnet.fixture"),
            primaryCommandID: CommandID("fixture.transform_text"),
            alternateCommandIDs: [CommandID("fixture.open")],
            inputs: [CommandID("fixture.open"): .string("https://spinnet.dev")]
        )
        slots = MenuPresentationFactory.makeSlots(
            configuration: editor.configuration,
            availability: {
                editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
            },
            presetName: presetName
        )
        XCTAssertEqual(slots[0].title, "Fixture")

        try editor.renameMenuItem(at: 0, name: "Research")
        slots = MenuPresentationFactory.makeSlots(
            configuration: editor.configuration,
            availability: {
                editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
            },
            presetName: presetName
        )
        XCTAssertEqual(slots[0].title, "Research")

        try editor.renameMenuItem(at: 0, name: nil)
        slots = MenuPresentationFactory.makeSlots(
            configuration: editor.configuration,
            availability: {
                editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
            },
            presetName: presetName
        )
        XCTAssertEqual(slots[0].title, "Fixture")
    }

    func testEditButtonsFindTheirSlotsAgainWhenTheCanvasIsSizedAfterAnUpdate() throws {
        // SwiftUI updates a hosted view before it has given the view its size,
        // so the in-slot Edit controls can be placed against an empty canvas.
        // Nothing updates them again afterwards, so they have to follow the
        // Menu themselves once the real canvas arrives.
        let slots = try (0..<6).map { index in
            EditorMenuSlot(id: UUID(), presentation: try occupiedSlot(named: "Slot \(index)"))
        }
        let view = RadialMenuView(
            slots: slots.map(\.presentation),
            mode: .editor,
            allowsEditing: true,
            previewScale: 1.24,
            previewCanvasDiameter: 432,
            showsPreviewBackground: true
        )

        view.setFrameSize(.zero)
        view.updateEditorSlots(slots, appearance: MenuAppearanceConfiguration())
        view.setFrameSize(NSSize(width: 432, height: 432))

        for button in view.subviews.compactMap({ $0 as? NSButton }) {
            XCTAssertEqual(
                button.frame,
                view.editorEditButtonRect(at: button.tag),
                "The Edit control of Slot \(button.tag + 1) should sit in its Slot"
            )
            XCTAssertTrue(
                view.bounds.contains(button.frame),
                "The Edit control of Slot \(button.tag + 1) should stay on the Menu"
            )
        }
    }

    func testEditButtonsStayInTheirSlotsWhileSettingsPagesAreSwitched() throws {
        // Every switch to the Menu page builds the Editor Mode Menu again, and
        // SwiftUI sizes it after it has first updated it. The Edit controls of
        // the Slots the Menu draws have to end up on those Slots every time.
        let editor = try makeEditor()
        for index in 0..<5 {
            let action = try editor.createAction(
                id: ActionID("page-switch-\(index)"),
                pluginID: PluginID("com.spinnet.fixture"),
                commandID: CommandID("fixture.open"),
                input: .string("https://example.com/\(index)")
            )
            try editor.addMenuItem(primaryActionID: action.id)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "editor-mode-page-switch"))
        defaults.removePersistentDomain(forName: "editor-mode-page-switch")
        let controller = SettingsWindowController(editor: editor, defaults: defaults)
        controller.showWindow(nil)
        let contentView = try XCTUnwrap(controller.window?.contentView)

        for round in 0..<4 {
            controller.select(page: .appearance)
            settleSettingsLayout(of: contentView)
            controller.select(page: .menu)
            settleSettingsLayout(of: contentView)

            let menu = try XCTUnwrap(findRadialMenu(in: contentView))
            let buttons = menu.subviews.compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.count, 6, "Every occupied Slot carries an Edit control")
            for button in buttons {
                XCTAssertEqual(
                    button.frame,
                    menu.editorEditButtonRect(at: button.tag),
                    "Slot \(button.tag + 1) lost its Edit control on page switch \(round + 1)"
                )
            }
        }
    }

    func testEditButtonsSurviveACanvasChangeThatArrivesWithFewerSlots() throws {
        // update(slots:appearance:) resizes the Menu before it rebuilds the
        // Edit controls, so the controls of the Slots that just went away are
        // still around while the canvas changes.
        let slots = try (0..<6).map { try occupiedSlot(named: "Slot \($0)") }
        let view = RadialMenuView(slots: slots, mode: .editor)

        view.update(
            slots: Array(slots.prefix(3)),
            appearance: MenuAppearanceConfiguration(menuSize: "100")
        )

        let buttons = view.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 3, "A Slot that is gone keeps no Edit control")
        for button in buttons {
            XCTAssertEqual(
                button.frame,
                view.editorEditButtonRect(at: button.tag),
                "The Edit control of Slot \(button.tag + 1) should sit in its Slot"
            )
        }
    }

    private func occupiedSlot(named title: String) throws -> MenuSlotPresentation {
        let actionID = ActionID("canvas-\(title)")
        return .occupied(MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: actionID),
            primaryAction: MenuActionPresentation(
                actionID: actionID,
                title: title,
                availability: .available
            ),
            alternateActions: []
        ))
    }

    /// Lets SwiftUI finish the layout pass that follows a page switch.
    private func settleSettingsLayout(of contentView: NSView) {
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()
    }

    func testUnavailableResourceKeepsPresetTitleAndAnnotatesTheAction() throws {
        let actionID = ActionID("missing-resource")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: actionID),
            primaryAction: MenuActionPresentation(
                actionID: actionID,
                title: "Open File",
                availability: .unavailable(.resourceMissing)
            ),
            alternateActions: [],
            defaultTitle: "Open File"
        )

        XCTAssertEqual(MenuSlotPresentation.occupied(item).title, "Open File")
        XCTAssertEqual(
            item.primaryAction.displayTitle,
            "Open File (Unavailable: Referenced resource is missing)"
        )
    }
}
