import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// A Plugin author's tests load the package's Plugin Icon the way the Host
/// admits it, and see the same refusal the Host gives an invalid one.
final class PluginIconAdmissionTests: XCTestCase {
    private func package(icon: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Iconic.spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("""
        {"protocol_version": "1.0", "engines": {"spinnet": "^1.0.0"}, "id": "com.example.iconic",
         "name": "Iconic", "version": "1.0.0", "icon": \(icon),
         "commands": [{"id": "run", "title": "Run", "execution": "javascript", "script": "run.js"}]}
        """.utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data("null".utf8).write(to: root.appendingPathComponent("run.js"))
        return root
    }

    func testThePluginIconLoadsAsTheHostAdmitsIt() throws {
        let plugin = try PluginUnderTest(packageAt: package(icon: #"{"symbol": "macwindow"}"#))
        XCTAssertEqual(plugin.manifest.icon, .symbol("macwindow"))
    }

    func testAnInvalidSymbolIsRefusedWithAReason() throws {
        let url = try package(icon: #"{"symbol": "MacWindow"}"#)
        XCTAssertThrowsError(try PluginUnderTest(packageAt: url)) { error in
            XCTAssertTrue(String(describing: error).contains("icon"), "\(error)")
        }
    }
}
