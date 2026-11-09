import Foundation

/// A Plugin Tag from the vocabulary published in `PluginAPI/plugin-tags.json`:
/// a category a Plugin declares to file its Menu Item Preset in the Library.
/// It is display-only and grants nothing.
///
/// A manifest may also name tags outside this vocabulary, written for a newer
/// Host; they are admitted and kept in `PluginManifest.tags` but are no
/// Library filter.
public enum PluginTag: String, CaseIterable, Sendable, Codable {
    case window
    case media
    case apps
    case text
    case clipboard
    case files
    case browser
    case developer
    case system

    /// The most tags one manifest may declare.
    public static let maximumDeclaredTags = 3
    /// The longest tag identifier, in characters.
    public static let maximumLength = 32

    /// The English title the Library shows, which is also its catalog key.
    public var title: String { rawValue.capitalized }

    /// Whether `value` is a well-formed tag identifier, known or not:
    /// lower-case ASCII letters and digits in parts joined by single hyphens,
    /// at most `maximumLength` characters.
    public static func isWellFormed(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
    }

    /// Reads a manifest's `tags` member, refusing anything but a short list
    /// of distinct well-formed identifiers with a reason naming `tags`.
    static func parsing(_ value: JSONValue) throws -> [String] {
        let shape = "tags must be a list of at most \(maximumDeclaredTags) Plugin Tags, each lower-case letters "
            + "and digits joined by single hyphens, at most \(maximumLength) characters, such as window or media"
        guard case .array(let items) = value else { throw ConfigurationError.invalidManifest(shape) }
        var tags: [String] = []
        for item in items {
            guard case .string(let tag) = item, isWellFormed(tag) else {
                throw ConfigurationError.invalidManifest(shape)
            }
            guard !tags.contains(tag) else {
                throw ConfigurationError.invalidManifest("tags names \(tag) more than once")
            }
            tags.append(tag)
        }
        guard tags.count <= maximumDeclaredTags else {
            throw ConfigurationError.invalidManifest(
                "tags names \(tags.count) Plugin Tags; a Plugin declares at most \(maximumDeclaredTags)")
        }
        return tags
    }
}
