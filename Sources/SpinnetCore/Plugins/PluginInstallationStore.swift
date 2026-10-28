import Foundation

/// What installing a package would do, worked out before anything is copied
/// so the user can allow it first.
public struct PluginInstallationReview: Equatable {
    /// The Plugin the install registers.
    public let manifest: PluginManifest
    /// The Capabilities nobody will have decided on once it is installed.
    public let requestedAccess: [PluginCapability]

    public init(manifest: PluginManifest, requestedAccess: [PluginCapability]) {
        self.manifest = manifest
        self.requestedAccess = requestedAccess
    }
}

/// Owns installed package copies and an atomic index. Every Plugin, whoever
/// publishes it, is installed, updated and removed here the same way.
/// Importing never starts a helper or grants access. Old copies remain
/// available if writing fails.
///
/// It also decides the fate of each Plugin's Plugin Storage and of the
/// Host's own preferences about it, such as its Pin: removing a Plugin
/// deletes them, installing a Plugin that is not registered starts them
/// empty, and an update keeps them.
public final class PluginInstallationStore {
    private let directory: URL
    private let registry: PluginRegistry
    private let grants: PluginCapabilityGrantStore
    private let persistGrants: () throws -> Void
    private let storage: PluginStorage?
    private let forgetHostPreferences: (PluginID) -> Void

    /// `forgetHostPreferences` forgets what the Host remembers of a Plugin
    /// outside its Plugin Storage and access decisions, such as its Pin.
    public init(directory: URL, registry: PluginRegistry, grants: PluginCapabilityGrantStore,
                persistGrants: @escaping () throws -> Void, storage: PluginStorage? = nil,
                forgetHostPreferences: @escaping (PluginID) -> Void = { _ in }) {
        self.directory = directory
        self.registry = registry
        self.grants = grants
        self.persistGrants = persistGrants
        self.storage = storage
        self.forgetHostPreferences = forgetHostPreferences
    }

    private var indexURL: URL { directory.appendingPathComponent("installed.json") }
    private func readIndex() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: indexURL))
    }

    /// Removes a Plugin the user no longer wants. Menu Items that referenced it
    /// are left alone: they report the same unavailability as a disabled
    /// Plugin, so nothing the user arranged is discarded by a removal. What it
    /// kept in Plugin Storage is deleted, and its access decisions and the
    /// Host's preferences about it, such as its Pin, are forgotten.
    ///
    /// The durable record is written before the Plugin leaves the registry, so
    /// a crash in between leaves the removal done rather than half done.
    public func uninstall(_ pluginID: PluginID) throws {
        let package = registry.package(for: pluginID)
        // A Refused Plugin has no package registered, but is removed the same
        // way, from what is on disk.
        guard package != nil || registry.refusedPlugin(pluginID) != nil else { return }
        try discardInstalledCopy(of: pluginID)
        registry.unregister(pluginID)
        grants.removeGrants(for: pluginID)
        try persistGrants()
        // The Plugin is removed by now, so a store that cannot be cleared
        // does not make the removal fail; installing it again clears it.
        try? storage?.clear(pluginID)
        forgetHostPreferences(pluginID)
    }

    /// Drops the user's own copy of a Plugin: its index entry first, so a
    /// crash leaves an unreferenced file rather than an index naming one that
    /// is gone.
    private func discardInstalledCopy(of pluginID: PluginID) throws {
        var index = try readIndex()
        guard let name = index.removeValue(forKey: pluginID.rawValue) else { return }
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        if name == URL(fileURLWithPath: name).lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Registers every installed Plugin. One this Host cannot register, such
    /// as a broken package, incompatible Host range or obsolete declaration,
    /// is recorded as a Refused Plugin with the reason
    /// and left installed, and the others restore regardless. Unreadable
    /// indexes or failed persistence stop the restore.
    public func restore() throws {
        let installed = try readIndex()
        for (rawID, name) in installed.sorted(by: { $0.key < $1.key }) {
            let pluginID = PluginID(rawID)
            var manifest: PluginManifest?
            do {
                guard name == URL(fileURLWithPath: name).lastPathComponent else {
                    throw ConfigurationError.invalidManifest("Invalid installed package location")
                }
                let package = try PluginManifestLoader.load(packageAt: directory.appendingPathComponent(name))
                guard package.manifest.id == pluginID else {
                    throw ConfigurationError.invalidManifest("Installed Plugin identity changed")
                }
                manifest = package.manifest
                try registry.register(package)
            } catch {
                // The executable loader remains strict. Read a refused legacy
                // declaration only as predecessor metadata for equal-scope
                // decisions when the user later replaces it; never register it.
                if manifest == nil, name == URL(fileURLWithPath: name).lastPathComponent,
                   let data = try? Data(contentsOf: directory.appendingPathComponent(name).appendingPathComponent("manifest.json")),
                   let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                   let previous = try? historicalManifestForAccessComparison(value),
                   previous.id == pluginID {
                    manifest = previous
                }
                registry.recordRefused(RefusedPlugin(id: pluginID, manifest: manifest,
                                                     reason: error.localizedDescription))
            }
        }
    }

    /// A refused legacy declaration predates engines.spinnet. Its version
    /// selector is irrelevant to equal-scope grant inheritance. Adapt only
    /// this read; public package decoding still refuses every old
    /// declaration, including one also containing engines.
    private func historicalManifestForAccessComparison(_ value: JSONValue) throws -> PluginManifest {
        guard case .object(var fields) = value else {
            throw ConfigurationError.invalidManifest("Invalid recorded Plugin manifest")
        }
        fields.removeValue(forKey: "api_level")
        fields.removeValue(forKey: "candidate_contracts")
        if fields["engines"] == nil {
            fields["engines"] = .object(["spinnet": .string(HostCompatibility.current.rawValue)])
        }
        let data = try JSONEncoder().encode(JSONValue.object(fields))
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    /// The manifest an install of `pluginID` replaces: the registered one, or
    /// that of a Refused Plugin when it could be read.
    private func replacedManifest(_ pluginID: PluginID) -> PluginManifest? {
        registry.package(for: pluginID)?.manifest ?? registry.refusedPlugin(pluginID)?.manifest
    }

    /// A package must be a plain tree. A symbolic link inside it would let a
    /// script reach outside the package, which the manifest's own rejection of
    /// escaping script paths cannot see, and a link copied into the install
    /// directory would dangle the moment whatever it points at moves.
    private func rejectSymbolicLinks(in root: URL) throws {
        var pending = [root]
        while let directory = pending.popLast() {
            let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey]
            for entry in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys)
            ) {
                let values = try entry.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else {
                    throw ConfigurationError.invalidManifest(
                        "Plugin package contains a symbolic link: \(entry.lastPathComponent)"
                    )
                }
                if values.isDirectory == true { pending.append(entry) }
            }
        }
    }

    /// What an install from `source` would do, found by the same checks the
    /// install makes, without copying, registering, or deciding anything.
    public func review(_ source: URL) throws -> PluginInstallationReview {
        let candidate = try check(source.resolvingSymlinksInPath())
        return PluginInstallationReview(
            manifest: candidate.manifest,
            requestedAccess: grants.requestsAfterInstallation(
                of: candidate.manifest, replacing: replacedManifest(candidate.manifest.id)
            )
        )
    }

    private func check(_ source: URL) throws -> PluginPackage {
        let candidate = try PluginManifestLoader.load(packageAt: source)
        try registry.contracts.check(candidate.manifest)
        return candidate
    }

    /// Installs the package the user chose, whatever its identity: a new
    /// Plugin, a Plugin Update, or a Plugin the user removed earlier.
    @discardableResult
    public func install(from package: URL) throws -> PluginManifest {
        // Copying follows no links, so a symlinked package would be installed
        // as the link itself and break as soon as it is read from elsewhere.
        let source = package.resolvingSymlinksInPath()
        let candidate = try check(source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".spinnetplugin"
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            try rejectSymbolicLinks(in: destination)
            let package = try PluginManifestLoader.load(packageAt: destination)
            guard package.manifest == candidate.manifest else {
                throw ConfigurationError.invalidManifest("Plugin changed during installation")
            }
            let isRegistered = registry.package(for: package.manifest.id) != nil
            let isUpdate = isRegistered || registry.refusedPlugin(package.manifest.id) != nil
            // A Plugin that is not registered starts with empty Plugin
            // Storage, even if a write reached it after it was removed. An
            // update keeps what the earlier version kept.
            if !isUpdate {
                try storage?.clear(package.manifest.id)
                forgetHostPreferences(package.manifest.id)
            }
            grants.prepareInstallation(of: package.manifest, replacing: replacedManifest(package.manifest.id))
            // Persist inherited and newly requested scope decisions before
            // publishing the package, including across a Host restart.
            try persistGrants()
            var index = try readIndex()
            let oldName = index.updateValue(name, forKey: package.manifest.id.rawValue)
            try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
            if !isRegistered {
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
