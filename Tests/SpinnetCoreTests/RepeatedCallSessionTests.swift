import Foundation
import XCTest
@testable import SpinnetCore

/// Explicit calls into an open View Session (Candidate Contract
/// `collections` r2, #78), driven through the sessions' seams: a renderer
/// that records, runs the test answers by hand, a clock it advances, and a
/// performer that records what it authorizes.
///
/// Calling a Plugin whose session is open queues the complete Action as
/// `called`, brings the panel forward at once and runs the Action's own
/// Command and input from the session's last good state. Only an answer with
/// a view or page makes the calling Action the session's handler.
final class RepeatedCallSessionTests: XCTestCase {
    private typealias B = PageBuilder
    private var clock: ManualClock!
    private var renderer: RecordingRenderer!
    private var runner: HeldEventRunner!
    private var performer: HeldPerformer!
    private var reported: [(action: ActionConfiguration, message: String)] = []
    private var feedback: [String] = []
    private var sessions: PluginViewSessions!
    private static let pluginID = PluginID("com.example.emoji-pages")

    override func setUp() {
        makeSessions(permits: CollectionsFixtures.permits)
    }

    private func makeSessions(permits: @escaping (PluginInterfaceMember) -> Bool) {
        clock = ManualClock()
        renderer = RecordingRenderer()
        runner = HeldEventRunner()
        performer = HeldPerformer()
        reported = []
        feedback = []
        sessions = PluginViewSessions(renderer: renderer, runEvent: runner.run, schedule: clock.schedule,
                                      showFeedback: { [unowned self] in feedback.append($0) }, permitting: { _ in permits }, operations: performer,
                                      reportOperation: { [unowned self] action, message in
                                          reported.append((action, message))
                                      })
    }

    // MARK: - Queueing

    /// The called Action runs as `called` with its own Command and input,
    /// from the last good state, with no insertion target shown; the panel
    /// comes forward when the call is accepted, before it runs.
    func testACallRunsTheCalledActionFromTheLastGoodState() throws {
        let session = try start()
        let call = try Self.action(input: ["scope": "outdated"])

        XCTAssertTrue(sessions.call(call))

        XCTAssertEqual(renderer.broughtForward, 1, "Brought forward on acceptance")
        let run = try XCTUnwrap(runner.runs.first)
        XCTAssertEqual(run.delivery, ViewEventDelivery(event: .called, state: .number(0), insertionTarget: .notShown))
        XCTAssertEqual(run.action.commandID, call.commandID)
        XCTAssertEqual(run.action.input, call.input)
        XCTAssertNotEqual(run.action.id, call.id, "Each run is a new invocation")
        XCTAssertTrue(session.action.isSameConfiguration(as: try Self.action()), "Not the handler until it answers a view")

        answer(0, page: Self.searchPage(), state: .number(1))
        XCTAssertTrue(session.action.isSameConfiguration(as: call), "The calling Action handles the session now")
        XCTAssertEqual(session.state, .number(1))
        XCTAssertEqual(session.answeredEvent, .called)
        XCTAssertEqual(session.presentationCount, 1, "A call's answer updates the panel in place")
        XCTAssertEqual(renderer.broughtForward, 1)
        XCTAssertTrue(sessions.session(for: Self.pluginID) === session)
    }

    /// Calls queue behind whatever is running, in order, never merged; each
    /// starts from the state the one before it committed.
    func testSuccessiveCallsQueueInOrderWithoutMerging() throws {
        let session = try start()
        session.send(itemAction("A"))
        let first = try Self.action(input: ["scope": "installed"])
        let second = try Self.action(input: ["scope": "outdated"])
        XCTAssertTrue(sessions.call(first))
        XCTAssertTrue(sessions.call(second))
        XCTAssertEqual(renderer.broughtForward, 2)
        XCTAssertEqual(runner.runs.count, 1, "One run at a time")

        answer(0, page: Self.searchPage(), state: .number(1))
        XCTAssertEqual(runner.runs[1].delivery.event, .called)
        XCTAssertEqual(runner.runs[1].action.input, first.input)
        XCTAssertEqual(runner.runs[1].delivery.state, .number(1))
        answer(1, page: Self.searchPage(), state: .number(2))
        XCTAssertEqual(runner.runs[2].action.input, second.input)
        XCTAssertEqual(runner.runs[2].delivery.state, .number(2))
        answer(2, page: Self.searchPage(), state: .number(3))
        XCTAssertEqual(runner.runs.count, 3, "Two calls, two runs")
        XCTAssertTrue(session.action.isSameConfiguration(as: second))
    }

    /// The four-second deadline starts when the call's script does, not
    /// while it waits its turn.
    func testACallsDeadlineStartsWhenItsScriptDoes() throws {
        let session = try start()
        runner.startsAtOnce = false
        XCTAssertTrue(sessions.call(try Self.action(input: ["scope": "all"])))
        clock.advance(by: 10)
        XCTAssertNil(runner.runs[0].stopReason, "Waiting for its turn is not running")
        runner.runs[0].start()
        clock.advance(by: ScriptedActionBudgets.viewEventDeadline + 0.1)
        XCTAssertEqual(runner.runs[0].stopReason, .timedOut)
        XCTAssertEqual(session.error?.category, .timedOut)
        XCTAssertEqual(session.errorEvent, .called)
        XCTAssertTrue(session.action.isSameConfiguration(as: try Self.action()), "A timeout keeps the handler")
        XCTAssertEqual(session.state, .number(0))
    }

    // MARK: - Commit

    /// No view, a refusal, a crash or a timeout keep the previous handler,
    /// view and state; the next call still runs, from the same state.
    func testWithoutAValidViewTheHandlerViewAndStateStay() throws {
        let session = try start()
        let shown = session.view
        let other = try Self.action(command: "emoji.recent", input: ["scope": "all"])
        let endings: [ActionTerminalOutcome] = [
            .succeeded(.null),
            .succeeded(.object(["toast": .string("Nothing new")])),
            .failed(ActionFailure(pluginID: Self.pluginID, actionID: ActionID("c"), category: .commandUnavailable,
                                  message: "Plugin Settings are incomplete")),
            .failed(ActionFailure(pluginID: Self.pluginID, actionID: ActionID("c"), category: .helperCrashed,
                                  message: "The helper crashed"))
        ]
        for (index, ending) in endings.enumerated() {
            XCTAssertTrue(sessions.call(other))
            runner.runs[index].finish(ending)
            XCTAssertTrue(session.action.isSameConfiguration(as: try Self.action()), "\(ending)")
            XCTAssertEqual(session.view, shown)
            XCTAssertEqual(session.state, .number(0))
            XCTAssertFalse(session.isEnded)
        }
        XCTAssertEqual(renderer.toasts, ["Nothing new"])
        XCTAssertEqual(session.error?.category, .helperCrashed, "A failure shows inline")

        // The first call failed; the one after it continues from the last
        // good state and commits.
        XCTAssertTrue(sessions.call(other))
        XCTAssertEqual(runner.runs[4].delivery.state, .number(0))
        answer(4, page: Self.searchPage(), state: .number(5))
        XCTAssertTrue(session.action.isSameConfiguration(as: other))
        XCTAssertNil(session.error)
        session.send(itemAction("A"))
        XCTAssertEqual(runner.runs[5].action.commandID, other.commandID, "Later events run under the new handler")
    }

    /// An answer to a call that breaks the interface ends the session.
    func testAProtocolViolationInACallsAnswerEndsTheSession() throws {
        let session = try start()
        XCTAssertTrue(sessions.call(try Self.action()))
        runner.runs[0].finish(.succeeded(.object(["state": .number(1)])))
        XCTAssertTrue(session.isEnded)
        guard case .failed(let failure)? = renderer.closes.last else { return XCTFail("\(renderer.closes)") }
        XCTAssertEqual(failure.category, .runtimeProtocolFailed)
    }

    /// The answer is read under the Action that generated it: its operation
    /// is authorized for the calling Action, with no target shown. Page
    /// actions use the committed handler's authority, so Commands never
    /// combine theirs through the shared session.
    func testAnAnswerIsValidatedUnderItsCallAndPageActionsUnderTheHandler() throws {
        let session = try start()
        let other = try Self.action(command: "emoji.recent")
        let copy = RequestedHostOperation(perform: "clipboard.write", input: .object(["text": .string("★")]), id: "copy")

        XCTAssertTrue(sessions.call(other))
        answer(0, page: nil, operation: copy)
        XCTAssertEqual(performer.authorized.last?.action.commandID, other.commandID)
        XCTAssertEqual(performer.performed.last?.target, .notShown)
        performer.finish(0, .succeeded)
        session.perform(copy, insertionTarget: .notShown)
        XCTAssertEqual(performer.authorized.last?.action.commandID, try Self.action().commandID,
                       "Without a view the calling Action did not become the handler")
        performer.finish(1, .succeeded)

        XCTAssertTrue(sessions.call(other))
        answer(1, page: Self.searchPage())
        session.perform(copy, insertionTarget: .notShown)
        XCTAssertEqual(performer.authorized.last?.action.commandID, other.commandID)
    }

    // MARK: - Provenance

    /// Ordinary events keep their page provenance across a change of
    /// handler: typing made in the page still runs when the call's answer
    /// keeps the page, under the new handler, and is dropped when it changes
    /// page. Settings notifications and calls are never page-bound.
    func testOrdinaryEventsFollowTheirPageNotTheHandler() throws {
        let session = try start()
        let other = try Self.action(command: "emoji.recent")
        XCTAssertTrue(sessions.call(other))
        session.send(typed("cat"))
        clock.advance(by: 0.2)
        answer(0, page: Self.searchPage(), state: .number(1))
        XCTAssertEqual(runner.runs.count, 2, "The page stayed, so its typing runs")
        XCTAssertEqual(runner.runs[1].delivery.event, typed("cat"))
        XCTAssertEqual(runner.runs[1].action.commandID, other.commandID)
        answer(1, page: Self.searchPage(), state: .number(2))

        XCTAssertTrue(sessions.call(try Self.action()))
        session.send(typed("dog"))
        session.send(.settingChanged(key: "skin", value: .string("dark")))
        XCTAssertTrue(sessions.call(other))
        answer(2, page: B.pageJSON("detail", [B.buttons(["back"])]), state: .number(3))
        XCTAssertEqual(runner.runs.count, 4, "The typing belonged to the search page")
        XCTAssertEqual(runner.runs[3].delivery.event, .settingChanged(key: "skin", value: .string("dark")))
        answer(3, page: nil)
        XCTAssertEqual(runner.runs[4].delivery.event, .called, "A call runs after any page change")
        XCTAssertEqual(runner.runs[4].delivery.state, .number(3))
    }

    /// In a Level 1 view, which has no page provenance, a call's view counts
    /// as a page change: events made in the old view are dropped, as when
    /// Level 1 presents again, while calls and Settings notifications stay.
    func testACallsViewReplacesALevelOneViewsQueuedEvents() throws {
        let session = try start(view: Self.form("first"))
        XCTAssertTrue(sessions.call(try Self.action(command: "emoji.recent")))
        session.send(.submitted(values: .object([:])))
        session.send(.settingChanged(key: "skin", value: .string("dark")))
        runner.runs[0].finish(.succeeded(.object(["view": Self.form("second"), "state": .number(1)])))
        XCTAssertEqual(runner.runs.count, 2)
        XCTAssertEqual(runner.runs[1].delivery.event, .settingChanged(key: "skin", value: .string("dark")))
        runner.runs[1].finish(.succeeded(.null))

        session.send(.submitted(values: .object([:])))
        XCTAssertEqual(runner.runs.count, 3, "An event's own answer does not drop what follows, as in Level 1")
        session.send(.actionChosen("next"))
        runner.runs[2].finish(.succeeded(.object(["view": Self.form("third"), "state": .number(2)])))
        XCTAssertEqual(runner.runs[3].delivery.event, .actionChosen("next"))
    }

    // MARK: - Ending

    /// Closing the view cancels the call running and the calls waiting,
    /// says so for each, and replays none of them.
    func testClosingCancelsAndReportsPendingCallsWithoutReplay() throws {
        let session = try start()
        let first = try Self.action(input: ["scope": "installed"])
        let second = try Self.action(input: ["scope": "outdated"])
        XCTAssertTrue(sessions.call(first))
        XCTAssertTrue(sessions.call(second))

        session.close()

        XCTAssertEqual(runner.runs[0].stopReason, .cancelled)
        XCTAssertEqual(reported.map(\.message), ["Cancelled: the view was closed", "Cancelled: the view was closed"])
        XCTAssertEqual(reported.map(\.action.input), [first.input, second.input])
        runner.runs[0].finish(.succeeded(.object(["page": Self.searchPage(), "state": .number(9)])))
        clock.advance(by: 10)
        XCTAssertEqual(runner.runs.count, 1, "Nothing is replayed")
        XCTAssertNil(sessions.session(for: Self.pluginID))
        XCTAssertFalse(sessions.call(second), "With no session open the call starts the Action as usual")
    }

    /// A second call may close the view: the first one's commit stands
    /// until then, and the toast is the Host's to show.
    func testASecondCallMayCloseTheView() throws {
        let session = try start()
        XCTAssertTrue(sessions.call(try Self.action(input: ["scope": "installed"])))
        XCTAssertTrue(sessions.call(try Self.action(input: ["scope": "outdated"])))
        answer(0, page: Self.searchPage(), state: .number(1))
        XCTAssertEqual(session.state, .number(1))
        runner.runs[1].finish(.succeeded(.object(["close": .bool(true), "toast": .string("Nothing outdated")])))
        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(renderer.closes, [.closedByPlugin])
        XCTAssertEqual(feedback, ["Nothing outdated"])
        XCTAssertTrue(reported.isEmpty, "Nothing was left to cancel")
        XCTAssertNil(sessions.session(for: Self.pluginID))
    }

    /// The second call is cancelled when the first one's answer closes the
    /// view; updating the Plugin or revoking a Capability cancels them too.
    func testEveryEndCancelsTheCallsStillWaiting() throws {
        var session = try start()
        XCTAssertTrue(sessions.call(try Self.action()))
        XCTAssertTrue(sessions.call(try Self.action(input: ["scope": "all"])))
        runner.runs[0].finish(.succeeded(.object(["close": .bool(true)])))
        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(reported.map(\.message), ["Cancelled: the Plugin closed its view"])
        XCTAssertEqual(runner.runs.count, 1)

        for (reason, message) in [(PluginViewSessionEnd.pluginChanged, "the Plugin was updated, disabled or removed"),
                                  (.capabilityRevoked, "a Capability it uses was revoked")] {
            setUp()
            session = try start()
            XCTAssertTrue(sessions.call(try Self.action()))
            sessions.end(pluginID: Self.pluginID, because: reason)
            XCTAssertTrue(session.isEnded)
            XCTAssertEqual(reported.map(\.message), ["Cancelled: \(message)"])
            XCTAssertEqual(runner.runs[0].stopReason, .cancelled)
        }
    }

    // MARK: - Who gets calls

    /// Level 1 Plugins, and Plugins declaring `collections` r1, keep Level 1's
    /// rule: calling again restarts the Action, so the call is not taken.
    /// Host Commands keep their native path whatever the Plugin declares.
    func testOnlyAPluginDeclaringRepeatedCallsTakesThem() throws {
        for permits in [CollectionsFixtures.revisionOne, CollectionsFixtures.withoutCollections, { _ in false }] {
            makeSessions(permits: permits)
            let session = try start(view: Self.form("first"))
            XCTAssertFalse(sessions.call(try Self.action()))
            XCTAssertEqual(runner.runs.count, 0)
            XCTAssertEqual(renderer.broughtForward, 0)
            XCTAssertFalse(session.isEnded)
        }
        setUp()
        _ = try start()
        let screenshot = try ActionConfiguration(id: ActionID("capture"), pluginID: Self.pluginID,
                                                 command: CommandDeclaration(id: CommandID("emoji.capture"), title: "Capture",
                                                                             execution: .host, hostServiceID: "screen.capture"),
                                                 input: .null)
        XCTAssertFalse(sessions.call(screenshot))
        XCTAssertFalse(sessions.call(try Self.action(pluginID: PluginID("com.example.other"))), "No session of that Plugin")
        XCTAssertEqual(runner.runs.count, 0)
    }

    // MARK: - Support

    @discardableResult
    private func start(view: JSONValue? = nil) throws -> PluginViewSession {
        let answer: JSONValue = view.map { .object(["view": $0, "state": .number(0)]) }
            ?? .object(["page": Self.searchPage(), "state": .number(0)])
        try sessions.actionAnswered(Self.action(), with: answer)
        return try XCTUnwrap(sessions.session(for: Self.pluginID))
    }

    private static func action(command: String = "emoji.search", input: [String: String]? = nil,
                               pluginID: PluginID = pluginID) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID(command), pluginID: pluginID,
                                command: CommandDeclaration(id: CommandID(command), title: "Search",
                                                            execution: .javascript, script: "emoji.js"),
                                input: input.map { .object($0.mapValues(JSONValue.string)) } ?? .null)
    }

    private static func searchPage() -> JSONValue {
        B.pageJSON("search", [B.row([B.field(), B.choice()]), B.grid(items: ["A", "B", "C"])])
    }

    private static func form(_ title: String) -> JSONValue {
        .object(["title": .string(title), "form": .object(["fields": .array([
            .object(["key": .string("query"), "kind": .string("text"), "title": .string("Query")])
        ])])])
    }

    private func answer(_ index: Int, page: JSONValue?, state: JSONValue = .number(1),
                        operation: RequestedHostOperation? = nil) {
        var members: [String: JSONValue] = [:]
        if let page { members["page"] = page; members["state"] = state }
        if let operation { members["operation"] = operation.json }
        runner.runs[index].finish(.succeeded(.object(members)))
    }

    private func typed(_ text: String) -> PluginViewEvent {
        .pageFieldChanged(page: "search", field: "query", values: .object(["query": .string(text), "category": .string("all")]))
    }

    private func itemAction(_ id: String) -> PluginViewEvent {
        .itemAction(page: "search", collection: "results", action: "insert",
                    item: PluginPageItemSnapshot(id: id, section: nil, text: "★"), values: .object([:]))
    }
}
