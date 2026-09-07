import Foundation

/// Authority a Plugin must receive before the Host will perform a protected
/// operation on its behalf.
public enum PluginCapability: String, Codable, CaseIterable, Equatable, Hashable {
    case readSelectedText = "read_selected_text"
    case writeClipboard = "write_clipboard"

    public var title: String {
        switch self {
        case .readSelectedText:
            return "Read Selected Text"
        case .writeClipboard:
            return "Write Clipboard"
        }
    }

    public var explanation: String {
        switch self {
        case .readSelectedText:
            return "Lets the Plugin ask the Host for the current selected text."
        case .writeClipboard:
            return "Lets the Plugin ask the Host to replace the current clipboard text."
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

    public init(
        pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability,
        decision: PluginCapabilityGrantDecision
    ) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.capability = capability
        self.decision = decision
    }
}

/// Host-owned storage for the current user decision for each Plugin
/// Capability. The store is deliberately independent from the Plugin package
/// so revocation is observed by the next Host Service request.
public final class PluginCapabilityGrantStore {
    private let lock = NSLock()
    private var decisions: [PluginID: [String: [PluginCapability: PluginCapabilityGrantDecision]]] = [:]

    public init(grants: [PluginCapabilityGrant] = []) {
        for grant in grants {
            decisions[grant.pluginID, default: [:]][grant.pluginVersion, default: [:]][grant.capability] = grant.decision
        }
    }

    public func decision(
        for pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability
    ) -> PluginCapabilityGrantDecision {
        lock.lock()
        defer { lock.unlock() }
        return decisions[pluginID]?[pluginVersion]?[capability] ?? .notDetermined
    }

    public func setDecision(
        _ decision: PluginCapabilityGrantDecision,
        for pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability
    ) {
        lock.lock()
        decisions[pluginID, default: [:]][pluginVersion, default: [:]][capability] = decision
        lock.unlock()
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
                            decision: decision
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
            return "Lets Spinnet intercept the configured Side Button and read selected text for an authorized Plugin."
        }
    }
}

/// A narrow operation exposed by the Host to a Plugin helper.
public enum PluginHostService: String, Codable, CaseIterable, Equatable, Hashable {
    case readSelectedText = "read_selected_text"
    case writeClipboard = "write_clipboard"

    public var requiredCapability: PluginCapability {
        switch self {
        case .readSelectedText:
            return .readSelectedText
        case .writeClipboard:
            return .writeClipboard
        }
    }

    public var requiredSystemPermission: PluginSystemPermission? {
        switch self {
        case .readSelectedText:
            return .accessibility
        case .writeClipboard:
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

/// Default broker for the two MVP Host Services. Every request checks the
/// current manifest declaration, current user grant, and current System
/// Permission before touching a protected Host provider.
public final class CapabilityCheckedHostServiceBroker: PluginHostServiceBroker {
    private let grantStore: PluginCapabilityGrantStore
    private let systemPermissionCheck: (PluginSystemPermission) -> Bool
    private let selectedTextProvider: () throws -> String
    private let clipboardWriter: (String) throws -> Void

    public init(
        grantStore: PluginCapabilityGrantStore,
        systemPermissionCheck: @escaping (PluginSystemPermission) -> Bool,
        selectedTextProvider: @escaping () throws -> String,
        clipboardWriter: @escaping (String) throws -> Void
    ) {
        self.grantStore = grantStore
        self.systemPermissionCheck = systemPermissionCheck
        self.selectedTextProvider = selectedTextProvider
        self.clipboardWriter = clipboardWriter
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
        guard package.manifest.capabilities.contains(capability),
              grantStore.decision(
                  for: package.manifest.id,
                  pluginVersion: package.manifest.version,
                  capability: capability
              ) == .granted else {
            throw PluginHostServiceError.capabilityDenied(capability)
        }

        if let permission = service.requiredSystemPermission,
           !systemPermissionCheck(permission) {
            throw PluginHostServiceError.systemPermissionDenied(permission)
        }

        switch service {
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
