import XCTest
import SpinnetCore
@testable import SpinnetHost

/// The Menu Editor's App switcher and App Overrides (#113): choosing an App,
/// overriding, emptying and resetting its Slots, and removing it, observed
/// as what the editor shows and what is saved.
final class MenuEditorAppOverrideTests: XCTestCase {
    private let safari = AppBundleIdentifier(validating: "com.apple.Safari")!
    private let finder = AppBundleIdentifier(validating: "com.apple.finder")!
    private let fixture = "com.spinnet.fixture"
    private let other = "com.spinnet.other"

    func testTheSwitcherStartsAtTheDefaultMenuAndAddsOnlyAppsWithABundleIdentifier() throws {
        let model = try makeModel()

        XCTAssertNil(model.editedApp)
        XCTAssertEqual(model.switcherApps, [])
        XCTAssertFalse(model.addApp(bundleIdentifier: nil, name: "Unbundled"))
        XCTAssertNil(model.editedApp)
        XCTAssertEqual(model.placementMessage, "Apps without a bundle identifier cannot be added.")

        XCTAssertTrue(model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari"))

        XCTAssertEqual(model.editedApp, MenuEditorApp(bundleIdentifier: safari, name: "Safari"))
        XCTAssertEqual(model.switcherApps.map(\.name), ["Safari"])
    }

    func testAnAppsUnoverriddenSlotsShowTheDefaultMenuItemsAsInherited() throws {
        let model = try makeModel()
        let defaultTitles = model.menuSlots.map(\.title)

        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

        XCTAssertEqual(model.menuSlots.map(\.title), defaultTitles)
        XCTAssertEqual(model.menuSlots.map(\.appOverride), [.inherited, .inherited, .inherited])
        model.editApp(nil)
        XCTAssertEqual(model.menuSlots.map(\.appOverride), [nil, nil, nil])
    }

    func testAddingAPresetForAnAppOverridesOnlyThatAppsSlotAndIsSaved() throws {
        let model = try makeModel()
        var saved: [HostConfiguration] = []
        model.onConfigurationChanged = { saved.append($0) }
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

        XCTAssertTrue(model.placePreset(pluginID: fixture, at: 1))

        XCTAssertEqual(model.menuSlots[1].appOverride, .overridden)
        XCTAssertFalse(model.menuSlots[1].isEmpty)
        let configuration = try XCTUnwrap(saved.last)
        XCTAssertNotNil(configuration.menu.slots(for: safari)[1].item)
        XCTAssertNil(configuration.menu.slots(for: nil)[1].item)
        XCTAssertNil(configuration.menu.slots(for: finder)[1].item)

        model.undoSlotEdit()
        XCTAssertEqual(model.menuSlots[1].appOverride, .inherited)
        XCTAssertEqual(saved.last?.menu.overriddenApps, [])
    }

    func testReplacingAnInheritedMenuItemForAnAppAsksFirstAndKeepsTheDefault() throws {
        let model = try makeModel()
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        let defaultItem = model.editor.configuration.menu.slots(for: nil)[0].item

        XCTAssertFalse(model.placePreset(pluginID: fixture, at: 0))
        model.confirmPresetReplacement()

        XCTAssertEqual(model.menuSlots[0].appOverride, .overridden)
        XCTAssertEqual(model.editor.configuration.menu.slots(for: nil)[0].item, defaultItem)
        XCTAssertNotEqual(model.editor.configuration.menu.slots(for: safari)[0].item, defaultItem)
    }

    func testAnAppCanEmptyASlotAndResetItToTheDefault() throws {
        let model = try makeModel()
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

        model.emptySlot(at: 0)
        XCTAssertTrue(model.menuSlots[0].isEmpty)
        XCTAssertEqual(model.menuSlots[0].appOverride, .overridden)
        XCTAssertEqual(model.editor.configuration.menu.slots(for: safari)[0].item, nil)

        model.resetSlotToDefault(at: 0)
        XCTAssertFalse(model.menuSlots[0].isEmpty)
        XCTAssertEqual(model.menuSlots[0].appOverride, .inherited)
        XCTAssertEqual(model.editor.configuration.menu.overriddenApps, [])
    }

    func testRemovingAnAppRemovesItsOverridesAndReturnsToTheDefaultMenu() throws {
        let model = try makeModel()
        var saved: [HostConfiguration] = []
        model.onConfigurationChanged = { saved.append($0) }
        model.addApp(bundleIdentifier: "com.apple.finder", name: "Finder")
        model.emptySlot(at: 0)
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        model.emptySlot(at: 0)

        model.removeEditedApp()

        XCTAssertNil(model.editedApp)
        XCTAssertEqual(model.switcherApps.map(\.name), ["Finder"])
        XCTAssertEqual(saved.last?.menu.overriddenApps, [finder])
        model.undoSlotEdit()
        XCTAssertEqual(Set(model.editor.configuration.menu.overriddenApps), [finder, safari])
    }

    func testAppsWithSavedOverridesAreListedByName() throws {
        let editor = try makeEditor()
        try editor.emptySlot(at: 2, for: safari)

        let model = MenuEditorModel(editor: editor, appName: { $0 == self.safari ? "Safari" : nil })

        XCTAssertNil(model.editedApp)
        XCTAssertEqual(model.switcherApps, [MenuEditorApp(bundleIdentifier: safari, name: "Safari")])
    }

    func testSlotsAreArrangedOnlyInTheDefaultMenu() throws {
        let model = try makeModel()
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        let before = model.editor.configuration

        model.addEmptySlot()
        XCTAssertFalse(model.requestSlotDeletion(at: 1))
        XCTAssertFalse(model.insertPreset(pluginID: fixture, at: 1))
        XCTAssertFalse(model.moveSlot(from: 0, to: 1))

        XCTAssertEqual(model.editor.configuration, before)
        XCTAssertEqual(model.menuSlots.count, 3)
        XCTAssertFalse(model.canArrangeSlots)
    }

    func testSavingAnInheritedMenuItemUnchangedIsNotAnEdit() throws {
        let model = try makeModel()
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        let before = model.editor.configuration
        let app = model.editedAppID

        // What the Configuration Sheet saves when nothing was changed.
        let candidate = try model.editor.configuredMenuItem(
            at: 0, pluginID: PluginID(fixture), primaryCommandID: CommandID("fixture.open"),
            inputs: [CommandID("fixture.open"): .string("https://example.com")],
            preserveUnselectedAlternates: true, for: app
        )
        model.saveMenuItemConfiguration(try model.editor.aliasedMenuItem(in: candidate, at: 0, to: nil, for: app))

        XCTAssertEqual(model.editor.configuration, before)
        XCTAssertEqual(model.menuSlots[0].appOverride, .inherited)
        XCTAssertFalse(model.canUndoSlotEdit)
    }

    func testAPlacementWaitingForConnectionsIsDroppedWhenAnotherAppIsChosen() throws {
        let model = try makeModel()
        var finish: ((Bool) -> Void)?
        model.preparePluginConnections = { _, completion in finish = completion; return true }
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        let before = model.editor.configuration

        XCTAssertFalse(model.placePreset(pluginID: fixture, at: 1))
        model.editApp(nil)
        finish?(true)

        XCTAssertEqual(model.editor.configuration, before)
        XCTAssertFalse(model.canUndoSlotEdit)
    }

    func testAPendingReplacementIsDroppedWhenAnotherAppIsChosen() throws {
        let model = try makeModel()
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        XCTAssertFalse(model.placePreset(pluginID: fixture, at: 0))
        XCTAssertNotNil(model.presetPendingReplacement)

        model.editApp(nil)

        XCTAssertNil(model.presetPendingReplacement)
    }

    func testPluginRemovalNamesTheAppOverridesThatUseThePlugin() throws {
        let model = try makeModel()
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        XCTAssertTrue(model.placePreset(pluginID: other, at: 2))
        model.addApp(bundleIdentifier: "com.apple.finder", name: "Finder")
        XCTAssertTrue(model.placePreset(pluginID: other, at: 1))
        XCTAssertTrue(model.placePreset(pluginID: other, at: 2))
        let preset = try XCTUnwrap(model.editor.menuItemPresets.first { $0.id == other })

        model.requestPluginRemoval(preset)

        XCTAssertEqual(
            model.removalMessage,
            "Its access is forgotten and it leaves the Library. App Overrides use it in Slots 2 and 3 for Finder"
                + " and Slot 3 for Safari; they stay and are marked unavailable."
        )
    }

    func testPluginRemovalNamesDefaultSlotsAndAppOverridesTogether() throws {
        let model = try makeModel()
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        XCTAssertTrue(model.placePreset(pluginID: fixture, at: 1))
        let preset = try XCTUnwrap(model.editor.menuItemPresets.first { $0.id == fixture })

        model.requestPluginRemoval(preset)

        XCTAssertEqual(
            model.removalMessage,
            "Its access is forgotten and it leaves the Library. The Menu Item in Slot 1 uses it; it stays in the Menu"
                + " and is marked unavailable. App Overrides use it in Slot 2 for Safari; they stay and are marked unavailable."
        )
    }

    func testUndoingAnOverrideEditShowsTheAppItWasMadeFor() throws {
        let model = try makeModel()
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        model.emptySlot(at: 0)
        model.editApp(nil)

        model.undoSlotEdit()

        XCTAssertEqual(model.editedAppID, safari)
        XCTAssertEqual(model.menuSlots[0].appOverride, .inherited)
        XCTAssertEqual(model.placementMessage, "Menu edit undone.")

        model.editApp(nil)
        model.redoSlotEdit()

        XCTAssertEqual(model.editedAppID, safari)
        XCTAssertTrue(model.menuSlots[0].isEmpty)
        XCTAssertEqual(model.menuSlots[0].appOverride, .overridden)
    }

    func testUndoingAnArrangementShowsTheDefaultMenu() throws {
        let model = try makeModel()
        model.addEmptySlot()
        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

        model.undoSlotEdit()

        XCTAssertNil(model.editedAppID)
        XCTAssertEqual(model.menuSlots.count, 3)
    }

    func testTheEditedAppStaysInTheSwitcherWhenItsLastOverrideIsReset() throws {
        let editor = try makeEditor()
        try editor.emptySlot(at: 2, for: safari)
        let model = MenuEditorModel(editor: editor, appName: { $0 == self.safari ? "Safari" : nil })
        model.editApp(safari)

        model.resetSlotToDefault(at: 2)

        XCTAssertEqual(model.editedAppID, safari)
        XCTAssertEqual(model.switcherApps, [MenuEditorApp(bundleIdentifier: safari, name: "Safari")])
    }

    func testReplacingAnAppsInheritedMenuItemSaysTheDefaultMenuStaysUnchanged() throws {
        let model = try makeModel()
        XCTAssertFalse(model.placePreset(pluginID: fixture, at: 0))
        XCTAssertEqual(model.replacementMessage,
                       "The current Menu Item and its Actions will be replaced by the selected Preset.")
        model.cancelPresetReplacement()

        model.addApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        XCTAssertFalse(model.placePreset(pluginID: fixture, at: 0))

        XCTAssertEqual(model.replacementMessage,
                       "Only Safari's Menu Item in this Slot is replaced. The default Menu stays unchanged.")
    }

    func testAppNamesAreLookedUpOncePerApp() throws {
        let editor = try makeEditor()
        try editor.emptySlot(at: 2, for: safari)
        var lookups = 0
        let model = MenuEditorModel(editor: editor, appName: { _ in lookups += 1; return "Safari" })

        _ = model.switcherApps
        _ = model.switcherApps

        XCTAssertEqual(lookups, 1)
    }

    // MARK: - Helpers

    private func makeEditor() throws -> HostConfigurationEditor {
        let registry = PluginRegistry()
        let manifest = try PluginManifest(
            id: PluginID(fixture), name: "Fixture", version: "1.0.0",
            commands: [CommandDeclaration(id: CommandID("fixture.open"), title: "Open URL", hostServiceID: "open.url")],
            preset: MenuItemPresetDeclaration(
                readiness: .readyToUse, isConfigurable: false,
                defaultPrimaryCommandID: CommandID("fixture.open"),
                defaultInputs: [CommandID("fixture.open"): .string("https://example.com")]
            )
        )
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
                                            manifest: manifest))
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/other.spinnetplugin"),
            manifest: PluginManifest(
                id: PluginID(other), name: "Other", version: "1.0.0",
                commands: [CommandDeclaration(id: CommandID("other.open"), title: "Open Other", hostServiceID: "open.url")],
                preset: MenuItemPresetDeclaration(
                    readiness: .readyToUse, isConfigurable: false,
                    defaultInputs: [CommandID("other.open"): .string("https://example.org")]
                )
            )
        ))
        let action = try ActionConfiguration(id: ActionID("open-url"), pluginID: manifest.id,
                                             command: manifest.commands[0], input: .string("https://example.com"))
        let configuration = try HostConfiguration(actions: [action], menu: MenuConfiguration(slots: [
            .occupied(try MenuItemConfiguration(primaryActionID: action.id)), .empty, .empty
        ]))
        return HostConfigurationEditor(registry: registry, configuration: configuration)
    }

    private func makeModel() throws -> MenuEditorModel {
        MenuEditorModel(editor: try makeEditor(), appName: { _ in nil })
    }
}
