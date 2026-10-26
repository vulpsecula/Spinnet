import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// Frozen retired declarations are refused before execution. Replacing one
/// with the same executable Commands and equal scopes preserves its data.
final class RetiredPluginDeclarationMigrationTests: XCTestCase {
    private static let retired = CandidateProbeFixture.fixtures.appendingPathComponent("RetiredCandidate.spinnetplugin")
    private static let pluginID = PluginID("com.example.retired-candidate")
    private static let reason = ConfigurationError.invalidManifest(PluginManifest.compatibilityMigrationMessage).localizedDescription
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
    private func replacement() throws -> URL {
        let copy = try ManifestVariant.write(Self.retired) {
            ManifestVariant.current(&$0); $0["version"] = .string("2.0.0")
        }
        copies.append(copy); return copy
    }
    private func host() -> (PluginRegistry, PluginStorage, PluginInstallationStore) {
        let registry = PluginRegistry(grantStore: grants)
        let storage = PluginStorage(directory: directory.appendingPathComponent("Storage"))
        return (registry, storage, PluginInstallationStore(directory: directory.appendingPathComponent("Plugins"),
            registry: registry, grants: grants, persistGrants: {}, storage: storage))
    }
    func testLegacyPackageIsRefusedByReviewInstallAndTestKitLoading() throws {
        let (registry, _, store) = host()
        XCTAssertThrowsError(try store.review(Self.retired)) { XCTAssertEqual($0.localizedDescription, Self.reason) }
        XCTAssertThrowsError(try store.install(from: Self.retired)) { XCTAssertEqual($0.localizedDescription, Self.reason) }
        XCTAssertThrowsError(try PluginUnderTest(packageAt: Self.retired)) { XCTAssertEqual($0.localizedDescription, Self.reason) }
        XCTAssertNil(registry.package(for: Self.pluginID))
    }
    func testReplacementOfLegacyRefusalPreservesSavedMenuStorageAndEqualScopeGrants() throws {
        let installed = directory.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.retired, to: installed.appendingPathComponent("retired.spinnetplugin"))
        try JSONEncoder().encode([Self.pluginID.rawValue: "retired.spinnetplugin"])
            .write(to: installed.appendingPathComponent("installed.json"))
        let source = try replacement()
        let manifest = try PluginManifestLoader.load(packageAt: source).manifest
        let (registry, storage, store) = host()
        let other = try store.install(from: ScriptedPackageFixture.write())
        try storage.setValue(.number(4), forKey: "shouts", of: Self.pluginID)
        for capability in [PluginCapability.readSelectedText, .writeClipboard] {
            grants.setDecision(.granted, for: Self.pluginID, pluginVersion: "1.0.0", capability: capability,
                scope: manifest.scope(for: capability))
        }
        let action = try ActionConfiguration(id: .init("saved-shout"), pluginID: Self.pluginID,
            command: manifest.commands[0], input: .null)
        let item = try MenuItemConfiguration(primaryActionID: action.id, alias: "My shout")
        let configuration = try HostConfiguration(actions: [action], menu: MenuConfiguration(slots: [.empty, .occupied(item)]))
        let saved = try JSONEncoder().encode(configuration)
        try store.restore()
        XCTAssertNotNil(registry.package(for: other.id))
        XCTAssertNil(registry.package(for: Self.pluginID))
        XCTAssertEqual(registry.refusedPlugins().map(\.reason), [Self.reason])
        XCTAssertEqual(registry.availability(for: action), .unavailable(.pluginRefused(Self.reason)))
        XCTAssertEqual(try storage.value(forKey: "shouts", of: Self.pluginID), .number(4))
        XCTAssertEqual(try store.review(source).requestedAccess, [], "Equal scopes inherit only existing decisions")
        try store.install(from: source)
        XCTAssertEqual(registry.refusedPlugins(), [])
        XCTAssertEqual(registry.availability(for: action), .available)
        XCTAssertEqual(try storage.value(forKey: "shouts", of: Self.pluginID), .number(4))
        XCTAssertEqual(try JSONDecoder().decode(HostConfiguration.self, from: saved), configuration)
        XCTAssertEqual(grants.decision(for: Self.pluginID, pluginVersion: "2.0.0", capability: .writeClipboard,
            scope: manifest.scope(for: .writeClipboard)), .granted)
        let (relaunched, _, restored) = host(); try restored.restore()
        XCTAssertNotNil(relaunched.package(for: Self.pluginID))
        XCTAssertEqual(relaunched.refusedPlugins(), [])
    }
}
