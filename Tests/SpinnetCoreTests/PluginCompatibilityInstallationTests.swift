import Foundation
import XCTest
@testable import SpinnetCore

/// A Host update can refuse one package without losing its installed identity,
/// data or the other packages; a compatible replacement recovers the same data.
final class PluginCompatibilityInstallationTests: XCTestCase {
    private struct Launch {
        let registry: PluginRegistry
        let storage: PluginStorage
        let store: PluginInstallationStore
    }
    private var directory: URL!
    private var copies: [URL] = []
    private let grants = PluginCapabilityGrantStore()
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        copies.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
    }
    private func source(_ change: (inout [String: JSONValue]) -> Void = { _ in }) throws -> URL {
        let source = try CandidateProbeFixture.write(change); copies.append(source); return source
    }
    private func launch(_ version: String = "1.0.0") throws -> Launch {
        let registry = PluginRegistry(contracts: PluginInterfaceContracts(hostVersion: try HostVersion(version)), grantStore: grants)
        let storage = PluginStorage(directory: directory.appendingPathComponent("Storage"))
        return Launch(registry: registry, storage: storage,
            store: PluginInstallationStore(directory: directory.appendingPathComponent("Plugins"),
                registry: registry, grants: grants, persistGrants: {}, storage: storage))
    }
    private func action(in source: URL) throws -> ActionConfiguration {
        let manifest = try PluginManifestLoader.load(packageAt: source).manifest
        return try ActionConfiguration(id: .init("probe-action"), pluginID: manifest.id, command: manifest.commands[0], input: .null)
    }
    private func installedCopies() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Plugins"),
            includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "spinnetplugin" }
    }
    func testCompatiblePackageIsReviewedInstalledAndAvailable() throws {
        let host = try launch(), source = try source()
        let review = try host.store.review(source)
        try host.store.install(from: source)
        XCTAssertEqual(review.manifest.hostCompatibility.rawValue, "^1.0.0")
        XCTAssertEqual(host.registry.availability(for: try action(in: source)), .available)
    }
    func testIncompatibleReleaseRefusesOnlyTheProbeAndKeepsItsData() throws {
        let first = try launch("1.1.0"), source = try source {
            $0["engines"] = .object(["spinnet": .string("^1.1.0")])
        }
        let original = try first.store.install(from: source)
        let other = try first.store.install(from: ScriptedPackageFixture.write())
        try first.storage.setValue(.number(3), forKey: "runs", of: original.id)
        let next = try launch("1.0.0")
        try next.store.restore()
        XCTAssertNotNil(next.registry.package(for: other.id), "Other compatible Plugins still restore")
        XCTAssertNil(next.registry.package(for: original.id))
        let refused = try XCTUnwrap(next.registry.refusedPlugin(original.id))
        XCTAssertEqual(refused.manifest, original)
        XCTAssertEqual(refused.reason, UnsupportedPluginHostVersion(requiredBy: original, hostVersion: try HostVersion("1.0.0")).localizedDescription)
        let saved = try action(in: source)
        XCTAssertEqual(next.registry.availability(for: saved), .unavailable(.pluginRefused(refused.reason)))
        XCTAssertEqual(try next.storage.value(forKey: "runs", of: original.id), .number(3))
        XCTAssertEqual(installedCopies().count, 2)
        let recovered = try launch("1.1.0")
        try recovered.store.restore()
        XCTAssertEqual(recovered.registry.availability(for: saved), .available)
        XCTAssertEqual(recovered.registry.refusedPlugins(), [])
    }
    func testBrokenInstalledPackageDoesNotStopOtherRestores() throws {
        let first = try launch(), source = try source()
        try first.store.install(from: source)
        let other = try first.store.install(from: ScriptedPackageFixture.write())
        let root = try XCTUnwrap(first.registry.package(for: CandidateProbeFixture.pluginID)).rootURL
        try Data("{".utf8).write(to: root.appendingPathComponent("manifest.json"))
        let next = try launch(); try next.store.restore()
        XCTAssertNotNil(next.registry.package(for: other.id))
        let refusal = try XCTUnwrap(next.registry.refusedPlugin(CandidateProbeFixture.pluginID))
        XCTAssertNil(refusal.name)
        XCTAssertFalse(refusal.reason.isEmpty)
        XCTAssertEqual(next.registry.availability(for: try action(in: source)), .unavailable(.pluginRefused(refusal.reason)))
    }
    func testCompatibleRevisionReplacesRefusedCopyAndKeepsStorage() throws {
        let first = try launch(), source = try source()
        try first.store.install(from: source)
        try first.storage.setValue(.number(3), forKey: "runs", of: CandidateProbeFixture.pluginID)
        let next = try launch("2.0.0"); try next.store.restore()
        let replacement = try self.source {
            $0["engines"] = .object(["spinnet": .string("^2.0.0")]); $0["version"] = .string("1.1.0")
        }
        XCTAssertEqual(try next.store.review(replacement).requestedAccess, [])
        try next.store.install(from: replacement)
        XCTAssertEqual(next.registry.package(for: CandidateProbeFixture.pluginID)?.manifest.version, "1.1.0")
        XCTAssertEqual(next.registry.refusedPlugins(), [])
        XCTAssertEqual(try next.storage.value(forKey: "runs", of: CandidateProbeFixture.pluginID), .number(3))
        XCTAssertEqual(installedCopies().count, 1)
    }
    func testRemovingRefusedPluginForgetsItsStorageAndGrants() throws {
        let first = try launch(), source = try source()
        try first.store.install(from: source)
        try first.storage.setValue(.number(3), forKey: "runs", of: CandidateProbeFixture.pluginID)
        grants.setDecision(.granted, for: CandidateProbeFixture.pluginID, pluginVersion: "1.0.0", capability: .readSelectedText)
        let next = try launch("2.0.0"); try next.store.restore()
        try next.store.uninstall(CandidateProbeFixture.pluginID)
        XCTAssertEqual(next.registry.refusedPlugins(), [])
        XCTAssertEqual(next.registry.availability(for: try action(in: source)), .unavailable(.pluginMissing))
        XCTAssertTrue(installedCopies().isEmpty)
        XCTAssertTrue(grants.allGrants.allSatisfy { $0.pluginID != CandidateProbeFixture.pluginID })
        XCTAssertEqual(try next.storage.keys(of: CandidateProbeFixture.pluginID), [])
        let relaunched = try launch(); try relaunched.store.restore()
        XCTAssertNil(relaunched.registry.package(for: CandidateProbeFixture.pluginID))
    }
}
