import XCTest
@testable import SpinnetCore

/// The repository's Translator package, registered the way the Host
/// registers a Plugin that ships with the app.
enum TranslatorFixture {
    static func load() throws -> PluginPackage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loaded = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Plugins/Translator.spinnetplugin"))
        return PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
    }

    static func grantAll(_ package: PluginPackage, in grants: PluginCapabilityGrantStore) {
        for capability in package.manifest.capabilities {
            grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: capability, scope: package.manifest.scope(for: capability))
        }
    }
}

/// Translator speaks the DeepL API v2 shape through `https_request`. Every
/// run here goes through the real helper and the real broker, with a
/// deterministic transport in place of the network.
final class TranslatorTests: XCTestCase {
    private let copy = "translator.copy"
    private let replace = "translator.replace"
    private let clipboard = "translator.clipboard"

    private func input(endpoint: String = "https://api-free.deepl.com", target: String = "DE",
                       formality: String = "default") -> JSONValue {
        .object(["endpoint": .string(endpoint), "credential": .string("deepl"),
                 "target_language": .string(target), "formality": .string(formality)])
    }

    private func action(_ commandID: String, in package: PluginPackage, input: JSONValue? = nil) throws -> ActionConfiguration {
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
        return try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id, command: command,
                                       input: input ?? self.input())
    }

    // MARK: Package

    func testTranslatorAppearsOnceWithFlatSetupRequiredCommands() throws {
        let package = try TranslatorFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)
        let presets = registry.menuItemPresets().filter { $0.pluginID == package.manifest.id }
        XCTAssertEqual(presets.map(\.name), ["Translator"])
        XCTAssertEqual(package.manifest.preset.readiness, .setupRequired, "An API key has to be entered first")
        XCTAssertEqual(package.manifest.commands.map(\.id.rawValue), [copy, replace, clipboard])
        XCTAssertEqual(package.manifest.preset.defaultPrimaryCommandID?.rawValue, copy)
        XCTAssertEqual(package.manifest.preset.defaultAlternateCommandIDs.map(\.rawValue), [replace, clipboard])
        for command in package.manifest.commands {
            XCTAssertNotNil(command.explanation, command.id.rawValue)
            XCTAssertEqual(command.configurationFields.map(\.key), ["endpoint", "credential", "target_language", "formality"])
            XCTAssertEqual(command.configurationFields.map(\.kind), [.httpsEndpoint, .credential, .choice, .choice])
            // The defaults are usable once a key is stored.
            let defaultInput = try XCTUnwrap(package.manifest.preset.defaultInputs[command.id])
            XCTAssertTrue(command.acceptsConfigurationFieldsInput(defaultInput))
        }
    }

    func testReadingNetworkClipboardAndInsertionAreSeparateCapabilities() throws {
        let manifest = try TranslatorFixture.load().manifest
        func required(_ id: String) throws -> [PluginCapability] {
            try manifest.requiredCapabilities(for: XCTUnwrap(manifest.commands.first { $0.id.rawValue == id }))
        }
        XCTAssertEqual(Set(try required(copy)), [.readSelectedText, .contactHTTPS, .writeClipboard])
        XCTAssertEqual(Set(try required(replace)), [.readSelectedText, .contactHTTPS, .insertIntoFocusedApp])
        XCTAssertEqual(Set(try required(clipboard)), [.readCurrentClipboard, .contactHTTPS, .writeClipboard])
        XCTAssertEqual(manifest.scope(for: .contactHTTPS)?.httpsHosts, ["api-free.deepl.com", "api.deepl.com"])
        let clipboardCommand = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == clipboard })
        XCTAssertEqual(manifest.requiredSystemPermissions(for: clipboardCommand), [], "Clipboard translation needs no Accessibility")
        let disclosure = PluginPermissionDisclosure(manifest: manifest)
        XCTAssertTrue(disclosure.details(for: .contacts).contains("api-free.deepl.com"))
        XCTAssertTrue(disclosure.details(for: .changes).contains("Insert Text into the Focused App"))
    }

    func testDenyingOneCapabilityDisablesOnlyTheCommandsThatNeedIt() throws {
        let package = try TranslatorFixture.load()
        let grants = PluginCapabilityGrantStore()
        TranslatorFixture.grantAll(package, in: grants)
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in true })
        try registry.register(package)
        func availability() throws -> [String: ActionAvailability] {
            try Dictionary(uniqueKeysWithValues: [copy, replace, clipboard].map {
                ($0, registry.availability(for: try action($0, in: package)))
            })
        }
        func set(_ decision: PluginCapabilityGrantDecision, _ capability: PluginCapability) {
            grants.setDecision(decision, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: capability, scope: package.manifest.scope(for: capability))
        }
        XCTAssertEqual(try availability(), [copy: .available, replace: .available, clipboard: .available])

        set(.denied, .insertIntoFocusedApp)
        XCTAssertEqual(try availability(), [copy: .available, replace: .unavailable(.capabilityDenied), clipboard: .available])
        set(.granted, .insertIntoFocusedApp)

        set(.denied, .readSelectedText)
        XCTAssertEqual(try availability(), [copy: .unavailable(.capabilityDenied), replace: .unavailable(.capabilityDenied),
                                            clipboard: .available])
        set(.granted, .readSelectedText)

        set(.denied, .writeClipboard)
        XCTAssertEqual(try availability(), [copy: .unavailable(.capabilityDenied), replace: .available,
                                            clipboard: .unavailable(.capabilityDenied)])
        set(.granted, .writeClipboard)

        set(.denied, .contactHTTPS)
        XCTAssertEqual(Set(try availability().values), [.unavailable(.capabilityDenied)])
    }

    func testInsertionNeedsItsOwnGrantAndAccessibility() throws {
        let package = try TranslatorFixture.load()
        let grants = PluginCapabilityGrantStore()
        TranslatorFixture.grantAll(package, in: grants)
        var accessibility = true
        var inserted: [String] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in accessibility },
            selectedTextProvider: { "" }, clipboardWriter: { _ in }, focusedTextInserter: { inserted.append($0) }
        )
        func insert(from commandID: String) throws {
            let request = PluginRuntimeHostServiceRequest(invocationID: "i", actionID: ActionID(commandID),
                                                          service: .insertText, input: .string("Hallo"))
            _ = try broker.execute(request: request, for: package, action: action(commandID, in: package))
        }
        XCTAssertNoThrow(try insert(from: replace))
        XCTAssertThrowsError(try insert(from: copy), "Copy is outside the insertion scope") { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.insertIntoFocusedApp))
        }
        accessibility = false
        XCTAssertThrowsError(try insert(from: replace)) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .systemPermissionDenied(.accessibility))
        }
        XCTAssertEqual(inserted, ["Hallo"])
    }
}

/// Translator runs through the real helper and the real broker, with a
/// deterministic transport in place of the network.
extension PluginRuntimeTests {
    private func translatorInput(endpoint: String = "https://api-free.deepl.com", target: String = "DE",
                                 formality: String = "default") -> JSONValue {
        .object(["endpoint": .string(endpoint), "credential": .string("deepl"),
                 "target_language": .string(target), "formality": .string(formality)])
    }

    private func translatorAction(_ commandID: String, in package: PluginPackage, input: JSONValue) throws -> ActionConfiguration {
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
        return try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id, command: command, input: input)
    }

    // MARK: Runs through the helper

    private func runTranslator(_ commandID: String, input: JSONValue? = nil, selection: String = "Good morning",
                     clipboardText: String? = nil, responses: [HTTPSTransportResponse],
                     prepare: (PluginPackage, PluginCapabilityGrantStore) -> Void = { _, _ in })
        throws -> (outcome: ActionTerminalOutcome, transport: ScriptedHTTPSTransport, copied: [String], inserted: [String]) {
        let package = try TranslatorFixture.load()
        let grants = PluginCapabilityGrantStore()
        TranslatorFixture.grantAll(package, in: grants)
        prepare(package, grants)
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in true })
        try registry.register(package)
        let credentials = InMemoryPluginCredentialStore()
        try credentials.setSecret("deepl-secret:fx", for: package.manifest.id, reference: "deepl")
        let transport = ScriptedHTTPSTransport(responses)
        var copied: [String] = []
        var inserted: [String] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { selection }, clipboardWriter: { copied.append($0) },
            currentClipboardProvider: { clipboardText.map { ClipboardContent(text: $0, type: .text) } },
            httpsTransport: transport, credentialStore: credentials,
            focusedTextInserter: { inserted.append($0) }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }
        let outcome = HostActionRunner(executor: TranslatorNoopExecutor(), scriptedExecutor: supervisor,
                                       hostServiceBroker: broker)
            .invoke(try translatorAction(commandID, in: package, input: input ?? translatorInput()), using: registry).terminal
        return (outcome, transport, copied, inserted)
    }

    private func deepL(_ translation: String) -> HTTPSTransportResponse {
        ScriptedHTTPSTransport.json(#"{"translations":[{"detected_source_language":"EN","text":"\#(translation)"}]}"#)
    }

    func testTranslateSelectionAndCopySendsADeepLRequestAndCopiesTheResult() throws {
        let result = try runTranslator("translator.copy", input: translatorInput(target: "DE", formality: "prefer_more"), responses: [deepL("Guten Morgen")])
        guard case .succeeded = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(result.copied, ["Guten Morgen"])
        XCTAssertEqual(result.inserted, [])

        let request = try XCTUnwrap(result.transport.requests.first)
        XCTAssertEqual(result.transport.requests.count, 1)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(request.headers["Authorization"], "DeepL-Auth-Key deepl-secret:fx")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(request.body))
        XCTAssertEqual(body, .object(["text": .array([.string("Good morning")]), "target_lang": .string("DE"),
                                      "formality": .string("prefer_more")]))
    }

    func testTranslateInPlaceInsertsIntoTheFocusedAppWithoutTouchingTheClipboard() throws {
        let result = try runTranslator("translator.replace", responses: [deepL("Guten Morgen")])
        guard case .succeeded = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(result.inserted, ["Guten Morgen"])
        XCTAssertEqual(result.copied, [])
    }

    func testTranslateClipboardReadsTheClipboardInsteadOfTheSelection() throws {
        let result = try runTranslator("translator.clipboard", selection: "not this", clipboardText: "Thank you", responses: [deepL("Danke")])
        guard case .succeeded = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(result.copied, ["Danke"])
        let body = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(result.transport.requests.first?.body))
        if case .object(let fields) = body { XCTAssertEqual(fields["text"], .array([.string("Thank you")])) } else { XCTFail() }
    }

    func testTranslatorARejectedKeyFailsTheActionWithoutDeliveringAnything() throws {
        let result = try runTranslator("translator.copy", responses: [ScriptedHTTPSTransport.json(#"{"message":"Forbidden"}"#, status: 403)])
        guard case .failed(let failure) = result.outcome else { return XCTFail("A rejected key must fail the Action") }
        XCTAssertEqual(failure.category, .scriptedActionFailed)
        XCTAssertEqual(result.copied, [])
    }

    func testTranslatorAnUnconsentedSelfHostedEndpointIsRefusedAndAConsentedOneIsUsed() throws {
        let selfHosted = translatorInput(endpoint: "https://translate.example.org")
        let refused = try runTranslator("translator.copy", input: selfHosted, responses: [deepL("Guten Morgen")])
        guard case .failed(let failure) = refused.outcome else { return XCTFail("An unconsented host must be refused") }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertEqual(refused.transport.requests, [], "Nothing was sent to the undeclared host")
        XCTAssertEqual(refused.copied, [])

        let consented = try runTranslator("translator.copy", input: selfHosted, responses: [deepL("Guten Morgen")]) { package, grants in
            let declared = package.manifest.scope(for: .contactHTTPS)!
            grants.setConsentedHTTPSHosts(["translate.example.org"], for: package.manifest.id,
                                          pluginVersion: package.manifest.version, declaredScope: declared)
        }
        guard case .succeeded = consented.outcome else { return XCTFail("\(consented.outcome)") }
        XCTAssertEqual(consented.transport.requests.first?.url.absoluteString, "https://translate.example.org/v2/translate")
        XCTAssertEqual(consented.copied, ["Guten Morgen"])
    }

    func testTranslatorRevokedContactStopsTheRequestBeforeTheNetwork() throws {
        let result = try runTranslator("translator.copy", responses: [deepL("Guten Morgen")]) { package, grants in
            grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: .contactHTTPS, scope: package.manifest.scope(for: .contactHTTPS))
        }
        guard case .failed(let failure) = result.outcome else { return XCTFail("A revoked grant must fail") }
        // The runner's availability check stops it before the helper starts.
        XCTAssertEqual(failure.category, .commandUnavailable)
        XCTAssertEqual(result.transport.requests, [])
        XCTAssertEqual(result.copied, [])
    }

}

private struct TranslatorNoopExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}
