import SpinnetTestSupport
import XCTest
import SpinnetCore

final class OpenTargetSetupTests: XCTestCase {
    private let root = TestRepository.root

    func testOpenFileAndURLRequireInputBeforePlacementAndKeepStoredTargets() throws {
        for name in ["OpenFile", "OpenURL"] {
            let package = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Tests/Fixtures/HostPlugins/\(name).spinnetplugin"))
            XCTAssertEqual(package.manifest.preset.readiness, .setupRequired, name)
            XCTAssertTrue(package.manifest.preset.defaultInputs.isEmpty, name)
            XCTAssertTrue(package.manifest.externalAppConnections.isEmpty)
            let registry = PluginRegistry()
            try registry.register(package)
            let empty = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
            let editor = HostConfigurationEditor(registry: registry, configuration: empty)
            XCTAssertThrowsError(try editor.placePreset(pluginID: package.manifest.id, inSlotAt: 0))
            let command = package.manifest.commands[0]
            func configure(_ input: JSONValue) throws -> HostConfiguration {
                try editor.configuredMenuItem(at: 0, pluginID: package.manifest.id, primaryCommandID: command.id,
                    inputs: [command.id: input], replacingEmptySlot: true)
            }
            XCTAssertThrowsError(try configure(.string("")))
            XCTAssertThrowsError(try configure(.null))
            let input = name == "OpenURL" ? JSONValue.string("https://example.com/user-target") : .string("/tmp/user-target.txt")
            let configured = try configure(input)
            try registry.replace(package)
            XCTAssertEqual(configured.actions.first?.input, input, "Updating the package must not reset stored input")
            XCTAssertEqual(editor.configuration, empty, "Cancelling the draft never places it")
        }
    }
}
