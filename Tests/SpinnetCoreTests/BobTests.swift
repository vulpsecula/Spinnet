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

    static func grant(
        _ capabilities: [PluginCapability],
        to package: PluginPackage,
        in grants: PluginCapabilityGrantStore
    ) {
        for capability in capabilities {
            grants.setDecision(
                .granted,
                for: package.manifest.id,
                pluginVersion: package.manifest.version,
                capability: capability,
                scope: package.manifest.scope(for: capability)
            )
        }
    }
}

final class BobTests: XCTestCase {
    func testBobIsAStandalonePluginScopedToBobTranslationAndItsSelectionRead() throws {
        let package = try BobPluginFixture.load()
        let selection = CommandID("bob.selection_translate")

        XCTAssertEqual(package.manifest.id.rawValue, "com.spinnet.bob")
        XCTAssertEqual(package.manifest.name, "Bob")
        XCTAssertEqual(package.manifest.capabilities, [.controlExternalApp, .readSelectedText, .readCurrentClipboard])
        XCTAssertEqual(package.manifest.optionalCapabilities, [.readCurrentClipboard])
        XCTAssertTrue(PluginCapability.controlExternalApp.isSupportedByHostServices)
        XCTAssertEqual(package.manifest.capabilityScopes.map(\.capability),
                       [.controlExternalApp, .readSelectedText, .readCurrentClipboard])
        for command in package.manifest.commands {
            let readsSelection = command.id == selection
            XCTAssertEqual(package.manifest.declares(.readSelectedText, for: command.id), readsSelection)
            XCTAssertEqual(package.manifest.declares(.readCurrentClipboard, for: command.id), readsSelection)
        }
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
        BobPluginFixture.grant([.controlExternalApp, .readSelectedText], to: package, in: grants)

        var invocations: [ExternalAppInvocation] = []
        var selectedTextReads = 0
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in selectedTextReads += 1; return "Selected text" },
            clipboardWriter: { _ in },
            externalAppInvoker: { invocations.append($0) }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }

        let text = "Text with \"quotes\", a backslash \\, and a newline.\nNext line."
        let operations: [(String, String, JSONValue)] = [
            ("bob.selection_translate", "translateText", .null),
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
        XCTAssertEqual(selectedTextReads, 1, "Only the selection Command reads the selection")
        for (invocation, operation) in zip(invocations, operations) {
            XCTAssertEqual(invocation.bundleID, BobPluginFixture.bundleID)
            XCTAssertEqual(invocation.operationFamily, BobPluginFixture.operationFamily)
            let request = try JSONDecoder().decode(JSONValue.self, from: Data(invocation.requestJSON.utf8))
            var body: [String: JSONValue] = ["action": .string(operation.1)]
            if operation.1 == "translateText" {
                body["text"] = .string(operation.0 == "bob.selection_translate" ? "Selected text" : text)
            }
            XCTAssertEqual(request, .object([
                "path": .string("translate"),
                "body": .object(body)
            ]))
        }
    }

    func testBobSelectionIsReadBySpinnetWithBobInputAndBobsOwnReadAsFallbacks() throws {
        let package = try BobPluginFixture.load()
        let grants = PluginCapabilityGrantStore()
        BobPluginFixture.grant([.controlExternalApp, .readSelectedText], to: package, in: grants)

        var selection: () throws -> String = { "" }
        var copyFallbackAllowed: [Bool] = []
        var actions: [String] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { allowingCopyFallback in
                copyFallbackAllowed.append(allowingCopyFallback)
                return try selection()
            },
            clipboardWriter: { _ in },
            externalAppInvoker: { invocation in
                let request = try JSONDecoder().decode(JSONValue.self, from: Data(invocation.requestJSON.utf8))
                guard case .object(let fields) = request, case .object(let body)? = fields["body"],
                      case .string(let action)? = body["action"] else { return XCTFail("Unexpected Bob request") }
                actions.append(action)
            }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == "bob.selection_translate" })
        let action = try ActionConfiguration(id: ActionID("bob-selection"), pluginID: package.manifest.id,
                                             command: command, input: .null)

        // Nothing selected: Bob's input window, as Smart Jump opens its own.
        selection = { "  \n" }
        XCTAssertEqual(try supervisor.execute(action, in: package, using: broker), .null)
        // An unreadable selection is left to Bob's own reading.
        selection = { throw PluginHostServiceError.failed("No readable selection") }
        XCTAssertEqual(try supervisor.execute(action, in: package, using: broker), .null)
        XCTAssertEqual(actions, ["inputTranslate", "selectionTranslate"])
        XCTAssertEqual(copyFallbackAllowed, [false, false])

        BobPluginFixture.grant([.readCurrentClipboard], to: package, in: grants)
        selection = { "Copied from Telegram" }
        XCTAssertEqual(try supervisor.execute(action, in: package, using: broker), .null)
        XCTAssertEqual(actions.last, "translateText")
        XCTAssertEqual(copyFallbackAllowed.last, true, "The clipboard grant lets the read fall back to a copy")
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
            selectedTextProvider: { _ in "" },
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
        BobPluginFixture.grant([.controlExternalApp, .readSelectedText], to: package, in: grants)
        var nextError: PluginHostServiceError = .automationPermissionDenied
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" },
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
        BobPluginFixture.grant([.controlExternalApp, .readSelectedText], to: package, in: grants)
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
