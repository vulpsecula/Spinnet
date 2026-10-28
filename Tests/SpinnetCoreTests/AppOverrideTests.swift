import Foundation
import XCTest
@testable import SpinnetCore

/// App Overrides through the Menu configuration resolution seam: given saved
/// configuration and a Current App bundle identifier, the Slots presented,
/// what is saved, and how older saved configuration loads.
final class AppOverrideTests: XCTestCase {
    private let safari = AppBundleIdentifier("com.apple.Safari")
    private let finder = AppBundleIdentifier("com.apple.finder")

    func testCurrentAppOverridesReplaceOrEmptyTheirSlotsAndOtherAppsGetTheDefaultMenu() throws {
        let configuration = try HostConfiguration(
            actions: [action("open"), action("copy"), action("safari-copy")],
            menu: MenuConfiguration(slots: [
                MenuSlotConfiguration(
                    item: item("open"),
                    appOverrides: [safari: .item(item("safari-copy"))]
                ),
                MenuSlotConfiguration(item: item("copy"), appOverrides: [finder: .empty]),
                .empty
            ])
        )

        XCTAssertEqual(presented(configuration, for: safari), ["safari-copy", "copy", nil])
        XCTAssertEqual(presented(configuration, for: finder), ["open", nil, nil])
        XCTAssertEqual(presented(configuration, for: AppBundleIdentifier("com.example.other")), ["open", "copy", nil])
        XCTAssertEqual(presented(configuration, for: nil), ["open", "copy", nil])
    }

    func testConfigurationSavedBeforeAppOverridesLoadsUnchangedAndSavesInTheSameShape() throws {
        // The saved shape of a Menu before App Overrides, including a Slot
        // alias still stored on the Slot as `name`.
        let saved = """
        {
          "actions": [
            {"id": "open", "pluginID": "com.spinnet.fixture", "commandID": "fixture.copy",
             "title": "Copy", "execution": "host", "hostServiceID": "open.url", "input": ""}
          ],
          "menu": {
            "slots": [
              {"item": {"primary_action_id": "open", "alternate_action_ids": []}, "name": "Mine"},
              {"item": null}
            ]
          }
        }
        """
        let configuration = try JSONDecoder().decode(HostConfiguration.self, from: Data(saved.utf8))

        XCTAssertEqual(configuration.menu.slots.map(\.appOverrides), [[:], [:]])
        XCTAssertEqual(configuration.menu.slots[0].item?.alias, "Mine")
        XCTAssertEqual(configuration.menu.overriddenApps, [])
        XCTAssertEqual(presented(configuration, for: safari), ["open", nil])

        let resaved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        let slots = try XCTUnwrap((resaved?["menu"] as? [String: Any])?["slots"] as? [[String: Any]])
        XCTAssertEqual(slots.map { $0.keys.sorted() }, [["item"], ["item"]])
    }

    func testAppOverridesSurviveAStoreRecreation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("configuration.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try HostConfiguration(
            actions: [action("open"), action("safari-copy")],
            menu: MenuConfiguration(slots: [
                MenuSlotConfiguration(item: item("open"), appOverrides: [safari: .item(item("safari-copy"))]),
                MenuSlotConfiguration(item: nil, appOverrides: [finder: .empty])
            ])
        )

        try HostConfigurationStore(fileURL: url).save(configuration)
        let restored = try XCTUnwrap(HostConfigurationStore(fileURL: url).load())

        XCTAssertEqual(restored, configuration)
        XCTAssertEqual(Set(restored.menu.overriddenApps), [finder, safari])
        XCTAssertEqual(presented(restored, for: safari), ["safari-copy", nil])
    }

    func testAnOverrideMenuItemMustBindItsOwnKnownActions() throws {
        XCTAssertThrowsError(try MenuConfiguration(slots: [
            MenuSlotConfiguration(item: item("open"), appOverrides: [safari: .item(item("open"))])
        ]))
        XCTAssertThrowsError(try HostConfiguration(
            actions: [action("open")],
            menu: MenuConfiguration(slots: [
                MenuSlotConfiguration(item: item("open"), appOverrides: [safari: .item(item("missing"))])
            ])
        ))
        XCTAssertThrowsError(try MenuConfiguration(slots: [
            MenuSlotConfiguration(item: nil, appOverrides: [AppBundleIdentifier(" "): .empty])
        ]))
    }

    func testAddingALibraryPresetWhileAnAppIsEditedOverridesOnlyThatAppsSlot() throws {
        let editor = try makeEditor()

        editor.editApp(safari)
        try editor.placePreset(pluginID: other, inSlotAt: 1)
        try editor.placePreset(pluginID: other, inSlotAt: 0, replacing: true)

        let configuration = editor.configuration
        XCTAssertEqual(presented(configuration, for: nil), ["open", nil])
        XCTAssertEqual(presented(configuration, for: finder), ["open", nil])
        let safariSlots = configuration.menu.slots(for: safari)
        XCTAssertEqual(safariSlots.compactMap(\.item).count, 2)
        XCTAssertEqual(pluginIDs(of: safariSlots, in: configuration), [other, other])
        XCTAssertEqual(editor.editedSlots, safariSlots)
        XCTAssertTrue(editor.isOverridden(slotAt: 0))
        XCTAssertTrue(editor.isOverridden(slotAt: 1))
        // The default Menu Item replaced for Safari keeps its Action.
        XCTAssertNotNil(configuration.actions.first { $0.id == ActionID("open") })
    }

    func testEditingAnInheritedMenuItemForAnAppGivesItsOverrideItsOwnActions() throws {
        let editor = try makeEditor()

        editor.editApp(safari)
        XCTAssertFalse(editor.isOverridden(slotAt: 0))
        try editor.configureMenuItem(
            at: 0, pluginID: fixture, primaryCommandID: CommandID("fixture.copy"),
            inputs: [CommandID("fixture.copy"): .string("https://safari.example")]
        )
        try editor.renameMenuItem(at: 0, name: "Safari Copy")

        let configuration = editor.configuration
        XCTAssertTrue(editor.isOverridden(slotAt: 0))
        let override = try XCTUnwrap(configuration.menu.slots(for: safari)[0].item)
        XCTAssertNotEqual(override.primaryActionID, ActionID("open"))
        XCTAssertEqual(override.alias, "Safari Copy")
        XCTAssertEqual(input(of: override.primaryActionID, in: configuration), .string("https://safari.example"))
        let defaultItem = try XCTUnwrap(configuration.menu.slots(for: nil)[0].item)
        XCTAssertEqual(defaultItem.primaryActionID, ActionID("open"))
        XCTAssertNil(defaultItem.alias)
        XCTAssertEqual(input(of: ActionID("open"), in: configuration), .string(""))
    }

    func testAConfigurationSheetCandidateForAnAppLeavesTheEditorUnchanged() throws {
        let editor = try makeEditor()
        editor.editApp(safari)
        let before = editor.configuration

        let candidate = try editor.configuredMenuItem(
            at: 0, pluginID: fixture, primaryCommandID: CommandID("fixture.copy"),
            inputs: [CommandID("fixture.copy"): .string("https://safari.example")]
        )
        let named = try editor.configuration(candidate, aliasingMenuItemAt: 0, to: "Named")

        XCTAssertEqual(editor.configuration, before)
        XCTAssertEqual(named.menu.slots(for: safari)[0].item?.alias, "Named")
        XCTAssertNil(named.menu.slots(for: nil)[0].item?.alias)
        XCTAssertEqual(named.menu.slots(for: safari)[0].item.map { input(of: $0.primaryActionID, in: named) },
                       .string("https://safari.example"))
    }

    func testAnAppCanEmptyASlotAndResetItToTheDefault() throws {
        let editor = try makeEditor()
        editor.editApp(safari)
        try editor.configureMenuItem(
            at: 0, pluginID: fixture, primaryCommandID: CommandID("fixture.copy"),
            inputs: [CommandID("fixture.copy"): .string("https://safari.example")]
        )
        let overrideActionID = try XCTUnwrap(editor.editedSlots[0].item?.primaryActionID)

        try editor.emptySlot(at: 0)
        XCTAssertEqual(presented(editor.configuration, for: safari), [nil, nil])
        XCTAssertTrue(editor.isOverridden(slotAt: 0))
        XCTAssertFalse(editor.configuration.actions.contains { $0.id == overrideActionID })

        try editor.resetSlotToDefault(at: 0)
        XCTAssertEqual(presented(editor.configuration, for: safari), ["open", nil])
        XCTAssertFalse(editor.isOverridden(slotAt: 0))
        XCTAssertEqual(editor.configuration.menu.overriddenApps, [])
    }

    func testResettingAnOverriddenMenuItemForgetsItsActions() throws {
        let editor = try makeEditor()
        editor.editApp(safari)
        try editor.placePreset(pluginID: other, inSlotAt: 1)
        let overrideActionIDs = try XCTUnwrap(editor.editedSlots[1].item?.boundActionIDs)

        try editor.resetSlotToDefault(at: 1)

        XCTAssertEqual(editor.configuration.actions.map(\.id), [ActionID("open")])
        XCTAssertFalse(overrideActionIDs.isEmpty)
    }

    func testRemovingAnAppRemovesAllItsOverridesAndKeepsOtherApps() throws {
        let editor = try makeEditor()
        editor.editApp(safari)
        try editor.placePreset(pluginID: other, inSlotAt: 1)
        try editor.emptySlot(at: 0)
        editor.editApp(finder)
        try editor.emptySlot(at: 0)

        try editor.removeApp(safari)

        XCTAssertEqual(editor.configuration.menu.overriddenApps, [finder])
        XCTAssertEqual(presented(editor.configuration, for: safari), ["open", nil])
        XCTAssertEqual(presented(editor.configuration, for: finder), [nil, nil])
        XCTAssertEqual(editor.configuration.actions.map(\.id), [ActionID("open")])
    }

    func testSlotsAreArrangedOnlyInTheDefaultMenu() throws {
        let editor = try makeEditor()
        editor.editApp(safari)

        XCTAssertThrowsError(try editor.addEmptySlot())
        XCTAssertThrowsError(try editor.removeSlot(at: 1))
        XCTAssertThrowsError(try editor.moveSlot(from: 0, to: 1))
        XCTAssertThrowsError(try editor.resetSlotToDefault(at: 0))
        editor.editApp(nil)
        XCTAssertThrowsError(try editor.emptySlot(at: 0))
        XCTAssertThrowsError(try editor.resetSlotToDefault(at: 0))
    }

    func testDefaultMenuEditsKeepAppOverrides() throws {
        let editor = try makeEditor()
        editor.editApp(safari)
        try editor.emptySlot(at: 1)

        editor.editApp(nil)
        try editor.placePreset(pluginID: other, inSlotAt: 1)
        try editor.renameMenuItem(at: 0, name: "Everywhere")

        XCTAssertEqual(presented(editor.configuration, for: safari)[1], nil)
        XCTAssertEqual(editor.configuration.menu.slots(for: safari)[0].item?.alias, "Everywhere")
        XCTAssertNotNil(editor.configuration.menu.slots(for: finder)[1].item)
    }

    func testRemovingAnActionAlsoRemovesItFromOverrideMenuItems() throws {
        let editor = try makeEditor()
        editor.editApp(safari)
        try editor.placePreset(pluginID: other, inSlotAt: 1)
        let overrideActionID = try XCTUnwrap(editor.editedSlots[1].item?.primaryActionID)

        try editor.removeAction(overrideActionID)

        XCTAssertEqual(presented(editor.configuration, for: safari), ["open", nil])
        XCTAssertTrue(editor.isOverridden(slotAt: 1))
    }

    // MARK: - Helpers

    private let fixture = PluginID("com.spinnet.fixture")
    private let other = PluginID("com.spinnet.other")

    private func makeEditor() throws -> HostConfigurationEditor {
        let registry = PluginRegistry()
        for (id, name) in [(fixture, "Fixture"), (other, "Other")] {
            let command = id == fixture ? "fixture.copy" : "other.copy"
            try registry.register(PluginPackage(
                rootURL: URL(fileURLWithPath: "/tmp/\(name).spinnetplugin"),
                manifest: PluginManifest(
                    id: id, name: name, version: "1.0.0",
                    commands: [CommandDeclaration(id: CommandID(command), title: "Copy", hostServiceID: "open.url")],
                    preset: MenuItemPresetDeclaration(
                        readiness: .readyToUse,
                        defaultInputs: [CommandID(command): .string("https://example.com")]
                    )
                )
            ))
        }
        let configuration = try HostConfiguration(
            actions: [action("open")],
            menu: MenuConfiguration(slots: [.occupied(item("open")), .empty])
        )
        return HostConfigurationEditor(registry: registry, configuration: configuration)
    }

    private func pluginIDs(of slots: [MenuSlotConfiguration], in configuration: HostConfiguration) -> [PluginID] {
        slots.compactMap(\.item).compactMap { item in
            configuration.actions.first { $0.id == item.primaryActionID }?.pluginID
        }
    }

    private func input(of actionID: ActionID, in configuration: HostConfiguration) -> JSONValue? {
        configuration.actions.first { $0.id == actionID }?.input
    }

    private func presented(_ configuration: HostConfiguration, for app: AppBundleIdentifier?) -> [String?] {
        configuration.menu.slots(for: app).map { $0.item?.primaryActionID.rawValue }
    }

    private func item(_ id: String) -> MenuItemConfiguration {
        try! MenuItemConfiguration(primaryActionID: ActionID(id))
    }

    private func action(_ id: String, command: String = "fixture.copy") -> ActionConfiguration {
        try! ActionConfiguration(
            id: ActionID(id),
            pluginID: PluginID("com.spinnet.fixture"),
            command: CommandDeclaration(id: CommandID(command), title: "Copy", hostServiceID: "open.url"),
            input: .string("")
        )
    }
}
