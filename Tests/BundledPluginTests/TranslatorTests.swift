import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The repository's Translator package, registered the way the Host
/// registers a Plugin that ships with the app.
enum TranslatorFixture {
    static func load() throws -> PluginPackage {
        try PluginUnderTest(named: "Translator.spinnetplugin", origin: .bundled).package
    }

    static func grantAll(_ package: PluginPackage, in grants: PluginCapabilityGrantStore) {
        for capability in package.manifest.capabilities {
            grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: capability, scope: package.manifest.scope(for: capability))
        }
    }
}

/// Translator shows one Host-Fetched Section per configured source in a
/// Plugin View; its three Commands differ only in where the text comes from.
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
            "sources", "source_language", "target_language", "auto_detect", "google_endpoint",
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

/// Translator's script runs in the real helper through the Plugin test kit,
/// with recorded answers for the text it reads. The view it answers with is
/// read as the Host reads it, and its Host-Fetched Sections are sent as the
/// Host sends them, to recorded responses in place of the network.
final class TranslatorScriptTests: XCTestCase {
    private var helper: PluginTestHelper!
    private var plugin: PluginUnderTest!

    override func setUpWithError() throws {
        helper = try PluginTestHelper()
        plugin = try PluginUnderTest(named: "Translator.spinnetplugin", origin: .bundled)
    }

    override func tearDown() {
        helper?.shutdown()
        helper = nil
    }

    /// The Action's input: the Plugin Settings, as the Host resolves them.
    private func translatorSettings(sources: [String] = ["DeepL"], source: String = "EN-US", target: String = "DE",
                                    autoDetect: Bool = false, formality: String = "default",
                                    deepLEndpoint: String = "https://api-free.deepl.com",
                                    googleEndpoint: String = "https://clients5.google.com",
                                    openAIEndpoint: String = "https://api.openai.com/v1") -> JSONValue {
        .object(["sources": .array(sources.map(JSONValue.string)), "source_language": .string(source),
                 "google_endpoint": .string(googleEndpoint),
                 "target_language": .string(target), "auto_detect": .bool(autoDetect),
                 "deepl_endpoint": .string(deepLEndpoint), "deepl_credential": .string("deepl"),
                 "formality": .string(formality),
                 "openai_endpoint": .string(openAIEndpoint), "openai_model": .string("gpt-test"),
                 "openai_credential": .string("openai")])
    }

    private static let answers: [String: HTTPSTransportResponse] = [
        "api-free.deepl.com": RecordedHostFetchedSections.json(#"{"translations":[{"detected_source_language":"EN","text":"Guten Morgen"}]}"#),
        "clients5.google.com": RecordedHostFetchedSections.json(#"[["Guten Morgen","en"]]"#),
        "api.openai.com": RecordedHostFetchedSections.json(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"Guten Morgen."}}]}"#)
    ]

    /// The Host's side of the network, with both keys stored.
    private func fetches(_ answers: [String: HTTPSTransportResponse] = TranslatorScriptTests.answers,
                         consentedHosts: [String] = []) -> RecordedHostFetchedSections {
        RecordedHostFetchedSections(answers, credentials: ["deepl": "deepl-secret", "openai": "openai-secret"],
                                    consentedHosts: consentedHosts)
    }

    /// One run of the script: what it asked the Host for, its answer, and
    /// the view as the Host reads it before drawing it.
    private struct Shown {
        let invocation: PluginTestInvocation
        let run: PluginTestRun
        let answer: PluginScriptAnswer
        let view: PluginViewDescription

        var sections: [PluginViewSection] { view.detail?.sections ?? [] }

        func section(_ id: String) -> PluginViewSection? { sections.first { $0.id == id } }

        /// What the text field holds.
        var text: JSONValue? { view.form?.fields.first { $0.key == "text" }?.value }
    }

    private func run(_ commandID: String, settings: JSONValue? = nil, event: PluginViewEvent? = nil,
                     state: JSONValue = .null, selection: String = "Good morning", clipboardText: String? = nil,
                     detected: String? = nil) throws -> Shown {
        let invocation = PluginTestInvocation(commandID, input: settings ?? translatorSettings(), event: event, state: state)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices([
            .readSelectedText: .value(.string(selection)),
            .readCurrentClipboard: .value(clipboardText.map {
                .object(["text": .string($0), "type": .string("text")])
            } ?? .null),
            .detectLanguage: .value(detected.map(JSONValue.string) ?? .null)
        ]))
        let answer = try run.answer()
        let view = try XCTUnwrap(answer.view, "The script showed no view")
        return Shown(invocation: invocation, run: run, answer: answer,
                     view: try PluginViewDescription(parsing: view, settingsFields: plugin.manifest.settingsFields))
    }

    /// Sends the view's sections and returns what each source section shows.
    private func translations(_ shown: Shown, _ fetches: RecordedHostFetchedSections) throws -> [HostFetchedSectionState] {
        try fetches.fetch(XCTUnwrap(shown.answer.view), of: plugin, for: shown.invocation).map(\.state)
    }

    private func request(to host: String, in fetches: RecordedHostFetchedSections) throws -> HTTPSTransportRequest {
        try XCTUnwrap(fetches.requests.first { $0.url.host == host }, "Nothing was sent to \(host)")
    }

    private func body(to host: String, in fetches: RecordedHostFetchedSections) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request(to: host, in: fetches).body))
    }

    // MARK: The view

    /// The view shows the selection in a field that can be changed, then
    /// one section per source in the order Plugin Settings put them, and the
    /// script answers before any source is asked.
    func testTranslateSelectionPresentsTheSelectionWithOneSectionPerSourceInOrder() throws {
        let shown = try run("translator.selection", settings: translatorSettings(sources: ["OpenAI", "DeepL", "Google"]))
        XCTAssertEqual(shown.run.requests.map(\.service), [.readSelectedText], "The script asks no source itself")
        XCTAssertEqual(shown.view.title, "Translate")
        XCTAssertNil(shown.view.subtitle, "The controls say what the languages are")
        let form = try XCTUnwrap(shown.view.form)
        XCTAssertEqual(form.fields.map(\.kind), [.multilineText])
        XCTAssertTrue(form.submitsOnReturn, "Return translates the text again; Shift-Return starts a line")
        XCTAssertEqual(shown.text, .string("Good morning"))
        XCTAssertEqual(shown.sections.map(\.id), ["openai", "deepl", "google"])
        XCTAssertEqual(shown.sections.map(\.title), ["OpenAI · gpt-test", "DeepL", "Google"])
        XCTAssertEqual(shown.answer.state, .object(["text": .string("Good morning")]))

        XCTAssertEqual(try translations(shown, fetches()),
                       [.text("Guten Morgen."), .text("Guten Morgen"), .text("Guten Morgen")],
                       "OpenAI, DeepL and Google, in the order Plugin Settings put them")
    }

    func testEachSourceSpeaksItsOwnAPIWithTheHostHeldKey() throws {
        let shown = try run("translator.selection",
                            settings: translatorSettings(sources: ["DeepL", "Google", "OpenAI"], target: "ZH-HANS",
                                                         formality: "prefer_more"))
        let fetches = fetches()
        _ = try translations(shown, fetches)

        let deepL = try request(to: "api-free.deepl.com", in: fetches)
        XCTAssertEqual(deepL.method, "POST")
        XCTAssertEqual(deepL.url.absoluteString, "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(deepL.headers["Authorization"], "DeepL-Auth-Key deepl-secret")
        XCTAssertEqual(deepL.headers["Content-Type"], "application/json")
        XCTAssertEqual(try body(to: "api-free.deepl.com", in: fetches),
                       .object(["text": .array([.string("Good morning")]), "target_lang": .string("ZH-HANS"),
                                "source_lang": .string("EN"), "formality": .string("prefer_more")]))

        // Google Translate's own endpoint: no key, and the text rides in the query.
        let google = try request(to: "clients5.google.com", in: fetches)
        XCTAssertEqual(google.method, "GET")
        XCTAssertEqual(google.url.absoluteString,
                       "https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=zh-CN&q=Good%20morning")
        XCTAssertNil(google.body)
        // Google turns away requests that look automated, so its web client's
        // User-Agent is sent; nothing else identifies the user.
        XCTAssertEqual(google.headers.keys.sorted(), ["User-Agent"])
        XCTAssertTrue(try XCTUnwrap(google.headers["User-Agent"]).hasPrefix("Mozilla/5.0"))

        let openAI = try request(to: "api.openai.com", in: fetches)
        XCTAssertEqual(openAI.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(openAI.headers["Authorization"], "Bearer openai-secret")
        guard case .object(let body) = try self.body(to: "api.openai.com", in: fetches),
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
        let shown = try run("translator.selection", settings: translatorSettings(sources: ["Google"]))
        let fetches = fetches()
        XCTAssertEqual(try translations(shown, fetches), [.text("Guten Morgen")])
        XCTAssertNil(try request(to: "clients5.google.com", in: fetches).headers["Authorization"])
    }

    /// Google refuses some networks outright, so its address is a setting and
    /// an address of one's own is contacted once consented to.
    func testGoogleSpeaksToTheAddressInItsSetting() throws {
        var answers = Self.answers
        answers["translate.example.org"] = answers["clients5.google.com"]
        let shown = try run("translator.selection",
                            settings: translatorSettings(sources: ["Google"], googleEndpoint: "https://translate.example.org"))
        let fetches = fetches(answers, consentedHosts: ["translate.example.org"])
        XCTAssertEqual(try translations(shown, fetches), [.text("Guten Morgen")])
        XCTAssertTrue(try request(to: "translate.example.org", in: fetches).url.path.hasSuffix("/translate_a/t"))
    }

    /// Translating the same text again asks no source a second time: every
    /// section is cacheable, and the same text makes the same request.
    func testTranslatingTheSameTextAgainAsksNoSourceAgain() throws {
        let settings = translatorSettings(sources: ["Google", "DeepL"])
        let fetches = fetches()
        XCTAssertEqual(try translations(run("translator.selection", settings: settings), fetches).count, 2)
        XCTAssertEqual(fetches.requests.count, 2)
        XCTAssertEqual(try translations(run("translator.selection", settings: settings), fetches),
                       [.text("Guten Morgen"), .text("Guten Morgen")])
        XCTAssertEqual(fetches.requests.count, 2, "Both answers came from the last ones")
        _ = try translations(run("translator.selection", settings: settings, selection: "Good evening"), fetches)
        XCTAssertEqual(fetches.requests.count, 4, "Different text is asked afresh")
    }

    /// The three language settings are controls in the view, with a swap
    /// between the two languages, so they can be changed where the
    /// translation is read. A change comes back as an event, and the same
    /// text is translated again with the new setting; the Action does not
    /// run again.
    func testTheViewOffersTheThreeLanguageSettingsAndTranslatesAgainWhenOneChanges() throws {
        let opened = try run("translator.selection",
                             settings: translatorSettings(sources: ["Google"], source: "EN-US", target: "ZH-HANS"))
        let controls = opened.view.settings
        XCTAssertEqual(controls.map(\.key), ["source_language", "target_language", "auto_detect"])
        XCTAssertEqual(controls.map(\.title), ["Input", "Target", "Auto Detect Language"])
        XCTAssertEqual(controls.map(\.swapWith), ["target_language", nil, nil], "The two languages swap")
        XCTAssertEqual(controls.first?.choices.first?.title, "English (American)")

        let changed = try run("translator.selection",
                              settings: translatorSettings(sources: ["Google"], source: "EN-US", target: "FR"),
                              event: .settingChanged(key: "target_language", value: .string("FR")),
                              state: opened.answer.state, selection: "not read again")
        XCTAssertEqual(changed.run.requests, [], "The text comes from the view's state")
        XCTAssertEqual(changed.text, .string("Good morning"))
        let fetches = fetches()
        _ = try translations(changed, fetches)
        XCTAssertEqual(try request(to: "clients5.google.com", in: fetches).url.query?.contains("tl=fr"), true)
    }

    // MARK: Direction

    /// The translation always goes into Target, as the controls show; Auto
    /// Detect Language only decides what language the text is in, and the
    /// view says what it found.
    func testTheTranslationAlwaysGoesIntoTheTarget() throws {
        let settings = translatorSettings(sources: ["DeepL", "Google"], source: "EN-GB", target: "ZH-HANS", autoDetect: true)
        let chinese = try run("translator.selection", settings: settings, selection: "早上好 pacing", detected: "zh-Hans")
        XCTAssertEqual(chinese.run.inputs(to: .detectLanguage), [.string("早上好 pacing")])
        XCTAssertEqual(chinese.view.subtitle, "Detected Simplified Chinese")
        let fetches = fetches()
        _ = try translations(chinese, fetches)
        guard case .object(let deepL) = try body(to: "api-free.deepl.com", in: fetches) else { return XCTFail() }
        XCTAssertEqual(deepL["target_lang"], .string("ZH-HANS"), "Text already in Target still goes into Target")
        XCTAssertNil(deepL["source_lang"], "DeepL is not told the language it is asked to translate into")
        XCTAssertEqual(try request(to: "clients5.google.com", in: fetches).url.query?.contains("tl=zh-CN"), true)

        let english = try run("translator.selection", settings: settings, detected: "en")
        XCTAssertEqual(english.view.subtitle, "Detected English (British)", "Named as Input names it")
    }

    /// Swapping the languages sends the same text into the new Target.
    func testTheSwapButtonTranslatesIntoTheNewTarget() throws {
        let opened = try run("translator.selection",
                             settings: translatorSettings(sources: ["DeepL"], source: "EN-US", target: "ZH-HANS"))
        let swapped = try run("translator.selection",
                              settings: translatorSettings(sources: ["DeepL"], source: "ZH-HANS", target: "EN-US"),
                              event: .settingsSwapped(first: "source_language", second: "target_language"),
                              state: opened.answer.state, selection: "not read again")
        XCTAssertEqual(swapped.text, .string("Good morning"))
        let fetches = fetches()
        _ = try translations(swapped, fetches)
        guard case .object(let deepL) = try body(to: "api-free.deepl.com", in: fetches) else { return XCTFail() }
        XCTAssertEqual(deepL["target_lang"], .string("EN-US"))
    }

    /// DeepL judges mixed text by itself, so it is told the text's language:
    /// the detected one, or Input with detection off. An unknown language
    /// is left to it.
    func testDeepLIsToldTheLanguageOfTheText() throws {
        for (autoDetect, detected, sent) in [(true, "zh-Hans", JSONValue.string("ZH")), (true, "fr", .string("FR")),
                                             (true, "xx", nil), (false, "fr", .string("ZH"))] {
            let settings = translatorSettings(sources: ["DeepL"], source: "ZH-HANS", target: "EN-GB", autoDetect: autoDetect)
            let shown = try run("translator.selection", settings: settings, selection: "早上好", detected: detected)
            let recorded = fetches()
            _ = try translations(shown, recorded)
            guard case .object(let deepL) = try body(to: "api-free.deepl.com", in: recorded) else { return XCTFail() }
            XCTAssertEqual(deepL["source_lang"], sent, "\(autoDetect) \(detected)")
        }
    }

    /// With it off the text is taken to be in Input, and nothing is detected.
    func testWithoutDetectionTheTextIsTakenToBeInInput() throws {
        let shown = try run("translator.selection",
                            settings: translatorSettings(sources: ["Google"], target: "ZH-HANS", autoDetect: false),
                            selection: "早上好", detected: "zh-Hans")
        XCTAssertEqual(shown.run.inputs(to: .detectLanguage), [], "Nothing needs detecting")
        XCTAssertNil(shown.view.subtitle)
        let fetches = fetches()
        _ = try translations(shown, fetches)
        XCTAssertEqual(try request(to: "clients5.google.com", in: fetches).url.query?.contains("tl=zh-CN"), true)
    }

    // MARK: Errors

    /// A source that fails shows its own error; the others still answer.
    func testOneSourceFailingLeavesTheOthersResults() throws {
        var answers = Self.answers
        // Google refuses with a status and no JSON of its own.
        answers["clients5.google.com"] = RecordedHostFetchedSections.json("Too Many Requests", status: 429)
        answers["api.openai.com"] = nil
        let shown = try run("translator.selection", settings: translatorSettings(sources: ["DeepL", "Google", "OpenAI"]))
        let states = try translations(shown, fetches(answers))
        XCTAssertEqual(states[0], .text("Guten Morgen"))
        XCTAssertEqual(states[1], .failed("Google is refusing requests from this network for now; try again later"))
        guard case .failed(let message) = states[2] else { return XCTFail("\(states[2])") }
        XCTAssertTrue(message.contains("api.openai.com"), message)
    }

    func testDeepLStatusesHaveTheirOwnMessages() throws {
        var answers = Self.answers
        answers["api-free.deepl.com"] = RecordedHostFetchedSections.json(#"{"message":"Quota Exceeded"}"#, status: 456)
        XCTAssertEqual(try translations(run("translator.selection"), fetches(answers)),
                       [.failed("The DeepL quota is used up")])
        answers["api-free.deepl.com"] = RecordedHostFetchedSections.json(#"{"message":"Wrong key"}"#, status: 403)
        XCTAssertEqual(try translations(run("translator.selection"), fetches(answers)),
                       [.failed("DeepL rejected the API key")])
    }

    /// A setting a source cannot work without fails only that source's
    /// section, in words that say where to repair it.
    func testAnAddressThatIsNotHTTPSFailsOnlyItsSource() throws {
        let shown = try run("translator.selection",
                            settings: translatorSettings(sources: ["DeepL", "Google"],
                                                         deepLEndpoint: "http://api-free.deepl.com"))
        XCTAssertNil(shown.section("deepl")?.fetch)
        XCTAssertEqual(shown.section("deepl")?.text, "Configure an https address for DeepL in Translator's Plugin Settings")
        let fetches = fetches()
        XCTAssertEqual(try translations(shown, fetches), [.text("Guten Morgen")])
        XCTAssertEqual(fetches.requests.map { $0.url.host }, ["clients5.google.com"])
    }

    // MARK: Where the text comes from

    func testTranslateInputAsksForTheTextWithoutReadingTheSelection() throws {
        let settings = translatorSettings(sources: ["DeepL", "Google"])
        let opened = try run("translator.input", settings: settings)
        XCTAssertEqual(opened.run.requests, [])
        let form = try XCTUnwrap(opened.view.form)
        XCTAssertEqual(form.fields.map(\.key), ["text"])
        XCTAssertEqual(form.fields.first?.placeholder, "Text to translate")
        XCTAssertTrue(form.submitsOnReturn)
        XCTAssertNil(opened.view.detail, "Nothing is translated before the text is sent")

        let submitted = try run("translator.input", settings: settings,
                                event: .submitted(values: .object(["text": .string("Thank you")])),
                                state: opened.answer.state)
        XCTAssertEqual(submitted.view.form?.values, .object(["text": .string("Thank you")]), "The typed text stays")
        XCTAssertEqual(submitted.sections.map(\.id), ["deepl", "google"])
        let fetches = fetches()
        XCTAssertEqual(try translations(submitted, fetches), [.text("Guten Morgen"), .text("Guten Morgen")])
        guard case .object(let body) = try body(to: "api-free.deepl.com", in: fetches) else { return XCTFail() }
        XCTAssertEqual(body["text"], .array([.string("Thank you")]), "What the user typed is what is sent")

        let blank = helper.run(PluginTestInvocation("translator.input", input: settings,
                                                    event: .submitted(values: .object(["text": .string("  ")])),
                                                    state: submitted.answer.state),
                               of: plugin, answering: RecordedHostServices())
        XCTAssertEqual(try blank.answer(), PluginScriptAnswer(), "Blank text changes nothing")
    }

    func testTranslateClipboardReadsTheClipboardInsteadOfTheSelection() throws {
        let shown = try run("translator.clipboard", selection: "not this", clipboardText: "Thank you")
        XCTAssertEqual(shown.run.requests.map(\.service), [.readCurrentClipboard])
        XCTAssertEqual(shown.text, .string("Thank you"))

        let empty = try run("translator.clipboard", clipboardText: nil)
        XCTAssertEqual(empty.text, .string(""), "A clipboard without text leaves the field for typing")
        XCTAssertNil(empty.view.detail)
    }

    /// An App that keeps its selection to itself leaves nothing to translate,
    /// so the view asks for the text instead of failing.
    func testNothingToTranslateOpensTheViewForTyping() throws {
        let opened = try run("translator.selection", selection: "  ")
        let form = try XCTUnwrap(opened.view.form)
        XCTAssertEqual(form.fields.first?.placeholder, "Text to translate")
        XCTAssertEqual(opened.text, .string(""))

        let submitted = try run("translator.selection", event: .submitted(values: .object(["text": .string("Good morning")])),
                                state: opened.answer.state)
        XCTAssertEqual(try translations(submitted, fetches()), [.text("Guten Morgen")])
    }

    /// The selected text can be changed and sent again with Return, as
    /// typed text can: the field holds it as it is, Markdown markers and all.
    func testTheSelectedTextCanBeEditedAndTranslatedAgain() throws {
        let text = "2 * 3 = *six* and `code`"
        let shown = try run("translator.selection", selection: text)
        XCTAssertEqual(shown.text, .string(text))

        let edited = try run("translator.selection", event: .submitted(values: .object(["text": .string("Good evening")])),
                             state: shown.answer.state)
        XCTAssertEqual(edited.text, .string("Good evening"))
        let fetches = fetches()
        _ = try translations(edited, fetches)
        guard case .object(let body) = try body(to: "api-free.deepl.com", in: fetches) else { return XCTFail() }
        XCTAssertEqual(body["text"], .array([.string("Good evening")]))
    }

    /// An edit not yet sent is what a change of language translates, so it
    /// is never lost under the field.
    func testAChangeOfLanguageTranslatesWhatTheFieldHolds() throws {
        let shown = try run("translator.selection")
        let typing = try run("translator.selection",
                             event: .fieldChanged(field: "text", values: .object(["text": .string("Good evening")])),
                             state: shown.answer.state)
        XCTAssertEqual(typing.text, .string("Good evening"))
        XCTAssertEqual(try XCTUnwrap(typing.view.detail).sections, try XCTUnwrap(shown.view.detail).sections,
                       "Typing alone translates nothing yet")

        let changed = try run("translator.selection", settings: translatorSettings(target: "FR"),
                              event: .settingChanged(key: "target_language", value: .string("FR")),
                              state: typing.answer.state)
        XCTAssertEqual(changed.text, .string("Good evening"))
        let fetches = fetches()
        _ = try translations(changed, fetches)
        guard case .object(let body) = try body(to: "api-free.deepl.com", in: fetches) else { return XCTFail() }
        XCTAssertEqual(body["text"], .array([.string("Good evening")]))
        XCTAssertEqual(body["target_lang"], .string("FR"))
    }

    /// The text is held once in the state and once per source in the view,
    /// three times over in Google's address, so the view says a text that
    /// would outgrow the Host's budgets is too long instead of ending.
    func testATextTooLongForTheViewIsRefusedInTheView() throws {
        let all = translatorSettings(sources: ["Google", "DeepL", "OpenAI"])
        let fitting = try run("translator.selection", settings: all, selection: String(repeating: "早", count: 10_000))
        XCTAssertEqual(fitting.sections.map(\.id), ["google", "deepl", "openai"])

        let long = try run("translator.selection", settings: all, selection: String(repeating: "早", count: 30_000))
        XCTAssertEqual(long.sections.map(\.id), ["too_long"])
        XCTAssertEqual(long.section("too_long")?.text, "The text is too long to translate at once. Select a shorter part.")
        XCTAssertEqual(long.text, .string(""), "The field is left for a shorter text")

        let typed = try run("translator.input", settings: all,
                            event: .submitted(values: .object(["text": .string(String(repeating: "a\n", count: 70_000))])),
                            state: .object(["text": .null]))
        XCTAssertEqual(typed.sections.map(\.id), ["too_long"])
    }

    // MARK: Consent

    /// A self-hosted address is contacted only once the user consented to
    /// its host; until then its section says the Plugin may not reach it and
    /// nothing is sent.
    func testAnUnconsentedSelfHostedEndpointIsRefusedAndAConsentedOneIsUsed() throws {
        let shown = try run("translator.selection",
                            settings: translatorSettings(sources: ["OpenAI"], openAIEndpoint: "https://llm.example.org/v1"))
        var answers = Self.answers
        answers["llm.example.org"] = answers["api.openai.com"]

        let refused = fetches(answers)
        XCTAssertEqual(try translations(shown, refused),
                       [.failed("Translator may not contact llm.example.org until it is allowed in its Plugin Settings")])
        XCTAssertEqual(refused.requests, [])

        let consented = fetches(answers, consentedHosts: ["llm.example.org"])
        XCTAssertEqual(try translations(shown, consented), [.text("Guten Morgen.")])
        XCTAssertEqual(try request(to: "llm.example.org", in: consented).url.absoluteString,
                       "https://llm.example.org/v1/chat/completions")
    }

    /// Revoking network access sends nothing more, cached answers included.
    func testTranslatorRevokedContactStopsTheSourcesBeforeTheNetwork() throws {
        let shown = try run("translator.selection", settings: translatorSettings(sources: ["Google"]))
        let fetches = fetches()
        XCTAssertEqual(try translations(shown, fetches), [.text("Guten Morgen")])

        fetches.deniedCapabilities = [.contactHTTPS]
        XCTAssertEqual(try translations(shown, fetches), [.failed("Network access is not granted to this Plugin")])
        XCTAssertEqual(fetches.requests.count, 1)
    }

    // MARK: Keys

    /// Pins what the keyed sources put on the wire, byte for byte, so moving
    /// their requests into the Plugin cannot change one. Body members are in
    /// sorted order, as they were when the Host encoded them.
    func testDeepLAndOpenAIRequestsAreUnchanged() throws {
        let shown = try run("translator.selection",
                            settings: translatorSettings(sources: ["DeepL", "OpenAI"], formality: "prefer_more"))
        let fetches = fetches()
        _ = try translations(shown, fetches)
        XCTAssertEqual(fetches.requests.count, 2)

        let deepL = try request(to: "api-free.deepl.com", in: fetches)
        XCTAssertEqual(deepL.method, "POST")
        XCTAssertEqual(deepL.url.absoluteString, "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(deepL.headers, ["Authorization": "DeepL-Auth-Key deepl-secret",
                                       "Content-Type": "application/json"])
        XCTAssertEqual(String(decoding: try XCTUnwrap(deepL.body), as: UTF8.self),
                       #"{"formality":"prefer_more","source_lang":"EN","target_lang":"DE","text":["Good morning"]}"#)
        XCTAssertEqual(deepL.maximumResponseBytes, HTTPSRequestBudgets.maximumResponseBodyBytes)

        let openAI = try request(to: "api.openai.com", in: fetches)
        XCTAssertEqual(openAI.method, "POST")
        XCTAssertEqual(openAI.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(openAI.headers, ["Authorization": "Bearer openai-secret",
                                        "Content-Type": "application/json"])
        XCTAssertEqual(String(decoding: try XCTUnwrap(openAI.body), as: UTF8.self),
                       #"{"messages":[{"content":"You are a translation engine. "#
            + #"Translate the text the user sends into German, including every word or phrase in another language, "#
            + #"such as quoted terms. Reply with the translation only, without quotes, "#
            + #"notes, or explanations, and keep its line breaks and formatting.","role":"system"},"#
            + #"{"content":"Good morning","role":"user"}],"model":"gpt-test"}"#)
    }
}
