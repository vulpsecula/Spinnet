import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// A script's answer, read as the Host reads it (ADR 0010).
final class PluginScriptAnswerTests: XCTestCase {
    func testTheThreeAnswersAndAToastOnAnyOfThem() throws {
        XCTAssertEqual(try PluginScriptAnswer(parsing: .null), PluginScriptAnswer())
        XCTAssertEqual(try PluginScriptAnswer(parsing: .object([:])), PluginScriptAnswer())
        XCTAssertEqual(try PluginScriptAnswer(parsing: .object(["view": .object(["type": .string("form")]),
                                                                "state": .number(1)])),
                       PluginScriptAnswer(view: .object(["type": .string("form")]), state: .number(1)))
        XCTAssertEqual(try PluginScriptAnswer(parsing: .object(["view": .object([:])])),
                       PluginScriptAnswer(view: .object([:]), state: .null))
        XCTAssertEqual(try PluginScriptAnswer(parsing: .object(["close": .bool(true)])), PluginScriptAnswer(close: true))
        XCTAssertEqual(try PluginScriptAnswer(parsing: .object(["toast": .string("Copied")])),
                       PluginScriptAnswer(toast: "Copied"))
        XCTAssertEqual(try PluginScriptAnswer(parsing: .object(["close": .bool(true), "toast": .string("Done")])),
                       PluginScriptAnswer(close: true, toast: "Done"))
    }

    func testAnythingElseIsAProtocolViolation() {
        let violations: [JSONValue] = [
            .string("done"), .bool(true), .number(1), .array([]),
            .object(["veiw": .object([:])]),
            .object(["close": .bool(false)]),
            .object(["close": .bool(true), "view": .object([:])]),
            .object(["state": .number(1)]),
            .object(["view": .string("form")]),
            .object(["toast": .number(1)]),
            .object(["toast": .string("  ")])
        ]
        for value in violations {
            XCTAssertThrowsError(try PluginScriptAnswer(parsing: value), "\(value)") {
                XCTAssertEqual(($0 as? PluginRuntimeError)?.failureCategory, .runtimeProtocolFailed)
            }
        }
    }

    /// ADR 0010: "64 KiB of state, 256 KiB of view description", counted as
    /// the UTF-8 JSON the Host keeps.
    func testStateAndViewAreBoundedByTheirBudgets() throws {
        let stateFits = Self.string(encodedAs: ScriptedActionBudgets.viewStateBytes)
        let stateTooLarge = Self.string(encodedAs: ScriptedActionBudgets.viewStateBytes + 1)
        XCTAssertNoThrow(try PluginScriptAnswer(parsing: .object(["view": .object([:]), "state": stateFits])))
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: .object(["view": .object([:]), "state": stateTooLarge])))

        // `{"t":` and `}` add six bytes around the string.
        let viewFits = JSONValue.object(["t": Self.string(encodedAs: ScriptedActionBudgets.viewDescriptionBytes - 6)])
        let viewTooLarge = JSONValue.object(["t": Self.string(encodedAs: ScriptedActionBudgets.viewDescriptionBytes - 5)])
        XCTAssertEqual(PluginScriptAnswer.encodedSize(of: viewFits), ScriptedActionBudgets.viewDescriptionBytes)
        XCTAssertNoThrow(try PluginScriptAnswer(parsing: .object(["view": viewFits])))
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: .object(["view": viewTooLarge])))
    }

    /// A JSON string whose encoding, quotes included, is `bytes` long.
    private static func string(encodedAs bytes: Int) -> JSONValue {
        .string(String(repeating: "a", count: bytes - 2))
    }
}

/// The View Session runtime of ADR 0010, driven through its seams: a test
/// renderer, an event runner the test answers by hand, and a clock the test
/// advances.
final class PluginViewSessionTests: XCTestCase {
    private var clock: ManualClock!
    private var renderer: RecordingRenderer!
    private var runner: HeldEventRunner!
    private var feedback: [String] = []
    private var sessions: PluginViewSessions!

    override func setUp() {
        clock = ManualClock()
        renderer = RecordingRenderer()
        runner = HeldEventRunner()
        feedback = []
        sessions = PluginViewSessions(renderer: renderer, runEvent: runner.run, schedule: clock.schedule,
                                      showFeedback: { [unowned self] in self.feedback.append($0) })
    }

    // MARK: - Starting

    func testAViewAnswerStartsASessionThatShowsTheViewAndKeepsTheState() throws {
        let action = try Self.action()
        XCTAssertTrue(try sessions.actionAnswered(action, with: Self.answer(view: "first", state: .number(1),
                                                                             toast: "Ready")))

        let session = try XCTUnwrap(sessions.session(for: action.pluginID))
        XCTAssertEqual(session.state, .number(1))
        XCTAssertEqual(renderer.presentations, [PluginViewPresentation(view: Self.view("first"), isBusy: false, error: nil)])
        XCTAssertEqual(renderer.toasts, ["Ready"], "A toast with a view shows in the view")
        XCTAssertEqual(feedback, [])
    }

    /// Acceptance: a view-less answer with a toast shows the Host feedback
    /// and opens no view.
    func testAViewlessToastIsHostFeedbackAndStartsNoSession() throws {
        let action = try Self.action()
        XCTAssertTrue(try sessions.actionAnswered(action, with: .object(["toast": .string("Copied")])))

        XCTAssertEqual(feedback, ["Copied"])
        XCTAssertNil(sessions.session(for: action.pluginID))
        XCTAssertEqual(renderer.presentations, [])
        XCTAssertEqual(renderer.toasts, [])
    }

    func testANullAnswerShowsNothing() throws {
        let action = try Self.action()
        XCTAssertFalse(try sessions.actionAnswered(action, with: .null))
        XCTAssertNil(sessions.session(for: action.pluginID))
        XCTAssertEqual(renderer.presentations, [])
        XCTAssertEqual(feedback, [])
    }

    func testAnActionAnswerThatIsNoAnswerIsAProtocolViolationAndStartsNoSession() throws {
        let action = try Self.action()
        XCTAssertThrowsError(try sessions.actionAnswered(action, with: .string("done"))) {
            XCTAssertEqual(($0 as? PluginRuntimeError)?.failureCategory, .runtimeProtocolFailed)
        }
        XCTAssertNil(sessions.session(for: action.pluginID))
    }

    /// Each Plugin has at most one View Session: presenting again replaces
    /// the view in place, and events meant for the old view are dropped.
    func testPresentingAgainReplacesTheViewInPlaceAndDropsTheOldViewsEvents() throws {
        let action = try Self.action()
        let session = try start(action, state: .number(1))
        session.send(.submitted(values: .null))
        session.send(.actionChosen("queued"))
        let inFlight = try XCTUnwrap(runner.runs.first)

        XCTAssertTrue(try sessions.actionAnswered(action, with: Self.answer(view: "again", state: .number(9))))

        XCTAssertTrue(sessions.session(for: action.pluginID) === session)
        XCTAssertEqual(session.state, .number(9))
        XCTAssertEqual(renderer.presentations.last, PluginViewPresentation(view: Self.view("again"), isBusy: false, error: nil))
        XCTAssertEqual(inFlight.stopReason, .cancelled)
        inFlight.finish(Self.succeeded(Self.answer(view: "stale", state: .number(2))))
        XCTAssertEqual(session.state, .number(9), "The answer for the old view's generation is dropped")
        XCTAssertEqual(runner.runs.count, 1, "The old view's queued action is dropped")
    }

    // MARK: - Events

    func testAnEventRunsTheCommandAgainWithTheEventAndTheKeptState() throws {
        let action = try Self.action()
        let session = try start(action, state: .object(["count": .number(1)]))

        session.send(.actionChosen("increment"))

        let run = try XCTUnwrap(runner.runs.first)
        XCTAssertEqual(run.delivery, ViewEventDelivery(event: .actionChosen("increment"),
                                                       state: .object(["count": .number(1)])))
        XCTAssertEqual(run.action.commandID, action.commandID)
        XCTAssertNotEqual(run.action.id, action.id, "Each event is a new invocation")
        run.finish(Self.succeeded(Self.answer(view: "two", state: .object(["count": .number(2)]))))

        XCTAssertEqual(session.state, .object(["count": .number(2)]))
        XCTAssertEqual(renderer.presentations.last, PluginViewPresentation(view: Self.view("two"), isBusy: false, error: nil))
        session.send(.actionChosen("increment"))
        XCTAssertEqual(runner.runs.last?.delivery.state, .object(["count": .number(2)]))
    }

    /// A `null` answer to an event changes nothing; its toast shows in the view.
    func testANullAnswerToAnEventKeepsTheViewAndState() throws {
        let session = try start(try Self.action(), state: .number(1))
        session.send(.submitted(values: .null))
        runner.runs[0].finish(Self.succeeded(.object(["toast": .string("Saved")])))

        XCTAssertEqual(session.state, .number(1))
        XCTAssertEqual(renderer.presentations.last, PluginViewPresentation(view: Self.view("first"), isBusy: false, error: nil))
        XCTAssertEqual(renderer.toasts, ["Saved"])
        XCTAssertEqual(feedback, [])
    }

    func testEveryKindOfEventReachesTheScriptAsJSON() {
        XCTAssertEqual(PluginViewEvent.fieldChanged(field: "q", values: .object(["q": .string("a")])).json,
                       .object(["type": .string("field_changed"), "field": .string("q"),
                                "values": .object(["q": .string("a")])]))
        XCTAssertEqual(PluginViewEvent.submitted(values: .object([:])).json,
                       .object(["type": .string("submitted"), "values": .object([:])]))
        XCTAssertEqual(PluginViewEvent.actionChosen("copy").json,
                       .object(["type": .string("action_chosen"), "action": .string("copy")]))
        XCTAssertEqual(PluginViewEvent.settingChanged(key: "target", value: .string("de")).json,
                       .object(["type": .string("setting_changed"), "key": .string("target"), "value": .string("de")]))
        XCTAssertEqual(PluginViewEvent.sectionDelivered(section: "deepl", response: .object(["status": .number(200)])).json,
                       .object(["type": .string("section_delivered"), "section": .string("deepl"),
                                "response": .object(["status": .number(200)])]))
    }

    /// Field changes wait for a 100 ms pause, and a change during the pause
    /// starts it again.
    func testFieldChangesAreDebouncedBy100Milliseconds() throws {
        let session = try start(try Self.action())

        session.send(Self.change("h"))
        clock.advance(by: 0.05)
        session.send(Self.change("he"))
        clock.advance(by: 0.099)
        XCTAssertEqual(runner.runs.count, 0)
        clock.advance(by: 0.001)
        XCTAssertEqual(runner.runs.map(\.delivery.event), [Self.change("he")])
    }

    func testOneEventIsInFlightAtATime() throws {
        let session = try start(try Self.action())

        session.send(.submitted(values: .null))
        session.send(.actionChosen("next"))
        XCTAssertEqual(runner.runs.count, 1)

        runner.runs[0].finish(Self.succeeded(.null))
        XCTAssertEqual(runner.runs.map(\.delivery.event), [.submitted(values: .null), .actionChosen("next")])
    }

    /// Field changes that wait behind an event in flight coalesce to the
    /// latest; submissions, actions, settings and sections queue in order.
    func testFieldChangesCoalesceWhileOtherEventsQueueInOrder() throws {
        let session = try start(try Self.action())
        session.send(.submitted(values: .null))

        session.send(Self.change("a"))
        clock.advance(by: 0.1)
        session.send(Self.change("ab"))
        clock.advance(by: 0.1)
        session.send(.actionChosen("copy"))
        session.send(.settingChanged(key: "target", value: .string("de")))
        session.send(.sectionDelivered(section: "s", response: .null))
        session.send(.submitted(values: .string("again")))

        for index in 0..<5 {
            runner.runs[index].finish(Self.succeeded(.null))
        }
        XCTAssertEqual(runner.runs.map(\.delivery.event), [
            .submitted(values: .null), Self.change("ab"), .actionChosen("copy"),
            .settingChanged(key: "target", value: .string("de")), .sectionDelivered(section: "s", response: .null),
            .submitted(values: .string("again"))
        ])
    }

    /// A submission right after typing delivers the typing first, without
    /// waiting out the pause, so events keep the order the user made them in.
    func testASubmissionDeliversAPendingFieldChangeFirst() throws {
        let session = try start(try Self.action())

        session.send(Self.change("hello"))
        session.send(.submitted(values: .null))
        XCTAssertEqual(runner.runs.map(\.delivery.event), [Self.change("hello")])
        runner.runs[0].finish(Self.succeeded(.null))
        clock.advance(by: 1)
        XCTAssertEqual(runner.runs.map(\.delivery.event), [Self.change("hello"), .submitted(values: .null)])
    }

    /// Events do not show the Action progress indicator: the view shows its
    /// own busy state at once, and the Host shows nothing, however long the
    /// event runs.
    func testAnEventShowsTheViewsBusyStateAndNoActionProgress() throws {
        let session = try start(try Self.action())

        session.send(.submitted(values: .null))
        XCTAssertEqual(renderer.presentations.last, PluginViewPresentation(view: Self.view("first"), isBusy: true, error: nil))
        clock.advance(by: ScriptedActionBudgets.progressDelay + 0.1)
        XCTAssertEqual(renderer.presentations.count, 2, "Nothing else is shown while the event runs")
        XCTAssertEqual(feedback, [])

        runner.runs[0].finish(Self.succeeded(.null))
        XCTAssertEqual(renderer.presentations.last?.isBusy, false)
    }

    // MARK: - Failures

    /// A refused Capability keeps the view with an inline error, and the
    /// next event starts from the last good state.
    func testARefusalKeepsTheViewWithAnInlineErrorAndTheLastGoodState() throws {
        let session = try start(try Self.action(), state: .number(1))
        session.send(.submitted(values: .null))
        runner.runs[0].finish(Self.succeeded(Self.answer(view: "second", state: .number(2))))

        session.send(.actionChosen("copy"))
        runner.runs[1].finish(Self.failed(.capabilityDenied))

        XCTAssertFalse(session.isEnded)
        XCTAssertEqual(renderer.presentations.last?.view, Self.view("second"))
        XCTAssertEqual(renderer.presentations.last?.error?.category, .capabilityDenied)
        XCTAssertEqual(session.state, .number(2))
        session.send(.submitted(values: .null))
        XCTAssertEqual(runner.runs[2].delivery.state, .number(2))
        runner.runs[2].finish(Self.succeeded(.null))
        XCTAssertNil(renderer.presentations.last?.error, "An event that succeeds clears the inline error")
    }

    /// A helper crash keeps the view and its state; the next event goes to
    /// the runner again, which starts a fresh helper.
    func testAHelperCrashKeepsTheViewAndState() throws {
        let session = try start(try Self.action(), state: .number(1))
        session.send(.submitted(values: .null))
        runner.runs[0].finish(Self.failed(.helperCrashed))

        XCTAssertFalse(session.isEnded)
        XCTAssertEqual(renderer.presentations.last,
                       PluginViewPresentation(view: Self.view("first"), isBusy: false,
                                              error: Self.failure(.helperCrashed)))
        session.send(.submitted(values: .null))
        XCTAssertEqual(runner.runs.count, 2)
        XCTAssertEqual(runner.runs[1].delivery.state, .number(1))
    }

    /// An event that outlives its four seconds is stopped; the view and
    /// state stay, the next event runs, and the late answer is dropped.
    func testATimedOutEventKeepsTheViewAndStateAndItsLateAnswerIsDropped() throws {
        let session = try start(try Self.action(), state: .number(1))
        session.send(.submitted(values: .null))
        session.send(.actionChosen("next"))

        clock.advance(by: ScriptedActionBudgets.viewEventDeadline - 0.001)
        XCTAssertNil(runner.runs[0].stopReason)
        clock.advance(by: 0.001)

        XCTAssertEqual(runner.runs[0].stopReason, .timedOut)
        XCTAssertFalse(session.isEnded)
        XCTAssertEqual(renderer.presentations.last?.view, Self.view("first"))
        XCTAssertEqual(renderer.presentations.last?.error?.category, .timedOut)
        XCTAssertEqual(runner.runs.map(\.delivery.event), [.submitted(values: .null), .actionChosen("next")])

        runner.runs[0].finish(Self.succeeded(Self.answer(view: "late", state: .number(5))))
        XCTAssertEqual(session.state, .number(1))
        XCTAssertNotEqual(renderer.presentations.last?.view, Self.view("late"))
    }

    func testAProtocolViolationEndsTheSession() throws {
        let session = try start(try Self.action())
        session.send(.submitted(values: .null))
        runner.runs[0].finish(Self.failed(.runtimeProtocolFailed))

        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(renderer.closes, [.failed(Self.failure(.runtimeProtocolFailed))])
        XCTAssertNil(sessions.session(for: session.pluginID))
    }

    /// An answer that is no answer, or state over its budget, is the
    /// script's protocol violation too.
    func testAMalformedOrOversizedAnswerEndsTheSession() throws {
        let oversized = JSONValue.string(String(repeating: "s", count: ScriptedActionBudgets.viewStateBytes))
        for answer in [JSONValue.string("done"), .object(["view": .object([:]), "state": oversized])] {
            setUp()
            let session = try start(try Self.action())
            session.send(.submitted(values: .null))
            runner.runs[0].finish(Self.succeeded(answer))

            XCTAssertTrue(session.isEnded, "\(answer)")
            guard case .failed(let failure) = renderer.closes.first else { return XCTFail("\(renderer.closes)") }
            XCTAssertEqual(failure.category, .runtimeProtocolFailed)
        }
    }

    // MARK: - Ending

    func testAPluginMayCloseItsViewWithAToastForTheHostToShow() throws {
        let session = try start(try Self.action())
        session.send(.actionChosen("done"))
        runner.runs[0].finish(Self.succeeded(.object(["close": .bool(true), "toast": .string("Inserted")])))

        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(renderer.closes, [.closedByPlugin])
        XCTAssertEqual(feedback, ["Inserted"])
        XCTAssertEqual(renderer.toasts, [])
    }

    /// An Action that answers `{close: true}` closes its Plugin's view.
    func testAnActionAnswerMayCloseItsPluginsView() throws {
        let action = try Self.action()
        let session = try start(action)
        XCTAssertTrue(try sessions.actionAnswered(action, with: .object(["close": .bool(true)])))
        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(renderer.closes, [.closedByPlugin])
    }

    /// Closing the view cancels the event in flight and any waiting, and an
    /// answer that arrives afterwards has no effect at all.
    func testClosingEndsTheSessionAndDiscardsLateAnswersWithoutSideEffects() throws {
        let session = try start(try Self.action(), state: .number(1))
        session.send(.submitted(values: .null))
        session.send(Self.change("typed"))

        session.close()

        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(renderer.closes, [.viewClosed])
        XCTAssertEqual(runner.runs[0].stopReason, .cancelled)
        let shown = renderer.presentations
        runner.runs[0].finish(Self.succeeded(.object(["close": .bool(true), "toast": .string("Late")])))
        clock.advance(by: 10)
        session.send(.submitted(values: .null))
        XCTAssertEqual(runner.runs.count, 1, "Nothing more runs")
        XCTAssertEqual(renderer.presentations, shown)
        XCTAssertEqual(renderer.toasts, [])
        XCTAssertEqual(renderer.closes, [.viewClosed])
        XCTAssertEqual(feedback, [])
        XCTAssertNil(sessions.session(for: session.pluginID))
    }

    /// Updating, disabling or removing the Plugin ends its session at once.
    func testUpdatingDisablingOrRemovingThePluginEndsItsSession() throws {
        let changes: [(PluginRegistry, PluginPackage) throws -> Void] = [
            { registry, package in try registry.replace(package) },
            { registry, package in try registry.setEnabled(false, for: package.manifest.id) },
            { registry, package in registry.unregister(package.manifest.id) }
        ]
        for change in changes {
            setUp()
            let package = try ScriptedPackageFixture.load()
            let registry = PluginRegistry()
            try registry.register(package)
            sessions.observe(registry: registry, grantStore: PluginCapabilityGrantStore(), on: { $0() })
            let session = try start(try Self.action(pluginID: package.manifest.id))
            session.send(.submitted(values: .null))

            try change(registry, package)

            XCTAssertTrue(session.isEnded)
            XCTAssertEqual(renderer.closes, [.pluginChanged])
            XCTAssertEqual(runner.runs[0].stopReason, .cancelled)
            runner.runs[0].finish(Self.succeeded(.object(["toast": .string("Late")])))
            XCTAssertEqual(renderer.toasts, [])
            XCTAssertEqual(feedback, [])
        }
    }

    func testRevokingACapabilityEndsThePluginsSession() throws {
        let pluginID = PluginID("com.example.view")
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: pluginID, pluginVersion: "1.0.0", capability: .writeClipboard)
        sessions.observe(registry: PluginRegistry(), grantStore: grants, on: { $0() })
        let session = try start(try Self.action(pluginID: pluginID))
        let other = try start(try Self.action(pluginID: PluginID("com.example.other")))

        grants.setDecision(.denied, for: pluginID, pluginVersion: "1.0.0", capability: .writeClipboard)

        XCTAssertTrue(session.isEnded)
        XCTAssertFalse(other.isEnded, "Another Plugin's view stays")
        XCTAssertEqual(renderer.closes, [.capabilityRevoked])
    }

    // MARK: - Support

    @discardableResult
    private func start(_ action: ActionConfiguration, state: JSONValue = .null) throws -> PluginViewSession {
        try sessions.actionAnswered(action, with: Self.answer(view: "first", state: state))
        return try XCTUnwrap(sessions.session(for: action.pluginID))
    }

    private static func action(pluginID: PluginID = PluginID("com.example.view")) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("view-action"), pluginID: pluginID,
                                command: CommandDeclaration(id: CommandID("example.view"), title: "View",
                                                            execution: .javascript, script: "view.js"),
                                input: .null)
    }

    private static func view(_ title: String) -> JSONValue { .object(["title": .string(title)]) }

    private static func answer(view title: String, state: JSONValue, toast: String? = nil) -> JSONValue {
        var members: [String: JSONValue] = ["view": view(title), "state": state]
        if let toast { members["toast"] = .string(toast) }
        return .object(members)
    }

    private static func change(_ text: String) -> PluginViewEvent {
        .fieldChanged(field: "query", values: .object(["query": .string(text)]))
    }

    private static func succeeded(_ value: JSONValue) -> ActionTerminalOutcome { .succeeded(value) }

    private static func failure(_ category: ActionFailureCategory) -> ActionFailure {
        ActionFailure(pluginID: PluginID("com.example.view"), actionID: ActionID("event"),
                      category: category, message: category.rawValue)
    }

    private static func failed(_ category: ActionFailureCategory) -> ActionTerminalOutcome { .failed(failure(category)) }
}

/// View Sessions over the real helper, run through `HostActionRunner` and
/// its broker exactly as an Action is.
final class PluginViewSessionHelperTests: XCTestCase {
    private static let counter = """
        (() => {
          if (event === null) {
            return { view: { type: "detail", markdown: "Count 0" }, state: { count: 0 } };
          }
          if (event.type === "action_chosen" && event.action === "increment") {
            const count = state.count + 1;
            return {
              view: { type: "detail", markdown: "Count " + count },
              state: { count: count, language: spinnet.text.detectLanguage("Bonjour tout le monde") }
            };
          }
          return null;
        })()
        """

    /// Acceptance: a helper retired while a view is open is started again by
    /// the next event, with the state intact. The event's Host Service
    /// request reaches the same broker an Action's does.
    func testAHelperRetiredWhileAViewIsOpenIsStartedAgainByTheNextEventWithTheStateIntact() throws {
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let plugin = try writePlugin(script: Self.counter)
        let registry = PluginRegistry()
        try registry.register(plugin.package)
        let broker = RecordingBroker(answering: RecordedHostServices([.detectLanguage: .value(.string("fr"))]))
        let runner = HostActionRunner(executor: NoHostCommands(), scriptedExecutor: helper, hostServiceBroker: broker)
        let renderer = RecordingRenderer()
        let sessions = PluginViewSessions(renderer: renderer, runEvent: { action, delivery, control, finish in
            finish(runner.invoke(action, using: registry, control: control, delivering: delivery))
        }, schedule: ManualClock().schedule, showFeedback: { _ in })
        let action = try plugin.action(for: PluginTestInvocation("example.run"))

        guard case .succeeded(let answer) = runner.invoke(action, using: registry).terminal else {
            return XCTFail("The Action should answer with its view")
        }
        XCTAssertTrue(try sessions.actionAnswered(action, with: answer))
        let session = try XCTUnwrap(sessions.session(for: action.pluginID))
        XCTAssertEqual(session.state, .object(["count": .number(0)]))
        XCTAssertEqual(helper.launchCount, 1)

        helper.retireHelper(of: plugin)
        session.send(.actionChosen("increment"))

        XCTAssertEqual(helper.launchCount, 2, "The event started a fresh helper")
        XCTAssertEqual(session.state, .object(["count": .number(1), "language": .string("fr")]))
        XCTAssertEqual(renderer.presentations.last,
                       PluginViewPresentation(view: .object(["type": .string("detail"), "markdown": .string("Count 1")]),
                                              isBusy: false, error: nil))
        XCTAssertEqual(broker.services, [.detectLanguage])
        XCTAssertFalse(session.isEnded)
    }

    private func writePlugin(script: String) throws -> PluginUnderTest {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetViewSession-\(UUID().uuidString).spinnetplugin", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        {
          "protocol_version": "1.0", "id": "com.example.counter", "name": "Counter", "version": "1.0.0",
          "capabilities": [],
          "commands": [
            {"id": "example.run", "title": "Count", "execution": "javascript", "is_configurable": false, "script": "run.js"}
          ]
        }
        """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try script.write(to: root.appendingPathComponent("run.js"), atomically: true, encoding: .utf8)
        return try PluginUnderTest(packageAt: root)
    }
}

/// How a View Event reaches the helper.
final class ViewEventInvocationTests: XCTestCase {
    func testTheInvocationCarriesTheEventAndStateAndRequiresBoth() throws {
        let invocation = PluginRuntimeInvocation(
            pluginID: PluginID("com.example.view"), actionID: ActionID("event-1"), commandID: CommandID("example.view"),
            scriptPath: "view.js", scriptSource: "null", input: .null,
            environment: PluginRuntimeEnvironment(hostVersion: "0.0.0", preferredLanguage: "en"),
            event: PluginViewEvent.actionChosen("copy").json, state: .object(["count": .number(1)])
        )
        let data = try PluginRuntimeProtocol.encodeInvocation(invocation)
        XCTAssertEqual(try PluginRuntimeProtocol.decodeInvocation(data), invocation)

        for member in ["event", "state"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object.removeValue(forKey: member)
            XCTAssertThrowsError(try PluginRuntimeProtocol.decodeInvocation(JSONSerialization.data(withJSONObject: object)),
                                 "An invocation without \(member) is malformed")
        }
    }

    /// An executor written before View Sessions runs an Action's start and
    /// refuses an event rather than answer it without its event and state.
    func testAnExecutorThatKnowsNoViewSessionsRefusesAViewEvent() throws {
        let executor = StartOnlyExecutor()
        let package = try ScriptedPackageFixture.load()
        let action = try ActionConfiguration(id: ActionID("a"), pluginID: package.manifest.id,
            command: try XCTUnwrap(package.manifest.commands.first { $0.id == ScriptedPackageFixture.transformDataCommandID }),
            input: .null)

        XCTAssertEqual(try executor.execute(action, in: package, using: nil, control: ActionExecutionControl(),
                                            delivering: .actionStart), .string("started"))
        XCTAssertThrowsError(try executor.execute(action, in: package, using: nil, control: ActionExecutionControl(),
                                                  delivering: ViewEventDelivery(event: .submitted(values: .null),
                                                                                state: .null)))
    }
}

private struct StartOnlyExecutor: ScriptedActionExecutor {
    func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue { .string("started") }
}

private struct NoHostCommands: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}

/// Records which services were requested before passing each request on.
private final class RecordingBroker: PluginHostServiceBroker {
    private let answering: PluginHostServiceBroker
    private let lock = NSLock()
    private var requested: [PluginHostService] = []

    init(answering: PluginHostServiceBroker) { self.answering = answering }

    var services: [PluginHostService] { lock.withLock { requested } }

    func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue {
        lock.withLock { requested.append(request.service) }
        return try answering.execute(request: request, for: package, action: action)
    }
}

/// A clock the test advances by hand, running what falls due in order.
final class ManualClock {
    private(set) var now: TimeInterval = 0
    private var pending: [(at: TimeInterval, order: Int, operation: () -> Void)] = []
    private var order = 0

    func schedule(_ delay: TimeInterval, _ operation: @escaping () -> Void) {
        order += 1
        pending.append((now + delay, order, operation))
    }

    func advance(by interval: TimeInterval) {
        let end = now + interval
        while let next = pending.filter({ $0.at <= end + 1e-9 }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            pending.removeAll { $0.order == next.order }
            now = max(now, next.at)
            next.operation()
        }
        now = end
    }
}

/// Records what the session asked the view to show.
final class RecordingRenderer: PluginViewRenderer {
    private(set) var presentations: [PluginViewPresentation] = []
    private(set) var toasts: [String] = []
    private(set) var closes: [PluginViewSessionEnd] = []

    func present(_ presentation: PluginViewPresentation, of session: PluginViewSession) {
        presentations.append(presentation)
    }

    func showToast(_ toast: String, in session: PluginViewSession) { toasts.append(toast) }

    func close(_ session: PluginViewSession, because reason: PluginViewSessionEnd) { closes.append(reason) }
}

/// Holds each event's run until the test finishes it.
final class HeldEventRunner {
    final class Run {
        let action: ActionConfiguration
        let delivery: ViewEventDelivery
        let control: ActionExecutionControl
        private let completion: (ActionOutcome) -> Void

        init(action: ActionConfiguration, delivery: ViewEventDelivery, control: ActionExecutionControl,
             completion: @escaping (ActionOutcome) -> Void) {
            self.action = action
            self.delivery = delivery
            self.control = control
            self.completion = completion
        }

        /// Why the session stopped this run, if it did.
        var stopReason: PluginRuntimeError? {
            do { try control.check(); return nil } catch { return error as? PluginRuntimeError }
        }

        func finish(_ terminal: ActionTerminalOutcome) {
            completion(ActionOutcome(actionID: action.id, pluginID: action.pluginID, title: action.title,
                                     terminal: terminal))
        }
    }

    private(set) var runs: [Run] = []

    var run: PluginViewSession.RunEvent {
        { [unowned self] action, delivery, control, completion in
            runs.append(Run(action: action, delivery: delivery, control: control, completion: completion))
        }
    }
}
