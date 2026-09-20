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

/// Translator describes one request per configured source and asks the Host
/// to present them together; its three Commands differ only in where the
/// text comes from.
final class TranslatorTests: XCTestCase {
    private let selection = "translator.selection"
    private let input = "translator.input"
    private let clipboard = "translator.clipboard"

    private func action(_ commandID: String, in package: PluginPackage, input: JSONValue = .object([:])) throws -> ActionConfiguration {
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
        return try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id, command: command, input: input)
    }

    // MARK: Package

    /// The sources, the two languages and each source's own settings are
    /// Plugin Settings shared by every Command. Out of the box only Google is
    /// on, which needs no key, so the Preset is ready to place as it is.
    func testTranslatorAppearsOnceWithItsSourcesInPluginSettings() throws {
        let package = try TranslatorFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)
        let presets = registry.menuItemPresets().filter { $0.pluginID == package.manifest.id }
        XCTAssertEqual(presets.map(\.name), ["Translator"])
        let manifest = package.manifest
        XCTAssertEqual(manifest.preset.readiness, .readyToUse)
        XCTAssertEqual(manifest.settingsFields.map(\.key), [
            "sources", "source_language", "target_language", "auto_detect",
            "deepl_endpoint", "deepl_credential", "formality",
            "openai_endpoint", "openai_model", "openai_credential"
        ])
        let sources = try XCTUnwrap(manifest.settingsFields.first)
        XCTAssertEqual(sources.kind, .orderedChoices)
        XCTAssertEqual(sources.choices, ["Google", "DeepL", "OpenAI"])
        XCTAssertEqual(manifest.overridableSettingsFields, [], "Every value is the Plugin's, not a Menu Item's")
        let languages = try XCTUnwrap(manifest.settingsFields.first { $0.key == "target_language" })
        XCTAssertEqual(languages.displayTitle(forChoice: "ZH-HANS"), "Simplified Chinese",
                       "A language shows its name, not its code")

        let defaults = manifest.resolvedSettings(stored: [:])
        XCTAssertEqual(defaults["sources"], .array([.string("Google")]))
        XCTAssertEqual(defaults["source_language"], .string("EN-US"))
        XCTAssertEqual(defaults["target_language"], .string("ZH-HANS"))
        XCTAssertEqual(defaults["auto_detect"], .bool(true))
        XCTAssertEqual(manifest.missingSettings(in: defaults, hasSecret: { _ in false }), [],
                       "Google needs no key, so nothing is missing out of the box")
        var everySource = defaults
        everySource["sources"] = .array([.string("OpenAI"), .string("Google"), .string("DeepL")])
        XCTAssertEqual(manifest.missingSettings(in: everySource, hasSecret: { _ in false }).map(\.key),
                       ["deepl_credential", "openai_credential"], "Only the sources that are on need their keys")

        XCTAssertEqual(manifest.commands.map(\.id.rawValue), [selection, input, clipboard])
        XCTAssertEqual(manifest.commands.map(\.title), ["Translate Selection", "Translate Input", "Translate Clipboard"])
        XCTAssertEqual(manifest.preset.defaultPrimaryCommandID?.rawValue, selection)
        XCTAssertEqual(manifest.preset.defaultAlternateCommandIDs.map(\.rawValue), [input, clipboard])
        for command in manifest.commands {
            XCTAssertNotNil(command.explanation, command.id.rawValue)
            XCTAssertFalse(command.isConfigurable, "A Menu Item has nothing of its own to configure")
            XCTAssertEqual(command.configurationFields, [])
        }
    }

    /// Reading the selection falls back to a copy, which the Host only does
    /// for a Command that may also read the clipboard, so the selection
    /// Command declares it too.
    func testTheSelectionCommandMayAlsoReadTheClipboardForTheCopyFallback() throws {
        let manifest = try TranslatorFixture.load().manifest
        func required(_ id: String) throws -> Set<PluginCapability> {
            Set(try manifest.requiredCapabilities(for: XCTUnwrap(manifest.commands.first { $0.id.rawValue == id })))
        }
        XCTAssertEqual(try required(selection), [.readSelectedText, .contactHTTPS])
        XCTAssertEqual(try required(input), [.contactHTTPS], "Typed text needs no read Capability")
        XCTAssertEqual(try required(clipboard), [.contactHTTPS])
        XCTAssertEqual(manifest.optionalCapabilities, [.readCurrentClipboard],
                       "Refusing the clipboard leaves the selection working without the fallback")
        // The Host only falls back to a copy for a Command that may read the
        // clipboard, so the selection Command declares it as well.
        XCTAssertTrue(manifest.declares(.readCurrentClipboard, for: CommandID(selection)))
        XCTAssertFalse(manifest.declares(.readCurrentClipboard, for: CommandID(input)))
        XCTAssertEqual(manifest.scope(for: .readCurrentClipboard)?.commandIDs.map(\.rawValue), [selection, clipboard])
        XCTAssertEqual(manifest.scope(for: .contactHTTPS)?.httpsHosts,
                       ["api-free.deepl.com", "api.deepl.com", "clients5.google.com", "api.openai.com"])
        for id in [input, clipboard] {
            let command = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == id })
            XCTAssertEqual(manifest.requiredSystemPermissions(for: command), [], "\(id) needs no Accessibility")
        }
        let disclosure = PluginPermissionDisclosure(manifest: manifest)
        XCTAssertTrue(disclosure.details(for: .contacts).contains("clients5.google.com"))
    }

    func testDenyingOneCapabilityDisablesOnlyTheCommandsThatNeedIt() throws {
        let package = try TranslatorFixture.load()
        let grants = PluginCapabilityGrantStore()
        TranslatorFixture.grantAll(package, in: grants)
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in true })
        try registry.register(package)
        func availability() throws -> [String: ActionAvailability] {
            try Dictionary(uniqueKeysWithValues: [selection, input, clipboard].map {
                ($0, registry.availability(for: try action($0, in: package)))
            })
        }
        func set(_ decision: PluginCapabilityGrantDecision, _ capability: PluginCapability) {
            grants.setDecision(decision, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: capability, scope: package.manifest.scope(for: capability))
        }
        XCTAssertEqual(try availability(), [selection: .available, input: .available, clipboard: .available])

        set(.denied, .readSelectedText)
        XCTAssertEqual(try availability(), [selection: .unavailable(.capabilityDenied), input: .available, clipboard: .available])
        set(.granted, .readSelectedText)

        set(.denied, .readCurrentClipboard)
        XCTAssertEqual(try availability(), [selection: .available, input: .available, clipboard: .available],
                       "The clipboard is optional, so refusing it disables no Command")
        set(.granted, .readCurrentClipboard)

        set(.denied, .contactHTTPS)
        XCTAssertEqual(Set(try availability().values), [.unavailable(.capabilityDenied)])
    }
}

/// Translator runs through the real helper and the real broker; the popup
/// the Host would show is captured and filled in with a deterministic
/// transport in place of the network.
extension PluginRuntimeTests {
    private struct TranslatorRun {
        let outcome: ActionTerminalOutcome
        let session: ResultsPresentationSession?
        let transport: RoutedHTTPSTransport
        let selectionReads: Int

        /// Every section's state once all have answered, in section order,
        /// for the direction the Host chose for this text.
        func resolve(_ text: String) throws -> [ResultsSectionState] {
            try resolveDirection(text).states
        }

        /// The same, with the direction that answered.
        func resolveDirection(_ text: String) throws -> (variant: ResultsPresentation.Variant,
                                                         states: [ResultsSectionState]) {
            let session = try XCTUnwrap(self.session, "Nothing was presented")
            let lock = NSLock()
            var states: [Int: ResultsSectionState] = [:]
            var chosen: ResultsPresentation.Variant?
            session.resolve(text: text, started: { variant in lock.withLock { chosen = variant } }) { index, state in
                lock.withLock { states[index] = state }
            }
            let variant = try XCTUnwrap(chosen)
            return (variant, (0..<variant.sections.count).compactMap { states[$0] })
        }

        /// The JSON body sent to `host`.
        func body(to host: String) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(request(to: host).body))
        }

        func request(to host: String) throws -> HTTPSTransportRequest {
            try XCTUnwrap(transport.requests.first { $0.url.host == host }, "Nothing was sent to \(host)")
        }
    }

    private func translatorSettings(sources: [String] = ["DeepL"], source: String = "EN-US", target: String = "DE",
                                    autoDetect: Bool = false, formality: String = "default",
                                    deepLEndpoint: String = "https://api-free.deepl.com",
                                    openAIEndpoint: String = "https://api.openai.com/v1") -> [String: JSONValue] {
        ["sources": .array(sources.map(JSONValue.string)), "source_language": .string(source),
         "target_language": .string(target), "auto_detect": .bool(autoDetect),
         "deepl_endpoint": .string(deepLEndpoint), "deepl_credential": .string("deepl"), "formality": .string(formality),
         "openai_endpoint": .string(openAIEndpoint), "openai_model": .string("gpt-test"), "openai_credential": .string("openai")]
    }

    private static let answers: [String: RoutedHTTPSTransport.Route] = [
        "api-free.deepl.com": RoutedHTTPSTransport.json(#"{"translations":[{"detected_source_language":"EN","text":"Guten Morgen"}]}"#),
        "clients5.google.com": RoutedHTTPSTransport.json(#"[["Guten Morgen","en"]]"#),
        "api.openai.com": RoutedHTTPSTransport.json(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"Guten Morgen."}}]}"#)
    ]

    /// `settings` are the stored Plugin Settings; `input` is the Menu Item's
    /// own overrides.
    private func runTranslator(_ commandID: String, settings: [String: JSONValue]? = nil, input: JSONValue = .object([:]),
                               selection: String = "Good morning", clipboardText: String? = nil,
                               answers: [String: RoutedHTTPSTransport.Route] = PluginRuntimeTests.answers,
                               detected: String? = nil,
                               prepare: (PluginPackage, PluginCapabilityGrantStore) -> Void = { _, _ in }) throws -> TranslatorRun {
        let package = try TranslatorFixture.load()
        let grants = PluginCapabilityGrantStore()
        TranslatorFixture.grantAll(package, in: grants)
        prepare(package, grants)
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in true })
        try registry.register(package)
        let credentials = InMemoryPluginCredentialStore()
        for reference in ["deepl", "openai"] {
            try credentials.setSecret("\(reference)-secret", for: package.manifest.id, reference: reference)
        }
        let transport = RoutedHTTPSTransport(answers)
        let stored = settings ?? translatorSettings()
        var session: ResultsPresentationSession?
        var selectionReads = 0
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { selectionReads += 1; return selection }, clipboardWriter: { _ in },
            currentClipboardProvider: { clipboardText.map { ClipboardContent(text: $0, type: .text) } },
            httpsTransport: transport, credentialStore: credentials,
            resultsPresenter: { session = $0 },
            languageDetector: { _ in detected },
            pluginSettingsReader: { $0.resolvedSettings(stored: stored) }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }
        let outcome = HostActionRunner(executor: TranslatorNoopExecutor(), scriptedExecutor: supervisor,
                                       hostServiceBroker: broker,
                                       pluginSettings: { $0.resolvedSettings(stored: stored) })
            .invoke(try translatorAction(commandID, in: package, input: input), using: registry).terminal
        return TranslatorRun(outcome: outcome, session: session, transport: transport, selectionReads: selectionReads)
    }

    private func translatorAction(_ commandID: String, in package: PluginPackage, input: JSONValue) throws -> ActionConfiguration {
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
        return try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id, command: command, input: input)
    }

    // MARK: The popup

    /// The popup shows the selection, then one section per source in the
    /// order Plugin Settings put them, and the Action is done before any
    /// source answers.
    func testTranslateSelectionPresentsTheSelectionWithOneSectionPerSourceInOrder() throws {
        let run = try runTranslator("translator.selection",
                                    settings: translatorSettings(sources: ["OpenAI", "DeepL", "Google"]))
        guard case .succeeded = run.outcome else { return XCTFail("\(run.outcome)") }
        XCTAssertEqual(run.transport.requests, [], "The Action returns before any source is asked")
        let presentation = try XCTUnwrap(run.session?.presentation)
        XCTAssertEqual(presentation.title, "Translate")
        XCTAssertEqual(presentation.main.subtitle, "Any language → German · Input English (American) · Detect Direction off")
        XCTAssertEqual(presentation.original, "Good morning")
        XCTAssertEqual(presentation.main.sections.map(\.title), ["OpenAI · gpt-test", "DeepL", "Google"])

        XCTAssertEqual(try run.resolve("Good morning"),
                       [.succeeded("Guten Morgen."), .succeeded("Guten Morgen"), .succeeded("Guten Morgen")],
                       "OpenAI, DeepL and Google, in the order Plugin Settings put them")
    }

    func testEachSourceSpeaksItsOwnAPIWithTheHostHeldKey() throws {
        let run = try runTranslator("translator.selection",
                                    settings: translatorSettings(sources: ["DeepL", "Google", "OpenAI"], target: "ZH-HANS",
                                                                 formality: "prefer_more"))
        _ = try run.resolve("Good morning")

        let deepL = try run.request(to: "api-free.deepl.com")
        XCTAssertEqual(deepL.method, "POST")
        XCTAssertEqual(deepL.url.absoluteString, "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(deepL.headers["Authorization"], "DeepL-Auth-Key deepl-secret")
        XCTAssertEqual(deepL.headers["Content-Type"], "application/json")
        XCTAssertEqual(try run.body(to: "api-free.deepl.com"),
                       .object(["text": .array([.string("Good morning")]), "target_lang": .string("ZH-HANS"),
                                "formality": .string("prefer_more")]))

        // Google Translate's own endpoint: no key, and the text rides in the query.
        let google = try run.request(to: "clients5.google.com")
        XCTAssertEqual(google.method, "GET")
        XCTAssertEqual(google.url.absoluteString,
                       "https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=zh-CN&q=Good%20morning")
        XCTAssertNil(google.body)
        XCTAssertEqual(google.headers, [:], "Nothing identifies the user to Google")

        let openAI = try run.request(to: "api.openai.com")
        XCTAssertEqual(openAI.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(openAI.headers["Authorization"], "Bearer openai-secret")
        guard case .object(let body) = try run.body(to: "api.openai.com"),
              case .array(let messages)? = body["messages"], messages.count == 2,
              case .object(let system) = messages[0], case .string(let prompt)? = system["content"] else {
            return XCTFail("OpenAI expects a model and a system and a user message")
        }
        XCTAssertEqual(body["model"], .string("gpt-test"))
        XCTAssertTrue(prompt.contains("Simplified Chinese"), prompt)
        XCTAssertEqual(messages[1], .object(["role": .string("user"), "content": .string("Good morning")]))
    }

    /// Google needs no key of any kind.
    func testGoogleTranslatesWithoutAKey() throws {
        let run = try runTranslator("translator.selection", settings: translatorSettings(sources: ["Google"]))
        XCTAssertEqual(try run.resolve("Good morning"), [.succeeded("Guten Morgen")])
        XCTAssertEqual(try run.request(to: "clients5.google.com").headers, [:])
    }

    /// The three language settings are controls in the popup, not just a
    /// line of text, so they can be changed where the translation is read.
    func testThePopupOffersTheThreeLanguageSettings() throws {
        let run = try runTranslator("translator.selection",
                                    settings: translatorSettings(sources: ["Google"], source: "EN-US", target: "ZH-HANS"))
        let session = try XCTUnwrap(run.session)
        XCTAssertEqual(session.settings.map(\.key), ["source_language", "target_language", "auto_detect"])
        XCTAssertEqual(session.settings.map(\.title), ["Input Language", "Target Language", "Detect Direction"])
        XCTAssertEqual(session.settings.map(\.value),
                       [.string("EN-US"), .string("ZH-HANS"), .bool(false)])
        XCTAssertEqual(session.settings.first?.choices.first?.title, "English (American)")
        guard let swap = session.swappableSettings else { return XCTFail("The two languages swap") }
        XCTAssertEqual([swap.0, swap.1], ["source_language", "target_language"])
    }

    // MARK: Direction

    /// With Detect Direction on, text already in the target language is
    /// translated back into the input language instead, so the two languages
    /// never have to be swapped by hand.
    func testDetectedTargetLanguageTurnsTheDirectionAround() throws {
        var answers = Self.answers
        answers["clients5.google.com"] = RoutedHTTPSTransport.json(#"[["Good morning","zh-CN"]]"#)
        let settings = translatorSettings(sources: ["Google"], source: "EN-US", target: "ZH-HANS", autoDetect: true)

        let chinese = try runTranslator("translator.selection", settings: settings, selection: "早上好",
                                        answers: answers, detected: "zh-Hans")
        let presentation = try XCTUnwrap(chinese.session?.presentation)
        XCTAssertEqual(presentation.main.subtitle, "English (American) → Simplified Chinese · Detect Direction on")
        XCTAssertEqual(presentation.alternate?.variant.subtitle,
                       "Simplified Chinese → English (American) · Detect Direction on")
        let turned = try chinese.resolveDirection("早上好")
        XCTAssertEqual(turned.variant.subtitle, "Simplified Chinese → English (American) · Detect Direction on")
        XCTAssertEqual(turned.states, [.succeeded("Good morning")])
        XCTAssertEqual(try chinese.request(to: "clients5.google.com").url.query?.contains("tl=en"), true)

        let english = try runTranslator("translator.selection", settings: settings, detected: "en")
        XCTAssertEqual(try english.resolveDirection("Good morning").variant.subtitle,
                       "English (American) → Simplified Chinese · Detect Direction on")
        XCTAssertEqual(try english.request(to: "clients5.google.com").url.query?.contains("tl=zh-CN"), true)
    }

    /// With it off there is one direction, and the popup says so.
    func testWithoutDetectionEverythingGoesIntoTheTargetLanguage() throws {
        let run = try runTranslator("translator.selection",
                                    settings: translatorSettings(sources: ["Google"], target: "ZH-HANS", autoDetect: false),
                                    selection: "早上好", detected: "zh-Hans")
        let presentation = try XCTUnwrap(run.session?.presentation)
        XCTAssertNil(presentation.alternate)
        let subtitle = "Any language → Simplified Chinese · Input English (American) · Detect Direction off"
        XCTAssertEqual(presentation.main.subtitle, subtitle, "All three language settings are shown")
        XCTAssertEqual(try run.resolveDirection("早上好").variant.subtitle, subtitle)
    }

    /// A source that fails shows its own error; the others still answer.
    func testOneSourceFailingLeavesTheOthersResults() throws {
        var answers = Self.answers
        // Google refuses with a status and no JSON of its own.
        answers["clients5.google.com"] = RoutedHTTPSTransport.json("Too Many Requests", status: 429)
        answers["api.openai.com"] = nil
        let run = try runTranslator("translator.selection", settings: translatorSettings(sources: ["DeepL", "Google", "OpenAI"]),
                                    answers: answers)
        let states = try run.resolve("Good morning")
        XCTAssertEqual(states[0], .succeeded("Guten Morgen"))
        XCTAssertEqual(states[1], .failed("Google is refusing requests from this network for now; try again later"))
        guard case .failed(let message) = states[2] else { return XCTFail("\(states[2])") }
        XCTAssertTrue(message.contains("api.openai.com"), message)
    }

    func testDeepLStatusesHaveTheirOwnMessages() throws {
        var answers = Self.answers
        answers["api-free.deepl.com"] = RoutedHTTPSTransport.json(#"{"message":"Quota Exceeded"}"#, status: 456)
        let run = try runTranslator("translator.selection", answers: answers)
        XCTAssertEqual(try run.resolve("Good morning"), [.failed("The DeepL quota is used up")])
    }

    func testTranslateInputAsksForTheTextWithoutReadingTheSelection() throws {
        let run = try runTranslator("translator.input", settings: translatorSettings(sources: ["DeepL", "Google"]))
        guard case .succeeded = run.outcome else { return XCTFail("\(run.outcome)") }
        XCTAssertEqual(run.selectionReads, 0)
        let presentation = try XCTUnwrap(run.session?.presentation)
        XCTAssertNil(presentation.original)
        XCTAssertEqual(presentation.inputPlaceholder, "Text to translate")
        XCTAssertEqual(try run.resolve("Thank you"), [.succeeded("Guten Morgen"), .succeeded("Guten Morgen")])
        guard case .object(let body) = try run.body(to: "api-free.deepl.com") else { return XCTFail() }
        XCTAssertEqual(body["text"], .array([.string("Thank you")]), "What the user typed is what is sent")
    }

    func testTranslateClipboardReadsTheClipboardInsteadOfTheSelection() throws {
        let run = try runTranslator("translator.clipboard", selection: "not this", clipboardText: "Thank you")
        guard case .succeeded = run.outcome else { return XCTFail("\(run.outcome)") }
        XCTAssertEqual(run.selectionReads, 0)
        XCTAssertEqual(run.session?.presentation.original, "Thank you")
    }

    /// An App that keeps its selection to itself leaves nothing to translate,
    /// so the popup asks for the text instead of failing, as Smart Jump does.
    func testNothingToTranslateOpensThePopupForTyping() throws {
        let run = try runTranslator("translator.selection", selection: "  ")
        guard case .succeeded = run.outcome else { return XCTFail("\(run.outcome)") }
        let presentation = try XCTUnwrap(run.session?.presentation)
        XCTAssertNil(presentation.original)
        XCTAssertEqual(presentation.inputPlaceholder, "Text to translate")
        XCTAssertEqual(presentation.submitTitle, "Translate")
        XCTAssertEqual(try run.resolve("Good morning"), [.succeeded("Guten Morgen")])
    }

    // MARK: Consent

    func testAnUnconsentedSelfHostedEndpointIsRefusedAndAConsentedOneIsUsed() throws {
        let selfHosted = translatorSettings(sources: ["OpenAI"], openAIEndpoint: "https://llm.example.org/v1")
        let refused = try runTranslator("translator.selection", settings: selfHosted)
        guard case .failed(let failure) = refused.outcome else { return XCTFail("An unconsented host must be refused") }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertNil(refused.session, "No popup opens for a request that could not be sent")

        var answers = Self.answers
        answers["llm.example.org"] = answers["api.openai.com"]
        let consented = try runTranslator("translator.selection", settings: selfHosted, answers: answers) { package, grants in
            let declared = package.manifest.scope(for: .contactHTTPS)!
            grants.setConsentedHTTPSHosts(["llm.example.org"], for: package.manifest.id,
                                          pluginVersion: package.manifest.version, declaredScope: declared)
        }
        guard case .succeeded = consented.outcome else { return XCTFail("\(consented.outcome)") }
        XCTAssertEqual(try consented.resolve("Good morning"), [.succeeded("Guten Morgen.")])
        XCTAssertEqual(try consented.request(to: "llm.example.org").url.absoluteString, "https://llm.example.org/v1/chat/completions")
    }

    func testTranslatorRevokedContactStopsTheActionBeforeTheNetwork() throws {
        let run = try runTranslator("translator.selection") { package, grants in
            grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: .contactHTTPS, scope: package.manifest.scope(for: .contactHTTPS))
        }
        guard case .failed(let failure) = run.outcome else { return XCTFail("A revoked grant must fail") }
        // The runner's availability check stops it before the helper starts.
        XCTAssertEqual(failure.category, .commandUnavailable)
        XCTAssertNil(run.session)
        XCTAssertEqual(run.transport.requests, [])
    }
}

private struct TranslatorNoopExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}
