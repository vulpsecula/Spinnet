import XCTest
import SpinnetCore
@testable import SpinnetHost

/// The Menu Editor's App switcher and App Overrides (#113): choosing an App,
/// overriding, emptying and resetting its Slots, and removing it, observed
/// as what the editor shows and what is saved.
final class MenuEditorAppOverrideTests: XCTestCase {
    private let safari = AppBundleIdentifier("com.apple.Safari")
    private let finder = AppBundleIdentifier("com.apple.finder")
    private let fixture = "com.spinnet.fixture"

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
        editor.editApp(safari)
        try editor.emptySlot(at: 2)
        editor.editApp(nil)

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
