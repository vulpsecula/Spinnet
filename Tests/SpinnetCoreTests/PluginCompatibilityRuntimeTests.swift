import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// Current compatibility, member availability and real-helper results remain
/// separate checks after removing declaration-based historical modes.
final class PluginCompatibilityRuntimeTests: XCTestCase {
    private var helpers: [PluginTestHelper] = []
    private var copies: [URL] = []
    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        copies.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
    }
    private func source(_ change: (inout [String: JSONValue]) -> Void = { _ in }) throws -> URL {
        let copy = try CandidateProbeFixture.write(change); copies.append(copy); return copy
    }
    private func run(_ source: URL, on contracts: PluginInterfaceContracts = .host) throws -> PluginTestRun {
        let helper = try PluginTestHelper(contracts: contracts); helpers.append(helper)
        return try helper.run(.init("probe.detect"), of: PluginUnderTest(packageAt: source),
            answering: RecordedHostServices([.detectLanguage: .value(.string("fr"))]))
    }
    func testCompatiblePluginReachesTheCurrentMember() throws {
        let result = try run(source())
        XCTAssertEqual(try result.answer().toast, "Language: fr")
        XCTAssertEqual(result.inputs(to: .detectLanguage), [.string("Bonjour tout le monde, comment allez-vous ?")])
    }
    func testIncompatibleHostDoesNotStartTheScript() throws {
        let source = try source()
        let manifest = try PluginManifestLoader.load(packageAt: source).manifest
        let contracts = PluginInterfaceContracts(hostVersion: try HostVersion("2.0.0"))
        let result = try run(source, on: contracts)
        XCTAssertThrowsError(try result.result.get()) {
            XCTAssertEqual($0 as? PluginRuntimeError, .invalidAction(
                UnsupportedPluginHostVersion(requiredBy: manifest, hostVersion: contracts.hostVersion).localizedDescription))
        }
        XCTAssertEqual(result.requests, [])
    }
    func testUnavailableCurrentMemberIsRefusedBeforeReachingTheBroker() throws {
        let contracts = PluginInterfaceContracts(members: PluginInterfaceContracts.currentMembers.subtracting([CandidateProbeFixture.member]))
        let result = try run(source(), on: contracts)
        XCTAssertThrowsError(try result.result.get()) { XCTAssertTrue($0.localizedDescription.contains("text.detectLanguage")) }
        XCTAssertEqual(result.requests, [])
    }
    func testCompatibleHostReleasesHaveTheSameResultAndRequests() throws {
        let source = try source()
        let first = try run(source)
        let later = try run(source, on: PluginInterfaceContracts(hostVersion: HostVersion("1.9.0")))
        XCTAssertEqual(try first.result.get(), try later.result.get())
        XCTAssertEqual(first.requests.map(\.operation), later.requests.map(\.operation))
        XCTAssertEqual(first.requests.map(\.input), later.requests.map(\.input))
    }
    func testFetchedSectionsRequireACompatiblePluginEvenWithNoRequests() throws {
        let plugin = try PluginUnderTest(packageAt: source())
        let view = JSONValue.object(["title": .string("Probe"), "detail": .object(["sections": .array([
            .object(["id": .string("text"), "text": .string("Bonjour")])
        ])])])
        let contracts = PluginInterfaceContracts(hostVersion: try HostVersion("2.0.0"))
        XCTAssertThrowsError(try RecordedHostFetchedSections(contracts: contracts).fetch(view, of: plugin, for: .init("probe.detect")))
        XCTAssertEqual(try RecordedHostFetchedSections().fetch(view, of: plugin, for: .init("probe.detect")), [])
    }
    func testEnvironmentReportsTheActualHostVersionAndNoLevel() throws {
        let source = try source()
        try "({toast: spinnet.environment.hostVersion + ':' + String('apiLevel' in spinnet.environment)})"
            .write(to: source.appendingPathComponent("detect.js"), atomically: true, encoding: .utf8)
        let result = try run(source, on: PluginInterfaceContracts(hostVersion: HostVersion("1.9.0")))
        XCTAssertEqual(try result.answer().toast, "1.9.0:false")
    }
}
