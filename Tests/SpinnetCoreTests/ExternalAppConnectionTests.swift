import SpinnetTestSupport
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class ExternalAppConnectionTests: XCTestCase {
    private func data(candidate: Bool = true, connections: String = "[{\"bundle_id\":\"com.spotify.client\",\"command_ids\":[\"control\"]}]", families: String = "\"playback_read\",\"playback_control\"", scopeCommands: String = "\"control\"") -> Data {
        Data("""
        {"api_level":\(candidate ? 3 : 2),"protocol_version":"1.0","id":"test.connection","name":"Connection","version":"1.0",
        "external_app_connections":\(connections),
        "capabilities":["control_external_app"],"optional_capabilities":["control_external_app"],
        "capability_scopes":[{"capability":"control_external_app","command_ids":[\(scopeCommands)],"data_types":[],"includes_existing_host_data":false,"https_hosts":[],"external_apps":[{"bundle_id":"com.spotify.client","operation_families":[\(families)]}]}],
        "commands":[{"id":"control","title":"Control","execution":"javascript","script":"control.js"}, {"id":"other","title":"Other","execution":"javascript","script":"other.js"}]}
        """.utf8)
    }

    func testUndeclaredConnectionCannotBeSilentlyIgnored() throws {
        XCTAssertThrowsError(try PluginManifestLoader.decode(data(candidate: false)))
    }
    func testOptionalCapabilityBecomesRequiredOnlyForDependentCommandsAndRechecksOwner() throws {
        let manifest = try PluginManifestLoader.decode(data())
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/connection-test"), manifest: manifest)
        let grants = PluginCapabilityGrantStore()
        var reads = 0
        var state = ExternalAppConnectionStatus.permissionNeeded
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true },
            externalAppConnectionStatus: { _ in reads += 1; return state })
        try registry.register(package)
        let check = try XCTUnwrap(registry.externalAppConnectionChecks(for: manifest.id).first)
        let action = try ActionConfiguration(id: ActionID("test"), pluginID: manifest.id, command: manifest.commands[0], input: .null)
        let other = try ActionConfiguration(id: ActionID("other"), pluginID: manifest.id, command: manifest.commands[1], input: .null)
        XCTAssertEqual(registry.externalAppConnectionStatus(for: check), .capabilityDenied)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(registry.availability(for: action), .unavailable(.capabilityDenied))
        XCTAssertEqual(registry.availability(for: other), .available)
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
            capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        XCTAssertEqual(registry.externalAppConnectionStatus(for: check), .permissionNeeded)
        XCTAssertFalse(registry.availability(for: action).isAvailable)
        state = .notRunning
        XCTAssertTrue(registry.externalAppConnectionStatus(for: check).isConnected)
        XCTAssertFalse(registry.availability(for: action).isAvailable)
        state = .ready
        XCTAssertEqual(registry.availability(for: action), .available)
        try registry.replace(package)
        XCTAssertEqual(registry.externalAppConnectionStatus(for: check), .ownerInvalid)
        XCTAssertFalse(registry.externalAppConnectionAuthorization(for: check).isAvailable)
    }

    func testConnectionDeclarationsRejectUnreviewedTargetsAndExecutableMetadata() throws {
        for connections in [
            "[]",
            "[{\"bundle_id\":\"com.hezongyidev.Bob\",\"command_ids\":[\"control\"]}]",
            "[{\"bundle_id\":\"com.spotify.client\",\"command_ids\":[\"missing\"]}]",
            "[{\"bundle_id\":\"com.spotify.client\",\"command_ids\":[\"control\",\"control\"]}]",
            "[{\"bundle_id\":\"com.spotify.client\",\"command_ids\":[\"control\"],\"operation\":\"play\"}]"
        ] { XCTAssertThrowsError(try PluginManifestLoader.decode(data(connections: connections)), connections) }
        XCTAssertThrowsError(try PluginManifestLoader.decode(data(families: "\"playback_control\"")))
        XCTAssertThrowsError(try PluginManifestLoader.decode(data(scopeCommands: "\"other\"")))
    }

    func testNewPlacementIsBlockedButExistingConfigurationSurvivesRevocation() throws {
        let manifest = try PluginManifestLoader.decode(data())
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
            capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        var state = ExternalAppConnectionStatus.permissionNeeded
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true },
            externalAppConnectionStatus: { _ in state })
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/connection-test"), manifest: manifest))
        let empty = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        let editor = HostConfigurationEditor(registry: registry, configuration: empty)
        func configure() throws -> HostConfiguration {
            try editor.configuredMenuItem(at: 0, pluginID: manifest.id, primaryCommandID: CommandID("control"), replacingEmptySlot: true)
        }
        XCTAssertThrowsError(try configure())
        XCTAssertEqual(editor.configuration, empty)
        state = .notRunning
        let configured = try configure()
        let existing = HostConfigurationEditor(registry: registry, configuration: configured)
        state = .permissionDenied
        XCTAssertNoThrow(try existing.configuredMenuItem(at: 0, pluginID: manifest.id,
            primaryCommandID: CommandID("control")))
        XCTAssertEqual(existing.configuration, configured)
    }

    func testReadinessProviderCanReenterRegistryAndCannotReturnSuccessAfterReplacement() throws {
        let manifest = try PluginManifestLoader.decode(data())
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/connection-test"), manifest: manifest)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
            capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        var registry: PluginRegistry!
        registry = PluginRegistry(grantStore: grants, externalAppConnectionStatus: { _ in
            XCTAssertNotNil(registry.package(for: manifest.id))
            try! registry.replace(package)
            return .ready
        })
        try registry.register(package)
        let check = try XCTUnwrap(registry.externalAppConnectionChecks(for: manifest.id).first)
        XCTAssertEqual(registry.externalAppConnectionStatus(for: check), .ownerInvalid)
    }

    func testDependentCommandsCannotPromptEvenWithoutSpotifyControlsCandidate() throws {
        let manifest = try PluginManifestLoader.decode(data())
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/connection-test"), manifest: manifest)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
            capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        var state = ExternalAppConnectionStatus.ready
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true }, externalAppConnectionStatus: { _ in state })
        try registry.register(package)
        let action = try ActionConfiguration(id: ActionID("control"), pluginID: manifest.id, command: manifest.commands[0], input: .null)
        var sends = 0
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            reviewedAppPerformer: { _, allowsPrompt in
                XCTAssertFalse(allowsPrompt)
                sends += 1
                return .null
            }, pluginRegistry: registry)
        let request = PluginRuntimeHostServiceRequest(invocationID: "control", actionID: action.id,
            service: .performAppOperation, input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string("pause")]))
        XCTAssertNoThrow(try broker.execute(request: request, for: package, action: action))
        state = .permissionDenied
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action))
        XCTAssertEqual(sends, 1)
    }

    func testStableConnectionSchemaRequiresLevelThreeAndRefusesRetiredDeclarations() throws {
        let root = TestRepository.root
        let schema = try JSONSchemaSubsetValidator(schemaAt: root.appendingPathComponent("PluginAPI/schemas/manifest-level-3.schema.json"))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        func value() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: manifest)) }
        XCTAssertEqual(schema.errors(for: try value()), [])
        manifest["candidate_contracts"] = [["name": "external_app_connections", "revision": 1]]
        XCTAssertFalse(schema.errors(for: try value()).isEmpty)
        XCTAssertThrowsError(try PluginInterfaceContracts.host.check(PluginManifestLoader.decode(JSONEncoder().encode(value())), origin: .installed))
        manifest["candidate_contracts"] = nil
        manifest["api_level"] = 2
        XCTAssertFalse(schema.errors(for: try value()).isEmpty)
    }

    func testExactCandidateIsEnforcedAtInstallRegistrationAndScriptRuntime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Connection.spinnetplugin")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try data().write(to: source.appendingPathComponent("manifest.json"))
        try Data("null".utf8).write(to: source.appendingPathComponent("control.js"))
        try Data("null".utf8).write(to: source.appendingPathComponent("other.js"))
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        let installation = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"), registry: registry,
            grants: grants, persistGrants: {})
        XCTAssertNoThrow(try installation.review(source))
        try installation.install(from: source)
        XCTAssertNotNil(registry.package(for: PluginID("test.connection")))
        let withoutCandidate = PluginInterfaceContracts(levels: [1: PluginInterfaceContracts.levelOneMembers, 2: PluginInterfaceContracts.levelTwoMembers])
        let refusedRegistry = PluginRegistry(contracts: withoutCandidate)
        let plugin = try PluginUnderTest(packageAt: source)
        XCTAssertThrowsError(try refusedRegistry.register(plugin.package))
        let refusedInstallation = PluginInstallationStore(directory: directory.appendingPathComponent("Refused"), registry: refusedRegistry,
            grants: grants, persistGrants: {})
        XCTAssertThrowsError(try refusedInstallation.review(source))
        XCTAssertThrowsError(try refusedInstallation.install(from: source))
        let helper = try PluginTestHelper(contracts: withoutCandidate)
        defer { helper.shutdown() }
        let run = helper.run(PluginTestInvocation("control"), of: plugin, answering: RecordedHostServices())
        XCTAssertThrowsError(try run.result.get())
        XCTAssertTrue(run.requests.isEmpty)
    }

    func testReplacingExistingIndependentActionCannotBypassConnectionSetup() throws {
        let manifest = try PluginManifestLoader.decode(data())
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
            capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        let registry = PluginRegistry(grantStore: grants, externalAppConnectionStatus: { _ in .permissionNeeded })
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/connection-test"), manifest: manifest))
        let originalAction = try ActionConfiguration(id: ActionID("original"), pluginID: manifest.id,
            command: manifest.commands[1], input: .null)
        let item = try MenuItemConfiguration(primaryActionID: originalAction.id)
        let original = try HostConfiguration(actions: [originalAction], menu: MenuConfiguration(items: [item]))
        let editor = HostConfigurationEditor(registry: registry, configuration: original)
        XCTAssertThrowsError(try editor.configuredMenuItem(at: 0, pluginID: manifest.id, primaryCommandID: CommandID("control")))
        XCTAssertEqual(editor.configuration, original)
        XCTAssertNoThrow(try editor.configuredMenuItem(at: 0, pluginID: manifest.id, primaryCommandID: CommandID("other")))
    }

}
