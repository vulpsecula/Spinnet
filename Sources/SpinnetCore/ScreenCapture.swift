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

/// The format a saved capture's file is written in.
public enum ScreenCaptureFormat: String, Codable, CaseIterable, Equatable, Hashable {
    case png
    case jpg
}

/// One capture for the native capturer: where to capture and what to do with
/// the image afterwards. The Host builds it from `ScreenshotSettings`, never
/// from Plugin input, and nothing here is a command-line argument, so nothing
/// reaches the capture tool's other options.
public struct ScreenCaptureRequest: Equatable, Hashable {
    public let source: ScreenCaptureSource
    public let copyToClipboard: Bool
    /// Where the capture is saved, or nil when it is only copied.
    public let saveFolder: URL?
    /// The saved file's format. The clipboard always gets the lossless
    /// capture.
    public let saveFormat: ScreenshotSettings.FileFormat

    public init(source: ScreenCaptureSource, copyToClipboard: Bool, saveFolder: URL?,
                saveFormat: ScreenshotSettings.FileFormat) {
        self.source = source
        self.copyToClipboard = copyToClipboard
        self.saveFolder = saveFolder
        self.saveFormat = saveFormat
    }
}

public extension ScreenCaptureSource {
    /// Reads a Plugin's `capture_screen` request, `{"source": …}`. A Plugin
    /// chooses the source only; the user's Screenshots settings decide what
    /// happens to the image, so any other member is refused.
    init(serviceInput json: JSONValue) throws {
        guard case .object(let fields) = json, fields.count == 1,
              case .string(let raw) = fields["source"], let source = ScreenCaptureSource(rawValue: raw) else {
            throw PluginHostServiceError.invalidInput(
                "capture_screen expects {\"source\": \"area\"|\"fullscreen\"|\"window\"} and nothing else"
            )
        }
        self = source
    }
}

/// What the Host does with every screenshot, whether a capture Host Command
/// or another Plugin asked for it. A Host setting, so a Plugin can neither
/// read nor choose it.
public struct ScreenshotSettings: Codable, Equatable {
    public enum AfterCapture: String, Codable, CaseIterable, Equatable {
        case copyToClipboard = "copy"
        case saveToFolder = "save"
        case copyAndSave = "copy_and_save"

        public var title: String {
            switch self {
            case .copyToClipboard: return "Copy to Clipboard"
            case .saveToFolder: return "Save to Folder"
            case .copyAndSave: return "Copy and Save"
            }
        }

        public var copies: Bool { self != .saveToFolder }
        public var saves: Bool { self != .copyToClipboard }
    }

    /// How a saved screenshot's file is written. The raw values of PNG and
    /// JPEG are those stored before Automatic existed.
    public enum FileFormat: String, Codable, CaseIterable, Equatable, Hashable {
        case automatic
        case png
        case jpeg = "jpg"

        public var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            }
        }

        /// A few words on what the choice trades, shown beside it.
        public var summary: String {
            switch self {
            case .automatic:
                return "JPEG for photos, gradients and noise; PNG for text and flat colours."
            case .png: return "Lossless and sharp for text; larger files."
            case .jpeg: return "Much smaller files; text and edges may blur slightly."
            }
        }
    }

    public static let defaultsKey = "screenshots.settings"

    public var afterCapture: AfterCapture
    /// Used only when the settings save.
    public var format: FileFormat
    /// The folder as the user chose it, `~` included. Kept while the capture
    /// only copies, so switching back to saving finds it again.
    public var saveFolder: String

    public init(afterCapture: AfterCapture = .copyToClipboard, format: FileFormat = .automatic, saveFolder: String = "~/Desktop") {
        self.afterCapture = afterCapture
        self.format = format
        self.saveFolder = saveFolder
    }

    /// The stored settings, or the defaults when none are stored or they no
    /// longer read.
    public init(defaults: UserDefaults) {
        self = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Why a capture cannot run as set, or nil when it can. Only a capture
    /// that saves looks at the folder.
    public var unavailableReason: ActionUnavailableReason? {
        afterCapture.saves && !ScreenCaptureDestination.isUsableFolder(saveFolder) ? .saveFolderUnavailable : nil
    }

    /// `unavailableReason` for a capture Host Command's Action; any other
    /// Action does not depend on these settings.
    public func unavailableReason(for action: ActionConfiguration) -> ActionUnavailableReason? {
        action.hostCommand?.captureSource == nil ? nil : unavailableReason
    }

    /// The capture these settings describe. The folder is checked here as
    /// well, since it may have gone since the Menu last looked.
    public func request(for source: ScreenCaptureSource) throws -> ScreenCaptureRequest {
        guard unavailableReason == nil else {
            throw PluginHostServiceError.unavailable(
                "The screenshot save folder is missing or cannot be written; choose it again in Screenshots settings"
            )
        }
        return ScreenCaptureRequest(
            source: source, copyToClipboard: afterCapture.copies,
            saveFolder: afterCapture.saves ? ScreenCaptureDestination.url(for: saveFolder) : nil,
            saveFormat: format
        )
    }

    private enum CodingKeys: String, CodingKey {
        case afterCapture = "after_capture"
        case format
        case saveFolder = "save_folder"
    }
}

/// Checks the save folder the same way wherever it is used: when a Menu
/// Item's availability is computed and again when a capture starts.
public enum ScreenCaptureDestination {
    /// A folder is usable when it exists, is a directory, and can be written.
    public static func isUsableFolder(_ path: String) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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

/// Automatic format: what a capture looks like decides how it is saved.
/// Photographs, gradients and noise change a little from pixel to pixel, which
/// JPEG stores small and without visible loss. Text and flat colours are long
/// runs of one colour with hard edges, which PNG stores small and sharp while
/// JPEG would blur them.
public enum ScreenshotContent {
    /// Suggests a format for 8-bit RGBA pixels, row by row with no padding.
    /// Each pixel is compared with its right and lower neighbours: an image
    /// that is mostly unchanged runs, with few small steps, is flat.
    public static func suggestedFormat(rgba: [UInt8], width: Int, height: Int) -> ScreenCaptureFormat {
        guard width > 1, height > 1, rgba.count >= width * height * 4 else { return .png }
        var pairs = 0, unchanged = 0, smallSteps = 0
        func compare(_ a: Int, _ b: Int) {
            let step = max(abs(Int(rgba[a]) - Int(rgba[b])),
                           abs(Int(rgba[a + 1]) - Int(rgba[b + 1])),
                           abs(Int(rgba[a + 2]) - Int(rgba[b + 2])))
            pairs += 1
            if step == 0 { unchanged += 1 } else if step <= smallStep { smallSteps += 1 }
        }
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let offset = (y * width + x) * 4
                compare(offset, offset + 4)
                compare(offset, offset + width * 4)
            }
        }
        let changed = pairs - unchanged
        let busy = Double(unchanged) < Double(pairs) * 0.4
        let smooth = Double(changed) >= Double(pairs) * 0.05 && Double(smallSteps) >= Double(changed) * 0.5
        return busy || smooth ? .jpg : .png
    }

    /// The largest channel change still read as shading rather than an edge.
    private static let smallStep = 16
}
