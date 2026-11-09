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

    // MARK: Package pictures

    func testAPackagePictureDeclarationRoundTrips() throws {
        let cases: [(String, IconPicture)] = [
            (#"{"image": "icons/mark.pdf"}"#, IconPicture(path: "icons/mark.pdf")),
            (#"{"image": "mark.png", "template": true}"#, IconPicture(path: "mark.png", isTemplate: true)),
            (#"{"image": "mark.png", "template": false, "dark_image": "mark-dark.png"}"#,
             IconPicture(path: "mark.png", darkPath: "mark-dark.png")),
            (#"{"image": "Mark.PDF", "dark_image": "dark/Mark.pdf"}"#, IconPicture(path: "Mark.PDF", darkPath: "dark/Mark.pdf"))
        ]
        for (json, picture) in cases {
            let declared = try PluginManifestLoader.decode(manifest(icon: json))
            XCTAssertEqual(declared.icon, .picture(picture), json)
            XCTAssertEqual(try PluginManifestLoader.decode(JSONEncoder().encode(declared)).icon, .picture(picture), json)
        }
    }

    /// Only a PNG or PDF path inside the package, and never a dark picture
    /// for a template one.
    func testAnInvalidPictureDeclarationRefusesThePackageWithAReason() {
        let refused = [
            #"{"image": "mark.jpg"}"#, #"{"image": "mark.svg"}"#, #"{"image": "mark"}"#, #"{"image": ""}"#,
            #"{"image": "/tmp/mark.png"}"#, #"{"image": "../mark.png"}"#, #"{"image": "icons/../../mark.png"}"#,
            #"{"image": "./mark.png"}"#, #"{"image": ".hidden.png"}"#, #"{"image": "a\\b.png"}"#,
            #"{"image": "\#(String(repeating: "a", count: 253)).png"}"#,
            #"{"image": 7}"#, #"{"image": "mark.png", "template": "yes"}"#,
            #"{"image": "mark.png", "dark_image": "mark.jpg"}"#,
            #"{"image": "mark.png", "template": true, "dark_image": "mark-dark.png"}"#,
            #"{"image": "mark.png", "symbol": "cpu"}"#, #"{"image": "mark.png", "tint": true}"#,
            #"{"dark_image": "mark.png"}"#
        ]
        for icon in refused {
            XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(icon: icon)), icon) { error in
                guard case ConfigurationError.invalidManifest(let reason)? = error as? ConfigurationError else {
                    return XCTFail("\(icon): \(error)")
                }
                XCTAssertTrue(reason.contains("icon"), "\(icon): \(reason)")
            }
        }
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest(icon: #"{"image": "\#(String(repeating: "a", count: 252)).png"}"#)))
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
