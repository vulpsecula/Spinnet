import Foundation
@testable import SpinnetCore

/// `Tests/Fixtures/OperationsProbe.spinnetplugin` is a tiny external Plugin
/// that declares Candidate Contract `host_operations` revision 1 and the
/// `namespaces` revision it requires: a symbol picker whose view names
/// where text goes and whose gestures request insertion and copying, and a
/// Command without a view that tries to insert a stamp.
enum OperationsProbeFixture {
    static let package = NamespacesProbeFixture.fixtures.appendingPathComponent("OperationsProbe.spinnetplugin",
                                                                              isDirectory: true)
    static let pluginID = PluginID("com.example.operations-probe")

    static func manifest() throws -> PluginManifest { try PluginManifestLoader.load(packageAt: package).manifest }

    /// A copy of the probe in a temporary directory with its manifest
    /// changed by `change` and its scripts replaced by `scripts`.
    static func write(scripts: [String: String] = [:],
                      _ change: (inout [String: JSONValue]) -> Void = { _ in }) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("OperationsProbe.spinnetplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package, to: root)
        guard case .object(var manifest) = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        ) else { fatalError("The probe's manifest is not an object") }
        change(&manifest)
        try JSONEncoder().encode(JSONValue.object(manifest)).write(to: root.appendingPathComponent("manifest.json"))
        for (name, source) in scripts {
            try Data(source.utf8).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    /// The probe declaring no candidate: a Level 1 Plugin.
    static let levelOne: (inout [String: JSONValue]) -> Void = { $0["candidate_contracts"] = nil }
}
