import Foundation
import SpinnetCore

/// Fixed copies of the official Plugins, frozen as Host test inputs. They are
/// ordinary Plugin packages: the Host ships none of them, and a test that
/// needs one registers or installs it like any other Plugin.
public enum OfficialPluginFixtures {
    public static var directory: URL {
        TestRepository.tests.appendingPathComponent("Fixtures/OfficialPlugins", isDirectory: true)
    }

    public static func all() throws -> [PluginPackage] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "spinnetplugin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try PluginManifestLoader.load(packageAt: $0) }
    }

    /// The official Plugins whose Commands are all Host Commands: Open URL,
    /// Screenshot and the rest that used to be built into the Library.
    public static func hostCommandPlugins() throws -> [PluginPackage] {
        try all().filter { $0.manifest.commands.allSatisfy { $0.execution == .host } }
    }

    public static func named(_ name: String) throws -> PluginPackage {
        guard let package = try all().first(where: { $0.manifest.name == name }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return package
    }
}
