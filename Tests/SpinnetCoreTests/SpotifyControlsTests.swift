import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class SpotifyControlsTests: XCTestCase {
    private func package(candidate: Bool = true) throws -> PluginPackage {
        let declaration = ""
        let manifest = try PluginManifestLoader.decode(Data("""
        {"api_level":\(candidate ? 3 : 2),"protocol_version":"1.0","id":"test.spotify.controls","name":"Spotify","version":"1.0"\(declaration),
        "capabilities":["control_external_app"],"capability_scopes":[{"capability":"control_external_app","command_ids":["control"],"data_types":[],"includes_existing_host_data":false,"https_hosts":[],"external_apps":[{"bundle_id":"com.spotify.client","operation_families":["playback_read","playback_control"]}]}],
        "commands":[{"id":"control","title":"Control","execution":"javascript","script":"control.js"}]}
        """.utf8))
        return PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/spotify-controls-test"), manifest: manifest)
    }

    func testExactCandidateAdmitsControlsButStableDoesNotGainThem() throws {
        let candidate = try package()
        let registry = PluginRegistry()
        try registry.register(candidate)
        let grants = PluginCapabilityGrantStore()
        for package in [candidate, try package(candidate: false)] {
            grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                capability: .controlExternalApp, scope: package.manifest.scope(for: .controlExternalApp))
            let action = try ActionConfiguration(id: ActionID("control"), pluginID: package.manifest.id, command: package.manifest.commands[0], input: .null)
            var dispatched = false
            let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
                selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, reviewedAppPerformer: { _, _ in
                    dispatched = true; return .object(["volume": .number(35)])
                })
            let request = PluginRuntimeHostServiceRequest(invocationID: "control", actionID: action.id, service: .performAppOperation,
                input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string("set_volume"),
                    "arguments": .object(["volume": .number(35)])]))
            if package.manifest.apiLevel < 3 {
                XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action))
                XCTAssertFalse(dispatched)
            } else {
                XCTAssertEqual(try broker.execute(request: request, for: package, action: action), .object(["volume": .number(35)]))
                XCTAssertTrue(dispatched)
            }
        }
    }
}


extension SpotifyControlsTests {
    func testPublicKitAcceptsCandidateVolumeAndRejectsBadTypedArgumentsBeforeAnswering() throws {
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
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, reviewedAppPerformer: { request, allowsPrompt in
                XCTAssertFalse(allowsPrompt)
                dispatched += 1
                return request.handler == "play_pause" ? .null : .object(["volume": .number(35)])
            })
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

    func testPublicCandidateMetadataFixturesAndStableSchemaRemainSeparate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PluginAPI")
        let folder = root.appendingPathComponent("candidates/spotify_controls/r1")
        XCTAssertEqual(try JSONDecoder().decode(CandidateContract.self, from: Data(contentsOf: folder.appendingPathComponent("candidate.json"))).status, .retired(promotedToLevel: 3))
        struct Entry: Decodable { let file: String; let definition: String; let valid: Bool }
        struct Index: Decodable { let fixtures: [Entry] }
        for entry in try JSONDecoder().decode(Index.self, from: Data(contentsOf: folder.appendingPathComponent("fixtures/index.json"))).fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent("fixtures/" + entry.file)))
            let schema = try JSONSchemaSubsetValidator(definition: entry.definition, inSchemaAt: folder.appendingPathComponent("spotify-controls.schema.json"))
            XCTAssertEqual(schema.errors(for: value).isEmpty, entry.valid, entry.file)
        }
        let stable = try JSONSchemaSubsetValidator(definition: "input", inSchemaAt: root.appendingPathComponent("schemas/spotify.schema.json"))
        XCTAssertFalse(stable.errors(for: .object(["bundle_id": .string("com.spotify.client"), "operation": .string("volume")])).isEmpty)
        XCTAssertEqual(try XCTUnwrap(ReviewedAppInterface.interface(for: SpotifyPlayback.bundleID)).request(operation: "next", arguments: [:]).handler, "next")
    }

    func testCandidateMismatchAndBundledOriginAreRefusedBeforeRegistrationOrBrokerDispatch() throws {
        let package = try package()
        let data = try JSONEncoder().encode(package.manifest)
        var retired = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        retired["candidate_contracts"] = [["name": "spotify_controls", "revision": 1]]
        let wrong = try PluginManifestLoader.decode(JSONSerialization.data(withJSONObject: retired))
        let registry = PluginRegistry()
        XCTAssertThrowsError(try registry.register(.init(rootURL: package.rootURL, manifest: wrong)))
        XCTAssertNoThrow(try registry.register(.init(rootURL: package.rootURL, manifest: package.manifest, origin: .bundled)))
        let oldContracts = PluginInterfaceContracts(levels: [1: PluginInterfaceContracts.levelOneMembers, 2: PluginInterfaceContracts.levelTwoMembers])
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
    func testRealHelperCannotForwardUndeclaredCandidateControlsToEvenAPermissiveBroker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Spotify.spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let package = try package(candidate: false)
        try JSONEncoder().encode(package.manifest).write(to: root.appendingPathComponent("manifest.json"))
        try "(function(){return {toast: String(spinnet.apps.perform({bundle_id:'com.spotify.client',operation:'volume'}).volume)};})()".write(to: root.appendingPathComponent("control.js"), atomically: true, encoding: .utf8)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let run = try helper.run(.init("control"), of: PluginUnderTest(packageAt: root), answering: SpotifyBoundaryAnswer())
        XCTAssertThrowsError(try run.result.get()) { error in
            guard case PluginRuntimeError.hostServiceFailed = error else { return XCTFail("Expected candidate gate, got \(error)") }
        }
        XCTAssertTrue(run.requests.isEmpty, "Undeclared operation must fail before reaching external dispatch")
    }
}

extension SpotifyControlsTests {
    func testCandidateSynchronousStableControlsDoNotWaitForAutomationConsent() throws {
        let candidate = try package()
        let action = try ActionConfiguration(id: ActionID("control"), pluginID: candidate.manifest.id, command: candidate.manifest.commands[0], input: .null)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: candidate.manifest.id, pluginVersion: candidate.manifest.version,
            capability: .controlExternalApp, scope: candidate.manifest.scope(for: .controlExternalApp))
        var prompts: [Bool] = []
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, reviewedAppPerformer: { _, allowsPrompt in
                prompts.append(allowsPrompt); return .null
            })
        for operation in ["play", "pause", "previous", "playback"] {
            _ = try broker.execute(request: .init(invocationID: "control", actionID: action.id, service: .performAppOperation,
                input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string(operation)]), operation: "apps.perform"),
                for: candidate, action: action)
        }
        XCTAssertEqual(prompts, [false, false, false, false])
    }
}

extension SpotifyControlsTests {
    func testHelperWireCannotEnableTrustedAutomationPromptFlagAndLegacyStillPrompts() throws {
        let candidate = try package()
        let action = try ActionConfiguration(id: ActionID("control"), pluginID: candidate.manifest.id, command: candidate.manifest.commands[0], input: .null)
        let original = PluginRuntimeHostServiceRequest(invocationID: "control", actionID: action.id, service: .performAppOperation,
            input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string("playback")]))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields["allowsAutomationPrompt"] = true; fields["allows_automation_prompt"] = true
        let forged = try JSONDecoder().decode(PluginRuntimeHostServiceRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertFalse(forged.allowsAutomationPrompt)
        var trusted = original; trusted.allowsAutomationPrompt = true
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trusted)) as? [String: Any])
        XCTAssertNil(encoded["allowsAutomationPrompt"]); XCTAssertNil(encoded["allows_automation_prompt"])
        let legacy = try package(candidate: false)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: legacy.manifest.id, pluginVersion: legacy.manifest.version,
            capability: .controlExternalApp, scope: legacy.manifest.scope(for: .controlExternalApp))
        var prompts: [Bool] = []
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, reviewedAppPerformer: { _, allowsPrompt in
                prompts.append(allowsPrompt); return .null
            })
        _ = try broker.execute(request: forged, for: candidate, action: action)
        _ = try broker.execute(request: original, for: legacy, action: action)
        XCTAssertEqual(prompts, [false, true])
    }
}
