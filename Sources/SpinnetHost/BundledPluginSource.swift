import Foundation

/// Where a launch reads its Bundled Plugins from, and whether that source
/// accounts for every Bundled Plugin the Host ships.
///
/// A packaged Host always reads the Plugins its own bundle carries. The
/// development directory is for a Host that runs outside an app bundle,
/// because a packaged Host that honoured it would let anything on the machine
/// hand an already trusted Host its own Plugins with Bundled authority.
enum BundledPluginSource: Equatable {
    /// The Plugins directory inside the running app bundle.
    case packaged(URL)
    /// The directory named by `SPINNET_BUNDLED_PLUGINS_DIR` for a run outside
    /// an app bundle, which is how a development run reads the repository's
    /// Plugins.
    case development(URL)
    /// A run outside an app bundle that was given no directory to read.
    case none

    var directory: URL? {
        switch self {
        case let .packaged(url), let .development(url): return url
        case .none: return nil
        }
    }

    /// Whether this launch read every Bundled Plugin the Host ships, which is
    /// what it takes to read a Plugin holding a decision as a Plugin that is
    /// gone. Only a packaged Host reads a directory it ships and can vouch
    /// for; a development directory holds whatever it was pointed at, so a
    /// launch that read it is in no position to forget anything.
    var accountsForBundledPlugins: Bool {
        if case .packaged = self { return true }
        return false
    }

    static func resolve(
        bundleURL: URL,
        resourceURL: URL?,
        environmentOverride: String?,
        directoryExists: (URL) -> Bool
    ) throws -> BundledPluginSource {
        guard bundleURL.pathExtension == "app" else {
            guard let override = environmentOverride, !override.isEmpty else { return .none }
            return .development(URL(fileURLWithPath: override, isDirectory: true))
        }
        guard let directory = resourceURL?
                .appendingPathComponent("Plugins", isDirectory: true),
              directoryExists(directory) else {
            // Packaged but missing its Plugins: a broken build, not a Host that
            // should start and quietly offer fewer Commands.
            throw HostCommandError.failed("The app bundle is missing its Bundled Plugins")
        }
        return .packaged(directory)
    }
}
