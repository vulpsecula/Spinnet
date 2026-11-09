import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An icon a manifest declares, such as a Plugin's Plugin Icon. It is
/// display-only: it grants nothing, and changing it changes no Command's
/// executable definition.
///
/// It is written either `{"symbol": "<name>"}`, a system symbol by its SF
/// Symbols name under the same rule a page `icon` component follows, or
/// `{"image": "<path>", "dark_image"?: "<path>", "template"?: true}`, a
/// picture inside the Plugin's package.
public enum IconDeclaration: Equatable, Hashable, Sendable, Codable {
    case symbol(String)
    case picture(IconPicture)

    /// The system symbol name, which the Host draws; nil for a picture.
    public var symbolName: String? {
        switch self {
        case .symbol(let name): return name
        case .picture: return nil
        }
    }

    /// The package picture; nil for a system symbol.
    public var picture: IconPicture? {
        switch self {
        case .symbol: return nil
        case .picture(let picture): return picture
        }
    }

    /// Reads `value`, the manifest member called `name`, refusing anything
    /// but a valid symbol or picture declaration with a reason naming that
    /// member. Whether a picture's files are in the package is checked when
    /// the package loads (`IconPicture.check(in:)`).
    public init(parsing value: JSONValue, _ name: String) throws {
        let refusal = ConfigurationError.invalidManifest(
            "\(name) must be {\"symbol\": name}, naming a system symbol such as cpu or music.note "
                + "in lower-case letters, digits and dots, at most \(PagePresentation.maximumSymbolNameLength) characters, "
                + "or {\"image\": path, \"dark_image\"?: path, \"template\"?: true}, naming .png or .pdf files "
                + "inside the package, without . or .. parts, at most \(PagePresentation.maximumResourcePathLength) "
                + "characters; a template picture has no dark_image")
        guard case .object(let fields) = value else { throw refusal }
        if fields.keys.contains("symbol") {
            guard fields.count == 1, case .string(let symbol)? = fields["symbol"], PluginPageSymbol.isValid(symbol) else {
                throw refusal
            }
            self = .symbol(symbol)
            return
        }
        guard Set(fields.keys).isSubset(of: ["image", "dark_image", "template"]),
              case .string(let path)? = fields["image"], IconPicture.isValidPath(path) else { throw refusal }
        var darkPath: String?
        if let dark = fields["dark_image"] {
            guard case .string(let dark) = dark, IconPicture.isValidPath(dark) else { throw refusal }
            darkPath = dark
        }
        var isTemplate = false
        if let template = fields["template"] {
            guard case .bool(let flag) = template else { throw refusal }
            isTemplate = flag
        }
        // A template picture is tinted for every appearance; a dark picture
        // would mean nothing.
        guard !(isTemplate && darkPath != nil) else { throw refusal }
        self = .picture(IconPicture(path: path, darkPath: darkPath, isTemplate: isTemplate))
    }

    public init(from decoder: Decoder) throws {
        try self.init(parsing: JSONValue(from: decoder), "icon")
    }

    public var json: JSONValue {
        switch self {
        case .symbol(let name):
            return .object(["symbol": .string(name)])
        case .picture(let picture):
            var fields: [String: JSONValue] = ["image": .string(picture.path)]
            if let dark = picture.darkPath { fields["dark_image"] = .string(dark) }
            if picture.isTemplate { fields["template"] = .bool(true) }
            return .object(fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// A picture inside a Plugin's package that an icon declaration names: a
/// PNG or PDF, by its path from the package's root, resolved like a package
/// Image Source and never leaving the package. The Host reads it from the
/// installed package whenever it draws it and keeps no copy.
public struct IconPicture: Equatable, Hashable, Sendable {
    /// The picture, written `image`.
    public let path: String
    /// The picture for a Dark appearance, written `dark_image`; never with a
    /// template picture.
    public let darkPath: String?
    /// Written `template`: the Host tints the picture's shape with the
    /// Menu's foreground colour, as it tints a system symbol.
    public let isTemplate: Bool

    public init(path: String, darkPath: String? = nil, isTemplate: Bool = false) {
        self.path = path
        self.darkPath = darkPath
        self.isTemplate = isTemplate
    }

    static func isValidPath(_ path: String) -> Bool {
        PluginImageSource.isValidResourcePath(path, extensions: ["png", "pdf"])
    }

    /// The picture's files: `path`, then `darkPath` when given.
    public var paths: [String] { [path] + (darkPath.map { [$0] } ?? []) }

    /// Whether the file at `path` is drawn from a PDF, as vectors.
    public static func isPDF(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "pdf"
    }

    /// Refuses the package unless each of the picture's files is a regular
    /// file inside `root`, links followed, within `IconPictureBudgets`, and
    /// is the PNG or PDF its name says. `name` is the declaring member.
    public func check(in root: URL, _ name: String = "icon") throws {
        for path in paths {
            let refuse = { (reason: String) in ConfigurationError.invalidManifest("\(name)'s picture \(path) \(reason)") }
            let data: Data
            do {
                data = try PluginPackageResource.readChecked(path, in: root,
                                                             maximumBytes: IconPictureBudgets.maximumPictureBytes)
            } catch PluginHostServiceError.failed(let message) {
                if message.contains("outside the package") { throw refuse("leads outside the package") }
                if message.contains("exceeds") { throw refuse("exceeds \(IconPictureBudgets.maximumPictureBytes) bytes") }
                if message.contains("cannot be read") { throw refuse("cannot be read") }
                throw refuse("is not in the package")
            }
            if Self.isPDF(path) {
                guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                      document.numberOfPages >= 1, document.page(at: 1) != nil else {
                    throw refuse("is not a PDF")
                }
            } else {
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), type.conforms(to: .png),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
                    throw refuse("is not a PNG")
                }
                guard width <= IconPictureBudgets.maximumPNGEdge, height <= IconPictureBudgets.maximumPNGEdge else {
                    throw refuse("is larger than \(IconPictureBudgets.maximumPNGEdge) pixels on a side")
                }
            }
        }
    }
}

/// The bounds of the pictures an icon declaration names, part of the
/// Documented Plugin Interface (`PluginAPI/reference/manifest.md`, "Icon
/// pictures"). An icon is drawn a few dozen points wide at most, so these
/// leave room for a sharp Large Menu on a Retina display and little more.
public enum IconPictureBudgets {
    /// The most bytes of one picture, PNG or PDF.
    public static let maximumPictureBytes = 262_144
    /// The longest edge, in pixels, of a PNG picture.
    public static let maximumPNGEdge = 1_024
}

public extension PluginManifest {
    /// Refuses the package at `root` unless every picture its icon
    /// declarations name, the Plugin Icon's and each Command Icon's, is
    /// admitted (`IconPicture.check(in:)`).
    func checkIconPictures(in root: URL) throws {
        try icon?.picture?.check(in: root, "icon")
        for command in commands {
            try command.icon?.picture?.check(in: root, "Command \(command.id.rawValue)'s icon")
        }
    }
}
