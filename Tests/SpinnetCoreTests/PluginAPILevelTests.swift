import Foundation
import XCTest
@testable import SpinnetCore

/// A manifest's `api_level` is the lowest Plugin API Level the Plugin needs
/// (ADR 0013). The Host declares the highest level it supports and refuses to
/// install a Plugin that needs more.
final class PluginAPILevelTests: XCTestCase {
    private func manifest(apiLevel: String?) -> Data {
        let member = apiLevel.map { "\"api_level\": \($0)," } ?? ""
        return Data("""
        {
          "protocol_version": "1.0",
          \(member)
          "id": "com.example.level",
          "name": "Level",
          "version": "1.0.0",
          "commands": [{"id": "level.run", "title": "Run", "execution": "javascript", "script": "run.js"}]
        }
        """.utf8)
    }

    func testAManifestDeclaresTheLevelItNeeds() throws {
        let manifest = try PluginManifestLoader.decode(manifest(apiLevel: "1"))

        XCTAssertEqual(manifest.apiLevel, 1)
    }

    /// Level 1 is the first level, so a manifest written before the field
    /// existed needs Level 1 and nothing newer.
    func testAManifestWithoutALevelNeedsLevelOne() throws {
        let manifest = try PluginManifestLoader.decode(manifest(apiLevel: nil))

        XCTAssertEqual(manifest.apiLevel, 1)
    }

    func testALevelMustBeAPositiveWholeNumber() {
        for level in ["0", "-1", "1.5", "\"1\"", "null"] {
            XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(apiLevel: level)), level)
        }
    }

    private func writePackage(apiLevel: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Level-\(UUID().uuidString).spinnetplugin", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try manifest(apiLevel: String(apiLevel)).write(to: root.appendingPathComponent("manifest.json"))
        try Data("null".utf8).write(to: root.appendingPathComponent("run.js"))
        return root
    }

    private func makeStore() -> (URL, PluginRegistry, PluginInstallationStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginRegistry()
        return (directory, registry, PluginInstallationStore(
            directory: directory, registry: registry, grants: PluginCapabilityGrantStore(), persistGrants: {}
        ))
    }

    func testInstallingAPluginThatNeedsANewerLevelIsRefusedWithTheUpdateMessage() throws {
        let (directory, registry, store) = makeStore()
        let source = try writePackage(apiLevel: PluginAPILevel.highestSupported + 1)

        XCTAssertThrowsError(try store.install(from: source)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Level needs Plugin API Level 2, but this version of Spinnet supports up to Level 1. "
                    + "Update Spinnet to install it."
            )
        }
        XCTAssertNil(registry.package(for: PluginID("com.example.level")))
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(leftovers.contains { $0.pathExtension == "spinnetplugin" },
                       "A refused package must not be copied into the install directory")
    }

    func testInstallingAPluginAtTheSupportedLevelSucceeds() throws {
        let (_, registry, store) = makeStore()

        try store.install(from: writePackage(apiLevel: PluginAPILevel.highestSupported))

        XCTAssertEqual(registry.package(for: PluginID("com.example.level"))?.manifest.apiLevel, 1)
    }
}
