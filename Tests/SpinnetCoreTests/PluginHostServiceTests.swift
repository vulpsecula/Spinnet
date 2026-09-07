import XCTest
@testable import SpinnetCore

final class PluginHostServiceTests: XCTestCase {
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
