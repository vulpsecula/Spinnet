import Foundation
import SpinnetCore

/// Translator 2 shows every translation in a Host popup instead of copying
/// or inserting one. Translate Selection and Copy becomes Translate
/// Selection; Translate Selection in Place has no counterpart and becomes
/// Translate Input, so a Menu Item made from the old default Preset becomes
/// the new default one. Actions keep their IDs and overrides, so every Slot,
/// alias and Alternate Action stays as the user arranged it.
enum TranslatorCommandMigration {
    static let pluginID = PluginID("com.spinnet.translator")

    private static let replacements: [CommandID: CommandID] = [
        CommandID("translator.copy"): CommandID("translator.selection"),
        CommandID("translator.replace"): CommandID("translator.input")
    ]

    /// The configuration with the retired Commands' Actions moved, or nil when
    /// there are none, or when the Translator is not registered and so has no
    /// Command to move them to.
    static func migrate(_ configuration: HostConfiguration, manifest: PluginManifest?) throws -> HostConfiguration? {
        guard let manifest, manifest.id == pluginID else { return nil }
        var changed = false
        let actions = try configuration.actions.map { action -> ActionConfiguration in
            guard action.pluginID == pluginID else { return action }
            let replacement = replacements[action.commandID] ?? action.commandID
            guard let command = manifest.commands.first(where: { $0.id == replacement }) else { return action }
            // Nothing is configured on a Menu Item any more, so an Action that
            // still carries a target language or formality of its own drops it
            // and follows Plugin Settings like every other one.
            let input: JSONValue = command.isConfigurable ? action.input : .null
            guard replacement != action.commandID || input != action.input else { return action }
            changed = true
            return try ActionConfiguration(id: action.id, pluginID: pluginID, command: command, input: input)
        }
        return changed ? try HostConfiguration(actions: actions, menu: configuration.menu) : nil
    }

    private static let renamedSettings = ["endpoint": "deepl_endpoint", "credential": "deepl_credential"]

    /// Version 1 kept DeepL's endpoint and key reference as `endpoint` and
    /// `credential`. The stored settings with those under their new keys, or
    /// nil when there is nothing to move. A value saved under a new key wins.
    static func migrateSettings(_ stored: [String: JSONValue]) -> [String: JSONValue]? {
        guard renamedSettings.keys.contains(where: { stored[$0] != nil }) else { return nil }
        var settings = stored
        for (old, new) in renamedSettings {
            guard let value = settings.removeValue(forKey: old) else { continue }
            if settings[new] == nil { settings[new] = value }
        }
        return settings
    }
}
