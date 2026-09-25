import AppKit
import Carbon
import SpinnetCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import SpinnetHost

/// Composing a Menu from Settings: placing Presets from the Library, the
/// Configuration Sheet for Setup-Required ones, replacement and deletion
/// confirmation, reordering, and the undo history over all of it.
final class MenuEditorWorkflowTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testSetupRequiredPresetStaysEmptyUntilValidConfigurationIsSaved() throws {
        let registry = PluginRegistry()
        let packages = try ShippedPluginPackages.hostCommandPlugins()
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

        XCTAssertFalse(model.menuEditor.placePreset(pluginID: applicationPreset.manifest.id.rawValue, at: 0))
        XCTAssertEqual(
            model.menuEditor.pendingPresetSetup,
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
        model.menuEditor.savePresetSetup(
            candidate,
            for: try XCTUnwrap(model.menuEditor.pendingPresetSetup)
        )

        XCTAssertNotNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertNil(model.menuEditor.pendingPresetSetup)
        XCTAssertNil(model.menuEditor.editingMenuIndex)
        XCTAssertTrue(model.menuEditor.canUndoSlotEdit)
    }

    func testCancellingSetupRequiredPresetLeavesItsSlotEmpty() throws {
        let registry = PluginRegistry()
        let packages = try ShippedPluginPackages.hostCommandPlugins()
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

        XCTAssertFalse(model.menuEditor.placePreset(pluginID: applicationPreset.manifest.id.rawValue, at: 0))
        XCTAssertNotNil(model.menuEditor.pendingPresetSetup)

        model.menuEditor.cancelPresetSetup()

        XCTAssertNil(model.menuEditor.pendingPresetSetup)
        XCTAssertNil(model.menuEditor.editingMenuIndex)
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertTrue(model.editor.configuration.actions.isEmpty)
    }

    /// Dropping a Preset from the Library between Slots adds a Slot for it
    /// there, and one undo takes the whole drop back.
    func testDroppingAPresetAddsASlotForItThatOneUndoRemoves() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        let before = model.editor.configuration
        let idsBefore = model.menuEditor.slotIDs

        XCTAssertTrue(model.menuEditor.insertPreset(pluginID: "com.spinnet.fixture", at: 1))

        let slots = model.editor.configuration.menu.slots
        XCTAssertEqual(slots.count, before.menu.slots.count + 1)
        XCTAssertNotNil(slots[1].item)
        XCTAssertEqual(model.menuEditor.slotIDs.count, idsBefore.count + 1)
        XCTAssertEqual(model.menuEditor.selectedMenuIndex, 1)
        XCTAssertEqual(model.menuEditor.placementMessage, "Menu Item added in a new Slot 2.")

        model.menuEditor.editingMenuIndex = nil
        model.menuEditor.undoSlotEdit()
        XCTAssertEqual(model.editor.configuration, before)
        XCTAssertEqual(model.menuEditor.slotIDs, idsBefore)
        XCTAssertFalse(model.menuEditor.canUndoSlotEdit)

        model.menuEditor.redoSlotEdit()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, before.menu.slots.count + 1)
        XCTAssertEqual(model.menuEditor.slotIDs.count, idsBefore.count + 1)
    }

    /// A Setup-Required Preset gets its Slot only once its setup is saved;
    /// cancelling the setup leaves the Menu as it was.
    func testDroppingASetupRequiredPresetKeepsItsNewSlotOnlyIfTheSetupIsSaved() throws {
        let registry = PluginRegistry()
        let packages = try ShippedPluginPackages.hostCommandPlugins()
        for package in packages { try registry.register(package) }
        let configuration = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        let model = SettingsWindowModel(
            editor: HostConfigurationEditor(registry: registry, configuration: configuration),
            metadata: .current,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )
        let applicationPreset = try XCTUnwrap(packages.first { $0.manifest.name == "Open Application" })

        XCTAssertFalse(model.menuEditor.insertPreset(pluginID: applicationPreset.manifest.id.rawValue, at: 1))
        XCTAssertEqual(model.menuEditor.pendingPresetSetup?.slotIndex, 1)
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 2)

        model.menuEditor.cancelPresetSetup()

        XCTAssertEqual(model.editor.configuration, configuration)
        XCTAssertEqual(model.menuEditor.slotIDs.count, 1)
        XCTAssertFalse(model.menuEditor.canUndoSlotEdit)
    }

    func testRemovingAPluginFromTheLibraryConfirmsFirstAndKeepsTheMenuIntact() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        var removed: [PluginID] = []
        model.menuEditor.removePlugin = { removed.append($0) }
        let preset = try XCTUnwrap(model.editor.menuItemPresets.first)
        let menuBefore = model.editor.configuration.menu

        model.menuEditor.requestPluginRemoval(preset)
        XCTAssertEqual(model.menuEditor.presetPendingRemoval?.pluginID, preset.pluginID)
        XCTAssertTrue(removed.isEmpty, "Removal must wait for the confirmation")

        model.menuEditor.confirmPluginRemoval()

        XCTAssertEqual(removed, [preset.pluginID])
        XCTAssertNil(model.menuEditor.presetPendingRemoval)
        XCTAssertEqual(model.editor.configuration.menu, menuBefore)
    }

    func testCancellingAPluginRemovalRemovesNothing() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        var removed: [PluginID] = []
        model.menuEditor.removePlugin = { removed.append($0) }
        let preset = try XCTUnwrap(model.editor.menuItemPresets.first)

        model.menuEditor.requestPluginRemoval(preset)
        model.menuEditor.cancelPluginRemoval()
        model.menuEditor.confirmPluginRemoval()

        XCTAssertTrue(removed.isEmpty)
        XCTAssertNil(model.menuEditor.presetPendingRemoval)
    }

    /// Open URL runs a Host Command, and is still a Plugin the user may remove.
    func testThePluginsThatRunHostCommandsCanBeRemovedLikeAnyOther() throws {
        let registry = PluginRegistry()
        for package in try ShippedPluginPackages.hostCommandPlugins() { try registry.register(package) }
        let model = SettingsWindowModel(
            editor: HostConfigurationEditor(
                registry: registry,
                configuration: try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
            ),
            metadata: .current
        )
        var removed: [PluginID] = []
        model.menuEditor.removePlugin = { removed.append($0) }
        let openURL = try XCTUnwrap(model.editor.menuItemPresets.first { $0.name == "Open URL" })

        model.menuEditor.requestPluginRemoval(openURL)
        model.menuEditor.confirmPluginRemoval()

        XCTAssertEqual(removed, [PluginID("com.spinnet.builtin.open-url")])
    }

    func testAddingTheSamePresetTwiceKeepsMenuItemActionsIndependent() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.addEmptySlot()
        model.menuEditor.addEmptySlot()

        XCTAssertTrue(model.menuEditor.placePreset(pluginID: "com.spinnet.fixture", at: 1))
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
        model.menuEditor.saveMenuItemConfiguration(firstNamedCandidate)

        XCTAssertTrue(model.menuEditor.placePreset(pluginID: "com.spinnet.fixture", at: 2))
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
        model.menuEditor.requestEdit(at: 0)
        XCTAssertEqual(model.menuEditor.editingMenuIndex, 0)
        model.selectPage(.privacyAndPermissions)
        XCTAssertEqual(model.page, .menu)
        model.menuEditor.editingMenuIndex = nil
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
        model.menuEditor.saveMenuItemConfiguration(candidate)
        XCTAssertEqual(
            model.editor.configuration.actions.first?.input,
            .string("https://spinnet.dev")
        )
        model.menuEditor.undoSlotEdit()
        XCTAssertEqual(model.editor.configuration, original)
        model.menuEditor.redoSlotEdit()
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
        model.menuEditor.onConfigurationChanged = { savedConfiguration = $0 }

        model.menuEditor.addEmptySlot()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 2)
        XCTAssertEqual(model.menuEditor.selectedMenuIndex, 1)
        XCTAssertNil(model.editor.configuration.menu.slots[1].item)

        XCTAssertTrue(model.menuEditor.placePreset(pluginID: "com.spinnet.fixture", at: 1))
        XCTAssertNotNil(model.editor.configuration.menu.slots[1].item)
        XCTAssertEqual(model.menuEditor.editingMenuIndex, 1)
        XCTAssertEqual(savedConfiguration, model.editor.configuration)
    }

    func testPlacingAPluginPresetBindsItsDefaultAlternateActionToTheSlot() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.addEmptySlot()

        XCTAssertTrue(model.menuEditor.placePreset(pluginID: "com.spinnet.fixture", at: 1))

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
            origin: .bundled
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

        let presets = model.menuEditor.libraryPresets(matching: "")

        XCTAssertEqual(presets.map(\.name), ["Copy", "Search Tools"], "One list, by name")
        XCTAssertEqual(presets[1].commands.count, 2)
        XCTAssertEqual(presets[0].stateLabel, "Ready to Use")
        XCTAssertEqual(presets[0].configurationLabel, "No Configuration")
        XCTAssertEqual(presets[1].stateLabel, "Setup Required")
        XCTAssertEqual(presets[1].configurationLabel, "Configurable")
        XCTAssertEqual(
            model.menuEditor.libraryPresets(matching: "documentation").map(\.name),
            ["Search Tools"]
        )
        let emptyConfiguration = model.editor.configuration
        XCTAssertFalse(model.menuEditor.placePreset(pluginID: plugin.id.rawValue, at: 0))
        XCTAssertEqual(model.editor.configuration, emptyConfiguration)
        XCTAssertEqual(model.menuEditor.placementMessage, "Invalid Action: Preset requires setup")
        for accessibleName in [
            "Copy, Ready to Use, No Configuration, Commands: Copy Selected Text",
            "Search Tools, Setup Required, Configurable, Commands: Search the Web, Search Documentation"
        ] {
            XCTAssertTrue(model.accessibleNames.contains(accessibleName))
        }

        try registry.setEnabled(false, for: plugin.id)
        let unavailablePreset = try XCTUnwrap(
            model.menuEditor.libraryPresets(matching: "Search Tools").first
        )
        XCTAssertEqual(unavailablePreset.stateLabel, "Unavailable")
        XCTAssertTrue(unavailablePreset.accessibilityLabel.contains("Plugin is disabled"))
    }

    func testOccupiedSlotRequiresExplicitPresetReplacementAndUndoRestoresIt() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        let originalConfiguration = model.editor.configuration

        XCTAssertFalse(model.menuEditor.placePreset(pluginID: "com.spinnet.fixture", at: 0))
        XCTAssertEqual(model.editor.configuration, originalConfiguration)
        XCTAssertEqual(
            model.menuEditor.presetPendingReplacement,
            PendingPresetReplacement(pluginID: "com.spinnet.fixture", slotIndex: 0)
        )

        model.menuEditor.confirmPresetReplacement()

        XCTAssertNotEqual(model.editor.configuration, originalConfiguration)
        XCTAssertNil(model.menuEditor.presetPendingReplacement)
        XCTAssertTrue(model.menuEditor.canUndoSlotEdit)

        model.menuEditor.undoSlotEdit()

        XCTAssertEqual(model.editor.configuration, originalConfiguration)
    }

    func testOccupiedAndEmptySlotsReorderAlongShortestArcAndUndoRestoresIdentity() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.addEmptySlot()
        model.menuEditor.addEmptySlot()
        let original = model.editor.configuration
        let ids = model.menuEditor.slotIDs
        XCTAssertTrue(model.menuEditor.moveSlot(from: 0, to: 2))
        XCTAssertEqual(model.menuEditor.slotIDs, [ids[2], ids[1], ids[0]])
        XCTAssertEqual(model.editor.configuration.menu.slots[2], original.menu.slots[0])
        XCTAssertTrue(model.menuEditor.moveSlot(from: 0, to: 1))
        XCTAssertEqual(model.menuEditor.slotIDs, [ids[1], ids[2], ids[0]])
        model.menuEditor.undoSlotEdit()
        model.menuEditor.undoSlotEdit()
        XCTAssertEqual(model.menuEditor.slotIDs, ids)
        XCTAssertEqual(model.editor.configuration, original)
        model.menuEditor.redoSlotEdit()
        XCTAssertEqual(model.menuEditor.slotIDs, [ids[2], ids[1], ids[0]])
    }


    func testMenuItemAliasMovesWithTheMenuItem() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.addEmptySlot()
        try model.editor.renameMenuItem(at: 0, name: "Pinned")

        XCTAssertTrue(model.menuEditor.moveSlot(from: 0, to: 1))
        XCTAssertNil(model.editor.configuration.menu.slots[0].item?.alias)
        XCTAssertEqual(model.editor.configuration.menu.slots[1].item?.alias, "Pinned")
        XCTAssertEqual(model.menuEditor.menuSlots[1].title, "Pinned")
    }

    func testDeletionRequiresConfirmationAndRemovesTheWholeOccupiedSlot() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.addEmptySlot()
        model.menuEditor.selectMenuItem(at: 0)
        let original = model.editor.configuration
        model.menuEditor.requestSelectedSlotDeletion()
        XCTAssertEqual(model.editor.configuration, original)
        XCTAssertNotNil(model.menuEditor.slotPendingDeletion)
        model.menuEditor.cancelSlotDeletion()
        XCTAssertEqual(model.editor.configuration, original)
        model.menuEditor.requestSelectedSlotDeletion()
        model.menuEditor.confirmSlotDeletion()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)
        model.menuEditor.undoSlotEdit()
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
        model.menuEditor.onConfigurationChanged = { try? store.save($0) }

        XCTAssertTrue(model.menuEditor.placePreset(pluginID: manifest.id.rawValue, at: 0))

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
        XCTAssertNil(model.menuEditor.editingMenuIndex)
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
        model.menuEditor.addEmptySlot()

        XCTAssertTrue(model.accessibleNames.contains("Add Fixture to selected Slot"))
        XCTAssertFalse(model.accessibleNames.contains("Replace selected Slot with Fixture"))

        model.menuEditor.selectMenuItem(at: 0)

        XCTAssertFalse(model.accessibleNames.contains("Add Fixture to selected Slot"))
        XCTAssertFalse(model.accessibleNames.contains("Replace selected Slot with Fixture"))
    }

    func testDeleteSelectedContentRemovesAnEmptySlotAtTheSettingsWorkflowSeam() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.addEmptySlot()
        model.menuEditor.selectMenuItem(at: 1)
        var savedConfiguration: HostConfiguration?
        model.menuEditor.onConfigurationChanged = { savedConfiguration = $0 }

        model.menuEditor.requestSelectedSlotDeletion()
        XCTAssertNil(savedConfiguration)
        model.menuEditor.confirmSlotDeletion()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertEqual(savedConfiguration, model.editor.configuration)
    }

    func testPendingDeletionTracksSlotIdentityAcrossReorderAndRejectsStaleDrags() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.addEmptySlot()
        let occupiedID = model.menuEditor.slotIDs[0]
        XCTAssertTrue(model.menuEditor.requestSlotDeletion(at: 0))
        XCTAssertTrue(model.menuEditor.moveSlot(from: 0, to: 1))
        model.menuEditor.confirmSlotDeletion()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertFalse(model.menuEditor.moveSlot(id: occupiedID, to: 0))
        XCTAssertFalse(model.menuEditor.requestSlotDeletion(id: occupiedID))
        XCTAssertFalse(model.menuEditor.requestSlotDeletion(at: 0))
        XCTAssertNil(model.menuEditor.slotPendingDeletion)
        model.menuEditor.undoSlotEdit()
        XCTAssertEqual(model.menuEditor.slotIDs[1], occupiedID)
        model.menuEditor.undoSlotEdit()
        XCTAssertEqual(model.menuEditor.slotIDs[0], occupiedID)
    }


    func testSlotEditsUndoRedoAndPersistThroughTheSettingsWorkflowSeam() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetSlotWorkflow-\(UUID().uuidString)")
        let store = HostConfigurationStore(
            fileURL: directory.appendingPathComponent("configuration.json")
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.onConfigurationChanged = { try? store.save($0) }

        model.menuEditor.addEmptySlot()
        XCTAssertTrue(model.menuEditor.canUndoSlotEdit)
        XCTAssertEqual(try store.load()?.menu.slots.count, 2)

        model.menuEditor.undoSlotEdit()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertEqual(try store.load()?.menu.slots.count, 1)
        XCTAssertTrue(model.menuEditor.canRedoSlotEdit)

        model.menuEditor.redoSlotEdit()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 2)
        XCTAssertNil(model.editor.configuration.menu.slots[1].item)
        XCTAssertEqual(try store.load(), model.editor.configuration)
    }

    func testUndoRestoresTheExactOccupiedSlotAfterConfirmedDeletion() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.addEmptySlot()
        model.menuEditor.selectMenuItem(at: 0)
        model.menuEditor.requestSelectedSlotDeletion()
        model.menuEditor.confirmSlotDeletion()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 1)
        XCTAssertNil(model.editor.configuration.menu.slots[0].item)

        model.menuEditor.undoSlotEdit()

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
            model.menuEditor.addEmptySlot()
        }

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 12)
        XCTAssertTrue(model.editor.configuration.menu.slots.dropFirst().allSatisfy { $0.item == nil })
    }

    func testPlacementAndSlotAdditionUndoAsSeparateCompositionEdits() throws {
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.addEmptySlot()
        model.menuEditor.addEmptySlot()
        XCTAssertTrue(model.menuEditor.canUndoSlotEdit)

        XCTAssertTrue(model.menuEditor.placePreset(pluginID: "com.spinnet.fixture", at: 2))

        XCTAssertTrue(model.menuEditor.canUndoSlotEdit)
        model.menuEditor.undoSlotEdit()
        XCTAssertEqual(model.editor.configuration.menu.slots.count, 3)
        XCTAssertNotNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertNil(model.editor.configuration.menu.slots[1].item)
        XCTAssertNil(model.editor.configuration.menu.slots[2].item)

        model.menuEditor.undoSlotEdit()

        XCTAssertEqual(model.editor.configuration.menu.slots.count, 2)
        XCTAssertNotNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertNil(model.editor.configuration.menu.slots[1].item)
    }
}
