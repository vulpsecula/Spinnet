import Foundation

/// Where the currently installed package was obtained. An Update Source is
/// separate: it declares where future versions may be found.
public enum PluginInstallationSource: Codable, Equatable, Sendable {
    case unknown
    case localFile
    case github(PluginUpdateSource)
}

/// A removed Plugin whose settings and storage the user chose to keep.
public struct RetainedPluginData: Equatable, Identifiable, Sendable {
    public let id: PluginID
    public let name: String
    public let source: PluginInstallationSource

    public init(id: PluginID, name: String, source: PluginInstallationSource) {
        self.id = id
        self.name = name
        self.source = source
    }
}
