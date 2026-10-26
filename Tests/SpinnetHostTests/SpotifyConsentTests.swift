import XCTest
import SpinnetCore
@testable import SpinnetHost

final class SpotifyConsentTests: XCTestCase {
    func testTrustedRequestedPlaybackReadCanPromptWhileDirectActionsCannot() throws {
        let manifest = try PluginManifestLoader.decode(Data("""
        {"engines":{"spinnet":"^1.0.0"},"protocol_version":"1.0","id":"test.spotify.consent","name":"Spotify","version":"1.0",
        "capabilities":["control_external_app"],"capability_scopes":[{"capability":"control_external_app","command_ids":["show"],"data_types":[],"includes_existing_host_data":false,"https_hosts":[],"external_apps":[{"bundle_id":"com.spotify.client","operation_families":["playback_read","playback_control"]}]}],
        "commands":[{"id":"show","title":"Playback","execution":"javascript","script":"show.js"}]}
        """.utf8))
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/spotify-consent-test"), manifest: manifest)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
            capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        let registry = PluginRegistry(grantStore: grants); try registry.register(package)
        let action = try ActionConfiguration(id: ActionID("show"), pluginID: manifest.id, command: manifest.commands[0], input: .null)
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, reviewedAppPerformer: { _, allowsPrompt in
                XCTAssertTrue(allowsPrompt, "Trusted Requested playback is the explicit consent path")
                return .object(["state": .string("paused"), "position": .number(0), "track": .null])
            }, pluginRegistry: registry)
        let desktop = FakeDesktop()
        let apps = FakeApps(desktop: desktop)
        let inserter = TargetedTextInserter(tracker: InsertionTargetTracker(environment: apps.environment),
            inserter: HostTextInserter(environment: desktop.environment))
        let performer = HostOperationsPerformer(registry: registry, broker: { broker }, inserter: inserter, openPluginSettings: { _ in })
        let operation = RequestedHostOperation(perform: "apps.perform", input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string("playback")]))
        try performer.authorize(operation, for: action)
        let done = expectation(description: "Requested playback")
        performer.perform(operation, for: action, target: .notShown, accepted: performer.accept(operation, for: action)) { result in
            XCTAssertEqual(result.outcome, .succeeded); done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
