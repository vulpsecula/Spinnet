import AppKit
import Carbon
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class SettingsWindowControllerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var testMenuFontFamily: String {
        MenuAppearanceConfiguration.fontOptions.first {
            $0 != MenuAppearanceConfiguration.MenuFont.system.rawValue
        } ?? MenuAppearanceConfiguration.MenuFont.system.rawValue
    }

    func testConfigurationInputResolverPreservesLegacyObjectPayloads() {
        let field = CommandConfigurationField(kind: .shortcut)
        let original: JSONValue = .object([
            "name": .string("Build project"),
            "input": .string("source tree")
        ])

        XCTAssertEqual(
            ConfigurationInputValueResolver.presentationValue(
                for: original,
                field: field,
                hostCommand: .invokeShortcut
            ),
            "Build project"
        )
        XCTAssertEqual(
            ConfigurationInputValueResolver.resolve(
                text: "Build project",
                field: field,
                hostCommand: .invokeShortcut,
                original: original
            ),
            original
        )
        XCTAssertEqual(
            ConfigurationInputValueResolver.resolve(
                text: "Run project",
                field: field,
                hostCommand: .invokeShortcut,
                original: original
            ),
            .object([
                "name": .string("Run project"),
                "input": .string("source tree")
            ])
        )

        let pathField = CommandConfigurationField(kind: .file)
        let pathInput: JSONValue = .object([
            "path": .string("/tmp/report.txt"),
            "bookmark": .string("retained")
        ])
        XCTAssertEqual(
            ConfigurationInputValueResolver.resolve(
                text: "/tmp/renamed.txt",
                field: pathField,
                hostCommand: .openFile,
                original: pathInput
            ),
            .object([
                "path": .string("/tmp/renamed.txt"),
                "bookmark": .string("retained")
            ])
        )
    }

    func testSettingsNavigationKeepsEditorModeOnlyOnMenuAndAppearance() throws {
        let controller = try makeController()

        XCTAssertEqual(
            controller.presentationSnapshot.navigationPages,
            [.menu, .appearance, .privacyAndPermissions, .about]
        )
        XCTAssertEqual(controller.presentationSnapshot.page, .menu)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .editorMode, .pageContent]
        )

        controller.select(page: .appearance)

        XCTAssertEqual(controller.presentationSnapshot.page, .appearance)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .editorMode, .pageContent]
        )
        XCTAssertTrue(controller.presentationSnapshot.editorModeIsNonExecuting)
        XCTAssertTrue(controller.presentationSnapshot.accessibleNames.contains("Appearance"))

        controller.select(page: .privacyAndPermissions)

        XCTAssertEqual(controller.presentationSnapshot.page, .privacyAndPermissions)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .pageContent]
        )
        for expectedName in [
            "System Permissions",
            "Sensitive Data Collection",
            "Plugin Access",
            "Open Accessibility Settings"
        ] {
            XCTAssertTrue(
                controller.presentationSnapshot.accessibleNames.contains(expectedName),
                "Missing accessible Privacy & Permissions content: \(expectedName)"
            )
        }

        controller.select(page: .about)

        XCTAssertEqual(controller.presentationSnapshot.page, .about)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .pageContent]
        )
        XCTAssertFalse(controller.presentationSnapshot.visibleRegions.contains(.editorMode))
    }

    func testPrivacyPagePresentsAndUpdatesPluginCapabilityGrants() throws {
        let store = PluginCapabilityGrantStore()
        let editor = try makeEditor(
            capabilities: [.readSelectedText, .writeClipboard]
        )
        store.register(
            pluginID: PluginID("com.spinnet.fixture"),
            pluginVersion: "1.0.0",
            capabilities: [.readSelectedText, .writeClipboard]
        )
        let controller = SettingsWindowController(
            editor: editor,
            capabilityGrantStore: store
        )
        controller.select(page: .privacyAndPermissions)

        XCTAssertTrue(
            controller.presentationSnapshot.accessibleNames.contains(
                "Read Selected Text: Not Determined"
            )
        )
        controller.setCapabilityDecision(
            .granted,
            for: PluginID("com.spinnet.fixture"),
            pluginVersion: "1.0.0",
            capability: .readSelectedText
        )

        XCTAssertEqual(
            store.decision(
                for: PluginID("com.spinnet.fixture"),
                pluginVersion: "1.0.0",
                capability: .readSelectedText
            ),
            .granted
        )
        XCTAssertTrue(
            controller.presentationSnapshot.accessibleNames.contains(
                "Read Selected Text: Granted"
            )
        )
    }

    func testAboutPageExposesApplicationIdentityAndLinksAtSettingsBoundary() throws {
        let controller = try makeController()
        controller.select(page: .about)

        let names = controller.presentationSnapshot.accessibleNames
        for expectedName in [
            "Spinnet",
            "Version 0.1 (Build Development)",
            "A mouse-first macOS action environment centered on a radial Menu.",
            "Source on GitHub",
            "Licence",
            "Acknowledgements",
            "Copyright"
        ] {
            XCTAssertTrue(names.contains(expectedName), "Missing accessible About content: \(expectedName)")
        }
    }

    func testSettingsNavigationPublishesPredictableFocusOrderAndNames() throws {
        let controller = try makeController()

        XCTAssertEqual(
            controller.presentationSnapshot.focusOrder,
            [
                .navigation(.menu),
                .navigation(.appearance),
                .navigation(.privacyAndPermissions),
                .navigation(.about),
                .pageContent
            ]
        )
        XCTAssertEqual(
            controller.presentationSnapshot.initialFocus,
            .navigation(.menu)
        )
        XCTAssertEqual(
            Array(controller.presentationSnapshot.accessibleNames.prefix(4)),
            ["Menu", "Appearance", "Privacy & Permissions", "About"]
        )
    }

    func testSettingsWindowClosesWithCommandW() throws {
        let controller = try makeController()
        defer { controller.close() }
        controller.present()

        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertFalse(window.isVisible)
    }

    func testStatusItemMenuOnlyOffersSettingsAndQuitWithAccessibleNames() {
        let statusItem = StatusItemController(openSettings: {}, quit: {})
        let menu = statusItem.makeMenu()

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Settings…", "Quit Spinnet"]
        )
        XCTAssertEqual(menu.items.first(where: { $0.title == "Settings…" })?.keyEquivalent, ",")
        XCTAssertEqual(menu.items.first(where: { $0.title == "Quit Spinnet" })?.keyEquivalent, "q")
        XCTAssertEqual(
            menu.items.first(where: { $0.title == "Settings…" })?.accessibilityLabel(),
            "Settings"
        )
        XCTAssertEqual(
            menu.items.first(where: { $0.title == "Quit Spinnet" })?.accessibilityLabel(),
            "Quit Spinnet"
        )
    }

    func testEditorMenuSurfaceIsVisiblyDistinctFromSettingsBackground() throws {
        let controller = try makeController()
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Settings window has no content view")
        }

        controller.window?.appearance = NSAppearance(named: .aqua)
        contentView.layoutSubtreeIfNeeded()
        let image = try render(contentView)
        let background = try XCTUnwrap(image.colorAt(x: 420, y: 420))
        let menuSurface = try XCTUnwrap(image.colorAt(x: 370, y: 515))

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
        for _ in 0..<7 { model.addEmptySlot() }
        let original = model.editorSlots
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
        view.onSlotDrop = { ids, selectedID in model.reorderSlots(ids: ids, selectedID: selectedID) }
        XCTAssertTrue(view.performDragOperation(sender))
        XCTAssertEqual(model.slotIDs, oppositeOrder)
        XCTAssertEqual(model.editor.configuration.menu.slots,
                       [7, 1, 2, 3, 0, 4, 5, 6].map { configuration.menu.slots[$0] })
        model.undoSlotEdit()
        XCTAssertEqual(model.editor.configuration, configuration)
        XCTAssertEqual(model.slotIDs, original.map(\.id))
        model.redoSlotEdit()
        XCTAssertEqual(model.slotIDs, oppositeOrder)

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

    func testRuntimeActionMenuListsPrimaryAndAlternateActions() throws {
        let primaryID = ActionID("primary")
        let alternateID = ActionID("alternate")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(
                primaryActionID: primaryID,
                alternateActionIDs: [alternateID]
            ),
            primaryAction: MenuActionPresentation(
                actionID: primaryID,
                title: "Open URL",
                availability: .available
            ),
            alternateActions: [MenuActionPresentation(
                actionID: alternateID,
                title: "Transform Text",
                availability: .available
            )]
        )
        let controller = MenuPresentationController(items: [.occupied(item)])

        let menu = try XCTUnwrap(controller.makeActionMenu(for: 0))

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Open URL", "Transform Text"]
        )
    }

    func testRuntimeActionMenuRefreshesStaleResourceAvailability() throws {
        let actionID = ActionID("resource-action")
        let configuration = try MenuItemConfiguration(primaryActionID: actionID)
        var resourceAvailable = true

        func makeSlots() -> [MenuSlotPresentation] {
            let availability: ActionAvailability = resourceAvailable
                ? .available
                : .unavailable(.resourceMissing)
            return [.occupied(MenuItemPresentation(
                configuration: configuration,
                primaryAction: MenuActionPresentation(
                    actionID: actionID,
                    title: "Open File",
                    availability: availability
                ),
                alternateActions: []
            ))]
        }

        let controller = MenuPresentationController(items: makeSlots())
        controller.onRefresh = makeSlots

        let availableMenu = try XCTUnwrap(controller.makeActionMenu(for: 0))
        XCTAssertTrue(try XCTUnwrap(availableMenu.items.first).isEnabled)

        resourceAvailable = false
        let unavailableMenu = try XCTUnwrap(controller.makeActionMenu(for: 0))
        XCTAssertFalse(try XCTUnwrap(unavailableMenu.items.first).isEnabled)
        XCTAssertTrue(unavailableMenu.items.first?.title.contains("Unavailable") == true)
    }

    func testSettingsAppearanceUpdatesTheRuntimeMenu() throws {
        let editor = try makeEditor()
        let suiteName = "SpinnetHostTests.RuntimeAppearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(editor: editor, metadata: .current, defaults: defaults)
        let items = MenuPresentationFactory.makeSlots(configuration: editor.configuration) {
            editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
        }
        let runtimeMenu = MenuPresentationController(items: items)
        model.onAppearanceChanged = runtimeMenu.applyAppearance

        model.appearanceTheme = "Dark"
        model.appearanceAccent = "Purple"
        model.appearanceMenuSize = "Large"
        model.appearanceFont = testMenuFontFamily
        model.appearanceFontWeight = "Bold"

        XCTAssertEqual(runtimeMenu.presentationSnapshot.theme, "Dark")
        XCTAssertEqual(runtimeMenu.presentationSnapshot.accent, "Purple")
        XCTAssertEqual(runtimeMenu.presentationSnapshot.menuSize, "Large")
        XCTAssertEqual(runtimeMenu.presentationSnapshot.font, testMenuFontFamily)
        XCTAssertEqual(runtimeMenu.presentationSnapshot.fontWeight, "Bold")
        XCTAssertGreaterThan(runtimeMenu.presentationSnapshot.outerRadius, 142)
    }

    func testMenuTitleLayoutUsesReadableWrappingAndConfiguredFont() {
        let wrapped = MenuTitleLayoutEngine.layout(
            title: "A Very Long Menu Item Name",
            maxWidth: 120,
            baseSize: 13,
            font: .system
        )
        XCTAssertEqual(wrapped.lineCount, 2)
        XCTAssertFalse(wrapped.text.contains("…"))
        XCTAssertEqual(wrapped.font.pointSize, 13)

        let short = MenuTitleLayoutEngine.layout(
            title: "Open",
            maxWidth: 120,
            baseSize: 13,
            font: .system
        )
        XCTAssertEqual(wrapped.font.fontDescriptor, short.font.fontDescriptor)

        let oneSlotLayout = RadialMenuLayout(
            itemCount: 1,
            innerRadius: 38,
            outerRadius: 142,
            itemCenterRadius: 90
        )
        let oneSlotTitle = MenuTitleLayoutEngine.layout(
            title: "Fixture",
            maxWidth: RadialMenuView.menuTitleWidth(for: oneSlotLayout),
            baseSize: 13,
            font: .system
        )
        XCTAssertEqual(
            oneSlotTitle.lineCount,
            1,
            "A one-slot Menu should not split an ordinary title into a vertical stack"
        )

        let singleWord = MenuTitleLayoutEngine.layout(
            title: "Fixture",
            maxWidth: 36,
            baseSize: 10,
            font: .system
        )
        XCTAssertFalse(singleWord.text.contains("\n"))

        let wrappedWord = MenuTitleLayoutEngine.layout(
            title: "ExtremelyLongSlotName",
            maxWidth: 36,
            baseSize: 10,
            font: .system
        )
        XCTAssertEqual(wrappedWord.font.pointSize, 10)
        XCTAssertFalse(wrappedWord.text.contains("…"))
        XCTAssertGreaterThan(wrappedWord.lineCount, 1)
        XCTAssertEqual(
            wrappedWord.text.replacingOccurrences(of: "\n", with: ""),
            "ExtremelyLongSlotName"
        )

        let system = MenuTitleLayoutEngine.layout(
            title: "Open",
            maxWidth: 80,
            baseSize: 13,
            font: .system
        )
        let customFamily = MenuTitleLayoutEngine.layout(
            title: "Open",
            maxWidth: 80,
            baseSize: 13,
            font: MenuAppearanceConfiguration.MenuFont(rawValue: testMenuFontFamily)
        )
        XCTAssertNotEqual(system.font.fontName, customFamily.font.fontName)

        let regular = MenuTitleLayoutEngine.layout(
            title: "Open",
            maxWidth: 80,
            baseSize: 13,
            font: .system,
            weight: .regular
        )
        let bold = MenuTitleLayoutEngine.layout(
            title: "Open",
            maxWidth: 80,
            baseSize: 13,
            font: .system,
            weight: .bold
        )
        XCTAssertNotEqual(regular.font.fontDescriptor, bold.font.fontDescriptor)
    }

    func testMenuFontOptionsIncludeEveryInstalledFontFamily() throws {
        let installedFamilies = Set(NSFontManager.shared.availableFontFamilies)
        let options = MenuAppearanceConfiguration.fontOptions

        XCTAssertEqual(options.first, MenuAppearanceConfiguration.MenuFont.system.rawValue)
        XCTAssertTrue(installedFamilies.isSubset(of: Set(options)))
        XCTAssertGreaterThan(options.count, 4)

        let family = try XCTUnwrap(options.dropFirst().first)
        let configuration = MenuAppearanceConfiguration(font: family)
        XCTAssertEqual(configuration.font, family)

        let renderedFont = configuration.titleFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(renderedFont.familyName, family)
    }

    func testMenuThemeDoesNotOverrideSettingsWindowAppearance() throws {
        let suiteName = "SpinnetHostTests.MenuThemeIsolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Dark", forKey: MenuAppearanceConfiguration.themeDefaultsKey)

        let controller = SettingsWindowController(
            editor: try makeEditor(),
            defaults: defaults
        )
        defer { controller.close() }

        XCTAssertNil(controller.window?.appearance)
    }

    func testAppearanceSizeUsesOneGeometryContractAcrossEditorRuntimeAndScreenEdges() throws {
        let visibleFrame = try XCTUnwrap(NSScreen.main).visibleFrame
        let centre = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        let edgePointers = [
            CGPoint(x: visibleFrame.minX + 1, y: visibleFrame.midY),
            CGPoint(x: visibleFrame.maxX - 1, y: visibleFrame.midY),
            CGPoint(x: visibleFrame.midX, y: visibleFrame.minY + 1),
            CGPoint(x: visibleFrame.midX, y: visibleFrame.maxY - 1)
        ]

        let menuSizes = MenuAppearanceConfiguration.menuSizeOptions + ["125", "200"]
        for size in menuSizes {
            let appearance = MenuAppearanceConfiguration(menuSize: size)
            for slotCount in [1, 4, 8, 12] {
                let slots = Array(repeating: MenuSlotPresentation.empty, count: slotCount)
                let editorView = RadialMenuView(slots: slots, mode: .editor)
                editorView.applyAppearance(appearance)
                let runtimeMenu = MenuPresentationController(
                    items: slots,
                    appearance: appearance
                )
                var activatedRuntimeSlot: Int?
                runtimeMenu.onEmptySlotActivated = { activatedRuntimeSlot = $0 }

                runtimeMenu.open(at: centre)
                let runtimeGeometry = runtimeMenu.geometrySnapshot
                XCTAssertEqual(editorView.geometryLayout, runtimeGeometry.layout)
                XCTAssertEqual(
                    editorView.bounds.width,
                    runtimeGeometry.contentSize.width,
                    accuracy: 1
                )
                XCTAssertEqual(
                    editorView.bounds.height,
                    runtimeGeometry.contentSize.height,
                    accuracy: 1
                )

                let editorCenter = CGPoint(
                    x: editorView.bounds.midX,
                    y: editorView.bounds.midY
                )
                let runtimeCenter = CGPoint(
                    x: runtimeGeometry.overlayFrame.midX,
                    y: runtimeGeometry.overlayFrame.midY
                )
                let editorItemCenter = editorView.geometryLayout.itemCenter(
                    index: 0,
                    center: editorCenter
                )
                let editorWindow = NSWindow(
                    contentRect: editorView.bounds,
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false
                )
                editorWindow.contentView = editorView
                var selectedEditorIndex: Int?
                editorView.onEditorSelection = { selectedEditorIndex = $0 }
                let editorEvent = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: editorItemCenter,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: editorWindow.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                ))
                editorView.mouseDown(with: editorEvent)
                XCTAssertEqual(
                    selectedEditorIndex,
                    runtimeGeometry.layout.hitTest(
                        point: editorItemCenter,
                        center: editorCenter
                    )
                )

                let runtimeItemOffset = runtimeGeometry.layout.itemCenter(
                    index: 0,
                    center: .zero
                )
                runtimeMenu.finishGesture(at: CGPoint(
                    x: runtimeCenter.x + runtimeItemOffset.x,
                    y: runtimeCenter.y + runtimeItemOffset.y
                ))
                XCTAssertEqual(activatedRuntimeSlot, 0)
                runtimeMenu.dismiss()

                for pointer in edgePointers {
                    runtimeMenu.open(at: pointer)
                    let actualFrame = runtimeMenu.geometrySnapshot.overlayFrame
                    let expectedFrame = appearance.layout(slotCount: slotCount).overlayFrame(
                        for: pointer,
                        in: visibleFrame
                    )
                    XCTAssertEqual(actualFrame.minX, expectedFrame.minX, accuracy: 1)
                    XCTAssertEqual(actualFrame.minY, expectedFrame.minY, accuracy: 1)
                    XCTAssertEqual(actualFrame.width, expectedFrame.width, accuracy: 1)
                    XCTAssertEqual(actualFrame.height, expectedFrame.height, accuracy: 1)
                    activatedRuntimeSlot = nil
                    let edgeItemOffset = runtimeMenu.geometrySnapshot.layout.itemCenter(
                        index: 0,
                        center: .zero
                    )
                    runtimeMenu.finishGesture(at: CGPoint(
                        x: actualFrame.midX + edgeItemOffset.x,
                        y: actualFrame.midY + edgeItemOffset.y
                    ))
                    XCTAssertEqual(activatedRuntimeSlot, 0)
                    runtimeMenu.dismiss()
                }
            }
        }
    }

    func testMenuSizeSupportsContinuousPercentagesAndThreeSnapPoints() {
        XCTAssertEqual(MenuAppearanceConfiguration.Size.small.percentage, 100)
        XCTAssertEqual(MenuAppearanceConfiguration.Size.medium.percentage, 150)
        XCTAssertEqual(MenuAppearanceConfiguration.Size.large.percentage, 200)
        XCTAssertEqual(MenuAppearanceConfiguration.menuSizeSnapPoints, [100, 150, 200])
        XCTAssertEqual(
            MenuAppearanceConfiguration.menuSizeSnapPoints[1]
                - MenuAppearanceConfiguration.menuSizeSnapPoints[0],
            MenuAppearanceConfiguration.menuSizeSnapPoints[2]
                - MenuAppearanceConfiguration.menuSizeSnapPoints[1]
        )
        for (index, point) in MenuAppearanceConfiguration.menuSizeSnapPoints.enumerated() {
            XCTAssertEqual(
                (point - MenuAppearanceConfiguration.menuSizeMinimumPercentage)
                    / (MenuAppearanceConfiguration.menuSizeMaximumPercentage
                        - MenuAppearanceConfiguration.menuSizeMinimumPercentage),
                Double(index + 1) / 3,
                accuracy: 0.001
            )
        }

        let custom = MenuAppearanceConfiguration(menuSize: "125")
        XCTAssertEqual(custom.menuSize, "125")
        XCTAssertEqual(custom.scale, 1.25, accuracy: 0.001)
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "125.5").menuSize, "125.5")
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "100").menuSize, "100")
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "150").menuSize, "150")
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "200").menuSize, "200")
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "100.00005").menuSize, "100.00005")
        XCTAssertEqual(MenuAppearanceConfiguration.exactMenuSizeValue(forPercentage: 100.4), "100.4")
        XCTAssertEqual(MenuAppearanceConfiguration.exactMenuSizeValue(forPercentage: 100), "100")
        XCTAssertEqual(MenuAppearanceConfiguration.exactMenuSizeValue(forPercentage: 150), "150")
        XCTAssertEqual(MenuAppearanceConfiguration.exactMenuSizeValue(forPercentage: 200), "200")

        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "20").menuSize, "50")
        XCTAssertEqual(MenuAppearanceConfiguration(menuSize: "999").menuSize, "Large")
        XCTAssertEqual(
            MenuAppearanceConfiguration.snappedMenuSizePercentage(97),
            100,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MenuAppearanceConfiguration.snappedMenuSizePercentage(153),
            150,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MenuAppearanceConfiguration.snappedMenuSizePercentage(160),
            160,
            accuracy: 0.001
        )
    }

    func testMenuSizeSliderSnapsDuringDragAndAlignsLabelsToTheNativeThumbTravel() throws {
        XCTAssertEqual(
            MenuAppearanceConfiguration.interactiveMenuSizeValue(forPercentage: 98),
            "Small"
        )
        XCTAssertEqual(
            MenuAppearanceConfiguration.interactiveMenuSizeValue(forPercentage: 104),
            "Small"
        )
        XCTAssertEqual(
            MenuAppearanceConfiguration.interactiveMenuSizeValue(forPercentage: 106),
            "106"
        )

        let slider = MenuSizeSliderView(
            value: 150,
            range: (MenuAppearanceConfiguration.menuSizeMinimumPercentage
                ... MenuAppearanceConfiguration.menuSizeMaximumPercentage)
        )
        slider.frame = NSRect(x: 0, y: 0, width: 300, height: 38)
        slider.layoutSubtreeIfNeeded()

        XCTAssertNil(
            MenuSizeSliderView(
                value: 104,
                range: (MenuAppearanceConfiguration.menuSizeMinimumPercentage
                    ... MenuAppearanceConfiguration.menuSizeMaximumPercentage)
            ).activeSnapPoint,
            "A custom percentage near a preset must not appear selected"
        )
        XCTAssertNil(
            MenuSizeSliderView(
                value: 100.4,
                range: (MenuAppearanceConfiguration.menuSizeMinimumPercentage
                    ... MenuAppearanceConfiguration.menuSizeMaximumPercentage)
            ).activeSnapPoint,
            "A precise custom percentage must not appear selected"
        )
        XCTAssertNil(
            MenuSizeSliderView(
                value: 100.00005,
                range: (MenuAppearanceConfiguration.menuSizeMinimumPercentage
                    ... MenuAppearanceConfiguration.menuSizeMaximumPercentage)
            ).activeSnapPoint,
            "A manually entered value that is merely close to a preset must not appear selected"
        )

        let nativeSlider = slider.nativeSlider
        let cell = try XCTUnwrap(nativeSlider.cell as? NSSliderCell)
        let originalValue = nativeSlider.doubleValue
        nativeSlider.doubleValue = MenuAppearanceConfiguration.menuSizeMinimumPercentage
        let expectedMinimum = nativeSlider.frame.minX
            + cell.knobRect(flipped: nativeSlider.isFlipped).midX
        nativeSlider.doubleValue = MenuAppearanceConfiguration.menuSizeMaximumPercentage
        let expectedMaximum = nativeSlider.frame.minX
            + cell.knobRect(flipped: nativeSlider.isFlipped).midX
        nativeSlider.doubleValue = originalValue

        XCTAssertEqual(slider.nativeThumbTravel.lowerBound, expectedMinimum, accuracy: 0.001)
        XCTAssertEqual(slider.nativeThumbTravel.upperBound, expectedMaximum, accuracy: 0.001)
        for (index, _) in MenuAppearanceConfiguration.Size.allCases.enumerated() {
            let expected = expectedMinimum
                + (expectedMaximum - expectedMinimum) * CGFloat(index + 1) / 3
            XCTAssertEqual(
                slider.snapPointXPositions[index],
                expected,
                accuracy: 0.001
            )
        }
    }

    func testMenuSizeSliderAdjustmentCreatesOneUndoEntry() throws {
        let suiteName = "SpinnetHostTests.MenuSizeUndo.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )

        model.beginAppearanceMenuSizeAdjustment()
        model.appearanceMenuSize = "112"
        model.appearanceMenuSize = "148"
        model.appearanceMenuSize = "125"
        model.endAppearanceMenuSizeAdjustment()

        XCTAssertEqual(model.appearanceMenuSize, "125")
        XCTAssertTrue(model.canUndoAppearance)

        model.undoAppearance()

        XCTAssertEqual(model.appearanceMenuSize, "Medium")
        XCTAssertFalse(model.canUndoAppearance)
        XCTAssertTrue(model.canRedoAppearance)
    }


    func testSettingsPauseResumeDuringIndexWriteInvalidatesTheOldCopy() throws {
        try assertLifecycleTransitionDuringIndexWrite { model in
            model.clipboardCollectionPaused = true
            model.clipboardCollectionPaused = false
        }
    }

    func testSettingsTurnOffReenableDuringIndexWriteInvalidatesTheOldCopy() throws {
        try assertLifecycleTransitionDuringIndexWrite { model in
            model.turnOffClipboardHistory(deleteEntries: false)
            model.clipboardCollectionEnabled = true
        }
    }

    func testSettingsClearDuringIndexWriteCannotPublishAStaleIndex() throws {
        try assertLifecycleTransitionDuringIndexWrite { $0.clearClipboardHistory() }
    }

    private func assertLifecycleTransitionDuringIndexWrite(_ transition: (SettingsWindowModel) -> Void) throws {
        let writingIndex = expectation(description: "index write is in flight")
        let sampleCompleted = expectation(description: "old sample finished")
        let controlsCompleted = expectation(description: "latest control is durable")
        let gate = DispatchSemaphore(value: 0)
        let ioLock = NSLock()
        var writesUntilPause = -1
        let h = try RichClipboardHistoryTests.Harness(writeFile: { data, url in
            ioLock.lock()
            if writesUntilPause > 0 { writesUntilPause -= 1 }
            let shouldPause = writesUntilPause == 0
            if shouldPause { writesUntilPause = -1 }
            ioLock.unlock()
            if shouldPause {
                writingIndex.fulfill()
                _ = gate.wait(timeout: .now() + 2)
            }
            try data.write(to: url, options: .atomic)
        })
        let suite = "ClipboardIndexRace." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
            clipboardHistoryStore: h.store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        model.onClipboardSettingsWillChange = { try h.collector.resetBaseline() }
        model.onClipboardHistoryChanged = { controlsCompleted.fulfill() }
        ioLock.lock(); writesUntilPause = 2; ioLock.unlock() // payload, then staged index
        let bytes = Data(repeating: 0x6A, count: 1_100_000)
        h.board.clearContents(); h.board.setData(bytes, forType: .init("com.example.binary"))
        h.collector.schedulePoll { _ in sampleCompleted.fulfill() }
        wait(for: [writingIndex], timeout: 2)
        let start = Date()
        transition(model)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
        XCTAssertTrue(model.clipboardSettingsPending)
        gate.signal()
        wait(for: [sampleCompleted, controlsCompleted], timeout: 4)
        XCTAssertFalse(model.clipboardSettingsPending)
        let package = try h.package(types: ["binary"]); h.grant(package)
        XCTAssertEqual(try h.query(package).entries, [])
        XCTAssertEqual(try h.query(package).state, .collecting)
        // The next valid large copy must still be retained in full.
        h.board.clearContents(); h.board.setData(bytes, forType: .init("com.example.binary"))
        let newCopy = expectation(description: "new valid large copy persisted")
        h.collector.schedulePoll { result in
            if case .failure(let error) = result { XCTFail("Collection failed: \(error)") }
            newCopy.fulfill()
        }
        wait(for: [newCopy], timeout: 3)
        try h.restart()
        let entry = try XCTUnwrap(h.query(package).entries.first)
        XCTAssertEqual(try h.query(package).entries.count, 1)
        XCTAssertEqual(entry.byteCount, 1_100_000)
        XCTAssertEqual(try h.chunk(package, id: entry.id, offset: 1_000_000).data, Data(repeating: 0x6A, count: 100_000))
    }

    func testSettingsClearRespondsDuringPayloadPersistenceAndPreventsLateCommit() throws {
        let writing = expectation(description: "filesystem is writing a large payload")
        let sampleCompleted = expectation(description: "sample finishes")
        let controlCompleted = expectation(description: "Clear is durable")
        let gate = DispatchSemaphore(value: 0)
        let payload = Data(repeating: 0x63, count: 1_100_000)
        let h = try RichClipboardHistoryTests.Harness(writeFile: { data, url in
            if data == payload {
                writing.fulfill()
                _ = gate.wait(timeout: .now() + 2)
            }
            try data.write(to: url, options: .atomic)
        })
        let suite = "ClipboardSlowDisk." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
            clipboardHistoryStore: h.store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        model.onClipboardSettingsWillChange = { try h.collector.resetBaseline() }
        model.onClipboardHistoryChanged = { controlCompleted.fulfill() }
        h.board.clearContents(); h.board.setData(payload, forType: .init("com.example.binary"))
        h.collector.schedulePoll { _ in sampleCompleted.fulfill() }
        wait(for: [writing], timeout: 2)
        let start = Date()
        XCTAssertTrue(h.store.settings.enabled)
        XCTAssertTrue(h.store.excludedApplications.contains("com.apple.Passwords"))
        model.clearClipboardHistory()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3, "Settings snapshots and controls must not wait for a blocked filesystem writer")
        gate.signal()
        wait(for: [sampleCompleted, controlCompleted], timeout: 4)
        let package = try h.package(types: ["binary"]); h.grant(package)
        XCTAssertEqual(try h.query(package).entries, [])
        try h.restart()
        XCTAssertEqual(try h.query(package).entries, [], "No stale index may be published after Clear")
    }

    func testSettingsClearInvalidatesAnInFlightScheduledCopy() throws {
        let h = try RichClipboardHistoryTests.Harness()
        let suite = "ClipboardLifecycle." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
            clipboardHistoryStore: h.store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        let reading = expectation(description: "old copy is in flight")
        let completed = expectation(description: "old sample completes")
        let gate = DispatchSemaphore(value: 0)
        var blockRead = true
        let collector = ClipboardCollector(store: h.store, changeCount: { h.board.changeCount }, readContents: {
            let content = ClipboardCollector.readAll(from: h.board)
            if blockRead {
                reading.fulfill()
                _ = gate.wait(timeout: .now() + 5)
            }
            return content
        }, sourceApplication: { h.source })
        model.onClipboardSettingsWillChange = { try collector.resetBaseline() }
        h.board.clearContents(); h.board.setString("before Clear", forType: .string)
        collector.schedulePoll { _ in completed.fulfill() }
        wait(for: [reading], timeout: 2)
        model.clearClipboardHistory()
        gate.signal()
        wait(for: [completed], timeout: 3)
        let package = try h.package(types: ["text"]); h.grant(package)
        XCTAssertEqual(try h.query(package).entries, [], "Clear must invalidate a sampled copy, not just existing entries")
        blockRead = false
        h.board.clearContents(); h.board.setString("after Clear", forType: .string)
        let next = expectation(description: "new copy persists")
        collector.schedulePoll { _ in next.fulfill() }
        wait(for: [next], timeout: 3)
        XCTAssertEqual(try h.query(package).entries.map(\.text), ["after Clear"])
        try h.restart()
        XCTAssertEqual(try h.query(package).entries.map(\.text), ["after Clear"])
    }

    func testSettingsHistoryUpgradeDenialReauthorizationAndRestartUsePersistedScope() throws {
        let h = try RichClipboardHistoryTests.Harness()
        let suite = "HistoryUpgrade." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let grantsURL = h.directory.appendingPathComponent("grants.json")
        let installedURL = h.directory.appendingPathComponent("Plugins")
        let configuration = try makeEditor().configuration
        func session() throws -> (SettingsWindowModel, PluginRegistry) {
            let grants = h.grants
            let registry = PluginRegistry(grantStore: grants)
            let installer = PluginInstallationStore(directory: installedURL, registry: registry, grants: grants, persistGrants: {
                try JSONEncoder().encode(grants.allGrants).write(to: grantsURL, options: .atomic)
            })
            try installer.restore()
            let model = SettingsWindowModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration),
                metadata: .current, capabilityGrantStore: grants, defaults: defaults, clipboardHistoryStore: h.store,
                accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
            model.installPlugin = { try installer.install(from: $0) }
            model.onCapabilityGrantChanged = { values in
                do { try JSONEncoder().encode(values).write(to: grantsURL, options: .atomic) }
                catch { XCTFail("Grant persistence failed: \(error)") }
            }
            return (model, registry)
        }
        func source(types: [String], version: String) throws -> URL {
            let url = h.directory.appendingPathComponent("v\(version).spinnetplugin")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONEncoder().encode(h.package(types: types, version: version).manifest).write(to: url.appendingPathComponent("manifest.json"))
            try Data("null".utf8).write(to: url.appendingPathComponent("browse.js"))
            return url
        }
        func restart() throws {
            h.grants = PluginCapabilityGrantStore(grants: try JSONDecoder().decode([PluginCapabilityGrant].self, from: Data(contentsOf: grantsURL)))
            try h.restart()
        }
        h.board.clearContents(); h.board.setString("pre-grant text", forType: .string)
        h.board.setData(Data([1, 2, 3]), forType: .png)
        try h.collector.poll()
        let (settings, registry) = try session()
        settings.installPluginPackage(at: try source(types: ["text"], version: "1"))
        XCTAssertTrue(settings.installationConsentPresented)
        settings.finishPluginConsent(grant: true)
        XCTAssertEqual(try h.query(XCTUnwrap(registry.package(for: PluginID("reader")))) .entries.map(\.text), ["pre-grant text"])
        settings.installPluginPackage(at: try source(types: ["text", "image"], version: "2"))
        let updated = try XCTUnwrap(registry.package(for: PluginID("reader")))
        XCTAssertTrue(settings.installationConsentPresented)
        XCTAssertEqual(settings.pendingCapabilityRequests(for: updated.manifest), [.readClipboardHistory])
        XCTAssertThrowsError(try h.query(updated))
        settings.finishPluginConsent(grant: false)
        XCTAssertThrowsError(try h.query(updated))
        try restart()
        let (deniedSettings, deniedRegistry) = try session()
        let denied = try XCTUnwrap(deniedRegistry.package(for: PluginID("reader")))
        XCTAssertEqual(denied.manifest.version, "2")
        XCTAssertThrowsError(try h.query(denied))
        deniedSettings.showPluginSettings(denied.manifest.id)
        deniedSettings.setCapabilityDecision(.granted, for: denied.manifest.id, pluginVersion: "2", capability: .readClipboardHistory)
        XCTAssertEqual(Set(try h.query(denied).entries.map(\.contentType)), [.text, .image])
        try restart()
        let (restoredSettings, restoredRegistry) = try session()
        let restored = try XCTUnwrap(restoredRegistry.package(for: PluginID("reader")))
        XCTAssertEqual(restoredSettings.pendingCapabilityRequests(for: restored.manifest), [])
        let image = try XCTUnwrap(h.query(restored).entries.first { $0.contentType == .image })
        XCTAssertEqual(try h.chunk(restored, id: image.id).data, Data([1, 2, 3]))
    }

    func testExcludedApplicationsSettingsPersistAndControlTheCollectorWithoutReplayingCopies() throws {
        let h = try RichClipboardHistoryTests.Harness()
        let suite = "ClipboardExclusions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
            clipboardHistoryStore: h.store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        XCTAssertTrue(model.clipboardExcludedApplications.contains("com.apple.Passwords"))
        model.addClipboardExcludedApplication(bundleID: "com.apple.Preview")
        h.board.clearContents(); h.board.setString("excluded", forType: .string)
        try h.collector.poll()
        let package = try h.package(types: ["text"])
        h.grant(package)
        XCTAssertEqual(try h.query(package).entries, [])
        let restoredStore = try ClipboardHistoryStore(fileURL: h.directory.appendingPathComponent("history.json"))
        let restored = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
            clipboardHistoryStore: restoredStore, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        XCTAssertTrue(restored.clipboardExcludedApplications.contains("com.apple.Preview"))
        model.removeClipboardExcludedApplication(bundleID: "com.apple.Preview")
        try h.collector.poll()
        XCTAssertEqual(try h.query(package).entries, [])
        h.board.clearContents(); h.board.setString("allowed", forType: .string)
        try h.collector.poll()
        XCTAssertEqual(try h.query(package).entries.map(\.text), ["allowed"])
        XCTAssertTrue(model.clipboardExcludedApplications.contains("com.apple.keychainaccess"))
    }

    func testClipboardPrivacyControlsTheHostStoreAndKeepsGrantIndependent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let suite = "ClipboardSettings." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: PluginID("history"), pluginVersion: "1", capability: .readClipboardHistory)
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, capabilityGrantStore: grants,
            defaults: defaults, clipboardHistoryStore: store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        XCTAssertFalse(model.clipboardCollectionEnabled)
        model.clipboardCollectionEnabled = true
        try store.observe(changeCount: 1, content: .init(text: "retained", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        model.clipboardCollectionPaused = true
        XCTAssertEqual(try store.query(dataTypes: ["text"]).state, .paused)
        let retentionSaved = expectation(description: "retention is durable")
        model.onClipboardHistoryChanged = { retentionSaved.fulfill() }
        model.clipboardRetention = .oneWeek
        wait(for: [retentionSaved], timeout: 2)
        model.onClipboardHistoryChanged = nil
        XCTAssertEqual(store.settings.retentionDays, 7)
        model.turnOffClipboardHistory(deleteEntries: false)
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries.count, 1)
        model.clearClipboardHistory()
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries, [])
        XCTAssertEqual(grants.decision(for: PluginID("history"), pluginVersion: "1", capability: .readClipboardHistory), .granted)
    }

    func testAppearanceUndoRedoAndClipboardPrivacyStatePersistAtTheSettingsSeam() throws {
        let suiteName = "SpinnetHostTests.SettingsState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )

        XCTAssertTrue(model.permissionGuidePresented)
        model.dismissPermissionGuide()
        XCTAssertFalse(model.permissionGuidePresented)
        XCTAssertTrue(defaults.bool(forKey: "privacy.permission-guide-shown"))

        model.appearanceTheme = "Dark"
        model.appearanceAccent = "Purple"
        model.appearanceMenuSize = "Large"
        model.appearanceFont = testMenuFontFamily
        model.appearanceFontWeight = "Bold"
        XCTAssertTrue(model.canUndoAppearance)
        model.undoAppearance()
        model.undoAppearance()
        model.undoAppearance()
        model.undoAppearance()
        model.undoAppearance()
        XCTAssertEqual(model.appearanceConfiguration, MenuAppearanceConfiguration())
        XCTAssertTrue(model.canRedoAppearance)
        model.redoAppearance()
        model.redoAppearance()
        model.redoAppearance()
        model.redoAppearance()
        model.redoAppearance()
        XCTAssertEqual(model.appearanceConfiguration.theme, "Dark")
        XCTAssertEqual(model.appearanceConfiguration.accent, "Purple")
        XCTAssertEqual(model.appearanceConfiguration.menuSize, "Large")
        XCTAssertEqual(model.appearanceConfiguration.font, testMenuFontFamily)
        XCTAssertEqual(model.appearanceConfiguration.fontWeight, "Bold")

        model.clipboardCollectionEnabled = true
        model.clipboardCollectionPaused = true
        model.clipboardRetention = .oneWeek
        XCTAssertEqual(model.clipboardCollectionStatus, "Paused — existing entries are retained")
        XCTAssertTrue(defaults.bool(forKey: "privacy.clipboard-collection-enabled"))
        XCTAssertTrue(defaults.bool(forKey: "privacy.clipboard-collection-paused"))
        XCTAssertEqual(defaults.string(forKey: "privacy.clipboard-retention"), "1 week")

        let restored = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )
        XCTAssertFalse(restored.permissionGuidePresented)
        XCTAssertTrue(restored.clipboardCollectionEnabled)
        XCTAssertTrue(restored.clipboardCollectionPaused)
        XCTAssertEqual(restored.clipboardRetention, .oneWeek)
    }

    func testResetAppearanceIsOneUndoableChange() throws {
        let suiteName = "SpinnetHostTests.AppearanceReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )

        model.appearanceTheme = "Dark"
        model.appearanceAccent = "Purple"
        model.appearanceMenuSize = "Large"
        model.appearanceFont = testMenuFontFamily
        model.appearanceFontWeight = "Bold"
        let customized = model.appearanceConfiguration

        model.resetAppearance()

        XCTAssertEqual(model.appearanceConfiguration, MenuAppearanceConfiguration())
        XCTAssertEqual(defaults.string(forKey: "appearance.theme"), "System")
        XCTAssertEqual(defaults.string(forKey: "appearance.accent"), "System")
        XCTAssertEqual(defaults.string(forKey: "appearance.menu-size"), "Medium")
        XCTAssertEqual(defaults.string(forKey: "appearance.font"), "System")
        XCTAssertEqual(defaults.string(forKey: "appearance.font-weight"), "Semibold")

        model.undoAppearance()

        XCTAssertEqual(model.appearanceConfiguration, customized)
        XCTAssertTrue(model.canRedoAppearance)

        model.redoAppearance()
        XCTAssertEqual(model.appearanceConfiguration, MenuAppearanceConfiguration())
    }

    func testSetupRequiredPresetStaysEmptyUntilValidConfigurationIsSaved() throws {
        let registry = PluginRegistry()
        let packages = try BuiltInPresetCatalog.makePackages()
        for package in packages { try registry.register(package) }
        let configuration = try HostConfiguration(
            actions: [],
            menu: MenuConfiguration(slots: [.empty])
        )
        let model = SettingsWindowModel(
            editor: HostConfigurationEditor(registry: registry, configuration: configuration),
            metadata: .current,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )
        let applicationPreset = try XCTUnwrap(
            packages.first { $0.manifest.name == "Open Application" }
        )

        XCTAssertFalse(model.placePreset(pluginID: applicationPreset.manifest.id.rawValue, at: 0))
        XCTAssertEqual(
            model.pendingPresetSetup,
            PendingPresetSetup(
                pluginID: applicationPreset.manifest.id.rawValue,
                slotIndex: 0,
                replacing: false
            )
        )
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)

        let command = try XCTUnwrap(applicationPreset.manifest.commands.first)
        XCTAssertThrowsError(try model.editor.configuredMenuItem(
            at: 0,
            pluginID: applicationPreset.manifest.id,
            primaryCommandID: command.id,
            inputs: [command.id: .string("")],
            replacingEmptySlot: true,
            validateInputs: true
        ))
        let candidate = try model.editor.configuredMenuItem(
            at: 0,
            pluginID: applicationPreset.manifest.id,
            primaryCommandID: command.id,
            inputs: [command.id: .string("/Applications/TextEdit.app")],
            replacingEmptySlot: true,
            validateInputs: true
        )
        model.savePresetSetup(
            candidate,
            for: try XCTUnwrap(model.pendingPresetSetup)
        )

        XCTAssertNotNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertNil(model.pendingPresetSetup)
        XCTAssertNil(model.editingMenuIndex)
        XCTAssertTrue(model.canUndoSlotEdit)
    }

    func testCancellingSetupRequiredPresetLeavesItsSlotEmpty() throws {
        let registry = PluginRegistry()
        let packages = try BuiltInPresetCatalog.makePackages()
        for package in packages { try registry.register(package) }
        let model = SettingsWindowModel(
            editor: HostConfigurationEditor(
                registry: registry,
                configuration: try HostConfiguration(
                    actions: [],
                    menu: MenuConfiguration(slots: [.empty])
                )
            ),
            metadata: .current,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )
        let applicationPreset = try XCTUnwrap(
            packages.first { $0.manifest.name == "Open Application" }
        )

        XCTAssertFalse(model.placePreset(pluginID: applicationPreset.manifest.id.rawValue, at: 0))
        XCTAssertNotNil(model.pendingPresetSetup)

        model.cancelPresetSetup()

        XCTAssertNil(model.pendingPresetSetup)
        XCTAssertNil(model.editingMenuIndex)
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertTrue(model.editor.configuration.actions.isEmpty)
    }

    func testAddingTheSamePresetTwiceKeepsMenuItemActionsIndependent() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        model.addEmptySlot()

        XCTAssertTrue(model.placePreset(pluginID: "com.spinnet.fixture", at: 1))
        let firstItem = try XCTUnwrap(model.editor.configuration.menu.slots[1].item)
        let firstPrimaryID = firstItem.primaryActionID

        let firstCandidate = try model.editor.configuredMenuItem(
            at: 1,
            pluginID: PluginID("com.spinnet.fixture"),
            primaryCommandID: CommandID("fixture.open"),
            inputs: [CommandID("fixture.open"): .string("https://first.example")],
            validateInputs: true
        )
        var firstNamedSlots = firstCandidate.menu.slots
        firstNamedSlots[1] = .occupied(
            try XCTUnwrap(firstNamedSlots[1].item).withAlias("First Item")
        )
        let firstNamedCandidate = try HostConfiguration(
            actions: firstCandidate.actions,
            menu: MenuConfiguration(slots: firstNamedSlots)
        )
        model.saveMenuItemConfiguration(firstNamedCandidate)

        XCTAssertTrue(model.placePreset(pluginID: "com.spinnet.fixture", at: 2))
        let secondItem = try XCTUnwrap(model.editor.configuration.menu.slots[2].item)
        let secondPrimaryID = secondItem.primaryActionID
        XCTAssertNotEqual(firstPrimaryID, secondPrimaryID)
        XCTAssertEqual(model.editor.configuration.menu.slots[1].item?.alias, "First Item")
        XCTAssertNil(model.editor.configuration.menu.slots[2].item?.alias)

        let firstAction = try XCTUnwrap(model.editor.configuration.actions.first {
            $0.id == firstPrimaryID
        })
        let secondAction = try XCTUnwrap(model.editor.configuration.actions.first {
            $0.id == secondPrimaryID
        })
        XCTAssertEqual(firstAction.input, .string("https://first.example"))
        XCTAssertEqual(secondAction.input, .string("https://example.com"))
    }

    func testSettingsPageSelectionIsBlockedWhileAConfigurationSheetIsOpen() throws {
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )
        model.requestEdit(at: 0)
        XCTAssertEqual(model.editingMenuIndex, 0)
        model.selectPage(.privacyAndPermissions)
        XCTAssertEqual(model.page, .menu)
        model.editingMenuIndex = nil
        model.selectPage(.privacyAndPermissions)
        XCTAssertEqual(model.page, .privacyAndPermissions)
    }

    func testMenuItemConfigurationSaveIsAtomicAndParticipatesInUndoRedo() throws {
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )
        let original = model.editor.configuration

        XCTAssertThrowsError(try model.editor.configuredMenuItem(
            at: 0,
            pluginID: PluginID("com.spinnet.fixture"),
            primaryCommandID: CommandID("fixture.open"),
            inputs: [CommandID("fixture.open"): .string("not a URL")],
            validateInputs: true
        ))
        XCTAssertEqual(model.editor.configuration, original)

        let candidate = try model.editor.configuredMenuItem(
            at: 0,
            pluginID: PluginID("com.spinnet.fixture"),
            primaryCommandID: CommandID("fixture.open"),
            inputs: [CommandID("fixture.open"): .string("https://spinnet.dev")],
            validateInputs: true
        )
        model.saveMenuItemConfiguration(candidate)
        XCTAssertEqual(
            model.editor.configuration.actions.first?.input,
            .string("https://spinnet.dev")
        )
        model.undoSlotEdit()
        XCTAssertEqual(model.editor.configuration, original)
        model.redoSlotEdit()
        XCTAssertEqual(
            model.editor.configuration.actions.first?.input,
            .string("https://spinnet.dev")
        )
    }

    func testAddingAnEmptySlotAndPlacingALibraryPluginOpensThatSlotEditor() throws {
        let suiteName = "SpinnetHostTests.SlotPlacement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults
        )
        var savedConfiguration: HostConfiguration?
        model.onConfigurationChanged = { savedConfiguration = $0 }

        model.addEmptySlot()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 2)
        XCTAssertEqual(model.selectedMenuIndex, 1)
        XCTAssertNil(model.editor.configuration.menu.slots[1].item)

        XCTAssertTrue(model.placePreset(pluginID: "com.spinnet.fixture", at: 1))
        XCTAssertNotNil(model.editor.configuration.menu.slots[1].item)
        XCTAssertEqual(model.editingMenuIndex, 1)
        XCTAssertEqual(savedConfiguration, model.editor.configuration)
    }

    func testPlacingAPluginPresetBindsItsDefaultAlternateActionToTheSlot() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()

        XCTAssertTrue(model.placePreset(pluginID: "com.spinnet.fixture", at: 1))

        let item = try XCTUnwrap(model.editor.configuration.menu.slots[1].item)
        XCTAssertEqual(item.alternateActionIDs.count, 1)
        let transformAction = try XCTUnwrap(model.editor.configuration.actions.first {
            $0.commandID == CommandID("fixture.transform_text")
        })
        XCTAssertFalse(transformAction.isConfigurable)
        XCTAssertEqual(transformAction.input, .null)
        let runtimeSlots = MenuPresentationFactory.makeSlots(
            configuration: model.editor.configuration,
            availability: { _ in .available }
        )
        XCTAssertEqual(runtimeSlots[1].item?.primaryAction.title, "Open URL")
        XCTAssertEqual(runtimeSlots[1].item?.alternateActions.map(\.title), ["Transform Text"])
    }

    func testLibraryGroupsOnePresetPerSourceAndSearchesPluginCommands() throws {
        let registry = PluginRegistry()
        let builtIn = try PluginManifest(
            id: PluginID("host.copy"),
            name: "Copy",
            version: "1.0.0",
            commands: [CommandDeclaration(
                id: CommandID("host.copy.selection"),
                title: "Copy Selected Text",
                hostCommand: .openURL
            )],
            preset: MenuItemPresetDeclaration(
                readiness: .readyToUse,
                isConfigurable: false,
                defaultPrimaryCommandID: CommandID("host.copy.selection"),
                defaultInputs: [CommandID("host.copy.selection"): .string("spinnet://copy-selection")]
            )
        )
        let plugin = try PluginManifest(
            id: PluginID("com.spinnet.search"),
            name: "Search Tools",
            version: "1.0.0",
            commands: [
                CommandDeclaration(
                    id: CommandID("search.web"),
                    title: "Search the Web",
                    hostCommand: .openURL
                ),
                CommandDeclaration(
                    id: CommandID("search.docs"),
                    title: "Search Documentation",
                    hostCommand: .openURL
                )
            ],
            preset: MenuItemPresetDeclaration(
                readiness: .setupRequired,
                isConfigurable: true,
                defaultPrimaryCommandID: CommandID("search.web")
            )
        )
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/copy.spinnetplugin"),
            manifest: builtIn,
            presetSource: .builtIn
        ))
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/search.spinnetplugin"),
            manifest: plugin
        ))
        let configuration = try HostConfiguration(
            actions: [],
            menu: MenuConfiguration(slots: [.empty])
        )
        let model = SettingsWindowModel(
            editor: HostConfigurationEditor(registry: registry, configuration: configuration),
            metadata: .current
        )

        let sections = model.librarySections(matching: "")

        XCTAssertEqual(sections.map(\.source), [.builtIn, .plugin])
        XCTAssertEqual(sections.map { $0.presets.count }, [1, 1])
        XCTAssertEqual(sections[1].presets[0].commands.count, 2)
        XCTAssertEqual(sections[0].presets[0].stateLabel, "Ready to Use")
        XCTAssertEqual(sections[0].presets[0].configurationLabel, "No Configuration")
        XCTAssertEqual(sections[1].presets[0].stateLabel, "Setup Required")
        XCTAssertEqual(sections[1].presets[0].configurationLabel, "Configurable")
        XCTAssertEqual(
            model.librarySections(matching: "documentation").flatMap(\.presets).map(\.name),
            ["Search Tools"]
        )
        let emptyConfiguration = model.editor.configuration
        XCTAssertFalse(model.placePreset(pluginID: plugin.id.rawValue, at: 0))
        XCTAssertEqual(model.editor.configuration, emptyConfiguration)
        XCTAssertEqual(model.placementMessage, "Invalid Action: Preset requires setup")
        for accessibleName in [
            "Built-in Presets",
            "Plugin Presets",
            "Copy, Ready to Use, No Configuration, Commands: Copy Selected Text",
            "Search Tools, Setup Required, Configurable, Commands: Search the Web, Search Documentation"
        ] {
            XCTAssertTrue(model.accessibleNames.contains(accessibleName))
        }

        try registry.setEnabled(false, for: plugin.id)
        let unavailablePreset = try XCTUnwrap(
            model.librarySections(matching: "Search Tools").flatMap(\.presets).first
        )
        XCTAssertEqual(unavailablePreset.stateLabel, "Unavailable")
        XCTAssertTrue(unavailablePreset.accessibilityLabel.contains("Plugin is disabled"))
    }

    func testOccupiedSlotRequiresExplicitPresetReplacementAndUndoRestoresIt() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        let originalConfiguration = model.editor.configuration

        XCTAssertFalse(model.placePreset(pluginID: "com.spinnet.fixture", at: 0))
        XCTAssertEqual(model.editor.configuration, originalConfiguration)
        XCTAssertEqual(
            model.presetPendingReplacement,
            PendingPresetReplacement(pluginID: "com.spinnet.fixture", slotIndex: 0)
        )

        model.confirmPresetReplacement()

        XCTAssertNotEqual(model.editor.configuration, originalConfiguration)
        XCTAssertNil(model.presetPendingReplacement)
        XCTAssertTrue(model.canUndoSlotEdit)

        model.undoSlotEdit()

        XCTAssertEqual(model.editor.configuration, originalConfiguration)
    }

    func testOccupiedAndEmptySlotsReorderAlongShortestArcAndUndoRestoresIdentity() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        model.addEmptySlot()
        let original = model.editor.configuration
        let ids = model.slotIDs
        XCTAssertTrue(model.moveSlot(from: 0, to: 2))
        XCTAssertEqual(model.slotIDs, [ids[2], ids[1], ids[0]])
        XCTAssertEqual(model.editor.configuration.menu.slots[2], original.menu.slots[0])
        XCTAssertTrue(model.moveSlot(from: 0, to: 1))
        XCTAssertEqual(model.slotIDs, [ids[1], ids[2], ids[0]])
        model.undoSlotEdit()
        model.undoSlotEdit()
        XCTAssertEqual(model.slotIDs, ids)
        XCTAssertEqual(model.editor.configuration, original)
        model.redoSlotEdit()
        XCTAssertEqual(model.slotIDs, [ids[2], ids[1], ids[0]])
    }


    func testMenuItemAliasMovesWithTheMenuItem() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        try model.editor.renameMenuItem(at: 0, name: "Pinned")

        XCTAssertTrue(model.moveSlot(from: 0, to: 1))
        XCTAssertNil(model.editor.configuration.menu.slots[0].item?.alias)
        XCTAssertEqual(model.editor.configuration.menu.slots[1].item?.alias, "Pinned")
        XCTAssertEqual(model.menuSlots[1].title, "Pinned")
    }

    func testDeletionRequiresConfirmationAndRemovesTheWholeOccupiedSlot() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        model.selectMenuItem(at: 0)
        let original = model.editor.configuration
        model.requestSelectedSlotDeletion()
        XCTAssertEqual(model.editor.configuration, original)
        XCTAssertNotNil(model.slotPendingDeletion)
        model.cancelSlotDeletion()
        XCTAssertEqual(model.editor.configuration, original)
        model.requestSelectedSlotDeletion()
        model.confirmSlotDeletion()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)
        model.undoSlotEdit()
        XCTAssertEqual(model.editor.configuration, original)
    }


    func testRadialMenuAcceptsSwiftUIPresetTextPasteboardType() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.spinnet.tests.preset-drag"))
        let textType = NSPasteboard.PasteboardType.string
        pasteboard.declareTypes([textType], owner: nil)
        pasteboard.setString("com.spinnet.fixture", forType: textType)

        XCTAssertEqual(
            RadialMenuView.libraryPresetID(from: pasteboard),
            "com.spinnet.fixture"
        )
    }

    func testLibraryPresetDragProviderPublishesStandardTextPayload() {
        let provider = MenuEditorView.libraryPresetDragProvider(for: "com.spinnet.fixture")

        XCTAssertTrue(
            provider.registeredTypeIdentifiers.contains(NSPasteboard.PasteboardType.string.rawValue)
        )
    }

    func testReadyPresetAutosavesAndProducesTheSameRuntimeMenuAfterRestart() throws {
        let registry = PluginRegistry()
        let manifest = try PluginManifest(
            id: PluginID("com.spinnet.ready"),
            name: "Ready Plugin",
            version: "1.0.0",
            commands: [
                CommandDeclaration(
                    id: CommandID("ready.primary"),
                    title: "Primary",
                    hostCommand: .openURL
                ),
                CommandDeclaration(
                    id: CommandID("ready.alternate"),
                    title: "Alternate",
                    hostCommand: .openURL
                )
            ],
            preset: MenuItemPresetDeclaration(
                readiness: .readyToUse,
                isConfigurable: false,
                defaultPrimaryCommandID: CommandID("ready.primary"),
                defaultAlternateCommandIDs: [CommandID("ready.alternate")],
                defaultInputs: [
                    CommandID("ready.primary"): .string("https://example.com/primary"),
                    CommandID("ready.alternate"): .string("https://example.com/alternate")
                ]
            )
        )
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/ready.spinnetplugin"),
            manifest: manifest
        ))
        let configuration = try HostConfiguration(
            actions: [],
            menu: MenuConfiguration(slots: [.empty])
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetPresetWorkflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostConfigurationStore(
            fileURL: directory.appendingPathComponent("configuration.json")
        )
        let model = SettingsWindowModel(
            editor: HostConfigurationEditor(registry: registry, configuration: configuration),
            metadata: .current
        )
        model.onConfigurationChanged = { try? store.save($0) }

        XCTAssertTrue(model.placePreset(pluginID: manifest.id.rawValue, at: 0))

        let restartedConfiguration = try XCTUnwrap(store.load())
        let item = try XCTUnwrap(restartedConfiguration.menu.slots[0].item)
        XCTAssertEqual(item.alternateActionIDs.count, 1)
        XCTAssertEqual(
            restartedConfiguration.actions.map(\.input),
            [
                .string("https://example.com/primary"),
                .string("https://example.com/alternate")
            ]
        )
        let runtimeSlots = MenuPresentationFactory.makeSlots(
            configuration: restartedConfiguration,
            availability: { _ in .available }
        )
        XCTAssertEqual(runtimeSlots[0].item?.primaryAction.title, "Primary")
        XCTAssertEqual(runtimeSlots[0].item?.alternateActions.map(\.title), ["Alternate"])
        XCTAssertNil(model.editingMenuIndex)
    }

    func testReadyPresetRejectsADefaultThatCannotRunImmediately() {
        XCTAssertThrowsError(try PluginManifest(
            id: PluginID("com.spinnet.invalid-ready"),
            name: "Invalid Ready Preset",
            version: "1.0.0",
            commands: [CommandDeclaration(
                id: CommandID("invalid.open"),
                title: "Open",
                hostCommand: .openURL
            )],
            preset: MenuItemPresetDeclaration(
                readiness: .readyToUse,
                isConfigurable: false,
                defaultPrimaryCommandID: CommandID("invalid.open"),
                defaultInputs: [CommandID("invalid.open"): .null]
            )
        )) { error in
            XCTAssertEqual(
                error as? ConfigurationError,
                .invalidManifest("Ready-to-Use Preset input is invalid for Command invalid.open")
            )
        }
    }

    func testDeleteKeyDoesNotClearSlotContent() throws {
        let occupiedEditor = try makeEditor()
        let occupiedController = SettingsWindowController(editor: occupiedEditor)
        defer { occupiedController.close() }
        let occupiedContent = try XCTUnwrap(occupiedController.window?.contentView)
        occupiedController.present()
        occupiedContent.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        _ = renderedAccessibilityLabels(in: occupiedContent)

        for label in [
            "Edit Menu Item in Slot 1",
            "Delete selected Slot…",
            "Undo Slot edit",
            "Redo Slot edit"
        ] {
            XCTAssertTrue(occupiedController.presentationSnapshot.accessibleNames.contains(label))
        }

        let deleteEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: occupiedController.window?.windowNumber ?? 0,
            context: nil,
            characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false,
            keyCode: UInt16(kVK_Delete)
        ))
        NSApp.sendEvent(deleteEvent)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertNotNil(occupiedEditor.configuration.menu.slots[0].item)

        let emptyController = try makeController(emptySlotCount: 1)
        defer { emptyController.close() }
        XCTAssertFalse(
            emptyController.presentationSnapshot.accessibleNames.contains("Replace selected Slot with Fixture")
        )
    }

    func testPluginPresetOnlyExposesAddForAnEmptyFocusedSlot() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()

        XCTAssertTrue(model.accessibleNames.contains("Add Fixture to selected Slot"))
        XCTAssertFalse(model.accessibleNames.contains("Replace selected Slot with Fixture"))

        model.selectMenuItem(at: 0)

        XCTAssertFalse(model.accessibleNames.contains("Add Fixture to selected Slot"))
        XCTAssertFalse(model.accessibleNames.contains("Replace selected Slot with Fixture"))
    }

    func testDeleteSelectedContentRemovesAnEmptySlotAtTheSettingsWorkflowSeam() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        model.selectMenuItem(at: 1)
        var savedConfiguration: HostConfiguration?
        model.onConfigurationChanged = { savedConfiguration = $0 }

        model.requestSelectedSlotDeletion()
        XCTAssertNil(savedConfiguration)
        model.confirmSlotDeletion()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertEqual(savedConfiguration, model.editor.configuration)
    }

    func testPendingDeletionTracksSlotIdentityAcrossReorderAndRejectsStaleDrags() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        let occupiedID = model.slotIDs[0]
        XCTAssertTrue(model.requestSlotDeletion(at: 0))
        XCTAssertTrue(model.moveSlot(from: 0, to: 1))
        model.confirmSlotDeletion()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertFalse(model.moveSlot(id: occupiedID, to: 0))
        XCTAssertFalse(model.requestSlotDeletion(id: occupiedID))
        XCTAssertFalse(model.requestSlotDeletion(at: 0))
        XCTAssertNil(model.slotPendingDeletion)
        model.undoSlotEdit()
        XCTAssertEqual(model.slotIDs[1], occupiedID)
        model.undoSlotEdit()
        XCTAssertEqual(model.slotIDs[0], occupiedID)
    }


    func testSlotEditsUndoRedoAndPersistThroughTheSettingsWorkflowSeam() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetSlotWorkflow-\(UUID().uuidString)")
        let store = HostConfigurationStore(
            fileURL: directory.appendingPathComponent("configuration.json")
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.onConfigurationChanged = { try? store.save($0) }

        model.addEmptySlot()
        XCTAssertTrue(model.canUndoSlotEdit)
        XCTAssertEqual(try store.load()?.menu.slots.count, 2)

        model.undoSlotEdit()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertEqual(try store.load()?.menu.slots.count, 1)
        XCTAssertTrue(model.canRedoSlotEdit)

        model.redoSlotEdit()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 2)
        XCTAssertNil(model.editor.configuration.menu.slots[1].item)
        XCTAssertEqual(try store.load(), model.editor.configuration)
    }

    func testUndoRestoresTheExactOccupiedSlotAfterConfirmedDeletion() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        model.selectMenuItem(at: 0)
        model.requestSelectedSlotDeletion()
        model.confirmSlotDeletion()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)

        model.undoSlotEdit()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 2)
        XCTAssertEqual(
            model.editor.configuration.menu.slots[0].item?.primaryActionID,
            ActionID("open-url")
        )
        XCTAssertNil(model.editor.configuration.menu.slots[1].item)
    }

    func testSettingsWorkflowStopsAddingEmptySlotsAtTwelve() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)

        for _ in 1..<13 {
            model.addEmptySlot()
        }

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 12)
        XCTAssertTrue(model.editor.configuration.menu.slots.dropFirst().allSatisfy { $0.item == nil })
    }

    func testPlacementAndSlotAdditionUndoAsSeparateCompositionEdits() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        model.addEmptySlot()
        XCTAssertTrue(model.canUndoSlotEdit)

        XCTAssertTrue(model.placePreset(pluginID: "com.spinnet.fixture", at: 2))

        XCTAssertTrue(model.canUndoSlotEdit)
        model.undoSlotEdit()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 3)
        XCTAssertNotNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertNil(model.editor.configuration.menu.slots[1].item)
        XCTAssertNil(model.editor.configuration.menu.slots[2].item)

        model.undoSlotEdit()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 2)
        XCTAssertNotNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertNil(model.editor.configuration.menu.slots[1].item)
    }

    func testEverySettingsPageRendersAtTheWindowBoundary() throws {
        let defaults = UserDefaults.standard
        let appearanceKeys = [
            "appearance.theme",
            "appearance.accent",
            "appearance.menu-size",
            "appearance.font",
            "appearance.font-weight"
        ]
        let originalAppearance = Dictionary(uniqueKeysWithValues: appearanceKeys.map { ($0, defaults.object(forKey: $0)) })
        if let theme = ProcessInfo.processInfo.environment["SPINNET_UI_THEME"] {
            defaults.set(theme, forKey: "appearance.theme")
        }
        if let accent = ProcessInfo.processInfo.environment["SPINNET_UI_ACCENT"] {
            defaults.set(accent, forKey: "appearance.accent")
        }
        if let menuSize = ProcessInfo.processInfo.environment["SPINNET_UI_MENU_SIZE"] {
            defaults.set(menuSize, forKey: "appearance.menu-size")
        }
        if let font = ProcessInfo.processInfo.environment["SPINNET_UI_FONT"] {
            defaults.set(font, forKey: "appearance.font")
        }
        if let fontWeight = ProcessInfo.processInfo.environment["SPINNET_UI_FONT_WEIGHT"] {
            defaults.set(fontWeight, forKey: "appearance.font-weight")
        }
        defer {
            for key in appearanceKeys {
                if let value = originalAppearance[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let emptySlotCount = Int(
            ProcessInfo.processInfo.environment["SPINNET_UI_EMPTY_SLOTS"] ?? "0"
        ) ?? 0
        let controller = try makeController(emptySlotCount: emptySlotCount)
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Settings window has no content view")
        }
        let artifactDirectory = ProcessInfo.processInfo.environment["SPINNET_UI_ARTIFACT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let artifactDirectory {
            try FileManager.default.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: true
            )
        }

        for page in SettingsPage.allCases {
            controller.select(page: page)
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            contentView.layoutSubtreeIfNeeded()
            let image = try render(contentView)
            let backingBounds = contentView.convertToBacking(contentView.bounds)
            XCTAssertEqual(image.pixelsWide, Int(backingBounds.width))
            XCTAssertEqual(image.pixelsHigh, Int(backingBounds.height))

            if let artifactDirectory,
               let data = image.representation(using: .png, properties: [:]) {
                try data.write(to: artifactDirectory.appendingPathComponent("settings-\(page.rawValue).png"))
            }
        }
    }

    func testAppearanceChangesPersistImmediatelyWithoutASaveButton() throws {
        let suiteName = "SpinnetHostTests.Appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let editor = try makeEditor()
        let model = SettingsWindowModel(
            editor: editor,
            metadata: .current,
            defaults: defaults
        )
        var appliedAppearance: MenuAppearanceConfiguration?
        model.onAppearanceChanged = { appliedAppearance = $0 }

        model.appearanceTheme = "Dark"
        model.appearanceAccent = "Purple"
        model.appearanceMenuSize = "Large"
        model.appearanceFont = testMenuFontFamily
        model.appearanceFontWeight = "Bold"

        XCTAssertEqual(appliedAppearance?.theme, "Dark")
        XCTAssertEqual(appliedAppearance?.accent, "Purple")
        XCTAssertEqual(appliedAppearance?.menuSize, "Large")
        XCTAssertEqual(appliedAppearance?.font, testMenuFontFamily)
        XCTAssertEqual(appliedAppearance?.fontWeight, "Bold")
        XCTAssertEqual(defaults.string(forKey: "appearance.theme"), "Dark")
        XCTAssertEqual(defaults.string(forKey: "appearance.accent"), "Purple")
        XCTAssertEqual(defaults.string(forKey: "appearance.menu-size"), "Large")
        XCTAssertEqual(defaults.string(forKey: "appearance.font"), testMenuFontFamily)
        XCTAssertEqual(defaults.string(forKey: "appearance.font-weight"), "Bold")

        let restored = SettingsWindowModel(
            editor: editor,
            metadata: .current,
            defaults: defaults
        )
        XCTAssertEqual(restored.appearanceTheme, "Dark")
        XCTAssertEqual(restored.appearanceAccent, "Purple")
        XCTAssertEqual(restored.appearanceMenuSize, "Large")
        XCTAssertEqual(restored.appearanceFont, testMenuFontFamily)
        XCTAssertEqual(restored.appearanceFontWeight, "Bold")
    }

    func testMenuTriggerDefaultsToMouseSideButtonWithoutAKeyboardShortcut() throws {
        let suiteName = "SpinnetHostTests.MenuTriggerDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = MenuTriggerConfiguration(defaults: defaults)

        XCTAssertEqual(configuration.mouseButton, 3)
        XCTAssertNil(configuration.keyboardShortcut)
    }

    func testOptionalKeyboardShortcutPersistsAndAppliesImmediately() throws {
        let suiteName = "SpinnetHostTests.MenuTriggerPersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults
        )
        let shortcut = MenuKeyboardShortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey),
            displayValue: "⌃⌥Space"
        )
        var appliedConfiguration: MenuTriggerConfiguration?
        model.onTriggerChanged = { appliedConfiguration = $0 }

        model.triggerKeyboardShortcut = shortcut

        XCTAssertEqual(appliedConfiguration?.keyboardShortcut, shortcut)
        XCTAssertEqual(
            MenuTriggerConfiguration(defaults: defaults).keyboardShortcut,
            shortcut
        )

        model.triggerKeyboardShortcut = nil

        XCTAssertNil(appliedConfiguration?.keyboardShortcut)
        XCTAssertNil(MenuTriggerConfiguration(defaults: defaults).keyboardShortcut)
    }

    func testMouseTriggerOnlyInvokesForTheConfiguredSideButton() {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 4)
        var invocationCount = 0
        controller.onInvoke = { invocationCount += 1 }

        XCTAssertFalse(controller.handleMouseButton(3))
        XCTAssertTrue(controller.handleMouseButton(4))
        XCTAssertEqual(invocationCount, 1)
    }

    func testConfiguredSideButtonEventsAreConsumedBeforeTheyReachTheForegroundApp() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3)
        var invocationCount = 0
        controller.onInvoke = { invocationCount += 1 }

        let down = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ))
        down.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        let up = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseUp,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ))
        up.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        let drag = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDragged,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ))
        drag.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        let unrelated = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ))
        unrelated.setIntegerValueField(.mouseEventButtonNumber, value: 4)

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: down))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseUp, event: up))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDragged, event: drag))
        XCTAssertNotNil(controller.interceptMouseEvent(type: .otherMouseDown, event: unrelated))
        XCTAssertEqual(invocationCount, 1, "Only mouse-down should toggle the Menu")
    }

    func testConfiguredMouseButtonSupportsClickAndDragReleaseSelection() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 2, clickDragEnabled: true)
        var invocationCount = 0
        var dragCount = 0
        var releaseCount = 0
        controller.onInvoke = { invocationCount += 1 }
        controller.onMouseDrag = { _ in dragCount += 1 }
        controller.onMouseDragRelease = { _ in releaseCount += 1 }

        let down = try mouseEvent(type: .otherMouseDown, buttonNumber: 2, location: .zero)
        let drag = try mouseEvent(type: .otherMouseDragged, buttonNumber: 2, location: CGPoint(x: 30, y: 0))
        let up = try mouseEvent(type: .otherMouseUp, buttonNumber: 2, location: CGPoint(x: 30, y: 0))

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: down))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDragged, event: drag))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseUp, event: up))
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(dragCount, 1)
        XCTAssertEqual(releaseCount, 1)
    }

    func testHeldAdditionalButtonTreatsMouseMovedEventsAsDragMotion() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: true)
        var dragCount = 0
        var releaseCount = 0
        var lastDragPoint: CGPoint?
        var releasePoint: CGPoint?
        controller.onMouseDrag = {
            dragCount += 1
            lastDragPoint = $0
        }
        controller.onMouseDragRelease = {
            releaseCount += 1
            releasePoint = $0
        }

        let down = try mouseEvent(type: .otherMouseDown, buttonNumber: 3, location: .zero)
        let moved = try mouseEvent(type: .mouseMoved, buttonNumber: 0, location: CGPoint(x: 40, y: 0))
        let up = try mouseEvent(type: .otherMouseUp, buttonNumber: 3, location: CGPoint(x: 40, y: 0))

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: down))
        XCTAssertNotNil(controller.interceptMouseEvent(type: .mouseMoved, event: moved))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseUp, event: up))
        XCTAssertEqual(dragCount, 1)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(lastDragPoint, NSEvent(cgEvent: moved)?.locationInWindow)
        XCTAssertEqual(releasePoint, NSEvent(cgEvent: up)?.locationInWindow)
    }

    func testHeldSideButtonRecoversGestureWhenDriverOmitsMouseDown() throws {
        let controller = GlobalTriggerController(
            mouseButtonStateCheck: { $0 == 3 }
        )
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: true)
        var invocationCount = 0
        var dragCount = 0
        var releaseCount = 0
        controller.onInvoke = { invocationCount += 1 }
        controller.onMouseDrag = { _ in dragCount += 1 }
        controller.onMouseDragRelease = { _ in releaseCount += 1 }

        let firstMove = try mouseEvent(type: .mouseMoved, buttonNumber: 0, location: CGPoint(x: 20, y: 0))
        let secondMove = try mouseEvent(type: .mouseMoved, buttonNumber: 0, location: CGPoint(x: 40, y: 0))
        let up = try mouseEvent(type: .otherMouseUp, buttonNumber: 3, location: CGPoint(x: 40, y: 0))

        XCTAssertNotNil(controller.interceptMouseEvent(type: .mouseMoved, event: firstMove))
        XCTAssertNotNil(controller.interceptMouseEvent(type: .mouseMoved, event: secondMove))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseUp, event: up))
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(dragCount, 1)
        XCTAssertEqual(releaseCount, 1)
    }

    func testRepeatedMouseDownDoesNotToggleAwayClickDragMenu() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 2, clickDragEnabled: true)
        var invocationCount = 0
        controller.onInvoke = { invocationCount += 1 }

        let firstDown = try mouseEvent(type: .otherMouseDown, buttonNumber: 2, location: .zero)
        let repeatedDown = try mouseEvent(type: .otherMouseDown, buttonNumber: 2, location: .zero)

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: firstDown))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: repeatedDown))
        XCTAssertEqual(invocationCount, 1)
    }

    func testHeldSideButtonCanRecoverFromNormalizedDragButtonNumber() throws {
        let controller = GlobalTriggerController(mouseButtonStateCheck: { $0 == 3 })
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: true)
        var invocationCount = 0
        var dragCount = 0
        controller.onInvoke = { invocationCount += 1 }
        controller.onMouseDrag = { _ in dragCount += 1 }

        let firstDrag = try mouseEvent(type: .otherMouseDragged, buttonNumber: 2, location: CGPoint(x: 20, y: 0))
        let secondDrag = try mouseEvent(type: .otherMouseDragged, buttonNumber: 2, location: CGPoint(x: 40, y: 0))

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDragged, event: firstDrag))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDragged, event: secondDrag))
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(dragCount, 1)
    }

    func testMouseClickWithoutDragLeavesRuntimeMenuOpenForPointAndClickUse() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3)
        var releaseCount = 0
        controller.onMouseDragRelease = { _ in releaseCount += 1 }

        let down = try mouseEvent(type: .otherMouseDown, buttonNumber: 3, location: .zero)
        let up = try mouseEvent(type: .otherMouseUp, buttonNumber: 3, location: CGPoint(x: 2, y: 2))

        _ = controller.interceptMouseEvent(type: .otherMouseDown, event: down)
        _ = controller.interceptMouseEvent(type: .otherMouseUp, event: up)

        XCTAssertEqual(releaseCount, 0)
    }

    func testClickAndDragSwitchDisablesReleaseSelection() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: false)
        var dragCount = 0
        var releaseCount = 0
        controller.onMouseDrag = { _ in dragCount += 1 }
        controller.onMouseDragRelease = { _ in releaseCount += 1 }

        _ = controller.interceptMouseEvent(
            type: .otherMouseDown,
            event: try mouseEvent(type: .otherMouseDown, buttonNumber: 3, location: .zero)
        )
        _ = controller.interceptMouseEvent(
            type: .otherMouseDragged,
            event: try mouseEvent(type: .otherMouseDragged, buttonNumber: 3, location: CGPoint(x: 40, y: 0))
        )
        _ = controller.interceptMouseEvent(
            type: .otherMouseUp,
            event: try mouseEvent(type: .otherMouseUp, buttonNumber: 3, location: CGPoint(x: 40, y: 0))
        )

        XCTAssertEqual(dragCount, 0)
        XCTAssertEqual(releaseCount, 0)
    }

    func testMouseButtonCaptureConsumesAndRecordsTheFirstButtonOutsideTheView() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3)
        var invocationCount = 0
        var capturedButton: Int?
        controller.onInvoke = { invocationCount += 1 }
        controller.setMouseButtonCaptureActive(true) { capturedButton = $0 }
        let event = try mouseEvent(type: .otherMouseDown, buttonNumber: 2, location: .zero)

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: event))
        XCTAssertEqual(capturedButton, 2)
        XCTAssertEqual(invocationCount, 0)
    }

    func testApplyingCapturedButtonDoesNotRestartTapOrInvokeRuntimeMenu() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3)
        var invocationCount = 0
        var capturedButton: Int?
        controller.onInvoke = { invocationCount += 1 }
        controller.setMouseButtonCaptureActive(true) { buttonNumber in
            capturedButton = buttonNumber
            _ = controller.apply(MenuTriggerConfiguration(mouseButton: buttonNumber))
        }
        let event = try mouseEvent(type: .otherMouseDown, buttonNumber: 2, location: .zero)

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: event))
        XCTAssertEqual(capturedButton, 2)
        XCTAssertEqual(controller.configuration.mouseButton, 2)
        XCTAssertEqual(invocationCount, 0)
    }

    func testMiddleButtonDoesNotUseHeldSideButtonRecoveryPath() throws {
        let controller = GlobalTriggerController(mouseButtonStateCheck: { _ in true })
        controller.configuration = MenuTriggerConfiguration(mouseButton: 2, clickDragEnabled: true)
        var invocationCount = 0
        controller.onInvoke = { invocationCount += 1 }
        let moved = try mouseEvent(type: .mouseMoved, buttonNumber: 0, location: CGPoint(x: 30, y: 0))

        XCTAssertNotNil(controller.interceptMouseEvent(type: .mouseMoved, event: moved))
        XCTAssertEqual(invocationCount, 0)
    }

    func testMouseTriggerCanPersistAndDescribeMiddleOrAdditionalButtons() throws {
        let suiteName = "SpinnetHostTests.MouseTriggerButton.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MenuTriggerConfiguration(mouseButton: 2, clickDragEnabled: true).save(to: defaults)

        XCTAssertEqual(MenuTriggerConfiguration(defaults: defaults).mouseButton, 2)
        XCTAssertTrue(MenuTriggerConfiguration(defaults: defaults).clickDragEnabled)
        XCTAssertEqual(MouseTriggerButton.displayName(for: 2), "Middle Button")
        XCTAssertEqual(MouseTriggerButton.displayName(for: 3), "Side Button 1")
        XCTAssertEqual(MouseTriggerButton.displayName(for: 7), "Mouse Button 8")
    }

    func testMouseTriggerRejectsLeftAndRightButtonsFromStoredOrNewConfiguration() throws {
        let suiteName = "SpinnetHostTests.MouseTriggerValidation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0, forKey: "trigger.mouse-button")

        XCTAssertEqual(
            MenuTriggerConfiguration(mouseButton: 1).mouseButton,
            MenuTriggerConfiguration.defaultMouseButton
        )
        XCTAssertEqual(
            MenuTriggerConfiguration(defaults: defaults).mouseButton,
            MenuTriggerConfiguration.defaultMouseButton
        )
    }

    func testMouseInputConflictDetectorRecognizesHelperAndDeduplicatesMainApplication() {
        let conflicts = MouseInputConflictDetector.detect(runningApplications: [
            RunningApplicationIdentity(
                bundleIdentifier: "com.nuebling.mac-mouse-fix.helper",
                localizedName: "Mac Mouse Fix Helper"
            ),
            RunningApplicationIdentity(
                bundleIdentifier: "com.nuebling.mac-mouse-fix",
                localizedName: "Mac Mouse Fix"
            )
        ], mouseButton: 3, claimedButtonsByDriver: ["mac-mouse-fix": [3]])

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.applicationName, "Mac Mouse Fix")
        XCTAssertTrue(conflicts.first?.guidance.contains("Click and Drag") == true)
    }

    func testMouseInputConflictDetectorDoesNotWarnWithoutVerifiedButtonClaim() {
        let conflicts = MouseInputConflictDetector.detect(runningApplications: [
            RunningApplicationIdentity(
                bundleIdentifier: "com.lujjjh.LinearMouse",
                localizedName: nil
            ),
            RunningApplicationIdentity(
                bundleIdentifier: nil,
                localizedName: "BetterTouchTool"
            ),
            RunningApplicationIdentity(
                bundleIdentifier: nil,
                localizedName: "Not BetterTouchTool"
            )
        ], mouseButton: 3, claimedButtonsByDriver: [:])

        XCTAssertTrue(conflicts.isEmpty)
    }

    func testSettingsModelRefreshesRunningMouseInputConflicts() throws {
        var runningApplications: [RunningApplicationIdentity] = []
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            mouseInputConflictCheck: { mouseButton in
                MouseInputConflictDetector.detect(
                    runningApplications: runningApplications,
                    mouseButton: mouseButton,
                    claimedButtonsByDriver: ["mac-mouse-fix": [3]]
                )
            }
        )
        XCTAssertTrue(model.mouseInputConflicts.isEmpty)

        runningApplications = [RunningApplicationIdentity(
            bundleIdentifier: "com.nuebling.mac-mouse-fix.helper",
            localizedName: nil
        )]
        model.refreshMouseInputConflicts()

        XCTAssertEqual(model.mouseInputConflicts.map(\.applicationName), ["Mac Mouse Fix"])
    }

    func testMacMouseFixParserFindsOnlyCurrentRemapsForTheSelectedButton() throws {
        let plist: [String: Any] = [
            "General": ["buttonKillSwitch": false],
            "Constants": [
                "configVersion": 24,
                "defaultRemaps": [["trigger": ["button": 5]]]
            ],
            "Remaps": [
                ["trigger": ["button": 4, "duration": "click"]],
                [
                    "trigger": "dragTrigger",
                    "modifiers": ["buttonModifiers": [["button": 4, "level": 1]]]
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        XCTAssertEqual(MouseInputConflictDetector.macMouseFixClaimedButtons(from: data), [3])
    }

    func testMacMouseFixParserHonorsDisabledButtons() throws {
        let plist: [String: Any] = [
            "Constants": ["configVersion": 24],
            "General": ["buttonKillSwitch": true],
            "Remaps": [["trigger": ["button": 4]]]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        XCTAssertTrue(MouseInputConflictDetector.macMouseFixClaimedButtons(from: data).isEmpty)
    }

    func testMacMouseFixParserFailsOpenForUnknownConfigurationVersion() throws {
        let plist: [String: Any] = [
            "Constants": ["configVersion": 25],
            "General": ["buttonKillSwitch": false],
            "Remaps": [["trigger": ["button": 4]]]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        XCTAssertTrue(MouseInputConflictDetector.macMouseFixClaimedButtons(from: data).isEmpty)
    }

    func testRuntimeMenuCommitsTheHoveredItemForAReleaseGesture() throws {
        let actionID = ActionID("gesture-action")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: actionID),
            primaryAction: MenuActionPresentation(
                actionID: actionID,
                title: "Gesture Action",
                availability: .available
            ),
            alternateActions: []
        )
        let view = RadialMenuView(items: [item])
        var selectedIndex: Int?
        view.onPrimarySelection = { selectedIndex = $0 }

        view.updateRuntimeSelection(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY + 90))
        view.commitRuntimeSelection()

        XCTAssertEqual(selectedIndex, 0)
    }

    func testAllEmptyRuntimeMenuOpensAndEmptySlotActivationOnlyGivesFeedback() throws {
        let runtimeMenu = MenuPresentationController(items: [.empty, .empty, .empty])
        var emptySlotIndex: Int?
        var actionCount = 0
        runtimeMenu.onEmptySlotActivated = { emptySlotIndex = $0 }
        runtimeMenu.onPrimaryAction = { _ in actionCount += 1 }
        let visibleFrame = try XCTUnwrap(NSScreen.main).visibleFrame
        let pointer = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)

        runtimeMenu.open(at: pointer)
        XCTAssertTrue(runtimeMenu.isOpen)

        runtimeMenu.activateSlot(at: 1)

        XCTAssertFalse(runtimeMenu.isOpen)
        XCTAssertEqual(emptySlotIndex, 1)
        XCTAssertEqual(actionCount, 0)
    }

    func testSettingsSlotEditSurvivesRestartAndKeepsRuntimeAngularOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetRuntimeWorkflow-\(UUID().uuidString)")
        let store = HostConfigurationStore(
            fileURL: directory.appendingPathComponent("configuration.json")
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.onConfigurationChanged = { try? store.save($0) }

        model.addEmptySlot()

        let restartedConfiguration = try XCTUnwrap(store.load())
        let runtimeSlots = MenuPresentationFactory.makeSlots(
            configuration: restartedConfiguration,
            availability: { _ in .available }
        )
        let runtimeMenu = MenuPresentationController(items: runtimeSlots)
        var invokedActionID: ActionID?
        var emptySlotIndex: Int?
        runtimeMenu.onPrimaryAction = { invokedActionID = $0 }
        runtimeMenu.onEmptySlotActivated = { emptySlotIndex = $0 }
        let visibleFrame = try XCTUnwrap(NSScreen.main).visibleFrame
        let pointer = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        let layout = MenuAppearanceConfiguration().layout(slotCount: runtimeSlots.count)

        runtimeMenu.open(at: pointer)
        runtimeMenu.finishGesture(at: layout.itemCenter(index: 0, center: pointer))
        XCTAssertEqual(invokedActionID, ActionID("open-url"))

        runtimeMenu.open(at: pointer)
        runtimeMenu.finishGesture(at: layout.itemCenter(index: 1, center: pointer))
        XCTAssertEqual(emptySlotIndex, 1)
        XCTAssertEqual(invokedActionID, ActionID("open-url"))
        XCTAssertFalse(runtimeMenu.isOpen)
    }

    func testNewHostFeedbackReplacesThePreviousDismissalTimer() {
        let presenter = HostFeedbackPresenter(displayDuration: 0.05)
        presenter.showMessage("First")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        presenter.showMessage("Second")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        XCTAssertTrue(presenter.presentationSnapshot.isVisible)
        XCTAssertEqual(presenter.presentationSnapshot.message, "Second")

        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertFalse(presenter.presentationSnapshot.isVisible)
    }

    func testAccessibilityPromptIsRequestedOnlyOnceWhileSystemTrustIsReadLive() {
        var isTrusted = false
        var requestCount = 0
        let permission = AccessibilityPermissionController(
            isTrusted: { isTrusted },
            request: { requestCount += 1 }
        )

        permission.requestOnceIfNeeded()
        permission.requestOnceIfNeeded()

        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(permission.isAuthorized)

        isTrusted = true

        XCTAssertTrue(permission.isAuthorized)
        permission.requestOnceIfNeeded()
        XCTAssertEqual(requestCount, 1)
    }

    func testPrivacySettingsRefreshesAccessibilityFromTheSystemSourceOfTruth() throws {
        var isTrusted = false
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            accessibilityPermissionCheck: { isTrusted }
        )
        XCTAssertFalse(model.accessibilityPermissionGranted)

        isTrusted = true
        model.refreshSystemPermissionStatus()

        XCTAssertTrue(model.accessibilityPermissionGranted)
    }

    private func makeController(emptySlotCount: Int = 0) throws -> SettingsWindowController {
        let editor = try makeEditor()
        for _ in 0..<emptySlotCount {
            try editor.addEmptySlot()
        }
        let controller = SettingsWindowController(editor: editor)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    private func mouseEvent(
        type: CGEventType,
        buttonNumber: Int,
        location: CGPoint
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        ))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber))
        return event
    }

    private func makeEditor(
        capabilities: [PluginCapability] = []
    ) throws -> HostConfigurationEditor {
        let registry = PluginRegistry()
        let manifest = try PluginManifest(
            id: PluginID("com.spinnet.fixture"),
            name: "Fixture",
            version: "1.0.0",
            capabilities: capabilities,
            commands: [CommandDeclaration(
                id: CommandID("fixture.open"),
                title: "Open URL",
                hostCommand: .openURL
            ), CommandDeclaration(
                id: CommandID("fixture.transform_text"),
                title: "Transform Text",
                execution: .javascript,
                isConfigurable: false,
                script: "transform-text.js"
            )],
            preset: MenuItemPresetDeclaration(
                readiness: .readyToUse,
                isConfigurable: true,
                defaultPrimaryCommandID: CommandID("fixture.open"),
                defaultAlternateCommandIDs: [CommandID("fixture.transform_text")],
                defaultInputs: [CommandID("fixture.open"): .string("https://example.com")]
            )
        )
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        ))
        let action = try ActionConfiguration(
            id: ActionID("open-url"),
            pluginID: manifest.id,
            command: manifest.commands[0],
            input: .string("https://example.com")
        )
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(primaryActionID: action.id)
            ])
        )
        return HostConfigurationEditor(registry: registry, configuration: configuration)
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let bounds = view.bounds
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: representation)
        return representation
    }

    private func renderedAccessibilityLabels(in root: NSObject) -> Set<String> {
        var labels = Set<String>()
        var visited = Set<ObjectIdentifier>()

        func visit(_ value: Any) {
            guard let object = value as? NSObject else { return }
            let identifier = ObjectIdentifier(object)
            guard visited.insert(identifier).inserted else { return }
            let attributeValue = NSSelectorFromString("accessibilityAttributeValue:")
            let accessibilityLabel = NSSelectorFromString("accessibilityLabel")
            let accessibilityChildren = NSSelectorFromString("accessibilityChildren")
            var descriptions: [String] = object.responds(to: attributeValue)
                ? [NSAccessibility.Attribute.description, .title].compactMap { attribute in
                    object.perform(attributeValue, with: attribute)?
                        .takeUnretainedValue() as? String
                }
                : []
            if object.responds(to: accessibilityLabel),
               let label = object.perform(accessibilityLabel)?.takeUnretainedValue() as? String {
                descriptions.append(label)
            }
            var children = object.responds(to: attributeValue)
                ? object.perform(attributeValue, with: NSAccessibility.Attribute.children)?
                    .takeUnretainedValue() as? [Any]
                : nil
            if children == nil, object.responds(to: accessibilityChildren) {
                children = object.perform(accessibilityChildren)?
                    .takeUnretainedValue() as? [Any]
            }
            labels.formUnion(descriptions.filter { !$0.isEmpty })
            children?.forEach(visit)
        }

        visit(root)
        return labels
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard let lhs = lhs.usingColorSpace(.deviceRGB),
              let rhs = rhs.usingColorSpace(.deviceRGB) else {
            return 0
        }
        return max(
            abs(lhs.redComponent - rhs.redComponent),
            abs(lhs.greenComponent - rhs.greenComponent),
            abs(lhs.blueComponent - rhs.blueComponent)
        )
    }
}
