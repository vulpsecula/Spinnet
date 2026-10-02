import Foundation
@testable import SpinnetCore

/// `Tests/Fixtures/CandidateProbe.spinnetplugin` is a tiny external Plugin
/// that declares the `language_probe` Candidate Contract, revision 1, whose
/// published metadata is `Tests/Fixtures/Candidates/language_probe/r1`. The
/// real Host offers no Candidate Contract yet, so these tests stand up Hosts
/// that do: Level 1 without `detect_language`, which only the candidate
/// offers, the way a provisional addition reaches a Host before it is stable.
enum CandidateProbeFixture {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
    static let package = fixtures.appendingPathComponent("CandidateProbe.spinnetplugin", isDirectory: true)
    static let metadata = fixtures.appendingPathComponent("Candidates/language_probe/r1/candidate.json")
    static let pluginID = PluginID("com.example.candidate-probe")
    static let member = PluginInterfaceMember.hostService("detect_language")

    /// The candidate as its published metadata pins it.
    static func contract() throws -> CandidateContract {
        try JSONDecoder().decode(CandidateContract.self, from: Data(contentsOf: metadata))
    }

    /// The same candidate at another revision, as a later attempt publishes it.
    static func contract(revision: Int) throws -> CandidateContract {
        let pinned = try contract()
        return CandidateContract(name: pinned.name, revision: revision, baseLevel: pinned.baseLevel,
                                 members: pinned.members, tag: "plugin-api-candidate/language_probe/r\(revision)")
    }

    /// Level 1 without the probe's member, plus `candidates`.
    static func host(offering candidates: [CandidateContract]) -> PluginInterfaceContracts {
        PluginInterfaceContracts(
            levels: [1: PluginInterfaceContracts.levelOneMembers.subtracting([member])],
            candidates: candidates
        )
    }

    /// A Host built from the probe's pinned metadata.
    static func matchingHost() throws -> PluginInterfaceContracts { host(offering: [try contract()]) }

    /// A copy of the probe in a temporary directory, its manifest changed by
    /// `change`, as the author's next revision of it would be.
    static func write(_ change: (inout [String: JSONValue]) -> Void = { _ in }) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("CandidateProbe.spinnetplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package, to: root)
        guard case .object(var manifest) = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        ) else { fatalError("The probe's manifest is not an object") }
        change(&manifest)
        try JSONEncoder().encode(JSONValue.object(manifest)).write(to: root.appendingPathComponent("manifest.json"))
        return root
    }

    static func declaring(_ declarations: [(String, Int)]) -> (inout [String: JSONValue]) -> Void {
        { manifest in
            manifest["candidate_contracts"] = .array(declarations.map {
                .object(["name": .string($0.0), "revision": .number(Double($0.1))])
            })
        }
    }

    /// The probe's next revision after its candidate became stable Level
    /// `level`: it declares the Level and no candidate.
    static func promoted(to level: Int) -> (inout [String: JSONValue]) -> Void {
        { manifest in
            manifest["candidate_contracts"] = nil
            manifest["api_level"] = .number(Double(level))
            manifest["version"] = .string("2.0.0")
        }
    }
}
