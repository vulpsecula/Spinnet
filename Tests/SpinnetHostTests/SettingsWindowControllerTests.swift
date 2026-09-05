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

    func testEditorContextMenuShowsFocusedSlotDetailsAndDeletesTheSlot() throws {
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

    func testMenuItemMovesOnlyToAnEmptySlotAndDeletionCanBeUndone() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()

        XCTAssertTrue(model.moveMenuItem(from: 0, to: 1))
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertEqual(
            model.editor.configuration.menu.slots[1].item?.primaryActionID,
            ActionID("open-url")
        )

        XCTAssertTrue(model.placePreset(pluginID: "com.spinnet.fixture", at: 0))
        let occupiedConfiguration = model.editor.configuration

        XCTAssertFalse(model.moveMenuItem(from: 1, to: 0))
        XCTAssertEqual(model.editor.configuration, occupiedConfiguration)
        XCTAssertEqual(model.placementMessage, "Slot 1 is occupied. Free it before moving a Menu Item there.")

        model.deleteMenuItem(at: 1)

        XCTAssertNil(model.editor.configuration.menu.slots[1].item)
        XCTAssertEqual(model.editor.configuration.actions.count, 1)

        model.undoSlotEdit()

        XCTAssertEqual(model.editor.configuration, occupiedConfiguration)
    }

    func testDeleteSelectedContentClearsAnItemThenRemovesAnEmptySlot() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        model.selectMenuItem(at: 0)

        model.deleteSelectedContent()

        XCTAssertNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertTrue(model.editor.configuration.actions.isEmpty)
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 2)

        model.deleteSelectedContent()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)
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

    func testRenderedSettingsExposesDeleteKeyboardEquivalent() throws {
        let occupiedEditor = try makeEditor()
        let occupiedController = SettingsWindowController(editor: occupiedEditor)
        defer { occupiedController.close() }
        let occupiedContent = try XCTUnwrap(occupiedController.window?.contentView)
        occupiedController.present()
        occupiedContent.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        _ = renderedAccessibilityLabels(in: occupiedContent)

        for label in [
            "Replace selected Slot with Fixture",
            "Edit Menu Item in Slot 1",
            "Clear Menu Item from Slot 1",
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
        XCTAssertNil(occupiedEditor.configuration.menu.slots[0].item)

        let emptyController = try makeController(emptySlotCount: 1)
        defer { emptyController.close() }
        XCTAssertTrue(
            emptyController.presentationSnapshot.accessibleNames.contains("Add Fixture to selected Slot")
        )
    }

    func testDeleteSelectedContentRemovesAnEmptySlotAtTheSettingsWorkflowSeam() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        model.selectMenuItem(at: 1)
        var savedConfiguration: HostConfiguration?
        model.onConfigurationChanged = { savedConfiguration = $0 }

        model.deleteSelectedContent()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertEqual(savedConfiguration, model.editor.configuration)
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

    func testUndoRestoresTheExactOccupiedSlotAfterDeleteKeyClearsIt() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.addEmptySlot()
        model.selectMenuItem(at: 0)
        model.deleteSelectedContent()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 2)
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
            )],
            preset: MenuItemPresetDeclaration(
                readiness: .readyToUse,
                isConfigurable: true,
                defaultPrimaryCommandID: CommandID("fixture.open"),
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
