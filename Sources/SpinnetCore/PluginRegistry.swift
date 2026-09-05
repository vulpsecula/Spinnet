import Foundation

public enum ActionUnavailableReason: String, Equatable, Hashable, CaseIterable, CustomStringConvertible {
    case pluginMissing = "plugin_missing"
    case pluginDisabled = "plugin_disabled"
    case commandMissing = "command_missing"
    case commandChanged = "command_changed"

    public var description: String {
        switch self {
        case .pluginMissing: return "Plugin is not registered"
        case .pluginDisabled: return "Plugin is disabled"
        case .commandMissing: return "Command is no longer registered"
        case .commandChanged: return "Command definition changed"
        }
    }
}

public enum ActionAvailability: Equatable, Hashable {
    case available
    case unavailable(ActionUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: ActionUnavailableReason? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

public struct AvailableCommand: Equatable, Hashable {
    public let pluginID: PluginID
    public let pluginName: String
    public let command: CommandDeclaration

    public init(pluginID: PluginID, pluginName: String, command: CommandDeclaration) {
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.command = command
    }

    public var commandID: CommandID { command.id }
    public var title: String { command.title }
}

public final class PluginRegistry {
    private let lock = NSLock()
    private var packages: [PluginID: PluginPackage] = [:]
    private var disabledPluginIDs: Set<PluginID> = []

    public init() {}

    @discardableResult
    public func register(packageAt rootURL: URL) throws -> PluginManifest {
        let package = try PluginManifestLoader.load(packageAt: rootURL)
        try register(package)
        return package.manifest
    }

    public func register(_ package: PluginPackage) throws {
        try package.manifest.validate()

        lock.lock()
        defer { lock.unlock() }

        guard packages[package.manifest.id] == nil else {
            throw ConfigurationError.invalidManifest(
                "duplicate plugin id \(package.manifest.id.rawValue)"
            )
        }

        packages[package.manifest.id] = package
    }

    public func replace(_ package: PluginPackage) throws {
        try package.manifest.validate()

        lock.lock()
        defer { lock.unlock() }

        guard packages[package.manifest.id] != nil else {
            throw ConfigurationError.invalidManifest(
                "cannot replace unregistered plugin \(package.manifest.id.rawValue)"
            )
        }
        packages[package.manifest.id] = package
    }

    public func setEnabled(_ enabled: Bool, for pluginID: PluginID) throws {
        lock.lock()
        defer { lock.unlock() }

        guard packages[pluginID] != nil else {
            throw ConfigurationError.invalidManifest(
                "plugin \(pluginID.rawValue) is not registered"
            )
        }
        if enabled {
            disabledPluginIDs.remove(pluginID)
        } else {
            disabledPluginIDs.insert(pluginID)
        }
    }

    public func isEnabled(for pluginID: PluginID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return packages[pluginID] != nil && !disabledPluginIDs.contains(pluginID)
    }

    public func availableCommands() -> [AvailableCommand] {
        lock.lock()
        defer { lock.unlock() }

        return packages.values
            .filter { !disabledPluginIDs.contains($0.manifest.id) }
            .flatMap { package in
                package.manifest.commands.map {
                    AvailableCommand(
                        pluginID: package.manifest.id,
                        pluginName: package.manifest.name,
                        command: $0
                    )
                }
            }
            .sorted {
                if $0.pluginID != $1.pluginID {
                    return $0.pluginID.rawValue < $1.pluginID.rawValue
                }
                return $0.commandID.rawValue < $1.commandID.rawValue
            }
    }

    public func menuItemPresets() -> [MenuItemPreset] {
        lock.lock()
        defer { lock.unlock() }

        return packages.values
            .map { package in
                MenuItemPreset(
                    pluginID: package.manifest.id,
                    name: package.manifest.name,
                    commands: package.manifest.commands,
                    source: package.presetSource,
                    declaration: package.manifest.preset,
                    unavailableReason: disabledPluginIDs.contains(package.manifest.id)
                        ? .pluginDisabled
                        : nil
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public func menuItemPreset(for pluginID: PluginID) -> MenuItemPreset? {
        menuItemPresets().first { $0.pluginID == pluginID }
    }

    public func command(
        for pluginID: PluginID,
        commandID: CommandID
    ) -> CommandDeclaration? {
        lock.lock()
        defer { lock.unlock() }
        return packages[pluginID]?.manifest.commands.first { $0.id == commandID }
    }

    public func availability(for action: ActionConfiguration) -> ActionAvailability {
        lock.lock()
        defer { lock.unlock() }

        guard let package = packages[action.pluginID] else {
            return .unavailable(.pluginMissing)
        }
        guard !disabledPluginIDs.contains(action.pluginID) else {
            return .unavailable(.pluginDisabled)
        }
        guard let command = package.manifest.commands.first(where: { $0.id == action.commandID }) else {
            return .unavailable(.commandMissing)
        }
        guard command == action.declaredCommand else {
            return .unavailable(.commandChanged)
        }
        return .available
    }

    public func package(for pluginID: PluginID) -> PluginPackage? {
        lock.lock()
        defer { lock.unlock() }
        return packages[pluginID]
    }

    public func manifests() -> [PluginManifest] {
        lock.lock()
        defer { lock.unlock() }
        return packages.values
            .map(\.manifest)
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }
}
