import Foundation
import SpinnetCore

/// The exact Plugin revision packaging ships, resolved through the same lock
/// and development override. Fail closed when the source cannot be resolved.
public enum ShippedPluginPackages {
    public static func all() throws -> [PluginPackage] {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resolver = Process()
        resolver.executableURL = URL(fileURLWithPath: "/bin/bash")
        resolver.arguments = [repository.appendingPathComponent("script/resolve_bundled_plugins.sh").path]
        let output = Pipe()
        resolver.standardOutput = output
        try resolver.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        resolver.waitUntilExit()
        guard resolver.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { throw CocoaError(.fileReadUnknown) }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
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
    public static func hostCommandPlugins() throws -> [PluginPackage] {
        try all().filter { $0.manifest.commands.allSatisfy { $0.hostCommand != nil } }
    }

    public static func named(_ name: String) throws -> PluginPackage {
        guard let package = try all().first(where: { $0.manifest.name == name }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return package
    }
}
