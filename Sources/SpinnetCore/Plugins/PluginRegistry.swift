import Foundation

public enum ActionUnavailableReason: Equatable, Hashable, CustomStringConvertible {
    case pluginMissing
    case pluginDisabled
    /// The Plugin is a Refused Plugin: installed, but not loaded at launch,
    /// such as an incompatible Host range or obsolete declaration. It holds
    /// the reason, which is what the user sees.
    case pluginRefused(String)
    case commandMissing
    case commandChanged
    case resourceMissing
    /// The External App the Command reaches is not installed. It holds the
    /// application's name as the manifest, or its Reviewed App Interface,
    /// gives it.
    case externalAppMissing(String)
    case externalAppOperationUnsupported
    case externalAppConnectionRequired(String)
    case externalAppNotRunning(String)
    case capabilityDenied
    case systemPermissionDenied
    case hostServiceUnavailable
    /// The Screen Recording System Permission is missing. Accessibility keeps
    /// `systemPermissionDenied`, so each permission names its own repair.
    case screenRecordingDenied
    /// The Screenshot save folder is gone, is not a folder, or cannot be
    /// written, and the Screenshot Plugin Settings say to save.
    case saveFolderUnavailable
    /// The Plugin declares settings and one still has no usable value.
    case pluginSettingsIncomplete

    public var description: String {
        switch self {
        case .pluginMissing: return "Plugin is not registered"
        case .pluginDisabled: return "Plugin is disabled"
        case .pluginRefused(let reason): return reason
        case .commandMissing: return "Command is no longer registered"
        case .commandChanged: return "Command definition changed"
        case .resourceMissing: return "Referenced resource is missing"
        case .externalAppMissing(let application): return "Install \(application) to use \(application) Commands"
        case .externalAppConnectionRequired(let app): return "Connect \(app) in Plugin Settings"
        case .externalAppNotRunning(let app): return "Start \(app) to use its Commands"
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
        command: CommandDeclaration? = nil,
        applicationExists: ((String) -> Bool)? = nil
    ) -> ActionUnavailableReason? {
        guard action.execution == .host else { return nil }
        if let id = action.hostServiceID, let operation = HostServiceCatalogue.operation(id) {
            let declaration = command ?? action.declaredCommand
            let input = operation.commandInput(for: declaration, actionInput: action.input)
            switch id {
            case "open.application":
                guard let value = stringValue(in: input, keys: ["application"]) else { return nil }
                return resourceExists(kind: .application, value: value, applicationExists: applicationExists)
                    ? nil : .resourceMissing
            case "open.path":
                guard let value = stringValue(in: input, keys: ["path"]) else { return nil }
                let kind = declaration.configurationField?.kind
                    ?? declaration.configurationFields.first(where: { $0.key == "path" })?.kind
                if let kind, kind == .file || kind == .folder {
                    return resourceExists(kind: kind, value: value) ? nil : .resourceMissing
                }
                // A generic open.path Command intentionally accepts either kind.
                return FileManager.default.fileExists(atPath: fileURL(for: value).path) ? nil : .resourceMissing
            default:
                return nil
            }
        }
        guard let hostCommand = action.hostCommand else { return nil }

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

/// Opaque identity of one enabled Plugin registration. Replacement and
/// disable rotate it even when package content/version do not change.
public struct PluginOwnerAdmission: Hashable {
    let pluginID: PluginID
    let identity: UUID
}

public final class PluginRegistry {
    private let lock = NSLock()
    private var packages: [PluginID: PluginPackage] = [:]
    private var disabledPluginIDs: Set<PluginID> = []
    /// The Refused Plugins: installed Plugins a launch did not load.
    private var refused: [PluginID: RefusedPlugin] = [:]
    /// What this Host offers Plugins; every registration is checked against it.
    public let contracts: PluginInterfaceContracts
    private var invalidationObservers: [UUID: (PluginID) -> Void] = [:]
    private var ownerAdmissions: [PluginID: UUID] = [:]

    public func ownerAdmission(for pluginID: PluginID) -> PluginOwnerAdmission? {
        lock.lock(); defer { lock.unlock() }
        guard packages[pluginID] != nil, !disabledPluginIDs.contains(pluginID), let identity = ownerAdmissions[pluginID] else { return nil }
        return PluginOwnerAdmission(pluginID: pluginID, identity: identity)
    }

    public func isCurrent(_ admission: PluginOwnerAdmission, for package: PluginPackage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard admission.pluginID == package.manifest.id,
              ownerAdmissions[admission.pluginID] == admission.identity,
              !disabledPluginIDs.contains(admission.pluginID), let current = packages[admission.pluginID] else { return false }
        return current.rootURL == package.rootURL && current.manifest == package.manifest
    }

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
        ownerAdmissions[pluginID] = nil
        disabledPluginIDs.remove(pluginID)
        refused.removeValue(forKey: pluginID)
        for observer in invalidationObservers.values { observer(pluginID) }
    }

    private let grantStore: PluginCapabilityGrantStore?
    private let systemPermissionCheck: (PluginSystemPermission) -> Bool
    private let externalAppExists: (String) -> Bool
    private let pluginSettingsComplete: (PluginManifest) -> Bool
    private let connectionStatusProvider: (ExternalAppConnectionCheck) -> ExternalAppConnectionStatus

    public init(
        contracts: PluginInterfaceContracts = .host,
        grantStore: PluginCapabilityGrantStore? = nil,
        systemPermissionCheck: @escaping (PluginSystemPermission) -> Bool = { _ in true },
        externalAppExists: @escaping (String) -> Bool = { _ in false },
        pluginSettingsComplete: @escaping (PluginManifest) -> Bool = { _ in true },
        externalAppConnectionStatus: @escaping (ExternalAppConnectionCheck) -> ExternalAppConnectionStatus = { _ in .permissionNeeded }
    ) {
        self.contracts = contracts
        self.grantStore = grantStore
        self.systemPermissionCheck = systemPermissionCheck
        self.externalAppExists = externalAppExists
        self.pluginSettingsComplete = pluginSettingsComplete
        self.connectionStatusProvider = externalAppConnectionStatus
    }

    @discardableResult
    public func register(packageAt rootURL: URL) throws -> PluginManifest {
        let package = try PluginManifestLoader.load(packageAt: rootURL)
        try register(package)
        return package.manifest
    }

    public func register(_ package: PluginPackage) throws {
        try package.manifest.validate()
        try contracts.check(package.manifest)

        lock.lock()
        defer { lock.unlock() }

        guard packages[package.manifest.id] == nil else {
            throw ConfigurationError.invalidManifest(
                "duplicate plugin id \(package.manifest.id.rawValue)"
            )
        }

        packages[package.manifest.id] = package
        ownerAdmissions[package.manifest.id] = UUID()
        refused.removeValue(forKey: package.manifest.id)
    }

    /// Records an installed Plugin a launch did not load. Its Actions then
    /// report its reason rather than a Plugin that is gone.
    public func recordRefused(_ plugin: RefusedPlugin) {
        lock.lock()
        defer { lock.unlock() }
        guard packages[plugin.id] == nil else { return }
        refused[plugin.id] = plugin
    }

    /// The Refused Plugins, by ID.
    public func refusedPlugins() -> [RefusedPlugin] {
        lock.lock()
        defer { lock.unlock() }
        return refused.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// The Refused Plugin with `pluginID`, if a launch refused it.
    public func refusedPlugin(_ pluginID: PluginID) -> RefusedPlugin? {
        lock.lock()
        defer { lock.unlock() }
        return refused[pluginID]
    }

    public func replace(_ package: PluginPackage) throws {
        try package.manifest.validate()
        try contracts.check(package.manifest)

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
        ownerAdmissions[package.manifest.id] = UUID()
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
            ownerAdmissions[pluginID] = UUID()
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
                    declaration: package.manifest.preset,
                    unavailableReason: disabledPluginIDs.contains(package.manifest.id)
                        ? .pluginDisabled
                        : nil,
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
        guard identity.isAvailable else { return identity }
        for check in externalAppConnectionChecks(for: action.pluginID) where check.declaration.commandIDs.contains(action.commandID) {
            let status = externalAppConnectionStatus(for: check)
            switch status {
            case .ready: break
            case .notRunning, .notRunningUnchecked: return .unavailable(.externalAppNotRunning(check.interface.name))
            case .notInstalled: return .unavailable(.externalAppMissing(check.interface.name))
            case .capabilityDenied: return .unavailable(.capabilityDenied)
            case .ownerInvalid: return .unavailable(.pluginDisabled)
            default: return .unavailable(.externalAppConnectionRequired(check.interface.name))
            }
        }
        guard let grantStore, let package = package(for: action.pluginID) else { return identity }
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
        // Operation families need a Reviewed App Interface that offers them;
        // Deep Link Templates need nothing the Host has reviewed.
        if targets.contains(where: { target in
            guard !target.operationFamilies.isEmpty else { return false }
            guard let interface = ReviewedAppInterface.interface(for: target.bundleID) else { return true }
            return !Set(target.operationFamilies).isSubset(of: interface.operations.map(\.family))
        }) { return .unavailable(.externalAppOperationUnsupported) }
        if let missingTarget = targets.first(where: { !externalAppExists($0.bundleID) }) {
            return .unavailable(.externalAppMissing(missingTarget.displayName))
        }
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
            if let plugin = refused[action.pluginID] { return .unavailable(.pluginRefused(plugin.reason)) }
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
        guard availability.isAvailable, let resourceAvailability else { return availability }
        let command = package(for: action.pluginID)?.manifest.commands.first { $0.id == action.commandID }
        if let reason = ActionResourceAvailability.missingReason(for: action, command: command) {
            return .unavailable(reason)
        }
        // Saved Actions retain identity and user input, while fixed targets and
        // picker kinds belong to the current declaration. Resolve the same input
        // execution uses before the Host checks App bundle IDs or other resources.
        var resolved = action
        if let command, let operation = command.hostServiceID.flatMap(HostServiceCatalogue.operation),
           let prepared = try? ActionConfiguration(id: action.id, pluginID: action.pluginID, command: command,
               input: operation.commandInput(for: command, actionInput: action.input)) {
            resolved = prepared
        }
        return resourceAvailability(resolved).map(ActionAvailability.unavailable) ?? availability
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


extension PluginRegistry {
    /// Capture metadata and registration identity together. Native providers are
    /// deliberately called after releasing the registry lock.
    public func externalAppConnectionChecks(for pluginID: PluginID) -> [ExternalAppConnectionCheck] {
        lock.lock(); defer { lock.unlock() }
        guard let package = packages[pluginID], !disabledPluginIDs.contains(pluginID),
              let owner = ownerAdmissions[pluginID] else { return [] }
        return package.manifest.externalAppConnections.compactMap { declaration in
            guard let interface = ReviewedAppInterface.interface(for: declaration.bundleID),
                  let name = interface.connectionCheckOperation,
                  let operation = interface.operations.first(where: { $0.name == name && $0.parameters.isEmpty }) else { return nil }
            return ExternalAppConnectionCheck(package: package,
                admission: PluginOwnerAdmission(pluginID: pluginID, identity: owner),
                declaration: declaration, interface: interface, operation: operation)
        }
    }

    /// Authority only, with no native I/O and no System Permission prompt.
    public func externalAppConnectionAuthorization(for check: ExternalAppConnectionCheck) -> ActionAvailability {
        guard isCurrent(check.admission, for: check.package),
              check.package.manifest.externalAppConnections.contains(check.declaration),
              (try? contracts.check(check.package.manifest)) != nil else {
            return .unavailable(.pluginDisabled)
        }
        let manifest = check.package.manifest
        guard let grantStore, check.declaration.commandIDs.allSatisfy({
            grantStore.isGranted(.controlExternalApp, for: $0, in: manifest)
        }) else { return .unavailable(.capabilityDenied) }
        return .available
    }

    public func externalAppConnectionStatus(for check: ExternalAppConnectionCheck) -> ExternalAppConnectionStatus {
        func refusal() -> ExternalAppConnectionStatus? {
            let authorization = externalAppConnectionAuthorization(for: check)
            guard !authorization.isAvailable else { return nil }
            return authorization.reason == .capabilityDenied ? .capabilityDenied : .ownerInvalid
        }
        if let failure = refusal() { return failure }
        let status = connectionStatusProvider(check)
        return refusal() ?? status
    }

    /// Configuration checks accept an authorized but stopped App; runtime
    /// availability additionally requires it to be running. Existing Menu Items
    /// may still be edited when a connection is revoked.
    public func externalAppConnectionPlacementAvailability(for pluginID: PluginID,
                                                            commandIDs: [CommandID]) -> ActionAvailability {
        guard isEnabled(for: pluginID) else { return .unavailable(.pluginDisabled) }
        for check in externalAppConnectionChecks(for: pluginID)
            where !Set(check.declaration.commandIDs).isDisjoint(with: commandIDs) {
            let status = externalAppConnectionStatus(for: check)
            guard !status.isConnected else { continue }
            if status == .capabilityDenied { return .unavailable(.capabilityDenied) }
            if status == .ownerInvalid { return .unavailable(.pluginDisabled) }
            if status == .notInstalled { return .unavailable(.externalAppMissing(check.interface.name)) }
            return .unavailable(.externalAppConnectionRequired(check.interface.name))
        }
        return .available
    }
}
