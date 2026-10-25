import Foundation

/// One typed column of a `list` setting. Every cell is a string the Host
/// checks against its column before the settings save, so a Plugin receives
/// only rows its declaration allows.
public struct ListFieldColumn: Codable, Equatable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Equatable, Hashable {
        /// One line of text, such as a name.
        case text
        /// An https address holding `{query}` exactly once, in its path or
        /// query, such as `https://example.com/search?q={query}`.
        case urlTemplate = "url_template"
    }

    /// Longest text cell a column may allow.
    public static let textLengthLimit = 256

    public let key: String
    public let kind: Kind
    public let title: String?
    public let placeholder: String?
    /// No two rows may hold the same cell in this column, ignoring
    /// surrounding whitespace.
    public let unique: Bool
    /// Only on a `text` column: its longest cell, in characters. Written as
    /// `max_length`; without it the limit is `textLengthLimit`.
    public let maxLength: Int?

    public init(key: String, kind: Kind, title: String? = nil, placeholder: String? = nil,
                unique: Bool = false, maxLength: Int? = nil) {
        self.key = key
        self.kind = kind
        self.title = title
        self.placeholder = placeholder
        self.unique = unique
        self.maxLength = maxLength
    }

    private enum CodingKeys: String, CodingKey {
        case key, kind, title, placeholder, unique
        case maxLength = "max_length"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: container.decode(String.self, forKey: .key),
            kind: container.decode(Kind.self, forKey: .kind),
            title: container.decodeIfPresent(String.self, forKey: .title),
            placeholder: container.decodeIfPresent(String.self, forKey: .placeholder),
            unique: container.decodeIfPresent(Bool.self, forKey: .unique) ?? false,
            maxLength: container.decodeIfPresent(Int.self, forKey: .maxLength)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
        if unique { try container.encode(true, forKey: .unique) }
        try container.encodeIfPresent(maxLength, forKey: .maxLength)
    }

    public var displayTitle: String { title ?? key }

    /// Whether the column accepts this cell.
    public func accepts(_ cell: String) -> Bool {
        switch kind {
        case .text:
            return !cell.trimmingCharacters(in: .whitespaces).isEmpty && !cell.contains(where: \.isNewline)
                && cell.count <= (maxLength ?? Self.textLengthLimit)
        case .urlTemplate:
            return Self.acceptsURLTemplate(cell)
        }
    }

    /// What a cell of this column must be, for the error when one is refused.
    public var requirement: String {
        switch kind {
        case .text:
            return "\(displayTitle) needs one line of text, at most \(maxLength ?? Self.textLengthLimit) characters."
        case .urlTemplate:
            return "\(displayTitle) must be an https address with {query} once in its path or query, such as https://example.com/search?q={query}."
        }
    }

    /// `{query}` is later replaced by percent-encoded text, so where it may
    /// stand is checked with a probe in its place: never in the host, the
    /// port, the user name, or the fragment.
    private static func acceptsURLTemplate(_ template: String) -> Bool {
        let probe = "spinnet_query_probe"
        guard template.components(separatedBy: "{query}").count == 2,
              let url = try? OpenableURL.validate(template.replacingOccurrences(of: "{query}", with: probe)),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.host?.contains(probe) == false,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.path.contains(probe) || components.query?.contains(probe) == true
    }
}

public extension CommandConfigurationField {
    /// Most rows a `list` setting may hold, and the default for `max_rows`.
    static let listRowLimit = 100

    /// Most columns a `list` setting may declare.
    static let listColumnLimit = 8

    /// Why a value is not a valid `list` value for this field, naming the
    /// first row at fault, or nil when it is one.
    func listProblem(_ value: JSONValue) -> String? {
        guard case .array(let rows) = value else { return "\(displayTitle) is not a list of rows." }
        let limit = maxRows ?? Self.listRowLimit
        guard rows.count <= limit else { return "\(displayTitle) holds at most \(limit) rows." }
        let keys = Set(columns.map(\.key))
        var seen: [String: [String: Int]] = [:]
        for (index, row) in rows.enumerated() {
            let label = "Row \(index + 1) of \(displayTitle)"
            guard case .object(let cells) = row, Set(cells.keys) == keys else {
                return "\(label) does not hold one value for each column."
            }
            for column in columns {
                guard case .string(let cell)? = cells[column.key], column.accepts(cell) else {
                    return "\(label): \(column.requirement)"
                }
            }
            for column in columns where column.unique {
                guard case .string(let cell)? = cells[column.key] else { continue }
                let normalized = cell.trimmingCharacters(in: .whitespaces)
                if let earlier = seen[column.key]?[normalized] {
                    return "\(label) repeats the \(column.displayTitle) of row \(earlier + 1)."
                }
                seen[column.key, default: [:]][normalized] = index
            }
        }
        return nil
    }

    /// The rows of a `list` setting stored as text, as settings saved before
    /// the `list` kind held them: one row per line, cells separated by `|` in
    /// column order, the last taking the rest of the line. Nil unless the
    /// text holds at least one row and every row is valid.
    func listRows(fromText text: String) -> JSONValue? {
        guard kind == .list, !columns.isEmpty else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var rows: [JSONValue] = []
        for line in lines {
            let cells = line.split(separator: "|", maxSplits: columns.count - 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == columns.count else { return nil }
            rows.append(.object(Dictionary(uniqueKeysWithValues: zip(columns.map(\.key), cells.map(JSONValue.string)))))
        }
        let value = JSONValue.array(rows)
        return !rows.isEmpty && listProblem(value) == nil ? value : nil
    }
}
