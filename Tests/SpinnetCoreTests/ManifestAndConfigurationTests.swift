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
}
