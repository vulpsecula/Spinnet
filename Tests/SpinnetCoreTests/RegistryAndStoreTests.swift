import Foundation
import XCTest
@testable import SpinnetCore

final class RegistryAndStoreTests: XCTestCase {
    func testRegistryLoadsFixtureThroughPublicPackagePath() throws {
        let registry = PluginRegistry()
        let manifest = try registry.register(packageAt: fixturePackageURL())

        XCTAssertEqual(manifest.id, PluginID("com.spinnet.fixture"))
        XCTAssertEqual(manifest.commands.map(\.id), [CommandID("fixture.open_url")])
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
