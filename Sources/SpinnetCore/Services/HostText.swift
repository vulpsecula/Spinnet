import Foundation

/// Host-owned English that the Host shows in the interface language, such as
/// a Host Confirmation built outside the Host. The key is the String Catalog
/// key, with `%@` for each argument; a verbatim text, such as a package name,
/// a version or a tool's own output, is shown as it is in every language.
public struct HostText: Equatable, Hashable, Sendable {
    public let key: String
    public let arguments: [HostText]
    public let isVerbatim: Bool

    public init(_ key: String, _ arguments: HostText...) {
        self.init(key: key, arguments: arguments)
    }

    public init(key: String, arguments: [HostText]) {
        self.key = key
        self.arguments = arguments
        isVerbatim = false
    }

    private init(verbatim text: String) {
        key = text
        arguments = []
        isVerbatim = true
    }

    public static func verbatim(_ text: String) -> HostText { HostText(verbatim: text) }

    /// The development language's text.
    public var english: String {
        guard !isVerbatim, !arguments.isEmpty else { return key }
        return String(format: key, arguments: arguments.map { $0.english as NSString as CVarArg })
    }

    /// Every catalog key this text and its arguments look up.
    public var catalogKeys: [String] {
        isVerbatim ? [] : [key] + arguments.flatMap(\.catalogKeys)
    }

    /// Sentences shown together, in English separated by a space.
    public static func englishSentences(_ sentences: [HostText]) -> String {
        sentences.map(\.english).joined(separator: " ")
    }
}
