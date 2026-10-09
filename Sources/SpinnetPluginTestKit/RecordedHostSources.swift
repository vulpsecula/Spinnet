import Foundation
import SpinnetCore

/// Visible-page sources through the Host's real broker and source engine,
/// with a deterministic clock and recorded network answers; no AppKit or server.
public final class RecordedHostSources {
    private final class Transport: HTTPSTransport {
        var responses: [String: HTTPSTransportResponse]
        var requests: [HTTPSTransportRequest] = []
        init(_ responses: [String: HTTPSTransportResponse]) { self.responses = responses }
        func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
            requests.append(request)
            guard let response = responses[request.url.host ?? ""] else { throw HTTPSTransportError.connectionFailed }
            return response
        }
    }
    public let plugin: PluginUnderTest
    public let invocation: PluginTestInvocation
    public let grants: PluginCapabilityGrantStore
    public let registry: PluginRegistry
    public let credentials: InMemoryPluginCredentialStore
    public private(set) var deliveries: [PluginViewEvent] = []
    public var requests: [HTTPSTransportRequest] { transport.requests }
    public var responses: [String: HTTPSTransportResponse] {
        get { transport.responses }
        set { transport.responses = newValue }
    }
    private let transport: Transport
    private let action: ActionConfiguration
    private var engine: HostRunSources!
    private var clock: TimeInterval = 0
    private var timers: [(TimeInterval, () -> Void)] = []

    public init(of plugin: PluginUnderTest, for invocation: PluginTestInvocation,
                responses: [String: HTTPSTransportResponse] = [:], secrets: [String: String] = [:],
                deniedCapabilities: Set<PluginCapability> = []) throws {
        self.plugin = plugin; self.invocation = invocation
        action = try plugin.action(for: invocation)
        transport = Transport(responses)
        grants = PluginCapabilityGrantStore()
        for capability in plugin.manifest.capabilities {
            grants.setDecision(deniedCapabilities.contains(capability) ? .denied : .granted,
                for: plugin.manifest.id, pluginVersion: plugin.manifest.version, capability: capability,
                scope: plugin.manifest.scope(for: capability))
        }
        registry = PluginRegistry(grantStore: grants)
        try registry.register(plugin.package)
        credentials = InMemoryPluginCredentialStore()
        for (reference, secret) in secrets { try credentials.setSecret(secret, for: plugin.manifest.id, reference: reference) }
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, httpsTransport: transport, credentialStore: credentials)
        engine = HostRunSources(adapters: ["http.request": broker.httpSourceAdapter(using: registry)],
            now: { [weak self] in self?.clock ?? 0 }, schedule: { [weak self] delay, task in
                guard let self else { return }; self.timers.append((self.clock + delay, task))
            }, background: { $0() }, executor: { $0() })
        engine.onDelivery = { [weak self] _, event, current in if current() { self?.deliveries.append(event) } }
    }
    public func present(_ page: JSONValue, answering event: PluginViewEvent? = nil) throws {
        let parsed = try PluginPage(parsing: page, permits: registry.contracts.permitting(plugin.manifest))
        try engine.present(parsed, for: action, answering: event)
    }
    public func setVisible(_ visible: Bool) { engine.setVisible(visible, pluginID: plugin.manifest.id) }
    public func shown(_ component: String, locale: Locale = .current) -> HostSourceShown? {
        engine.shown(component: component, pluginID: plugin.manifest.id, locale: locale)
    }
    public func credentialChanged() { engine.credentialsChanged(pluginID: plugin.manifest.id) }
    public func authorityChanged() { engine.authorityChanged(pluginID: plugin.manifest.id) }
    public func close() { engine.end(pluginID: plugin.manifest.id) }
    /// Runs due timers in order; fixed delay means no sample backlog.
    public func advance(by seconds: TimeInterval) {
        let target = clock + max(0, seconds)
        while let index = timers.indices.filter({ timers[$0].0 <= target }).min(by: { timers[$0].0 < timers[$1].0 }) {
            let task = timers.remove(at: index); clock = task.0; task.1()
        }
        clock = target
    }
}
