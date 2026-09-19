import Foundation

public extension CommandConfigurationField {
    /// The host of an `https_endpoint` value: an absolute https URL without a
    /// user name, query, fragment, or port other than 443.
    static func httpsEndpointHost(_ value: JSONValue) -> String? {
        // An endpoint is a base address, so it also carries no query or fragment.
        guard case .string(let text) = value, let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              url.query == nil, url.fragment == nil else { return nil }
        return HTTPSDestination.host(of: url)
    }
}

public extension CommandDeclaration {
    /// Hosts named by this Command's `https_endpoint` fields in a configured input.
    func configuredEndpointHosts(in input: JSONValue) -> [String] {
        guard case .object(let members) = input else { return [] }
        return configurationFields.filter { $0.kind == .httpsEndpoint }.compactMap { field in
            field.key.flatMap { members[$0] }.flatMap(CommandConfigurationField.httpsEndpointHost)
        }
    }
}

public extension PluginManifest {
    /// Hosts named by a Command's input: its own `https_endpoint` fields and
    /// the Plugin's `https_endpoint` settings in use, which reach every
    /// Command. An endpoint whose `used_when` is not met is never contacted.
    func configuredEndpointHosts(for command: CommandDeclaration, in input: JSONValue) -> [String] {
        guard case .object(let members) = input else { return [] }
        let settings = settingsFields.filter { $0.kind == .httpsEndpoint && $0.isUsed(by: members) }.compactMap { field in
            field.key.flatMap { members[$0] }.flatMap(CommandConfigurationField.httpsEndpointHost)
        }
        return command.configuredEndpointHosts(in: input) + settings
    }
}

/// The consent a Configuration Sheet needs before it saves an endpoint whose
/// host the Plugin did not declare, such as a self-hosted server.
///
/// Only Commands in the `contact_https` scope count: their configured
/// `https_endpoint` fields are endpoints. A host outside the declared hosts
/// and outside the hosts the user already added must be disclosed and
/// explicitly allowed, and the allowance joins the Plugin's contact scope
/// (ADR 0008).
public struct HTTPSEndpointConsent {
    public let manifest: PluginManifest
    /// Hosts that need the user's consent, in the order they were configured.
    public let newHosts: [String]

    public init(manifest: PluginManifest, inputs: [CommandID: JSONValue], grantStore: PluginCapabilityGrantStore) {
        self.manifest = manifest
        guard let declared = manifest.scope(for: .contactHTTPS) else {
            newHosts = []
            return
        }
        let known = declared.withConsentedHTTPSHosts(grantStore.consentedHTTPSHosts(
            for: manifest.id, pluginVersion: manifest.version, declaredScope: declared
        )).contactableHTTPSHosts
        var hosts: [String] = []
        for command in manifest.commands where declared.commandIDs.contains(command.id) {
            guard let input = inputs[command.id] else { continue }
            for host in manifest.configuredEndpointHosts(for: command, in: input)
            where !known.contains(host) && !hosts.contains(host) {
                hosts.append(host)
            }
        }
        newHosts = hosts
    }

    /// The sentence the Configuration Sheet shows beside the consent control.
    public var disclosure: String {
        "\(manifest.name) will send its requests, including the text its Commands work on and any credential you entered, to "
            + newHosts.joined(separator: ", ") + ", which the Plugin did not declare."
    }

    /// Records the consent, or refuses the save when it was not given for
    /// every new host. Consent names hosts, not a yes: allowing one host must
    /// not carry over to another the endpoint was edited to afterwards.
    public func approve(allowedHosts: Set<String>, grantStore: PluginCapabilityGrantStore) throws {
        guard !newHosts.isEmpty, let declared = manifest.scope(for: .contactHTTPS) else { return }
        guard Set(newHosts).isSubset(of: allowedHosts) else {
            throw ConfigurationError.invalidAction(
                "Allow \(manifest.name) to contact \(newHosts.joined(separator: ", ")) before saving."
            )
        }
        let existing = grantStore.consentedHTTPSHosts(for: manifest.id, pluginVersion: manifest.version, declaredScope: declared)
        grantStore.setConsentedHTTPSHosts(existing + newHosts, for: manifest.id,
                                          pluginVersion: manifest.version, declaredScope: declared)
    }
}
