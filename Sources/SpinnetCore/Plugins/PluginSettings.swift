import Foundation

/// Plugin Settings: configuration a Plugin shares across the Menu Items made
/// from its Preset, declared as `settings_fields` and filled in from the
/// Library before anything is placed. The script sees one input: the
/// settings, then the Menu Item's own value for any `overridable` setting,
/// then the Command's own fields.
public extension PluginManifest {
    var hasSettings: Bool { !settingsFields.isEmpty }

    /// The settings the Host uses: the defaults, replaced by each stored value
    /// that is still a valid value of a declared field. Anything else stored,
    /// such as a value from an older version, is ignored.
    func resolvedSettings(stored: [String: JSONValue]) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for field in settingsFields {
            guard let key = field.key else { continue }
            if let value = stored[key], field.acceptsMemberValue(value) {
                values[key] = value
            } else if let value = defaultSettings[key] {
                values[key] = value
            }
        }
        return values
    }

    /// `stored` with each `list` setting saved as text, as settings were
    /// before that kind held them, rewritten as its rows. Text that is not a
    /// valid list is left for `resolvedSettings` to ignore. Nil when nothing
    /// is stored as text, so applying it again changes nothing.
    func listSettingsAsRows(_ stored: [String: JSONValue]) -> [String: JSONValue]? {
        var settings = stored
        for field in settingsFields where field.kind == .list {
            guard let key = field.key, case .string(let text)? = stored[key],
                  let rows = field.listRows(fromText: text) else { continue }
            settings[key] = rows
        }
        return settings == stored ? nil : settings
    }

    /// Settings fields the current values use that have no usable value:
    /// absent, blank text, no choice in an `ordered_choices`, no row in a
    /// `list`, or a credential whose secret is not stored. A field whose `used_when` is
    /// not met is never missing. Until none are, the Plugin's Menu Items are
    /// unavailable.
    func missingSettings(in values: [String: JSONValue], hasSecret: (String) -> Bool) -> [CommandConfigurationField] {
        settingsFields.filter { field in
            guard field.isUsed(by: values) else { return false }
            guard let key = field.key, let value = values[key], field.acceptsMemberValue(value) else { return true }
            switch (field.kind, value) {
            case (.credential, .string(let reference)): return !hasSecret(reference)
            case (_, .string(let text)): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case (_, .array(let items)): return items.isEmpty
            default: return false
            }
        }
    }

    /// The settings a Menu Item may override.
    var overridableSettingsFields: [CommandConfigurationField] { settingsFields.filter(\.overridable) }

    /// Whether an Action of `command` may hold `input`: the Command's own
    /// fields, plus a value for any overridable setting. A Plugin without
    /// settings keeps the Command's own rule.
    func acceptsActionInput(_ input: JSONValue, for command: CommandDeclaration) -> Bool {
        guard hasSettings else { return command.acceptsConfigurationFieldsInput(input) }
        var members: [String: JSONValue]
        switch input {
        case .object(let values): members = values
        case .null: members = [:]
        default: return false
        }
        for field in overridableSettingsFields {
            guard let key = field.key, let value = members.removeValue(forKey: key) else { continue }
            guard field.acceptsMemberValue(value) else { return false }
        }
        if command.configurationFields.isEmpty {
            return members.isEmpty
        }
        return command.acceptsConfigurationFieldsInput(.object(members))
    }

    /// What the script receives for an Action of `command`.
    func effectiveInput(for command: CommandDeclaration, actionInput: JSONValue, settings: [String: JSONValue]) -> JSONValue {
        guard hasSettings else { return actionInput }
        var combined = settings
        if case .object(let members) = actionInput {
            let settingKeys = Set(settingsFields.compactMap(\.key))
            let overridable = Set(overridableSettingsFields.compactMap(\.key))
            for (key, value) in members where !settingKeys.contains(key) || overridable.contains(key) {
                combined[key] = value
            }
        }
        return .object(combined)
    }
}

public extension HTTPSEndpointConsent {
    /// The consent Plugin Settings need before they save: an endpoint setting
    /// reaches every Command, so it counts once any Command contacts the
    /// network.
    init(manifest: PluginManifest, settings: [String: JSONValue], grantStore: PluginCapabilityGrantStore) {
        let inputs = Dictionary(uniqueKeysWithValues: manifest.commands.map {
            ($0.id, manifest.effectiveInput(for: $0, actionInput: .object([:]), settings: settings))
        })
        self.init(manifest: manifest, inputs: inputs, grantStore: grantStore)
    }
}

/// Where the Host keeps each Plugin's settings: one JSON file, by Plugin ID.
/// Secrets are not here; a credential setting holds only its reference.
public final class PluginSettingsStore {
    public let fileURL: URL
    private var values: [String: [String: JSONValue]]
    private let lock = NSLock()

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                values = try JSONDecoder().decode([String: [String: JSONValue]].self, from: Data(contentsOf: fileURL))
            } catch {
                throw ConfigurationError.persistence("Plugin Settings could not be read: \(error.localizedDescription)")
            }
        } else {
            values = [:]
        }
    }

    public func values(for pluginID: PluginID) -> [String: JSONValue] {
        lock.withLock { values[pluginID.rawValue] ?? [:] }
    }

    /// Whether the user, or a migration, ever saved settings for the Plugin.
    public func hasValues(for pluginID: PluginID) -> Bool {
        lock.withLock { values[pluginID.rawValue] != nil }
    }

    public func setValues(_ newValues: [String: JSONValue], for pluginID: PluginID) throws {
        try lock.withLock {
            var updated = values
            updated[pluginID.rawValue] = newValues
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(updated).write(to: fileURL, options: .atomic)
            } catch {
                throw ConfigurationError.persistence("Plugin Settings could not be saved: \(error.localizedDescription)")
            }
            values = updated
        }
    }
}

/// Moves Actions that carried every value themselves, from before their
/// Plugin declared settings, onto Plugin Settings. The first Menu Item's
/// Primary Action seeds the settings when none are stored. Every Action then
/// keeps its own fields, plus an overridable value where it differs from the
/// settings, so each Menu Item behaves as it did.
public enum PluginSettingsMigration {
    public struct Result {
        /// Settings to store, or nil when the stored ones stand.
        public let settings: [String: JSONValue]?
        public let configuration: HostConfiguration
    }

    /// Nil when there is nothing to move.
    public static func migrate(
        _ configuration: HostConfiguration,
        manifest: PluginManifest,
        storedSettings: [String: JSONValue]?
    ) throws -> Result? {
        guard manifest.hasSettings else { return nil }
        let settingKeys = Set(manifest.settingsFields.compactMap(\.key))
        let overridable = Set(manifest.overridableSettingsFields.compactMap(\.key))
        func settingMembers(_ action: ActionConfiguration) -> [String: JSONValue] {
            guard case .object(let members) = action.input else { return [:] }
            return members.filter { settingKeys.contains($0.key) }
        }

        let owned = configuration.actions.filter { $0.pluginID == manifest.id }
        var seeded: [String: JSONValue]?
        if storedSettings == nil {
            let byID = Dictionary(uniqueKeysWithValues: owned.map { ($0.id, $0) })
            let primary = configuration.menu.items.lazy.compactMap { byID[$0.primaryActionID] }.first ?? owned.first
            if let primary, !settingMembers(primary).isEmpty {
                seeded = manifest.resolvedSettings(stored: settingMembers(primary))
            }
        }
        let settings = seeded ?? manifest.resolvedSettings(stored: storedSettings ?? [:])

        var changed = false
        let actions = try configuration.actions.map { action -> ActionConfiguration in
            guard action.pluginID == manifest.id, case .object(let members) = action.input else { return action }
            let kept = members.filter { key, value in
                !settingKeys.contains(key) || (overridable.contains(key) && settings[key] != value)
            }
            guard kept != members else { return action }
            changed = true
            return try ActionConfiguration(id: action.id, pluginID: action.pluginID, command: action.declaredCommand,
                                           input: .object(kept))
        }
        guard changed || seeded != nil else { return nil }
        return Result(settings: seeded, configuration: try HostConfiguration(actions: actions, menu: configuration.menu))
    }
}

public extension ActionConfiguration {
    /// The same Action with a different input, such as its Plugin Settings
    /// combined in for one run.
    func withInput(_ input: JSONValue) throws -> ActionConfiguration {
        try ActionConfiguration(id: id, pluginID: pluginID, command: declaredCommand, input: input)
    }
}
