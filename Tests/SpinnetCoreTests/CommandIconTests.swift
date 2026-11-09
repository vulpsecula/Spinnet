import XCTest
@testable import SpinnetCore

/// A Command may declare its own Command Icon, in the same shape as the
/// Plugin Icon, so Menu Items made from one Plugin look different when they
/// do different things. Like a Command's `description`, it is display-only.
final class CommandIconTests: XCTestCase {

    private func manifest(commandIcon: String?) -> Data {
        let member = commandIcon.map { ", \"icon\": \($0)" } ?? ""
        return Data("""
        {
          "protocol_version": "1.0", "engines": {"spinnet":"^1.0.0"}, "id": "com.example.iconic", "name": "Iconic",
          "version": "1.0.0",
          "commands": [{"id": "run", "title": "Run", "execution": "javascript", "script": "run.js"\(member)},
                       {"id": "plain", "title": "Plain", "execution": "javascript", "script": "run.js"}]
        }
        """.utf8)
    }

    func testACommandIconIsOptionalAndRoundTrips() throws {
        let cases: [(String, IconDeclaration)] = [
            (#"{"symbol": "arrow.up.left.and.arrow.down.right"}"#, .symbol("arrow.up.left.and.arrow.down.right")),
            (#"{"image": "icons/run.pdf", "template": true}"#, .picture(IconPicture(path: "icons/run.pdf", isTemplate: true))),
            (#"{"image": "run.png", "dark_image": "run-dark.png"}"#,
             .picture(IconPicture(path: "run.png", darkPath: "run-dark.png")))
        ]
        for (json, icon) in cases {
            let declared = try PluginManifestLoader.decode(manifest(commandIcon: json))
            XCTAssertEqual(declared.commands[0].icon, icon, json)
            XCTAssertNil(declared.commands[1].icon, "A Command without an icon has none")
            XCTAssertNil(declared.icon, "A Command Icon is not the Plugin Icon")
            let encoded = try JSONEncoder().encode(declared)
            XCTAssertEqual(try PluginManifestLoader.decode(encoded).commands[0].icon, icon, json)
        }
        let plain = try PluginManifestLoader.decode(manifest(commandIcon: nil))
        let command = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain.commands[0])) as? [String: Any]
        XCTAssertNil(command?["icon"], "A Command without an icon encodes without one")
    }

    /// The same rule and reasons as the Plugin Icon, naming the Command.
    func testAnInvalidCommandIconRefusesThePackageWithAReason() {
        let refused = [
            #"{"symbol": "Rectangle"}"#, #"{"symbol": ""}"#, #"{}"#, #""cpu""#, "null",
            #"{"symbol": "cpu", "template": true}"#, #"{"image": "mark.jpg"}"#, #"{"image": "../mark.png"}"#,
            #"{"image": "mark.png", "template": true, "dark_image": "mark-dark.png"}"#, #"{"dark_image": "mark.png"}"#
        ]
        for icon in refused {
            XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(commandIcon: icon)), icon) { error in
                guard case ConfigurationError.invalidManifest(let reason)? = error as? ConfigurationError else {
                    return XCTFail("\(icon): \(error)")
                }
                XCTAssertTrue(reason.contains("icon"), "\(icon): \(reason)")
                XCTAssertTrue(reason.contains("run"), "\(icon): the reason names the Command: \(reason)")
            }
        }
    }

    /// A Command Icon is shown, not executed, so changing it must not turn a
    /// configured Action into a changed Command.
    func testChangingOnlyACommandIconKeepsConfiguredActionsAvailable() throws {
        let registry = PluginRegistry()
        let root = URL(fileURLWithPath: "/tmp/iconic.spinnetplugin")
        let before = try PluginManifestLoader.decode(manifest(commandIcon: nil))
        try registry.register(PluginPackage(rootURL: root, manifest: before))
        let action = try ActionConfiguration(id: ActionID("run"), pluginID: before.id,
                                             command: before.commands[0], input: .null)
        XCTAssertEqual(registry.availability(for: action), .available)
        for icon in [#"{"symbol": "star"}"#, #"{"image": "run.pdf"}"#] {
            try registry.replace(PluginPackage(rootURL: root, manifest: PluginManifestLoader.decode(manifest(commandIcon: icon))))
            XCTAssertEqual(registry.availability(for: action), .available, icon)
        }
    }
}
