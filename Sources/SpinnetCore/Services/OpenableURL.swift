import Foundation

/// The Host's rule for which text the `open_url` Host Service may hand to the
/// default browser. It lives Host-side so a Plugin that skips its own checks
/// still cannot open another scheme, and its messages are the stable
/// explanations a user sees when a link is refused.
public enum OpenableURL {
    /// Longest link, in characters after trimming, the Host will open.
    public static let maximumLength = 2048

    public static let emptyMessage = "The link is empty"
    public static let tooLongMessage = "The link is longer than \(maximumLength) characters"
    public static let malformedMessage = "The text is not a single valid link"
    public static let unsupportedSchemeMessage = "Only http and https links can be opened"

    /// Trims surrounding whitespace and returns the link to open, or throws
    /// `invalidInput` with one of the messages above.
    public static func validate(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PluginHostServiceError.invalidInput(emptyMessage) }
        guard trimmed.count <= maximumLength else { throw PluginHostServiceError.invalidInput(tooLongMessage) }
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !trimmed.unicodeScalars.contains(where: separators.contains),
              let components = URLComponents(string: trimmed) else {
            throw PluginHostServiceError.invalidInput(malformedMessage)
        }
        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw PluginHostServiceError.invalidInput(unsupportedSchemeMessage)
        }
        guard components.host?.isEmpty == false, let url = components.url else {
            throw PluginHostServiceError.invalidInput(malformedMessage)
        }
        return url
    }
}
