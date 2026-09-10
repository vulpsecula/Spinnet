import Foundation

/// Concrete scope displayed by the Host. Scope equality is part of a grant,
/// so changing a target or data category invalidates the old decision.
public struct PluginCapabilityScope: Codable, Equatable, Hashable {
    public let capability: PluginCapability
    public let commandIDs: [CommandID]
    public let dataTypes: [String]
    public let includesExistingHostData: Bool
    public let httpsHosts: [String]
    public let externalApps: [ExternalAppScope]

    private enum CodingKeys: String, CodingKey {
        case capability
        case commandIDs = "command_ids"
        case dataTypes = "data_types"
        case includesExistingHostData = "includes_existing_host_data"
        case httpsHosts = "https_hosts"
        case externalApps = "external_apps"
    }

    public struct ExternalAppScope: Codable, Equatable, Hashable {
        public let bundleID: String
        public let operationFamilies: [String]

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id"
            case operationFamilies = "operation_families"
        }

        public init(bundleID: String, operationFamilies: [String]) {
            self.bundleID = bundleID
            self.operationFamilies = operationFamilies
        }
    }

    public init(capability: PluginCapability, commandIDs: [CommandID], dataTypes: [String] = [],
                includesExistingHostData: Bool = false, httpsHosts: [String] = [],
                externalApps: [ExternalAppScope] = []) {
        self.capability = capability
        self.commandIDs = commandIDs
        self.dataTypes = dataTypes
        self.includesExistingHostData = includesExistingHostData
        self.httpsHosts = httpsHosts
        self.externalApps = externalApps
    }
}

public extension PluginManifest {
    func scope(for capability: PluginCapability) -> PluginCapabilityScope? {
        capabilityScopes.first { $0.capability == capability }
    }
}
