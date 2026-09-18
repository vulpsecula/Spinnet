import Foundation

/// The Host-rendered editor used for a Command's instance input.
///
/// Most fields describe presentation only, and the Command remains the
/// authority for validating and executing the resulting JSON value. `size` and
/// `position` also carry a grammar the Host checks before it saves an Action,
/// so an invalid value is rejected in the Configuration Sheet rather than when
/// the Action runs.
public enum CommandConfigurationFieldKind: String, Codable, CaseIterable, Equatable, Hashable {
    case text
    case multilineText = "multiline_text"
    case toggle
    case choice
    case application
    case file
    case folder
    case shortcut
    case keyboardShortcut = "keyboard_shortcut"
    case url
    /// A width and a height, such as `800, 600` or `50%, 100%`.
    case size
    /// An x and a y from the visible frame's top-left, such as `0, 0` or `25%, 10%`.
    case position

    public var title: String {
        switch self {
        case .text: return "Text"
        case .multilineText: return "Multiline Text"
        case .toggle: return "Switch"
        case .choice: return "Choice"
        case .application: return "Application"
        case .file: return "File"
        case .folder: return "Folder"
        case .shortcut: return "Shortcut"
        case .keyboardShortcut: return "Keyboard Shortcut"
        case .url: return "URL"
        case .size: return "Size"
        case .position: return "Position"
        }
    }
}

/// Declarative metadata for one Host-rendered configuration field.
public struct CommandConfigurationField: Codable, Equatable, Hashable {
    public let kind: CommandConfigurationFieldKind
    public let title: String?
    public let placeholder: String?
    public let choices: [String]
    /// Names the field's member in the Action input when a Command declares
    /// several `configuration_fields`. A lone `configuration_field` has none.
    public let key: String?

    public init(
        kind: CommandConfigurationFieldKind,
        title: String? = nil,
        placeholder: String? = nil,
        choices: [String] = [],
        key: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.placeholder = placeholder
        self.choices = choices
        self.key = key
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case title
        case placeholder
        case choices
        case key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(CommandConfigurationFieldKind.self, forKey: .kind),
            title: container.decodeIfPresent(String.self, forKey: .title),
            placeholder: container.decodeIfPresent(String.self, forKey: .placeholder),
            choices: container.decodeIfPresent([String].self, forKey: .choices) ?? [],
            key: container.decodeIfPresent(String.self, forKey: .key)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
        if !choices.isEmpty {
            try container.encode(choices, forKey: .choices)
        }
        try container.encodeIfPresent(key, forKey: .key)
    }

    public var displayTitle: String { title ?? kind.title }

    /// Whether the Host accepts this value for the field. Only kinds with a
    /// Host-checked grammar can reject a value; every other kind leaves
    /// validation to its Command.
    public func isValidInput(_ input: JSONValue) -> Bool {
        switch kind {
        case .size:
            return WindowAxisGrammar.accepts(input, allowsZero: false)
        case .position:
            return WindowAxisGrammar.accepts(input, allowsZero: true)
        default:
            return true
        }
    }

    /// Explains the grammar of a Host-checked field, for the Configuration
    /// Sheet's error when a value is rejected.
    public var inputRequirement: String? {
        switch kind {
        case .size:
            return "Enter a width and a height, each in points or as a percentage of the visible frame up to 100%, such as 800, 600 or 50%, 100%. Neither may be zero."
        case .position:
            return "Enter an x and a y from the visible frame's top-left, each in points or as a percentage up to 100%, such as 0, 0 or 25%, 10%."
        default:
            return nil
        }
    }
}

/// Two comma-separated window lengths, each in points or as a percentage of
/// the visible frame. The Window Position scripts parse the same grammar; the
/// Host checks it so the Configuration Sheet can refuse a bad value.
private enum WindowAxisGrammar {
    static func accepts(_ input: JSONValue, allowsZero: Bool) -> Bool {
        guard case .string(let text) = input else { return false }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { acceptsLength($0, allowsZero: allowsZero) }
    }

    private static func acceptsLength(_ part: Substring, allowsZero: Bool) -> Bool {
        var text = part.trimmingCharacters(in: .whitespaces)
        let isPercent = text.hasSuffix("%")
        if isPercent { text.removeLast() }
        // Plain decimal digits only: no sign, exponent, or unit.
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count),
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }),
              let value = Double(text), value.isFinite,
              allowsZero || value > 0 else { return false }
        return value <= (isPercent ? 100 : WindowRect.coordinateLimit)
    }
}

/// Several Host-rendered fields for one Command, declared as
/// `configuration_fields`. The Action input is then an object holding one
/// member per field key: a boolean for a `toggle`, one of the declared choices
/// for a `choice`, and a string for every other kind.
public extension CommandDeclaration {
    /// Kinds whose value is a single string or boolean, which is what a
    /// member of a field set holds.
    static let fieldSetKinds: Set<CommandConfigurationFieldKind> = [.text, .toggle, .choice, .file, .folder, .url]

    /// Whether the input has exactly the declared members, each of its field's
    /// shape. A Command without `configuration_fields` accepts any input here.
    func acceptsConfigurationFieldsInput(_ input: JSONValue) -> Bool {
        guard !configurationFields.isEmpty else { return true }
        guard case .object(let values) = input,
              Set(values.keys) == Set(configurationFields.compactMap(\.key)) else { return false }
        return configurationFields.allSatisfy { field in
            guard let key = field.key, let value = values[key] else { return false }
            switch (field.kind, value) {
            case (.toggle, .bool): return true
            case (.choice, .string(let choice)): return field.choices.contains(choice)
            case (.toggle, _), (.choice, _): return false
            case (_, .string): return true
            default: return false
            }
        }
    }
}
