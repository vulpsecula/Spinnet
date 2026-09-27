import Foundation
import SpinnetCore

/// Sends the Host-Fetched Sections of a Plugin View the way the Host sends
/// them, with recorded responses in place of the network, and reads what
/// each section shows (ADR 0010).
///
/// Every request goes through the Host's own broker, so it is held to the
/// Host's rules: the Command must declare `contact_https`, the destination
/// must be a host the manifest declares or the test consented to, the
/// Plugin's Credential Uses are applied from the recorded secrets, and a
/// section with `cache` is answered again from its last 2xx answer. Every
/// Capability the Plugin declares counts as granted unless the test denies it.
public final class RecordedHostFetchedSections {
    /// One fetched section once its request was sent and answered.
    public struct Section: Equatable {
        public let id: String
        public let title: String?
        /// For `show`, the answer the Host extracts or why there is none; for
        /// `deliver`, loading until the script answers `delivery`, or why no
        /// response arrived.
        public let state: HostFetchedSectionState
        /// For a `deliver` section that got a response, the
        /// `section_delivered` event the Host hands the script.
        public let delivery: PluginViewEvent?
    }

    /// What each host answers, by host name. A host without an answer
    /// cannot be reached.
    public var responses: [String: HTTPSTransportResponse]
    /// Secrets by credential reference, as the user stored them.
    public var credentials: [String: String]
    /// Hosts beyond the manifest's own that the user consented to contact.
    public var consentedHosts: [String]
    /// Declared Capabilities the user refused.
    public var deniedCapabilities: Set<PluginCapability> = []
    /// The answers kept for sections with `cache`, across `fetch` calls.
    public let cache: FetchedResponseCache
    private let transport = RecordedTransport()

    public init(_ responses: [String: HTTPSTransportResponse] = [:], credentials: [String: String] = [:],
                consentedHosts: [String] = [], cache: FetchedResponseCache = FetchedResponseCache()) {
        self.responses = responses
        self.credentials = credentials
        self.consentedHosts = consentedHosts
        self.cache = cache
    }

    /// A JSON response with `body`, as a service answers.
    public static func json(_ body: String, status: Int = 200) -> HTTPSTransportResponse {
        HTTPSTransportResponse(status: status, headers: ["content-type": "application/json"], body: Data(body.utf8))
    }

    /// Every request that reached the network, in order, as it left: with
    /// its Credential Uses applied.
    public var requests: [HTTPSTransportRequest] { transport.requests }

    /// Sends the fetched sections of `view`, one after another, as the Host
    /// would once `invocation` answered with it, and returns them in view
    /// order. A view the Host would not draw throws its protocol violation.
    public func fetch(_ view: JSONValue, of plugin: PluginUnderTest,
                      for invocation: PluginTestInvocation) throws -> [Section] {
        let manifest = plugin.manifest
        let description = try PluginViewDescription(parsing: view, settingsFields: manifest.settingsFields)
        let action = try plugin.action(for: invocation)
        let grants = PluginCapabilityGrantStore()
        for capability in manifest.capabilities {
            grants.setDecision(deniedCapabilities.contains(capability) ? .denied : .granted, for: manifest.id,
                               pluginVersion: manifest.version, capability: capability,
                               scope: manifest.scope(for: capability))
        }
        if let declared = manifest.scope(for: .contactHTTPS) {
            grants.setConsentedHTTPSHosts(consentedHosts, for: manifest.id, pluginVersion: manifest.version,
                                          declaredScope: declared)
        }
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(plugin.package)
        let secrets = InMemoryPluginCredentialStore()
        for (reference, secret) in credentials {
            try secrets.setSecret(secret, for: manifest.id, reference: reference)
        }
        transport.responses = responses
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            httpsTransport: transport, credentialStore: secrets, responseCache: cache
        )

        var sections: [Section] = []
        for section in description.detail?.sections ?? [] {
            guard let fetch = section.fetch else { continue }
            // As the Host does, a view past its limit fetches nothing more.
            guard sections.count < HostFetchedSectionBudgets.maximumSections else {
                sections.append(Section(id: section.id, title: section.title, state: .overLimit, delivery: nil))
                continue
            }
            let request: HostFetchedRequest
            do {
                request = try HostFetchedRequest(parsing: fetch)
            } catch {
                sections.append(Section(id: section.id, title: section.title, state: .failure(error), delivery: nil))
                continue
            }
            let result = Result {
                try broker.sendHostFetchedRequest(request, for: action, using: registry,
                                                  cancellation: HostFetchedSections.Cancellation())
            }
            var delivery: PluginViewEvent?
            if request.mode == .deliver, case .success(let response) = result {
                delivery = .sectionDelivered(section: section.id, response: response)
            }
            sections.append(Section(id: section.id, title: section.title, state: request.state(afterSending: result),
                                    delivery: delivery))
        }
        return sections
    }
}

/// Answers by host from the recorded responses and keeps every request.
private final class RecordedTransport: HTTPSTransport {
    private let lock = NSLock()
    private var sent: [HTTPSTransportRequest] = []
    private var answers: [String: HTTPSTransportResponse] = [:]

    var responses: [String: HTTPSTransportResponse] {
        get { lock.withLock { answers } }
        set { lock.withLock { answers = newValue } }
    }

    var requests: [HTTPSTransportRequest] { lock.withLock { sent } }

    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        let response = lock.withLock { () -> HTTPSTransportResponse? in
            sent.append(request)
            return answers[request.url.host ?? ""]
        }
        guard let response else { throw HTTPSTransportError.connectionFailed }
        return response
    }
}
