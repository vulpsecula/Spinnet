import Foundation

/// Owns installed package copies and an atomic index, plus the record of which
/// shipped Plugins the user removed. Importing never starts a helper or grants
/// access. Old copies remain available if writing fails.
public final class PluginInstallationStore {
    private let directory: URL
    private let registry: PluginRegistry
    private let grants: PluginCapabilityGrantStore
    private let persistGrants: () throws -> Void

    public init(directory: URL, registry: PluginRegistry, grants: PluginCapabilityGrantStore,
                persistGrants: @escaping () throws -> Void) {
        self.directory = directory
        self.registry = registry
        self.grants = grants
        self.persistGrants = persistGrants
    }

    private var indexURL: URL { directory.appendingPathComponent("installed.json") }
    /// A Bundled Plugin ships with the app, so removing its files is not an
    /// option and deleting it would only last until the next launch. The user's
    /// decision is recorded here instead, and discovery skips what it names.
    private var removedIndexURL: URL { directory.appendingPathComponent("removed.json") }

    private func readIndex() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: indexURL))
    }

    public func removedPluginIDs() throws -> Set<PluginID> {
        guard FileManager.default.fileExists(atPath: removedIndexURL.path) else { return [] }
        let raw = try JSONDecoder().decode([String].self, from: Data(contentsOf: removedIndexURL))
        return Set(raw.map { PluginID($0) })
    }

    private func writeRemoved(_ pluginIDs: Set<PluginID>) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = pluginIDs.map(\.rawValue).sorted()
        try JSONEncoder().encode(raw).write(to: removedIndexURL, options: .atomic)
    }

    /// Removes a Plugin the user no longer wants. Menu Items that referenced it
    /// are left alone: they report the same unavailability as a disabled
    /// Plugin, so nothing the user arranged is discarded by a removal.
    ///
    /// The durable record is written before the Plugin leaves the registry, so
    /// a crash in between leaves the removal done rather than half done.
    public func uninstall(_ pluginID: PluginID) throws {
        guard let package = registry.package(for: pluginID) else { return }
        guard package.canBeRemovedByUser else {
            throw ConfigurationError.invalidManifest("A Host Command cannot be removed")
        }
        switch package.origin {
        case .hostCommand:
            return
        case .bundled:
            try writeRemoved(try removedPluginIDs().union([pluginID]))
        case .installed:
            var index = try readIndex()
            let name = index.removeValue(forKey: pluginID.rawValue)
            try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
            if let name, name == URL(fileURLWithPath: name).lastPathComponent {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        registry.unregister(pluginID)
        grants.removeGrants(for: pluginID)
        try persistGrants()
    }

    /// Forgets that a Bundled Plugin was removed. The caller rediscovers the
    /// shipped packages afterwards, which is where the Plugin comes back.
    public func reinstate(_ pluginID: PluginID) throws {
        guard registry.package(for: pluginID) == nil else {
            throw ConfigurationError.invalidManifest(
                "A Plugin with that identity is already registered"
            )
        }
        try writeRemoved(try removedPluginIDs().subtracting([pluginID]))
    }

    public func restore() throws {
        for (pluginID, name) in try readIndex() {
            // Shipped packages own their identities even if an older Host
            // installed a package with that ID before it became bundled.
            if registry.package(for: PluginID(pluginID))?.canBeReplacedByInstall == false { continue }
            guard name == URL(fileURLWithPath: name).lastPathComponent else {
                throw ConfigurationError.invalidManifest("Invalid installed package location")
            }
            let package = try PluginManifestLoader.load(packageAt: directory.appendingPathComponent(name))
            guard package.manifest.id.rawValue == pluginID else {
                throw ConfigurationError.invalidManifest("Installed Plugin identity changed")
            }
            try registry.register(package)
        }
    }

    @discardableResult
    public func install(from source: URL) throws -> PluginManifest {
        let candidate = try PluginManifestLoader.load(packageAt: source)
        if let existing = registry.package(for: candidate.manifest.id),
           !existing.canBeReplacedByInstall {
            throw ConfigurationError.invalidManifest("Cannot replace a Host-provided Plugin")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".spinnetplugin"
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            let package = try PluginManifestLoader.load(packageAt: destination)
            guard package.manifest == candidate.manifest else {
                throw ConfigurationError.invalidManifest("Plugin changed during installation")
            }
            grants.prepareInstallation(of: package.manifest,
                replacing: registry.package(for: package.manifest.id)?.manifest)
            // Persist inherited and newly requested scope decisions before
            // publishing the package, including across a Host restart.
            try persistGrants()
            var index = try readIndex()
            let oldName = index.updateValue(name, forKey: package.manifest.id.rawValue)
            try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
            if registry.package(for: package.manifest.id) == nil {
                try registry.register(package)
            } else {
                try registry.replace(package)
            }
            if let oldName, oldName == URL(fileURLWithPath: oldName).lastPathComponent {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldName))
            }
            return package.manifest
        } catch {
            // An indexed copy must survive a later activation failure.
            if (try? readIndex().values.contains(name)) != true {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }
}
