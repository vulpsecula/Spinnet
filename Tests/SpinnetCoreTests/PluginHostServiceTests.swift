import XCTest
@testable import SpinnetCore

final class PluginHostServiceTests: XCTestCase {

    /// ADR 0002 states that presenting the Host's own Clipboard History window
    /// is a Host-internal privilege a third-party Plugin cannot reach. Only a
    /// Bundled Plugin may ask for it; a granted Capability buys the data, not
    /// the window.
    func testPresentingClipboardHistoryIsRefusedToAThirdPartyPlugin() throws {
        let manifest = try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0",
          "id": "com.example.history-peeker",
          "name": "History Peeker",
          "version": "1.0.0",
          "capabilities": ["read_clipboard_history"],
          "capability_scopes": [{
            "capability": "read_clipboard_history",
            "command_ids": ["peek"],
            "data_types": ["text"],
            "includes_existing_host_data": true,
            "https_hosts": [],
            "external_apps": []
          }],
          "preset": {
            "readiness": "ready_to_use",
            "is_configurable": false,
            "default_primary_command_id": "peek"
          },
          "commands": [{
            "id": "peek", "title": "Peek", "execution": "javascript",
            "is_configurable": false, "script": "peek.js"
          }]
        }
        """.utf8))
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/peeker"), manifest: manifest)
        let action = try ActionConfiguration(
            id: ActionID("peek"), pluginID: manifest.id,
            command: manifest.commands[0], input: .null
        )

        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .readClipboardHistory,
                           scope: manifest.scope(for: .readClipboardHistory))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))

        var presentations = 0
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in false },
            selectedTextProvider: { "" }, clipboardWriter: { _ in },
            clipboardHistoryProvider: { types, offset in try store.query(dataTypes: types, offset: offset) },
            clipboardHistoryPresenter: { _, _ in presentations += 1 }
        )
        func request(_ service: PluginHostService, _ input: JSONValue) -> PluginRuntimeHostServiceRequest {
            PluginRuntimeHostServiceRequest(
                invocationID: UUID().uuidString, actionID: action.id,
                requestID: UUID().uuidString, service: service, input: input
            )
        }

        XCTAssertThrowsError(
            try broker.execute(request: request(.presentClipboardHistory, .null),
                               for: package, action: action)
        )
        XCTAssertEqual(presentations, 0, "A third-party Plugin opened a Host-owned window")

        // Reading is what the Capability bought, and it still works.
        XCTAssertNoThrow(
            try broker.execute(request: request(.readClipboardHistory, .null),
                               for: package, action: action)
        )
        // The privilege is no longer reachable through the reading service.
        XCTAssertThrowsError(
            try broker.execute(request: request(.readClipboardHistory,
                                                .object(["present": .bool(true)])),
                               for: package, action: action)
        )
        XCTAssertEqual(presentations, 0)
    }
    func testCapabilityGrantStoreKeepsAnExplicitDecisionForEachDeclaredCapability() throws {
        let pluginID = PluginID("com.example.fixture")
        let store = PluginCapabilityGrantStore()

        store.register(
            pluginID: pluginID,
            pluginVersion: "1.0.0",
            capabilities: [.readSelectedText, .writeClipboard]
        )

        XCTAssertEqual(
            store.decision(
                for: pluginID,
                pluginVersion: "1.0.0",
                capability: .readSelectedText
            ),
            .notDetermined
        )

        store.setDecision(
            .granted,
            for: pluginID,
            pluginVersion: "1.0.0",
            capability: .readSelectedText
        )
        store.setDecision(
            .denied,
            for: pluginID,
            pluginVersion: "1.0.0",
            capability: .writeClipboard
        )

        XCTAssertEqual(
            store.grants(
                for: pluginID,
                pluginVersion: "1.0.0",
                capabilities: [.readSelectedText, .writeClipboard]
            ),
            [
                PluginCapabilityGrant(
                    pluginID: pluginID,
                    pluginVersion: "1.0.0",
                    capability: .readSelectedText,
                    decision: .granted
                ),
                PluginCapabilityGrant(
                    pluginID: pluginID,
                    pluginVersion: "1.0.0",
                    capability: .writeClipboard,
                    decision: .denied
                )
            ]
        )
        XCTAssertEqual(
            store.allGrants,
            [
                PluginCapabilityGrant(
                    pluginID: pluginID,
                    pluginVersion: "1.0.0",
                    capability: .readSelectedText,
                    decision: .granted
                ),
                PluginCapabilityGrant(
                    pluginID: pluginID,
                    pluginVersion: "1.0.0",
                    capability: .writeClipboard,
                    decision: .denied
                )
            ]
        )

        let restored = PluginCapabilityGrantStore(
            grants: try JSONDecoder().decode(
                [PluginCapabilityGrant].self,
                from: JSONEncoder().encode(store.allGrants)
            )
        )
        XCTAssertEqual(restored.allGrants, store.allGrants)
    }

    func testCapabilityGrantStoreRequiresNewConsentForANewPluginVersion() throws {
        let pluginID = PluginID("com.example.fixture")
        let store = PluginCapabilityGrantStore()

        store.setDecision(
            .granted,
            for: pluginID,
            pluginVersion: "1.0.0",
            capability: .readSelectedText
        )
        store.register(
            pluginID: pluginID,
            pluginVersion: "2.0.0",
            capabilities: [.readSelectedText]
        )

        XCTAssertEqual(
            store.decision(
                for: pluginID,
                pluginVersion: "1.0.0",
                capability: .readSelectedText
            ),
            .granted
        )
        XCTAssertEqual(
            store.decision(
                for: pluginID,
                pluginVersion: "2.0.0",
                capability: .readSelectedText
            ),
            .notDetermined
        )
    }

    func testCapabilityCheckedBrokerUsesCurrentGrantAndSystemPermissionAtRequestTime() throws {
        let pluginID = PluginID("com.example.fixture")
        let package = try makePackage(pluginID: pluginID)
        let action = try ActionConfiguration(
            id: ActionID("action-1"),
            pluginID: pluginID,
            command: package.manifest.commands[0],
            input: .null
        )
        let store = PluginCapabilityGrantStore()
        store.setDecision(
            .granted,
            for: pluginID,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        store.setDecision(
            .granted,
            for: pluginID,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        var accessibilityGranted = true
        var clipboardValue: String?
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: store,
            systemPermissionCheck: { _ in accessibilityGranted },
            selectedTextProvider: { "selected text" },
            clipboardWriter: { clipboardValue = $0 }
        )

        let readRequest = PluginRuntimeHostServiceRequest(
            invocationID: "invocation-1",
            actionID: action.id,
            requestID: "request-1",
            service: .readSelectedText,
            input: .null
        )
        XCTAssertEqual(
            try broker.execute(request: readRequest, for: package, action: action),
            .string("selected text")
        )

        let writeRequest = PluginRuntimeHostServiceRequest(
            invocationID: "invocation-1",
            actionID: action.id,
            requestID: "request-2",
            service: .writeClipboard,
            input: .string("transformed")
        )
        _ = try broker.execute(request: writeRequest, for: package, action: action)
        XCTAssertEqual(clipboardValue, "transformed")

        store.setDecision(
            .denied,
            for: pluginID,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        XCTAssertThrowsError(
            try broker.execute(request: writeRequest, for: package, action: action)
        ) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.writeClipboard))
        }

        store.setDecision(
            .granted,
            for: pluginID,
            pluginVersion: package.manifest.version,
            capability: .writeClipboard
        )
        accessibilityGranted = false
        XCTAssertThrowsError(
            try broker.execute(request: readRequest, for: package, action: action)
        ) { error in
            XCTAssertEqual(
                error as? PluginHostServiceError,
                .systemPermissionDenied(.accessibility)
            )
        }
    }

    func testBrokerRejectsAServiceThePluginDidNotDeclare() throws {
        let pluginID = PluginID("com.example.fixture")
        let command = CommandDeclaration(
            id: CommandID("fixture.transform"),
            title: "Transform",
            execution: .javascript,
            script: "transform.js"
        )
        let manifest = try PluginManifest(
            id: pluginID,
            name: "Fixture",
            version: "1.0.0",
            capabilities: [.readSelectedText],
            commands: [command]
        )
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        )
        let action = try ActionConfiguration(
            id: ActionID("action-1"),
            pluginID: pluginID,
            command: command,
            input: .null
        )
        let store = PluginCapabilityGrantStore()
        store.setDecision(
            .granted,
            for: pluginID,
            pluginVersion: package.manifest.version,
            capability: .readSelectedText
        )
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: store,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { "selected text" },
            clipboardWriter: { _ in }
        )
        let request = PluginRuntimeHostServiceRequest(
            invocationID: "invocation-1",
            actionID: action.id,
            requestID: "request-1",
            service: .writeClipboard,
            input: .string("transformed")
        )

        XCTAssertThrowsError(
            try broker.execute(request: request, for: package, action: action)
        ) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.writeClipboard))
        }
    }

    private func makePackage(pluginID: PluginID) throws -> PluginPackage {
        let command = CommandDeclaration(
            id: CommandID("fixture.transform"),
            title: "Transform",
            execution: .javascript,
            script: "transform.js"
        )
        return PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: try PluginManifest(
                id: pluginID,
                name: "Fixture",
                version: "1.0.0",
                capabilities: [.readSelectedText, .writeClipboard],
                commands: [command]
            )
        )
    }
}
