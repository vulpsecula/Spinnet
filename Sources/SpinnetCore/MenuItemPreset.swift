import Foundation

public enum MenuItemPresetSource: String, Codable, CaseIterable, Equatable, Hashable {
    case builtIn = "built_in"
    case plugin

    public var title: String {
        switch self {
        case .builtIn: return "Built-in"
        case .plugin: return "Plugin"
        }
    }
}

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
    public let defaultInputs: [String: JSONValue]

    public init(
        readiness: MenuItemPresetReadiness = .setupRequired,
        isConfigurable: Bool = true,
        defaultPrimaryCommandID: CommandID? = nil,
        defaultAlternateCommandIDs: [CommandID] = [],
        defaultInputs: [String: JSONValue] = [:]
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
}

public struct MenuItemPreset: Equatable {
    public let pluginID: PluginID
    public let name: String
    public let commands: [CommandDeclaration]
    public let source: MenuItemPresetSource
    public let declaration: MenuItemPresetDeclaration
    public let unavailableReason: ActionUnavailableReason?

    public var id: String { pluginID.rawValue }
    public var readiness: MenuItemPresetReadiness { declaration.readiness }
    public var isAvailable: Bool { unavailableReason == nil }
    public var isConfigurable: Bool { declaration.isConfigurable }

    public var stateLabel: String {
        guard unavailableReason == nil else { return "Unavailable" }
        return readiness.label
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
        source: MenuItemPresetSource,
        declaration: MenuItemPresetDeclaration,
        unavailableReason: ActionUnavailableReason? = nil
    ) {
        self.pluginID = pluginID
        self.name = name
        self.commands = commands
        self.source = source
        self.declaration = declaration
        self.unavailableReason = unavailableReason
    }
}

public struct MenuItemPresetSection: Equatable {
    public let source: MenuItemPresetSource
    public let presets: [MenuItemPreset]

    public init(source: MenuItemPresetSource, presets: [MenuItemPreset]) {
        self.source = source
        self.presets = presets
    }
}
