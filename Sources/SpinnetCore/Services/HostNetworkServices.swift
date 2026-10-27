import Foundation

/// The HTTPS performer, credential application and bounded cache share one
/// implementation for direct calls, fetched sections, images and source checks.
public struct HostNetworkServices {
    private let httpsTransport: HTTPSTransport?
    private let credentialStore: PluginCredentialStore?
    public let responseCache: FetchedResponseCache

    public init(httpsTransport: HTTPSTransport? = nil, credentialStore: PluginCredentialStore? = nil,
                responseCache: FetchedResponseCache = FetchedResponseCache()) {
        self.httpsTransport = httpsTransport
        self.credentialStore = credentialStore
        self.responseCache = responseCache
    }

    func validate(_ input: JSONValue, for package: PluginPackage, grantStore: PluginCapabilityGrantStore) throws {
        try httpsPerformer(for: package, grantStore: grantStore).validate(input)
    }

    func perform(_ input: JSONValue, for package: PluginPackage, grantStore: PluginCapabilityGrantStore) throws -> JSONValue {
        try httpsPerformer(for: package, grantStore: grantStore).perform(input)
    }

    func send(_ request: HostFetchedRequest, for package: PluginPackage, grantStore: PluginCapabilityGrantStore,
              cancellation: HostFetchedSections.Cancellation) throws -> JSONValue {
        let performer = try httpsPerformer(for: package, grantStore: grantStore,
            timeout: ScriptedActionBudgets.hostFetchedSectionDeadline, cancellation: cancellation)
        var destination: URL?
        if case .object(let fields) = request.request, case .string(let address)? = fields["url"] {
            destination = URL(string: address)
        }
        return try namingTheRefusedHost(of: destination, for: package) {
            try sendAnsweringFromCache(request.request, for: package, mayAnswerFromCache: request.isCacheable, performer: performer)
        }
    }

    func fetchImage(_ url: URL, for package: PluginPackage, grantStore: PluginCapabilityGrantStore,
                    cancellation: HostFetchedSections.Cancellation) throws -> Data {
        let performer = try httpsPerformer(for: package, grantStore: grantStore,
            timeout: PageImageBudgets.loadDeadline, cancellation: cancellation)
        return try namingTheRefusedHost(of: url, for: package) {
            try performer.fetchImage(url, maximumBytes: PageImageBudgets.maximumImageBytes)
        }
    }

    /// Performs an `https_request` input the Host sends for a view.
    /// Asking the same question twice, such as translating the same text
    /// again, is answered from the last answer when the Plugin allows it;
    /// the caller has checked the Plugin's authority first, so a withdrawn
    /// grant stops these too, and a kept answer is given only while the
    /// request would still be sent, its host consented to now. Only a 2xx
    /// answer is kept.
    private func sendAnsweringFromCache(_ input: JSONValue, for package: PluginPackage, mayAnswerFromCache: Bool,
                                        performer: PluginHTTPSRequestPerformer) throws -> JSONValue {
        let key = mayAnswerFromCache ? FetchedResponseCache.key(pluginID: package.manifest.id, request: input) : nil
        if let key, let cached = responseCache.response(for: key) {
            try performer.validate(input)
            return cached
        }
        let response = try performer.perform(input)
        if let key, case .object(let fields) = response, case .number(let status)? = fields["status"],
           (200..<300).contains(Int(status)) {
            responseCache.store(response, for: key)
        }
        return response
    }

    /// Runs `send`; when its destination is outside the consented hosts,
    /// though the grant stood a moment ago, it is a host the user never
    /// allowed, such as a self-hosted endpoint, and the refusal names it.
    private func namingTheRefusedHost<T>(of destination: URL?, for package: PluginPackage,
                                         _ send: () throws -> T) throws -> T {
        do {
            return try send()
        } catch PluginHostServiceError.capabilityScopeDenied(.contactHTTPS) {
            guard let host = destination.flatMap(HTTPSDestination.host(of:)) else {
                throw PluginHostServiceError.capabilityScopeDenied(.contactHTTPS)
            }
            throw PluginHostServiceError.failed(package.manifest.refusalToContact(host))
        }
    }

    /// A performer for the Plugin's declared hosts plus those the user
    /// consented to, read from the grant each time so a change applies at once.
    private func httpsPerformer(
        for package: PluginPackage, grantStore: PluginCapabilityGrantStore, timeout: TimeInterval = HTTPSRequestBudgets.timeout,
        cancellation: HostFetchedSections.Cancellation = .init()
    ) throws -> PluginHTTPSRequestPerformer {
        guard let httpsTransport else {
            throw PluginHostServiceError.unavailable("HTTPS transport")
        }
        let pluginID = package.manifest.id
        var performer = PluginHTTPSRequestPerformer(
            transport: httpsTransport,
            consentedHosts: package.manifest.contactableHTTPSHosts(in: grantStore),
            credential: { [credentialStore] reference in
                try credentialStore?.secret(for: pluginID, reference: reference)
            }
        )
        performer.timeout = timeout
        performer.cancellation = cancellation
        return performer
    }

}
