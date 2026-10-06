import Foundation
@testable import SpinnetCore

/// The Host's own probes declare Plugin API Level 2. Each was proved first
/// against the Candidate Contracts Level 2 promoted (#79); its candidate
/// variant declares them again at Level 1, as before promotion, and runs
/// against `PluginInterfaceContracts.candidateHost`, so a test can show that
/// a scenario gives the same result on the candidate Host and on Level 2, or
/// keep a retired revision's own behaviour checked.
enum CandidateVariant {
    static let namespaces = CandidateContractRevision(name: "namespaces", revision: 1)

    /// What a Plugin using pages declared: `collections` at `revision` and
    /// the `host_operations` and `namespaces` revisions it required.
    static func pages(collections revision: Int = 3) -> [CandidateContractRevision] {
        [CandidateContractRevision(name: "collections", revision: revision),
         CandidateContractRevision(name: "host_operations", revision: revision >= 3 ? 2 : 1), namespaces]
    }

    /// What a Plugin requesting operations without pages declared.
    static func operations(revision: Int = 2) -> [CandidateContractRevision] {
        [CandidateContractRevision(name: "host_operations", revision: revision), namespaces]
    }

    /// Changes a Level 2 manifest into one declaring `declarations` at Level 1.
    static func declaring(_ declarations: [CandidateContractRevision]) -> (inout [String: JSONValue]) -> Void {
        { manifest in
            manifest["api_level"] = .number(1)
            manifest["candidate_contracts"] = .array(declarations.map {
                .object(["name": .string($0.name), "revision": .number(Double($0.revision))])
            })
        }
    }

    /// Changes a Level 2 manifest into a Level 1 one declaring nothing.
    static let levelOne: (inout [String: JSONValue]) -> Void = { manifest in
        manifest["api_level"] = .number(1)
        manifest["candidate_contracts"] = nil
    }

    /// The Host's record of `contract` now that Level 2 retired it, which
    /// its published `candidate.json` is.
    static func retired(_ contract: CandidateContract) -> CandidateContract? {
        PluginInterfaceContracts.host.candidates.first { $0.declaration == contract.declaration }
    }

    /// The manifest of `package` changed by `change`.
    static func manifest(of package: URL, _ change: (inout [String: JSONValue]) -> Void) throws -> PluginManifest {
        let data = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        guard case .object(var manifest) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        change(&manifest)
        return try PluginManifestLoader.decode(JSONEncoder().encode(JSONValue.object(manifest)))
    }

    /// A copy of `package` in a temporary directory, its manifest changed by
    /// `change`.
    static func write(_ package: URL, _ change: (inout [String: JSONValue]) -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(package.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package, to: root)
        guard case .object(var manifest) = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        ) else { throw CocoaError(.fileReadCorruptFile) }
        change(&manifest)
        try JSONEncoder().encode(JSONValue.object(manifest)).write(to: root.appendingPathComponent("manifest.json"))
        return root
    }
}
