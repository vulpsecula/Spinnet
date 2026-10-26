import Foundation
@testable import SpinnetCore

/// Explicit changed copies of fixture manifests; frozen refusal bytes are
/// never admitted implicitly by the production loader.
enum ManifestVariant {
    static let current: (inout [String: JSONValue]) -> Void = { manifest in
        manifest["api_level"] = nil
        manifest["candidate_contracts"] = nil
        manifest["engines"] = .object(["spinnet": .string(HostCompatibility.current.rawValue)])
    }

    static func manifest(of package: URL, _ change: (inout [String: JSONValue]) -> Void) throws -> PluginManifest {
        guard case .object(var manifest) = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: package.appendingPathComponent("manifest.json"))) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        change(&manifest)
        return try PluginManifestLoader.decode(JSONEncoder().encode(JSONValue.object(manifest)))
    }

    static func write(_ package: URL, _ change: (inout [String: JSONValue]) -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(package.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package, to: root)
        guard case .object(var manifest) = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json"))) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        change(&manifest)
        try JSONEncoder().encode(JSONValue.object(manifest)).write(to: root.appendingPathComponent("manifest.json"))
        return root
    }
}
