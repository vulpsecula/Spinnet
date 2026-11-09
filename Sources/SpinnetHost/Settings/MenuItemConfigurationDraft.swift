import Carbon
import Foundation
import SpinnetCore

/// One Menu Item's Menu Item Configuration as its Configuration Sheet edits
/// it, until the sheet saves or cancels: which Plugin is edited, its Primary
/// and Alternate Actions, their inputs, the Menu Item Alias and the user's
/// own Menu Item Icon. Saving produces the Host configuration with the Menu
/// Item configured; typed credentials and endpoint consent travel beside it
/// in a `MenuItemSaveDraft`.
final class MenuItemConfigurationDraft: ObservableObject {
    private let editor: HostConfigurationEditor
    private let plugins: InstalledPlugins
    /// The App whose Menu Item is edited, or nil for the default Menu.
    let app: AppBundleIdentifier?
    let slotIndex: Int
    /// The edited Plugin: the Preset's when one is being placed, else the
    /// Plugin of the Menu Item's Primary Action. Nil when that Plugin is not
    /// loaded, so the Actions cannot be changed.
    let pluginID: PluginID?
    let manifest: PluginManifest?

    @Published var alias: String
    /// The user's own Menu Item Icon, a system symbol name, or nil for the
    /// default the Menu Item shows without it.
    @Published var ownIcon: String?
    /// The Command of the Primary Action. Choosing another makes the former
    /// Primary Action's Command an Alternate Action, last and off.
    @Published var primaryCommandID: CommandID {
        didSet { primaryCommandDidChange(from: oldValue) }
    }
    /// Every Command other than the Primary Action's, in the order the
    /// Menu Item exposes them.
    @Published private(set) var alternateCommandOrder: [CommandID]
    @Published private var enabledAlternateCommandIDs: Set<CommandID>
    /// Each Command's input as the sheet shows it, by Command.
    @Published private var inputTexts: [CommandID: String]
    private let originalInputValues: [CommandID: JSONValue]
    /// What the Menu Item shows without the user's icon while the edited
    /// Plugin is not loaded.
    private let savedDefaultIcon: MenuItemIcon

    /// The Menu Item `app` sees at `slotIndex`, nil for the default Menu.
    /// `presetPluginID` names the Plugin of a Preset being placed there,
    /// into an empty Slot or replacing its Menu Item.
    init(editor: HostConfigurationEditor, app: AppBundleIdentifier? = nil, slotIndex: Int,
         presetPluginID: PluginID? = nil) {
        self.editor = editor
        self.app = app
        self.slotIndex = slotIndex
        let plugins = editor.installedPlugins
        self.plugins = plugins
        let configuration = editor.configuration
        let slots = configuration.menu.slots(for: app)
        let item = slots.indices.contains(slotIndex) ? slots[slotIndex].item : nil
        let actions = Dictionary(uniqueKeysWithValues: configuration.actions.map { ($0.id, $0) })
        let primaryAction = item.flatMap { actions[$0.primaryActionID] }

        alias = item?.alias ?? ""
        ownIcon = item?.icon
        savedDefaultIcon = MenuItemIcon.resolve(
            of: primaryAction, in: plugins,
            availability: primaryAction.map(plugins.availability(of:)) ?? .unavailable(.commandMissing)
        )

        let editedPluginID = slots.indices.contains(slotIndex) ? presetPluginID ?? primaryAction?.pluginID : nil
        guard let editedPluginID, let manifest = plugins.manifest(editedPluginID), !manifest.commands.isEmpty else {
            pluginID = nil
            manifest = nil
            primaryCommandID = CommandID("missing")
            alternateCommandOrder = []
            enabledAlternateCommandIDs = []
            inputTexts = [:]
            originalInputValues = [:]
            return
        }
        pluginID = editedPluginID
        self.manifest = manifest
        let commands = manifest.commands

        let primaryCommandID: CommandID
        if let primaryAction, primaryAction.pluginID == editedPluginID,
           commands.contains(where: { $0.id == primaryAction.commandID }) {
            primaryCommandID = primaryAction.commandID
        } else {
            primaryCommandID = manifest.preset.defaultPrimaryCommandID ?? commands[0].id
        }
        self.primaryCommandID = primaryCommandID

        // The Menu Item's own Actions of the edited Plugin, in its order.
        let boundActions = (item?.boundActionIDs ?? []).compactMap { actions[$0] }
            .filter { $0.pluginID == editedPluginID }
        var order: [CommandID] = []
        for action in boundActions where action.commandID != primaryCommandID
            && commands.contains(where: { $0.id == action.commandID }) && !order.contains(action.commandID) {
            order.append(action.commandID)
        }
        for command in commands where command.id != primaryCommandID && !order.contains(command.id) {
            order.append(command.id)
        }
        alternateCommandOrder = order

        if let item {
            let enabledActionIDs = Set(item.alternateActionIDs)
            enabledAlternateCommandIDs = Set(boundActions.filter {
                $0.commandID != primaryCommandID && enabledActionIDs.contains($0.id) && order.contains($0.commandID)
            }.map(\.commandID))
        } else {
            enabledAlternateCommandIDs = Set(manifest.preset.defaultAlternateCommandIDs.filter {
                $0 != primaryCommandID && order.contains($0)
            })
        }

        var inputTexts: [CommandID: String] = [:]
        var originalInputValues: [CommandID: JSONValue] = [:]
        for command in commands {
            let input = boundActions.first { $0.commandID == command.id }?.input
                ?? manifest.preset.defaultInputs[command.id]
            guard let input else { continue }
            inputTexts[command.id] = ConfigurationInputValueResolver.presentationValue(
                for: input, field: Self.field(of: command), hostCommand: command.hostCommand
            )
            originalInputValues[command.id] = input
        }
        self.inputTexts = inputTexts
        self.originalInputValues = originalInputValues
    }

    // MARK: Actions

    /// The edited Plugin's Commands, which the Primary Action is chosen from.
    var commands: [CommandDeclaration] { manifest?.commands ?? [] }

    func command(_ commandID: CommandID) -> CommandDeclaration? {
        manifest?.command(commandID)
    }

    /// The Commands offered as Alternate Actions, in their order.
    var alternateCommands: [CommandDeclaration] {
        alternateCommandOrder.compactMap(command)
    }

    /// The Primary Action's Command, then each Alternate Action's that is on.
    var selectedCommands: [CommandDeclaration] {
        guard let primary = command(primaryCommandID) else { return [] }
        return [primary] + alternateCommandOrder.compactMap { commandID in
            enabledAlternateCommandIDs.contains(commandID) ? command(commandID) : nil
        }
    }

    /// The selected Commands that take an input.
    var configurableCommands: [CommandDeclaration] {
        selectedCommands.filter(\.isConfigurable)
    }

    func isAlternateEnabled(_ commandID: CommandID) -> Bool {
        enabledAlternateCommandIDs.contains(commandID)
    }

    func setAlternate(_ commandID: CommandID, enabled: Bool) {
        if enabled, alternateCommandOrder.contains(commandID) {
            enabledAlternateCommandIDs.insert(commandID)
        } else {
            enabledAlternateCommandIDs.remove(commandID)
        }
    }

    func canMoveAlternate(_ commandID: CommandID, by offset: Int) -> Bool {
        guard let index = alternateCommandOrder.firstIndex(of: commandID) else { return false }
        return alternateCommandOrder.indices.contains(index + offset)
    }

    func moveAlternate(_ commandID: CommandID, by offset: Int) {
        guard canMoveAlternate(commandID, by: offset),
              let index = alternateCommandOrder.firstIndex(of: commandID) else { return }
        alternateCommandOrder.swapAt(index, index + offset)
    }

    private func primaryCommandDidChange(from previous: CommandID) {
        enabledAlternateCommandIDs.remove(primaryCommandID)
        alternateCommandOrder.removeAll { $0 == primaryCommandID }
        if previous != primaryCommandID, command(previous) != nil, !alternateCommandOrder.contains(previous) {
            alternateCommandOrder.append(previous)
        }
    }

    // MARK: Inputs

    /// The input of `commandID` as the sheet shows it.
    func inputText(for commandID: CommandID) -> String {
        inputTexts[commandID] ?? ""
    }

    func setInputText(_ text: String, for commandID: CommandID) {
        inputTexts[commandID] = text
    }

    /// The input `commandID`'s Action would be saved with: the shown text
    /// in the shape its Command accepts, keeping members of the original
    /// input the text does not show.
    func inputValue(for commandID: CommandID) -> JSONValue {
        let command = command(commandID)
        return ConfigurationInputValueResolver.resolve(
            text: inputText(for: commandID),
            field: command.flatMap(Self.field(of:)),
            hostCommand: command?.hostCommand,
            original: originalInputValues[commandID]
        )
    }

    /// The configurable selected Commands' inputs, which are saved.
    var inputs: [CommandID: JSONValue] {
        Dictionary(uniqueKeysWithValues: configurableCommands.map { ($0.id, inputValue(for: $0.id)) })
    }

    /// Every selected Command's input, for the access it would need.
    var selectedInputs: [CommandID: JSONValue] {
        Dictionary(uniqueKeysWithValues: selectedCommands.map { ($0.id, inputValue(for: $0.id)) })
    }

    /// A toggle input: on when it is true, "true", or an object whose
    /// `enabled`, `value` or `checked` member is true.
    func isOn(_ commandID: CommandID) -> Bool {
        switch inputValue(for: commandID) {
        case .bool(let value): return value
        case .string(let value): return value.lowercased() == "true"
        case .object(let values):
            for key in ["enabled", "value", "checked"] {
                if case .bool(let value) = values[key] { return value }
            }
            return false
        default: return false
        }
    }

    func setOn(_ isOn: Bool, for commandID: CommandID) {
        inputTexts[commandID] = isOn ? "true" : "false"
    }

    /// A keyboard shortcut input, nil when it holds none.
    func keyboardShortcut(for commandID: CommandID) -> MenuKeyboardShortcut? {
        guard case .object(let values) = inputValue(for: commandID),
              case .number(let rawKeyCode) = values["key_code"],
              rawKeyCode.isFinite, rawKeyCode.rounded() == rawKeyCode, (0...127).contains(rawKeyCode),
              let keyCode = UInt32(exactly: rawKeyCode),
              case .string(let displayValue)? = values["display_value"],
              let modifiers = Self.carbonModifiers(from: values["modifiers"]) else {
            return nil
        }
        return MenuKeyboardShortcut(keyCode: keyCode, modifiers: modifiers, displayValue: displayValue)
    }

    func setKeyboardShortcut(_ shortcut: MenuKeyboardShortcut?, for commandID: CommandID) {
        guard let shortcut else {
            inputTexts[commandID] = ""
            return
        }
        inputTexts[commandID] = Self.displayValue(for: .object([
            "key_code": .number(Double(shortcut.keyCode)),
            "modifiers": .array(Self.carbonModifierNames(for: shortcut.modifiers).map { .string($0) }),
            "display_value": .string(shortcut.displayValue)
        ]))
    }

    /// One member of a Command's object input, keyed by its field.
    func fieldValue(_ key: String, for commandID: CommandID) -> JSONValue? {
        fieldValues(for: commandID)[key]
    }

    /// Sets one member of a Command's object input; nil removes it, which
    /// for an overridable Plugin Setting means using the Plugin's value.
    func setFieldValue(_ value: JSONValue?, _ key: String, for commandID: CommandID) {
        var values = fieldValues(for: commandID)
        values[key] = value
        inputTexts[commandID] = Self.displayValue(for: .object(values))
    }

    private func fieldValues(for commandID: CommandID) -> [String: JSONValue] {
        guard case .object(let values) = inputValue(for: commandID) else { return [:] }
        return values
    }

    // MARK: Menu Item Icon

    /// What the Menu Item shows without the user's own icon: the Primary
    /// Action's Command Icon, else the Plugin Icon, else the neutral symbol.
    var defaultIcon: MenuItemIcon {
        manifest == nil ? savedDefaultIcon : icon(for: primaryCommandID)
    }

    /// The icon shown beside `commandID` in the Primary Action picker and
    /// the Alternate Action list: its Command Icon, else the Plugin Icon.
    func icon(for commandID: CommandID) -> MenuItemIcon {
        guard command(commandID) != nil else { return .neutral }
        return MenuItemIcon.resolve(command: commandID, of: pluginID, in: plugins, availability: .available)
    }

    // MARK: Saving

    /// Whether the draft can be saved: a Menu Item of a loaded Plugin needs
    /// a Primary Action.
    var canSave: Bool { manifest == nil || !selectedCommands.isEmpty }

    /// The Host configuration with this Menu Item configured as the draft
    /// says. Without a loaded Plugin only its alias and icon change.
    func makeConfiguration() throws -> HostConfiguration {
        guard let pluginID, manifest != nil else {
            return try editor.presentedMenuItem(
                in: editor.configuration, at: slotIndex, alias: normalizedAlias, icon: ownIcon, for: app
            )
        }
        guard selectedCommands.first?.id == primaryCommandID else {
            throw DraftError.invalidPrimaryAction
        }
        let candidate = try editor.configuredMenuItem(
            at: slotIndex,
            pluginID: pluginID,
            primaryCommandID: primaryCommandID,
            alternateCommandIDs: selectedCommands.dropFirst().map(\.id),
            inputs: inputs,
            alternateCommandOrder: alternateCommandOrder,
            replacingEmptySlot: editor.configuration.menu.slots(for: app)[slotIndex].item == nil,
            validateInputs: true,
            preserveUnselectedAlternates: true,
            for: app
        )
        // For an App, the candidate holds its override of this Slot.
        return try editor.presentedMenuItem(in: candidate, at: slotIndex, alias: normalizedAlias, icon: ownIcon, for: app)
    }

    /// What the sheet hands its save: the configuration, with the secrets
    /// typed into the selected Commands' credential fields and the endpoint
    /// consent, which are saved apart from it.
    func makeSaveDraft(typedSecrets: [String: String] = [:], consent: HTTPSEndpointConsent? = nil,
                       allowedHosts: Set<String> = []) throws -> MenuItemSaveDraft {
        let configuration = try makeConfiguration()
        guard let pluginID, manifest != nil else { return MenuItemSaveDraft(configuration: configuration) }
        return MenuItemSaveDraft(
            configuration: configuration, pluginID: pluginID,
            secrets: CredentialFieldSecrets.typed(for: selectedCommands, inputs: inputs, secrets: typedSecrets),
            consent: consent, allowedHosts: allowedHosts
        )
    }

    enum DraftError: LocalizedError {
        case invalidPrimaryAction

        var errorDescription: String? {
            localized("Choose a valid Primary Action before saving.")
        }
    }

    private var normalizedAlias: String? {
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: Input presentation

    private static func field(of command: CommandDeclaration) -> CommandConfigurationField? {
        command.configurationField ?? command.hostCommand?.configurationField
    }

    static func displayValue(for value: JSONValue) -> String {
        ConfigurationInputValueResolver.presentationValue(for: value, field: nil, hostCommand: nil)
    }

    private static func carbonModifiers(from value: JSONValue?) -> UInt32? {
        guard let value else { return 0 }
        switch value {
        case .number(let rawValue):
            guard rawValue.isFinite, rawValue.rounded() == rawValue,
                  let modifiers = UInt32(exactly: rawValue) else { return nil }
            return modifiers
        case .string(let rawValue):
            return rawValue.split(separator: "+").reduce(into: UInt32(0)) { result, value in
                result |= carbonModifier(for: String(value))
            }
        case .array(let values):
            return values.reduce(into: UInt32(0)) { result, value in
                guard case .string(let modifier) = value else { return }
                result |= carbonModifier(for: modifier)
            }
        default:
            return nil
        }
    }

    private static func carbonModifier(for value: String) -> UInt32 {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd", "⌘": return UInt32(cmdKey)
        case "shift", "⇧": return UInt32(shiftKey)
        case "option", "alt", "⌥": return UInt32(optionKey)
        case "control", "ctrl", "⌃": return UInt32(controlKey)
        default: return 0
        }
    }

    private static func carbonModifierNames(for modifiers: UInt32) -> [String] {
        [
            (UInt32(cmdKey), "command"),
            (UInt32(shiftKey), "shift"),
            (UInt32(optionKey), "option"),
            (UInt32(controlKey), "control"),
        ].compactMap { bit, name in
            modifiers & bit == 0 ? nil : name
        }
    }
}
