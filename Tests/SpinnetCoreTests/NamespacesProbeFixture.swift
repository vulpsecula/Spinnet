import Foundation
@testable import SpinnetCore

/// `Tests/Fixtures/NamespacesProbe.spinnetplugin` is a tiny external Plugin
/// that declares Candidate Contract `namespaces` revision 1: a script that
/// calls Host Services by their catalogue IDs, and a Command that runs one
/// directly without a script. Its variants name Level 1 names and reserved
/// IDs, which the Host refuses.
enum NamespacesProbeFixture {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
    static let package = fixtures.appendingPathComponent("NamespacesProbe.spinnetplugin", isDirectory: true)
    static let pluginID = PluginID("com.example.namespaces-probe")

    /// The Host this repository builds, which provides the candidate.
    static var host: PluginInterfaceContracts { .host }

    /// A copy of the probe in a temporary directory, its manifest changed by
    /// `change` and its scripts replaced by `scripts`, as the author's next
    /// revision of it would be.
    static func write(scripts: [String: String] = [:],
                      _ change: (inout [String: JSONValue]) -> Void = { _ in }) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("NamespacesProbe.spinnetplugin", isDirectory: true)
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

    /// Changes the probe's scriptless Command, `probe.copy_greeting`.
    static func hostCommand(_ change: @escaping (inout [String: JSONValue]) -> Void) -> (inout [String: JSONValue]) -> Void {
        { manifest in
            guard case .array(var commands)? = manifest["commands"] else { return }
            for index in commands.indices {
                guard case .object(var command) = commands[index],
                      command["id"] == .string("probe.copy_greeting") else { continue }
                change(&command)
                commands[index] = .object(command)
            }
            manifest["commands"] = .array(commands)
        }
    }

    /// The probe's scriptless Command named `name` with no fixed input.
    static func naming(_ name: String) -> (inout [String: JSONValue]) -> Void {
        hostCommand { command in
            command["host_command"] = .string(name)
            command["input"] = nil
        }
    }

    /// The probe declaring no candidate: a Level 1 Plugin.
    static let levelOne: (inout [String: JSONValue]) -> Void = { $0["candidate_contracts"] = nil }
}
