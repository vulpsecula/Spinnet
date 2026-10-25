import Foundation

/// Local paths have their own authority; they never pass the web URL gate.
public enum OpenableLocalPath {
    /// The longest path, in UTF-8 bytes, the Host opens.
    public static let maximumBytes = 4096

    public static func validate(_ path: String) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= maximumBytes,
              path.hasPrefix("/") || path.hasPrefix("~/"),
              !path.hasPrefix("//"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PluginHostServiceError.invalidInput("Use an absolute local path or ~/path, up to 4096 bytes")
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}
