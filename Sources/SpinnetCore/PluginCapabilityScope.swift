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
    /// Hosts the user added to a `contact_https` scope in a Configuration
    /// Sheet, such as a self-hosted endpoint. Only the Host records them, so a
    /// manifest that declares any is rejected; they persist with the grant and
    /// are forgotten when the declared part of the scope changes.
    public let consentedHTTPSHosts: [String]

    private enum CodingKeys: String, CodingKey {
        case capability
        case commandIDs = "command_ids"
        case dataTypes = "data_types"
        case includesExistingHostData = "includes_existing_host_data"
        case httpsHosts = "https_hosts"
        case externalApps = "external_apps"
        case consentedHTTPSHosts = "consented_https_hosts"
    }

    /// One External App a Plugin may reach: operation families from the
    /// Host's Reviewed App Interface for it, sent as Apple Events, and Deep
    /// Link Templates the Plugin declares itself (ADR 0012).
    public struct ExternalAppScope: Codable, Equatable, Hashable {
        public let bundleID: String
        /// What the user knows the application as. Required with templates;
        /// a Reviewed App Interface already names its application.
        public let name: String?
        public let operationFamilies: [String]
        public let deepLinkTemplates: [DeepLinkTemplate]

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id"
            case name
            case operationFamilies = "operation_families"
            case deepLinkTemplates = "deep_link_templates"
        }

        public init(bundleID: String, name: String? = nil, operationFamilies: [String] = [],
                    deepLinkTemplates: [DeepLinkTemplate] = []) {
            self.bundleID = bundleID
            self.name = name
            self.operationFamilies = operationFamilies
            self.deepLinkTemplates = deepLinkTemplates
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                bundleID: try container.decode(String.self, forKey: .bundleID),
                name: try container.decodeIfPresent(String.self, forKey: .name),
                operationFamilies: try container.decodeIfPresent([String].self, forKey: .operationFamilies) ?? [],
                deepLinkTemplates: try container.decodeIfPresent([DeepLinkTemplate].self, forKey: .deepLinkTemplates) ?? []
            )
        }

        /// Written only with what it declares, so a scope from before Deep
        /// Link Templates is persisted, and compared, exactly as it was.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(bundleID, forKey: .bundleID)
            try container.encodeIfPresent(name, forKey: .name)
            if !operationFamilies.isEmpty { try container.encode(operationFamilies, forKey: .operationFamilies) }
            if !deepLinkTemplates.isEmpty { try container.encode(deepLinkTemplates, forKey: .deepLinkTemplates) }
        }

        /// The name guidance uses: the manifest's, else its Reviewed App
        /// Interface's, else the bundle identifier.
        public var displayName: String {
            name ?? ReviewedAppInterface.interface(for: bundleID)?.name ?? bundleID
        }
    }

    public init(capability: PluginCapability, commandIDs: [CommandID], dataTypes: [String] = [],
                includesExistingHostData: Bool = false, httpsHosts: [String] = [],
                externalApps: [ExternalAppScope] = [], consentedHTTPSHosts: [String] = []) {
        self.capability = capability
        self.commandIDs = commandIDs
        self.dataTypes = dataTypes
        self.includesExistingHostData = includesExistingHostData
        self.httpsHosts = httpsHosts
        self.externalApps = externalApps
        self.consentedHTTPSHosts = consentedHTTPSHosts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            capability: try container.decode(PluginCapability.self, forKey: .capability),
            commandIDs: try container.decode([CommandID].self, forKey: .commandIDs),
            dataTypes: try container.decode([String].self, forKey: .dataTypes),
            includesExistingHostData: try container.decode(Bool.self, forKey: .includesExistingHostData),
            httpsHosts: try container.decode([String].self, forKey: .httpsHosts),
            externalApps: try container.decode([ExternalAppScope].self, forKey: .externalApps),
            consentedHTTPSHosts: try container.decodeIfPresent([String].self, forKey: .consentedHTTPSHosts) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capability, forKey: .capability)
        try container.encode(commandIDs, forKey: .commandIDs)
        try container.encode(dataTypes, forKey: .dataTypes)
        try container.encode(includesExistingHostData, forKey: .includesExistingHostData)
        try container.encode(httpsHosts, forKey: .httpsHosts)
        try container.encode(externalApps, forKey: .externalApps)
        if !consentedHTTPSHosts.isEmpty {
            try container.encode(consentedHTTPSHosts, forKey: .consentedHTTPSHosts)
        }
    }

    /// The scope as the manifest declares it, without hosts the user added.
    public var declaredPart: PluginCapabilityScope {
        withConsentedHTTPSHosts([])
    }

    public func withConsentedHTTPSHosts(_ hosts: [String]) -> PluginCapabilityScope {
        PluginCapabilityScope(capability: capability, commandIDs: commandIDs, dataTypes: dataTypes,
                              includesExistingHostData: includesExistingHostData, httpsHosts: httpsHosts,
                              externalApps: externalApps, consentedHTTPSHosts: hosts)
    }

    /// Every host a request may reach: the declared ones, then the ones the
    /// user added.
    public var contactableHTTPSHosts: [String] {
        httpsHosts + consentedHTTPSHosts.filter { !httpsHosts.contains($0) }
    }
}

public extension PluginManifest {
    func scope(for capability: PluginCapability) -> PluginCapabilityScope? {
        capabilityScopes.first { $0.capability == capability }
    }
}
