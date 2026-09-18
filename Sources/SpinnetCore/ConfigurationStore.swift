import Foundation

public protocol ConfigurationStore {
    func load() throws -> HostConfiguration?
    func save(_ configuration: HostConfiguration) throws
}

public final class HostConfigurationStore: ConfigurationStore {
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
            slots: configuration.menu.slots
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
        try replaceConfiguration(actions: actions, slots: configuration.menu.slots)
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

        var slots: [MenuSlotConfiguration] = []
        for slot in configuration.menu.slots {
            guard let item = slot.item else {
                slots.append(slot)
                continue
            }
            let remainingEnabled = item.alternateActionIDs.filter { $0 != id }
            let remainingDisabled = item.disabledAlternateActionIDs.filter { $0 != id }
            let remainingOrder = item.alternateActionOrder.filter { $0 != id }
            if item.primaryActionID == id {
                // Promote the first visible Alternate when possible. If all
                // remaining Alternates are hidden, promote the first retained
                // one so deleting a Primary does not discard saved setup.
                let promotedPrimary = remainingEnabled.first ?? remainingDisabled.first
                if let promotedPrimary {
                    let enabled = remainingEnabled.filter { $0 != promotedPrimary }
                    let disabled = remainingDisabled.filter { $0 != promotedPrimary }
                    slots.append(.occupied(try MenuItemConfiguration(
                        primaryActionID: promotedPrimary,
                        alternateActionIDs: enabled,
                        disabledAlternateActionIDs: disabled,
                        alternateActionOrder: remainingOrder.filter { $0 != promotedPrimary },
                        alias: item.alias
                    )))
                } else {
                    slots.append(.empty)
                }
            } else {
                slots.append(.occupied(try MenuItemConfiguration(
                    primaryActionID: item.primaryActionID,
                    alternateActionIDs: remainingEnabled,
                    disabledAlternateActionIDs: remainingDisabled,
                    alternateActionOrder: remainingOrder,
                    alias: item.alias
                )))
            }
        }

        let actions = configuration.actions.filter { $0.id != id }
        try replaceConfiguration(actions: actions, slots: slots)
    }

    public func updateMenuItem(
        at index: Int,
        primaryActionID: ActionID,
        alternateActionIDs: [ActionID] = []
    ) throws {
        guard configuration.menu.slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Item index is out of range")
        }
        let item = try MenuItemConfiguration(
            primaryActionID: primaryActionID,
            alternateActionIDs: alternateActionIDs,
            alias: configuration.menu.slots[index].item?.alias
        )
        var slots = configuration.menu.slots
        slots[index] = .occupied(item)
        try replaceConfiguration(actions: configuration.actions, slots: slots)
    }

    /// Sets or clears the user override for a Menu Item's displayed name. A
    /// nil name returns the item to automatic naming from its Preset.
    public func renameMenuItem(at index: Int, name: String?) throws {
        guard configuration.menu.slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
        }
        let slot = configuration.menu.slots[index]
        guard let item = slot.item else {
            throw ConfigurationError.invalidMenu("Cannot rename an empty Menu Slot")
        }
        var slots = configuration.menu.slots
        slots[index] = .occupied(item.withAlias(name))
        try replaceConfiguration(actions: configuration.actions, slots: slots)
    }

    /// Compatibility spelling for clients written before aliases moved onto
    /// Menu Items. The operation now follows the Menu Item identity.
    @available(*, deprecated, message: "Use renameMenuItem(at:name:) instead")
    public func renameSlot(at index: Int, name: String?) throws {
        try renameMenuItem(at: index, name: name)
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
        guard let existingItem = configuration.menu.slots[index].item else {
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
        var slots = configuration.menu.slots
        slots[index] = .occupied(item)
        return try HostConfiguration(
            actions: configuration.actions.filter { !oldActionIDs.contains($0.id) }
                + newActions
                + retainedActions,
            menu: MenuConfiguration(slots: slots)
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
        var slots = configuration.menu.slots
        slots[index] = .occupied(item)
        return try HostConfiguration(
            actions: configuration.actions + newActions,
            menu: MenuConfiguration(slots: slots)
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
                if validateInputs,
                   command.execution == .host,
                   let hostCommand = command.hostCommand,
                   !hostCommand.isValidInput(input) {
                    throw ConfigurationError.invalidAction(
                        "Configuration input is invalid for Command \(commandID.rawValue)"
                    )
                }
                if validateInputs,
                   let field = command.configurationField,
                   !field.isValidInput(input) {
                    throw ConfigurationError.invalidAction(
                        "\(command.title): \(field.inputRequirement ?? "The value is invalid.")"
                    )
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
        let item = try MenuItemConfiguration(
            primaryActionID: primaryActionID,
            alternateActionIDs: alternateActionIDs
        )
        try replaceConfiguration(
            actions: configuration.actions,
            slots: configuration.menu.slots + [.occupied(item)]
        )
    }

    public func removeMenuItem(at index: Int) throws {
        try removeSlot(at: index)
    }

    public func addEmptySlot() throws {
        try insertSlot(.empty, at: configuration.menu.slots.endIndex)
    }

    public func insertSlot(_ slot: MenuSlotConfiguration, at index: Int) throws {
        guard (0...configuration.menu.slots.count).contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
        }
        var slots = configuration.menu.slots
        slots.insert(slot, at: index)
        try replaceConfiguration(actions: configuration.actions, slots: slots)
    }

    public func removeSlot(at index: Int) throws {
        guard configuration.menu.slots.indices.contains(index) else {
            throw ConfigurationError.invalidMenu("Menu Item index is out of range")
        }
        guard configuration.menu.slots.count > 1 else {
            throw ConfigurationError.invalidMenu("A Menu must contain at least one Slot")
        }
        var slots = configuration.menu.slots
        slots.remove(at: index)
        try replaceConfiguration(actions: configuration.actions, slots: slots)
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
        guard configuration.menu.slots[index].item == nil else {
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
        var slots = configuration.menu.slots
        slots[index] = .occupied(item)
        try replaceConfiguration(
            actions: configuration.actions + [action],
            slots: slots
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
        guard configuration.menu.slots[index].item == nil || replacing else {
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
            configuration.menu.slots[index].item.map {
                $0.boundActionIDs
            } ?? []
        )
        var slots = configuration.menu.slots
        slots[index] = .occupied(item)
        try replaceConfiguration(
            actions: configuration.actions.filter { !replacedActionIDs.contains($0.id) } + newActions,
            slots: slots
        )
        return item
    }

    /// Reorders complete Slots along the shorter circular arc.
    public func moveSlot(from sourceIndex: Int, to targetIndex: Int) throws {
        guard configuration.menu.slots.indices.contains(sourceIndex),
              configuration.menu.slots.indices.contains(targetIndex) else {
            throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
        }
        guard sourceIndex != targetIndex else { return }
        let plan = CircularSlotReorder(count: configuration.menu.slots.count, source: sourceIndex, target: targetIndex)
        try reorderSlots(order: plan.order)
    }

    public func reorderSlots(order: [Int]) throws {
        let slots = configuration.menu.slots
        guard order.count == slots.count, Set(order) == Set(slots.indices) else {
            throw ConfigurationError.invalidMenu("Slot order must contain each existing Slot exactly once")
        }
        try replaceConfiguration(actions: configuration.actions, slots: order.map { slots[$0] })
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

    private func replaceConfiguration(
        actions: [ActionConfiguration],
        slots: [MenuSlotConfiguration]
    ) throws {
        let menu = try MenuConfiguration(slots: slots)
        configuration = try HostConfiguration(actions: actions, menu: menu)
    }
}
