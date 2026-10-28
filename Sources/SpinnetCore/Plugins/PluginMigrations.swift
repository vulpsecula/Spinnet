import Foundation

/// A manifest's `migrations` block: how the data an earlier version of the
/// Plugin left behind maps onto this one. It may rename Commands, rename
/// settings keys, and drop the input of Actions whose Command takes none, and
/// nothing else, so a migration can never grant a Capability. The Host applies
/// it whenever it registers or updates the Plugin; every step leaves data it
/// already moved as it is, so applying it again changes nothing.
public struct PluginMigrations: Codable, Equatable, Sendable {
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
        var changed = false
        let actions = try configuration.actions.map { action -> ActionConfiguration in
            guard action.pluginID == id else { return action }
            let commandID = migrations.renamedCommands[action.commandID] ?? action.commandID
            let input = migrations.droppedInputs.contains(commandID) ? .null : action.input
            guard let command = commands.first(where: { $0.id == commandID }) else { return action }
            guard commandID != action.commandID || input != action.input
                    || command.preservesHistoricalExecution(of: action) else { return action }
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


private extension CommandDeclaration {
    /// The first current interface replaced saved internal adapter names with
    /// catalogue IDs. Rebind only when the ID, title, executable kind and
    /// target are unchanged and both routes produce exactly the same input.
    /// Unknown or changed definitions remain unavailable for explicit repair.
    func preservesHistoricalExecution(of action: ActionConfiguration) -> Bool {
        guard execution == .host, action.execution == .host,
              id == action.commandID, title == action.title,
              script == action.script, deepLinkTemplate == action.deepLinkTemplate,
              hostCommand == nil, let adapter = action.hostCommand,
              let serviceID = hostServiceID,
              HostServiceCatalogue.ids(replacing: adapter).contains(serviceID),
              let operation = HostServiceCatalogue.operation(serviceID),
              operation.isOffered(at: .command), adapter.isValidInput(action.input) else { return false }

        // A Deep Link keeps its declared template and parameter object. Fixed
        // input was absent from saved adapter Commands, so cannot be invented.
        if adapter == .openDeepLink {
            return serviceID == HostServiceCatalogue.deepLinkOperation
                && (fixedInput == nil || fixedInput == .object([:]))
        }
        let input = operation.commandInput(for: self, actionInput: action.input)
        let preservedDirectory: Bool?
        if adapter == .openFile || adapter == .openFolder {
            // A generic open.path can open either kind. Do not broaden an
            // unavailable historical file Action into a directory Action (or
            // vice versa) merely by forcing the old adapter into commandStep.
            let kind = configurationField?.kind
                ?? configurationFields.first(where: { $0.key == "path" })?.kind
            if kind == .file || kind == .folder {
                guard (kind == .folder) == (adapter == .openFolder) else { return false }
                // Current resource validation preserves this explicit kind,
                // including refusal while the target is missing or wrong-kind.
                preservedDirectory = kind == .folder
            } else {
                guard case .string(let path) = input else { return false }
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue == (adapter == .openFolder) else { return false }
                preservedDirectory = isDirectory.boolValue
            }
        } else {
            preservedDirectory = nil
        }
        guard let step = try? operation.commandStep(input: input, isDirectory: { _ in preservedDirectory ?? false }) else {
            return false
        }
        func text(_ keys: [String]) -> JSONValue? {
            if case .string = action.input { return action.input }
            if case .object(let values) = action.input {
                for key in keys { if case .string? = values[key] { return values[key] } }
            }
            return nil
        }
        let expected: HostServiceCommandStep
        switch adapter {
        case .copyText:
            if action.input == .null { expected = .hostCommand(.copyText, .null) }
            else if let text = text(["text"]) { expected = .hostCommand(.copyText, text) }
            else { return false }
        case .openURL:
            guard let text = text(["url"]) else { return false }
            expected = .hostCommand(adapter, text)
        case .openFile, .openFolder:
            guard let text = text(["path"]) else { return false }
            expected = .hostCommand(adapter, text)
        case .openApplication:
            guard let text = text(["path", "bundle_id", "bundle_identifier", "bundleIdentifier"]) else { return false }
            expected = .hostCommand(adapter, text)
        case .presentFeedback:
            guard case .string(let message)? = text(["message", "text"]) else { return false }
            expected = .toast(message)
        case .captureArea, .captureFullScreen, .captureWindow, .cutText, .pasteText:
            guard action.input == .null else { return false }
            expected = .hostCommand(adapter, .null)
        case .invokeKeyboardShortcut, .invokeService, .invokeShortcut:
            expected = .hostCommand(adapter, action.input)
        case .openDeepLink: return false // handled above
        }
        return step == expected
    }
}
