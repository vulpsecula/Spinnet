import Foundation
import SpinnetCore

/// Where a Host's saved data keeps its Plugins: the installed packages, each
/// Plugin's Plugin Storage and the Capability decisions. The running Host and
/// the launcher's development install both open Plugin installation through
/// it, so they read and write the same files the same way.
struct HostPluginFiles {
    let dataDirectory: URL

    var pluginsDirectory: URL { dataDirectory.appendingPathComponent("Plugins") }
    var pluginStorageDirectory: URL { dataDirectory.appendingPathComponent("PluginStorage") }
    var capabilityGrantsFile: URL { dataDirectory.appendingPathComponent("capability-grants.json") }

    /// Adds the saved Capability decisions to `grants`; none are saved before
    /// the first decision.
    func restoreCapabilityGrants(into grants: PluginCapabilityGrantStore) throws {
        guard FileManager.default.fileExists(atPath: capabilityGrantsFile.path) else { return }
        try StoredDataMigration.restoreCapabilityGrants(from: Data(contentsOf: capabilityGrantsFile), into: grants)
    }

    func saveCapabilityGrants(_ grants: [PluginCapabilityGrant]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(grants)
        try FileManager.default.createDirectory(at: capabilityGrantsFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: capabilityGrantsFile, options: .atomic)
    }

    /// The installation store over these files. By default it keeps Plugin
    /// Storage in its own directory and saves `grants` here after each change.
    func installationStore(
        registry: PluginRegistry,
        grants: PluginCapabilityGrantStore,
        storage: PluginStorage? = nil,
        persistGrants: (() throws -> Void)? = nil,
        forgetHostPreferences: @escaping (PluginID) -> Void
    ) -> PluginInstallationStore {
        PluginInstallationStore(
            directory: pluginsDirectory, registry: registry, grants: grants,
            persistGrants: persistGrants ?? { [self, grants] in try saveCapabilityGrants(grants.allGrants) },
            storage: storage ?? PluginStorage(directory: pluginStorageDirectory),
            forgetHostPreferences: forgetHostPreferences
        )
    }
}
