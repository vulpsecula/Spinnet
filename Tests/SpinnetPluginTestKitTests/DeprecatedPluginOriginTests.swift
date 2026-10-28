import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// Plugin repositories written before #109 still pass a Plugin Origin. The kit
/// keeps those calls compiling and ignores the origin: every Plugin loads as
/// an installed one.
@available(*, deprecated, message: "Exercises the deprecated origin shims")
final class DeprecatedPluginOriginTests: XCTestCase {
    func testOriginArgumentsStillCompileAndAreIgnored() throws {
        let root = try writePackage()
        for origin: PluginOrigin in [.bundled, .installed] {
            let loaded = try PluginUnderTest(packageAt: root, origin: origin)
            XCTAssertEqual(loaded.manifest.id.rawValue, "com.example.origin")
            XCTAssertEqual(loaded.package.origin, .installed)
            try PluginInterfaceContracts.host.check(loaded.manifest, origin: origin)

            let named = try PluginUnderTest(named: root.lastPathComponent, origin: origin,
                                            searchingFrom: root.deletingLastPathComponent()
                                                .appendingPathComponent("caller.swift").path)
            XCTAssertEqual(named.package.rootURL.standardizedFileURL, root.standardizedFileURL)

            let rebuilt = PluginPackage(rootURL: root, manifest: loaded.manifest, origin: origin)
            XCTAssertEqual(rebuilt.origin, .installed)
            XCTAssertTrue(rebuilt.isVisibleInLibrary)
        }
    }

    private func writePackage() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Origin.spinnetplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        {
          "protocol_version": "1.0", "engines": {"spinnet":"^1.0.0"}, "id": "com.example.origin",
          "name": "Origin Example", "version": "1.0.0", "capabilities": [],
          "commands": [
            {"id": "example.run", "title": "Run", "execution": "javascript", "is_configurable": false, "script": "run.js"}
          ]
        }
        """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "null".write(to: root.appendingPathComponent("run.js"), atomically: true, encoding: .utf8)
        return root
    }
}
