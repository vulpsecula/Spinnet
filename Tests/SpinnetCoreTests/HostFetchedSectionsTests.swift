import Foundation
import XCTest
@testable import SpinnetCore

/// Host-Fetched Sections (ADR 0010), driven through their seams: a View
/// Session whose renderer presents the sections of each view it is shown, a
/// send the test answers by hand, background work the test runs when it
/// chooses, and a clock the test advances.
final class HostFetchedSectionsTests: XCTestCase {
    private var clock: ManualClock!
    private var runner: HeldEventRunner!
    private var background: HeldWork!
    private var renderer: SectionPresentingRenderer!
    private var engine: HostFetchedSections!
    private var sessions: PluginViewSessions!
    /// Every request the engine asked to send, in the order the sends ran.
    private var sent: [(action: ActionConfiguration, request: HostFetchedRequest,
                        cancellation: HostFetchedSections.Cancellation)] = []
    /// What a send answers for a request, by URL.
    private var answers: [String: Result<JSONValue, Error>] = [:]
    /// Happens while a request is on the network, before it answers.
    private var duringSend: (() -> Void)?

    override func setUp() {
        clock = ManualClock()
        runner = HeldEventRunner()
        background = HeldWork()
        renderer = SectionPresentingRenderer()
        sent = []
        answers = [:]
        duringSend = nil
        engine = HostFetchedSections(send: { [unowned self] action, request, cancellation in
            sent.append((action, request, cancellation))
            duringSend?()
            guard case .object(let fields) = request.request, case .string(let url)? = fields["url"],
                  let answer = answers[url] else { throw PluginHostServiceError.failed("The request failed") }
            return try answer.get()
        }, schedule: clock.schedule, background: background.enqueue, executor: { $0() })
        renderer.engine = engine
        sessions = PluginViewSessions(renderer: renderer, runEvent: runner.run, schedule: clock.schedule,
                                      showFeedback: { _ in }, fetchedSections: engine)
    }

    // MARK: - show

    /// Acceptance: in `show` mode the Host extracts the answer by JSON
    /// pointer and shows it; the script is never run with it.
    func testAShowSectionIsLoadingUntilTheHostExtractsItsAnswerByPointer() throws {
        answers["https://api.example.com/translate"] = .success(Self.response(#"{"translations":[{"text":" Guten Morgen "}]}"#))
        try start([Self.show("deepl", pointer: "/translations/0/text")])

        XCTAssertEqual(state("deepl"), .loading)
        XCTAssertEqual(background.pending, 1, "The request is sent off the sessions' executor")
        background.runAll()

        XCTAssertEqual(state("deepl"), .text("Guten Morgen"))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].request.mode, .show)
        XCTAssertEqual(sent[0].request.request, Self.request())
        XCTAssertEqual(sent[0].action.commandID, try Self.action().commandID,
                       "The request is sent with the authority of the Command that presented the view")
        XCTAssertEqual(runner.runs.count, 0, "The Plugin never sees a show section's answer")
    }

    func testAShowSectionSaysWhyItHasNoAnswer() throws {
        let cases: [(Result<JSONValue, Error>, HostFetchedSectionState)] = [
            (.success(Self.response(#"{"message":"quota"}"#, status: 456)), .failed("The quota is used up")),
            (.success(Self.response(#"{"message":" Wrong language "}"#, status: 400)), .failed("Wrong language")),
            (.success(Self.response("gateway", status: 502)), .failed("The service answered 502")),
            (.success(Self.response(#"{"other":1}"#)), .failed("The service sent an unexpected response")),
            (.failure(PluginHostServiceError.capabilityDenied(.contactHTTPS)),
             .failed("Network access is not granted to this Plugin")),
            (.failure(PluginHostServiceError.failed("The request timed out")), .failed("The request timed out"))
        ]
        for (answer, expected) in cases {
            setUp()
            answers["https://api.example.com/translate"] = answer
            try start([Self.show("deepl", pointer: "/text", extra: [
                "error_pointer": .string("/message"),
                "status_messages": .object(["456": .string("The quota is used up")])
            ])])
            background.runAll()
            XCTAssertEqual(state("deepl"), expected, "\(answer)")
        }
    }

    // MARK: - deliver

    /// Acceptance: in `deliver` mode the response reaches the script as a
    /// `section_delivered` View Event, through the session's own ordering,
    /// and the section shows the text the script answers with.
    func testADeliverSectionHandsTheResponseToTheScriptAndShowsTheTextItAnswers() throws {
        let response = Self.response(#"{"rate":1.08}"#)
        answers["https://api.example.com/translate"] = .success(response)
        let session = try start([Self.deliver("rate")])
        session.send(.actionChosen("refresh"))
        XCTAssertEqual(runner.runs.count, 1)

        background.runAll()
        XCTAssertEqual(state("rate"), .loading)
        XCTAssertEqual(runner.runs.count, 1, "The delivery waits behind the event in flight")

        runner.runs[0].finish(.succeeded(Self.answer([Self.deliver("rate", text: "Before delivery")])))
        XCTAssertEqual(runner.runs.count, 2)
        XCTAssertEqual(runner.runs[1].delivery.event, .sectionDelivered(section: "rate", response: response))
        XCTAssertEqual(state("rate"), .loading, "A deliver section shows nothing of its own before delivery")

        runner.runs[1].finish(.succeeded(Self.answer([Self.deliver("rate", text: "1 EUR = 1.08 USD")])))
        XCTAssertEqual(state("rate"), .delivered("1 EUR = 1.08 USD"))
        XCTAssertEqual(sent.count, 1, "Answering the delivery sends nothing again")

        session.send(.actionChosen("other"))
        runner.runs[2].finish(.succeeded(Self.answer([Self.deliver("rate", text: "1 EUR = 1.09 USD")])))
        XCTAssertEqual(state("rate"), .delivered("1 EUR = 1.09 USD"), "Later views keep showing the script's text")
        XCTAssertEqual(sent.count, 1)
    }

    func testADeliveredSectionFailsWhenTheScriptFailsOrGivesItNoText() throws {
        answers["https://api.example.com/translate"] = .success(Self.response("{}"))
        try start([Self.deliver("rate")])
        background.runAll()
        runner.runs[0].finish(.failed(ActionFailure(pluginID: Self.pluginID, actionID: ActionID("event"),
                                                    category: .scriptedActionFailed, message: "rate is not a number")))
        XCTAssertEqual(state("rate"), .failed("rate is not a number"))

        setUp()
        answers["https://api.example.com/translate"] = .success(Self.response("{}"))
        try start([Self.deliver("rate")])
        background.runAll()
        runner.runs[0].finish(.succeeded(.null))
        XCTAssertEqual(state("rate"), .failed("The Plugin gave this section no text"))
    }

    /// A deliver section whose request fails has nothing to deliver.
    func testAFailedDeliverRequestShowsItsFailureAndRunsNoEvent() throws {
        try start([Self.deliver("rate")])
        background.runAll()
        XCTAssertEqual(state("rate"), .failed("The request failed"))
        XCTAssertEqual(runner.runs.count, 0)
    }

    /// Presenting again drops the old view's events, a waiting delivery with
    /// them; the section's response is delivered again, not fetched again.
    func testPresentingAgainDeliversAnAbandonedResponseAgainWithoutSendingItAgain() throws {
        let response = Self.response(#"{"rate":1.08}"#)
        answers["https://api.example.com/translate"] = .success(response)
        try start([Self.deliver("rate")])
        background.runAll()
        XCTAssertEqual(runner.runs.count, 1)

        try sessions.actionAnswered(Self.action(), with: Self.answer([Self.deliver("rate")]))
        XCTAssertEqual(runner.runs[0].stopReason, .cancelled)
        XCTAssertEqual(runner.runs.count, 2)
        XCTAssertEqual(runner.runs[1].delivery.event, .sectionDelivered(section: "rate", response: response))
        XCTAssertEqual(sent.count, 1)

        runner.runs[0].finish(.succeeded(Self.answer([Self.deliver("rate", text: "stale")])))
        XCTAssertEqual(state("rate"), .loading, "The abandoned delivery's answer is dropped")
        runner.runs[1].finish(.succeeded(Self.answer([Self.deliver("rate", text: "1.08")])))
        XCTAssertEqual(state("rate"), .delivered("1.08"))
    }

    // MARK: - Concurrency

    /// Acceptance: the sections of a view are sent at once, and each shows
    /// its answer as it arrives, so a slow one never holds back another.
    func testTheSectionsOfAViewAreSentAtOnceAndAnswerIndependently() throws {
        for host in ["a", "b", "c"] {
            answers["https://\(host).example.com/translate"] = .success(Self.response(#"{"text":"\#(host)"}"#))
        }
        try start([Self.show("a", host: "a.example.com"), Self.show("b", host: "b.example.com"),
                   Self.show("c", host: "c.example.com")])

        XCTAssertEqual(background.pending, 3, "Every request starts before any answers")
        background.run(at: 2)
        XCTAssertEqual(engine.states(for: Self.pluginID), ["a": .loading, "b": .loading, "c": .text("c")])
        background.run(at: 0)
        XCTAssertEqual(engine.states(for: Self.pluginID), ["a": .text("a"), "b": .loading, "c": .text("c")])
        background.runAll()
        XCTAssertEqual(engine.states(for: Self.pluginID), ["a": .text("a"), "b": .text("b"), "c": .text("c")])
    }

    /// The same on real threads: each send waits until the other has
    /// started, which only concurrent sends can satisfy.
    func testSectionsRunConcurrentlyOnRealThreads() throws {
        let queue = DispatchQueue(label: "HostFetchedSectionsTests.sessions")
        let bothStarted = DispatchGroup()
        bothStarted.enter()
        bothStarted.enter()
        let answered = expectation(description: "both sections answered")
        let engine = HostFetchedSections(send: { _, request, _ in
            bothStarted.leave()
            guard bothStarted.wait(timeout: .now() + 5) == .success else {
                throw PluginHostServiceError.failed("The other section was not sent at the same time")
            }
            guard case .object(let fields) = request.request, case .string(let url)? = fields["url"] else {
                throw PluginHostServiceError.failed("No URL")
            }
            return Self.response(#"{"text":"\#(url)"}"#)
        }, schedule: { _, _ in }, executor: { queue.async(execute: $0) })
        let token = engine.observeChanges { pluginID in
            let states = engine.states(for: pluginID)
            if states.count == 2, states.values.allSatisfy({ if case .text = $0 { return true }; return false }) {
                answered.fulfill()
            }
        }
        defer { engine.removeChangeObserver(token) }
        let renderer = SectionPresentingRenderer()
        renderer.engine = engine
        let sessions = PluginViewSessions(renderer: renderer, runEvent: { _, _, _, _, _ in },
                                          schedule: { _, _ in }, showFeedback: { _ in }, fetchedSections: engine)
        _ = try queue.sync {
            try sessions.actionAnswered(Self.action(), with: Self.answer([
                Self.show("a", host: "a.example.com"), Self.show("b", host: "b.example.com")
            ]))
        }
        wait(for: [answered], timeout: 10)
        queue.sync {
            XCTAssertEqual(engine.states(for: Self.pluginID), [
                "a": .text("https://a.example.com/translate"), "b": .text("https://b.example.com/translate")
            ])
        }
    }

    // MARK: - Budget

    /// Acceptance: a section has its own 15-second budget; one that outlives
    /// it fails, and its late answer changes nothing.
    func testASectionThatOutlivesItsBudgetFailsAndItsLateAnswerIsDropped() throws {
        answers["https://api.example.com/translate"] = .success(Self.response("{}"))
        try start([Self.deliver("rate")])

        clock.advance(by: ScriptedActionBudgets.hostFetchedSectionDeadline - 0.01)
        XCTAssertEqual(state("rate"), .loading)
        duringSend = { [unowned self] in
            clock.advance(by: 0.01)
            XCTAssertEqual(state("rate"), .failed("The request timed out"))
        }

        background.runAll()
        XCTAssertTrue(sent[0].cancellation.isCancelled, "A send past its budget is told to stop")
        XCTAssertEqual(state("rate"), .failed("The request timed out"))
        XCTAssertEqual(runner.runs.count, 0, "A late response is never delivered")
    }

    /// The budget is the section's own: waiting behind nothing, it is not
    /// the four-second event deadline.
    func testTheBudgetIsLongerThanAnEventsDeadline() throws {
        answers["https://api.example.com/translate"] = .success(Self.response(#"{"text":"late but fine"}"#))
        try start([Self.show("deepl")])
        clock.advance(by: ScriptedActionBudgets.viewEventDeadline + 1)
        background.runAll()
        XCTAssertEqual(state("deepl"), .text("late but fine"))
    }

    // MARK: - Cancellation

    /// Acceptance: closing the view cancels its sections, and an answer that
    /// arrives afterwards is dropped without side effects.
    func testClosingTheViewCancelsItsSectionsAndDropsLateAnswers() throws {
        answers["https://api.example.com/translate"] = .success(Self.response("{}"))
        let session = try start([Self.deliver("rate")])
        duringSend = { [unowned self] in
            session.close()
            XCTAssertEqual(engine.states(for: Self.pluginID), [:])
        }

        background.runAll()

        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].cancellation.isCancelled)
        XCTAssertEqual(runner.runs.count, 0, "The response that arrived after closing is not delivered")
        XCTAssertEqual(engine.states(for: Self.pluginID), [:])
    }

    /// Every other way a View Session ends cancels its sections too, and a
    /// section is never sent for a session that has ended.
    func testEveryWayASessionEndsCancelsItsSections() throws {
        let ends: [(PluginViewSessions, PluginID) -> Void] = [
            { $0.end(pluginID: $1, because: .pluginChanged) },
            { $0.end(pluginID: $1, because: .capabilityRevoked) },
            { sessions, pluginID in sessions.session(for: pluginID)?.close() }
        ]
        for end in ends {
            setUp()
            try start([Self.show("a", host: "a.example.com")])
            end(sessions, Self.pluginID)
            XCTAssertEqual(engine.states(for: Self.pluginID), [:])
            background.runAll()
            XCTAssertEqual(sent.count, 0, "A cancelled section sends nothing")
        }

        // A protocol violation in the script's answer ends the session.
        setUp()
        answers["https://api.example.com/translate"] = .success(Self.response("{}"))
        let session = try start([Self.show("a")])
        session.send(.submitted(values: .null))
        runner.runs[0].finish(.succeeded(.string("not an answer")))
        XCTAssertNil(sessions.session(for: Self.pluginID))
        background.runAll()
        XCTAssertEqual(sent.count, 0)
        XCTAssertEqual(engine.states(for: Self.pluginID), [:])

        // Presenting sections of a Plugin without a session sends nothing.
        engine.present([HostFetchedSection(id: "x", fetch: Self.fetch(mode: "show", pointer: "/text"))],
                       for: PluginID("com.example.other"))
        XCTAssertEqual(background.pending, 0)
    }

    /// Revoking a Capability ends the session through the grant store, and
    /// with it the sections in flight.
    func testRevokingACapabilityCancelsTheSectionsInFlight() throws {
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry()
        sessions.observe(registry: registry, grantStore: grants, on: { $0() })
        grants.setDecision(.granted, for: Self.pluginID, pluginVersion: "1.0.0", capability: .contactHTTPS)
        answers["https://api.example.com/translate"] = .success(Self.response("{}"))
        try start([Self.deliver("rate")])
        duringSend = {
            grants.setDecision(.denied, for: Self.pluginID, pluginVersion: "1.0.0", capability: .contactHTTPS)
        }

        background.runAll()

        XCTAssertNil(sessions.session(for: Self.pluginID))
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].cancellation.isCancelled)
        XCTAssertEqual(runner.runs.count, 0, "The response is not delivered to a session that ended")
        XCTAssertEqual(engine.states(for: Self.pluginID), [:])
    }

    // MARK: - Views

    /// A section keeps what it fetched across views while its id and fetch
    /// stay the same; a changed fetch is sent afresh, and a section the view
    /// no longer has is cancelled.
    func testASectionKeepsItsResultWhileItsFetchIsUnchanged() throws {
        answers["https://api.example.com/translate"] = .success(Self.response(#"{"text":"one"}"#))
        answers["https://b.example.com/translate"] = .success(Self.response(#"{"text":"two"}"#))
        let session = try start([Self.show("deepl")])
        background.runAll()

        session.send(.actionChosen("same"))
        runner.runs[0].finish(.succeeded(Self.answer([Self.show("deepl", text: "ignored in show mode")])))
        XCTAssertEqual(state("deepl"), .text("one"))
        XCTAssertEqual(sent.count, 1)

        session.send(.actionChosen("changed"))
        runner.runs[1].finish(.succeeded(Self.answer([Self.show("deepl", host: "b.example.com")])))
        XCTAssertEqual(state("deepl"), .loading)
        background.runAll()
        XCTAssertEqual(state("deepl"), .text("two"))
        XCTAssertEqual(sent.count, 2)

        answers["https://b.example.com/translate"] = nil
        session.send(.actionChosen("changed back"))
        runner.runs[2].finish(.succeeded(Self.answer([Self.show("deepl")])))
        let pending = sent.count
        session.send(.actionChosen("gone"))
        runner.runs[3].finish(.succeeded(Self.answer([])))
        XCTAssertNil(state("deepl"))
        background.runAll()
        XCTAssertEqual(sent.count, pending, "A section the view no longer has is not sent")
    }

    /// A view presented by another Command of the Plugin may not rely on
    /// what the first one fetched: its sections are sent afresh.
    func testPresentingFromAnotherCommandSendsTheSectionsAfresh() throws {
        answers["https://api.example.com/translate"] = .success(Self.response(#"{"text":"one"}"#))
        try start([Self.show("deepl")])
        background.runAll()

        try sessions.actionAnswered(Self.action(command: "example.other"), with: Self.answer([Self.show("deepl")]))
        XCTAssertEqual(state("deepl"), .loading)
        background.runAll()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].action.commandID, CommandID("example.other"))
    }

    /// Under `collections` r2 a call's view from the same Command keeps a
    /// section with the same ID and fetch, even with other overrides, and a
    /// delivery waiting behind the call is delivered again, not fetched
    /// again; a call's view from another Command sends the sections afresh
    /// under it; a call that answers no view changes nothing.
    func testACallKeepsTheSameCommandsSectionsAndSendsAnotherCommandsAfresh() throws {
        sessions = PluginViewSessions(renderer: renderer, runEvent: runner.run, schedule: clock.schedule,
                                      showFeedback: { _ in }, fetchedSections: engine,
                                      permitting: { _ in CollectionsFixtures.permits })
        let response = Self.response(#"{"text":"one"}"#)
        answers["https://api.example.com/translate"] = .success(response)
        let session = try start([Self.show("deepl")])
        background.runAll()
        let overridden = try ActionConfiguration(id: ActionID("other-item"), pluginID: Self.pluginID,
                                                 command: CommandDeclaration(id: CommandID("example.view"), title: "View",
                                                                             execution: .javascript, script: "view.js"),
                                                 input: .object(["into": .string("fr")]))

        XCTAssertTrue(sessions.call(overridden))
        runner.runs[0].finish(.succeeded(Self.answer([Self.show("deepl"), Self.deliver("rate")])))
        XCTAssertEqual(state("deepl"), .text("one"), "Kept: same Command, same ID and fetch")
        XCTAssertTrue(sessions.call(overridden))
        background.runAll()
        XCTAssertEqual(sent.count, 2, "Only the new section was sent")
        XCTAssertEqual(runner.runs.count, 2, "The delivery waits behind the call")
        runner.runs[1].finish(.succeeded(Self.answer([Self.show("deepl"), Self.deliver("rate")])))
        XCTAssertEqual(runner.runs[2].delivery.event, .sectionDelivered(section: "rate", response: response))
        XCTAssertEqual(sent.count, 2, "Delivered again, not fetched again")
        runner.runs[2].finish(.succeeded(.null))

        XCTAssertTrue(sessions.call(try Self.action(command: "example.other")))
        runner.runs[3].finish(.succeeded(.null))
        XCTAssertEqual(state("deepl"), .text("one"), "No view, no change")
        XCTAssertTrue(sessions.call(try Self.action(command: "example.other")))
        runner.runs[4].finish(.succeeded(Self.answer([Self.show("deepl")])))
        XCTAssertEqual(state("deepl"), .loading)
        background.runAll()
        XCTAssertEqual(sent.last?.action.commandID, CommandID("example.other"))
        XCTAssertEqual(state("deepl"), .text("one"))
        XCTAssertFalse(session.isEnded)
    }

    func testAnInvalidFetchFailsOnlyItsOwnSection() throws {
        answers["https://api.example.com/translate"] = .success(Self.response(#"{"text":"fine"}"#))
        try start([
            .object(["id": .string("bad"), "fetch": .object(["request": Self.request(), "mode": .string("show")])]),
            Self.show("good")
        ])
        background.runAll()
        guard case .failed(let message)? = state("bad") else { return XCTFail("\(String(describing: state("bad")))") }
        XCTAssertTrue(message.contains("pointer"), message)
        XCTAssertEqual(state("good"), .text("fine"))
        XCTAssertEqual(sent.count, 1)
    }

    func testAViewFetchesAtMostEightSections() throws {
        let sections = (0...HostFetchedSectionBudgets.maximumSections).map { Self.show("s\($0)") }
        try start(sections)
        XCTAssertEqual(background.pending, HostFetchedSectionBudgets.maximumSections)
        XCTAssertEqual(state("s\(HostFetchedSectionBudgets.maximumSections)"),
                       .failed("A view fetches at most 8 sections"))

        // The same section in a view with room for it is sent.
        let session = try XCTUnwrap(sessions.session(for: Self.pluginID))
        session.send(.actionChosen("fewer"))
        runner.runs[0].finish(.succeeded(Self.answer(Array(sections.dropFirst()))))
        XCTAssertEqual(state("s\(HostFetchedSectionBudgets.maximumSections)"), .loading)
        XCTAssertEqual(background.pending, HostFetchedSectionBudgets.maximumSections + 1)
    }

    // MARK: - The renderer's seam

    /// The Plugin View renderer reaches the engine as its
    /// `HostFetchedSectionProvider`: it presents the fetch sections of each
    /// view, redraws the sections it is told changed, and ends them with the
    /// session.
    func testTheEngineAnswersTheRenderersSeam() throws {
        answers["https://api.example.com/translate"] = .success(Self.response(#"{"text":"fine"}"#))
        let session = try start([])
        var changed: [String] = []
        let provider: HostFetchedSectionProvider = engine
        provider.onChange = { changedSession, id in
            XCTAssertTrue(changedSession === session)
            changed.append(id)
        }

        provider.sectionsPresented([
            PluginViewSection(id: "one", title: nil, text: nil, fetch: Self.fetch(mode: "show", pointer: "/text")),
            PluginViewSection(id: "two", title: nil, text: nil, fetch: Self.fetch(mode: "show", pointer: "/missing"))
        ], in: session)
        XCTAssertEqual(changed, ["one", "two"])
        XCTAssertEqual(provider.state(ofSection: "one", in: session), .loading)
        XCTAssertEqual(provider.state(ofSection: "unknown", in: session), .loading)

        changed = []
        background.run(at: 0)
        XCTAssertEqual(changed, ["one"], "Only the section whose state changed is redrawn")
        XCTAssertEqual(provider.state(ofSection: "one", in: session), .text("fine"))

        provider.sessionEnded(session)
        XCTAssertNil(engine.state(ofSection: "two", for: Self.pluginID))
        background.runAll()
        XCTAssertEqual(sent.count, 1, "A section of an ended session sends nothing")
    }

    // MARK: - Support

    private static let pluginID = PluginID("com.example.view")

    private func state(_ id: String) -> HostFetchedSectionState? {
        engine.state(ofSection: id, for: Self.pluginID)
    }

    @discardableResult
    private func start(_ sections: [JSONValue]) throws -> PluginViewSession {
        try sessions.actionAnswered(Self.action(), with: Self.answer(sections))
        return try XCTUnwrap(sessions.session(for: Self.pluginID))
    }

    private static func action(command: String = "example.view") throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("view-action"), pluginID: pluginID,
                                command: CommandDeclaration(id: CommandID(command), title: "View",
                                                            execution: .javascript, script: "view.js"),
                                input: .null)
    }

    /// A view as this test's renderer reads it: `{sections: [...]}`.
    private static func answer(_ sections: [JSONValue]) -> JSONValue {
        .object(["view": .object(["sections": .array(sections)]), "state": .null])
    }

    static func request(host: String = "api.example.com") -> JSONValue {
        .object([
            "method": .string("POST"),
            "url": .string("https://\(host)/translate"),
            "body": .string(#"{"text":"Good morning"}"#),
            "credential_uses": .array([.object(["reference": .string("key"), "header": .string("Authorization"),
                                                "template": .string("Key {credential}")])])
        ])
    }

    static func fetch(mode: String, pointer: String? = nil, host: String = "api.example.com",
                      extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = ["request": request(host: host), "mode": .string(mode)]
        if let pointer { fields["pointer"] = .string(pointer) }
        fields.merge(extra) { $1 }
        return .object(fields)
    }

    private static func show(_ id: String, pointer: String = "/text", host: String = "api.example.com",
                             text: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "title": .string(id),
                                           "fetch": fetch(mode: "show", pointer: pointer, host: host, extra: extra)]
        if let text { fields["text"] = .string(text) }
        return .object(fields)
    }

    private static func deliver(_ id: String, text: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "fetch": fetch(mode: "deliver")]
        if let text { fields["text"] = .string(text) }
        return .object(fields)
    }

    /// An `https_request` result, as the broker answers a send.
    static func response(_ body: String, status: Int = 200) -> JSONValue {
        .object(["status": .number(Double(status)),
                 "headers": .object(["content-type": .string("application/json")]),
                 "body": .string(body)])
    }
}

/// What the Host checks and does when it sends a section's request: the
/// Plugin's current authority, its Credential Uses, the section's budget,
/// and the answers it may give again.
final class HostFetchedRequestBrokerTests: XCTestCase {
    private var manifest: PluginManifest!
    private var package: PluginPackage!
    private var registry: PluginRegistry!
    private var grants: PluginCapabilityGrantStore!
    private var credentials: InMemoryPluginCredentialStore!
    private var transport: RoutedHTTPSTransport!
    private var clock: TimeInterval = 0
    private lazy var cache = FetchedResponseCache(lifetime: 60, limit: 2, now: { [unowned self] in clock })

    override func setUpWithError() throws {
        manifest = try NetworkPluginFixture.manifest(hosts: ["api.example.com"])
        package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/network"), manifest: manifest)
        grants = PluginCapabilityGrantStore()
        for capability in manifest.capabilities {
            grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                               capability: capability, scope: manifest.scope(for: capability))
        }
        registry = PluginRegistry()
        try registry.register(package)
        credentials = InMemoryPluginCredentialStore()
        try credentials.setSecret("s3cret", for: manifest.id, reference: "key")
        transport = RoutedHTTPSTransport(["api.example.com": RoutedHTTPSTransport.json(#"{"text":"Guten Morgen"}"#)])
    }

    private var broker: CapabilityCheckedHostServiceBroker {
        CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            httpsTransport: transport, credentialStore: credentials, responseCache: cache
        )
    }

    private func action(_ commandID: String = "fetch") throws -> ActionConfiguration {
        let command = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == commandID })
        return try ActionConfiguration(id: ActionID(commandID), pluginID: manifest.id, command: command, input: .null)
    }

    private func send(_ fetch: JSONValue = HostFetchedSectionsTests.fetch(mode: "show", pointer: "/text"),
                      from commandID: String = "fetch",
                      cancellation: HostFetchedSections.Cancellation = .init()) throws -> JSONValue {
        try broker.sendHostFetchedRequest(HostFetchedRequest(parsing: fetch), for: action(commandID),
                                          using: registry, cancellation: cancellation)
    }

    /// Credential Uses are applied as the request leaves; the answer the
    /// Plugin could see holds no secret. The section's own budget bounds it.
    func testTheRequestLeavesWithItsCredentialUsesWithinTheSectionBudget() throws {
        let response = try send()

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.headers["Authorization"], "Key s3cret")
        XCTAssertEqual(request.body, Data(#"{"text":"Good morning"}"#.utf8))
        XCTAssertGreaterThan(request.timeout, HTTPSRequestBudgets.timeout)
        XCTAssertLessThanOrEqual(request.timeout, ScriptedActionBudgets.hostFetchedSectionDeadline)
        XCTAssertEqual(response, .object(["status": .number(200),
                                          "headers": .object(["content-type": .string("application/json")]),
                                          "body": .string(#"{"text":"Guten Morgen"}"#)]))
        XCTAssertFalse("\(response)".contains("s3cret"))
    }

    /// Acceptance: every send reads the grant afresh, so revoking
    /// `contact_https` stops sends, cached answers included.
    func testRevokingContactHTTPSStopsSendsAndCachedAnswers() throws {
        let cacheable = HostFetchedSectionsTests.fetch(mode: "show", pointer: "/text", extra: ["cache": .bool(true)])
        _ = try send(cacheable)
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version,
                           capability: .contactHTTPS, scope: manifest.scope(for: .contactHTTPS))

        for fetch in [cacheable, HostFetchedSectionsTests.fetch(mode: "deliver")] {
            XCTAssertThrowsError(try send(fetch)) {
                XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.contactHTTPS))
            }
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// Acceptance: the consented hosts are read on every send too.
    func testRemovingAConsentedHostStopsSendsToIt() throws {
        let scope = try XCTUnwrap(manifest.scope(for: .contactHTTPS))
        grants.setConsentedHTTPSHosts(["self.example.com"], for: manifest.id, pluginVersion: manifest.version,
                                      declaredScope: scope)
        transport.answer("self.example.com", with: RoutedHTTPSTransport.json(#"{"text":"mine"}"#))
        let own = HostFetchedSectionsTests.fetch(mode: "show", pointer: "/text", host: "self.example.com")
        _ = try send(own)

        grants.setConsentedHTTPSHosts([], for: manifest.id, pluginVersion: manifest.version, declaredScope: scope)

        XCTAssertThrowsError(try send(own)) {
            XCTAssertEqual($0 as? PluginHostServiceError,
                           .failed("\(manifest.name) may not contact self.example.com until it is allowed in its Plugin Settings"),
                           "The section names the host, since the grant itself still stands")
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// A kept answer is no way around the consent: once its host is removed,
    /// the same cacheable request is refused rather than answered from the
    /// cache, even though nothing cleared it.
    func testRemovingAConsentedHostStopsCachedAnswersFromIt() throws {
        let scope = try XCTUnwrap(manifest.scope(for: .contactHTTPS))
        grants.setConsentedHTTPSHosts(["self.example.com"], for: manifest.id, pluginVersion: manifest.version,
                                      declaredScope: scope)
        transport.answer("self.example.com", with: RoutedHTTPSTransport.json(#"{"text":"mine"}"#))
        let own = HostFetchedSectionsTests.fetch(mode: "show", pointer: "/text", host: "self.example.com",
                                                 extra: ["cache": .bool(true)])
        _ = try send(own)
        _ = try send(own)
        XCTAssertEqual(transport.requests.count, 1, "The second answer came from the cache")

        grants.setConsentedHTTPSHosts([], for: manifest.id, pluginVersion: manifest.version, declaredScope: scope)

        XCTAssertThrowsError(try send(own)) {
            XCTAssertEqual($0 as? PluginHostServiceError,
                           .failed("\(manifest.name) may not contact self.example.com until it is allowed in its Plugin Settings"),
                           "The section names the host, since the grant itself still stands")
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// The request is authorised as the Command that presented the view
    /// would be: another Command, or a Plugin no longer active, sends nothing.
    func testOnlyAnActivePluginsCommandThatDeclaresTheCapabilitySends() throws {
        XCTAssertThrowsError(try send(from: "copy")) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.contactHTTPS))
        }
        try registry.setEnabled(false, for: manifest.id)
        XCTAssertThrowsError(try send())
        try registry.setEnabled(true, for: manifest.id)
        registry.unregister(manifest.id)
        XCTAssertThrowsError(try send())
        XCTAssertEqual(transport.requests.count, 0)
    }

    /// Acceptance: a section marked `cache` is answered again from the
    /// shared cache (kept for its lifetime, successes only).
    func testACacheableSectionIsAnsweredFromTheCacheUntilItExpires() throws {
        let cacheable = HostFetchedSectionsTests.fetch(mode: "show", pointer: "/text", extra: ["cache": .bool(true)])
        let first = try send(cacheable)
        XCTAssertEqual(try send(cacheable), first)
        XCTAssertEqual(transport.requests.count, 1)

        // Without `cache` the request is always sent.
        _ = try send()
        _ = try send()
        XCTAssertEqual(transport.requests.count, 3)

        clock += 61
        _ = try send(cacheable)
        XCTAssertEqual(transport.requests.count, 4, "An expired answer is asked again")

        cache.clear()
        _ = try send(cacheable)
        XCTAssertEqual(transport.requests.count, 5, "A grant change clears the cache")

        transport.answer("api.example.com", with: RoutedHTTPSTransport.json(#"{"message":"busy"}"#, status: 503))
        cache.clear()
        _ = try send(cacheable)
        _ = try send(cacheable)
        XCTAssertEqual(transport.requests.count, 7, "A failed answer is not kept")
    }

    /// One Plugin never reads another's answers, and a credential is keyed by
    /// its reference, never its secret.
    func testAnswersAreKeptPerPluginAndPerRequest() throws {
        let request: JSONValue = .object(["method": .string("GET"), "url": .string("https://api.example.com/t")])
        let mine = try XCTUnwrap(FetchedResponseCache.key(pluginID: PluginID("com.example.a"), request: request))
        let theirs = try XCTUnwrap(FetchedResponseCache.key(pluginID: PluginID("com.example.b"), request: request))
        XCTAssertNotEqual(mine, theirs)
        let other: JSONValue = .object(["method": .string("GET"), "url": .string("https://api.example.com/u")])
        XCTAssertNotEqual(mine, FetchedResponseCache.key(pluginID: PluginID("com.example.a"), request: other))
        XCTAssertFalse(mine.contains("secret"))
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

    /// A cancelled send stops before its next hop: a redirect is not followed.
    func testACancelledSendFollowsNoRedirect() throws {
        let cancellation = HostFetchedSections.Cancellation()
        final class RedirectingTransport: HTTPSTransport {
            var requests: [HTTPSTransportRequest] = []
            let onSend: () -> Void
            init(onSend: @escaping () -> Void) { self.onSend = onSend }
            func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
                requests.append(request)
                onSend()
                return HTTPSTransportResponse(status: 302, headers: ["location": "https://api.example.com/next"],
                                              body: Data())
            }
        }
        let redirecting = RedirectingTransport { cancellation.cancel() }
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            httpsTransport: redirecting, credentialStore: credentials
        )
        XCTAssertThrowsError(try broker.sendHostFetchedRequest(
            HostFetchedRequest(parsing: HostFetchedSectionsTests.fetch(mode: "deliver")),
            for: action(), using: registry, cancellation: cancellation))
        XCTAssertEqual(redirecting.requests.count, 1)
    }
}

/// `PluginAPI/schemas/host-fetched-section.schema.json` publishes the shape
/// of a Detail section's `fetch`. The Host must accept exactly what the
/// schema accepts.
final class HostFetchedSectionSchemaTests: XCTestCase {
    private static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI/schemas/host-fetched-section.schema.json")

    private func validator(for definition: String) throws -> JSONSchemaSubsetValidator {
        try JSONSchemaSubsetValidator(definition: definition, inSchemaAt: Self.schemaURL)
    }

    /// Reading a fetch checks its request's members; the rest of the
    /// `https_request` rules, which the schema also publishes, are checked
    /// as the request is sent and fail only that section. So the requests
    /// below break the rules reading applies, if any.
    func testTheHostAcceptsExactlyTheFetchesTheSchemaAccepts() throws {
        let request = HostFetchedSectionsTests.request()
        func fetch(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }
        let longPointer = "/" + String(repeating: "a", count: HostFetchedSectionBudgets.maximumPointerLength - 1)
        let candidates: [JSONValue] = [
            fetch(["request": request, "mode": .string("show"), "pointer": .string("/text")]),
            fetch(["request": request, "mode": .string("show"), "pointer": .string(longPointer),
                   "error_pointer": .string("/error/message"), "status_messages": .object(["401": .string("No")]),
                   "cache": .bool(true)]),
            fetch(["request": request, "mode": .string("deliver")]),
            fetch(["request": request, "mode": .string("deliver"), "cache": .bool(false)]),
            fetch(["request": .object(["method": .string("GET"), "url": .string("https://api.example.com/")]),
                   "mode": .string("deliver")]),
            // Refused:
            fetch(["request": request, "mode": .string("show")]),
            fetch(["request": request, "mode": .string("show"), "pointer": .string("text")]),
            fetch(["request": request, "mode": .string("show"), "pointer": .string(longPointer + "a")]),
            fetch(["request": request, "mode": .string("deliver"), "pointer": .string("/text")]),
            fetch(["request": request, "mode": .string("deliver"), "error_pointer": .string("/e")]),
            fetch(["request": request, "mode": .string("deliver"), "status_messages": .object([:])]),
            fetch(["request": request, "mode": .string("show"), "pointer": .string("/t"),
                   "status_messages": .object(["abc": .string("No")])]),
            fetch(["request": request, "mode": .string("show"), "pointer": .string("/t"),
                   "status_messages": .object(["401": .string("")])]),
            fetch(["request": request, "mode": .string("peek"), "pointer": .string("/t")]),
            fetch(["request": request]),
            fetch(["mode": .string("deliver")]),
            fetch(["request": request, "mode": .string("deliver"), "cache": .string("yes")]),
            fetch(["request": request, "mode": .string("deliver"), "extra": .null]),
            fetch(["request": .object(["method": .string("PUT"), "url": .string("https://api.example.com/")]),
                   "mode": .string("deliver")]),
            fetch(["request": .object(["method": .string("GET")]), "mode": .string("deliver")]),
            fetch(["request": .object(["method": .string("GET"), "url": .string("https://a.example/"),
                                       "json_body": .object([:])]), "mode": .string("deliver")]),
            fetch(["request": .string("https://api.example.com/"), "mode": .string("deliver")]),
            .string("show"), .null
        ]
        let schema = try validator(for: "fetch")
        for candidate in candidates {
            let schemaAccepts = schema.errors(for: candidate).isEmpty
            var hostAccepts = true
            do { _ = try HostFetchedRequest(parsing: candidate) } catch { hostAccepts = false }
            XCTAssertEqual(hostAccepts, schemaAccepts, "\(candidate)")
        }
    }

    func testTheDeliveredEventMatchesTheSchema() throws {
        let event = PluginViewEvent.sectionDelivered(section: "rate",
                                                     response: HostFetchedSectionsTests.response(#"{"rate":1}"#))
        XCTAssertEqual(try validator(for: "section_delivered").errors(for: event.json), [])
    }
}

/// Reads the Detail sections of a test view, `{sections: [...]}`, and
/// presents them to the engine each time a view is shown, as the Host's
/// renderer does.
final class SectionPresentingRenderer: PluginViewRenderer {
    weak var engine: HostFetchedSections?
    private(set) var closes: [PluginViewSessionEnd] = []

    func present(_ presentation: PluginViewPresentation, of session: PluginViewSession) {
        guard case .object(let view) = presentation.view, case .array(let sections)? = view["sections"] else { return }
        engine?.present(sections.compactMap(HostFetchedSection.init(detailSection:)), for: session.pluginID)
    }

    func showToast(_ toast: String, in session: PluginViewSession) {}

    func close(_ session: PluginViewSession, because reason: PluginViewSessionEnd) { closes.append(reason) }
}

/// Background work the test runs when it chooses.
final class HeldWork {
    private var items: [() -> Void] = []

    var pending: Int { items.count }

    func enqueue(_ work: @escaping () -> Void) { items.append(work) }

    func run(at index: Int) {
        items.remove(at: index)()
    }

    func runAll() {
        while !items.isEmpty { items.removeFirst()() }
    }
}
