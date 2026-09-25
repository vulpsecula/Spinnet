import XCTest
@testable import SpinnetCore

/// A transport that never touches the network. It answers from a script of
/// responses and records every request the Host sent, so the tests see exactly
/// what would have left the machine.
final class ScriptedHTTPSTransport: HTTPSTransport {
    var responses: [HTTPSTransportResponse]
    private(set) var requests: [HTTPSTransportRequest] = []

    init(_ responses: [HTTPSTransportResponse] = []) {
        self.responses = responses
    }

    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw HTTPSTransportError.connectionFailed }
        return responses.removeFirst()
    }

    static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPSTransportResponse {
        HTTPSTransportResponse(status: status,
                               headers: headers.merging(["content-type": "application/json"]) { first, _ in first },
                               body: Data(body.utf8))
    }
}

/// A Plugin that contacts one declared host from one Command and only copies
/// from another, so a test can tell which Commands a decision reaches.
enum NetworkPluginFixture {
    static func manifest(hosts: [String] = ["api.example.com"], settings: String = "") throws -> PluginManifest {
        let hostList = hosts.map { "\"\($0)\"" }.joined(separator: ", ")
        return try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0",
          "id": "com.example.network",
          "name": "Network Example",
          "version": "1.0.0",
          "capabilities": ["contact_https", "write_clipboard"],
          \(settings)
          "capability_scopes": [{
            "capability": "contact_https", "command_ids": ["fetch"], "data_types": [],
            "includes_existing_host_data": false, "https_hosts": [\(hostList)], "external_apps": []
          }, {
            "capability": "write_clipboard", "command_ids": ["fetch", "copy"], "data_types": [],
            "includes_existing_host_data": false, "https_hosts": [], "external_apps": []
          }],
          "preset": {"readiness": "ready_to_use", "is_configurable": false, "default_primary_command_id": "fetch"},
          "commands": [
            {"id": "fetch", "title": "Fetch", "execution": "javascript", "is_configurable": false, "script": "fetch.js"},
            {"id": "copy", "title": "Copy", "execution": "javascript", "is_configurable": false, "script": "copy.js"}
          ]
        }
        """.utf8))
    }
}

final class HTTPSHostServiceTests: XCTestCase {
    private var manifest: PluginManifest!
    private var package: PluginPackage!
    private var grants: PluginCapabilityGrantStore!
    private var credentials: InMemoryPluginCredentialStore!
    private var transport: ScriptedHTTPSTransport!

    override func setUpWithError() throws {
        manifest = try NetworkPluginFixture.manifest()
        package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/network"), manifest: manifest)
        grants = PluginCapabilityGrantStore()
        for capability in manifest.capabilities {
            grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                               capability: capability, scope: manifest.scope(for: capability))
        }
        credentials = InMemoryPluginCredentialStore()
        transport = ScriptedHTTPSTransport()
    }

    private var broker: CapabilityCheckedHostServiceBroker {
        CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            httpsTransport: transport, credentialStore: credentials
        )
    }

    private func action(_ commandID: String = "fetch") throws -> ActionConfiguration {
        let command = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == commandID })
        return try ActionConfiguration(id: ActionID(commandID), pluginID: manifest.id, command: command, input: .null)
    }

    private func request(_ input: JSONValue, from commandID: String = "fetch") throws -> JSONValue {
        let request = PluginRuntimeHostServiceRequest(invocationID: "invocation", actionID: ActionID(commandID),
                                                      service: .httpsRequest, input: input)
        return try broker.execute(request: request, for: package, action: action(commandID))
    }

    private func get(_ url: String) -> JSONValue {
        .object(["method": .string("GET"), "url": .string(url)])
    }

    private func encoded(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    // MARK: Destination

    func testADeclaredHostIsContactedAndItsResponseReturned() throws {
        transport.responses = [ScriptedHTTPSTransport.json(#"{"ok":true}"#, headers: ["set-cookie": "a=b"])]
        let result = try request(get("https://api.example.com/v1/status?full=1"))

        XCTAssertEqual(transport.requests.map(\.url.absoluteString), ["https://api.example.com/v1/status?full=1"])
        XCTAssertEqual(transport.requests.first?.method, "GET")
        XCTAssertLessThan(try XCTUnwrap(transport.requests.first?.timeout), ScriptedActionBudgets.actionDeadline,
                          "The request must finish inside the Action deadline")
        XCTAssertEqual(result, .object([
            "status": .number(200),
            // Only the documented subset of response headers reaches the Plugin.
            "headers": .object(["content-type": .string("application/json")]),
            "body": .string(#"{"ok":true}"#)
        ]))
    }

    func testAHostOutsideTheConsentedScopeIsRefusedBeforeAnythingIsSent() throws {
        XCTAssertThrowsError(try request(get("https://attacker.example.net/collect"))) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.contactHTTPS))
        }
        // A declared host's subdomain or a look-alike is a different host.
        XCTAssertThrowsError(try request(get("https://evil.api.example.com/")))
        XCTAssertThrowsError(try request(get("https://api.example.com.evil.net/")))
        XCTAssertEqual(transport.requests, [], "Nothing may leave the machine for an unconsented host")
    }

    func testOnlyPlainHTTPSURLsAreAccepted() throws {
        for url in ["http://api.example.com/", "ftp://api.example.com/", "https://user:pw@api.example.com/",
                    "https://api.example.com:8443/", "api.example.com/v1", "file:///etc/hosts"] {
            XCTAssertThrowsError(try request(get(url)), url) { error in
                XCTAssertEqual((error as? PluginHostServiceError)?.runtimeFailureCategory, .hostServiceFailed, url)
            }
        }
        XCTAssertEqual(transport.requests, [])
    }

    func testMethodsHeadersAndBodiesAreBounded() throws {
        let invalid: [JSONValue] = [
            .object(["method": .string("DELETE"), "url": .string("https://api.example.com/")]),
            .object(["method": .string("GET"), "url": .string("https://api.example.com/"), "body": .string("x")]),
            .object(["method": .string("POST"), "url": .string("https://api.example.com/"),
                     "headers": .object(["Cookie": .string("session=1")])]),
            .object(["method": .string("POST"), "url": .string("https://api.example.com/"),
                     "headers": .object(["Authorization": .string("Bearer guessed")])]),
            .object(["method": .string("POST"), "url": .string("https://api.example.com/"),
                     "headers": .object(["X-Test": .string("a\r\nInjected: 1")])]),
            .object(["method": .string("POST"), "url": .string("https://api.example.com/"),
                     "body": .string(String(repeating: "a", count: HTTPSRequestBudgets.maximumRequestBodyBytes + 1))]),
            .object(["method": .string("GET"), "url": .string("https://api.example.com/"), "proxy": .string("x")])
        ]
        for input in invalid {
            XCTAssertThrowsError(try request(input))
        }
        XCTAssertEqual(transport.requests, [])
    }

    // MARK: Redirects

    func testARedirectToAnUnconsentedHostIsNotFollowed() throws {
        transport.responses = [HTTPSTransportResponse(status: 302, headers: ["location": "https://attacker.example.net/steal"], body: Data())]
        XCTAssertThrowsError(try request(get("https://api.example.com/start"))) { error in
            XCTAssertEqual((error as? PluginHostServiceError)?.runtimeFailureCategory, .hostServiceFailed)
        }
        XCTAssertEqual(transport.requests.map(\.url.host), ["api.example.com"])

        transport.responses = [HTTPSTransportResponse(status: 301, headers: ["location": "http://api.example.com/plain"], body: Data())]
        XCTAssertThrowsError(try request(get("https://api.example.com/start")), "A downgrade to http is a new destination")
    }

    func testARedirectWithinTheConsentedScopeIsFollowedByTheHost() throws {
        transport.responses = [
            HTTPSTransportResponse(status: 307, headers: ["location": "/v2/moved"], body: Data()),
            ScriptedHTTPSTransport.json("{}")
        ]
        let result = try request(.object(["method": .string("POST"), "url": .string("https://api.example.com/v2/old"),
                                          "body": .string("payload")]))
        XCTAssertEqual(transport.requests.map(\.url.absoluteString),
                       ["https://api.example.com/v2/old", "https://api.example.com/v2/moved"])
        XCTAssertEqual(transport.requests.last?.method, "POST", "307 keeps the method")
        XCTAssertEqual(transport.requests.last?.body, Data("payload".utf8))
        if case .object(let fields) = result { XCTAssertEqual(fields["status"], .number(200)) } else { XCTFail() }

        transport.responses = Array(repeating: HTTPSTransportResponse(status: 302, headers: ["location": "/again"], body: Data()),
                                    count: HTTPSRequestBudgets.maximumRedirects + 1)
        XCTAssertThrowsError(try request(get("https://api.example.com/loop")), "Redirect chains are bounded")
    }

    // MARK: Credentials

    func testTheHostInjectsAStoredCredentialThePluginNeverSees() throws {
        try credentials.setSecret("s3cr3t-key", for: manifest.id, reference: "primary")
        transport.responses = [ScriptedHTTPSTransport.json(#"{"translated":"Hallo"}"#)]
        let result = try request(.object([
            "method": .string("POST"), "url": .string("https://api.example.com/v2/translate"),
            "headers": .object(["Content-Type": .string("application/json")]),
            "body": .string(#"{"text":["Hello"]}"#),
            "credential_uses": .array([.object(["reference": .string("primary"), "header": .string("Authorization"),
                                                "template": .string("DeepL-Auth-Key {credential}")])])
        ]))

        XCTAssertEqual(transport.requests.first?.headers["Authorization"], "DeepL-Auth-Key s3cr3t-key")
        XCTAssertEqual(transport.requests.first?.headers["Content-Type"], "application/json")
        XCTAssertFalse(try encoded(result).contains("s3cr3t-key"), "The secret reached the Plugin")
    }

    func testAMissingCredentialFailsWithoutSendingAndNeverEchoesTheSecret() throws {
        let credential: JSONValue = .object(["reference": .string("primary"), "header": .string("Authorization")])
        XCTAssertThrowsError(try request(.object(["method": .string("GET"), "url": .string("https://api.example.com/"),
                                                  "credential_uses": .array([credential])])))
        XCTAssertEqual(transport.requests, [])

        // Another Plugin's credential is not reachable by naming its reference.
        try credentials.setSecret("other-plugin-secret", for: PluginID("com.example.other"), reference: "primary")
        XCTAssertThrowsError(try request(.object(["method": .string("GET"), "url": .string("https://api.example.com/"),
                                                  "credential_uses": .array([credential])])))

        try credentials.setSecret("s3cr3t-key", for: manifest.id, reference: "primary")
        transport.responses = []
        XCTAssertThrowsError(try request(.object(["method": .string("GET"), "url": .string("https://api.example.com/"),
                                                  "credential_uses": .array([credential])]))) { error in
            XCTAssertFalse(String(describing: error).contains("s3cr3t-key"))
        }
    }

    func testTheCredentialIsNotForwardedToAnotherHostOnRedirect() throws {
        let scoped = try NetworkPluginFixture.manifest(hosts: ["api.example.com", "cdn.example.com"])
        manifest = scoped
        package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/network"), manifest: scoped)
        grants.setDecision(.granted, for: scoped.id, pluginVersion: scoped.version,
                           capability: .contactHTTPS, scope: scoped.scope(for: .contactHTTPS))
        try credentials.setSecret("s3cr3t-key", for: scoped.id, reference: "primary")
        transport.responses = [
            HTTPSTransportResponse(status: 302, headers: ["location": "https://cdn.example.com/file"], body: Data()),
            ScriptedHTTPSTransport.json("{}")
        ]
        _ = try request(.object(["method": .string("GET"), "url": .string("https://api.example.com/"),
                                 "credential_uses": .array([.object(["reference": .string("primary"),
                                                                     "header": .string("Authorization")])])]))
        XCTAssertEqual(transport.requests.first?.headers["Authorization"], "s3cr3t-key")
        XCTAssertNil(transport.requests.last?.headers["Authorization"])
    }

    // MARK: Response bounds

    func testAnOversizedResponseFailsInsteadOfReachingTheHelper() throws {
        let body = String(repeating: "a", count: HTTPSRequestBudgets.maximumResponseBodyBytes + 1)
        transport.responses = [ScriptedHTTPSTransport.json(body)]
        XCTAssertThrowsError(try request(get("https://api.example.com/large"))) { error in
            XCTAssertEqual((error as? PluginHostServiceError)?.runtimeFailureCategory, .hostServiceFailed)
        }
        XCTAssertEqual(transport.requests.first?.maximumResponseBytes, HTTPSRequestBudgets.maximumResponseBodyBytes)

        // The largest accepted body still fits one helper message after JSON escaping.
        let worst = String(repeating: "\u{01}", count: HTTPSRequestBudgets.maximumResponseBodyBytes)
        transport.responses = [HTTPSTransportResponse(status: 200, headers: [:], body: Data(worst.utf8))]
        let result = try request(get("https://api.example.com/escaped"))
        let response = PluginRuntimeHostServiceResponse(invocationID: "invocation", actionID: ActionID("fetch"),
                                                        requestID: "r", outcome: .succeeded(result))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(response).count, PluginRuntimeProtocol.maximumMessageBytes)
    }

    // MARK: Authority

    func testRevokingContactDisablesOnlyTheCommandsThatUseTheNetwork() throws {
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in true })
        try registry.register(package)
        XCTAssertEqual(registry.availability(for: try action("fetch")), .available)
        XCTAssertEqual(registry.availability(for: try action("copy")), .available)

        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version,
                           capability: .contactHTTPS, scope: manifest.scope(for: .contactHTTPS))
        XCTAssertEqual(registry.availability(for: try action("fetch")), .unavailable(.capabilityDenied))
        XCTAssertEqual(registry.availability(for: try action("copy")), .available)
        XCTAssertThrowsError(try request(get("https://api.example.com/"))) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.contactHTTPS))
        }
        // A Command outside the contact scope cannot reach the network either.
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .contactHTTPS, scope: manifest.scope(for: .contactHTTPS))
        XCTAssertThrowsError(try request(get("https://api.example.com/"), from: "copy"))
        XCTAssertEqual(transport.requests, [])
    }

    // MARK: User-consented hosts

    func testAUserConsentedHostJoinsTheContactScopeWithoutChangingTheDecision() throws {
        let declared = try XCTUnwrap(manifest.scope(for: .contactHTTPS))
        XCTAssertThrowsError(try request(get("https://translate.self-hosted.test/")))

        grants.setConsentedHTTPSHosts(["translate.self-hosted.test"], for: manifest.id,
                                      pluginVersion: manifest.version, declaredScope: declared)
        XCTAssertEqual(grants.decision(for: manifest.id, pluginVersion: manifest.version,
                                       capability: .contactHTTPS, scope: declared), .granted)
        XCTAssertEqual(grants.consentedHTTPSHosts(for: manifest.id, pluginVersion: manifest.version, declaredScope: declared),
                       ["translate.self-hosted.test"])
        transport.responses = [ScriptedHTTPSTransport.json("{}")]
        XCTAssertNoThrow(try request(get("https://translate.self-hosted.test/v2/translate")))

        // Revoking and granting again from Plugin Settings keeps the host the
        // user added; the added host is part of the persisted scope.
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version,
                           capability: .contactHTTPS, scope: declared)
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .contactHTTPS, scope: declared)
        let persisted = try JSONDecoder().decode([PluginCapabilityGrant].self,
                                                 from: JSONEncoder().encode(grants.allGrants))
        let restored = PluginCapabilityGrantStore(grants: persisted)
        XCTAssertEqual(restored.consentedHTTPSHosts(for: manifest.id, pluginVersion: manifest.version, declaredScope: declared),
                       ["translate.self-hosted.test"])
        XCTAssertEqual(restored.decision(for: manifest.id, pluginVersion: manifest.version,
                                         capability: .contactHTTPS, scope: declared), .granted)
    }

    func testAChangedDeclaredScopeForgetsTheUserConsentedHosts() throws {
        let declared = try XCTUnwrap(manifest.scope(for: .contactHTTPS))
        grants.setConsentedHTTPSHosts(["translate.self-hosted.test"], for: manifest.id,
                                      pluginVersion: manifest.version, declaredScope: declared)
        var retired: [PluginID] = []
        _ = grants.observeRevocation { retired.append($0) }

        // An update that keeps the scope inherits the decision and the host.
        let same = try NetworkPluginFixture.manifest()
        grants.prepareInstallation(of: same, replacing: manifest)
        XCTAssertEqual(grants.consentedHTTPSHosts(for: same.id, pluginVersion: same.version, declaredScope: declared),
                       ["translate.self-hosted.test"])

        // An update that widens the declared hosts asks again from scratch.
        let widened = try NetworkPluginFixture.manifest(hosts: ["api.example.com", "api2.example.com"])
        grants.prepareInstallation(of: widened, replacing: manifest)
        let widenedScope = try XCTUnwrap(widened.scope(for: .contactHTTPS))
        XCTAssertEqual(grants.decision(for: widened.id, pluginVersion: widened.version,
                                       capability: .contactHTTPS, scope: widenedScope), .notDetermined)
        XCTAssertEqual(grants.consentedHTTPSHosts(for: widened.id, pluginVersion: widened.version, declaredScope: widenedScope), [])
        XCTAssertEqual(retired, [manifest.id], "A running helper loses the narrowed authority")
    }

    func testAManifestCannotDeclareUserConsentedHosts() throws {
        XCTAssertThrowsError(try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "id": "com.example.sneaky", "name": "Sneaky", "version": "1.0.0",
          "capabilities": ["contact_https"],
          "capability_scopes": [{
            "capability": "contact_https", "command_ids": ["fetch"], "data_types": [],
            "includes_existing_host_data": false, "https_hosts": ["api.example.com"], "external_apps": [],
            "consented_https_hosts": ["attacker.example.net"]
          }],
          "commands": [{"id": "fetch", "title": "Fetch", "execution": "javascript", "is_configurable": false, "script": "f.js"}]
        }
        """.utf8)))
    }

    func testNetworkingIsNowAnAvailableHostService() throws {
        XCTAssertTrue(PluginCapability.contactHTTPS.isSupportedByHostServices)
        XCTAssertEqual(PluginHostService.httpsRequest.requiredCapability, .contactHTTPS)
        XCTAssertNil(PluginHostService.httpsRequest.requiredSystemPermission)
        let disclosure = PluginPermissionDisclosure(manifest: manifest).details(for: .contacts)
        XCTAssertTrue(disclosure.contains("api.example.com"))
        XCTAssertFalse(disclosure.contains("not available"))
    }
}
