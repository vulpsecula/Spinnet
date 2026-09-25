import Foundation
import SpinnetCore

/// The Plugin packages this repository ships, read from `Plugins/` as the
/// Host reads them from its app bundle.
enum ShippedPluginPackages {
    static func all() throws -> [PluginPackage] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Plugins")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "spinnetplugin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let loaded = try PluginManifestLoader.load(packageAt: url)
                return PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
            }
    }

    /// The shipped Plugins whose Commands are all Host Commands: Open URL,
    /// Screenshot and the rest that used to be built into the Library.
    static func hostCommandPlugins() throws -> [PluginPackage] {
        try all().filter { $0.manifest.commands.allSatisfy { $0.hostCommand != nil } }
    }

    static func named(_ name: String) throws -> PluginPackage {
        guard let package = try all().first(where: { $0.manifest.name == name }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return package
    }
}
