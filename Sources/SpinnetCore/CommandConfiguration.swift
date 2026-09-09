import Foundation

/// The Host-rendered editor used for a Command's instance input.
///
/// A field describes presentation only. The Command remains the authority for
/// validating and executing the resulting JSON value.
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
        }
    }
}

/// Declarative metadata for one Host-rendered configuration field.
public struct CommandConfigurationField: Codable, Equatable, Hashable {
    public let kind: CommandConfigurationFieldKind
    public let title: String?
    public let placeholder: String?
    public let choices: [String]

    public init(
        kind: CommandConfigurationFieldKind,
        title: String? = nil,
        placeholder: String? = nil,
        choices: [String] = []
    ) {
        self.kind = kind
        self.title = title
        self.placeholder = placeholder
        self.choices = choices
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case title
        case placeholder
        case choices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(CommandConfigurationFieldKind.self, forKey: .kind),
            title: container.decodeIfPresent(String.self, forKey: .title),
            placeholder: container.decodeIfPresent(String.self, forKey: .placeholder),
            choices: container.decodeIfPresent([String].self, forKey: .choices) ?? []
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
    }

    public var displayTitle: String { title ?? kind.title }
}
