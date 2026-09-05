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

    public init(registry: PluginRegistry, configuration: HostConfiguration) {
        self.registry = registry
        self.configuration = configuration
    }

    public var availableCommands: [AvailableCommand] {
        registry.availableCommands()
    }

    public func availability(for actionID: ActionID) -> ActionAvailability? {
        guard let action = action(with: actionID) else { return nil }
        return registry.availability(for: action)
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
                slots.append(.empty)
                continue
            }
            if item.primaryActionID == id {
                let remainingAlternates = item.alternateActionIDs.filter { $0 != id }
                if let promotedPrimary = remainingAlternates.first {
                    slots.append(.occupied(try MenuItemConfiguration(
                        primaryActionID: promotedPrimary,
                        alternateActionIDs: Array(remainingAlternates.dropFirst())
                    )))
                } else {
                    slots.append(.empty)
                }
            } else {
                slots.append(.occupied(try MenuItemConfiguration(
                    primaryActionID: item.primaryActionID,
                    alternateActionIDs: item.alternateActionIDs.filter { $0 != id }
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
            alternateActionIDs: alternateActionIDs
        )
        var slots = configuration.menu.slots
        slots[index] = .occupied(item)
        try replaceConfiguration(actions: configuration.actions, slots: slots)
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
