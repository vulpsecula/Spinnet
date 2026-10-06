import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// Moving a Plugin from the retired candidates to Plugin API Level 2 (#79).
/// `Tests/Fixtures/RetiredCandidate.spinnetplugin` still declares
/// `namespaces` r1 at Level 1, as an external Plugin installed before
/// promotion does. On the promoted Host it is refused everywhere the Host
/// checks a Plugin, with the Level to declare instead, while the user's data
/// stays; its Level 2 revision installs over it as an update.
final class LevelTwoMigrationTests: XCTestCase {
    private struct Launch {
        let registry: PluginRegistry
        let storage: PluginStorage
        let store: PluginInstallationStore
    }

    private static let retired = NamespacesProbeFixture.fixtures.appendingPathComponent("RetiredCandidate.spinnetplugin")
    private static let pluginID = PluginID("com.example.retired-candidate")
    private static let reason = "Retired Candidate declares revision 1 of the namespaces Candidate Contract, which "
        + "became Plugin API Level 2. Install a revision of the Plugin that declares Level 2 instead."

    private var directory: URL!
    private let grants = PluginCapabilityGrantStore()
    private var helpers: [PluginTestHelper] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        helpers.forEach { $0.shutdown() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func launch(_ contracts: PluginInterfaceContracts) -> Launch {
        let registry = PluginRegistry(contracts: contracts, grantStore: grants)
        let storage = PluginStorage(directory: directory.appendingPathComponent("Storage"))
        return Launch(registry: registry, storage: storage,
                      store: PluginInstallationStore(directory: directory.appendingPathComponent("Plugins"),
                                                     registry: registry, grants: grants, persistGrants: {},
                                                     storage: storage))
    }

    /// The fixture's Level 2 revision: the same Plugin declaring Level 2.
    private func levelTwoRevision() throws -> URL {
        try CandidateVariant.write(Self.retired) { manifest in
            manifest["api_level"] = .number(2)
            manifest["candidate_contracts"] = nil
            manifest["version"] = .string("2.0.0")
        }
    }

    private func shoutAction(in registry: PluginRegistry) throws -> ActionConfiguration {
        let manifest = try PluginManifestLoader.load(packageAt: Self.retired).manifest
        return try ActionConfiguration(id: ActionID("shout"), pluginID: manifest.id, command: manifest.commands[0],
                                       input: .null)
    }

    func testTheRetiredDeclarationIsRefusedForReviewAndInstallNamingLevelTwo() throws {
        let host = launch(.host)

        XCTAssertThrowsError(try host.store.review(Self.retired)) { XCTAssertEqual($0.localizedDescription, Self.reason) }
        XCTAssertThrowsError(try host.store.install(from: Self.retired)) {
            XCTAssertEqual($0.localizedDescription, Self.reason)
        }
        XCTAssertNil(host.registry.package(for: Self.pluginID))
    }

    /// A run is checked again: the kit, holding a Plugin to this Host, fails
    /// the retired declaration before the script starts.
    func testARunOfTheRetiredDeclarationFailsBeforeTheScriptStarts() throws {
        let helper = try PluginTestHelper()
        helpers.append(helper)
        let run = helper.run(PluginTestInvocation("probe.shout"), of: try PluginUnderTest(packageAt: Self.retired),
                             answering: RecordedHostServices())

        XCTAssertThrowsError(try run.result.get()) {
            XCTAssertEqual($0 as? PluginRuntimeError, .invalidAction(Self.reason))
        }
        XCTAssertEqual(run.requests, [])
    }

    /// The user installed the Plugin on the candidate Host. On the promoted
    /// Host it is a Refused Plugin with the reason, its Menu Items are
    /// unavailable with it, and its storage and decisions are kept; the
    /// other Plugins restore. Its Level 2 revision installs over it as an
    /// update that keeps them.
    func testUpdatingARefusedCandidatePluginToItsLevelTwoRevisionKeepsItsData() throws {
        let candidate = launch(.candidateHost)
        try candidate.store.install(from: Self.retired)
        let other = try candidate.store.install(from: ScriptedPackageFixture.write())
        _ = try candidate.storage.answer(.setStorageValue, input: .object(["key": .string("shouts"), "value": .number(4)]),
                                         for: Self.pluginID)
        let manifest = try PluginManifestLoader.load(packageAt: Self.retired).manifest
        for capability in [PluginCapability.readSelectedText, .writeClipboard] {
            grants.setDecision(.granted, for: Self.pluginID, pluginVersion: "1.0.0", capability: capability,
                               scope: manifest.scope(for: capability))
        }

        let promoted = launch(.host)
        try promoted.store.restore()

        XCTAssertNotNil(promoted.registry.package(for: other.id), "The other Plugin restores")
        XCTAssertNil(promoted.registry.package(for: Self.pluginID))
        XCTAssertEqual(promoted.registry.refusedPlugins().map(\.reason), [Self.reason])
        let action = try shoutAction(in: promoted.registry)
        XCTAssertEqual(promoted.registry.availability(for: action), .unavailable(.pluginRefused(Self.reason)))
        XCTAssertEqual(try promoted.storage.answer(.getStorageValue, input: .string("shouts"), for: Self.pluginID),
                       .number(4))

        let update = try levelTwoRevision()
        XCTAssertEqual(try promoted.store.review(update).requestedAccess, [], "Nothing new to ask for")
        try promoted.store.install(from: update)

        let installed = try XCTUnwrap(promoted.registry.package(for: Self.pluginID))
        XCTAssertEqual(installed.manifest.apiLevel, 2)
        XCTAssertEqual(installed.manifest.version, "2.0.0")
        XCTAssertEqual(promoted.registry.refusedPlugins(), [])
        XCTAssertEqual(promoted.registry.availability(for: action), .available)
        XCTAssertEqual(try promoted.storage.answer(.getStorageValue, input: .string("shouts"), for: Self.pluginID),
                       .number(4))
        XCTAssertEqual(grants.decision(for: Self.pluginID, pluginVersion: "2.0.0", capability: .writeClipboard,
                                       scope: installed.manifest.scope(for: .writeClipboard)), .granted)

        let relaunched = launch(.host)
        try relaunched.store.restore()
        XCTAssertNotNil(relaunched.registry.package(for: Self.pluginID), "The update reopens on the next launch")
        XCTAssertEqual(relaunched.registry.refusedPlugins(), [])
    }

    /// The Level 2 revision does what the candidate revision did: the same
    /// script, the same IDs, the same result.
    func testTheLevelTwoRevisionRunsAsTheCandidateRevisionDid() throws {
        let services = RecordedHostServices(operations: [
            "selection.readText": .value(.string("hello")), "clipboard.write": .value(.null)
        ])
        let candidateHelper = try PluginTestHelper(contracts: .candidateHost)
        let levelTwoHelper = try PluginTestHelper()
        helpers += [candidateHelper, levelTwoHelper]

        let before = candidateHelper.run(PluginTestInvocation("probe.shout"), of: try PluginUnderTest(packageAt: Self.retired),
                                         answering: services)
        let after = levelTwoHelper.run(PluginTestInvocation("probe.shout"),
                                       of: try PluginUnderTest(packageAt: levelTwoRevision()), answering: services)

        XCTAssertEqual(try after.result.get(), try before.result.get())
        XCTAssertEqual(after.performed, before.performed)
        XCTAssertEqual(after.performed.map(\.id), ["selection.readText", "clipboard.write"])
    }
}
