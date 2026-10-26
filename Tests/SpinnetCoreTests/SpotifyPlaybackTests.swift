import SpinnetTestSupport
import XCTest
import SpinnetCore

final class SpotifyPlaybackTests: XCTestCase {
    func testPlaybackProjectsMillisecondsIntoSecondsAndBoundsUntrustedTrackText() throws {
        let result = try SpotifyPlayback.project(state: "playing", position: 12.5,
            track: ["name": .string(String(repeating: "x", count: 600)), "artist": .string("Artist"),
                    "album": .string("Album"), "id": .string("spotify:track:abc"),
                    "duration": .number(241000), "artwork_url": .string("https://i.scdn.co/image/abc")])
        XCTAssertEqual(result.value(atPointer: "/track/duration"), .number(241))
        XCTAssertEqual(result.value(atPointer: "/position"), .number(12.5))
        XCTAssertEqual(result.value(atPointer: "/track/name"), .string(String(repeating: "x", count: 512)))
    }
}

extension SpotifyPlaybackTests {
    private func package() throws -> PluginPackage {
        let manifest = try PluginManifestLoader.decode(Data("""
        {"engines":{"spinnet":"^1.0.0"},"protocol_version":"1.0","id":"test.spotify","name":"Spotify","version":"1.0",
        "capabilities":["control_external_app"],"capability_scopes":[{"capability":"control_external_app","command_ids":["show"],"data_types":[],"includes_existing_host_data":false,"https_hosts":[],"external_apps":[{"bundle_id":"com.spotify.client","operation_families":["playback_read","playback_control"]}]}],
        "commands":[{"id":"show","title":"Playback","execution":"javascript","script":"show.js"}]}
        """.utf8))
        return PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/spotify-test"), manifest: manifest)
    }
    func testARevokedThenRegrantedReadCannotReturnItsLatePlaybackAnswer() throws {
        let package = try package()
        let action = try ActionConfiguration(id: ActionID("show"), pluginID: package.manifest.id, command: package.manifest.commands[0], input: .null)
        let grants = PluginCapabilityGrantStore()
        func decision(_ value: PluginCapabilityGrantDecision) {
            grants.setDecision(value, for: package.manifest.id, pluginVersion: package.manifest.version,
                capability: .controlExternalApp, scope: package.manifest.scope(for: .controlExternalApp))
        }
        decision(.granted)
        let registry = PluginRegistry(grantStore: grants); try registry.register(package)
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, reviewedAppPerformer: { _, allowsPrompt in
                XCTAssertFalse(allowsPrompt, "Visible sources may never request Automation consent")
                decision(.denied); decision(.granted)
                return .object(["state": .string("playing")])
            }, pluginRegistry: registry)
        let source = try PluginPageSource(parsing: .object(["id": .string("playback"), "perform": .string("apps.perform"),
            "input": .object(["bundle_id": .string("com.spotify.client"), "operation": .string("playback")]), "every": .number(1)]), permits: { _ in true })
        let adapter = broker.reviewedAppSourceAdapter(using: registry)
        XCTAssertThrowsError(try adapter.sample(action, source, .init())) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.controlExternalApp))
        }
    }
}

extension SpotifyPlaybackTests {
    func testPublicSpotifyFixturesMatchTheirSchemas() throws {
        let root = TestRepository.root.appendingPathComponent("PluginAPI")
        struct Entry: Decodable { let file: String; let definition: String; let valid: Bool; let schema: String }
        struct Index: Decodable { let fixtures: [Entry] }
        let folder = root.appendingPathComponent("fixtures/spotify")
        for entry in try JSONDecoder().decode(Index.self, from: Data(contentsOf: folder.appendingPathComponent("index.json"))).fixtures {
            let validator = try JSONSchemaSubsetValidator(definition: entry.definition, inSchemaAt: root.appendingPathComponent("schemas/" + entry.schema))
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent(entry.file)))
            XCTAssertEqual(validator.errors(for: value).isEmpty, entry.valid, entry.file)
        }
    }
}
