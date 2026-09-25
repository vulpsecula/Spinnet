import Foundation

/// The version of the Documented Plugin Interface (ADR 0013), an integer that
/// additive changes raise. A manifest's `api_level` is the lowest level the
/// Plugin needs; the Host installs a Plugin only if it supports that level.
/// `protocol_version` is unrelated: it only frames helper messages.
public enum PluginAPILevel {
    /// The highest level this Host supports. Level 1 is the first versioned
    /// release, and stays open to change until it is published (#64).
    public static let highestSupported = 1

    /// The level of a manifest written before `api_level` existed. Such a
    /// manifest was written against the interface Level 1 grew out of, so
    /// the Host keeps loading it rather than stranding a user's installed
    /// copy. The published schema still requires the field.
    public static let undeclared = 1
}

/// Why an install was refused: the Plugin needs a newer Documented Plugin
/// Interface than this Host provides, which only updating Spinnet can fix.
public struct UnsupportedPluginAPILevel: Error, Equatable, LocalizedError {
    public let pluginName: String
    public let requiredLevel: Int
    public let supportedLevel: Int

    public init(requiredBy manifest: PluginManifest, supportedLevel: Int = PluginAPILevel.highestSupported) {
        self.pluginName = manifest.name
        self.requiredLevel = manifest.apiLevel
        self.supportedLevel = supportedLevel
    }

    public var errorDescription: String? {
        "\(pluginName) needs Plugin API Level \(requiredLevel), but this version of Spinnet "
            + "supports up to Level \(supportedLevel). Update Spinnet to install it."
    }
}
