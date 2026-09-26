import Foundation

/// One search destination. `{query}` is substituted only after the search
/// text is percent encoded, so it cannot change the host or query structure.
public struct SmartJumpSearchEngine: Equatable {
    public let name: String
    public let template: String

    public static let google = SmartJumpSearchEngine(name: "Google", template: "https://www.google.com/search?q={query}")

    /// The rows a `smart_jump` request names as `engines`, each a `name` and
    /// a `url` template, as a `list` setting holds them. The first is the
    /// default. No rows means Google.
    public static func engines(from rows: JSONValue?) throws -> [SmartJumpSearchEngine] {
        guard let rows, rows != .null else { return [.google] }
        guard Self.engineRows.listProblem(rows) == nil, case .array(let items) = rows else {
            throw PluginHostServiceError.invalidInput(
                "smart_jump expects engines as up to 10 rows of a unique name and an https url with {query} once in its path or query"
            )
        }
        let engines = items.compactMap { item -> SmartJumpSearchEngine? in
            guard case .object(let cells) = item, case .string(let name)? = cells["name"],
                  case .string(let template)? = cells["url"] else { return nil }
            return SmartJumpSearchEngine(name: name.trimmingCharacters(in: .whitespaces),
                                         template: template.trimmingCharacters(in: .whitespaces))
        }
        return engines.isEmpty ? [.google] : engines
    }

    /// What an engine row must be: the checks a `list` setting's columns
    /// make, so the Host accepts here what the Plugin Settings sheet saves.
    private static let engineRows = CommandConfigurationField(
        kind: .list, title: "engines",
        columns: [ListFieldColumn(key: "name", kind: .text, title: "name", unique: true, maxLength: 50),
                  ListFieldColumn(key: "url", kind: .urlTemplate, title: "url")],
        maxRows: 10
    )

    public func url(for text: String) throws -> URL {
        // RFC 3986 unreserved characters only, including for a path template.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw PluginHostServiceError.invalidInput("The search text cannot be encoded")
        }
        return try OpenableURL.validate(template.replacingOccurrences(of: "{query}", with: encoded))
    }
}
