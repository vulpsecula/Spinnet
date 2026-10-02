import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The Candidate Probe run the way its author runs it, through the public
/// test kit and the real helper, against Hosts that do and do not provide
/// its candidate. A member belongs to the stable Levels and Candidate
/// Contracts that offer it, and a Plugin reaches it only by declaring one.
final class CandidateProbeRuntimeTests: XCTestCase {
    private let answers = RecordedHostServices([.detectLanguage: .value(.string("fr"))])
    private var helpers: [PluginTestHelper] = []

    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        helpers = []
    }

    private func helper(_ contracts: PluginInterfaceContracts) throws -> PluginTestHelper {
        let helper = try PluginTestHelper(contracts: contracts)
        helpers.append(helper)
        return helper
    }

    private func run(_ source: URL, on contracts: PluginInterfaceContracts) throws -> PluginTestRun {
        try helper(contracts).run(PluginTestInvocation("probe.detect"), of: PluginUnderTest(packageAt: source),
                                  answering: answers)
    }

    func testThePinnedRevisionReachesItsCandidateMember() throws {
        let run = try run(CandidateProbeFixture.package, on: CandidateProbeFixture.matchingHost())

        XCTAssertEqual(try run.answer().toast, "Language: fr")
        XCTAssertEqual(run.inputs(to: .detectLanguage), [.string("Bonjour tout le monde, comment allez-vous ?")])
    }

    /// The kit holds a run to the same revisions the Host installs, so an
    /// author learns of a mismatch before shipping.
    func testAMismatchedRevisionDoesNotRun() throws {
        let run = try run(CandidateProbeFixture.package,
                          on: CandidateProbeFixture.host(offering: [CandidateProbeFixture.contract(revision: 2)]))

        XCTAssertThrowsError(try run.result.get()) {
            XCTAssertEqual($0 as? PluginRuntimeError, .invalidAction(
                "Candidate Probe needs revision 1 of the language_probe Candidate Contract, but this version of "
                    + "Spinnet provides revision 2. Candidate revisions must match exactly."
            ))
        }
        XCTAssertEqual(run.requests, [], "No helper ran")
    }

    /// A member of a candidate the Plugin does not declare is refused, even
    /// though the Host provides it to Plugins that do.
    func testAnUndeclaredCandidateMemberIsRefused() throws {
        let undeclared = try CandidateProbeFixture.write { $0["candidate_contracts"] = nil }

        let run = try run(undeclared, on: CandidateProbeFixture.matchingHost())

        XCTAssertThrowsError(try run.result.get()) {
            XCTAssertEqual($0 as? PluginRuntimeError, .hostServiceFailed(
                "Host Service is unavailable: detect_language is not part of Plugin API Level 1 or a Candidate "
                    + "Contract Candidate Probe declares"
            ))
        }
        XCTAssertEqual(run.requests, [], "The request never reached the Host's services")
    }

    /// Promotion keeps behaviour: the revision declaring the new Level runs
    /// as the candidate revision did, the candidate revision no longer runs,
    /// and a Plugin still declaring only Level 1 still cannot reach it.
    func testPromotionMovesTheProbeOntoTheStableLevelWithTheSameResult() throws {
        let candidateHost = try CandidateProbeFixture.matchingHost()
        let stableHost = try candidateHost.promoting("language_probe", toLevel: 2)

        let before = try run(CandidateProbeFixture.package, on: candidateHost)
        let after = try run(CandidateProbeFixture.write(CandidateProbeFixture.promoted(to: 2)), on: stableHost)

        XCTAssertEqual(try after.result.get(), try before.result.get())
        XCTAssertEqual(after.requests, before.requests)
        XCTAssertThrowsError(try run(CandidateProbeFixture.package, on: stableHost).result.get())
        XCTAssertThrowsError(try run(CandidateProbeFixture.write { $0["candidate_contracts"] = nil },
                                     on: stableHost).result.get())
        XCTAssertEqual(stableHost.highestStableLevel, 2)
        XCTAssertTrue(stableHost.levels[1]!.isSubset(of: candidateHost.levels[1]!)
                      && candidateHost.levels[1]!.isSubset(of: stableHost.levels[1]!),
                      "Promotion leaves earlier stable vocabulary as it was")
    }

    /// Fetched sections are sent for the Plugins the Host under test runs,
    /// so the kit holds them to the same contracts.
    func testFetchedSectionsAreSentOnlyForAPluginTheHostRuns() throws {
        let plugin = try PluginUnderTest(packageAt: CandidateProbeFixture.package)
        let view = JSONValue.object(["title": .string("Probe"), "detail": .object(["sections": .array([
            .object(["id": .string("text"), "text": .string("Bonjour")])
        ])])])

        XCTAssertThrowsError(try RecordedHostFetchedSections().fetch(view, of: plugin, for: PluginTestInvocation("probe.detect")))
        XCTAssertEqual(try RecordedHostFetchedSections(contracts: CandidateProbeFixture.matchingHost())
            .fetch(view, of: plugin, for: PluginTestInvocation("probe.detect")), [])
    }

    /// `spinnet.environment.apiLevel` stays the highest stable Level the Host
    /// supports, whatever candidates it provides or the Plugin declares.
    func testTheEnvironmentReportsTheHighestStableLevel() throws {
        let source = try CandidateProbeFixture.write { _ in }
        try Data("spinnet.ui.toast(String(spinnet.environment.apiLevel))".utf8)
            .write(to: source.appendingPathComponent("detect.js"))

        XCTAssertEqual(try run(source, on: CandidateProbeFixture.matchingHost()).answer().toast, "1")
    }
}
