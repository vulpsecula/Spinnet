import Foundation

public final class HostConfigurationStore {
    public let fileURL: URL

    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> HostConfiguration? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(HostConfiguration.self, from: data)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.persistence(error.localizedDescription)
        }
    }

    public func save(_ configuration: HostConfiguration) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.persistence(error.localizedDescription)
        }
    }
}

public final class HostConfigurationEditor {
    public private(set) var configuration: HostConfiguration

    private let registry: PluginRegistry
    private let resourceAvailability: (ActionConfiguration) -> ActionUnavailableReason?

    public init(
        registry: PluginRegistry,
        configuration: HostConfiguration,
        resourceAvailability: @escaping (ActionConfiguration) -> ActionUnavailableReason? = {
            ActionResourceAvailability.missingReason(for: $0)
        }
    ) {
        self.registry = registry
        self.configuration = configuration
        self.resourceAvailability = resourceAvailability
    }

    public var availableCommands: [AvailableCommand] {
        registry.availableCommands()
    }

    public var menuItemPresets: [MenuItemPreset] {
        registry.menuItemPresets()
    }

    public var pluginManifests: [PluginManifest] {
        registry.manifests()
    }

    /// The Refused Plugins, which the Library lists but offers no Preset of.
    public var refusedPlugins: [RefusedPlugin] {
        registry.refusedPlugins()
    }

    public func availability(for actionID: ActionID) -> ActionAvailability? {
        guard let action = action(with: actionID) else { return nil }
        return registry.availability(
            for: action,
            resourceAvailability: resourceAvailability
        )
    }

    public func restore(_ configuration: HostConfiguration) {
        self.configuration = configuration
    }

    // MARK: - App Overrides

    /// The App whose App Overrides Menu Item edits change, or nil for the
    /// default Menu. Slots are arranged only in the default Menu.
    public private(set) var editedApp: AppBundleIdentifier?

    /// Directs Menu Item edits to `app`'s App Overrides, or to the default
    /// Menu for nil.
    public func editApp(_ app: AppBundleIdentifier?) {
        editedApp = app
    }

    /// The Slots as the edited App sees them: its overrides, and the default
    /// Menu's Menu Items elsewhere.
    public var editedSlots: [MenuSlotConfiguration] {
        configuration.menu.slots(for: editedApp)
    }

    /// Whether the edited App overrides the Slot at `index`, with a Menu
    /// Item or empty. Nothing is overridden in the default Menu.
    public func isOverridden(slotAt index: Int) -> Bool {
        guard let app = editedApp, configuration.menu.slots.indices.contains(index) else { return false }
        return configuration.menu.slots[index].appOverrides[app] != nil
    }

    /// Empties the Slot at `index` for the edited App, forgetting the
    /// Actions of the Menu Item it overrode the Slot with.
    public func emptySlot(at index: Int) throws {
        let app = try requireEditedApp()
        let slot = try arrangedSlot(at: index)
        configuration = try configuration(
            settingOverride: .empty, for: app, at: index, forgetting: slot.appOverrides[app]?.item
        )
    }

    /// Returns the Slot at `index` to the default Menu's Menu Item for the
    /// edited App, forgetting the Actions of its override.
    public func resetSlotToDefault(at index: Int) throws {
        let app = try requireEditedApp()
        let slot = try arrangedSlot(at: index)
        guard let override = slot.appOverrides[app] else {
            throw ConfigurationError.invalidMenu("Menu Slot is not overridden for this App")
        }
        configuration = try configuration(settingOverride: nil, for: app, at: index, forgetting: override.item)
    }

    /// Removes every App Override of `app` and forgets their Actions. The
    /// default Menu is edited afterwards when `app` was the edited App.
    public func removeApp(_ app: AppBundleIdentifier) throws {
        let forgotten = Set(configuration.menu.slots.compactMap { $0.appOverrides[app]?.item }.flatMap(\.boundActionIDs))
        let slots = configuration.menu.slots.map { $0.withOverride(nil, for: app) }
        configuration = try HostConfiguration(
            actions: configuration.actions.filter { !forgotten.contains($0.id) },
            menu: MenuConfiguration(slots: slots)
        )
        if editedApp == app { editedApp = nil }
    }

    /// `base` with the Menu Item the edited App sees at `index` given
    /// `alias`. A Configuration Sheet names its candidate this way.
    public func configuration(
        _ base: HostConfiguration,
        aliasingMenuItemAt index: Int,
        to alias: String?
    ) throws -> HostConfiguration {
        let base = try materialized(base, at: index)
        var slots = base.menu.slots(for: editedApp)
        guard slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
        }
        guard let item = slots[index].item else {
            throw ConfigurationError.invalidMenu("Cannot rename an empty Menu Slot")
        }
        slots[index] = .occupied(item.withAlias(alias))
        return try HostConfiguration(actions: base.actions, menu: menu(applying: slots, to: base.menu))
    }

    private func requireEditedApp() throws -> AppBundleIdentifier {
        guard let editedApp else {
            throw ConfigurationError.invalidMenu("Only an App's Menu Slots can be emptied or reset")
        }
        return editedApp
    }

    private func requireDefaultMenu() throws {
        guard editedApp == nil else {
            throw ConfigurationError.invalidMenu("Slots are arranged in the default Menu")
        }
    }

    private func arrangedSlot(at index: Int) throws -> MenuSlotConfiguration {
        guard configuration.menu.slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
        }
        return configuration.menu.slots[index]
    }

    private func configuration(
        settingOverride override: AppSlotOverride?,
        for app: AppBundleIdentifier,
        at index: Int,
        forgetting item: MenuItemConfiguration?
    ) throws -> HostConfiguration {
        let forgotten = Set(item?.boundActionIDs ?? [])
        var slots = configuration.menu.slots
        slots[index] = slots[index].withOverride(override, for: app)
        return try HostConfiguration(
            actions: configuration.actions.filter { !forgotten.contains($0.id) },
            menu: MenuConfiguration(slots: slots)
        )
    }

    /// Folds Slots edited as the edited App sees them back into `base`: in
    /// the default Menu each Slot's Menu Item is replaced and its overrides
    /// kept; for an App each changed Slot becomes, or stays, its override.
    private func menu(
        applying edited: [MenuSlotConfiguration],
        to base: MenuConfiguration
    ) throws -> MenuConfiguration {
        let resolved = base.slots(for: editedApp)
        guard edited.count == base.slots.count else {
            throw ConfigurationError.invalidMenu("Slots are arranged in the default Menu")
        }
        var slots: [MenuSlotConfiguration] = []
        for (index, slot) in base.slots.enumerated() {
            let item = edited[index].item
            guard let app = editedApp else {
                slots.append(slot.withItem(item))
                continue
            }
            slots.append(item == resolved[index].item ? slot : slot.withOverride(AppSlotOverride(item: item), for: app))
        }
        return try MenuConfiguration(slots: slots)
    }

    /// `base` where the edited App's inherited Menu Item at `index` has
    /// become its own override, a copy with its own Actions, so editing it
    /// never changes the default Menu's.
    private func materialized(_ base: HostConfiguration, at index: Int) throws -> HostConfiguration {
        guard let app = editedApp, base.menu.slots.indices.contains(index) else { return base }
        let slot = base.menu.slots[index]
        guard slot.appOverrides[app] == nil, let item = slot.item else { return base }
        let actions = Dictionary(uniqueKeysWithValues: base.actions.map { ($0.id, $0) })
        var copiedIDs: [ActionID: ActionID] = [:]
        var copies: [ActionConfiguration] = []
        for actionID in item.boundActionIDs {
            guard let action = actions[actionID] else { continue }
            let copy = try ActionConfiguration(
                id: ActionID(UUID().uuidString),
                pluginID: action.pluginID,
                command: action.declaredCommand,
                input: action.input
            )
            copiedIDs[actionID] = copy.id
            copies.append(copy)
        }
        let copied: (ActionID) -> ActionID = { copiedIDs[$0] ?? $0 }
        let override = try MenuItemConfiguration(
            primaryActionID: copied(item.primaryActionID),
            alternateActionIDs: item.alternateActionIDs.map(copied),
            disabledAlternateActionIDs: item.disabledAlternateActionIDs.map(copied),
            alternateActionOrder: item.alternateActionOrder.map(copied),
            alias: item.alias
        )
        var slots = base.menu.slots
        slots[index] = slot.withOverride(.item(override), for: app)
        return try HostConfiguration(actions: base.actions + copies, menu: MenuConfiguration(slots: slots))
    }

    /// Runs an edit of the Menu Item at `index` on a configuration where an
    /// inherited one is already the edited App's own. The materialized copy
    /// is kept only by an edit that succeeds and keeps its changes.
    private func editingMenuItem<T>(at index: Int, keepsChanges: Bool, _ edit: () throws -> T) throws -> T {
        let original = configuration
        configuration = try materialized(original, at: index)
        do {
            let result = try edit()
            if !keepsChanges { configuration = original }
            return result
        } catch {
            configuration = original
            throw error
        }
    }

    @discardableResult
    public func createAction(
        id: ActionID? = nil,
        pluginID: PluginID,
        commandID: CommandID,
        input: JSONValue
    ) throws -> ActionConfiguration {
        let actionID = id ?? ActionID(UUID().uuidString)
        guard !configuration.actions.contains(where: { $0.id == actionID }) else {
            throw ConfigurationError.invalidAction("Duplicate Action ID \(actionID.rawValue)")
        }
        let action = try makeAvailableAction(
            id: actionID,
            pluginID: pluginID,
            commandID: commandID,
            input: input
        )
        try replaceConfiguration(
            actions: configuration.actions + [action],
            arrangedSlots: configuration.menu.slots
        )
        return action
    }

    @discardableResult
    public func updateAction(
        id: ActionID,
        pluginID: PluginID,
        commandID: CommandID,
        input: JSONValue
    ) throws -> ActionConfiguration {
        guard let index = configuration.actions.firstIndex(where: { $0.id == id }) else {
            throw ConfigurationError.invalidAction("Action \(id.rawValue) is not configured")
        }
        let action = try makeAvailableAction(
            id: id,
            pluginID: pluginID,
            commandID: commandID,
            input: input
        )
        var actions = configuration.actions
        actions[index] = action
        try replaceConfiguration(actions: actions, arrangedSlots: configuration.menu.slots)
        return action
    }

    @discardableResult
    public func updateAction(id: ActionID, input: JSONValue) throws -> ActionConfiguration {
        guard let existingAction = action(with: id) else {
            throw ConfigurationError.invalidAction("Action \(id.rawValue) is not configured")
        }
        return try updateAction(
            id: id,
            pluginID: existingAction.pluginID,
            commandID: existingAction.commandID,
            input: input
        )
    }

    public func removeAction(_ id: ActionID) throws {
        guard configuration.actions.contains(where: { $0.id == id }) else {
            throw ConfigurationError.invalidAction("Action \(id.rawValue) is not configured")
        }

        // Every Menu Item that binds the Action loses it: the default Menu's
        // and every App Override's.
        let slots = try configuration.menu.slots.map { slot -> MenuSlotConfiguration in
            var overrides: [AppBundleIdentifier: AppSlotOverride] = [:]
            for (app, override) in slot.appOverrides {
                overrides[app] = AppSlotOverride(item: try override.item.flatMap { try Self.removing(id, from: $0) })
            }
            return MenuSlotConfiguration(
                item: try slot.item.flatMap { try Self.removing(id, from: $0) },
                appOverrides: overrides
            )
        }

        let actions = configuration.actions.filter { $0.id != id }
        configuration = try HostConfiguration(actions: actions, menu: MenuConfiguration(slots: slots))
    }

    /// `item` without Action `id`, or nil when nothing is left to be its
    /// Primary Action.
    private static func removing(_ id: ActionID, from item: MenuItemConfiguration) throws -> MenuItemConfiguration? {
        let remainingEnabled = item.alternateActionIDs.filter { $0 != id }
        let remainingDisabled = item.disabledAlternateActionIDs.filter { $0 != id }
        let remainingOrder = item.alternateActionOrder.filter { $0 != id }
        guard item.primaryActionID == id else {
            return try MenuItemConfiguration(
                primaryActionID: item.primaryActionID,
                alternateActionIDs: remainingEnabled,
                disabledAlternateActionIDs: remainingDisabled,
                alternateActionOrder: remainingOrder,
                alias: item.alias
            )
        }
        // Promote the first visible Alternate when possible. If all
        // remaining Alternates are hidden, promote the first retained
        // one so deleting a Primary does not discard saved setup.
        guard let promotedPrimary = remainingEnabled.first ?? remainingDisabled.first else { return nil }
        return try MenuItemConfiguration(
            primaryActionID: promotedPrimary,
            alternateActionIDs: remainingEnabled.filter { $0 != promotedPrimary },
            disabledAlternateActionIDs: remainingDisabled.filter { $0 != promotedPrimary },
            alternateActionOrder: remainingOrder.filter { $0 != promotedPrimary },
            alias: item.alias
        )
    }

    public func updateMenuItem(
        at index: Int,
        primaryActionID: ActionID,
        alternateActionIDs: [ActionID] = []
    ) throws {
        guard configuration.menu.slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Item index is out of range")
        }
        try editingMenuItem(at: index, keepsChanges: true) {
            let item = try MenuItemConfiguration(
                primaryActionID: primaryActionID,
                alternateActionIDs: alternateActionIDs,
                alias: editedSlots[index].item?.alias
            )
            var slots = editedSlots
            slots[index] = .occupied(item)
            try replaceConfiguration(actions: configuration.actions, editedSlots: slots)
        }
    }

    /// Sets or clears the user override for a Menu Item's displayed name. A
    /// nil name returns the item to automatic naming from its Preset.
    public func renameMenuItem(at index: Int, name: String?) throws {
        guard configuration.menu.slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
        }
        configuration = try configuration(configuration, aliasingMenuItemAt: index, to: name)
    }

    /// Rebuilds one Menu Slot from a single Plugin's selected Commands. The
    /// operation keeps existing Action IDs when a selected Command remains in
    /// the Slot, creates Actions for newly selected Commands, and removes the
    /// Slot's old Actions in the same configuration replacement.
    public func configureMenuItem(
        at index: Int,
        pluginID: PluginID,
        primaryCommandID: CommandID,
        alternateCommandIDs: [CommandID] = [],
        inputs: [CommandID: JSONValue] = [:]
    ) throws {
        configuration = try configuredMenuItem(
            at: index,
            pluginID: pluginID,
            primaryCommandID: primaryCommandID,
            alternateCommandIDs: alternateCommandIDs,
            inputs: inputs,
            replacingEmptySlot: false,
            validateInputs: false
        )
    }

    /// Builds a complete configuration for a Menu Item edit without mutating
    /// the editor. Settings sheets use this to apply all fields atomically.
    public func configuredMenuItem(
        at index: Int,
        pluginID: PluginID,
        primaryCommandID: CommandID,
        alternateCommandIDs: [CommandID] = [],
        inputs: [CommandID: JSONValue] = [:],
        alternateCommandOrder: [CommandID]? = nil,
        replacingEmptySlot: Bool = false,
        validateInputs: Bool = true,
        preserveUnselectedAlternates: Bool = false
    ) throws -> HostConfiguration {
        let requestedAlternateOrder = alternateCommandOrder ?? alternateCommandIDs
        let selectedAlternateIDs = Set(alternateCommandIDs)
        guard requestedAlternateOrder.count == Set(requestedAlternateOrder).count,
              !requestedAlternateOrder.contains(primaryCommandID),
              selectedAlternateIDs.isSubset(of: Set(requestedAlternateOrder)) else {
            throw ConfigurationError.invalidMenu("Alternate Command order is invalid")
        }
        guard configuration.menu.slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Item index is out of range")
        }
        return try editingMenuItem(at: index, keepsChanges: false) {
            try configuredEditableMenuItem(
                at: index,
                pluginID: pluginID,
                primaryCommandID: primaryCommandID,
                alternateCommandIDs: alternateCommandIDs,
                inputs: inputs,
                alternateCommandOrder: requestedAlternateOrder,
                replacingEmptySlot: replacingEmptySlot,
                validateInputs: validateInputs,
                preserveUnselectedAlternates: preserveUnselectedAlternates
            )
        }
    }

    private func configuredEditableMenuItem(
        at index: Int,
        pluginID: PluginID,
        primaryCommandID: CommandID,
        alternateCommandIDs: [CommandID],
        inputs: [CommandID: JSONValue],
        alternateCommandOrder requestedAlternateOrder: [CommandID],
        replacingEmptySlot: Bool,
        validateInputs: Bool,
        preserveUnselectedAlternates: Bool
    ) throws -> HostConfiguration {
        guard let existingItem = editedSlots[index].item else {
            guard replacingEmptySlot else {
                throw ConfigurationError.invalidMenu("Menu Slot is empty")
            }
            return try configuredEmptyMenuItem(
                at: index,
                pluginID: pluginID,
                primaryCommandID: primaryCommandID,
                alternateCommandIDs: alternateCommandIDs,
                alternateCommandOrder: requestedAlternateOrder,
                inputs: inputs,
                validateInputs: validateInputs
            )
        }

        return try configuredExistingMenuItem(
            at: index,
            existingItem: existingItem,
            pluginID: pluginID,
            primaryCommandID: primaryCommandID,
            alternateCommandIDs: alternateCommandIDs,
            alternateCommandOrder: requestedAlternateOrder,
            inputs: inputs,
            validateInputs: validateInputs,
            preserveUnselectedAlternates: preserveUnselectedAlternates
        )
    }

    private func configuredExistingMenuItem(
        at index: Int,
        existingItem: MenuItemConfiguration,
        pluginID: PluginID,
        primaryCommandID: CommandID,
        alternateCommandIDs: [CommandID],
        alternateCommandOrder: [CommandID],
        inputs: [CommandID: JSONValue],
        validateInputs: Bool,
        preserveUnselectedAlternates: Bool
    ) throws -> HostConfiguration {
        let selectedAlternateIDs = Set(alternateCommandIDs)
        let orderedSelectedAlternateIDs = alternateCommandOrder.filter(selectedAlternateIDs.contains)
        guard Set(orderedSelectedAlternateIDs) == selectedAlternateIDs else {
            throw ConfigurationError.invalidMenu("Alternate Command order is incomplete")
        }
        let selectedCommandIDs = [primaryCommandID] + orderedSelectedAlternateIDs
        guard Set(selectedCommandIDs).count == selectedCommandIDs.count else {
            throw ConfigurationError.invalidMenu("A Command is selected more than once")
        }
        guard inputs.keys.allSatisfy(selectedCommandIDs.contains) else {
            throw ConfigurationError.invalidAction(
                "Configuration input references an unselected Command"
            )
        }

        let oldActionIDs = Set(existingItem.boundActionIDs)
        let oldActions = configuration.actions.filter { oldActionIDs.contains($0.id) }
        let existingCommandIDs = Set(oldActions.filter { $0.pluginID == pluginID }.map(\.commandID))
        let addedCommandIDs = selectedCommandIDs.filter { !existingCommandIDs.contains($0) }
        if let reason = registry.externalAppConnectionPlacementAvailability(for: pluginID, commandIDs: addedCommandIDs).reason {
            throw ConfigurationError.invalidAction(reason.description)
        }
        let presetInputs = registry.menuItemPreset(for: pluginID)?.declaration.defaultInputs ?? [:]
        var existingActionsByCommandID: [CommandID: ActionConfiguration] = [:]
        for action in oldActions where action.pluginID == pluginID {
            existingActionsByCommandID[action.commandID] = action
        }

        let newActions = try makeActions(
            selectedCommandIDs: selectedCommandIDs,
            pluginID: pluginID,
            inputs: inputs,
            fallbackInputs: presetInputs,
            existingActionsByCommandID: existingActionsByCommandID,
            validateInputs: validateInputs
        )

        let newActionsByCommandID = Dictionary(
            uniqueKeysWithValues: newActions.map { ($0.commandID, $0) }
        )
        var retainedActions: [ActionConfiguration] = []
        var enabledAlternateActionIDs: [ActionID] = []
        var disabledAlternateActionIDs: [ActionID] = []
        var alternateActionOrder: [ActionID] = []
        var representedCommandIDs = Set<CommandID>()

        for commandID in alternateCommandOrder where commandID != primaryCommandID {
            if let action = newActionsByCommandID[commandID] {
                alternateActionOrder.append(action.id)
                enabledAlternateActionIDs.append(action.id)
                representedCommandIDs.insert(commandID)
                continue
            }
            guard preserveUnselectedAlternates,
                  let action = existingActionsByCommandID[commandID] else { continue }
            alternateActionOrder.append(action.id)
            disabledAlternateActionIDs.append(action.id)
            retainedActions.append(action)
            representedCommandIDs.insert(commandID)
        }

        if preserveUnselectedAlternates {
            // Keep an old Alternate whose Command is no longer surfaced by
            // the current manifest at the end of the editor order. This makes
            // stale configuration recoverable instead of silently deleting it.
            for actionID in existingItem.alternateActionOrder {
                guard let action = existingActionsByCommandID.first(where: { $0.value.id == actionID })?.value,
                      action.commandID != primaryCommandID,
                      !representedCommandIDs.contains(action.commandID) else { continue }
                alternateActionOrder.append(action.id)
                disabledAlternateActionIDs.append(action.id)
                retainedActions.append(action)
                representedCommandIDs.insert(action.commandID)
            }
        }

        let item = try MenuItemConfiguration(
            primaryActionID: newActions[0].id,
            alternateActionIDs: enabledAlternateActionIDs,
            disabledAlternateActionIDs: disabledAlternateActionIDs,
            alternateActionOrder: alternateActionOrder,
            alias: existingItem.alias
        )
        var slots = editedSlots
        slots[index] = .occupied(item)
        return try HostConfiguration(
            actions: configuration.actions.filter { !oldActionIDs.contains($0.id) }
                + newActions
                + retainedActions,
            menu: menu(applying: slots, to: configuration.menu)
        )
    }

    private func configuredEmptyMenuItem(
        at index: Int,
        pluginID: PluginID,
        primaryCommandID: CommandID,
        alternateCommandIDs: [CommandID],
        alternateCommandOrder: [CommandID],
        inputs: [CommandID: JSONValue],
        validateInputs: Bool
    ) throws -> HostConfiguration {
        let selectedAlternateIDs = Set(alternateCommandIDs)
        let orderedSelectedAlternateIDs = alternateCommandOrder.filter(selectedAlternateIDs.contains)
        let selectedCommandIDs = [primaryCommandID] + orderedSelectedAlternateIDs
        if let reason = registry.externalAppConnectionPlacementAvailability(for: pluginID, commandIDs: selectedCommandIDs).reason {
            throw ConfigurationError.invalidAction(reason.description)
        }
        guard Set(selectedCommandIDs).count == selectedCommandIDs.count else {
            throw ConfigurationError.invalidMenu("A Command is selected more than once")
        }
        guard inputs.keys.allSatisfy(selectedCommandIDs.contains) else {
            throw ConfigurationError.invalidAction(
                "Configuration input references an unselected Command"
            )
        }
        let presetInputs = registry.menuItemPreset(for: pluginID)?.declaration.defaultInputs ?? [:]
        let newActions = try makeActions(
            selectedCommandIDs: selectedCommandIDs,
            pluginID: pluginID,
            inputs: inputs,
            fallbackInputs: presetInputs,
            existingActionsByCommandID: [:],
            validateInputs: validateInputs
        )
        guard let primary = newActions.first else {
            throw ConfigurationError.invalidAction("A Primary Action is required")
        }
        let item = try MenuItemConfiguration(
            primaryActionID: primary.id,
            alternateActionIDs: newActions.dropFirst().map(\.id)
        )
        var slots = editedSlots
        slots[index] = .occupied(item)
        return try HostConfiguration(
            actions: configuration.actions + newActions,
            menu: menu(applying: slots, to: configuration.menu)
        )
    }

    private func makeActions(
        selectedCommandIDs: [CommandID],
        pluginID: PluginID,
        inputs: [CommandID: JSONValue],
        fallbackInputs: [CommandID: JSONValue],
        existingActionsByCommandID: [CommandID: ActionConfiguration],
        validateInputs: Bool
    ) throws -> [ActionConfiguration] {
        try selectedCommandIDs.map { commandID -> ActionConfiguration in
            guard let command = registry.command(for: pluginID, commandID: commandID) else {
                throw ConfigurationError.invalidAction("Command is unavailable")
            }
            let existingAction = existingActionsByCommandID[commandID]
            let input: JSONValue
            if !command.isConfigurable {
                input = .null
            } else {
                input = inputs[commandID]
                    ?? existingAction?.input
                    ?? fallbackInputs[commandID]
                    ?? .null
                if validateInputs, let problem = CommandInputValidation.problem(
                    with: input, for: command, in: registry.package(for: pluginID)?.manifest
                ) {
                    throw ConfigurationError.invalidAction(problem)
                }
            }
            return try makeAvailableAction(
                id: existingAction?.id ?? ActionID(UUID().uuidString),
                pluginID: pluginID,
                commandID: commandID,
                input: input
            )
        }
    }

    public func addMenuItem(
        primaryActionID: ActionID,
        alternateActionIDs: [ActionID] = []
    ) throws {
        try requireDefaultMenu()
        let item = try MenuItemConfiguration(
            primaryActionID: primaryActionID,
            alternateActionIDs: alternateActionIDs
        )
        try replaceConfiguration(
            actions: configuration.actions,
            arrangedSlots: configuration.menu.slots + [.occupied(item)]
        )
    }

    public func addEmptySlot() throws {
        try insertSlot(.empty, at: configuration.menu.slots.endIndex)
    }

    public func insertSlot(_ slot: MenuSlotConfiguration, at index: Int) throws {
        try requireDefaultMenu()
        guard (0...configuration.menu.slots.count).contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
        }
        var slots = configuration.menu.slots
        slots.insert(slot, at: index)
        try replaceConfiguration(actions: configuration.actions, arrangedSlots: slots)
    }

    public func removeSlot(at index: Int) throws {
        try requireDefaultMenu()
        guard configuration.menu.slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Item index is out of range")
        }
        guard configuration.menu.slots.count > 1 else {
            throw ConfigurationError.invalidMenu("A Menu must contain at least one Slot")
        }
        var slots = configuration.menu.slots
        slots.remove(at: index)
        try replaceConfiguration(actions: configuration.actions, arrangedSlots: slots)
    }

    @discardableResult
    public func placeCommand(
        id: ActionID? = nil,
        pluginID: PluginID,
        commandID: CommandID,
        input: JSONValue,
        inSlotAt index: Int
    ) throws -> ActionConfiguration {
        guard configuration.menu.slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
        }
        guard editedSlots[index].item == nil else {
            throw ConfigurationError.invalidMenu("Menu Slot is already occupied")
        }
        let actionID = id ?? ActionID(UUID().uuidString)
        let action = try makeAvailableAction(
            id: actionID,
            pluginID: pluginID,
            commandID: commandID,
            input: input
        )
        let item = try MenuItemConfiguration(primaryActionID: action.id)
        var slots = editedSlots
        slots[index] = .occupied(item)
        try replaceConfiguration(
            actions: configuration.actions + [action],
            editedSlots: slots
        )
        return action
    }

    @discardableResult
    public func placePreset(
        pluginID: PluginID,
        inSlotAt index: Int,
        replacing: Bool = false
    ) throws -> MenuItemConfiguration {
        guard configuration.menu.slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
        }
        // Replacing an App's inherited Menu Item replaces a copy of it, so
        // the default Menu keeps its Actions.
        return try editingMenuItem(at: index, keepsChanges: true) {
            try placeEditablePreset(pluginID: pluginID, inSlotAt: index, replacing: replacing)
        }
    }

    private func placeEditablePreset(
        pluginID: PluginID,
        inSlotAt index: Int,
        replacing: Bool
    ) throws -> MenuItemConfiguration {
        guard editedSlots[index].item == nil || replacing else {
            throw ConfigurationError.invalidMenu("Menu Slot is already occupied")
        }
        guard let preset = registry.menuItemPreset(for: pluginID), preset.isAvailable else {
            throw ConfigurationError.invalidAction("Preset is unavailable")
        }
        guard preset.readiness == .readyToUse else {
            throw ConfigurationError.invalidAction("Preset requires setup")
        }

        let declaration = preset.declaration
        let primaryCommandID = declaration.defaultPrimaryCommandID ?? preset.commands[0].id
        let commandIDs = [primaryCommandID] + declaration.defaultAlternateCommandIDs
        if let reason = registry.externalAppConnectionPlacementAvailability(for: pluginID, commandIDs: commandIDs).reason {
            throw ConfigurationError.invalidAction(reason.description)
        }
        let newActions = try commandIDs.map { commandID -> ActionConfiguration in
            guard let command = preset.commands.first(where: { $0.id == commandID }) else {
                throw ConfigurationError.invalidAction("Preset defaults are incomplete")
            }
            let input: JSONValue
            if let configuredInput = declaration.defaultInputs[commandID] {
                input = configuredInput
            } else if !command.isConfigurable {
                input = .null
            } else {
                throw ConfigurationError.invalidAction("Preset defaults are incomplete")
            }
            return try ActionConfiguration(
                id: ActionID(UUID().uuidString),
                pluginID: pluginID,
                command: command,
                input: input
            )
        }
        let item = try MenuItemConfiguration(
            primaryActionID: newActions[0].id,
            alternateActionIDs: newActions.dropFirst().map(\.id)
        )
        let replacedActionIDs = Set(
            editedSlots[index].item.map {
                $0.boundActionIDs
            } ?? []
        )
        var slots = editedSlots
        slots[index] = .occupied(item)
        try replaceConfiguration(
            actions: configuration.actions.filter { !replacedActionIDs.contains($0.id) } + newActions,
            editedSlots: slots
        )
        return item
    }

    /// Reorders complete Slots along the shorter circular arc.
    public func moveSlot(from sourceIndex: Int, to targetIndex: Int) throws {
        try requireDefaultMenu()
        guard configuration.menu.slots.indices.contains(sourceIndex),
              configuration.menu.slots.indices.contains(targetIndex) else {
            throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
        }
        guard sourceIndex != targetIndex else { return }
        let plan = CircularSlotReorder(count: configuration.menu.slots.count, source: sourceIndex, target: targetIndex)
        try reorderSlots(order: plan.order)
    }

    public func reorderSlots(order: [Int]) throws {
        try requireDefaultMenu()
        let slots = configuration.menu.slots
        guard order.count == slots.count, Set(order) == Set(slots.indices) else {
            throw ConfigurationError.invalidMenu("Slot order must contain each existing Slot exactly once")
        }
        try replaceConfiguration(actions: configuration.actions, arrangedSlots: order.map { slots[$0] })
    }

    private func action(with id: ActionID) -> ActionConfiguration? {
        configuration.actions.first { $0.id == id }
    }

    private func makeAvailableAction(
        id: ActionID,
        pluginID: PluginID,
        commandID: CommandID,
        input: JSONValue
    ) throws -> ActionConfiguration {
        guard registry.isEnabled(for: pluginID) else {
            throw ConfigurationError.invalidAction("Plugin is unavailable")
        }
        guard let command = registry.command(for: pluginID, commandID: commandID) else {
            throw ConfigurationError.invalidAction("Command is unavailable")
        }
        return try ActionConfiguration(
            id: id,
            pluginID: pluginID,
            command: command,
            input: input
        )
    }

    /// Replaces the Slots as the edited App sees them, folding them back
    /// into the default Menu or the App's overrides.
    private func replaceConfiguration(
        actions: [ActionConfiguration],
        editedSlots: [MenuSlotConfiguration]
    ) throws {
        let menu = try menu(applying: editedSlots, to: configuration.menu)
        configuration = try HostConfiguration(actions: actions, menu: menu)
    }

    /// Replaces the arrangement of the default Menu's Slots, each carrying
    /// its App Overrides.
    private func replaceConfiguration(
        actions: [ActionConfiguration],
        arrangedSlots: [MenuSlotConfiguration]
    ) throws {
        let menu = try MenuConfiguration(slots: arrangedSlots)
        configuration = try HostConfiguration(actions: actions, menu: menu)
    }
}
