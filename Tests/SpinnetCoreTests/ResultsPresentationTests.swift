import XCTest
@testable import SpinnetCore

/// Answers by host, from any thread, so the sections of one presentation can
/// run at once. A host may answer late or not at all.
final class RoutedHTTPSTransport: HTTPSTransport {
    struct Route {
        var response: HTTPSTransportResponse?
        var delay: TimeInterval = 0
    }

    private let lock = NSLock()
    private var routes: [String: Route]
    private var sent: [HTTPSTransportRequest] = []

    init(_ routes: [String: Route] = [:]) { self.routes = routes }

    var requests: [HTTPSTransportRequest] { lock.withLock { sent } }

    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        let route = lock.withLock { () -> Route? in
            sent.append(request)
            return routes[request.url.host ?? ""]
        }
        if let delay = route?.delay, delay > 0 { Thread.sleep(forTimeInterval: delay) }
        guard let response = route?.response else { throw HTTPSTransportError.connectionFailed }
        return response
    }

    static func json(_ body: String, status: Int = 200, delay: TimeInterval = 0) -> Route {
        Route(response: ScriptedHTTPSTransport.json(body, status: status), delay: delay)
    }
}

/// `present_results` asks the Host to show a result popup: the original text,
/// or a field to type it into, then one section per request. The script
/// returns at once; the Host sends every section's request through the same
/// HTTPS policy as `https_request`, at the same time, and fills each section
/// in as its answer arrives. The Plugin never sees the answers.
final class ResultsPresentationTests: XCTestCase {
    private var manifest: PluginManifest!
    private var package: PluginPackage!
    private var grants: PluginCapabilityGrantStore!
    private var credentials: InMemoryPluginCredentialStore!
    private var presented: [ResultsPresentationSession] = []
    /// What the Host's language detector reports for the text being resolved.
    private var detected: String?

    override func setUpWithError() throws {
        manifest = try NetworkPluginFixture.manifest(hosts: ["api.example.com", "slow.example.com", "down.example.com"])
        package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/network"), manifest: manifest)
        grants = PluginCapabilityGrantStore()
        for capability in manifest.capabilities {
            grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                               capability: capability, scope: manifest.scope(for: capability))
        }
        credentials = InMemoryPluginCredentialStore()
        try credentials.setSecret("s3cret", for: manifest.id, reference: "key")
        presented = []
    }

    private func broker(_ transport: HTTPSTransport) -> CapabilityCheckedHostServiceBroker {
        CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { "" }, clipboardWriter: { _ in },
            httpsTransport: transport, credentialStore: credentials,
            resultsPresenter: { [unowned self] session in presented.append(session) },
            languageDetector: { [unowned self] _ in detected }
        )
    }

    private func present(_ input: JSONValue, from commandID: String = "fetch",
                         transport: HTTPSTransport = RoutedHTTPSTransport()) throws -> JSONValue {
        let command = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == commandID })
        let action = try ActionConfiguration(id: ActionID(commandID), pluginID: manifest.id, command: command, input: .null)
        let request = PluginRuntimeHostServiceRequest(invocationID: "invocation", actionID: action.id,
                                                      service: .presentResults, input: input)
        return try broker(transport).execute(request: request, for: package, action: action)
    }

    private func section(_ title: String, host: String = "api.example.com", pointer: String = "/text",
                         extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = [
            "title": .string(title),
            "request": .object([
                "method": .string("POST"),
                "url": .string("https://\(host)/translate"),
                "json_body": .object(["q": .array([.string("{{text}}")]), "target": .string("DE")]),
                "credential": .object(["reference": .string("key"), "format": .string("Key {credential}")])
            ]),
            "result_pointer": .string(pointer)
        ]
        fields.merge(extra) { $1 }
        return .object(fields)
    }

    private func presentation(original: String? = "Good morning", sections: [JSONValue]) -> JSONValue {
        var fields: [String: JSONValue] = ["title": .string("Translate"), "sections": .array(sections)]
        if let original { fields["original"] = .string(original) }
        else { fields["input"] = .object(["placeholder": .string("Text to translate")]) }
        return .object(fields)
    }

    /// Resolves every section and returns the states in the order they arrived.
    private func resolve(_ session: ResultsPresentationSession, text: String) -> [(Int, ResultsSectionState)] {
        let lock = NSLock()
        var updates: [(Int, ResultsSectionState)] = []
        session.resolve(text: text, started: { _ in }) { index, state in lock.withLock { updates.append((index, state)) } }
        return updates
    }

    /// The variant the session chose for `text`, and its section states.
    private func resolveVariant(_ session: ResultsPresentationSession,
                                text: String) -> (ResultsPresentation.Variant?, [ResultsSectionState]) {
        let lock = NSLock()
        var variant: ResultsPresentation.Variant?
        var states: [Int: ResultsSectionState] = [:]
        session.resolve(text: text, started: { chosen in lock.withLock { variant = chosen } }) { index, state in
            lock.withLock { states[index] = state }
        }
        return (variant, (0..<states.count).compactMap { states[$0] })
    }

    // MARK: Presenting

    func testPresentingHandsTheHostThePopupAndTellsThePluginNothing() throws {
        let result = try present(presentation(sections: [section("One"), section("Two")]))
        XCTAssertEqual(result, .null, "The Plugin learns nothing from presenting")
        let session = try XCTUnwrap(presented.first)
        XCTAssertEqual(session.presentation.title, "Translate")
        XCTAssertEqual(session.presentation.original, "Good morning")
        XCTAssertNil(session.presentation.inputPlaceholder)
        XCTAssertEqual(session.presentation.main.sections.map(\.title), ["One", "Two"])
    }

    func testAPopupThatAsksForTheTextHasNoOriginal() throws {
        _ = try present(presentation(original: nil, sections: [section("One")]))
        let session = try XCTUnwrap(presented.first)
        XCTAssertNil(session.presentation.original)
        XCTAssertEqual(session.presentation.inputPlaceholder, "Text to translate")
        XCTAssertEqual(session.presentation.submitTitle, "Submit", "The button has a Host default")
        _ = try present(.object(["title": .string("T"), "sections": .array([section("One")]),
                                 "input": .object(["submit_title": .string("Translate")])]))
        XCTAssertEqual(presented.last?.presentation.submitTitle, "Translate")
        XCTAssertEqual(presented.last?.presentation.inputPlaceholder, "")
    }

    func testMalformedPresentationsAreRefused() {
        let one = section("One")
        let cases: [(String, JSONValue)] = [
            ("not an object", .string("hi")),
            ("no sections", presentation(sections: [])),
            ("too many sections", presentation(sections: Array(repeating: one, count: ResultsPresentationBudgets.maximumSections + 1))),
            ("both original and input", .object(["title": .string("T"), "original": .string("a"),
                                                 "input": .object([:]), "sections": .array([one])])),
            ("neither original nor input", .object(["title": .string("T"), "sections": .array([one])])),
            ("empty title", .object(["title": .string(" "), "original": .string("a"), "sections": .array([one])])),
            ("unknown member", .object(["title": .string("T"), "original": .string("a"), "sections": .array([one]),
                                        "html": .string("<b>")])),
            ("section without a result pointer", presentation(sections: [.object(["title": .string("One"),
                                                                                 "request": .object(["method": .string("GET"), "url": .string("https://api.example.com/")])])])),
            ("pointer not starting with a slash", presentation(sections: [section("One", pointer: "text")])),
            ("a raw body instead of json_body", presentation(sections: [section("One", extra: [
                "request": .object(["method": .string("POST"), "url": .string("https://api.example.com/"), "body": .string("x")])
            ])])),
            ("a GET with a body", presentation(sections: [section("One", extra: [
                "request": .object(["method": .string("GET"), "url": .string("https://api.example.com/"),
                                    "json_body": .object([:])])
            ])])),
            ("a reserved header", presentation(sections: [section("One", extra: [
                "request": .object(["method": .string("GET"), "url": .string("https://api.example.com/"),
                                    "headers": .object(["Cookie": .string("a=b")])])
            ])]))
        ]
        for (name, input) in cases {
            XCTAssertThrowsError(try present(input), name) { error in
                XCTAssertEqual((error as? PluginHostServiceError)?.runtimeFailureCategory, .hostServiceFailed, name)
            }
        }
        XCTAssertTrue(presented.isEmpty)
    }

    /// Every section's host is checked before anything is shown, so a
    /// popup never opens for a request that could not be sent.
    func testASectionForAnUnconsentedHostRefusesThePresentation() throws {
        XCTAssertThrowsError(try present(presentation(sections: [section("One"), section("Two", host: "attacker.example.net")]))) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.contactHTTPS))
        }
        XCTAssertTrue(presented.isEmpty)
    }

    func testPresentingNeedsTheContactGrantForThatCommand() throws {
        XCTAssertThrowsError(try present(presentation(sections: [section("One")]), from: "copy"), "Copy is outside the contact scope") { error in
            XCTAssertEqual(error as? PluginHostServiceError, .capabilityDenied(.contactHTTPS))
        }
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version,
                           capability: .contactHTTPS, scope: manifest.scope(for: .contactHTTPS))
        XCTAssertThrowsError(try present(presentation(sections: [section("One")])))
        XCTAssertTrue(presented.isEmpty)
    }

    // MARK: Resolving

    func testEachSectionSendsItsRequestWithTheTextAndShowsItsResult() throws {
        let transport = RoutedHTTPSTransport(["api.example.com": RoutedHTTPSTransport.json(#"{"text":"  Guten Morgen\n"}"#)])
        _ = try present(presentation(sections: [section("One")]), transport: transport)
        let updates = resolve(try XCTUnwrap(presented.first), text: #"Say "hi""#)
        XCTAssertEqual(updates.map(\.0), [0])
        XCTAssertEqual(updates.first?.1, .succeeded("Guten Morgen"), "Surrounding whitespace is trimmed")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Authorization"], "Key s3cret", "The Host adds the secret")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(request.body))
        XCTAssertEqual(body, .object(["q": .array([.string(#"Say "hi""#)]), "target": .string("DE")]),
                       "The text replaces the placeholder as a JSON string, whatever it contains")
    }

    /// A source that fails or answers slowly does not hold back the others.
    func testASlowOrFailingSectionDoesNotHoldBackTheOthers() throws {
        let transport = RoutedHTTPSTransport([
            "api.example.com": RoutedHTTPSTransport.json(#"{"text":"fast"}"#),
            "slow.example.com": RoutedHTTPSTransport.json(#"{"text":"slow"}"#, delay: 0.4)
        ])
        _ = try present(presentation(sections: [section("Slow", host: "slow.example.com"), section("Down", host: "down.example.com"),
                                                section("Fast")]), transport: transport)
        let updates = resolve(try XCTUnwrap(presented.first), text: "Good morning")
        XCTAssertEqual(Set(updates.prefix(2).map(\.0)), [1, 2], "The fast and the failed sections arrive first")
        XCTAssertEqual(updates.last?.0, 0)
        let states = Dictionary(updates, uniquingKeysWith: { $1 })
        XCTAssertEqual(states[0], .succeeded("slow"))
        XCTAssertEqual(states[2], .succeeded("fast"))
        guard case .failed(let message)? = states[1] else { return XCTFail("\(String(describing: states[1]))") }
        XCTAssertTrue(message.contains("down.example.com"), message)
    }

    func testAFailedAnswerShowsTheSectionsOwnMessage() throws {
        let transport = RoutedHTTPSTransport(["api.example.com": RoutedHTTPSTransport.json(#"{"error":{"message":"Model not found"}}"#, status: 404)])
        _ = try present(presentation(sections: [
            section("Mapped", extra: ["status_messages": .object(["404": .string("Choose another model")])]),
            section("Pointed", extra: ["error_pointer": .string("/error/message")]),
            section("Plain")
        ]), transport: transport)
        let states = Dictionary(resolve(try XCTUnwrap(presented.first), text: "x"), uniquingKeysWith: { $1 })
        XCTAssertEqual(states[0], .failed("Choose another model"))
        XCTAssertEqual(states[1], .failed("Model not found"))
        XCTAssertEqual(states[2], .failed("The service answered 404"))
    }

    func testAnAnswerWithoutTheResultIsAFailureOfThatSection() throws {
        let transport = RoutedHTTPSTransport(["api.example.com": RoutedHTTPSTransport.json(#"{"other":1}"#)])
        _ = try present(presentation(sections: [section("One")]), transport: transport)
        XCTAssertEqual(resolve(try XCTUnwrap(presented.first), text: "x").first?.1,
                       .failed("The service sent an unexpected response"))
    }

    func testAMissingSecretFailsOnlyItsSection() throws {
        let transport = RoutedHTTPSTransport(["api.example.com": RoutedHTTPSTransport.json(#"{"text":"ok"}"#)])
        var noKey = section("No Key")
        if case .object(var fields) = noKey, case .object(var request)? = fields["request"] {
            request["credential"] = .object(["reference": .string("absent")])
            fields["request"] = .object(request)
            noKey = .object(fields)
        }
        _ = try present(presentation(sections: [noKey, section("Keyed")]), transport: transport)
        let states = Dictionary(resolve(try XCTUnwrap(presented.first), text: "x"), uniquingKeysWith: { $1 })
        XCTAssertEqual(states[1], .succeeded("ok"))
        guard case .failed(let message)? = states[0] else { return XCTFail() }
        XCTAssertTrue(message.contains("credential"), message)
        XCTAssertEqual(transport.requests.count, 1, "Nothing is sent without its secret")
    }

    /// Authority is read again whenever the popup sends, so revoking the
    /// grant while a popup waits for input stops the requests.
    func testRevokingContactAfterPresentingStopsTheRequests() throws {
        let transport = RoutedHTTPSTransport(["api.example.com": RoutedHTTPSTransport.json(#"{"text":"ok"}"#)])
        _ = try present(presentation(original: nil, sections: [section("One")]), transport: transport)
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version,
                           capability: .contactHTTPS, scope: manifest.scope(for: .contactHTTPS))
        guard case .failed? = resolve(try XCTUnwrap(presented.first), text: "typed").first?.1 else { return XCTFail() }
        XCTAssertEqual(transport.requests, [])
    }

    func testTextLongerThanARequestBodyIsRefused() throws {
        let transport = RoutedHTTPSTransport(["api.example.com": RoutedHTTPSTransport.json(#"{"text":"ok"}"#)])
        _ = try present(presentation(original: nil, sections: [section("One")]), transport: transport)
        let long = String(repeating: "a", count: HTTPSRequestBudgets.maximumRequestBodyBytes + 1)
        guard case .failed? = resolve(try XCTUnwrap(presented.first), text: long).first?.1 else { return XCTFail() }
        XCTAssertEqual(transport.requests, [])
    }

    // MARK: Direction, URLs and joined results

    /// A popup may carry a second set of sections for text that is already in
    /// one language, so the Host can turn the direction around itself.
    func testTheAlternateSectionsAreUsedWhenTheTextIsInTheirLanguage() throws {
        let transport = RoutedHTTPSTransport(["api.example.com": RoutedHTTPSTransport.json(#"{"text":"answered"}"#)])
        let input: JSONValue = .object([
            "title": .string("Translate"),
            "subtitle": .string("English → Chinese"),
            "original": .string("Good morning"),
            "sections": .array([section("Into Chinese")]),
            "alternate": .object(["when_language": .string("zh"), "subtitle": .string("Chinese → English"),
                                  "sections": .array([section("Into English"), section("Second")])])
        ])
        detected = "en"
        _ = try present(input, transport: transport)
        let session = try XCTUnwrap(presented.first)
        XCTAssertEqual(session.presentation.main.subtitle, "English → Chinese")
        XCTAssertEqual(session.presentation.alternate?.variant.sections.map(\.title), ["Into English", "Second"])
        XCTAssertEqual(session.presentation.variants.count, 2)

        let english = resolveVariant(session, text: "Good morning")
        XCTAssertEqual(english.0?.sections.map(\.title), ["Into Chinese"])
        XCTAssertEqual(english.1, [.succeeded("answered")])

        detected = "zh-Hans"
        let chinese = resolveVariant(session, text: "早上好")
        XCTAssertEqual(chinese.0?.subtitle, "Chinese → English", "A primary subtag is enough to match")
        XCTAssertEqual(chinese.0?.sections.map(\.title), ["Into English", "Second"])
        XCTAssertEqual(chinese.1.count, 2)

        detected = nil
        XCTAssertEqual(resolveVariant(session, text: "???").0?.sections.map(\.title), ["Into Chinese"],
                       "Without a detected language the popup keeps its main direction")
    }

    func testTextInAURLIsPercentEncoded() throws {
        let transport = RoutedHTTPSTransport(["api.example.com": RoutedHTTPSTransport.json(#"{"text":"ok"}"#)])
        let get: JSONValue = .object([
            "title": .string("Translate"), "original": .string("a"),
            "sections": .array([.object([
                "title": .string("Free"),
                "request": .object(["method": .string("GET"),
                                    "url": .string("https://api.example.com/t?sl=auto&q={{text}}&dt=t")]),
                "result_pointer": .string("/text")
            ])])
        ])
        _ = try present(get, transport: transport)
        XCTAssertEqual(resolve(try XCTUnwrap(presented.first), text: "a b&c=d/e#f?").first?.1, .succeeded("ok"))
        XCTAssertEqual(transport.requests.first?.url.absoluteString,
                       "https://api.example.com/t?sl=auto&q=a%20b%26c%3Dd%2Fe%23f%3F&dt=t",
                       "The text cannot leave its query value")
    }

    func testMalformedDirectionsAreRefused() {
        let one = section("One")
        let cases: [(String, JSONValue)] = [
            ("alternate without a language", .object(["title": .string("T"), "original": .string("a"),
                                                      "sections": .array([one]),
                                                      "alternate": .object(["sections": .array([one])])])),
            ("alternate without sections", .object(["title": .string("T"), "original": .string("a"),
                                                    "sections": .array([one]),
                                                    "alternate": .object(["when_language": .string("zh")])])),
            ("an alternate section for an unconsented host",
             .object(["title": .string("T"), "original": .string("a"), "sections": .array([one]),
                      "alternate": .object(["when_language": .string("zh"),
                                            "sections": .array([section("Bad", host: "attacker.example.net")])])])),
            ("an empty language", .object(["title": .string("T"), "original": .string("a"), "sections": .array([one]),
                                           "alternate": .object(["when_language": .string(" "),
                                                                 "sections": .array([one])])]))
        ]
        for (name, input) in cases {
            XCTAssertThrowsError(try present(input), name)
        }
        XCTAssertTrue(presented.isEmpty)
    }

    func testJSONPointersFollowRFC6901() {
        let document: JSONValue = .object(["a": .array([.object(["b/c": .string("slash"), "d~e": .string("tilde")])]),
                                           "": .string("empty")])
        XCTAssertEqual(document.value(atPointer: "/a/0/b~1c"), .string("slash"))
        XCTAssertEqual(document.value(atPointer: "/a/0/d~0e"), .string("tilde"))
        XCTAssertEqual(document.value(atPointer: "/"), .string("empty"))
        XCTAssertEqual(document.value(atPointer: ""), document)
        XCTAssertNil(document.value(atPointer: "/a/1"))
        XCTAssertNil(document.value(atPointer: "/a/-"))
        XCTAssertNil(document.value(atPointer: "/a/01"))
    }
}
