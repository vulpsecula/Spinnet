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
            "Open macOS System Settings"
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
        XCTAssertEqual(selectedIndex, 0, "Hovering a Slot should expose its editor in place")

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

        XCTAssertEqual(selectedIndex, 0)
        XCTAssertEqual(editedIndex, 0)
        XCTAssertEqual(primaryExecutionCount, 0)
        XCTAssertEqual(alternateExecutionCount, 0)
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

        XCTAssertEqual(runtimeMenu.presentationSnapshot.theme, "Dark")
        XCTAssertEqual(runtimeMenu.presentationSnapshot.accent, "Purple")
        XCTAssertEqual(runtimeMenu.presentationSnapshot.menuSize, "Large")
        XCTAssertGreaterThan(runtimeMenu.presentationSnapshot.outerRadius, 142)
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

    func testEverySettingsPageRendersAtTheWindowBoundary() throws {
        let defaults = UserDefaults.standard
        let appearanceKeys = ["appearance.theme", "appearance.accent", "appearance.menu-size"]
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

        XCTAssertEqual(appliedAppearance?.theme, "Dark")
        XCTAssertEqual(appliedAppearance?.accent, "Purple")
        XCTAssertEqual(appliedAppearance?.menuSize, "Large")
        XCTAssertEqual(defaults.string(forKey: "appearance.theme"), "Dark")
        XCTAssertEqual(defaults.string(forKey: "appearance.accent"), "Purple")
        XCTAssertEqual(defaults.string(forKey: "appearance.menu-size"), "Large")

        let restored = SettingsWindowModel(
            editor: editor,
            metadata: .current,
            defaults: defaults
        )
        XCTAssertEqual(restored.appearanceTheme, "Dark")
        XCTAssertEqual(restored.appearanceAccent, "Purple")
        XCTAssertEqual(restored.appearanceMenuSize, "Large")
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
        controller.onMouseDrag = { dragCount += 1 }
        controller.onMouseDragRelease = { releaseCount += 1 }

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

    func testMouseClickWithoutDragLeavesRuntimeMenuOpenForPointAndClickUse() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3)
        var releaseCount = 0
        controller.onMouseDragRelease = { releaseCount += 1 }

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
        controller.onMouseDrag = { dragCount += 1 }
        controller.onMouseDragRelease = { releaseCount += 1 }

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

    func testMouseButtonCaptureTemporarilyPassesTheConfiguredButtonThrough() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3)
        var invocationCount = 0
        controller.onInvoke = { invocationCount += 1 }
        controller.setMouseButtonCaptureActive(true)
        let event = try mouseEvent(type: .otherMouseDown, buttonNumber: 3, location: .zero)

        XCTAssertNotNil(controller.interceptMouseEvent(type: .otherMouseDown, event: event))
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

    private func makeEditor() throws -> HostConfigurationEditor {
        let registry = PluginRegistry()
        let manifest = try PluginManifest(
            id: PluginID("com.spinnet.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [CommandDeclaration(
                id: CommandID("fixture.open"),
                title: "Open URL",
                hostCommand: .openURL
            )]
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
