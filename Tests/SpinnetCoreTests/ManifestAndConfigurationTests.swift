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

    func testHostCommandCatalogueExposesInputContractsAndAuthority() throws {
        let manifest = try PluginManifestLoader.decode(Data(#"""
        {
          "protocol_version": "1.0",
          "id": "com.example.fixture",
          "name": "Fixture",
          "version": "1.0.0",
          "capabilities": ["write_clipboard"],
          "commands": [
            {"id": "fixture.open_app", "title": "Open Application", "execution": "host", "host_command": "application.open"},
            {"id": "fixture.open_file", "title": "Open File", "execution": "host", "host_command": "file.open"},
            {"id": "fixture.open_folder", "title": "Open Folder", "execution": "host", "host_command": "folder.open"},
            {"id": "fixture.keyboard", "title": "Keyboard Shortcut", "execution": "host", "host_command": "keyboard_shortcut.invoke"},
            {"id": "fixture.service", "title": "Service", "execution": "host", "host_command": "service.invoke"},
            {"id": "fixture.shortcut", "title": "Shortcut", "execution": "host", "host_command": "shortcut.invoke"},
            {"id": "fixture.copy", "title": "Copy", "execution": "host", "host_command": "clipboard.copy"},
            {"id": "fixture.feedback", "title": "Feedback", "execution": "host", "host_command": "feedback.present"}
          ]
        }
        """#.utf8))

        XCTAssertEqual(manifest.commands.map(\.hostCommand), [
            .openApplication, .openFile, .openFolder, .invokeKeyboardShortcut,
            .invokeService, .invokeShortcut, .copyText, .presentFeedback
        ])
        XCTAssertEqual(HostCommand.copyText.requiredCapability, .writeClipboard)
        XCTAssertEqual(HostCommand.invokeKeyboardShortcut.requiredSystemPermission, .accessibility)
        XCTAssertTrue(HostCommand.openApplication.isValidInput(.string("com.apple.TextEdit")))
        XCTAssertTrue(HostCommand.openFile.isValidInput(.object(["path": .string("/tmp/file")])))
        XCTAssertTrue(HostCommand.invokeKeyboardShortcut.isValidInput(.object([
            "key_code": .number(35),
            "modifiers": .array([.string("command")])
        ])))
        XCTAssertFalse(HostCommand.openURL.isValidInput(.string("not a URL")))
    }

    func testManifestRejectsAProtectedHostCommandWithoutItsCapabilityDeclaration() {
        let data = Data(#"""
        {
          "protocol_version": "1.0",
          "id": "com.example.fixture",
          "name": "Fixture",
          "version": "1.0.0",
          "commands": [
            {"id": "fixture.copy", "title": "Copy", "execution": "host", "host_command": "clipboard.copy"}
          ]
        }
        """#.utf8)

        XCTAssertThrowsError(try PluginManifestLoader.decode(data))
    }

    func testReadyPresetRejectsUnknownKeyboardKeyAndModifier() {
        let command = CommandDeclaration(
            id: CommandID("fixture.keyboard"),
            title: "Keyboard Shortcut",
            hostCommand: .invokeKeyboardShortcut
        )
        let inputs: [JSONValue] = [
            .string("not-a-key"),
            .object([
                "key": .string("P"),
                "modifiers": .array([.string("unknown")])
            ]),
            .object(["key": .string("F01")])
        ]

        for input in inputs {
            let preset = MenuItemPresetDeclaration(
                readiness: .readyToUse,
                defaultPrimaryCommandID: command.id,
                defaultInputs: [command.id: input]
            )
            XCTAssertThrowsError(try PluginManifest(
                id: PluginID("com.example.fixture"),
                name: "Fixture",
                version: "1.0.0",
                commands: [command],
                preset: preset
            ))
        }
    }

    func testManifestLoadsCommonJavaScriptCommandsWithScriptReferences() throws {
        let data = Data(#"""
        {
          "protocol_version": "1.0",
          "id": "com.example.fixture",
          "name": "Fixture",
          "version": "1.0.0",
          "commands": [
            {"id": "fixture.transform_text", "title": "Transform Text", "execution": "javascript", "is_configurable": false, "script": "transform-text.js"},
            {"id": "fixture.transform_data", "title": "Transform Structured Data", "execution": "javascript", "is_configurable": true, "script": "structured-data.js"}
          ]
        }
        """#.utf8)

        let manifest = try PluginManifestLoader.decode(data)

        XCTAssertEqual(manifest.commands.map(\.execution), [.javascript, .javascript])
        XCTAssertEqual(manifest.commands.map(\.scriptPath), ["transform-text.js", "structured-data.js"])
        XCTAssertEqual(manifest.commands.map(\.isConfigurable), [false, true])
        XCTAssertNil(manifest.commands[0].hostCommand)
    }

    func testManifestRejectsJavaScriptCommandWithoutAScriptReference() {
        let data = Data(#"""
        {
          "protocol_version": "1.0",
          "id": "com.example.fixture",
          "name": "Fixture",
          "version": "1.0.0",
          "commands": [
            {"id": "fixture.transform", "title": "Transform", "execution": "javascript"}
          ]
        }
        """#.utf8)

        XCTAssertThrowsError(try PluginManifestLoader.decode(data))
    }

    func testJavaScriptActionPersistsItsScriptReferenceAndInput() throws {
        let command = CommandDeclaration(
            id: CommandID("fixture.transform"),
            title: "Transform",
            execution: .javascript,
            script: "transform.js"
        )
        let action = try ActionConfiguration(
            id: ActionID("script-action"),
            pluginID: PluginID("com.example.fixture"),
            command: command,
            input: .object(["value": .string("input")])
        )

        let restored = try JSONDecoder().decode(
            ActionConfiguration.self,
            from: JSONEncoder().encode(action)
        )

        XCTAssertEqual(restored, action)
        XCTAssertEqual(restored.declaredCommand, command)
    }

    func testManifestRejectsScriptReferencesThatEscapeThePluginPackage() {
        let data = Data(#"""
        {
          "protocol_version": "1.0",
          "id": "com.example.fixture",
          "name": "Fixture",
          "version": "1.0.0",
          "commands": [
            {"id": "fixture.transform", "title": "Transform", "execution": "javascript", "script": "../outside.js"}
          ]
        }
        """#.utf8)

        XCTAssertThrowsError(try PluginManifestLoader.decode(data))
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

    func testMenuSlotNameRoundTripsAndBlankNamesUseAutomaticMode() throws {
        let menuItem = try MenuItemConfiguration(primaryActionID: ActionID("primary"))
        let configuration = try MenuConfiguration(slots: [
            .occupied(menuItem, name: "  Work  "),
            MenuSlotConfiguration(item: nil, name: "   ")
        ])

        XCTAssertEqual(configuration.slots[0].name, "Work")
        XCTAssertNil(configuration.slots[1].name)

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(MenuConfiguration.self, from: data)

        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.slots[0].name, "Work")
        XCTAssertNil(decoded.slots[1].name)
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
