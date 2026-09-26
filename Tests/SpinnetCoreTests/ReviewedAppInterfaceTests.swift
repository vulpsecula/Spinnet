import XCTest
@testable import SpinnetCore

/// Apple Events reach an External App only through a Reviewed App Interface
/// the Host ships (ADR 0012). A Plugin's scope selects its operation
/// families; `perform_app_operation` names one operation and its arguments,
/// and the Host checks both against the interface before anything is sent.
final class ReviewedAppInterfaceTests: XCTestCase {
    private let bob = "com.hezongyidev.Bob"

    private func package(externalApps: [PluginCapabilityScope.ExternalAppScope]) throws -> PluginPackage {
        let command = CommandDeclaration(id: CommandID("example.translate"), title: "Translate",
                                         execution: .javascript, scriptPath: "translate.js")
        let manifest = try PluginManifest(
            id: PluginID("com.example.translate-adapter"), name: "Translate Adapter", version: "1.0.0",
            capabilities: [.controlExternalApp],
            capabilityScopes: [PluginCapabilityScope(capability: .controlExternalApp, commandIDs: [command.id],
                                                     externalApps: externalApps)],
            commands: [command]
        )
        return PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/translate-adapter"), manifest: manifest)
    }

    private func broker(for package: PluginPackage, granted: Bool = true,
                        sent: @escaping (AppleEventRequest) throws -> Void) -> CapabilityCheckedHostServiceBroker {
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(granted ? .granted : .denied, for: package.manifest.id,
                           pluginVersion: package.manifest.version, capability: .controlExternalApp,
                           scope: package.manifest.scope(for: .controlExternalApp))
        return CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            appleEventSender: sent
        )
    }

    private func perform(_ input: JSONValue, with broker: CapabilityCheckedHostServiceBroker,
                         in package: PluginPackage) throws -> JSONValue {
        let action = try ActionConfiguration(id: ActionID("translate"), pluginID: package.manifest.id,
                                             command: package.manifest.commands[0], input: .null)
        return try broker.execute(
            request: PluginRuntimeHostServiceRequest(invocationID: "invocation", actionID: action.id,
                                                     service: .performAppOperation, input: input),
            for: package, action: action
        )
    }

    private func operation(_ name: String, bundleID: String? = nil,
                           arguments: [String: JSONValue]? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["bundle_id": .string(bundleID ?? bob), "operation": .string(name)]
        if let arguments { fields["arguments"] = .object(arguments) }
        return .object(fields)
    }

    func testBobsInterfaceDescribesItsRequestHandlerAndTranslationOperations() throws {
        let interface = try XCTUnwrap(ReviewedAppInterface.interface(for: bob))

        XCTAssertEqual(interface.name, "Bob")
        XCTAssertEqual(interface.handler, "request")
        XCTAssertEqual(interface.operations.map(\.name), [
            "selectionTranslate", "snipTranslate", "inputTranslate", "pasteboardTranslate", "translateText"
        ])
        XCTAssertEqual(Set(interface.operations.map(\.family)), ["translate"])
        XCTAssertEqual(interface.operations.last?.parameters,
                       [.init(key: "text", maximumUTF8Bytes: ExternalAppBudgets.maximumRequestTextBytes)])
        XCTAssertNil(ReviewedAppInterface.interface(for: "cc.ffitch.shottr"),
                     "an app reached by links needs no reviewed Apple Events")
    }

    func testAnOperationIsSentAsTheJSONRequestBobsHandlerDocuments() throws {
        let package = try package(externalApps: [.init(bundleID: bob, operationFamilies: ["translate"])])
        var sent: [AppleEventRequest] = []
        let broker = broker(for: package) { sent.append($0) }

        XCTAssertEqual(try perform(operation("snipTranslate"), with: broker, in: package), .null)
        XCTAssertEqual(try perform(operation("translateText", arguments: ["text": .string("Hi \"there\"\n")]),
                                   with: broker, in: package), .null)

        XCTAssertEqual(sent, [
            AppleEventRequest(bundleID: bob, applicationName: "Bob", handler: "request",
                              argument: #"{"body":{"action":"snipTranslate"},"path":"translate"}"#),
            AppleEventRequest(bundleID: bob, applicationName: "Bob", handler: "request",
                              argument: #"{"body":{"action":"translateText","text":"Hi \"there\"\n"},"path":"translate"}"#)
        ])
    }

    func testTheHostChecksScopeInterfaceOperationAndArgumentsBeforeSending() throws {
        let package = try package(externalApps: [
            .init(bundleID: bob, operationFamilies: ["translate"]),
            .init(bundleID: "com.example.unreviewed", operationFamilies: ["translate"])
        ])
        var sent: [AppleEventRequest] = []
        let broker = broker(for: package) { sent.append($0) }
        let cases: [(String, JSONValue, PluginHostServiceError)] = [
            ("an app outside the scope", operation("translateText", bundleID: "com.example.other",
                                                    arguments: ["text": .string("x")]),
             .capabilityDenied(.controlExternalApp)),
            ("an app without a Reviewed App Interface", operation("translate", bundleID: "com.example.unreviewed"),
             .externalAppOperationUnsupported("com.example.unreviewed has no Apple Events interface Spinnet has reviewed")),
            ("an operation the interface lacks", operation("deleteHistory"),
             .externalAppOperationUnsupported("Bob does not support deleteHistory")),
            ("text for an operation without parameters", operation("snipTranslate", arguments: ["text": .string("x")]),
             .invalidInput("Bob snipTranslate takes no arguments")),
            ("a missing argument", operation("translateText"),
             .invalidInput("Bob translateText needs nonempty text up to 128 KiB")),
            ("blank text", operation("translateText", arguments: ["text": .string(" \n")]),
             .invalidInput("Bob translateText needs nonempty text up to 128 KiB")),
            ("text that is not a string", operation("translateText", arguments: ["text": .number(1)]),
             .invalidInput("Bob translateText needs nonempty text up to 128 KiB")),
            ("an undeclared argument", operation("translateText", arguments: ["text": .string("x"), "to": .string("fr")]),
             .invalidInput("Bob translateText takes only text")),
            ("another shape", .object(["bundle_id": .string(bob), "operation_family": .string("translate")]),
             .invalidInput("perform_app_operation expects bundle_id, operation, and optional arguments"))
        ]

        for (name, input, expected) in cases {
            XCTAssertThrowsError(try perform(input, with: broker, in: package), name) { error in
                XCTAssertEqual(error as? PluginHostServiceError, expected, name)
            }
        }
        XCTAssertTrue(sent.isEmpty)
    }

    func testAnOperationOutsideTheDeclaredFamiliesIsRefused() throws {
        let package = try package(externalApps: [.init(bundleID: bob, operationFamilies: ["ocr"])])
        var sent: [AppleEventRequest] = []
        let broker = broker(for: package) { sent.append($0) }

        XCTAssertThrowsError(try perform(operation("snipTranslate"), with: broker, in: package)) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.controlExternalApp))
        }
        XCTAssertTrue(sent.isEmpty)
    }

    func testTextUpToTheBudgetIsSentAndAnyMoreIsRefused() throws {
        let package = try package(externalApps: [.init(bundleID: bob, operationFamilies: ["translate"])])
        var sent: [AppleEventRequest] = []
        let broker = broker(for: package) { sent.append($0) }
        let boundary = String(repeating: "\u{1}", count: ExternalAppBudgets.maximumRequestTextBytes)

        XCTAssertNoThrow(try perform(operation("translateText", arguments: ["text": .string(boundary)]),
                                     with: broker, in: package))
        XCTAssertLessThanOrEqual(sent.first?.argument.utf8.count ?? .max, PluginRuntimeProtocol.maximumMessageBytes)
        XCTAssertThrowsError(try perform(operation("translateText", arguments: ["text": .string(boundary + "\u{1}")]),
                                         with: broker, in: package)) { error in
            XCTAssertEqual(error as? PluginHostServiceError,
                           .invalidInput("Bob translateText needs nonempty text up to 128 KiB"))
        }
        XCTAssertEqual(sent.count, 1)
    }

    func testADeniedGrantSendsNothing() throws {
        let package = try package(externalApps: [.init(bundleID: bob, operationFamilies: ["translate"])])
        var sent: [AppleEventRequest] = []
        let broker = broker(for: package, granted: false) { sent.append($0) }

        XCTAssertThrowsError(try perform(operation("inputTranslate"), with: broker, in: package)) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.controlExternalApp))
        }
        XCTAssertTrue(sent.isEmpty)
    }

    /// Operation families the Host has no Reviewed App Interface for leave
    /// the Command unavailable; a missing app names itself.
    func testAvailabilityNamesTheMissingAppAndRefusesUnreviewedFamilies() throws {
        for (apps, exists, expected) in [
            ([PluginCapabilityScope.ExternalAppScope(bundleID: bob, operationFamilies: ["translate"])], false,
             ActionAvailability.unavailable(.externalAppMissing("Bob"))),
            ([.init(bundleID: bob, operationFamilies: ["translate"])], true, .available),
            ([.init(bundleID: bob, operationFamilies: ["ocr"])], true, .unavailable(.externalAppOperationUnsupported)),
            ([.init(bundleID: "com.example.unreviewed", operationFamilies: ["translate"])], true,
             .unavailable(.externalAppOperationUnsupported)),
            ([.init(bundleID: "com.example.links", name: "Links", deepLinkTemplates: [
                DeepLinkTemplate(id: "open", url: "links-example://open")
            ])], false, .unavailable(.externalAppMissing("Links")))
        ] {
            let package = try package(externalApps: apps)
            let grants = PluginCapabilityGrantStore()
            grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: .controlExternalApp, scope: package.manifest.scope(for: .controlExternalApp))
            let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in exists })
            try registry.register(package)
            let action = try ActionConfiguration(id: ActionID("translate"), pluginID: package.manifest.id,
                                                 command: package.manifest.commands[0], input: .null)
            XCTAssertEqual(registry.availability(for: action), expected, "\(apps)")
        }
        XCTAssertEqual(ActionUnavailableReason.externalAppMissing("Bob").description, "Install Bob to use Bob Commands")
    }
}
