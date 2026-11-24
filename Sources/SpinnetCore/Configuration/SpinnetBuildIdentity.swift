import Foundation

/// Who this build is to macOS: its bundle identifier, the prefix every
/// signed helper and privileged service name shares, and the folder its
/// saved data lives in.
///
/// A release build (the release configuration that packaging builds) is
/// Spinnet itself. A development build (the debug configuration the launcher
/// and tests build, Official or not) is a separate app, so the two can be
/// installed side by side without sharing System Permissions, settings,
/// saved data or the Root helper, and a development helper can never answer
/// for a release Host.
public struct SpinnetBuildIdentity: Equatable, Sendable {
    /// The bundle identifier the Host is signed and registered with.
    public let hostBundleIdentifier: String
    /// The prefix of every helper's signing identifier and Root service name.
    public let identifierPrefix: String
    /// The folder in Application Support that holds the user's saved data.
    public let dataFolderName: String
    public static let release = SpinnetBuildIdentity(
        hostBundleIdentifier: "com.vulpsecula.SpinnetHost",
        identifierPrefix: "com.vulpsecula.SpinnetHost",
        dataFolderName: "Spinnet"
    )

    public static let development = SpinnetBuildIdentity(
        hostBundleIdentifier: "com.vulpsecula.SpinnetHost.dev",
        identifierPrefix: "com.vulpsecula.SpinnetHost.dev",
        dataFolderName: "Spinnet Dev"
    )

    /// The identity this build was compiled as.
    #if DEBUG
    public static let current = development
    #else
    public static let current = release
    #endif

    /// The bundle identifier 1.0.0-beta.1 and beta.2 shipped with, and every
    /// development build used until the identities were split. Both
    /// identities adopt its settings once.
    public static let betaHostBundleIdentifier = "com.vulpsecula.SpinnetHost.preview"
    /// The data folder every build used before the identities were split.
    public static let sharedDataFolderName = "Spinnet"

    /// The Keychain service named `name` under this identity.
    ///
    /// The login Keychain lets only the app that created an item read it
    /// without asking, and the bundle identifier is part of that app's
    /// identity. The betas' items (`com.vulpsecula.Spinnet.*`) trust only the
    /// beta app, so reading one would ask for the login password on every
    /// launch; each identity keeps its own items instead.
    public func keychainService(_ name: String) -> String { identifierPrefix + "." + name }
}
