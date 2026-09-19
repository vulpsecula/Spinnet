import Foundation

/// Local paths have their own authority; they never pass the web URL gate.
public enum OpenableLocalPath {
    public static func validate(_ path: String) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 4096,
              path.hasPrefix("/") || path.hasPrefix("~/"),
              !path.hasPrefix("//"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PluginHostServiceError.invalidInput("Use an absolute local path or ~/path, up to 4096 bytes")
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}
