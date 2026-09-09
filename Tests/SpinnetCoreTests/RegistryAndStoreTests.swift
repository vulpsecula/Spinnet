import Foundation
import XCTest
@testable import SpinnetCore

final class RegistryAndStoreTests: XCTestCase {
    func testRegistryLoadsFixtureThroughPublicPackagePath() throws {
        let registry = PluginRegistry()
        let manifest = try registry.register(packageAt: fixturePackageURL())

        XCTAssertEqual(manifest.id, PluginID("com.spinnet.fixture"))
        XCTAssertEqual(
            manifest.commands.map(\.id),
            [
                CommandID("fixture.open_url"),
                CommandID("fixture.open_application"),
                CommandID("fixture.open_file"),
                CommandID("fixture.open_folder"),
                CommandID("fixture.invoke_keyboard_shortcut"),
                CommandID("fixture.invoke_service"),
                CommandID("fixture.invoke_shortcut"),
                CommandID("fixture.copy_text"),
                CommandID("fixture.present_feedback"),
                CommandID("fixture.transform_text"),
                CommandID("fixture.transform_data")
            ]
        )
        let transformText = try XCTUnwrap(
            manifest.commands.first { $0.id == CommandID("fixture.transform_text") }
        )
        let transformData = try XCTUnwrap(
            manifest.commands.first { $0.id == CommandID("fixture.transform_data") }
        )
        XCTAssertFalse(transformText.isConfigurable)
        XCTAssertTrue(transformData.isConfigurable)
        XCTAssertEqual(registry.package(for: manifest.id)?.manifest, manifest)
        XCTAssertEqual(registry.manifests().map(\.id), [manifest.id])
    }

    func testHostConfigurationRejectsMenuActionThatIsNotConfigured() throws {
        let action = try ActionConfiguration(
            id: ActionID("configured"),
            pluginID: PluginID("com.spinnet.fixture"),
            command: CommandDeclaration(
                id: CommandID("fixture.open_url"),
                title: "Open URL",
                hostCommand: .openURL
            ),
            input: .string("https://example.com")
        )
        let menu = try MenuConfiguration(items: [
            try MenuItemConfiguration(primaryActionID: ActionID("missing"))
        ])

        XCTAssertThrowsError(try HostConfiguration(actions: [action], menu: menu))

        let menuWithMissingAlternate = try MenuConfiguration(items: [
            try MenuItemConfiguration(
                primaryActionID: action.id,
                alternateActionIDs: [ActionID("missing-alternate")]
            )
        ])
        XCTAssertThrowsError(
            try HostConfiguration(actions: [action], menu: menuWithMissingAlternate)
        )
    }

    func testRegistryListsCommandsAndReportsUnavailableConfiguredActions() throws {
        let registry = PluginRegistry()
        let originalManifest = try makeManifest(title: "Open URL")
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: originalManifest
        ))
        let action = try ActionConfiguration(
            id: ActionID("open-action"),
            pluginID: originalManifest.id,
            command: originalManifest.commands[0],
            input: .string("https://example.com")
        )

        XCTAssertEqual(registry.availableCommands().map(\.commandID), [CommandID("fixture.open")])
        XCTAssertEqual(registry.availability(for: action), .available)

        try registry.setEnabled(false, for: originalManifest.id)
        XCTAssertTrue(registry.availableCommands().isEmpty)
        XCTAssertEqual(
            registry.availability(for: action),
            .unavailable(.pluginDisabled)
        )

        try registry.setEnabled(true, for: originalManifest.id)
        let changedManifest = try makeManifest(title: "Open a URL")
        try registry.replace(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: changedManifest
        ))
        XCTAssertEqual(
            registry.availability(for: action),
            .unavailable(.commandChanged)
        )

        let missingCommandManifest = try makeManifest(
            title: "Another Command",
            commandID: CommandID("fixture.other")
        )
        try registry.replace(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: missingCommandManifest
        ))
        XCTAssertEqual(
            registry.availability(for: action),
            .unavailable(.commandMissing)
        )
    }

    func testCompatibilityPackageCanStayRegisteredWithoutALibraryPreset() throws {
        let manifest = try makeManifest(title: "Fixture Compatibility")
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture-compatibility.spinnetplugin"),
            manifest: manifest,
            isVisibleInLibrary: false
        )
        let registry = PluginRegistry()
        try registry.register(package)

        XCTAssertNil(registry.menuItemPreset(for: manifest.id))
        XCTAssertEqual(
            registry.command(for: manifest.id, commandID: manifest.commands[0].id),
            manifest.commands[0]
        )
        XCTAssertEqual(registry.manifests(), [manifest])
    }

    func testChangingCommandConfigurationMetadataDoesNotInvalidateAnAction() throws {
        let registry = PluginRegistry()
        let originalManifest = try PluginManifest(
            id: PluginID("com.spinnet.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [CommandDeclaration(
                id: CommandID("fixture.open"),
                title: "Open URL",
                isConfigurable: true,
                hostCommand: .openURL
            )]
        )
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: originalManifest
        ))
        let action = try ActionConfiguration(
            id: ActionID("open-action"),
            pluginID: originalManifest.id,
            command: originalManifest.commands[0],
            input: .string("https://example.com")
        )

        let updatedManifest = try PluginManifest(
            id: originalManifest.id,
            name: originalManifest.name,
            version: originalManifest.version,
            commands: [CommandDeclaration(
                id: CommandID("fixture.open"),
                title: "Open URL",
                isConfigurable: false,
                hostCommand: .openURL
            )]
        )
        try registry.replace(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: updatedManifest
        ))

        XCTAssertEqual(registry.availability(for: action), .available)
    }

    func testRegistryReportsMissingPluginAndCommand() throws {
        let registry = PluginRegistry()
        let action = try ActionConfiguration(
            id: ActionID("missing-action"),
            pluginID: PluginID("missing.plugin"),
            command: CommandDeclaration(
                id: CommandID("missing.command"),
                title: "Missing",
                hostCommand: .openURL
            ),
            input: .string("https://example.com")
        )

        XCTAssertEqual(
            registry.availability(for: action),
            .unavailable(.pluginMissing)
        )
    }

    private func makeManifest(
        title: String,
        commandID: CommandID = CommandID("fixture.open")
    ) throws -> PluginManifest {
        try PluginManifest(
            id: PluginID("com.spinnet.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [CommandDeclaration(
                id: commandID,
                title: title,
                hostCommand: .openURL
            )]
        )
    }

    private func fixturePackageURL() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            root.deleteLastPathComponent()
        }
        let packageURL = root.appendingPathComponent("Plugins/SpinnetFixture.spinnetplugin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        return packageURL
    }
}
