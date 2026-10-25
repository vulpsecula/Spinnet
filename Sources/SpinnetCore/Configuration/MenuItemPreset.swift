import Foundation

public enum MenuItemPresetReadiness: String, Codable, Equatable, Hashable {
    case readyToUse = "ready_to_use"
    case setupRequired = "setup_required"

    public var label: String {
        switch self {
        case .readyToUse: return "Ready to Use"
        case .setupRequired: return "Setup Required"
        }
    }
}

public struct MenuItemPresetDeclaration: Codable, Equatable {
    public let readiness: MenuItemPresetReadiness
    public let isConfigurable: Bool
    public let defaultPrimaryCommandID: CommandID?
    public let defaultAlternateCommandIDs: [CommandID]
    public let defaultInputs: [CommandID: JSONValue]

    public init(
        readiness: MenuItemPresetReadiness = .setupRequired,
        isConfigurable: Bool = true,
        defaultPrimaryCommandID: CommandID? = nil,
        defaultAlternateCommandIDs: [CommandID] = [],
        defaultInputs: [CommandID: JSONValue] = [:]
    ) {
        self.readiness = readiness
        self.isConfigurable = isConfigurable
        self.defaultPrimaryCommandID = defaultPrimaryCommandID
        self.defaultAlternateCommandIDs = defaultAlternateCommandIDs
        self.defaultInputs = defaultInputs
    }

    private enum CodingKeys: String, CodingKey {
        case readiness
        case isConfigurable = "is_configurable"
        case defaultPrimaryCommandID = "default_primary_command_id"
        case defaultAlternateCommandIDs = "default_alternate_command_ids"
        case defaultInputs = "default_inputs"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        readiness = try container.decode(MenuItemPresetReadiness.self, forKey: .readiness)
        isConfigurable = try container.decode(Bool.self, forKey: .isConfigurable)
        defaultPrimaryCommandID = try container.decodeIfPresent(
            CommandID.self,
            forKey: .defaultPrimaryCommandID
        )
        defaultAlternateCommandIDs = try container.decodeIfPresent(
            [CommandID].self,
            forKey: .defaultAlternateCommandIDs
        ) ?? []
        let inputs = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .defaultInputs
        ) ?? [:]
        defaultInputs = Dictionary(uniqueKeysWithValues: inputs.map {
            (CommandID($0.key), $0.value)
        })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(readiness, forKey: .readiness)
        try container.encode(isConfigurable, forKey: .isConfigurable)
        try container.encodeIfPresent(defaultPrimaryCommandID, forKey: .defaultPrimaryCommandID)
        try container.encode(defaultAlternateCommandIDs, forKey: .defaultAlternateCommandIDs)
        try container.encode(
            Dictionary(uniqueKeysWithValues: defaultInputs.map {
                ($0.key.rawValue, $0.value)
            }),
            forKey: .defaultInputs
        )
    }
}

public struct MenuItemPreset: Equatable {
    public let pluginID: PluginID
    public let name: String
    public let commands: [CommandDeclaration]
    public let declaration: MenuItemPresetDeclaration
    public let unavailableReason: ActionUnavailableReason?
    /// The Plugin declares Plugin Settings and one has no usable value yet.
    /// The Preset can still be placed; its Menu Items wait for the settings.
    public let needsPluginSettings: Bool

    public var id: String { pluginID.rawValue }
    public var readiness: MenuItemPresetReadiness { declaration.readiness }
    public var isAvailable: Bool { unavailableReason == nil }
    public var isConfigurable: Bool { declaration.isConfigurable }

    public var stateLabel: String {
        guard unavailableReason == nil else { return "Unavailable" }
        return needsPluginSettings ? "Needs Plugin Settings" : readiness.label
    }

    public var configurationLabel: String {
        isConfigurable ? "Configurable" : "No Configuration"
    }

    public var accessibilityLabel: String {
        let commandNames = commands.map(\.title).joined(separator: ", ")
        let reason = unavailableReason.map { ", \($0.description)" } ?? ""
        return "\(name), \(stateLabel), \(configurationLabel)\(reason), Commands: \(commandNames)"
    }

    public init(
        pluginID: PluginID,
        name: String,
        commands: [CommandDeclaration],
        declaration: MenuItemPresetDeclaration,
        unavailableReason: ActionUnavailableReason? = nil,
        needsPluginSettings: Bool = false
    ) {
        self.pluginID = pluginID
        self.name = name
        self.commands = commands
        self.declaration = declaration
        self.unavailableReason = unavailableReason
        self.needsPluginSettings = needsPluginSettings
    }
}
