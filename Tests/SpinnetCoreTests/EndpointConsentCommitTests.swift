import SpinnetCore
import XCTest

final class EndpointConsentCommitTests: XCTestCase {
    private let owner = PluginID("example.endpoint")
    private var scope: PluginCapabilityScope {
        PluginCapabilityScope(capability: .contactHTTPS, commandIDs: [CommandID("run")], dataTypes: ["text"], httpsHosts: ["api.example"])
    }

    func testAddingAnEndpointNeverPromotesAnUnscopedHistoricalGrant() throws {
        let grants = PluginCapabilityGrantStore(grants: [
            .init(pluginID: owner, pluginVersion: "1", capability: .contactHTTPS, decision: .granted)
        ])
        XCTAssertEqual(grants.decision(for: owner, pluginVersion: "1", capability: .contactHTTPS, scope: scope), .notDetermined)
        try grants.addConsentedHTTPSHosts(["self.example"], for: owner, pluginVersion: "1", declaredScope: scope, persisting: { proposed in
            XCTAssertEqual(proposed.first?.decision, .notDetermined)
        })
        XCTAssertEqual(grants.decision(for: owner, pluginVersion: "1", capability: .contactHTTPS, scope: scope), .notDetermined)
        XCTAssertEqual(grants.consentedHTTPSHosts(for: owner, pluginVersion: "1", declaredScope: scope), ["self.example"])
    }

    func testAddingAnEndpointPreservesOnlyTheMatchingScopedDecision() throws {
        let grants = PluginCapabilityGrantStore(grants: [
            .init(pluginID: owner, pluginVersion: "1", capability: .contactHTTPS, decision: .granted, scope: scope)
        ])
        try grants.addConsentedHTTPSHosts(["self.example"], for: owner, pluginVersion: "1", declaredScope: scope, persisting: { _ in })
        XCTAssertEqual(grants.decision(for: owner, pluginVersion: "1", capability: .contactHTTPS, scope: scope), .granted)
    }
}
