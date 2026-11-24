import Foundation
import SpinnetCore

/// Where the Host keeps the user's saved data: a folder in Application
/// Support named by this build's identity. Reading it changes nothing; a
/// launch prepares it first with `HostIdentityMigration.prepareAtLaunch()`.
enum HostDataDirectory {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var url: URL { support.appendingPathComponent(SpinnetBuildIdentity.current.dataFolderName, isDirectory: true) }
}

/// Moves what the user had into this build's identity the first time it runs.
enum HostIdentityMigration {
    /// Run by a launch, app or command line, before anything reads saved
    /// data or settings; tests never run it, so they never touch the user's.
    /// The launcher's `--verify-…` packaging checks change nothing either.
    static func prepareAtLaunch(arguments: [String] = CommandLine.arguments) {
        guard !isPackagingCheck(arguments) else { return }
        adoptBetaSettingsIfNeeded()
        _ = prepareDataDirectory(in: HostDataDirectory.support, for: .current)
    }

    static func isPackagingCheck(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix("--verify-") }
    }

    /// The data folder for `identity`. Every build used to share the release
    /// folder, so a development build that has no folder of its own starts
    /// from a copy of it, keeping its installed Plugins and configuration.
    static func prepareDataDirectory(in support: URL, for identity: SpinnetBuildIdentity,
                                     fileManager: FileManager = .default) -> URL {
        let folder = support.appendingPathComponent(identity.dataFolderName, isDirectory: true)
        let shared = support.appendingPathComponent(SpinnetBuildIdentity.sharedDataFolderName, isDirectory: true)
        if folder != shared, !fileManager.fileExists(atPath: folder.path), fileManager.fileExists(atPath: shared.path) {
            // A failed copy leaves no folder, so the build starts empty and
            // the next launch tries again; the shared folder is never changed.
            do { try fileManager.copyItem(at: shared, to: folder) }
            catch { try? fileManager.removeItem(at: folder) }
        }
        return folder
    }

    /// A build that replaced 1.0.0-beta.1 or beta.2, or a development build
    /// that used their identifier, adopts their settings once: only while its
    /// own settings are still empty. System Permissions are keyed by the
    /// bundle identifier and cannot follow.
    static func adoptBetaSettingsIfNeeded(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                                          identity: SpinnetBuildIdentity = .current,
                                          defaults: UserDefaults = .standard) {
        guard let bundleIdentifier, bundleIdentifier == identity.hostBundleIdentifier,
              bundleIdentifier != SpinnetBuildIdentity.betaHostBundleIdentifier else { return }
        adoptSettings(from: SpinnetBuildIdentity.betaHostBundleIdentifier, into: bundleIdentifier, defaults: defaults)
    }

    /// Copies `previous`'s settings into an empty `domain`, except the record
    /// of what macOS was asked: the release has to ask for itself, or it would
    /// never appear in System Settings. True when it copied anything.
    @discardableResult
    static func adoptSettings(from previous: String, into domain: String, defaults: UserDefaults) -> Bool {
        guard defaults.persistentDomain(forName: domain)?.isEmpty ?? true,
              let settings = defaults.persistentDomain(forName: previous)?
                .filter({ !PrivacyPermissionsModel.systemPermissionRequestKeys.contains($0.key) }),
              !settings.isEmpty else { return false }
        defaults.setPersistentDomain(settings, forName: domain)
        return true
    }
}
