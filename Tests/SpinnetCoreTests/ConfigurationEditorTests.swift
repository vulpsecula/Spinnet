import Foundation
import XCTest
@testable import SpinnetCore

final class ConfigurationEditorTests: XCTestCase {
    func testEditorCreatesEditsBindsAndRemovesConfiguredActions() throws {
        let registry = try makeRegistry()
        let firstCommand = try XCTUnwrap(registry.command(
            for: PluginID("com.spinnet.fixture"),
            commandID: CommandID("fixture.open")
        ))
        let firstAction = try ActionConfiguration(
            id: ActionID("first"),
            pluginID: PluginID("com.spinnet.fixture"),
            command: firstCommand,
            input: .string("https://example.com")
        )
        let initialConfiguration = try HostConfiguration(
            actions: [firstAction],
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(primaryActionID: firstAction.id)
            ])
        )
        let editor = HostConfigurationEditor(
            registry: registry,
            configuration: initialConfiguration
        )

        let secondAction = try editor.createAction(
            id: ActionID("second"),
            pluginID: PluginID("com.spinnet.fixture"),
            commandID: CommandID("fixture.copy"),
            input: .string("Copied text")
        )
        let updatedAction = try editor.updateAction(
            id: secondAction.id,
            pluginID: secondAction.pluginID,
            commandID: secondAction.commandID,
            input: .string("Updated text")
        )
        try editor.updateMenuItem(
            at: 0,
            primaryActionID: firstAction.id,
            alternateActionIDs: [updatedAction.id]
        )

        XCTAssertEqual(editor.configuration.actions.count, 2)
        XCTAssertEqual(editor.configuration.actions[1].input, .string("Updated text"))
        XCTAssertEqual(
            editor.configuration.menu.items[0].alternateActionIDs,
            [ActionID("second")]
        )

        try editor.removeAction(updatedAction.id)
        XCTAssertEqual(editor.configuration.actions.map(\.id), [firstAction.id])
        XCTAssertTrue(editor.configuration.menu.items[0].alternateActionIDs.isEmpty)
    }

    func testConfigurationSurvivesAStoreRecreation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("configuration.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let action = try ActionConfiguration(
            id: ActionID("persisted"),
            pluginID: PluginID("com.spinnet.fixture"),
            command: CommandDeclaration(
                id: CommandID("fixture.open"),
                title: "Open",
                hostCommand: .openURL
            ),
            input: .string("https://example.com")
        )
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(primaryActionID: action.id)
            ])
        )

        try HostConfigurationStore(fileURL: url).save(configuration)
        let restored = try HostConfigurationStore(fileURL: url).load()

        XCTAssertEqual(restored, configuration)
    }

    func testEditorReportsUnavailableActionWithoutRemovingItFromConfiguration() throws {
        let registry = try makeRegistry()
        let command = try XCTUnwrap(registry.command(
            for: PluginID("com.spinnet.fixture"),
            commandID: CommandID("fixture.open")
        ))
        let action = try ActionConfiguration(
            id: ActionID("stale"),
            pluginID: PluginID("com.spinnet.fixture"),
            command: command,
            input: .string("https://example.com")
        )
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(primaryActionID: action.id)
            ])
        )
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)

        try registry.setEnabled(false, for: action.pluginID)

        XCTAssertEqual(editor.availability(for: action.id), .unavailable(.pluginDisabled))
        XCTAssertEqual(editor.configuration.actions, [action])
    }

    func testRemovingPrimaryPromotesTheFirstAlternate() throws {
        let registry = try makeRegistry()
        let commands = try [
            XCTUnwrap(registry.command(
                for: PluginID("com.spinnet.fixture"),
                commandID: CommandID("fixture.open")
            )),
            XCTUnwrap(registry.command(
                for: PluginID("com.spinnet.fixture"),
                commandID: CommandID("fixture.copy")
            ))
        ]
        let actions = try commands.enumerated().map { index, command in
            try ActionConfiguration(
                id: ActionID("action-\(index)"),
                pluginID: PluginID("com.spinnet.fixture"),
                command: command,
                input: .string("value-\(index)")
            )
        }
        let configuration = try HostConfiguration(
            actions: actions,
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(
                    primaryActionID: actions[0].id,
                    alternateActionIDs: [actions[1].id]
                )
            ])
        )
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)

        try editor.removeAction(actions[0].id)

        XCTAssertEqual(editor.configuration.menu.items[0].primaryActionID, actions[1].id)
        XCTAssertTrue(editor.configuration.menu.items[0].alternateActionIDs.isEmpty)
    }

    func testEmptySlotsRoundTripAndPresetPlacementTargetsTheExactSlot() throws {
        let registry = try makeRegistry()
        let command = try XCTUnwrap(registry.command(
            for: PluginID("com.spinnet.fixture"),
            commandID: CommandID("fixture.open")
        ))
        let action = try ActionConfiguration(
            id: ActionID("existing"),
            pluginID: PluginID("com.spinnet.fixture"),
            command: command,
            input: .string("https://example.com")
        )
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(slots: [
                .occupied(try MenuItemConfiguration(primaryActionID: action.id)),
                .empty,
                .empty
            ])
        )
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)

        let placedAction = try editor.placeCommand(
            pluginID: PluginID("com.spinnet.fixture"),
            commandID: CommandID("fixture.copy"),
            input: .string(""),
            inSlotAt: 2
        )

        XCTAssertNil(editor.configuration.menu.slots[1].item)
        XCTAssertEqual(
            editor.configuration.menu.slots[2].item?.primaryActionID,
            placedAction.id
        )

        let data = try JSONEncoder().encode(editor.configuration)
        let restored = try JSONDecoder().decode(HostConfiguration.self, from: data)
        XCTAssertEqual(restored, editor.configuration)
        XCTAssertEqual(restored.menu.slots.count, 3)
        XCTAssertNil(restored.menu.slots[1].item)
    }

    func testEditorAddsAndRemovesTheExactEmptySlot() throws {
        let registry = try makeRegistry()
        let command = try XCTUnwrap(registry.command(
            for: PluginID("com.spinnet.fixture"),
            commandID: CommandID("fixture.open")
        ))
        let action = try ActionConfiguration(
            id: ActionID("existing"),
            pluginID: PluginID("com.spinnet.fixture"),
            command: command,
            input: .string("https://example.com")
        )
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(primaryActionID: action.id)
            ])
        )
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)

        try editor.addEmptySlot()
        try editor.addEmptySlot()
        XCTAssertEqual(editor.configuration.menu.slots.count, 3)
        XCTAssertNil(editor.configuration.menu.slots[1].item)

        try editor.removeSlot(at: 1)
        XCTAssertEqual(editor.configuration.menu.slots.count, 2)
        XCTAssertNotNil(editor.configuration.menu.slots[0].item)
        XCTAssertNil(editor.configuration.menu.slots[1].item)
    }

    private func makeRegistry() throws -> PluginRegistry {
        let registry = PluginRegistry()
        let manifest = try PluginManifest(
            id: PluginID("com.spinnet.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [
                CommandDeclaration(
                    id: CommandID("fixture.open"),
                    title: "Open",
                    hostCommand: .openURL
                ),
                CommandDeclaration(
                    id: CommandID("fixture.copy"),
                    title: "Copy",
                    hostCommand: .openURL
                )
            ]
        )
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        ))
        return registry
    }
}
