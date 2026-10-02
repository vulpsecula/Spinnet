import Foundation
import XCTest
@testable import SpinnetCore

/// A Plugin that declares a Candidate Contract names its exact revision
/// (ADR 0013). Installing it, reviewing it and registering it at launch all
/// hold it to the revisions this Host provides, and one installed Plugin the
/// Host can no longer run is left a Refused Plugin, with its reason, while
/// every other Plugin restores.
final class CandidateContractInstallationTests: XCTestCase {
    private struct Launch {
        let directory: URL
        let registry: PluginRegistry
        let grants: PluginCapabilityGrantStore
        let storage: PluginStorage
        let store: PluginInstallationStore
    }

    private var directory: URL!
    private let grants = PluginCapabilityGrantStore()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One launch of a Host providing `contracts`, over the same installed
    /// packages, decisions and Plugin Storage as every other launch here.
    private func launch(_ contracts: PluginInterfaceContracts) -> Launch {
        let registry = PluginRegistry(contracts: contracts, grantStore: grants)
        let storage = PluginStorage(directory: directory.appendingPathComponent("Storage"))
        return Launch(directory: directory, registry: registry, grants: grants, storage: storage,
                      store: PluginInstallationStore(directory: directory.appendingPathComponent("Plugins"),
                                                     registry: registry, grants: grants, persistGrants: {},
                                                     storage: storage))
    }

    private func installedCopies() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Plugins"), includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "spinnetplugin" }
    }

    private func assertRefused(_ source: URL, by host: Launch, with message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try host.store.review(source), file: file, line: line) {
            XCTAssertEqual($0.localizedDescription, message, file: file, line: line)
        }
        XCTAssertThrowsError(try host.store.install(from: source), file: file, line: line) {
            XCTAssertEqual($0.localizedDescription, message, file: file, line: line)
        }
        XCTAssertNil(host.registry.package(for: CandidateProbeFixture.pluginID), file: file, line: line)
        XCTAssertTrue(installedCopies().isEmpty, "A refused package is not copied", file: file, line: line)
    }

    private func probeAction(in registry: PluginRegistry) throws -> ActionConfiguration {
        let manifest = try PluginManifestLoader.load(packageAt: CandidateProbeFixture.package).manifest
        return try ActionConfiguration(id: ActionID("probe-action"), pluginID: manifest.id,
                                       command: manifest.commands[0], input: .null)
    }

    // MARK: Review and install

    func testThePinnedRevisionIsReviewedAndInstalled() throws {
        let host = launch(try CandidateProbeFixture.matchingHost())

        let review = try host.store.review(CandidateProbeFixture.package)
        try host.store.install(from: CandidateProbeFixture.package)

        XCTAssertEqual(review.manifest.candidateContracts, [CandidateContractRevision(name: "language_probe", revision: 1)])
        XCTAssertEqual(review.manifest.apiLevel, 1, "A candidate does not raise the stable Level the Plugin needs")
        XCTAssertEqual(host.registry.availability(for: try probeAction(in: host.registry)), .available)
    }

    func testAnotherRevisionOfTheCandidateIsRefusedBeforeTheUserIsAsked() throws {
        let host = launch(CandidateProbeFixture.host(offering: [try CandidateProbeFixture.contract(revision: 2)]))

        assertRefused(CandidateProbeFixture.package, by: host, with:
            "Candidate Probe needs revision 1 of the language_probe Candidate Contract, but this version of Spinnet "
                + "provides revision 2. Candidate revisions must match exactly.")
    }

    func testACandidateThisHostDoesNotProvideIsRefused() throws {
        let host = launch(CandidateProbeFixture.host(offering: []))

        assertRefused(CandidateProbeFixture.package, by: host, with:
            "Candidate Probe needs revision 1 of the language_probe Candidate Contract, which this version of "
                + "Spinnet does not provide.")
    }

    func testAnUnsupportedStableLevelIsRefusedWithTheUpdateMessageFirst() throws {
        let host = launch(try CandidateProbeFixture.matchingHost())
        let source = try CandidateProbeFixture.write { $0["api_level"] = .number(2) }

        assertRefused(source, by: host, with:
            "Candidate Probe needs Plugin API Level 2, but this version of Spinnet supports up to Level 1. "
                + "Update Spinnet to install it.")
    }

    func testACandidateNeedsTheCandidatesItDependsOn() throws {
        let base = try CandidateProbeFixture.contract()
        let dependent = CandidateContract(name: base.name, revision: base.revision, baseLevel: 1,
                                          requires: [CandidateContractRevision(name: "text_probe", revision: 3)],
                                          members: base.members, tag: base.tag)
        let textProbe = CandidateContract(name: "text_probe", revision: 3, baseLevel: 1, members: [],
                                          tag: "plugin-api-candidate/text_probe/r3")
        let host = launch(CandidateProbeFixture.host(offering: [dependent, textProbe]))

        assertRefused(CandidateProbeFixture.package, by: host, with:
            "Revision 1 of the language_probe Candidate Contract needs revision 3 of the text_probe Candidate "
                + "Contract, which Candidate Probe does not declare.")

        try host.store.install(from: CandidateProbeFixture.write(
            CandidateProbeFixture.declaring([("language_probe", 1), ("text_probe", 3)])
        ))
        XCTAssertNotNil(host.registry.package(for: CandidateProbeFixture.pluginID))
    }

    func testCandidatesThatConflictCannotBeDeclaredTogether() throws {
        let base = try CandidateProbeFixture.contract()
        let conflicting = CandidateContract(name: base.name, revision: base.revision, baseLevel: 1,
                                            conflicts: ["other_probe"], members: base.members, tag: base.tag)
        let other = CandidateContract(name: "other_probe", revision: 1, baseLevel: 1, members: [],
                                      tag: "plugin-api-candidate/other_probe/r1")
        let host = launch(CandidateProbeFixture.host(offering: [conflicting, other]))

        assertRefused(try CandidateProbeFixture.write(
            CandidateProbeFixture.declaring([("language_probe", 1), ("other_probe", 1)])
        ), by: host, with: "Candidate Probe declares the language_probe and other_probe Candidate Contracts, "
            + "which cannot be used together.")
    }

    func testACandidateBuildsOnTheStableLevelItNames() throws {
        let base = try CandidateProbeFixture.contract()
        let onLevelTwo = CandidateContract(name: base.name, revision: base.revision, baseLevel: 2,
                                           members: base.members, tag: base.tag)
        let host = launch(PluginInterfaceContracts(
            levels: [1: PluginInterfaceContracts.levelOneMembers.subtracting([CandidateProbeFixture.member]), 2: []],
            candidates: [onLevelTwo]
        ))

        assertRefused(CandidateProbeFixture.package, by: host, with:
            "Revision 1 of the language_probe Candidate Contract builds on Plugin API Level 2, but Candidate Probe "
                + "declares Level 1.")
    }

    /// The Host decides where a Plugin came from, and a shipped one may use
    /// only stable contracts, so launching with one that declares a candidate
    /// is refused like any other broken build.
    func testABundledPluginCannotDeclareACandidate() throws {
        let host = launch(try CandidateProbeFixture.matchingHost())
        let loaded = try PluginManifestLoader.load(packageAt: CandidateProbeFixture.package)

        XCTAssertThrowsError(try host.registry.register(PluginPackage(
            rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled
        ))) {
            XCTAssertEqual($0.localizedDescription, "Candidate Probe ships with Spinnet, so it may use only stable "
                + "Plugin API Levels, not the language_probe Candidate Contract.")
        }
        XCTAssertNil(host.registry.package(for: CandidateProbeFixture.pluginID))
    }

    func testADeclarationNamesEachCandidateOnceAtARealRevision() {
        for (name, change) in [
            ("revision 0", CandidateProbeFixture.declaring([("language_probe", 0)])),
            ("the same candidate twice", CandidateProbeFixture.declaring([("language_probe", 1), ("language_probe", 2)])),
            ("a name that is not an identifier", CandidateProbeFixture.declaring([("Language Probe", 1)])),
            ("a fractional revision", { $0["candidate_contracts"] = .array([
                .object(["name": .string("language_probe"), "revision": .number(1.5)])
            ]) })
        ] as [(String, (inout [String: JSONValue]) -> Void)] {
            XCTAssertThrowsError(try PluginManifestLoader.load(packageAt: CandidateProbeFixture.write(change)), name)
        }
    }

    // MARK: Promotion

    /// Promotion makes the candidate's members the next stable Level and
    /// retires its declaration: the revision that declared it is refused with
    /// what to install instead, and the revision declaring the Level runs.
    func testAPromotedCandidateIsRefusedAndItsStableLevelInstalls() throws {
        let host = launch(try CandidateProbeFixture.matchingHost().promoting("language_probe", toLevel: 2))

        assertRefused(CandidateProbeFixture.package, by: host, with:
            "Candidate Probe declares revision 1 of the language_probe Candidate Contract, which became Plugin API "
                + "Level 2. Install a revision of the Plugin that declares Level 2 instead.")

        try host.store.install(from: CandidateProbeFixture.write(CandidateProbeFixture.promoted(to: 2)))
        XCTAssertEqual(host.registry.package(for: CandidateProbeFixture.pluginID)?.manifest.apiLevel, 2)
    }

    // MARK: Restoring at launch

    /// The same Library on a Host that no longer provides the revision: the
    /// probe is a Refused Plugin with the reason, distinct from a removed one,
    /// and nothing the user kept is lost. Going back to a Host that provides
    /// it makes it available again.
    func testADowngradedHostRefusesOnlyTheProbeAndKeepsItsData() throws {
        let first = launch(try CandidateProbeFixture.matchingHost())
        try first.store.install(from: CandidateProbeFixture.package)
        let other = try first.store.install(from: ScriptedPackageFixture.write())
        _ = try first.storage.answer(.setStorageValue, input: .object(["key": .string("runs"), "value": .number(3)]),
                                     for: CandidateProbeFixture.pluginID)

        let downgraded = launch(CandidateProbeFixture.host(offering: []))
        try downgraded.store.restore()

        XCTAssertNotNil(downgraded.registry.package(for: other.id), "The other Plugin restores")
        XCTAssertNil(downgraded.registry.package(for: CandidateProbeFixture.pluginID))
        let reason = "Candidate Probe needs revision 1 of the language_probe Candidate Contract, which this version "
            + "of Spinnet does not provide."
        let refused = try XCTUnwrap(downgraded.registry.refusedPlugins().first)
        XCTAssertEqual(downgraded.registry.refusedPlugins().count, 1)
        XCTAssertEqual(refused.id, CandidateProbeFixture.pluginID)
        XCTAssertEqual(refused.name, "Candidate Probe")
        XCTAssertEqual(refused.reason, reason)
        let action = try probeAction(in: downgraded.registry)
        XCTAssertEqual(downgraded.registry.availability(for: action), .unavailable(.pluginRefused(reason)))
        XCTAssertEqual(ActionUnavailableReason.pluginRefused(reason).description, reason)
        XCTAssertEqual(try downgraded.storage.answer(.getStorageValue, input: .string("runs"),
                                                     for: CandidateProbeFixture.pluginID), .number(3))
        XCTAssertEqual(installedCopies().count, 2, "The refused package stays installed")

        let upgraded = launch(try CandidateProbeFixture.matchingHost())
        try upgraded.store.restore()
        XCTAssertEqual(upgraded.registry.availability(for: action), .available)
        XCTAssertEqual(upgraded.registry.refusedPlugins(), [])
    }

    func testABrokenInstalledPackageDoesNotStopTheOthersFromRestoring() throws {
        let first = launch(try CandidateProbeFixture.matchingHost())
        try first.store.install(from: CandidateProbeFixture.package)
        let other = try first.store.install(from: ScriptedPackageFixture.write())
        let probeCopy = try XCTUnwrap(first.registry.package(for: CandidateProbeFixture.pluginID)).rootURL
        try Data("{".utf8).write(to: probeCopy.appendingPathComponent("manifest.json"))

        let relaunched = launch(try CandidateProbeFixture.matchingHost())
        try relaunched.store.restore()

        XCTAssertNotNil(relaunched.registry.package(for: other.id))
        let refused = try XCTUnwrap(relaunched.registry.refusedPlugins().first)
        XCTAssertEqual(refused.id, CandidateProbeFixture.pluginID)
        XCTAssertNil(refused.name, "A manifest that cannot be read has no name to show")
        XCTAssertFalse(refused.reason.isEmpty)
        XCTAssertEqual(relaunched.registry.availability(for: try probeAction(in: relaunched.registry)),
                       .unavailable(.pluginRefused(refused.reason)))
    }

    /// Installing a revision the Host can run over a Refused Plugin is
    /// an update: it keeps the Plugin's storage and the decisions on scopes
    /// it did not change.
    func testInstallingARunnableRevisionOverARefusedPluginIsAnUpdate() throws {
        let first = launch(try CandidateProbeFixture.matchingHost())
        try first.store.install(from: CandidateProbeFixture.package)
        _ = try first.storage.answer(.setStorageValue, input: .object(["key": .string("runs"), "value": .number(3)]),
                                     for: CandidateProbeFixture.pluginID)
        let downgraded = launch(CandidateProbeFixture.host(offering: []))
        try downgraded.store.restore()

        let source = try CandidateProbeFixture.write { $0["candidate_contracts"] = nil; $0["version"] = .string("1.1.0") }
        XCTAssertEqual(try downgraded.store.review(source).requestedAccess, [])
        try downgraded.store.install(from: source)

        XCTAssertEqual(downgraded.registry.package(for: CandidateProbeFixture.pluginID)?.manifest.version, "1.1.0")
        XCTAssertEqual(downgraded.registry.refusedPlugins(), [])
        XCTAssertEqual(try downgraded.storage.answer(.getStorageValue, input: .string("runs"),
                                                     for: CandidateProbeFixture.pluginID), .number(3))
        XCTAssertEqual(installedCopies().count, 1, "The refused copy is replaced")
    }

    func testRemovingARefusedPluginRemovesItForGood() throws {
        let first = launch(try CandidateProbeFixture.matchingHost())
        try first.store.install(from: CandidateProbeFixture.package)
        _ = try first.storage.answer(.setStorageValue, input: .object(["key": .string("runs"), "value": .number(3)]),
                                     for: CandidateProbeFixture.pluginID)
        grants.setDecision(.granted, for: CandidateProbeFixture.pluginID, pluginVersion: "1.0.0",
                           capability: .readSelectedText)
        let downgraded = launch(CandidateProbeFixture.host(offering: []))
        try downgraded.store.restore()

        try downgraded.store.uninstall(CandidateProbeFixture.pluginID)

        XCTAssertEqual(downgraded.registry.refusedPlugins(), [])
        XCTAssertEqual(downgraded.registry.availability(for: try probeAction(in: downgraded.registry)),
                       .unavailable(.pluginMissing))
        XCTAssertTrue(installedCopies().isEmpty)
        XCTAssertTrue(grants.allGrants.allSatisfy { $0.pluginID != CandidateProbeFixture.pluginID })
        XCTAssertEqual(try downgraded.storage.answer(.listStorageKeys, input: .null,
                                                     for: CandidateProbeFixture.pluginID), .array([]))
        let relaunched = launch(try CandidateProbeFixture.matchingHost())
        try relaunched.store.restore()
        XCTAssertNil(relaunched.registry.package(for: CandidateProbeFixture.pluginID))
    }
}
