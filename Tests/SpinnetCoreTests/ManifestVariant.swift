import Foundation
@testable import SpinnetCore

/// Changed copies of a fixture's manifest: the Host's probes declare Plugin
/// API Level 2, and a test may need the same Plugin at Level 1 or declaring
/// Candidate Contracts.
enum ManifestVariant {
    /// Changes a Level 2 manifest into a Level 1 one declaring nothing.
    static let levelOne: (inout [String: JSONValue]) -> Void = { manifest in
        manifest["api_level"] = .number(1)
        manifest["candidate_contracts"] = nil
    }

    /// Changes a manifest into one declaring `declarations` at Level 1.
    static func declaring(_ declarations: [CandidateContractRevision]) -> (inout [String: JSONValue]) -> Void {
        { manifest in
            manifest["api_level"] = .number(1)
            manifest["candidate_contracts"] = .array(declarations.map {
                .object(["name": .string($0.name), "revision": .number(Double($0.revision))])
            })
        }
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
