import Foundation

public final class PluginRegistry {
    private let lock = NSLock()
    private var packages: [PluginID: PluginPackage] = [:]

    public init() {}

    @discardableResult
    public func register(packageAt rootURL: URL) throws -> PluginManifest {
        let package = try PluginManifestLoader.load(packageAt: rootURL)
        try register(package)
        return package.manifest
    }

    public func register(_ package: PluginPackage) throws {
        try package.manifest.validate()

        lock.lock()
        defer { lock.unlock() }

        guard packages[package.manifest.id] == nil else {
            throw ConfigurationError.invalidManifest(
                "duplicate plugin id \(package.manifest.id.rawValue)"
            )
        }

        packages[package.manifest.id] = package
    }

    public func package(for pluginID: PluginID) -> PluginPackage? {
        lock.lock()
        defer { lock.unlock() }
        return packages[pluginID]
    }

    public func manifests() -> [PluginManifest] {
        lock.lock()
        defer { lock.unlock() }
        return packages.values
            .map(\.manifest)
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }
}
