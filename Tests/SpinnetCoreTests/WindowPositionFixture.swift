import Foundation
@testable import SpinnetCore

/// The repository's Window Position package, registered the way the Host
/// registers a Plugin that ships with the app.
enum WindowPositionFixture {
    static func load() throws -> PluginPackage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loaded = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Plugins/WindowPosition.spinnetplugin"))
        return PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
    }

    /// Grants the package's focused-window Capability with its current scope.
    static func grant(_ package: PluginPackage, in grants: PluginCapabilityGrantStore) {
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                           capability: .positionFocusedWindow, scope: package.manifest.scope(for: .positionFocusedWindow))
    }
}
