import Foundation

extension HomebrewReadProfile {
    /// Ordinary reads use Homebrew's documented CLI, including its own JSON
    /// cache and source-loading semantics. Plugins still choose typed operations,
    /// never argv, code or environment. The process tree remains offline and
    /// unable to persist writes; an update requires its separate Task grant.
    ///
    /// No Ruby implementation is loaded or injected by this path.
    static func executeReadCancellable(_ executable: URL, _ arguments: [String],
                                      _ environment: [String: String], _ deadline: Date,
                                      _ cancellation: HostFetchedSections.Cancellation) throws -> HomebrewReadOutput {
        let commands: Set<String> = ["--version", "info", "outdated", "search", "list", "tap", "tap-info", "services", "doctor", "trust", "config", "--prefix", "--cellar", "--caskroom"]
        let previews: Set<String> = ["install", "upgrade", "autoremove", "link", "unlink"]
        guard let command = arguments.first,
              commands.contains(command) || (previews.contains(command) && arguments.contains("--dry-run")) else {
            throw PluginHostServiceError.invalidInput("Unsupported Homebrew read command")
        }
        guard ["info", "outdated", "search", "list", "tap", "tap-info", "trust", "services", "install", "upgrade", "autoremove", "link", "unlink"].contains(command) else {
            return try executeBounded(executable, arguments, environment, deadline, cancellation,
                                      stdoutLimit: ReviewedToolReads.stdoutBytes, readOnly: true)
        }
        let cache = try HomebrewReadCache(environment: environment, deadline: deadline, cancellation: cancellation)
        var isolatedEnvironment = environment
        isolatedEnvironment["HOMEBREW_CACHE"] = cache.directory.path
        return try withExtendedLifetime(cache) {
            try executeBounded(executable, arguments, isolatedEnvironment, deadline, cancellation,
                               stdoutLimit: ReviewedToolReads.stdoutBytes, readOnly: true, writableCache: cache.directory)
        }
    }
}
