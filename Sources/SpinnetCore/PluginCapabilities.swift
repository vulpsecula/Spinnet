import Foundation

/// Authority a Plugin must receive before the Host will perform a protected
/// operation on its behalf.
public enum PluginCapability: String, Codable, CaseIterable, Equatable, Hashable {
    case readSelectedText = "read_selected_text"
    case writeClipboard = "write_clipboard"
    case readCurrentClipboard = "read_current_clipboard"
    case readClipboardHistory = "read_clipboard_history"
    case monitorClipboard = "monitor_clipboard"
    case contactHTTPS = "contact_https"
    case controlExternalApp = "control_external_app"

    public var isSupportedByHostServices: Bool {
        [.readSelectedText, .writeClipboard, .readCurrentClipboard, .readClipboardHistory].contains(self)
    }

    public var title: String {
        switch self {
        case .readSelectedText:
            return "Read Selected Text"
        case .writeClipboard:
            return "Write Clipboard"
        case .readCurrentClipboard: return "Read Current Clipboard"
        case .readClipboardHistory: return "Read Clipboard History"
        case .monitorClipboard: return "Monitor Clipboard"
        case .contactHTTPS: return "Contact HTTPS Hosts"
        case .controlExternalApp: return "Control External Apps"
        }
    }

    public var explanation: String {
        switch self {
        case .readSelectedText:
            return "Lets the Plugin ask the Host for the current selected text."
        case .writeClipboard:
            return "Lets the Plugin ask the Host to replace the current clipboard text."
        case .readCurrentClipboard: return "Read the declared data types from the current clipboard."
        case .readClipboardHistory: return "Read declared data types, including retained entries collected before this grant."
        case .monitorClipboard: return "Requires separate Host Sensitive Data Collection opt-in."
        case .contactHTTPS: return "Contact only the declared HTTPS hosts through Host Services."
        case .controlExternalApp: return "Request only the named External Apps and operation families."
        }
    }
}

/// The Host keeps an explicit decision instead of treating an absent entry as
/// an implicit grant. This lets a later Settings surface distinguish a new
/// request from an intentional denial.
public enum PluginCapabilityGrantDecision: String, Codable, CaseIterable, Equatable, Hashable {
    case notDetermined = "not_determined"
    case denied
    case granted

    public var title: String {
        switch self {
        case .notDetermined:
            return "Not Determined"
        case .denied:
            return "Denied"
        case .granted:
            return "Granted"
        }
    }
}

public struct PluginCapabilityGrant: Codable, Equatable, Hashable {
    public let pluginID: PluginID
    public let pluginVersion: String
    public let capability: PluginCapability
    public let decision: PluginCapabilityGrantDecision
    public let scope: PluginCapabilityScope?

    public init(
        pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability,
        decision: PluginCapabilityGrantDecision,
        scope: PluginCapabilityScope? = nil
    ) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.capability = capability
        self.decision = decision
        self.scope = scope
    }
}

/// Host-owned storage for the current user decision for each Plugin
/// Capability. The store is deliberately independent from the Plugin package
/// so revocation is observed by the next Host Service request.
public final class PluginCapabilityGrantStore {
    private let lock = NSLock()
    private var decisions: [PluginID: [String: [PluginCapability: PluginCapabilityGrantDecision]]] = [:]
    private var scopes: [PluginID: [String: [PluginCapability: PluginCapabilityScope]]] = [:]

    private var revocationObservers: [UUID: (PluginID) -> Void] = [:]
    private var changeObservers: [UUID: () -> Void] = [:]

    public func observeChanges(_ observer: @escaping () -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    public func removeChangeObserver(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        changeObservers.removeValue(forKey: token)
    }

    /// Observers retire helpers synchronously and must not reenter this store.
    public func observeRevocation(_ observer: @escaping (PluginID) -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        revocationObservers[token] = observer
        return token
    }

    public func removeRevocationObserver(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        revocationObservers.removeValue(forKey: token)
    }

    public init(grants: [PluginCapabilityGrant] = []) {
        for grant in grants {
            decisions[grant.pluginID, default: [:]][grant.pluginVersion, default: [:]][grant.capability] = grant.decision
            scopes[grant.pluginID, default: [:]][grant.pluginVersion, default: [:]][grant.capability] = grant.scope
        }
    }

    /// Inherit decisions only for the same Plugin and identical Capability
    /// scope. Snapshot first because an update may reuse its version string.
    public func prepareInstallation(of manifest: PluginManifest, replacing previous: PluginManifest?) {
        let inherited = manifest.capabilities.map { capability -> PluginCapabilityGrant in
            let scope = manifest.scope(for: capability)
            let decision: PluginCapabilityGrantDecision
            if let previous, previous.id == manifest.id,
               previous.capabilities.contains(capability), previous.scope(for: capability) == scope {
                decision = self.decision(for: previous.id, pluginVersion: previous.version,
                                         capability: capability, scope: scope)
            } else {
                decision = .notDetermined
            }
            return PluginCapabilityGrant(pluginID: manifest.id, pluginVersion: manifest.version,
                                         capability: capability, decision: decision, scope: scope)
        }
        for grant in inherited {
            setDecision(grant.decision, for: grant.pluginID, pluginVersion: grant.pluginVersion,
                        capability: grant.capability, scope: grant.scope)
        }
    }

    public func decision(
        for pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability,
        scope: PluginCapabilityScope? = nil
    ) -> PluginCapabilityGrantDecision {
        lock.lock()
        defer { lock.unlock() }
        guard scopes[pluginID]?[pluginVersion]?[capability] == scope else { return .notDetermined }
        return decisions[pluginID]?[pluginVersion]?[capability] ?? .notDetermined
    }

    public func setDecision(
        _ decision: PluginCapabilityGrantDecision,
        for pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability,
        scope: PluginCapabilityScope? = nil
    ) {
        lock.lock()
        let previous = decisions[pluginID]?[pluginVersion]?[capability]
        let previousScope = scopes[pluginID]?[pluginVersion]?[capability]
        decisions[pluginID, default: [:]][pluginVersion, default: [:]][capability] = decision
        scopes[pluginID, default: [:]][pluginVersion, default: [:]][capability] = scope
        if previous == .granted && (decision != .granted || previousScope != scope) {
            for observer in revocationObservers.values { observer(pluginID) }
        }
        let observers = Array(changeObservers.values)
        lock.unlock()
        observers.forEach { $0() }
    }

    /// Registers every declared Capability without changing an existing user
    /// decision. New entries remain explicitly `notDetermined` so a settings
    /// surface can present the complete scope requested by a Plugin.
    public func register(
        pluginID: PluginID,
        pluginVersion: String,
        capabilities: [PluginCapability]
    ) {
        lock.lock()
        var pluginVersions = decisions[pluginID, default: [:]]
        var pluginDecisions = pluginVersions[pluginVersion, default: [:]]
        for capability in capabilities {
            if pluginDecisions[capability] == nil {
                pluginDecisions[capability] = .notDetermined
            }
        }
        pluginVersions[pluginVersion] = pluginDecisions
        decisions[pluginID] = pluginVersions
        lock.unlock()
    }

    /// Returns every requested Capability in the supplied order, including
    /// Capabilities with no prior decision.
    public func grants(
        for pluginID: PluginID,
        pluginVersion: String,
        capabilities: [PluginCapability]
    ) -> [PluginCapabilityGrant] {
        register(
            pluginID: pluginID,
            pluginVersion: pluginVersion,
            capabilities: capabilities
        )
        return capabilities.map {
            PluginCapabilityGrant(
                pluginID: pluginID,
                pluginVersion: pluginVersion,
                capability: $0,
                decision: decision(
                    for: pluginID,
                    pluginVersion: pluginVersion,
                    capability: $0
                )
            )
        }
    }

    /// A stable snapshot suitable for persistence by a Host settings layer.
    public var allGrants: [PluginCapabilityGrant] {
        lock.lock()
        defer { lock.unlock() }
        return decisions
            .flatMap { pluginID, versions in
                versions.flatMap { pluginVersion, capabilities in
                    capabilities.map { capability, decision in
                        PluginCapabilityGrant(
                            pluginID: pluginID,
                            pluginVersion: pluginVersion,
                            capability: capability,
                            decision: decision,
                            scope: scopes[pluginID]?[pluginVersion]?[capability]
                        )
                    }
                }
            }
            .sorted {
                if $0.pluginID != $1.pluginID {
                    return $0.pluginID.rawValue < $1.pluginID.rawValue
                }
                if $0.pluginVersion != $1.pluginVersion {
                    return $0.pluginVersion < $1.pluginVersion
                }
                return $0.capability.rawValue < $1.capability.rawValue
            }
    }
}

/// System authority that may be required in addition to a user-granted
/// Plugin Capability.
public enum PluginSystemPermission: String, Codable, CaseIterable, Equatable, Hashable {
    case accessibility

    public var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        }
    }

    public var explanation: String {
        switch self {
        case .accessibility:
            return "Lets Spinnet intercept the configured Side Button, read selected text, and send keyboard actions such as Paste or Cut."
        }
    }
}

/// A narrow operation exposed by the Host to a Plugin helper.
public enum PluginHostService: String, Codable, CaseIterable, Equatable, Hashable {
    case readSelectedText = "read_selected_text"
    case writeClipboard = "write_clipboard"
    case readCurrentClipboard = "read_current_clipboard"
    case readClipboardHistory = "read_clipboard_history"

    public var requiredCapability: PluginCapability {
        switch self {
        case .readSelectedText:
            return .readSelectedText
        case .readCurrentClipboard: return .readCurrentClipboard
        case .readClipboardHistory: return .readClipboardHistory
        case .writeClipboard:
            return .writeClipboard
        }
    }

    public var requiredSystemPermission: PluginSystemPermission? {
        switch self {
        case .readSelectedText:
            return .accessibility
        case .writeClipboard, .readCurrentClipboard, .readClipboardHistory:
            return nil
        }
    }
}

public enum PluginHostServiceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case capabilityDenied(PluginCapability)
    case systemPermissionDenied(PluginSystemPermission)
    case invalidInput(String)
    case unavailable(String)
    case failed(String)

    public var description: String {
        switch self {
        case .capabilityDenied(let capability):
            return "Capability \(capability.rawValue) is not granted"
        case .systemPermissionDenied(let permission):
            return "System Permission \(permission.rawValue) is not granted"
        case .invalidInput(let message):
            return "Host Service input is invalid: \(message)"
        case .unavailable(let message):
            return "Host Service is unavailable: \(message)"
        case .failed(let message):
            return "Host Service failed: \(message)"
        }
    }

    public var errorDescription: String? { description }

    public var runtimeFailureCategory: PluginRuntimeFailureCategory {
        switch self {
        case .capabilityDenied:
            return .capabilityDenied
        case .systemPermissionDenied:
            return .systemPermissionDenied
        case .invalidInput, .unavailable, .failed:
            return .hostServiceFailed
        }
    }

    public var actionFailureCategory: ActionFailureCategory {
        switch self {
        case .capabilityDenied:
            return .capabilityDenied
        case .systemPermissionDenied:
            return .systemPermissionDenied
        case .invalidInput, .unavailable, .failed:
            return .hostServiceFailed
        }
    }
}

/// The Host-side seam used to broker a validated Plugin request. The package
/// supplies the connection-bound Plugin identity; a helper request does not.
public protocol PluginHostServiceBroker {
    func execute(
        request: PluginRuntimeHostServiceRequest,
        for package: PluginPackage,
        action: ActionConfiguration
    ) throws -> JSONValue
}

/// Broker for public Host Services. Every request checks the
/// current manifest declaration, current user grant, and current System
/// Permission before touching a protected Host provider.
public final class CapabilityCheckedHostServiceBroker: PluginHostServiceBroker {
    private let grantStore: PluginCapabilityGrantStore
    private let systemPermissionCheck: (PluginSystemPermission) -> Bool
    private let selectedTextProvider: () throws -> String
    private let clipboardWriter: (String) throws -> Void
    private let currentClipboardProvider: () throws -> ClipboardContent?
    private let clipboardHistoryProvider: ([String], Int) throws -> ClipboardHistorySnapshot
    private let clipboardHistoryPresenter: (PluginPackage, ActionConfiguration) -> Void

    public init(
        grantStore: PluginCapabilityGrantStore,
        systemPermissionCheck: @escaping (PluginSystemPermission) -> Bool,
        selectedTextProvider: @escaping () throws -> String,
        clipboardWriter: @escaping (String) throws -> Void,
        currentClipboardProvider: @escaping () throws -> ClipboardContent? = { nil },
        clipboardHistoryProvider: @escaping ([String], Int) throws -> ClipboardHistorySnapshot = { _, _ in
            throw PluginHostServiceError.unavailable("Clipboard History")
        },
        clipboardHistoryPresenter: @escaping (PluginPackage, ActionConfiguration) -> Void = { _, _ in }
    ) {
        self.grantStore = grantStore
        self.systemPermissionCheck = systemPermissionCheck
        self.selectedTextProvider = selectedTextProvider
        self.clipboardWriter = clipboardWriter
        self.currentClipboardProvider = currentClipboardProvider
        self.clipboardHistoryProvider = clipboardHistoryProvider
        self.clipboardHistoryPresenter = clipboardHistoryPresenter
    }

    public func execute(
        request: PluginRuntimeHostServiceRequest,
        for package: PluginPackage,
        action: ActionConfiguration
    ) throws -> JSONValue {
        grantStore.register(
            pluginID: package.manifest.id,
            pluginVersion: package.manifest.version,
            capabilities: package.manifest.capabilities
        )
        let service = request.service
        let capability = service.requiredCapability
        guard package.manifest.id == action.pluginID,
              package.manifest.commands.contains(where: { $0.matchesExecutableDefinition(action.declaredCommand) }),
              package.manifest.requiredCapabilities(for: action.declaredCommand, input: action.input).contains(capability),
              package.manifest.declares(capability, for: action.commandID),
              grantStore.decision(
                  for: package.manifest.id,
                  pluginVersion: package.manifest.version,
                  capability: capability,
                  scope: package.manifest.scope(for: capability)
              ) == .granted else {
            throw PluginHostServiceError.capabilityDenied(capability)
        }

        if let permission = service.requiredSystemPermission,
           !systemPermissionCheck(permission) {
            throw PluginHostServiceError.systemPermissionDenied(permission)
        }

        switch service {
        case .readCurrentClipboard:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("read_current_clipboard expects null")
            }
            guard let content = try currentClipboardProvider(),
                  package.manifest.scope(for: capability)?.dataTypes.contains(content.type.rawValue) == true else { return .null }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(content))
        case .readClipboardHistory:
            let present = request.input == .object(["present": .bool(true)])
            var offset = 0
            if case .object(let fields) = request.input, fields.count == 1,
               case .number(let value) = fields["offset"], value >= 0, value <= Double(Int.max / 2), value.rounded() == value {
                offset = Int(value)
            } else if request.input != .null && !present {
                throw PluginHostServiceError.invalidInput("Expected null, {present: true}, or a nonnegative integer offset")
            }
            let snapshot = try clipboardHistoryProvider(package.manifest.scope(for: capability)?.dataTypes ?? [], offset)
            if present { clipboardHistoryPresenter(package, action) }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot))
        case .readSelectedText:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("read_selected_text expects null")
            }
            return .string(try selectedTextProvider())
        case .writeClipboard:
            guard case .string(let text) = request.input else {
                throw PluginHostServiceError.invalidInput(
                    "write_clipboard expects a text string"
                )
            }
            try clipboardWriter(text)
            return .null
        }
    }
}
