import SpinnetTestSupport
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class SpotifyControlsTests: XCTestCase {
    private func package() throws -> PluginPackage {
        let manifest = try PluginManifestLoader.decode(Data("""
        {"engines":{"spinnet":"^1.0.0"},"protocol_version":"1.0","id":"test.spotify.controls","name":"Spotify","version":"1.0",
        "capabilities":["control_external_app"],"capability_scopes":[{"capability":"control_external_app","command_ids":["control"],"data_types":[],"includes_existing_host_data":false,"https_hosts":[],"external_apps":[{"bundle_id":"com.spotify.client","operation_families":["playback_read","playback_control"]}]}],
        "commands":[{"id":"control","title":"Control","execution":"javascript","script":"control.js"}]}
        """.utf8))
        return PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/spotify-controls-test"), manifest: manifest)
    }

    func testCurrentControlsStillRequireGrantsBeforeExternalDispatch() throws {
        let package = try package()
        let registry = PluginRegistry(); try registry.register(package)
        let grants = PluginCapabilityGrantStore()
        let action = try ActionConfiguration(id: .init("control"), pluginID: package.manifest.id, command: package.manifest.commands[0], input: .null)
        var dispatches = 0
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
            externalApps: .init(
                reviewedAppPerformer: { _, _ in
            dispatches += 1; return .object(["volume": .number(35)])
        }
            )
        )
        let request = PluginRuntimeHostServiceRequest(invocationID: "control", actionID: action.id, service: .performAppOperation,
            input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string("set_volume"), "arguments": .object(["volume": .number(35)])]), operation: "apps.perform")
        for decision in [PluginCapabilityGrantDecision.denied, .granted, .denied] {
            grants.setDecision(decision, for: package.manifest.id, pluginVersion: package.manifest.version, capability: .controlExternalApp, scope: package.manifest.scope(for: .controlExternalApp))
            if decision == .granted { XCTAssertEqual(try broker.execute(request: request, for: package, action: action), .object(["volume": .number(35)])) }
            else { XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action)) }
        }
        XCTAssertEqual(dispatches, 1)
    }
}


extension SpotifyControlsTests {
    func testPublicKitAcceptsCurrentVolumeAndRejectsBadTypedArgumentsBeforeAnswering() throws {
        let package = try package()
        let action = try ActionConfiguration(id: ActionID("control"), pluginID: package.manifest.id, command: package.manifest.commands[0], input: .null)
        var answered = 0
        let kit = RecordedHostServices(operations: ["apps.perform": .answer { _ in
            answered += 1; return .object(["volume": .number(35)])
        }])
        func request(_ value: JSONValue) -> PluginRuntimeHostServiceRequest {
            PluginRuntimeHostServiceRequest(invocationID: "control", actionID: action.id, service: .performAppOperation,
                input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string("set_volume"),
                    "arguments": .object(["volume": value])]), operation: "apps.perform")
        }
        XCTAssertEqual(try kit.execute(request: request(.number(35)), for: package, action: action), .object(["volume": .number(35)]))
        for bad in [JSONValue.string("35"), .number(35.5), .number(-1), .number(101), .bool(true)] {
            XCTAssertThrowsError(try kit.execute(request: request(bad), for: package, action: action))
        }
        XCTAssertEqual(answered, 1)
    }
}

extension SpotifyControlsTests {
    func testTypedBoundsAndScopeAreRejectedBeforeExternalDispatchAndControlsNeverPrompt() throws {
        let package = try package()
        let action = try ActionConfiguration(id: ActionID("control"), pluginID: package.manifest.id, command: package.manifest.commands[0], input: .null)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .controlExternalApp, scope: package.manifest.scope(for: .controlExternalApp))
        var dispatched = 0
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
            externalApps: .init(
                reviewedAppPerformer: { request, allowsPrompt in
                XCTAssertFalse(allowsPrompt)
                dispatched += 1
                return request.handler == "play_pause" ? .null : .object(["volume": .number(35)])
            }
            )
        )
        func call(_ operation: String, _ arguments: [String: JSONValue]) throws -> JSONValue {
            try broker.execute(request: .init(invocationID: "control", actionID: action.id, service: .performAppOperation,
                input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string(operation),
                    "arguments": .object(arguments)])), for: package, action: action)
        }
        for operation in ["set_volume", "adjust_volume"] {
            let key = operation == "set_volume" ? "volume" : "delta"
            for bad in [JSONValue.string("35"), .number(35.5), .number(101), .number(-101), .number(.infinity), .number(.nan), .bool(true), .null] {
                XCTAssertThrowsError(try call(operation, [key: bad]))
            }
            XCTAssertThrowsError(try call(operation, [:]))
            XCTAssertThrowsError(try call(operation, [key: .number(35), "script": .string("x")]))
        }
        for operation in ["volume", "play_pause", "next_checked"] {
            XCTAssertThrowsError(try call(operation, ["extra": .number(1)]))
        }
        XCTAssertEqual(dispatched, 0)
        XCTAssertEqual(try call("set_volume", ["volume": .number(0)]), .object(["volume": .number(35)]))
        XCTAssertEqual(try call("adjust_volume", ["delta": .number(-100)]), .object(["volume": .number(35)]))
        XCTAssertEqual(try call("play_pause", [:]), .null)
        grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .controlExternalApp, scope: package.manifest.scope(for: .controlExternalApp))
        XCTAssertThrowsError(try call("set_volume", ["volume": .number(50)]))
        XCTAssertEqual(dispatched, 3)
    }

    func testPublishedFixturesPreserveTypedControlBounds() throws {
        let root = TestRepository.root.appendingPathComponent("PluginAPI")
        let folder = root.appendingPathComponent("fixtures/spotify-controls")
        struct Entry: Decodable { let file: String; let definition: String; let valid: Bool }
        struct Index: Decodable { let fixtures: [Entry] }
        for entry in try JSONDecoder().decode(Index.self, from: Data(contentsOf: folder.appendingPathComponent("index.json"))).fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent(entry.file)))
            let schema = try JSONSchemaSubsetValidator(definition: entry.definition, inSchemaAt: root.appendingPathComponent("schemas/spotify-controls.schema.json"))
            XCTAssertEqual(schema.errors(for: value).isEmpty, entry.valid, entry.file)
        }
        let stable = try JSONSchemaSubsetValidator(definition: "input", inSchemaAt: root.appendingPathComponent("schemas/spotify.schema.json"))
        XCTAssertFalse(stable.errors(for: .object(["bundle_id": .string("com.spotify.client"), "operation": .string("volume")])).isEmpty)
        XCTAssertEqual(try XCTUnwrap(ReviewedAppInterface.interface(for: SpotifyPlayback.bundleID)).request(operation: "next", arguments: [:]).handler, "next")
    }

    func testLegacyDeclarationsAreRefusedAndCurrentBundledPackageIsAccepted() throws {
        let package = try package()
        let data = try JSONEncoder().encode(package.manifest)
        var retired = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        retired["candidate_contracts"] = [["name": "spotify_controls", "revision": 1]]
        XCTAssertThrowsError(try PluginManifestLoader.decode(JSONSerialization.data(withJSONObject: retired)))
        let registry = PluginRegistry()
        XCTAssertNoThrow(try registry.register(.init(rootURL: package.rootURL, manifest: package.manifest, origin: .bundled)))
        let oldContracts = PluginInterfaceContracts(hostVersion: try HostVersion("0.9.0"))
        XCTAssertThrowsError(try oldContracts.check(package.manifest, origin: .installed))
        XCTAssertNotNil(registry.package(for: package.manifest.id))
    }
}

private final class SpotifyBoundaryAnswer: PluginHostServiceBroker {
    func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage, action: ActionConfiguration) throws -> JSONValue {
        .object(["volume": .number(35)])
    }
}

extension SpotifyControlsTests {
    func testRealHelperForwardsCurrentTypedControls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Spotify.spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let package = try package()
        try JSONEncoder().encode(package.manifest).write(to: root.appendingPathComponent("manifest.json"))
        try "(function(){return {toast: String(spinnet.apps.perform({bundle_id:'com.spotify.client',operation:'volume'}).volume)};})()".write(to: root.appendingPathComponent("control.js"), atomically: true, encoding: .utf8)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let run = try helper.run(.init("control"), of: PluginUnderTest(packageAt: root), answering: SpotifyBoundaryAnswer())
        XCTAssertEqual(try run.result.get().value(atPointer: "/toast"), .string("35"))
        XCTAssertEqual(run.requests.count, 1)
    }
}

extension SpotifyControlsTests {
    func testSynchronousControlsDoNotWaitForAutomationConsent() throws {
        let plugin = try package()
        let action = try ActionConfiguration(id: ActionID("control"), pluginID: plugin.manifest.id, command: plugin.manifest.commands[0], input: .null)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
            capability: .controlExternalApp, scope: plugin.manifest.scope(for: .controlExternalApp))
        var prompts: [Bool] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
            externalApps: .init(
                reviewedAppPerformer: { _, allowsPrompt in
                prompts.append(allowsPrompt); return .null
            }
            )
        )
        for operation in ["play", "pause", "previous", "playback"] {
            _ = try broker.execute(request: .init(invocationID: "control", actionID: action.id, service: .performAppOperation,
                input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string(operation)]), operation: "apps.perform"),
                for: plugin, action: action)
        }
        XCTAssertEqual(prompts, [false, false, false, false])
    }
}

extension SpotifyControlsTests {
    func testHelperWireCannotEnableTrustedAutomationPromptFlag() throws {
        let plugin = try package()
        let action = try ActionConfiguration(id: ActionID("control"), pluginID: plugin.manifest.id, command: plugin.manifest.commands[0], input: .null)
        let original = PluginRuntimeHostServiceRequest(invocationID: "control", actionID: action.id, service: .performAppOperation,
            input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string("playback")]))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields["allowsAutomationPrompt"] = true; fields["allows_automation_prompt"] = true
        let forged = try JSONDecoder().decode(PluginRuntimeHostServiceRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertFalse(forged.allowsAutomationPrompt)
        var trusted = original; trusted.allowsAutomationPrompt = true
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trusted)) as? [String: Any])
        XCTAssertNil(encoded["allowsAutomationPrompt"]); XCTAssertNil(encoded["allows_automation_prompt"])
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
            capability: .controlExternalApp, scope: plugin.manifest.scope(for: .controlExternalApp))
        var prompts: [Bool] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
            externalApps: .init(
                reviewedAppPerformer: { _, allowsPrompt in
                prompts.append(allowsPrompt); return .null
            }
            )
        )
        _ = try broker.execute(request: forged, for: plugin, action: action)
        _ = try broker.execute(request: original, for: plugin, action: action)
        XCTAssertEqual(prompts, [false, false])
    }
}
