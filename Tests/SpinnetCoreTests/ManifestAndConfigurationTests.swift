import XCTest
@testable import SpinnetCore

final class ManifestAndConfigurationTests: XCTestCase {
    func testManifestLoadsHostURLCommandAndCreatesMenuBinding() throws {
        let data = Data(#"""
        {
          "protocol_version": "1.0",
          "id": "com.example.fixture",
          "name": "Fixture",
          "version": "1.0.0",
          "commands": [
            {"id": "fixture.open", "title": "Open", "execution": "host", "host_command": "url.open"}
          ]
        }
        """#.utf8)

        let manifest = try PluginManifestLoader.decode(data)
        XCTAssertEqual(manifest.id, PluginID("com.example.fixture"))
        XCTAssertEqual(manifest.commands.count, 1)
        XCTAssertEqual(manifest.commands[0].execution, .host)
        XCTAssertEqual(manifest.commands[0].hostCommand, .openURL)

        let action = try ActionConfiguration(
            id: ActionID("action-1"),
            pluginID: manifest.id,
            command: manifest.commands[0],
            input: .string("https://example.com")
        )
        let menu = try MenuConfiguration(
            items: [try MenuItemConfiguration(primaryActionID: action.id)]
        )
        let configuration = try HostConfiguration(actions: [action], menu: menu)

        XCTAssertEqual(configuration.actions[0].title, "Open")
        XCTAssertEqual(configuration.menu.items[0].primaryActionID, action.id)
    }

    func testManifestRejectsUnsupportedProtocolAndDuplicateCommandIDs() {
        let unsupported = Data(#"""
        {
          "protocol_version": "9.0", "id": "fixture", "name": "Fixture", "version": "1",
          "commands": [{"id": "open", "title": "Open", "execution": "host", "host_command": "url.open"}]
        }
        """#.utf8)
        XCTAssertThrowsError(try PluginManifestLoader.decode(unsupported))

        let duplicate = Data(#"""
        {
          "protocol_version": "1.0", "id": "fixture", "name": "Fixture", "version": "1",
          "commands": [
            {"id": "same", "title": "One", "execution": "host", "host_command": "url.open"},
            {"id": "same", "title": "Two", "execution": "host", "host_command": "url.open"}
          ]
        }
        """#.utf8)
        XCTAssertThrowsError(try PluginManifestLoader.decode(duplicate))
    }

    func testMenuItemBindsPrimaryAndAlternateActionsAndRoundTrips() throws {
        let menuItem = try MenuItemConfiguration(
            primaryActionID: ActionID("primary"),
            alternateActionIDs: [ActionID("alternate-1"), ActionID("alternate-2")]
        )
        let menu = try MenuConfiguration(items: [menuItem])
        let command = CommandDeclaration(
            id: CommandID("fixture.open"),
            title: "Open",
            hostCommand: .openURL
        )
        let actions = try [
            ActionConfiguration(
                id: ActionID("primary"),
                pluginID: PluginID("fixture"),
                command: command,
                input: .string("https://example.com")
            ),
            ActionConfiguration(
                id: ActionID("alternate-1"),
                pluginID: PluginID("fixture"),
                command: command,
                input: .string("https://example.org")
            ),
            ActionConfiguration(
                id: ActionID("alternate-2"),
                pluginID: PluginID("fixture"),
                command: command,
                input: .string("https://example.net")
            )
        ]
        let configuration = try HostConfiguration(actions: actions, menu: menu)

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(HostConfiguration.self, from: data)

        XCTAssertEqual(
            decoded.menu.items[0].alternateActionIDs,
            [ActionID("alternate-1"), ActionID("alternate-2")]
        )
    }

    func testMenuItemRejectsDuplicateOrPrimaryAlternateBindings() {
        XCTAssertThrowsError(try MenuItemConfiguration(
            primaryActionID: ActionID("same"),
            alternateActionIDs: [ActionID("same")]
        ))

        XCTAssertThrowsError(try MenuItemConfiguration(
            primaryActionID: ActionID("primary"),
            alternateActionIDs: [ActionID("alternate"), ActionID("alternate")]
        ))
    }

    func testLegacyItemOnlyMenuMigratesToOccupiedSlots() throws {
        let data = Data(#"""
        {
          "items": [
            {"primary_action_id": "legacy", "alternate_action_ids": []}
          ]
        }
        """#.utf8)

        let menu = try JSONDecoder().decode(MenuConfiguration.self, from: data)

        XCTAssertEqual(menu.slots.count, 1)
        XCTAssertEqual(menu.slots[0].item?.primaryActionID, ActionID("legacy"))
    }

    func testLegacyHostConfigurationMigrationPreservesConfiguredActions() throws {
        let action = try ActionConfiguration(
            id: ActionID("legacy"),
            pluginID: PluginID("fixture"),
            command: CommandDeclaration(
                id: CommandID("fixture.open"),
                title: "Open",
                hostCommand: .openURL
            ),
            input: .string("https://example.com")
        )
        let current = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(primaryActionID: action.id)
            ])
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
                as? [String: Any]
        )
        object["menu"] = [
            "items": [[
                "primary_action_id": "legacy",
                "alternate_action_ids": []
            ]]
        ]

        let migrated = try JSONDecoder().decode(
            HostConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(migrated.actions, [action])
        XCTAssertEqual(migrated.menu.slots.count, 1)
        XCTAssertEqual(migrated.menu.slots[0].item?.primaryActionID, action.id)
    }
}
