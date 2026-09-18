import Foundation

/// What a native screen capture records.
public enum ScreenCaptureSource: String, Codable, CaseIterable, Equatable, Hashable {
    /// An area the user drags across the screen.
    case area
    /// The whole main display, captured at once.
    case fullScreen = "fullscreen"
    /// A window the user clicks.
    case window
}

/// The image format of a saved or copied capture.
public enum ScreenCaptureFormat: String, Codable, CaseIterable, Equatable, Hashable {
    case png
    case jpg
}

/// One validated `capture_screen` request. The Host runs the capture and the
/// post-capture operations; nothing here is a command-line argument, so a
/// Plugin cannot reach the capture tool's other options.
public struct ScreenCaptureRequest: Equatable, Hashable {
    public let source: ScreenCaptureSource
    public let format: ScreenCaptureFormat
    public let copyToClipboard: Bool
    /// Where the capture is saved, or nil when it is only copied.
    public let saveFolder: URL?

    public init(source: ScreenCaptureSource, format: ScreenCaptureFormat, copyToClipboard: Bool, saveFolder: URL?) {
        self.source = source
        self.format = format
        self.copyToClipboard = copyToClipboard
        self.saveFolder = saveFolder
    }

    private static let keys: Set<String> = ["source", "format", "copy_to_clipboard", "save_to_folder"]

    /// Reads a Plugin's request. `configuredFolders` are the folder values of
    /// the Action the Plugin is running; a save may name only one of them, so
    /// a Plugin can never pick its own destination.
    public init(json: JSONValue, configuredFolders: [String]) throws {
        let shape = "capture_screen expects source (area, fullscreen or window), format (png or jpg), "
            + "copy_to_clipboard (a boolean) and save_to_folder (the configured folder or null)"
        guard case .object(let fields) = json, Set(fields.keys) == Self.keys,
              case .string(let rawSource) = fields["source"], let source = ScreenCaptureSource(rawValue: rawSource),
              case .string(let rawFormat) = fields["format"], let format = ScreenCaptureFormat(rawValue: rawFormat),
              case .bool(let copy) = fields["copy_to_clipboard"] else {
            throw PluginHostServiceError.invalidInput(shape)
        }
        var folder: URL?
        switch fields["save_to_folder"] {
        case .null?:
            guard copy else {
                throw PluginHostServiceError.invalidInput("capture_screen must copy to the clipboard, save to a folder, or both")
            }
        case .string(let path)?:
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginHostServiceError.unavailable("No save folder is configured; choose one in the Configuration Sheet")
            }
            guard configuredFolders.contains(path) else {
                throw PluginHostServiceError.invalidInput("save_to_folder must be the folder configured for this Action")
            }
            guard ScreenCaptureDestination.isUsableFolder(path) else {
                throw PluginHostServiceError.unavailable(
                    "The save folder is missing or cannot be written; choose it again in the Configuration Sheet"
                )
            }
            folder = ScreenCaptureDestination.url(for: path)
        default:
            throw PluginHostServiceError.invalidInput(shape)
        }
        self.init(source: source, format: format, copyToClipboard: copy, saveFolder: folder)
    }
}

/// Checks a configured save folder the same way wherever it is used: when a
/// Menu Item's availability is computed and again when a capture starts.
public enum ScreenCaptureDestination {
    /// A folder is usable when it exists, is a directory, and can be written.
    public static func isUsableFolder(_ path: String) -> Bool {
        let resolved = url(for: path).path
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: resolved)
    }

    static func url(for path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
}

public extension CommandDeclaration {
    /// The values the Action gives this Command's `folder` fields, as typed.
    func configuredFolders(in input: JSONValue) -> [String] {
        guard case .object(let values) = input else { return [] }
        return configurationFields.compactMap { field in
            guard field.kind == .folder, let key = field.key, case .string(let path) = values[key] else { return nil }
            return path
        }
    }
}
