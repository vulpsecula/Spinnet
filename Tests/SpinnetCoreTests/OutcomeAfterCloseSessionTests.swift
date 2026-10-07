import Foundation
import XCTest
@testable import SpinnetCore

/// Candidate Contract `host_operations` r2 in View Sessions: an operation
/// that asked to `notify` and whose view closed while it ran, by its own
/// `closes_view`, by the user or by the Host, still reaches the Action that
/// requested it, once, in a viewless invocation whose answer can show a
/// toast and nothing else. Revision 1 keeps showing such an outcome without
/// telling the Plugin.
final class OutcomeAfterCloseSessionTests: XCTestCase {
    private var clock: ManualClock!
    private var renderer: RecordingRenderer!
    private var runner: HeldEventRunner!
    private var performer: HeldPerformer!
    private var reported: [String] = []
    private var feedback: [String] = []
    private var sessions: PluginViewSessions!
    private static let pluginID = PluginID("com.example.operations")
    private static let shown = InsertionTargetCapture.shown(app: nil, focus: nil)

    /// What a Level 2 Plugin may use beyond Level 1.
    private static let permits: (PluginInterfaceMember) -> Bool = { PluginInterfaceContracts.levelTwoMembers.contains($0) }

    private func makeSessions() {
        clock = ManualClock()
        renderer = RecordingRenderer()
        runner = HeldEventRunner()
        performer = HeldPerformer()
        reported = []
        feedback = []
        let permits = Self.permits
        sessions = PluginViewSessions(
            renderer: renderer, runEvent: runner.run, schedule: clock.schedule,
            showFeedback: { [unowned self] in feedback.append($0) },
            permitting: { _ in permits }, operations: performer,
            reportOperation: { [unowned self] _, message in reported.append(message) }
        )
    }

    override func setUp() { makeSessions() }

    private static func action() throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("example.pick"), pluginID: pluginID,
                                command: CommandDeclaration(id: CommandID("example.pick"), title: "Pick",
                                                            execution: .javascript, script: "pick.js"),
                                input: .object(["tone": .string("warm")]))
    }

    private func start(state: JSONValue = .object(["recent": .array([])])) throws -> PluginViewSession {
        try sessions.actionAnswered(Self.action(), with: .object(["view": .object(["title": .string("Pick")]), "state": state]))
        return try XCTUnwrap(sessions.session(for: Self.pluginID))
    }

    /// The gesture's answer requests an insertion that closes the view on
    /// success and asks to hear its outcome.
    private func requestInsertion(in session: PluginViewSession, notify: Bool = true) {
        session.send(.submitted(values: .null), insertionTarget: Self.shown)
        let insert = RequestedHostOperation(perform: "selection.replace", input: .string("😀"), id: "insert",
                                            closesView: true, notify: notify)
        runner.runs[runner.runs.count - 1].finish(.succeeded(.object(["operation": insert.json])))
    }

    private func answer(_ index: Int, _ value: JSONValue) {
        runner.runs[index].finish(.succeeded(value))
    }

    // MARK: - Delivered after the view closed

    /// Emoji's insertion: the view closes on success, and the outcome
    /// reaches one viewless invocation of the requesting Action, from the
    /// view's last good state, which may store what it likes.
    func testClosesViewSuccessIsDeliveredToAViewlessInvocation() throws {
        let session = try start()
        requestInsertion(in: session)
        performer.finish(0, .succeeded)
        let drawn = renderer.presentations.count

        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(renderer.closes, [.closedByPlugin])
        XCTAssertEqual(runner.runs.count, 2)
        let run = runner.runs[1]
        XCTAssertEqual(run.delivery.event?.json, .object([
            "type": .string("operation_finished"), "operation": .string("insert"), "perform": .string("selection.replace"),
            "outcome": .string("succeeded"), "view_closed": .bool(true)
        ]))
        XCTAssertEqual(run.delivery.state, .object(["recent": .array([])]), "The view's last good state")
        XCTAssertEqual(run.delivery.insertionTarget, .notShown, "Nothing is shown where text would go")
        XCTAssertEqual(run.action.input, .object(["tone": .string("warm")]), "The requesting Action's input")

        answer(1, .null)
        XCTAssertEqual(renderer.presentations.count, drawn, "Nothing is drawn for it")
        XCTAssertEqual(reported, [])
        XCTAssertEqual(feedback, [])
    }

    /// An unpinned panel gives up the keyboard to the App it inserts into
    /// and closes before the insertion finishes: the user's or the Host's
    /// close, while the operation ran, still lets its outcome through, a
    /// refusal included.
    func testAnOutcomeReachedAfterTheViewClosedIsDelivered() throws {
        for outcome in [HostOperationOutcome.succeeded, .refused(.targetChanged), .failed(.targetUnresponsive)] {
            setUp()
            let session = try start()
            requestInsertion(in: session)
            session.close()
            performer.finish(0, outcome, message: "Host message")
            XCTAssertEqual(runner.runs.count, 2, "\(outcome)")
            guard case .operationFinished(_, _, let delivered, true, nil)? = runner.runs[1].delivery.event else {
                return XCTFail("\(String(describing: runner.runs[1].delivery.event))")
            }
            XCTAssertEqual(delivered, outcome)
            XCTAssertEqual(reported, outcome == .succeeded ? [] : ["Host message"], "The Host still shows a failure")
        }
    }

    /// Its answer may show a toast near the pointer and nothing else: a
    /// view, page, state, operation or close breaks the interface, which
    /// the Host reports and otherwise ignores.
    func testItsAnswerShowsAToastAtMostAndAnythingElseIsReportedAndIgnored() throws {
        let session = try start()
        requestInsertion(in: session)
        performer.finish(0, .succeeded)
        answer(1, .object(["toast": .string("Added to Recent")]))
        XCTAssertEqual(feedback, ["Added to Recent"])

        for value: JSONValue in [
            .object(["view": .object(["title": .string("Again")]), "state": .null]),
            .object(["close": .bool(true)]),
            .object(["operation": RequestedHostOperation(perform: "clipboard.write", input: .string("x")).json]),
            .object(["state": .number(1)])
        ] {
            setUp()
            let again = try start()
            requestInsertion(in: again)
            performer.finish(0, .succeeded)
            let drawn = renderer.presentations.count
            answer(1, value)
            XCTAssertEqual(reported.count, 1, "\(value)")
            XCTAssertTrue(reported.first?.contains("answer") == true, "\(reported)")
            XCTAssertEqual(performer.performed.count, 1, "Nothing more is performed")
            XCTAssertEqual(renderer.presentations.count, drawn, "Nothing is drawn")
            XCTAssertNil(sessions.session(for: Self.pluginID))
        }
    }

    /// It holds the Plugin's operation slot until it ends, so the Action's
    /// next start from the Menu reads what it stored; a failure is reported
    /// and frees the slot too.
    func testTheNextStartWaitsForIt() throws {
        let session = try start()
        requestInsertion(in: session)
        performer.finish(0, .succeeded)
        var started = false
        sessions.whenOperationSlotFree(for: Self.pluginID) { started = true }
        XCTAssertFalse(started, "The next gesture waits")
        runner.runs[1].finish(.failed(ActionFailure(pluginID: Self.pluginID, actionID: ActionID("example.pick"),
                                                    category: .scriptedActionFailed, message: "boom")))
        XCTAssertTrue(started)
        XCTAssertEqual(reported, ["boom"])
    }

    /// Its script must start within four seconds of the outcome and answer
    /// within four seconds of starting; either deadline frees the slot.
    func testItsDeadlines() throws {
        runner.startsAtOnce = false
        let session = try start()
        requestInsertion(in: session)
        performer.finish(0, .succeeded)
        var free = false
        sessions.whenOperationSlotFree(for: Self.pluginID) { free = true }
        clock.advance(by: HostOperationsContract.afterCloseStartDeadline + 0.1)
        XCTAssertTrue(free, "Dropped when it never started")
        XCTAssertEqual(runner.runs[1].stopReason, .cancelled)

        setUp()
        let again = try start()
        requestInsertion(in: again)
        performer.finish(0, .succeeded)
        clock.advance(by: 1)
        free = false
        sessions.whenOperationSlotFree(for: Self.pluginID) { free = true }
        clock.advance(by: ScriptedActionBudgets.viewEventDeadline)
        XCTAssertTrue(free, "Stopped at its deadline")
        XCTAssertEqual(runner.runs[1].stopReason, .timedOut)
        XCTAssertEqual(reported.count, 1)
        answer(1, .null)
        XCTAssertEqual(reported.count, 1, "A late answer changes nothing")
    }

    // MARK: - Not delivered

    /// A pinned view stays open and hears the outcome in the view.
    func testAPinnedViewHearsItInTheView() throws {
        renderer.pinned = true
        let session = try start()
        requestInsertion(in: session)
        performer.finish(0, .succeeded)
        XCTAssertFalse(session.isEnded)
        XCTAssertEqual(runner.runs.count, 2)
        XCTAssertNil(runner.runs[1].delivery.event.flatMap { event -> Bool? in
            if case .operationFinished(_, _, _, true, _) = event { return true } else { return nil }
        }, "Delivered in the view, not after it")
    }

    /// Without notify, for a request cancelled before it ran, and when the
    /// Plugin changed, nothing is delivered after the
    /// view closed.
    func testWhenItIsNotDelivered() throws {
        let session = try start()
        requestInsertion(in: session, notify: false)
        performer.finish(0, .succeeded)
        XCTAssertEqual(runner.runs.count, 1, "Without notify")

        setUp()
        let changed = try start()
        requestInsertion(in: changed)
        sessions.end(pluginID: Self.pluginID, because: .pluginChanged)
        performer.finish(0, .succeeded)
        XCTAssertEqual(runner.runs.count, 1, "Not after the Plugin changed")

        setUp()
        let busy = try start()
        busy.send(.submitted(values: .null), insertionTarget: Self.shown)
        answer(0, .object(["operation": RequestedHostOperation(perform: "clipboard.write", input: .string("a")).json]))
        busy.send(.submitted(values: .null), insertionTarget: Self.shown)
        XCTAssertEqual(runner.runs.count, 1, "The second gesture waits for the first operation")
        performer.finish(0, .succeeded)
        answer(1, .object(["operation": RequestedHostOperation(perform: "clipboard.write", input: .string("b"),
                                                               notify: true).json]))
        XCTAssertEqual(performer.performed.count, 2)
        busy.close()
        performer.finish(1, .succeeded)
        XCTAssertEqual(runner.runs.count, 3, "A request running when the view closed is delivered")
    }
}
