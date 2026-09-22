import Foundation

public enum ActionUnavailableReason: String, Equatable, Hashable, CaseIterable, CustomStringConvertible {
    case pluginMissing = "plugin_missing"
    case pluginDisabled = "plugin_disabled"
    case commandMissing = "command_missing"
    case commandChanged = "command_changed"
    case resourceMissing = "resource_missing"
    case externalAppMissing = "external_app_missing"
    case externalAppOperationUnsupported = "external_app_operation_unsupported"
    case capabilityDenied = "capability_denied"
    case systemPermissionDenied = "system_permission_denied"
    case hostServiceUnavailable = "host_service_unavailable"
    /// The Screen Recording System Permission is missing. Accessibility keeps
    /// `systemPermissionDenied`, so each permission names its own repair.
    case screenRecordingDenied = "screen_recording_denied"
    /// The Screenshot save folder is gone, is not a folder, or cannot be
    /// written, and the Screenshot Plugin Settings say to save.
    case saveFolderUnavailable = "save_folder_unavailable"
    /// The Plugin declares settings and one still has no usable value.
    case pluginSettingsIncomplete = "plugin_settings_incomplete"

    public var description: String {
        switch self {
        case .pluginMissing: return "Plugin is not registered"
        case .pluginDisabled: return "Plugin is disabled"
        case .commandMissing: return "Command is no longer registered"
        case .commandChanged: return "Command definition changed"
        case .resourceMissing: return "Referenced resource is missing"
        case .externalAppMissing: return "Install the required External App, then try again"
        case .externalAppOperationUnsupported: return "This External App operation is not supported by Spinnet"
        case .capabilityDenied: return "Grant Access in Plugin Settings"
        case .systemPermissionDenied: return "Enable Accessibility in Privacy & Permissions"
        case .hostServiceUnavailable: return "Required Host Service is not available in this version"
        case .screenRecordingDenied: return "Enable Screen Recording in Privacy & Permissions"
        case .pluginSettingsIncomplete: return "Complete this Plugin's Plugin Settings in the Library"
        case .saveFolderUnavailable: return "Screenshot save folder is missing or not writable; choose it again in Screenshot Plugin Settings"
        }
    }
}

/// Resolves resources referenced by Host Commands at the configuration seam.
/// PluginRegistry remains responsible for Plugin and Command identity; the
/// Host uses this resolver to keep a Menu Item in place while disabling only
/// the Action whose external resource disappeared.
public enum ActionResourceAvailability {
    /// Returns the reason an Action cannot currently resolve its external
    /// resource, or nil when the Action has no resource reference. Hosts can
    /// provide an application resolver to validate bundle identifiers.
    public static func missingReason(
        for action: ActionConfiguration,
        applicationExists: ((String) -> Bool)? = nil
    ) -> ActionUnavailableReason? {
        guard action.execution == .host,
              let hostCommand = action.hostCommand else { return nil }

        switch hostCommand {
        case .openApplication:
            guard let value = stringValue(
                in: action.input,
                keys: ["path", "bundle_id", "bundle_identifier", "bundleIdentifier"]
            ) else {
                return nil
            }
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikePath(trimmedValue) {
                return applicationPathExists(at: trimmedValue) ? nil : .resourceMissing
            }
            return applicationExists?(trimmedValue) == false ? .resourceMissing : nil
        case .openFile:
            guard let path = stringValue(in: action.input, keys: ["path"]) else {
                return nil
            }
            return pathExists(path, isDirectory: false) ? nil : .resourceMissing
        case .openFolder:
            guard let path = stringValue(in: action.input, keys: ["path"]) else {
                return nil
            }
            return pathExists(path, isDirectory: true) ? nil : .resourceMissing
        default:
            return nil
        }
    }

    /// The editor uses this for the native picker label and stale-resource
    /// hint without having to construct an Action snapshot first.
    public static func resourceExists(
        kind: CommandConfigurationFieldKind,
        value: String,
        applicationExists: ((String) -> Bool)? = nil
    ) -> Bool {
        switch kind {
        case .application:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if looksLikePath(trimmed) {
                return applicationPathExists(at: trimmed)
            }
            return applicationExists?(trimmed) ?? true
        case .file:
            return pathExists(value, isDirectory: false)
        case .folder:
            return pathExists(value, isDirectory: true)
        default:
            return true
        }
    }

    private static func applicationPathExists(at value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard looksLikePath(trimmed) else {
            // Bundle identifiers are resolved by NSWorkspace at execution
            // time and cannot be queried from the Core target without an
            // AppKit dependency. Keep them available until execution.
            return true
        }
        return pathExists(trimmed, isDirectory: true)
    }

    private static func looksLikePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            || value.hasPrefix("~")
            || value.contains("/")
            || value.hasSuffix(".app")
    }

    private static func fileURL(for path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func pathExists(_ path: String, isDirectory expectedDirectory: Bool) -> Bool {
        var actualDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: fileURL(for: path).path,
            isDirectory: &actualDirectory
        )
        return exists && actualDirectory.boolValue == expectedDirectory
    }

    private static func stringValue(in input: JSONValue, keys: [String]) -> String? {
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
    private var invalidationObservers: [UUID: (PluginID) -> Void] = [:]

    /// Observers must only retire runtime work; they must not reenter the registry.
    public func observeInvalidation(_ observer: @escaping (PluginID) -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        invalidationObservers[token] = observer
        return token
    }

    public func removeInvalidationObserver(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        invalidationObservers.removeValue(forKey: token)
    }

    /// Keeps validation and helper admission atomic with Plugin mutations.
    func withCurrentPackage<T>(_ package: PluginPackage, operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let current = packages[package.manifest.id],
              current.rootURL == package.rootURL,
              current.manifest == package.manifest,
              !disabledPluginIDs.contains(package.manifest.id) else {
            throw PluginRuntimeError.invalidAction("Plugin package is no longer active")
        }
        return try operation()
    }

    public func unregister(_ pluginID: PluginID) {
        lock.lock()
        defer { lock.unlock() }
        packages.removeValue(forKey: pluginID)
        disabledPluginIDs.remove(pluginID)
        for observer in invalidationObservers.values { observer(pluginID) }
    }

    private let grantStore: PluginCapabilityGrantStore?
    private let systemPermissionCheck: (PluginSystemPermission) -> Bool
    private let externalAppExists: (String) -> Bool
    private let pluginSettingsComplete: (PluginManifest) -> Bool

    public init(
        grantStore: PluginCapabilityGrantStore? = nil,
        systemPermissionCheck: @escaping (PluginSystemPermission) -> Bool = { _ in true },
        externalAppExists: @escaping (String) -> Bool = { _ in false },
        pluginSettingsComplete: @escaping (PluginManifest) -> Bool = { _ in true }
    ) {
        self.grantStore = grantStore
        self.systemPermissionCheck = systemPermissionCheck
        self.externalAppExists = externalAppExists
        self.pluginSettingsComplete = pluginSettingsComplete
    }

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

        // Installation owns migration and persistence. Scope-bound decisions
        // prevent a replacement from broadening a grant, including when its
        // version string is reused. Registry replacement still retires helpers.

        lock.lock()
        defer { lock.unlock() }

        guard packages[package.manifest.id] != nil else {
            throw ConfigurationError.invalidManifest(
                "cannot replace unregistered plugin \(package.manifest.id.rawValue)"
            )
        }
        packages[package.manifest.id] = package
        for observer in invalidationObservers.values { observer(package.manifest.id) }
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
            for observer in invalidationObservers.values { observer(pluginID) }
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
            .filter(\.isVisibleInLibrary)
            .map { package in
                MenuItemPreset(
                    pluginID: package.manifest.id,
                    name: package.manifest.name,
                    commands: package.manifest.commands,
                    source: package.presetSource,
                    declaration: package.manifest.preset,
                    unavailableReason: disabledPluginIDs.contains(package.manifest.id)
                        ? .pluginDisabled
                        : nil,
                    canBeRemoved: package.canBeRemovedByUser,
                    needsPluginSettings: package.manifest.hasSettings && !pluginSettingsComplete(package.manifest)
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
        let identity = identityAvailability(for: action)
        guard identity.isAvailable, let grantStore, let package = package(for: action.pluginID) else { return identity }
        // Resolve every new required scope before activating this revision. Explicit
        // denial completes review while keeping only affected Commands off.
        if package.manifest.capabilities.contains(where: {
            !package.manifest.optionalCapabilities.contains($0)
                && grantStore.decision(for: action.pluginID, pluginVersion: package.manifest.version,
                    capability: $0, scope: package.manifest.scope(for: $0)) == .notDetermined
        }) { return .unavailable(.capabilityDenied) }
        let capabilities = package.manifest.requiredCapabilities(for: action.declaredCommand, input: action.input)
        if capabilities.contains(where: {
            !package.manifest.declares($0, for: action.commandID) || grantStore.decision(
                for: action.pluginID, pluginVersion: package.manifest.version, capability: $0, scope: package.manifest.scope(for: $0)
            ) != .granted
        }) { return .unavailable(.capabilityDenied) }
        let targets = package.manifest.capabilityScopes.filter {
            capabilities.contains($0.capability) && $0.commandIDs.contains(action.commandID)
        }
            .flatMap(\.externalApps)
        let supportedExternalAppOperations: [String: Set<String>] = [
            "com.hezongyidev.Bob": ["translate"],
            "cc.ffitch.shottr": ["capture"]
        ]
        if targets.contains(where: { target in
            guard let operations = supportedExternalAppOperations[target.bundleID] else { return true }
            return !Set(target.operationFamilies).isSubset(of: operations)
        }) { return .unavailable(.externalAppOperationUnsupported) }
        if targets.contains(where: { !externalAppExists($0.bundleID) }) { return .unavailable(.externalAppMissing) }
        if capabilities.contains(where: { !$0.isSupportedByHostServices }) { return .unavailable(.hostServiceUnavailable) }
        let permissions = package.manifest.requiredSystemPermissions(for: action.declaredCommand, input: action.input)
        if let missing = permissions.first(where: { !systemPermissionCheck($0) }) {
            return .unavailable(missing == .screenRecording ? .screenRecordingDenied : .systemPermissionDenied)
        }
        if package.manifest.hasSettings, !pluginSettingsComplete(package.manifest) {
            return .unavailable(.pluginSettingsIncomplete)
        }
        return .available
    }

    private func identityAvailability(for action: ActionConfiguration) -> ActionAvailability {
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
        guard command.matchesExecutableDefinition(action.declaredCommand) else {
            return .unavailable(.commandChanged)
        }
        return .available
    }

    /// Combines registry identity checks with an optional Host resource check.
    /// The resolver is evaluated only after the Plugin and Command are known
    /// to be available, so a stale external resource cannot hide a more
    /// specific registry failure.
    public func availability(
        for action: ActionConfiguration,
        resourceAvailability: ((ActionConfiguration) -> ActionUnavailableReason?)?
    ) -> ActionAvailability {
        let availability = availability(for: action)
        guard availability.isAvailable,
              let reason = resourceAvailability?(action) else {
            return availability
        }
        return .unavailable(reason)
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
