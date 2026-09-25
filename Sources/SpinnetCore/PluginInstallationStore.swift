import Foundation

/// What an install did. A Plugin that ships with the app is brought back
/// rather than copied, so the two outcomes read differently to the user.
public enum PluginInstallationOutcome: Equatable {
    case installed(PluginManifest)
    case restored(PluginManifest)

    public var manifest: PluginManifest {
        switch self {
        case let .installed(manifest), let .restored(manifest): return manifest
        }
    }
}

/// Owns installed package copies and an atomic index, plus the record of which
/// shipped Plugins the user removed. Importing never starts a helper or grants
/// access. Old copies remain available if writing fails.
public final class PluginInstallationStore {
    private let directory: URL
    private let registry: PluginRegistry
    private let grants: PluginCapabilityGrantStore
    private let persistGrants: () throws -> Void
    private let shippedPackages: () throws -> [PluginPackage]

    public init(directory: URL, registry: PluginRegistry, grants: PluginCapabilityGrantStore,
                persistGrants: @escaping () throws -> Void,
                shippedPackages: @escaping () throws -> [PluginPackage] = { [] }) {
        self.directory = directory
        self.registry = registry
        self.grants = grants
        self.persistGrants = persistGrants
        self.shippedPackages = shippedPackages
    }

    private func shippedPackage(_ pluginID: PluginID) throws -> PluginPackage? {
        try shippedPackages().first { $0.manifest.id == pluginID }
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
            try discardInstalledCopy(of: pluginID)
        }
        registry.unregister(pluginID)
        grants.removeGrants(for: pluginID)
        try persistGrants()
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

    /// The shipped Plugins the user removed. They are the ones an install
    /// brings back rather than copies, and the only ones a Library can offer
    /// to restore.
    public func restorablePlugins() throws -> [PluginManifest] {
        let removed = try removedPluginIDs()
        return try shippedPackages()
            .map(\.manifest)
            .filter { removed.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Brings a removed Bundled Plugin back by forgetting the removal and
    /// registering the copy that ships with the app. The Plugin keeps the
    /// origin it shipped with, which is what a copy of the same package
    /// installed into Application Support could never have.
    ///
    /// Access is not inherited: the removal forgot the user's decisions, and a
    /// Plugin returning to the Library asks for them again.
    @discardableResult
    public func reinstate(_ pluginID: PluginID) throws -> PluginManifest {
        guard registry.package(for: pluginID) == nil else {
            throw ConfigurationError.invalidManifest(
                "A Plugin with that identity is already registered"
            )
        }
        guard let shipped = try shippedPackage(pluginID) else {
            throw ConfigurationError.invalidManifest(
                "No Plugin ships with that identity"
            )
        }
        grants.prepareInstallation(of: shipped.manifest, replacing: nil)
        try persistGrants()
        // The Plugin is back once it registers, so the durable record is
        // cleared after that and put back if clearing it fails. A removal
        // writes its record first for the same reason: whichever state a
        // crash lands in has to be one of the two the user asked for.
        try registry.register(shipped)
        do {
            try writeRemoved(try removedPluginIDs().subtracting([pluginID]))
            // The shipped copy owns the identity again, so a user copy left
            // underneath it from an older Host is no longer anybody's Plugin.
            try discardInstalledCopy(of: pluginID)
        } catch {
            registry.unregister(pluginID)
            throw error
        }
        return shipped.manifest
    }

    public func restore() throws {
        let removed = try removedPluginIDs()
        for (pluginID, name) in try readIndex() {
            // A removal is of the Plugin, not of whichever copy of it is on
            // top, so a user copy left underneath a shipped one must not bring
            // a removed Plugin back.
            if removed.contains(PluginID(pluginID)) { continue }
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

    @discardableResult
    public func install(from source: URL) throws -> PluginInstallationOutcome {
        // Copying follows no links, so a symlinked package would be installed
        // as the link itself and break as soon as it is read from elsewhere.
        let source = source.resolvingSymlinksInPath()
        let candidate = try PluginManifestLoader.load(packageAt: source)
        // A Plugin that ships with the app keeps its identity wherever a copy
        // of it is pointed at from. Installing that copy would put it back as
        // a user Plugin, which is a weaker origin than the one it shipped
        // with, so the Plugin would return to the Library unable to do what it
        // did before. Bringing back the shipped copy is what was asked for.
        if try removedPluginIDs().contains(candidate.manifest.id),
           try shippedPackage(candidate.manifest.id) != nil {
            return .restored(try reinstate(candidate.manifest.id))
        }
        guard candidate.manifest.apiLevel <= PluginAPILevel.highestSupported else {
            throw UnsupportedPluginAPILevel(requiredBy: candidate.manifest)
        }
        if let existing = registry.package(for: candidate.manifest.id),
           !existing.canBeReplacedByInstall {
            throw ConfigurationError.invalidManifest("Cannot replace a Host-provided Plugin")
        }
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
            // The record suppresses a shipped Plugin the user dropped. They
            // have just installed this identity themselves, so it no longer
            // names something they refused — and left in place it would make
            // the next launch drop the copy they just installed.
            let removed = try removedPluginIDs()
            if removed.contains(package.manifest.id) {
                try writeRemoved(removed.subtracting([package.manifest.id]))
            }
            return .installed(package.manifest)
        } catch {
            // An indexed copy must survive a later activation failure.
            if (try? readIndex().values.contains(name)) != true {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }
}
