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
    /// A secret the Host keeps, such as an API key. The Action stores only the
    /// credential reference; the Host renders a secure field and injects the
    /// secret into an `https_request` itself. Only in `configuration_fields`.
    case credential
    /// The base URL of a remote service: https only, without a user name,
    /// query, fragment, or port other than 443. On a Command that contacts
    /// the network, a host the Plugin did not declare needs the user's consent
    /// before the Configuration Sheet saves. Only in `configuration_fields`;
    /// unlike `url`, which accepts any link.
    case httpsEndpoint = "https_endpoint"
    /// Some of the field's `choices`, each at most once, in the order the
    /// user put them, such as which translation sources run and in what
    /// order. Only in `settings_fields`, and never overridable.
    case orderedChoices = "ordered_choices"
    /// An ordered set of search destinations rendered as named editable rows.
    /// The first entry is the default engine. Only in Plugin Settings.
    case searchEngines = "search_engines"

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
        case .credential: return "Credential"
        case .httpsEndpoint: return "HTTPS Endpoint"
        case .orderedChoices: return "Ordered Choices"
        case .searchEngines: return "Search Engines"
        }
    }
}

/// Declarative metadata for one Host-rendered configuration field.
/// The choices of another field in the same set that use a field. A field
/// whose condition is not met is not used by the Action, so the Host ignores
/// its value, for instance when deciding whether a save folder must exist.
public struct CommandConfigurationFieldCondition: Codable, Equatable, Hashable {
    public let key: String
    public let values: [String]

    public init(key: String, values: [String]) {
        self.key = key
        self.values = values
    }
}

public struct CommandConfigurationField: Codable, Equatable, Hashable {
    public let kind: CommandConfigurationFieldKind
    public let title: String?
    public let placeholder: String?
    public let choices: [String]
    /// What to show for each of `choices`, in the same order, when the stored
    /// value is a code such as `ZH-HANS`. Empty means the choices show
    /// themselves. Written as `choice_titles`.
    public let choiceTitles: [String]
    /// Names the field's member in the Action input when a Command declares
    /// several `configuration_fields`. A lone `configuration_field` has none.
    public let key: String?
    /// Written as `used_when`; only valid inside `configuration_fields`.
    public let usedWhen: CommandConfigurationFieldCondition?
    /// Only in `settings_fields`: one Menu Item may set its own value in place
    /// of the Plugin's, such as a different target language.
    public let overridable: Bool
    /// Only in `settings_fields`: the heading this setting sits under, so a
    /// Plugin with many settings reads as a few short groups rather than one
    /// long list. Settings with no group come first, in their declared order.
    public let group: String?

    public init(
        kind: CommandConfigurationFieldKind,
        title: String? = nil,
        placeholder: String? = nil,
        choices: [String] = [],
        choiceTitles: [String] = [],
        key: String? = nil,
        usedWhen: CommandConfigurationFieldCondition? = nil,
        overridable: Bool = false,
        group: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.placeholder = placeholder
        self.choices = choices
        self.choiceTitles = choiceTitles
        self.key = key
        self.usedWhen = usedWhen
        self.overridable = overridable
        self.group = group
    }

    /// Whether an Action whose field values are `values` uses this field:
    /// the governing `choice` holds one of the named choices, or the
    /// governing `ordered_choices` holds at least one of them.
    public func isUsed(by values: [String: JSONValue]) -> Bool {
        guard let usedWhen else { return true }
        switch values[usedWhen.key] {
        case .string(let chosen)?:
            return usedWhen.values.contains(chosen)
        case .array?:
            return values[usedWhen.key]?.strings?.contains(where: usedWhen.values.contains) ?? false
        default:
            return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case title
        case placeholder
        case choices
        case choiceTitles = "choice_titles"
        case key
        case usedWhen = "used_when"
        case overridable
        case group
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(CommandConfigurationFieldKind.self, forKey: .kind),
            title: container.decodeIfPresent(String.self, forKey: .title),
            placeholder: container.decodeIfPresent(String.self, forKey: .placeholder),
            choices: container.decodeIfPresent([String].self, forKey: .choices) ?? [],
            choiceTitles: container.decodeIfPresent([String].self, forKey: .choiceTitles) ?? [],
            key: container.decodeIfPresent(String.self, forKey: .key),
            usedWhen: container.decodeIfPresent(CommandConfigurationFieldCondition.self, forKey: .usedWhen),
            overridable: container.decodeIfPresent(Bool.self, forKey: .overridable) ?? false,
            group: container.decodeIfPresent(String.self, forKey: .group)
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
        if !choiceTitles.isEmpty {
            try container.encode(choiceTitles, forKey: .choiceTitles)
        }
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(usedWhen, forKey: .usedWhen)
        if overridable { try container.encode(true, forKey: .overridable) }
        try container.encodeIfPresent(group, forKey: .group)
    }

    public var displayTitle: String { title ?? kind.title }

    /// What to show for one choice: its title when the field gives one, and
    /// the choice itself otherwise.
    public func displayTitle(forChoice choice: String) -> String {
        guard let index = choices.firstIndex(of: choice), choiceTitles.indices.contains(index) else { return choice }
        return choiceTitles[index]
    }

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

public extension CommandConfigurationField {
    /// Whether a value has this field's shape as a member of a field set: a
    /// boolean for a `toggle`, one of the choices for a `choice`, distinct
    /// choices for `ordered_choices`, a valid reference for a `credential`,
    /// an https base URL for an `https_endpoint`, and a string otherwise.
    func acceptsMemberValue(_ value: JSONValue) -> Bool {
        switch (kind, value) {
        case (.toggle, .bool): return true
        case (.choice, .string(let choice)): return choices.contains(choice)
        case (.credential, .string(let reference)): return PluginCredentialReference.isValid(reference)
        case (.httpsEndpoint, _): return Self.httpsEndpointHost(value) != nil
        case (.orderedChoices, _):
            guard let chosen = value.strings else { return false }
            return chosen.allSatisfy(choices.contains) && Set(chosen).count == chosen.count
        case (.toggle, _), (.choice, _), (.credential, _): return false
        case (_, .string): return true
        default: return false
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
    static let fieldSetKinds: Set<CommandConfigurationFieldKind> = [
        .text, .multilineText, .toggle, .choice, .file, .folder, .url, .credential, .httpsEndpoint
    ]

    /// Kinds that are Plugin Settings only and never belong to an Action's
    /// configuration fields.
    static let settingsOnlyKinds: Set<CommandConfigurationFieldKind> = [.searchEngines]

    /// Kinds that only make sense as a member of a field set: a credential
    /// reference and a network endpoint describe one part of a request.
    static let fieldSetOnlyKinds: Set<CommandConfigurationFieldKind> = [.credential, .httpsEndpoint]

    /// Whether the input has exactly the declared members, each of its field's
    /// shape. A Command without `configuration_fields` accepts any input here.
    func acceptsConfigurationFieldsInput(_ input: JSONValue) -> Bool {
        guard !configurationFields.isEmpty else { return true }
        guard case .object(let values) = input,
              Set(values.keys) == Set(configurationFields.compactMap(\.key)) else { return false }
        return configurationFields.allSatisfy { field in
            guard let key = field.key, let value = values[key] else { return false }
            return field.acceptsMemberValue(value)
        }
    }
}
