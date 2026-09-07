import Foundation

public enum CommandExecution: String, Codable, Equatable, Hashable {
    case host
    case javascript

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case Self.host.rawValue:
            self = .host
        case Self.javascript.rawValue, "common_javascript", "script":
            self = .javascript
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unsupported Command execution \(value)"
            )
        }
    }
}

public enum HostCommand: String, Codable, CaseIterable, Equatable, Hashable {
    case openURL = "url.open"

    public func resolvedURL(from input: JSONValue) -> URL? {
        guard self == .openURL,
              case .string(let value) = input,
              let url = URL(string: value),
              url.scheme?.isEmpty == false else { return nil }
        return url
    }
}

public struct CommandDeclaration: Codable, Equatable, Hashable {
    public let id: CommandID
    public let title: String
    public let execution: CommandExecution
    public let hostCommand: HostCommand?
    public let script: String?

    public init(
        id: CommandID,
        title: String,
        execution: CommandExecution = .host,
        hostCommand: HostCommand? = nil,
        script: String? = nil
    ) {
        self.id = id
        self.title = title
        self.execution = execution
        self.hostCommand = hostCommand
        self.script = script
    }

    /// The manifest-facing script reference. `scriptPath` keeps call sites
    /// explicit about the value being relative to the Plugin package root.
    public var scriptPath: String? { script }

    public init(
        id: CommandID,
        title: String,
        execution: CommandExecution = .javascript,
        scriptPath: String
    ) {
        self.init(
            id: id,
            title: title,
            execution: execution,
            script: scriptPath
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case execution
        case hostCommand = "host_command"
        case script
        case scriptPath = "script_path"
        case javascript
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let script = try container.decodeIfPresent(String.self, forKey: .script)
            ?? container.decodeIfPresent(String.self, forKey: .scriptPath)
            ?? container.decodeIfPresent(String.self, forKey: .javascript)
        self.init(
            id: try container.decode(CommandID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            execution: try container.decode(CommandExecution.self, forKey: .execution),
            hostCommand: try container.decodeIfPresent(HostCommand.self, forKey: .hostCommand),
            script: script
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(execution, forKey: .execution)
        try container.encodeIfPresent(hostCommand, forKey: .hostCommand)
        try container.encodeIfPresent(script, forKey: .script)
    }
}

public struct PluginManifest: Codable, Equatable {
    public static let supportedProtocolVersion = "1.0"

    public let protocolVersion: String
    public let id: PluginID
    public let name: String
    public let version: String
    public let capabilities: [PluginCapability]
    public let commands: [CommandDeclaration]
    public let preset: MenuItemPresetDeclaration

    public init(
        protocolVersion: String = Self.supportedProtocolVersion,
        id: PluginID,
        name: String,
        version: String,
        capabilities: [PluginCapability] = [],
        commands: [CommandDeclaration],
        preset: MenuItemPresetDeclaration = MenuItemPresetDeclaration()
    ) throws {
        self.protocolVersion = protocolVersion
        self.id = id
        self.name = name
        self.version = version
        self.capabilities = capabilities
        self.commands = commands
        self.preset = preset
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case id
        case name
        case version
        case capabilities
        case commands
        case preset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        self.id = try container.decode(PluginID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.version = try container.decode(String.self, forKey: .version)
        self.capabilities = try container.decodeIfPresent(
            [PluginCapability].self,
            forKey: .capabilities
        ) ?? []
        self.commands = try container.decode([CommandDeclaration].self, forKey: .commands)
        self.preset = try container.decodeIfPresent(
            MenuItemPresetDeclaration.self,
            forKey: .preset
        ) ?? MenuItemPresetDeclaration()
        try validate()
    }

    public func validate() throws {
        guard protocolVersion == Self.supportedProtocolVersion else {
            throw ConfigurationError.invalidManifest(
                "Unsupported protocol version \(protocolVersion)"
            )
        }
        try validateText(id.rawValue, name: "Plugin ID")
        try validateText(name, name: "Plugin name")
        try validateText(version, name: "Plugin version")
        guard Set(capabilities).count == capabilities.count else {
            throw ConfigurationError.invalidManifest("Plugin declares a Capability more than once")
        }
        guard !commands.isEmpty else {
            throw ConfigurationError.invalidManifest("Plugin declares no Commands")
        }

        var commandIDs = Set<CommandID>()
        for command in commands {
            guard commandIDs.insert(command.id).inserted else {
                throw ConfigurationError.invalidManifest(
                    "Duplicate Command ID \(command.id.rawValue)"
                )
            }
            try validateText(command.id.rawValue, name: "Command ID")
            try validateText(command.title, name: "Command title")
            try validate(command)
        }

        let primaryCommandID = preset.defaultPrimaryCommandID ?? commands[0].id
        guard commandIDs.contains(primaryCommandID) else {
            throw ConfigurationError.invalidManifest("Preset Primary Command is not declared")
        }
        guard Set(preset.defaultAlternateCommandIDs).count == preset.defaultAlternateCommandIDs.count,
              !preset.defaultAlternateCommandIDs.contains(primaryCommandID),
              preset.defaultAlternateCommandIDs.allSatisfy(commandIDs.contains) else {
            throw ConfigurationError.invalidManifest("Preset Alternate Commands are invalid")
        }
        guard preset.defaultInputs.keys.allSatisfy(commandIDs.contains) else {
            throw ConfigurationError.invalidManifest("Preset input references an undeclared Command")
        }
        if preset.readiness == .readyToUse {
            let defaultCommandIDs = [primaryCommandID] + preset.defaultAlternateCommandIDs
            guard defaultCommandIDs.allSatisfy({ preset.defaultInputs[$0] != nil }) else {
                throw ConfigurationError.invalidManifest(
                    "Ready-to-Use Preset requires an input for every default Command"
                )
            }
            for commandID in defaultCommandIDs {
                guard let command = commands.first(where: { $0.id == commandID }),
                      let input = preset.defaultInputs[commandID],
                      validDefaultInput(input, for: command) else {
                    throw ConfigurationError.invalidManifest(
                        "Ready-to-Use Preset input is invalid for Command \(commandID.rawValue)"
                    )
                }
            }
        }
    }

    private func validate(_ command: CommandDeclaration) throws {
        switch command.execution {
        case .host:
            guard command.hostCommand != nil, command.script == nil else {
                throw ConfigurationError.invalidManifest(
                    "Host Command \(command.id.rawValue) must declare host_command only"
                )
            }
        case .javascript:
            guard let script = command.script,
                  isValidScriptReference(script),
                  command.hostCommand == nil else {
                throw ConfigurationError.invalidManifest(
                    "JavaScript Command \(command.id.rawValue) must declare a relative script only"
                )
            }
        }
    }

    private func validDefaultInput(_ input: JSONValue, for command: CommandDeclaration) -> Bool {
        switch command.execution {
        case .host:
            guard let hostCommand = command.hostCommand else { return false }
            return hostCommand.resolvedURL(from: input) != nil
        case .javascript:
            return (try? JSONEncoder().encode(input)) != nil
        }
    }

    private func isValidScriptReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256,
              !trimmed.hasPrefix("/"), !trimmed.contains("\\") else { return false }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(".") && !components.contains("..")
    }

    private func validateText(_ value: String, name: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidManifest("\(name) is empty")
        }
        guard value.count <= 256 else {
            throw ConfigurationError.invalidManifest("\(name) is too long")
        }
    }
}

public struct PluginPackage {
    public let rootURL: URL
    public let manifest: PluginManifest
    public let presetSource: MenuItemPresetSource

    public init(
        rootURL: URL,
        manifest: PluginManifest,
        presetSource: MenuItemPresetSource = .plugin
    ) {
        self.rootURL = rootURL
        self.manifest = manifest
        self.presetSource = presetSource
    }
}

public enum PluginManifestLoader {
    public static func decode(_ data: Data) throws -> PluginManifest {
        do {
            return try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.invalidManifest(error.localizedDescription)
        }
    }

    public static func load(packageAt rootURL: URL) throws -> PluginPackage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ConfigurationError.invalidManifest("Plugin package is not a directory")
        }
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        let manifest = try decode(Data(contentsOf: manifestURL))
        return PluginPackage(rootURL: rootURL, manifest: manifest)
    }
}

public struct ActionConfiguration: Codable, Equatable, Hashable {
    public let id: ActionID
    public let pluginID: PluginID
    public let commandID: CommandID
    public let title: String
    public let execution: CommandExecution
    public let hostCommand: HostCommand?
    public let script: String?
    public let input: JSONValue

    public init(
        id: ActionID,
        pluginID: PluginID,
        command: CommandDeclaration,
        input: JSONValue
    ) throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidAction("Action ID is empty")
        }
        guard !pluginID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidAction("Plugin ID is empty")
        }
        guard !command.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidAction("Command ID is empty")
        }
        guard !command.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidAction("Action title is empty")
        }
        switch command.execution {
        case .host:
            guard command.hostCommand != nil, command.script == nil else {
                throw ConfigurationError.invalidAction("Host Action is missing its Host Command")
            }
        case .javascript:
            guard let script = command.script,
                  !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationError.invalidAction("Scripted Action is missing its script")
            }
        }
        self.id = id
        self.pluginID = pluginID
        self.commandID = command.id
        self.title = command.title
        self.execution = command.execution
        self.hostCommand = command.hostCommand
        self.script = command.script
        self.input = input
    }

    public var scriptPath: String? { script }

    public var declaredCommand: CommandDeclaration {
        CommandDeclaration(
            id: commandID,
            title: title,
            execution: execution,
            hostCommand: hostCommand,
            script: script
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case pluginID
        case commandID
        case title
        case execution
        case hostCommand
        case script
        case input
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ActionID.self, forKey: .id),
            pluginID: container.decode(PluginID.self, forKey: .pluginID),
            command: CommandDeclaration(
                id: container.decode(CommandID.self, forKey: .commandID),
                title: container.decode(String.self, forKey: .title),
                execution: container.decode(CommandExecution.self, forKey: .execution),
                hostCommand: container.decodeIfPresent(HostCommand.self, forKey: .hostCommand),
                script: container.decodeIfPresent(String.self, forKey: .script)
            ),
            input: container.decode(JSONValue.self, forKey: .input)
        )
    }
}

public struct MenuItemConfiguration: Codable, Equatable, Hashable {
    public let primaryActionID: ActionID
    public let alternateActionIDs: [ActionID]

    public init(
        primaryActionID: ActionID,
        alternateActionIDs: [ActionID] = []
    ) throws {
        guard !primaryActionID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidMenu("Primary Action ID is empty")
        }
        guard alternateActionIDs.allSatisfy({
            !$0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ConfigurationError.invalidMenu("Alternate Action ID is empty")
        }
        guard Set(alternateActionIDs).count == alternateActionIDs.count else {
            throw ConfigurationError.invalidMenu("An Alternate Action is bound more than once")
        }
        guard !alternateActionIDs.contains(primaryActionID) else {
            throw ConfigurationError.invalidMenu(
                "An Action cannot be both Primary and Alternate"
            )
        }
        self.primaryActionID = primaryActionID
        self.alternateActionIDs = alternateActionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case primaryActionID = "primary_action_id"
        case alternateActionIDs = "alternate_action_ids"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            primaryActionID: container.decode(ActionID.self, forKey: .primaryActionID),
            alternateActionIDs: container.decodeIfPresent(
                [ActionID].self,
                forKey: .alternateActionIDs
            ) ?? []
        )
    }
}

public struct MenuSlotConfiguration: Codable, Equatable, Hashable {
    public let item: MenuItemConfiguration?

    public static var empty: Self { Self(item: nil) }

    public static func occupied(_ item: MenuItemConfiguration) -> Self {
        Self(item: item)
    }

    public init(item: MenuItemConfiguration?) {
        self.item = item
    }
}

public struct MenuConfiguration: Codable, Equatable {
    public let slots: [MenuSlotConfiguration]

    public var items: [MenuItemConfiguration] {
        slots.compactMap(\.item)
    }

    public init(items: [MenuItemConfiguration]) throws {
        try self.init(slots: items.map(MenuSlotConfiguration.occupied))
    }

    public init(slots: [MenuSlotConfiguration]) throws {
        guard !slots.isEmpty, slots.count <= 12 else {
            throw ConfigurationError.invalidMenu("Menu must contain between 1 and 12 Slots")
        }
        var actionIDs = Set<ActionID>()
        for item in slots.compactMap(\.item) {
            for actionID in [item.primaryActionID] + item.alternateActionIDs {
                guard actionIDs.insert(actionID).inserted else {
                    throw ConfigurationError.invalidMenu("An Action is bound more than once")
                }
            }
        }
        self.slots = slots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let slots = try container.decodeIfPresent([MenuSlotConfiguration].self, forKey: .slots) {
            try self.init(slots: slots)
        } else {
            try self.init(items: container.decode([MenuItemConfiguration].self, forKey: .items))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
    }

    private enum CodingKeys: String, CodingKey {
        case slots
        case items
    }
}

public struct HostConfiguration: Codable, Equatable {
    public let actions: [ActionConfiguration]
    public let menu: MenuConfiguration

    public init(actions: [ActionConfiguration], menu: MenuConfiguration) throws {
        var actionIDs = Set<ActionID>()
        for action in actions {
            guard actionIDs.insert(action.id).inserted else {
                throw ConfigurationError.invalidAction("Duplicate Action ID \(action.id.rawValue)")
            }
        }
        for item in menu.slots.compactMap(\.item) {
            for actionID in [item.primaryActionID] + item.alternateActionIDs {
                guard actionIDs.contains(actionID) else {
                    throw ConfigurationError.invalidMenu("Menu Item references an unknown Action")
                }
            }
        }
        self.actions = actions
        self.menu = menu
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            actions: container.decode([ActionConfiguration].self, forKey: .actions),
            menu: container.decode(MenuConfiguration.self, forKey: .menu)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case actions
        case menu
    }
}

public protocol HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue
}

/// The Host-level Action seam used by the production Host and automated tests.
public struct HostActionRunner {
    private let executor: HostCommandExecutor
    private let scriptedExecutor: ScriptedActionExecutor?
    private let hostServiceBroker: PluginHostServiceBroker?

    public init(
        executor: HostCommandExecutor,
        scriptedExecutor: ScriptedActionExecutor? = nil,
        hostServiceBroker: PluginHostServiceBroker? = nil
    ) {
        self.executor = executor
        self.scriptedExecutor = scriptedExecutor
        self.hostServiceBroker = hostServiceBroker
    }

    public func invoke(_ action: ActionConfiguration) -> ActionOutcome {
        guard action.execution == .host else {
            return failure(
                for: action,
                category: .invalidConfiguration,
                message: "Action is not a Host Command"
            )
        }
        do {
            return ActionOutcome(
                actionID: action.id,
                pluginID: action.pluginID,
                title: action.title,
                terminal: .succeeded(try executor.execute(action))
            )
        } catch {
            return failure(
                for: action,
                category: .hostCommandFailed,
                message: error.localizedDescription
            )
        }
    }

    public func invoke(
        _ action: ActionConfiguration,
        using registry: PluginRegistry
    ) -> ActionOutcome {
        switch registry.availability(for: action) {
        case .available:
            guard action.execution == .javascript else {
                return invoke(action)
            }
            guard let scriptedExecutor,
                  let package = registry.package(for: action.pluginID) else {
                return failure(
                    for: action,
                    category: .helperUnavailable,
                    message: "No Plugin helper is configured"
                )
            }
            do {
                return ActionOutcome(
                    actionID: action.id,
                    pluginID: action.pluginID,
                    title: action.title,
                    terminal: .succeeded(try scriptedExecutor.execute(
                        action,
                        in: package,
                        using: hostServiceBroker
                    ))
                )
            } catch let error as PluginRuntimeError {
                return failure(
                    for: action,
                    category: error.failureCategory,
                    message: error.localizedDescription
                )
            } catch {
                return failure(
                    for: action,
                    category: .scriptedActionFailed,
                    message: error.localizedDescription
                )
            }
        case .unavailable(let reason):
            return failure(
                for: action,
                category: .commandUnavailable,
                message: reason.description
            )
        }
    }

    private func failure(
        for action: ActionConfiguration,
        category: ActionFailureCategory,
        message: String
    ) -> ActionOutcome {
        ActionOutcome(
            actionID: action.id,
            pluginID: action.pluginID,
            title: action.title,
            terminal: .failed(ActionFailure(
                pluginID: action.pluginID,
                actionID: action.id,
                category: category,
                message: message
            ))
        )
    }
}
