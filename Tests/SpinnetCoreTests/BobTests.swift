import Foundation
import XCTest
@testable import SpinnetCore

private enum BobPluginFixture {
    static let bundleID = "com.hezongyidev.Bob"
    static let operationFamily = "translate"

    static func load() throws -> PluginPackage {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let loaded = try PluginManifestLoader.load(
            packageAt: root.appendingPathComponent("Plugins/Bob.spinnetplugin")
        )
        return PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
    }
}

final class BobTests: XCTestCase {
    func testBobIsAStandalonePluginScopedOnlyToBobTranslation() throws {
        let package = try BobPluginFixture.load()

        XCTAssertEqual(package.manifest.id.rawValue, "com.spinnet.bob")
        XCTAssertEqual(package.manifest.name, "Bob")
        XCTAssertEqual(package.manifest.capabilities, [.controlExternalApp])
        XCTAssertTrue(PluginCapability.controlExternalApp.isSupportedByHostServices)
        XCTAssertEqual(package.manifest.capabilityScopes.map(\.capability), [.controlExternalApp])
        XCTAssertEqual(
            package.manifest.scope(for: .controlExternalApp)?.externalApps,
            [.init(bundleID: BobPluginFixture.bundleID, operationFamilies: [BobPluginFixture.operationFamily])]
        )
        XCTAssertTrue(package.manifest.commands.allSatisfy { !$0.id.rawValue.hasPrefix("translator.") })
    }

    func testHostExplainsAnUnsupportedExternalAppOperationWithoutRemovingItsAction() throws {
        let command = CommandDeclaration(
            id: CommandID("other-app.translate"), title: "Translate with another app",
            execution: .javascript, scriptPath: "translate.js"
        )
        let scope = PluginCapabilityScope(
            capability: .controlExternalApp,
            commandIDs: [command.id],
            externalApps: [.init(bundleID: "com.example.translator", operationFamilies: ["translate"])]
        )
        let manifest = try PluginManifest(
            id: PluginID("com.example.external-translation"), name: "External Translation",
            version: "1.0.0", capabilities: [.controlExternalApp], capabilityScopes: [scope],
            commands: [command]
        )
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .controlExternalApp, scope: scope)
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true })
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/external-translation.spinnetplugin"),
                                            manifest: manifest))
        let action = try ActionConfiguration(id: ActionID("external-translation"), pluginID: manifest.id,
                                             command: command, input: .null)

        XCTAssertEqual(registry.availability(for: action), .unavailable(.externalAppOperationUnsupported))
        XCTAssertEqual(action.input, .null)
        XCTAssertEqual(action.commandID, command.id)
    }
}

extension PluginRuntimeTests {
    func testBobPluginUsesOnlyDeclaredTranslationOperationsAndSendsBobJSON() throws {
        let package = try BobPluginFixture.load()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .controlExternalApp,
            scope: package.manifest.scope(for: .controlExternalApp)
        )

        var invocations: [ExternalAppInvocation] = []
        var selectedTextReads = 0
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { selectedTextReads += 1; return "not used" },
            clipboardWriter: { _ in },
            externalAppInvoker: { invocations.append($0) }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }

        let text = "Text with \"quotes\", a backslash \\, and a newline.\nNext line."
        let operations: [(String, String, JSONValue)] = [
            ("bob.selection_translate", "selectionTranslate", .null),
            ("bob.snip_translate", "snipTranslate", .null),
            ("bob.input_translate", "inputTranslate", .null),
            ("bob.pasteboard_translate", "pasteboardTranslate", .null),
            ("bob.translate_text", "translateText", .string(text))
        ]

        for (commandID, _, input) in operations {
            let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
            let action = try ActionConfiguration(
                id: ActionID(commandID), pluginID: package.manifest.id, command: command, input: input
            )
            XCTAssertEqual(try supervisor.execute(action, in: package, using: broker), .null)
        }

        XCTAssertEqual(invocations.count, operations.count)
        XCTAssertEqual(selectedTextReads, 0, "Bob owns selection capture; the Plugin never reads it")
        for (invocation, operation) in zip(invocations, operations) {
            XCTAssertEqual(invocation.bundleID, BobPluginFixture.bundleID)
            XCTAssertEqual(invocation.operationFamily, BobPluginFixture.operationFamily)
            let request = try JSONDecoder().decode(JSONValue.self, from: Data(invocation.requestJSON.utf8))
            var body: [String: JSONValue] = ["action": .string(operation.1)]
            if operation.1 == "translateText" { body["text"] = .string(text) }
            XCTAssertEqual(request, .object([
                "path": .string("translate"),
                "body": .object(body)
            ]))
        }
    }

    func testBobHostServiceChecksCapabilityTargetAndOperationFamilyBeforeSending() throws {
        let package = try BobPluginFixture.load()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(
            .denied,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .controlExternalApp,
            scope: package.manifest.scope(for: .controlExternalApp)
        )

        var invocations: [ExternalAppInvocation] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { "" },
            clipboardWriter: { _ in },
            externalAppInvoker: { invocations.append($0) }
        )
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == "bob.selection_translate" })
        let action = try ActionConfiguration(id: ActionID("bob.selection_translate"), pluginID: package.manifest.id,
                                             command: command, input: .null)

        func input(bundleID: String, operationFamily: String, action: String = "selectionTranslate") -> JSONValue {
            .object([
                "bundle_id": .string(bundleID),
                "operation_family": .string(operationFamily),
                "request": .object([
                    "path": .string("translate"),
                    "body": .object(["action": .string(action)])
                ])
            ])
        }

        func request(_ input: JSONValue) -> PluginRuntimeHostServiceRequest {
            PluginRuntimeHostServiceRequest(
                invocationID: "test-invocation", actionID: action.id,
                service: .invokeExternalApp, input: input
            )
        }

        XCTAssertThrowsError(try broker.execute(
            request: request(input(bundleID: BobPluginFixture.bundleID, operationFamily: "translate")),
            for: package, action: action
        )) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.controlExternalApp))
        }
        grants.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .controlExternalApp,
            scope: package.manifest.scope(for: .controlExternalApp)
        )

        XCTAssertThrowsError(try broker.execute(
            request: request(input(bundleID: "example.unlisted.app", operationFamily: "translate")),
            for: package, action: action
        )) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.controlExternalApp))
        }
        XCTAssertThrowsError(try broker.execute(
            request: request(input(bundleID: BobPluginFixture.bundleID, operationFamily: "ocr")),
            for: package, action: action
        )) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.controlExternalApp))
        }
        XCTAssertThrowsError(try broker.execute(
            request: request(input(
                bundleID: BobPluginFixture.bundleID,
                operationFamily: BobPluginFixture.operationFamily,
                action: "unsupportedTranslateOperation"
            )),
            for: package, action: action
        )) { error in
            XCTAssertEqual(
                error as? PluginHostServiceError,
                .externalAppOperationUnsupported("Bob does not support this translation operation")
            )
        }
        XCTAssertTrue(invocations.isEmpty)

        func textInput(_ text: String) -> JSONValue {
            .object([
                "bundle_id": .string(BobPluginFixture.bundleID),
                "operation_family": .string(BobPluginFixture.operationFamily),
                "request": .object([
                    "path": .string("translate"),
                    "body": .object([
                        "action": .string("translateText"),
                        "text": .string(text)
                    ])
                ])
            ])
        }

        let boundaryText = String(repeating: "\u{1}", count: ExternalAppBudgets.maximumRequestTextBytes)
        XCTAssertNoThrow(try broker.execute(
            request: request(textInput(boundaryText)), for: package, action: action
        ))
        XCTAssertEqual(invocations.count, 1)
        XCTAssertLessThanOrEqual(invocations[0].requestJSON.utf8.count, PluginRuntimeProtocol.maximumMessageBytes)

        let oversizedText = boundaryText + "\u{1}"
        XCTAssertThrowsError(try broker.execute(
            request: request(textInput(oversizedText)), for: package, action: action
        )) { error in
            XCTAssertEqual(
                error as? PluginHostServiceError,
                .invalidInput("Bob translateText needs nonempty text up to 128 KiB")
            )
        }
        XCTAssertEqual(invocations.count, 1, "Oversized text must be rejected before contacting Bob")
    }

    func testBobAdapterErrorsRemainDistinctThroughThePluginHelper() throws {
        let package = try BobPluginFixture.load()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .controlExternalApp,
            scope: package.manifest.scope(for: .controlExternalApp)
        )
        var nextError: PluginHostServiceError = .automationPermissionDenied
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { "" },
            clipboardWriter: { _ in },
            externalAppInvoker: { _ in throw nextError }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == "bob.selection_translate" })
        let action = try ActionConfiguration(id: ActionID("bob-errors"), pluginID: package.manifest.id,
                                             command: command, input: .null)
        let failures: [(PluginHostServiceError, ActionFailureCategory, String)] = [
            (.automationPermissionDenied, .automationPermissionDenied,
             "Allow Spinnet to control Bob in System Settings > Privacy & Security > Automation, then try again"),
            (.externalAppMissing("Install Bob to use Bob Commands"),
             .externalAppMissing, "Install Bob to use Bob Commands"),
            (.externalAppOperationUnsupported(
                "This Bob version does not support the requested translation operation; update Bob and try again"
            ), .externalAppOperationUnsupported,
             "This Bob version does not support the requested translation operation; update Bob and try again")
        ]

        for (hostError, category, message) in failures {
            nextError = hostError
            XCTAssertThrowsError(try supervisor.execute(action, in: package, using: broker)) { error in
                guard let runtimeError = error as? PluginRuntimeError else {
                    return XCTFail("Unexpected failure: \(error)")
                }
                XCTAssertEqual(runtimeError.failureCategory, category)
                XCTAssertEqual(runtimeError.description, message)
            }
        }
    }

    func testMissingBobDisablesButKeepsTheConfiguredBobAction() throws {
        let package = try BobPluginFixture.load()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .controlExternalApp,
            scope: package.manifest.scope(for: .controlExternalApp)
        )
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in false })
        try registry.register(package)
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == "bob.selection_translate" })
        let action = try ActionConfiguration(id: ActionID("bob-selection"), pluginID: package.manifest.id,
                                             command: command, input: .null)
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [try MenuItemConfiguration(primaryActionID: action.id)])
        )
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)

        XCTAssertEqual(editor.availability(for: action.id), .unavailable(.externalAppMissing))
        XCTAssertEqual(configuration.actions, [action])
        XCTAssertEqual(action.commandID, CommandID("bob.selection_translate"))
    }
}
