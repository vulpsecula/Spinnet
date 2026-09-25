import Foundation
import XCTest
@testable import SpinnetCore

/// The Library asks the user to allow an install before anything is copied, so
/// the store has to say what an install would do without doing it: which
/// Plugin would be registered, and which access it would ask for.
final class PluginInstallationReviewTests: XCTestCase {

    private func makeStore(
        shipping shipped: PluginPackage? = nil
    ) -> (URL, PluginRegistry, PluginCapabilityGrantStore, PluginInstallationStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginRegistry()
        let grants = PluginCapabilityGrantStore()
        return (directory, registry, grants, PluginInstallationStore(
            directory: directory, registry: registry, grants: grants, persistGrants: {},
            shippedPackages: { [shipped].compactMap { $0 } }
        ))
    }

    private func installedCopies(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "spinnetplugin" }
    }

    func testANewPluginAsksForEveryCapabilityItDeclaresAndNothingIsInstalledYet() throws {
        let (directory, registry, grants, store) = makeStore()

        let review = try store.review(ScriptedPackageFixture.write())

        XCTAssertEqual(review.manifest.id, ScriptedPackageFixture.pluginID)
        XCTAssertEqual(review.requestedAccess, [.readSelectedText, .writeClipboard])
        XCTAssertNil(registry.package(for: ScriptedPackageFixture.pluginID))
        XCTAssertTrue(try installedCopies(in: directory).isEmpty)
        XCTAssertTrue(grants.allGrants.isEmpty, "Reviewing records no decision")
    }

    func testAnUpdateAsksOnlyForAccessItCannotInherit() throws {
        let (_, _, grants, store) = makeStore()
        let manifest = try store.install(from: ScriptedPackageFixture.write())
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .readSelectedText, scope: manifest.scope(for: .readSelectedText))

        let review = try store.review(ScriptedPackageFixture.write())

        XCTAssertEqual(review.requestedAccess, [.writeClipboard],
                       "An unchanged scope keeps its decision; an undecided one is asked for")
    }

    func testAPluginThatNeedsANewerPluginAPILevelIsRefusedBeforeTheUserIsAsked() throws {
        let (_, _, _, store) = makeStore()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("Newer.spinnetplugin")
        addTeardownBlock { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("""
        {"protocol_version": "1.0", "api_level": 2, "id": "com.example.newer", "name": "Newer",
         "version": "1.0.0",
         "commands": [{"id": "newer.run", "title": "Run", "execution": "javascript", "script": "run.js"}]}
        """.utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("null".utf8).write(to: source.appendingPathComponent("run.js"))

        XCTAssertThrowsError(try store.review(source)) { error in
            let refusal = error as? UnsupportedPluginAPILevel
            XCTAssertEqual(refusal?.requiredLevel, 2)
            XCTAssertEqual(refusal?.supportedLevel, 1)
        }
    }

    /// A removed Bundled Plugin comes back by installing a copy of it, like
    /// any other Plugin. The Host registers the copy the app carries, since
    /// only that one keeps the Host Surface it shipped with, and the user is
    /// asked again for the access its removal forgot.
    func testACopyOfARemovedBundledPluginIsReviewedAsTheShippedOne() throws {
        let loaded = try ScriptedPackageFixture.load()
        let shipped = PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
        let (_, registry, grants, store) = makeStore(shipping: shipped)
        try registry.register(shipped)
        grants.setDecision(.granted, for: shipped.manifest.id, pluginVersion: shipped.manifest.version,
                           capability: .readSelectedText)
        try store.uninstall(shipped.manifest.id)

        let review = try store.review(ScriptedPackageFixture.write())

        XCTAssertEqual(review.manifest, shipped.manifest)
        XCTAssertEqual(review.requestedAccess, [.readSelectedText, .writeClipboard])
        XCTAssertTrue(try store.removedPluginIDs().contains(shipped.manifest.id), "Reviewing changes nothing")
        XCTAssertNil(registry.package(for: shipped.manifest.id))
    }
}
