import XCTest
@testable import SpinnetCore

/// A Plugin may declare a Plugin Icon, a system symbol named the way a page
/// `icon` component names one, so the user recognises its Menu Items.
final class PluginIconTests: XCTestCase {

    private func manifest(icon: String?) -> Data {
        let member = icon.map { ", \"icon\": \($0)" } ?? ""
        return Data("""
        {
          "protocol_version": "1.0", "engines": {"spinnet":"^1.0.0"}, "id": "com.example.iconic", "name": "Iconic",
          "version": "1.0.0"\(member),
          "commands": [{"id": "run", "title": "Run", "execution": "javascript", "script": "run.js"}]
        }
        """.utf8)
    }

    func testAPluginIconIsOptionalAndRoundTrips() throws {
        let declared = try PluginManifestLoader.decode(manifest(icon: #"{"symbol": "rectangle.split.2x1"}"#))
        XCTAssertEqual(declared.icon, .symbol("rectangle.split.2x1"))
        let encoded = try JSONEncoder().encode(declared)
        XCTAssertEqual(try PluginManifestLoader.decode(encoded).icon, .symbol("rectangle.split.2x1"))
        XCTAssertEqual(
            ((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["icon"] as? [String: String]),
            ["symbol": "rectangle.split.2x1"]
        )

        let plain = try PluginManifestLoader.decode(manifest(icon: nil))
        XCTAssertNil(plain.icon)
        XCTAssertNil((try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])?["icon"],
                     "A manifest without an icon encodes without one")
    }

    /// The same rule as a page `icon` component: lower-case letters, digits
    /// and dots, at most 64 characters.
    func testAnInvalidSymbolNameRefusesThePackageWithAReason() {
        let refused = [
            #"{"symbol": ""}"#, #"{"symbol": "Rectangle"}"#, #"{"symbol": ".cpu"}"#, #"{"symbol": "cpu."}"#,
            #"{"symbol": "a..b"}"#, #"{"symbol": "with space"}"#, #"{"symbol": "\#(String(repeating: "a", count: 65))"}"#,
            #"{"symbol": 7}"#, #"{}"#, #"{"symbol": "cpu", "template": true}"#, #""cpu""#, "null"
        ]
        for icon in refused {
            XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(icon: icon)), icon) { error in
                guard case ConfigurationError.invalidManifest(let reason)? = error as? ConfigurationError else {
                    return XCTFail("\(icon): \(error)")
                }
                XCTAssertTrue(reason.contains("icon"), "\(icon): \(reason)")
            }
        }
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest(icon: #"{"symbol": "\#(String(repeating: "a", count: 64))"}"#)))
    }

    func testThePresetCarriesItsPluginIcon() throws {
        let registry = PluginRegistry()
        let manifest = try PluginManifestLoader.decode(manifest(icon: #"{"symbol": "music.note"}"#))
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/iconic.spinnetplugin"), manifest: manifest))
        XCTAssertEqual(registry.menuItemPreset(for: manifest.id)?.icon, .symbol("music.note"))
    }

    /// A Plugin Icon is display-only: an update that changes only it keeps
    /// every configured Action available.
    func testAnIconOnlyUpdateKeepsConfiguredActionsAvailable() throws {
        let registry = PluginRegistry()
        let before = try PluginManifestLoader.decode(manifest(icon: nil))
        let root = URL(fileURLWithPath: "/tmp/iconic.spinnetplugin")
        try registry.register(PluginPackage(rootURL: root, manifest: before))
        let action = try ActionConfiguration(id: ActionID("run"), pluginID: before.id,
                                             command: before.commands[0], input: .null)
        XCTAssertEqual(registry.availability(for: action), .available)

        try registry.replace(PluginPackage(rootURL: root,
                                           manifest: PluginManifestLoader.decode(manifest(icon: #"{"symbol": "star"}"#))))
        XCTAssertEqual(registry.availability(for: action), .available)
        try registry.replace(PluginPackage(rootURL: root,
                                           manifest: PluginManifestLoader.decode(manifest(icon: #"{"symbol": "star.fill"}"#))))
        XCTAssertEqual(registry.availability(for: action), .available)
    }
}
