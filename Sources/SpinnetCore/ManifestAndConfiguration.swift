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

/// Declarative operations performed by the trusted Host on behalf of a
/// configured Action. The raw values are part of the public Plugin Interface.
public enum HostCommand: String, Codable, CaseIterable, Equatable, Hashable {
    case openURL = "url.open"
    case openApplication = "application.open"
    case openFile = "file.open"
    case openFolder = "folder.open"
    case invokeKeyboardShortcut = "keyboard_shortcut.invoke"
    case invokeService = "service.invoke"
    case invokeShortcut = "shortcut.invoke"
    case copyText = "clipboard.copy"
    case pasteText = "clipboard.paste"
    case cutText = "clipboard.cut"
    case presentFeedback = "feedback.present"
    /// Screenshots. The Host captures and then copies or saves as its
    /// Screenshot Plugin Settings say; the Action names only the source.
    case captureArea = "screen.capture_area"
    case captureFullScreen = "screen.capture_full_screen"
    case captureWindow = "screen.capture_window"

    /// A protected Host Command is still declarative, but it must pass through
    /// the same authority checks as an equivalent Host Service request.
    public var requiredCapability: PluginCapability? {
        switch self {
        case .copyText:
            return .writeClipboard
        case .captureArea, .captureFullScreen, .captureWindow:
            return .captureScreen
        default:
            return nil
        }
    }

    public var requiredSystemPermission: PluginSystemPermission? {
        switch self {
        case .invokeKeyboardShortcut, .pasteText, .cutText:
            return .accessibility
        case .captureArea, .captureFullScreen, .captureWindow:
            return .screenRecording
        default:
            return nil
        }
    }

    /// What a screenshot Host Command captures, or nil for any other.
    public var captureSource: ScreenCaptureSource? {
        switch self {
        case .captureArea: return .area
        case .captureFullScreen: return .fullScreen
        case .captureWindow: return .window
        default: return nil
        }
    }

    public var inputPlaceholder: String {
        switch self {
        case .openURL:
            return "https://example.com"
        case .openApplication:
            return "Application path or bundle identifier"
        case .openFile:
            return "File path"
        case .openFolder:
            return "Folder path"
        case .invokeKeyboardShortcut:
            return "{\"key\":\"P\",\"modifiers\":[\"command\",\"shift\"]}"
        case .invokeService:
            return "Exact title from the active app's Services menu"
        case .invokeShortcut:
            return "Shortcut name"
        case .copyText:
            return "Uses the current selected text"
        case .pasteText:
            return "Pastes the current clipboard into the focused app"
        case .cutText:
            return "Cuts the current selection in the focused app"
        case .presentFeedback:
            return "Feedback message"
        case .captureArea, .captureFullScreen, .captureWindow:
            return "Copies or saves as set in Screenshot Plugin Settings"
        }
    }

    /// The default editor metadata for a declarative Host Command. Plugin
    /// manifests may override this with `configuration_field` when a command
    /// needs a more specific presentation.
    public var configurationField: CommandConfigurationField? {
        switch self {
        case .openURL:
            return CommandConfigurationField(
                kind: .url,
                title: "URL",
                placeholder: inputPlaceholder
            )
        case .openApplication:
            return CommandConfigurationField(
                kind: .application,
                title: "Application",
                placeholder: inputPlaceholder
            )
        case .openFile:
            return CommandConfigurationField(
                kind: .file,
                title: "File",
                placeholder: inputPlaceholder
            )
        case .openFolder:
            return CommandConfigurationField(
                kind: .folder,
                title: "Folder",
                placeholder: inputPlaceholder
            )
        case .invokeKeyboardShortcut:
            return CommandConfigurationField(
                kind: .keyboardShortcut,
                title: "Keyboard Shortcut",
                placeholder: inputPlaceholder
            )
        case .invokeShortcut:
            return CommandConfigurationField(
                kind: .shortcut,
                title: "Shortcut",
                placeholder: inputPlaceholder
            )
        case .presentFeedback:
            return CommandConfigurationField(
                kind: .multilineText,
                title: "Feedback",
                placeholder: inputPlaceholder
            )
        case .invokeService:
            return CommandConfigurationField(
                kind: .text,
                title: "macOS Service",
                placeholder: inputPlaceholder
            )
        case .copyText, .pasteText, .cutText, .captureArea, .captureFullScreen, .captureWindow:
            return nil
        }
    }

    /// Returns the URL-shaped value used by URL Commands. The Host keeps the
    /// parser here so manifest default validation and execution share one
    /// definition of a valid external URL.
    public func resolvedURL(from input: JSONValue) -> URL? {
        guard self == .openURL,
              let value = stringValue(from: input, keys: ["url"]),
              let url = URL(string: value),
              url.scheme?.isEmpty == false else { return nil }
        return url
    }

    /// Validates the public JSON shape before a configured Action is admitted
    /// to a Ready-to-Use Preset. Resource existence and OS permissions remain
    /// runtime concerns and are reported as unavailable Host operations.
    public func isValidInput(_ input: JSONValue) -> Bool {
        switch self {
        case .openURL:
            return resolvedURL(from: input) != nil
        case .openApplication:
            return stringValue(
                from: input,
                keys: ["path", "bundle_id", "bundle_identifier", "bundleIdentifier"]
            ) != nil
        case .openFile, .openFolder:
            return stringValue(from: input, keys: ["path"]) != nil
        case .invokeKeyboardShortcut:
            return validKeyboardShortcutInput(input)
        case .invokeService:
            return validNamedInput(input, keys: ["name", "service"])
        case .invokeShortcut:
            return validNamedInput(input, keys: ["name", "shortcut"])
        case .copyText:
            // A null input means “copy the current selected text”. The
            // string/object forms remain accepted for backwards compatibility
            // with persisted Actions created before the Built-in Preset.
            return input == .null || containsStringValue(from: input, keys: ["text"])
        case .pasteText, .cutText, .captureArea, .captureFullScreen, .captureWindow:
            return input == .null
        case .presentFeedback:
            return stringValue(from: input, keys: ["message", "text"]) != nil
        }
    }

    private func validKeyboardShortcutInput(_ input: JSONValue) -> Bool {
        switch input {
        case .string(let value):
            return validKeyboardShortcutString(value)
        case .object(let values):
            if let modifiers = values["modifiers"] ?? values["modifier_flags"],
               !validKeyboardModifiers(modifiers) {
                return false
            }
            if let keyCode = values["key_code"], case .number(let value) = keyCode,
               value.isFinite, value.rounded() == value, (0...127).contains(value) {
                return true
            }
            guard let key = stringValue(from: input, keys: ["key", "character"]) else {
                return false
            }
            return validKeyboardKey(key)
        default:
            return false
        }
    }

    private func validKeyboardShortcutString(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var key = trimmed
        let symbols = ["⌘", "⇧", "⌥", "⌃"]
        for symbol in symbols {
            key = key.replacingOccurrences(of: symbol, with: "")
        }
        let parts = key.split(separator: "+", omittingEmptySubsequences: true)
        guard let keyPart = parts.last,
              validKeyboardKey(String(keyPart)) else {
            return false
        }
        return parts.dropLast().allSatisfy { validKeyboardModifier(String($0)) }
    }

    private func validKeyboardModifiers(_ input: JSONValue) -> Bool {
        switch input {
        case .number(let value):
            return UInt64(exactly: value) != nil
        case .string(let value):
            let parts = value.split(separator: "+", omittingEmptySubsequences: true)
            return !parts.isEmpty && parts.allSatisfy { validKeyboardModifier(String($0)) }
        case .array(let values):
            return values.allSatisfy { value in
                guard case .string(let modifier) = value else { return false }
                return validKeyboardModifier(modifier)
            }
        default:
            return false
        }
    }

    private func validKeyboardModifier(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd", "⌘", "shift", "⇧", "option", "opt", "alt", "⌥",
             "control", "ctrl", "⌃", "function", "fn", "caps_lock", "caps lock":
            return true
        default:
            return false
        }
    }

    private func validKeyboardKey(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return false }
        if key.count == 1,
           let scalar = key.unicodeScalars.first,
           ((65...90).contains(scalar.value) || (48...57).contains(scalar.value)) {
            return true
        }
        switch key {
        case "RETURN", "ENTER", "ESCAPE", "ESC", "TAB", "SPACE", "DELETE", "BACKSPACE",
             "LEFT", "RIGHT", "UP", "DOWN":
            return true
        default:
            return (1...20).contains { key == "F\($0)" }
        }
    }

    private func validNamedInput(_ input: JSONValue, keys: [String]) -> Bool {
        switch input {
        case .string:
            return stringValue(from: input, keys: keys) != nil
        case .object(let values):
            guard stringValue(from: input, keys: keys) != nil else { return false }
            guard let payload = values["input"] ?? values["text"] else { return true }
            if case .string = payload { return true }
            return false
        default:
            return false
        }
    }

    private func stringValue(from input: JSONValue, keys: [String]) -> String? {
        switch input {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : value
        case .object(let values):
            for key in keys {
                if case .string(let value) = values[key],
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
            return nil
        default:
            return nil
        }
    }

    private func containsStringValue(from input: JSONValue, keys: [String]) -> Bool {
        switch input {
        case .string:
            return true
        case .object(let values):
            return keys.contains { key in
                if case .string = values[key] { return true }
                return false
            }
        default:
            return false
        }
    }
}

public struct CommandDeclaration: Codable, Equatable, Hashable {
    public let id: CommandID
    public let title: String
    public let execution: CommandExecution
    public let isConfigurable: Bool
    public let hostCommand: HostCommand?
    public let script: String?
    public let configurationField: CommandConfigurationField?
    /// One sentence saying what the Command does, shown wherever the user
    /// chooses between Commands. It is written as `description` in a manifest.
    public let explanation: String?
    /// Several keyed Host-rendered fields, written as `configuration_fields`,
    /// for a Command whose input is an object of named values. A Command
    /// declares these or a single `configurationField`, not both.
    public let configurationFields: [CommandConfigurationField]

    public init(
        id: CommandID,
        title: String,
        execution: CommandExecution = .host,
        isConfigurable: Bool = true,
        hostCommand: HostCommand? = nil,
        script: String? = nil,
        configurationField: CommandConfigurationField? = nil,
        explanation: String? = nil,
        configurationFields: [CommandConfigurationField] = []
    ) {
        self.id = id
        self.title = title
        self.execution = execution
        self.isConfigurable = isConfigurable
        self.hostCommand = hostCommand
        self.script = script
        self.configurationField = configurationField
        self.explanation = explanation
        self.configurationFields = configurationFields
    }

    /// The manifest-facing script reference. `scriptPath` keeps call sites
    /// explicit about the value being relative to the Plugin package root.
    public var scriptPath: String? { script }

    public init(
        id: CommandID,
        title: String,
        execution: CommandExecution = .javascript,
        isConfigurable: Bool = true,
        scriptPath: String
    ) {
        self.init(
            id: id,
            title: title,
            execution: execution,
            isConfigurable: isConfigurable,
            script: scriptPath
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case execution
        case isConfigurable = "is_configurable"
        case hostCommand = "host_command"
        case script
        case scriptPath = "script_path"
        case javascript
        case configurationField = "configuration_field"
        case configuration
        case explanation = "description"
        case configurationFields = "configuration_fields"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let script = try container.decodeIfPresent(String.self, forKey: .script)
            ?? container.decodeIfPresent(String.self, forKey: .scriptPath)
            ?? container.decodeIfPresent(String.self, forKey: .javascript)
        let configurationField = try container.decodeIfPresent(
            CommandConfigurationField.self,
            forKey: .configurationField
        ) ?? container.decodeIfPresent(
            CommandConfigurationField.self,
            forKey: .configuration
        )
        self.init(
            id: try container.decode(CommandID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            execution: try container.decode(CommandExecution.self, forKey: .execution),
            isConfigurable: try container.decodeIfPresent(Bool.self, forKey: .isConfigurable) ?? true,
            hostCommand: try container.decodeIfPresent(HostCommand.self, forKey: .hostCommand),
            script: script,
            configurationField: configurationField,
            explanation: try container.decodeIfPresent(String.self, forKey: .explanation),
            configurationFields: try container.decodeIfPresent(
                [CommandConfigurationField].self,
                forKey: .configurationFields
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(execution, forKey: .execution)
        try container.encode(isConfigurable, forKey: .isConfigurable)
        try container.encodeIfPresent(hostCommand, forKey: .hostCommand)
        try container.encodeIfPresent(script, forKey: .script)
        try container.encodeIfPresent(configurationField, forKey: .configurationField)
        try container.encodeIfPresent(explanation, forKey: .explanation)
        if !configurationFields.isEmpty {
            try container.encode(configurationFields, forKey: .configurationFields)
        }
    }

    /// Configuration metadata may change without invalidating an existing
    /// executable Action. The Host still needs the other Command fields to
    /// match before it can run a persisted Action.
    public func matchesExecutableDefinition(_ other: CommandDeclaration) -> Bool {
        id == other.id
            && title == other.title
            && execution == other.execution
            && hostCommand == other.hostCommand
            && script == other.script
    }
}

public struct PluginManifest: Codable, Equatable {
    public static let supportedProtocolVersion = "1.0"

    public let protocolVersion: String
    public let id: PluginID
    public let name: String
    public let version: String
    public let capabilities: [PluginCapability]
    public let capabilityScopes: [PluginCapabilityScope]
    public let commands: [CommandDeclaration]
    public let preset: MenuItemPresetDeclaration
    /// Plugin Settings: fields shared by every Menu Item made from this
    /// Plugin, filled in from the Library. Written as `settings_fields`.
    public let settingsFields: [CommandConfigurationField]
    /// Starting values for `settingsFields`, written as `default_settings`.
    public let defaultSettings: [String: JSONValue]

    public init(
        protocolVersion: String = Self.supportedProtocolVersion,
        id: PluginID,
        name: String,
        version: String,
        capabilities: [PluginCapability] = [],
        capabilityScopes: [PluginCapabilityScope] = [],
        commands: [CommandDeclaration],
        preset: MenuItemPresetDeclaration = MenuItemPresetDeclaration(),
        settingsFields: [CommandConfigurationField] = [],
        defaultSettings: [String: JSONValue] = [:]
    ) throws {
        self.protocolVersion = protocolVersion
        self.id = id
        self.name = name
        self.version = version
        self.capabilities = capabilities
        self.capabilityScopes = capabilityScopes
        self.commands = commands
        self.preset = preset
        self.settingsFields = settingsFields
        self.defaultSettings = defaultSettings
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case id
        case name
        case version
        case capabilities
        case capabilityScopes = "capability_scopes"
        case commands
        case preset
        case settingsFields = "settings_fields"
        case defaultSettings = "default_settings"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(capabilityScopes, forKey: .capabilityScopes)
        try container.encode(commands, forKey: .commands)
        try container.encode(preset, forKey: .preset)
        if !settingsFields.isEmpty { try container.encode(settingsFields, forKey: .settingsFields) }
        if !defaultSettings.isEmpty { try container.encode(defaultSettings, forKey: .defaultSettings) }
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
        self.capabilityScopes = try container.decodeIfPresent([PluginCapabilityScope].self, forKey: .capabilityScopes) ?? []
        self.commands = try container.decode([CommandDeclaration].self, forKey: .commands)
        self.preset = try container.decodeIfPresent(
            MenuItemPresetDeclaration.self,
            forKey: .preset
        ) ?? MenuItemPresetDeclaration()
        self.settingsFields = try container.decodeIfPresent([CommandConfigurationField].self, forKey: .settingsFields) ?? []
        self.defaultSettings = try container.decodeIfPresent([String: JSONValue].self, forKey: .defaultSettings) ?? [:]
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
        guard Set(capabilityScopes.map(\.capability)).count == capabilityScopes.count else {
            throw ConfigurationError.invalidManifest("Duplicate Capability scope")
        }
        for scope in capabilityScopes {
            guard capabilities.contains(scope.capability), !scope.commandIDs.isEmpty,
                  Set(scope.commandIDs).count == scope.commandIDs.count,
                  scope.commandIDs.allSatisfy({ id in commands.contains { $0.id == id } }),
                  scope.httpsHosts.allSatisfy({ host in
                      guard let url = URL(string: "https://" + host) else { return false }
                      return !host.contains("*") && url.host == host && url.path.isEmpty && url.port == nil
                          && url.user == nil && url.query == nil && url.fragment == nil
                  }),
                  scope.externalApps.allSatisfy({ !$0.bundleID.isEmpty && !$0.operationFamilies.isEmpty }) else {
                throw ConfigurationError.invalidManifest("Invalid Capability scope")
            }
            if (scope.capability == .contactHTTPS && scope.httpsHosts.isEmpty)
                || (scope.capability == .controlExternalApp && scope.externalApps.isEmpty)
                || ([PluginCapability.readCurrentClipboard, .readClipboardHistory, .monitorClipboard].contains(scope.capability) && scope.dataTypes.isEmpty)
                || (scope.capability == .readClipboardHistory && !scope.includesExistingHostData) {
                throw ConfigurationError.invalidManifest("Capability scope must name all affected data and targets")
            }
            if [.readSelectedText, .writeClipboard].contains(scope.capability) &&
                (!scope.httpsHosts.isEmpty || !scope.externalApps.isEmpty || scope.includesExistingHostData ||
                 scope.dataTypes.contains(where: { $0 != "text" })) {
                throw ConfigurationError.invalidManifest("This Capability only supports current text data")
            }
            if scope.capability == .positionFocusedWindow &&
                (!scope.httpsHosts.isEmpty || !scope.externalApps.isEmpty || scope.includesExistingHostData ||
                 !scope.dataTypes.isEmpty) {
                throw ConfigurationError.invalidManifest("This Capability acts only on the focused window")
            }
            if scope.capability == .openURL &&
                (!scope.httpsHosts.isEmpty || !scope.externalApps.isEmpty || scope.includesExistingHostData ||
                 !scope.dataTypes.isEmpty) {
                throw ConfigurationError.invalidManifest("This Capability only opens links in the default browser")
            }
            if scope.capability == .captureScreen &&
                (!scope.httpsHosts.isEmpty || !scope.externalApps.isEmpty || scope.includesExistingHostData ||
                 !scope.dataTypes.isEmpty) {
                throw ConfigurationError.invalidManifest("This Capability only starts a Host-run screen capture")
            }
            // Only the user adds hosts beyond the declared ones.
            if !scope.consentedHTTPSHosts.isEmpty {
                throw ConfigurationError.invalidManifest("A manifest cannot declare user-consented hosts")
            }
            if scope.capability == .insertIntoFocusedApp &&
                (!scope.httpsHosts.isEmpty || !scope.externalApps.isEmpty || scope.includesExistingHostData ||
                 scope.dataTypes.contains(where: { $0 != "text" })) {
                throw ConfigurationError.invalidManifest("This Capability only inserts text into the focused App")
            }
        }
        for capability in capabilities where ![.readSelectedText, .writeClipboard, .positionFocusedWindow, .openURL, .captureScreen].contains(capability) {
            guard scope(for: capability) != nil else {
                throw ConfigurationError.invalidManifest("\(capability.title) requires a concrete Capability scope")
            }
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
            if let explanation = command.explanation {
                try validateText(explanation, name: "Command description")
            }
            try validate(command)
            try validateConfigurationField(command)
        }
        try validateSettings()

        let primaryCommandID = preset.defaultPrimaryCommandID ?? commands[0].id
        guard commandIDs.contains(primaryCommandID) else {
            throw ConfigurationError.invalidManifest("Preset Primary Command is not declared")
        }
        guard Set(preset.defaultAlternateCommandIDs).count == preset.defaultAlternateCommandIDs.count,
              !preset.defaultAlternateCommandIDs.contains(primaryCommandID),
              preset.defaultAlternateCommandIDs.allSatisfy(commandIDs.contains) else {
            throw ConfigurationError.invalidManifest("Preset Alternate Commands are invalid")
        }
        guard preset.defaultInputs.keys.allSatisfy({ commandID in
            guard let command = commands.first(where: { $0.id == commandID }) else {
                return false
            }
            return command.isConfigurable
        }) else {
            throw ConfigurationError.invalidManifest(
                "Preset input references an undeclared or non-configurable Command"
            )
        }
        if preset.readiness == .readyToUse {
            let defaultCommandIDs = [primaryCommandID] + preset.defaultAlternateCommandIDs
            for commandID in defaultCommandIDs {
                guard let command = commands.first(where: { $0.id == commandID }) else {
                    throw ConfigurationError.invalidManifest(
                        "Ready-to-Use Preset references an undeclared Command"
                    )
                }
                guard command.isConfigurable else { continue }
                guard let input = preset.defaultInputs[commandID],
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
            guard let hostCommand = command.hostCommand, command.script == nil else {
                throw ConfigurationError.invalidManifest(
                    "Host Command \(command.id.rawValue) must declare host_command only"
                )
            }
            if let requiredCapability = hostCommand.requiredCapability,
               !capabilities.contains(requiredCapability) {
                throw ConfigurationError.invalidManifest(
                    "Host Command \(command.id.rawValue) requires Capability \(requiredCapability.rawValue)"
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

    private func validateConfigurationField(_ command: CommandDeclaration) throws {
        if !command.configurationFields.isEmpty {
            guard command.isConfigurable, command.configurationField == nil else {
                throw ConfigurationError.invalidManifest(
                    "Command \(command.id.rawValue) must be configurable and declare either configuration_field or configuration_fields"
                )
            }
            var keys = Set<String>()
            for field in command.configurationFields {
                guard let key = field.key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      key.count <= 64, keys.insert(key).inserted,
                      CommandDeclaration.fieldSetKinds.contains(field.kind) else {
                    throw ConfigurationError.invalidManifest(
                        "Configuration fields of Command \(command.id.rawValue) need unique keys and single-value kinds"
                    )
                }
                try validateFieldMetadata(field)
            }
            for field in command.configurationFields {
                guard let condition = field.usedWhen else { continue }
                guard condition.key != field.key, !condition.values.isEmpty,
                      let governing = command.configurationFields.first(where: { $0.key == condition.key }),
                      governing.kind == .choice,
                      Set(condition.values).isSubset(of: governing.choices) else {
                    throw ConfigurationError.invalidManifest(
                        "used_when in Command \(command.id.rawValue) must name another choice field and some of its choices"
                    )
                }
            }
        }
        guard let field = command.configurationField else { return }
        guard field.kind != .orderedChoices else {
            throw ConfigurationError.invalidManifest("An ordered_choices field is only valid in settings_fields")
        }
        guard field.usedWhen == nil else {
            throw ConfigurationError.invalidManifest("used_when is only valid inside configuration_fields")
        }
        guard command.isConfigurable else {
            throw ConfigurationError.invalidManifest(
                "Non-configurable Command \(command.id.rawValue) cannot declare a Configuration field"
            )
        }
        guard !CommandDeclaration.fieldSetOnlyKinds.contains(field.kind) else {
            throw ConfigurationError.invalidManifest(
                "A \(field.kind.rawValue) field must be declared in configuration_fields"
            )
        }
        try validateFieldMetadata(field)
    }

    private func validateSettings() throws {
        var keys = Set<String>()
        for field in settingsFields {
            guard let key = field.key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  key.count <= 64, keys.insert(key).inserted,
                  CommandDeclaration.fieldSetKinds.contains(field.kind) || field.kind == .orderedChoices else {
                throw ConfigurationError.invalidManifest(
                    "Settings fields need unique keys and single-value or ordered_choices kinds"
                )
            }
            guard !(field.kind == .orderedChoices && field.overridable) else {
                throw ConfigurationError.invalidManifest("An ordered_choices setting cannot be overridable")
            }
            try validateFieldMetadata(field)
        }
        for field in settingsFields {
            guard let condition = field.usedWhen else { continue }
            guard condition.key != field.key, !condition.values.isEmpty,
                  let governing = settingsFields.first(where: { $0.key == condition.key }),
                  governing.kind == .choice || governing.kind == .orderedChoices,
                  Set(condition.values).isSubset(of: governing.choices) else {
                throw ConfigurationError.invalidManifest(
                    "used_when in settings_fields must name another choice or ordered_choices setting and some of its choices"
                )
            }
        }
        for command in commands {
            if command.configurationFields.contains(where: \.overridable) || command.configurationField?.overridable == true {
                throw ConfigurationError.invalidManifest("overridable is only valid inside settings_fields")
            }
            if command.configurationFields.contains(where: { $0.key.map(keys.contains) ?? false }) {
                throw ConfigurationError.invalidManifest(
                    "Command \(command.id.rawValue) declares a field that is also a Plugin setting"
                )
            }
        }
        for (key, value) in defaultSettings {
            guard let field = settingsFields.first(where: { $0.key == key }), field.acceptsMemberValue(value) else {
                throw ConfigurationError.invalidManifest("default_settings names an unknown setting or an invalid value for \(key)")
            }
        }
    }

    private func validateFieldMetadata(_ field: CommandConfigurationField) throws {
        if let title = field.title {
            try validateText(title, name: "Configuration field title")
        }
        if let placeholder = field.placeholder {
            guard placeholder.count <= 512 else {
                throw ConfigurationError.invalidManifest(
                    "Configuration field placeholder is too long"
                )
            }
        }
        let offersChoices = field.kind == .choice || field.kind == .orderedChoices
        guard offersChoices || field.choices.isEmpty else {
            throw ConfigurationError.invalidManifest(
                "Configuration field choices require the choice or ordered_choices kind"
            )
        }
        if offersChoices {
            guard !field.choices.isEmpty,
                  Set(field.choices).count == field.choices.count,
                  field.choices.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ConfigurationError.invalidManifest(
                    "Choice Configuration field must declare unique non-empty choices"
                )
            }
        }
    }

    private func validDefaultInput(_ input: JSONValue, for command: CommandDeclaration) -> Bool {
        switch command.execution {
        case .host:
            guard let hostCommand = command.hostCommand else { return false }
            return hostCommand.isValidInput(input)
        case .javascript:
            if let field = command.configurationField, !field.isValidInput(input) {
                return false
            }
            if !acceptsActionInput(input, for: command) {
                return false
            }
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

/// Where a package came from, which is what decides who may act on it. This
/// used to be spread across three independent flags, so combinations with no
/// meaning were representable, and questions with different answers — may an
/// install overwrite this, may the user remove it — collapsed into one.
public enum PluginOrigin: String, Equatable, Hashable, CaseIterable {
    /// A Host Command surfaced as its own Library entry. It has no package on
    /// disk, so there is nothing to replace or remove.
    case hostCommand
    /// A first-party Plugin package delivered inside the app bundle.
    case bundled
    /// A Plugin package the user installed into Application Support.
    case installed
}

public struct PluginPackage {
    /// The package directory on disk. A Host Command has none — it is Swift in
    /// the Host, not a package — and says so rather than naming a path that
    /// does not exist.
    public let rootURL: URL?
    public let manifest: PluginManifest
    /// Set only by the Host when it loads a package, never by a manifest.
    /// Defaults to the least privileged origin, so a caller that forgets to
    /// say where a package came from cannot accidentally widen what it may do.
    public let origin: PluginOrigin
    /// Compatibility packages can remain registered for persisted Actions
    /// without adding another user-facing Library entry.
    public let isVisibleInLibrary: Bool

    /// Only the user's own copies may be overwritten by an install.
    public var canBeReplacedByInstall: Bool { origin == .installed }

    /// A Host Command is part of the Host. Every Plugin, shipped or installed,
    /// is something the user may remove.
    public var canBeRemovedByUser: Bool { origin != .hostCommand }

    /// Asking the Host to present a window it owns outright is a Host-internal
    /// privilege (ADR 0002), not something a granted Capability buys.
    public var mayPresentHostWindows: Bool { origin != .installed }

    public var presetSource: MenuItemPresetSource {
        origin == .hostCommand ? .builtIn : .plugin
    }

    public init(
        rootURL: URL?,
        manifest: PluginManifest,
        origin: PluginOrigin = .installed,
        isVisibleInLibrary: Bool = true
    ) {
        self.rootURL = rootURL
        self.manifest = manifest
        self.origin = origin
        self.isVisibleInLibrary = isVisibleInLibrary
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
    public let isConfigurable: Bool
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
        self.isConfigurable = command.isConfigurable
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
            isConfigurable: isConfigurable,
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
        case isConfigurable
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
                    isConfigurable: container.decodeIfPresent(
                        Bool.self,
                        forKey: .isConfigurable
                    ) ?? true,
                    hostCommand: container.decodeIfPresent(HostCommand.self, forKey: .hostCommand),
                    script: container.decodeIfPresent(String.self, forKey: .script)
                ),
            input: container.decode(JSONValue.self, forKey: .input)
        )
    }
}

public struct MenuItemConfiguration: Codable, Equatable, Hashable {
    public let primaryActionID: ActionID
    /// A user-defined display name for this Menu Item. The alias belongs to
    /// the item rather than the Slot so moving the item preserves its name.
    public let alias: String?
    /// Alternate Actions currently exposed by the runtime context menu.
    public let alternateActionIDs: [ActionID]
    /// Alternate Actions retained by the editor but currently hidden from the
    /// runtime context menu. Keeping these IDs lets a user untick an Action,
    /// save, and re-enable it later without losing its parameters.
    public let disabledAlternateActionIDs: [ActionID]
    /// The stable editor order for both enabled and disabled Alternate
    /// Actions. Legacy configurations derive this from the enabled list.
    public let alternateActionOrder: [ActionID]

    public init(
        primaryActionID: ActionID,
        alternateActionIDs: [ActionID] = [],
        disabledAlternateActionIDs: [ActionID] = [],
        alternateActionOrder: [ActionID]? = nil,
        alias: String? = nil
    ) throws {
        guard !primaryActionID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidMenu("Primary Action ID is empty")
        }
        let allAlternateActionIDs = alternateActionIDs + disabledAlternateActionIDs
        guard allAlternateActionIDs.allSatisfy({
            !$0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ConfigurationError.invalidMenu("Alternate Action ID is empty")
        }
        guard Set(alternateActionIDs).count == alternateActionIDs.count else {
            throw ConfigurationError.invalidMenu("An Alternate Action is bound more than once")
        }
        guard Set(disabledAlternateActionIDs).count == disabledAlternateActionIDs.count else {
            throw ConfigurationError.invalidMenu("An Alternate Action is retained more than once")
        }
        guard Set(allAlternateActionIDs).count == allAlternateActionIDs.count else {
            throw ConfigurationError.invalidMenu("An Action cannot be both enabled and disabled")
        }
        guard !allAlternateActionIDs.contains(primaryActionID) else {
            throw ConfigurationError.invalidMenu(
                "An Action cannot be both Primary and Alternate"
            )
        }
        let resolvedAlternateActionOrder = alternateActionOrder ?? allAlternateActionIDs
        guard Set(resolvedAlternateActionOrder).count == resolvedAlternateActionOrder.count,
              Set(resolvedAlternateActionOrder) == Set(allAlternateActionIDs) else {
            throw ConfigurationError.invalidMenu("Alternate Action order does not match its Actions")
        }
        self.primaryActionID = primaryActionID
        self.alias = Self.normalizedAlias(alias)
        self.alternateActionIDs = alternateActionIDs
        self.disabledAlternateActionIDs = disabledAlternateActionIDs
        self.alternateActionOrder = resolvedAlternateActionOrder
    }

    private init(copying item: Self, alias: String?) {
        self.primaryActionID = item.primaryActionID
        self.alias = Self.normalizedAlias(alias)
        self.alternateActionIDs = item.alternateActionIDs
        self.disabledAlternateActionIDs = item.disabledAlternateActionIDs
        self.alternateActionOrder = item.alternateActionOrder
    }

    /// Returns the same Menu Item with a replaced or cleared display alias.
    /// The existing item has already passed validation, so changing only its
    /// presentation metadata does not need to repeat action-binding checks.
    public func withAlias(_ alias: String?) -> Self {
        Self(copying: self, alias: alias)
    }

    private static func normalizedAlias(_ alias: String?) -> String? {
        guard let alias else { return nil }
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAlias.isEmpty ? nil : trimmedAlias
    }

    /// All Alternate Action IDs in editor order, including Actions that are
    /// currently disabled in the runtime menu.
    public var allAlternateActionIDs: [ActionID] { alternateActionOrder }

    /// Every Action ID retained by this Menu Item, in Primary-then-Alternate
    /// order. This is useful for safely removing an item and its hidden state.
    public var boundActionIDs: [ActionID] { [primaryActionID] + alternateActionOrder }

    private enum CodingKeys: String, CodingKey {
        case primaryActionID = "primary_action_id"
        case alias
        case alternateActionIDs = "alternate_action_ids"
        case disabledAlternateActionIDs = "disabled_alternate_action_ids"
        case alternateActionOrder = "alternate_action_order"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alternateActionIDs = try container.decodeIfPresent(
            [ActionID].self,
            forKey: .alternateActionIDs
        ) ?? []
        let disabledAlternateActionIDs = try container.decodeIfPresent(
            [ActionID].self,
            forKey: .disabledAlternateActionIDs
        ) ?? []
        try self.init(
            primaryActionID: container.decode(ActionID.self, forKey: .primaryActionID),
            alternateActionIDs: alternateActionIDs,
            disabledAlternateActionIDs: disabledAlternateActionIDs,
            alternateActionOrder: container.decodeIfPresent(
                [ActionID].self,
                forKey: .alternateActionOrder
            ),
            alias: container.decodeIfPresent(String.self, forKey: .alias)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(primaryActionID, forKey: .primaryActionID)
        try container.encodeIfPresent(alias, forKey: .alias)
        try container.encode(alternateActionIDs, forKey: .alternateActionIDs)
        if !disabledAlternateActionIDs.isEmpty {
            try container.encode(disabledAlternateActionIDs, forKey: .disabledAlternateActionIDs)
        }
        if !alternateActionOrder.isEmpty {
            try container.encode(alternateActionOrder, forKey: .alternateActionOrder)
        }
    }
}

public struct MenuSlotConfiguration: Codable, Equatable, Hashable {
    public let item: MenuItemConfiguration?
    /// Compatibility accessor for callers that still read a Slot name. New
    /// code should read the alias from the Menu Item instead.
    @available(*, deprecated, message: "Read MenuItemConfiguration.alias instead")
    public var alias: String? { item?.alias }
    @available(*, deprecated, message: "Menu Item aliases are no longer stored on Slots")
    public var name: String? { item?.alias }

    public static var empty: Self { Self(item: nil) }

    public static func occupied(_ item: MenuItemConfiguration) -> Self {
        Self(item: item)
    }

    @available(*, deprecated, message: "Pass the alias to MenuItemConfiguration instead")
    public static func occupied(
        _ item: MenuItemConfiguration,
        name: String?
    ) -> Self {
        Self(item: item, legacyName: name)
    }

    public init(item: MenuItemConfiguration?) {
        self.item = item
    }

    @available(*, deprecated, message: "Pass the alias to MenuItemConfiguration instead")
    public init(item: MenuItemConfiguration?, name: String?) {
        self.init(item: item, legacyName: name)
    }

    private init(item: MenuItemConfiguration?, legacyName: String?) {
        guard let item, item.alias == nil, legacyName != nil else {
            self.item = item
            return
        }
        self.item = item.withAlias(legacyName)
    }

    private enum CodingKeys: String, CodingKey {
        case item
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let item = try container.decodeIfPresent(MenuItemConfiguration.self, forKey: .item)
        // Older configurations stored the alias on the Slot as `name`. Move
        // that value onto the decoded Menu Item exactly once at the boundary.
        let legacyName = try container.decodeIfPresent(String.self, forKey: .name)
        self.init(item: item, legacyName: legacyName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(item, forKey: .item)
    }
}

public struct MenuConfiguration: Codable, Equatable {
    public let slots: [MenuSlotConfiguration]

    public var items: [MenuItemConfiguration] {
        slots.compactMap(\.item)
    }

    public init(items: [MenuItemConfiguration]) throws {
        try self.init(slots: items.map { MenuSlotConfiguration.occupied($0) })
    }

    public init(slots: [MenuSlotConfiguration]) throws {
        guard !slots.isEmpty, slots.count <= 12 else {
            throw ConfigurationError.invalidMenu("Menu must contain between 1 and 12 Slots")
        }
        var actionIDs = Set<ActionID>()
        for item in slots.compactMap(\.item) {
            for actionID in item.boundActionIDs {
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
            for actionID in item.boundActionIDs {
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

/// Stable errors emitted by a Host Command adapter. The Action runner maps
/// these to the documented terminal categories while preserving the detailed
/// reason for protected diagnostics.
public enum HostCommandExecutionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidInput(String)
    case unavailable(String)
    case capabilityDenied(PluginCapability)
    case systemPermissionDenied(PluginSystemPermission)
    case failed(String)

    public var description: String {
        switch self {
        case .invalidInput(let message):
            return "Host Command input is invalid: \(message)"
        case .unavailable(let message):
            return "Host Command is unavailable: \(message)"
        case .capabilityDenied(let capability):
            return "Capability \(capability.rawValue) is not granted"
        case .systemPermissionDenied(let permission):
            return "System Permission \(permission.rawValue) is not granted"
        case .failed(let message):
            return "Host Command failed: \(message)"
        }
    }

    public var errorDescription: String? { description }

    public var actionFailureCategory: ActionFailureCategory {
        switch self {
        case .invalidInput:
            return .invalidConfiguration
        case .unavailable:
            return .commandUnavailable
        case .capabilityDenied:
            return .capabilityDenied
        case .systemPermissionDenied:
            return .systemPermissionDenied
        case .failed:
            return .hostCommandFailed
        }
    }
}

public protocol HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue
}

/// Optional context-aware extension for Host executors that enforce a
/// Command's declared Capability and System Permission against its package.
/// Keeping this separate preserves source compatibility for lightweight test
/// executors and third-party adapters that only need the Action seam.
public protocol ContextualHostCommandExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue
}

/// The Host-level Action seam used by the production Host and automated tests.
public struct HostActionRunner {
    private let executor: HostCommandExecutor
    private let scriptedExecutor: ScriptedActionExecutor?
    private let hostServiceBroker: PluginHostServiceBroker?
    private let resourceAvailability: ((ActionConfiguration) -> ActionUnavailableReason?)?
    private let pluginSettings: ((PluginManifest) -> [String: JSONValue])?

    /// `pluginSettings` gives a Plugin's resolved Plugin Settings; a scripted
    /// Action runs with them combined into its input.
    public init(
        executor: HostCommandExecutor,
        scriptedExecutor: ScriptedActionExecutor? = nil,
        hostServiceBroker: PluginHostServiceBroker? = nil,
        resourceAvailability: ((ActionConfiguration) -> ActionUnavailableReason?)? = nil,
        pluginSettings: ((PluginManifest) -> [String: JSONValue])? = nil
    ) {
        self.executor = executor
        self.scriptedExecutor = scriptedExecutor
        self.hostServiceBroker = hostServiceBroker
        self.resourceAvailability = resourceAvailability
        self.pluginSettings = pluginSettings
    }

    public func invoke(_ action: ActionConfiguration) -> ActionOutcome {
        guard action.execution == .host else {
            return failure(
                for: action,
                category: .invalidConfiguration,
                message: "Action is not a Host Command"
            )
        }
        return invokeHost(action) {
            try self.executor.execute(action)
        }
    }

    public func invoke(
        _ action: ActionConfiguration,
        using registry: PluginRegistry,
        control: ActionExecutionControl = ActionExecutionControl()
    ) -> ActionOutcome {
        switch registry.availability(
            for: action,
            resourceAvailability: resourceAvailability
        ) {
        case .available:
            guard action.execution == .javascript else {
                guard let package = registry.package(for: action.pluginID),
                      let contextualExecutor = executor as? ContextualHostCommandExecutor else {
                    return invoke(action)
                }
                return invokeHost(action) {
                    try contextualExecutor.execute(action, in: package)
                }
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
                // The script, and every Host Service it asks for, sees the
                // Plugin Settings with this Menu Item's overrides applied.
                let manifest = package.manifest
                let action = try manifest.commands.first(where: { $0.id == action.commandID }).map { command in
                    try action.withInput(manifest.effectiveInput(
                        for: command, actionInput: action.input, settings: pluginSettings?(manifest) ?? [:]
                    ))
                } ?? action
                return ActionOutcome(
                    actionID: action.id,
                    pluginID: action.pluginID,
                    title: action.title,
                    terminal: .succeeded(try scriptedExecutor.execute(
                        action,
                        in: package,
                        using: hostServiceBroker,
                        control: control
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

    private func invokeHost(
        _ action: ActionConfiguration,
        execute: () throws -> JSONValue
    ) -> ActionOutcome {
        do {
            return ActionOutcome(
                actionID: action.id,
                pluginID: action.pluginID,
                title: action.title,
                terminal: .succeeded(try execute())
            )
        } catch let error as HostCommandExecutionError {
            return failure(
                for: action,
                category: error.actionFailureCategory,
                message: error.localizedDescription
            )
        } catch let error as PluginHostServiceError {
            return failure(
                for: action,
                category: error.actionFailureCategory,
                message: error.localizedDescription
            )
        } catch {
            return failure(
                for: action,
                category: .hostCommandFailed,
                message: error.localizedDescription
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
