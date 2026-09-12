import Foundation

/// Owns installed package copies and an atomic index. Importing never starts
/// a helper or grants access. Old copies remain available if writing fails.
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

    private func readIndex() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: indexURL))
    }

    public func restore() throws {
        for (pluginID, name) in try readIndex() {
            // Shipped packages own their identities even if an older Host
            // installed a package with that ID before it became bundled.
            if registry.package(for: PluginID(pluginID))?.isHostProvided == true { continue }
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
           existing.isHostProvided {
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
