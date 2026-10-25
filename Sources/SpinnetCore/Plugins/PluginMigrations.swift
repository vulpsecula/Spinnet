import Foundation

/// A manifest's `migrations` block: how the data an earlier version of the
/// Plugin left behind maps onto this one. It may rename Commands, rename
/// settings keys, and drop the input of Actions whose Command takes none, and
/// nothing else, so a migration can never grant a Capability. The Host applies
/// it whenever it registers or updates the Plugin; every step leaves data it
/// already moved as it is, so applying it again changes nothing.
public struct PluginMigrations: Codable, Equatable {
    /// Retired Command IDs and the declared Command their Actions move onto,
    /// keeping their IDs. Written as `rename_commands`.
    public let renamedCommands: [CommandID: CommandID]
    /// Retired settings keys and the declared key their stored value moves
    /// to. Written as `rename_settings`.
    public let renamedSettings: [String: String]
    /// Declared Commands that take no input, whose Actions drop whatever an
    /// earlier version stored for them. Written as `drop_input`.
    public let droppedInputs: [CommandID]

    public init(
        renamedCommands: [CommandID: CommandID] = [:],
        renamedSettings: [String: String] = [:],
        droppedInputs: [CommandID] = []
    ) {
        self.renamedCommands = renamedCommands
        self.renamedSettings = renamedSettings
        self.droppedInputs = droppedInputs
    }

    public var isEmpty: Bool { renamedCommands.isEmpty && renamedSettings.isEmpty && droppedInputs.isEmpty }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case renamedCommands = "rename_commands"
        case renamedSettings = "rename_settings"
        case droppedInputs = "drop_input"
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        // A member the Host does not know is refused rather than skipped, so
        // no manifest can slip anything else, such as a grant, into the block.
        let members = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard members.allSatisfy({ CodingKeys(rawValue: $0) != nil }) else {
            throw ConfigurationError.invalidManifest(
                "A migration may only rename Commands, rename settings keys, and drop an Action's input; "
                    + "it never grants a Capability"
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let commands = try container.decodeIfPresent([String: String].self, forKey: .renamedCommands) ?? [:]
        self.init(
            renamedCommands: Dictionary(uniqueKeysWithValues: commands.map { (CommandID($0.key), CommandID($0.value)) }),
            renamedSettings: try container.decodeIfPresent([String: String].self, forKey: .renamedSettings) ?? [:],
            droppedInputs: try container.decodeIfPresent([CommandID].self, forKey: .droppedInputs) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !renamedCommands.isEmpty {
            try container.encode(Dictionary(uniqueKeysWithValues: renamedCommands.map { ($0.key.rawValue, $0.value.rawValue) }),
                                 forKey: .renamedCommands)
        }
        if !renamedSettings.isEmpty { try container.encode(renamedSettings, forKey: .renamedSettings) }
        if !droppedInputs.isEmpty { try container.encode(droppedInputs, forKey: .droppedInputs) }
    }

    /// Every step must end at something this version declares and start at
    /// something it no longer does, so a step moves only data an earlier
    /// version left and never touches what the user set up with this one.
    func validate(commands: [CommandDeclaration], settingsKeys: Set<String>) throws {
        let declared = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
        for (retired, current) in renamedCommands {
            guard declared[retired] == nil, declared[current] != nil else {
                throw ConfigurationError.invalidManifest(
                    "rename_commands must move a retired Command ID onto a declared one: \(retired.rawValue)"
                )
            }
        }
        for (retired, current) in renamedSettings {
            guard !settingsKeys.contains(retired), settingsKeys.contains(current) else {
                throw ConfigurationError.invalidManifest(
                    "rename_settings must move a retired settings key onto a declared one: \(retired)"
                )
            }
        }
        // The input of a configurable Command is what the user entered, and
        // it would be dropped again at every registration.
        guard Set(droppedInputs).count == droppedInputs.count,
              droppedInputs.allSatisfy({ declared[$0].map { !$0.isConfigurable } ?? false }) else {
            throw ConfigurationError.invalidManifest(
                "drop_input must name declared Commands that are not configurable, each once"
            )
        }
    }
}

public extension PluginManifest {
    /// The configuration with this Plugin's Actions moved off retired
    /// Commands and stripped of input their Command no longer takes, or nil
    /// when there is nothing to move. Actions keep their IDs, so every Slot,
    /// alias and Alternate Action stays as the user arranged it.
    func migrate(_ configuration: HostConfiguration) throws -> HostConfiguration? {
        guard !migrations.isEmpty else { return nil }
        var changed = false
        let actions = try configuration.actions.map { action -> ActionConfiguration in
            guard action.pluginID == id else { return action }
            let commandID = migrations.renamedCommands[action.commandID] ?? action.commandID
            let input = migrations.droppedInputs.contains(commandID) ? .null : action.input
            guard commandID != action.commandID || input != action.input,
                  let command = commands.first(where: { $0.id == commandID }) else { return action }
            changed = true
            return try ActionConfiguration(id: action.id, pluginID: id, command: command, input: input)
        }
        return changed ? try HostConfiguration(actions: actions, menu: configuration.menu) : nil
    }

    /// Stored Plugin Settings with values under retired keys moved to their
    /// new ones, or nil when there is nothing to move. A value already saved
    /// under a new key wins.
    func migrateSettings(_ stored: [String: JSONValue]) -> [String: JSONValue]? {
        guard migrations.renamedSettings.keys.contains(where: { stored[$0] != nil }) else { return nil }
        var settings = stored
        for (retired, current) in migrations.renamedSettings {
            guard let value = settings.removeValue(forKey: retired) else { continue }
            if settings[current] == nil { settings[current] = value }
        }
        return settings
    }
}
