import Foundation
import XCTest
@testable import SpinnetCore

/// Requested Host Operations in View Sessions (ADR 0018, Candidate Contract
/// `host_operations` r1), driven through the sessions' seams: a renderer
/// that records, events the test answers by hand, a clock it advances, and
/// a performer that holds each operation until the test finishes it. Each
/// test follows one of the published scenarios.
final class HostOperationSessionTests: XCTestCase {
    private var clock: ManualClock!
    private var renderer: RecordingRenderer!
    private var runner: HeldEventRunner!
    private var performer: HeldPerformer!
    private var reported: [String] = []
    private var feedback: [String] = []
    private var sessions: PluginViewSessions!

    private static let appA = InsertionTargetApp(processIdentifier: 42, bundleIdentifier: "com.example.a",
                                                 launchDate: Date(timeIntervalSince1970: 1), name: "App A")
    private static let shownA = InsertionTargetCapture.shown(app: appA, focus: nil)

    override func setUp() {
        clock = ManualClock()
        renderer = RecordingRenderer()
        runner = HeldEventRunner()
        performer = HeldPerformer()
        reported = []
        feedback = []
        sessions = PluginViewSessions(
            renderer: renderer, runEvent: runner.run, schedule: clock.schedule,
            showFeedback: { [unowned self] in feedback.append($0) },
            // Revision 1's rules: an outcome whose view closed is shown by
            // the Host and not delivered (`OutcomeAfterCloseSessionTests`
            // covers revision 2's).
            permitting: { _ in { member in
                member != HostOperationsContract.outcomeAfterClose
                    && PluginInterfaceContracts.host.candidates.contains { $0.members.contains(member) }
            } },
            operations: performer,
            reportOperation: { [unowned self] _, message in reported.append(message) }
        )
    }

    // MARK: - Commit

    /// Scenario 01: the answer and its request commit together, the request
    /// runs after the script has answered with the target shown at the
    /// gesture, and success with `closes_view` closes the view.
    func testARequestedInsertionCommitsWithItsAnswerAndRunsAfterIt() throws {
        let session = try start(state: .object(["recent": .array([])]))
        session.send(.submitted(values: .null), insertionTarget: Self.shownA)
        XCTAssertEqual(runner.runs[0].delivery.insertionTarget, Self.shownA, "The invocation knows what was shown")

        let insert = RequestedHostOperation(perform: "selection.replace", input: .object(["text": .string("😀")]),
                                            id: "insert", closesView: true)
        finish(0, view: "picked", state: .object(["recent": .array([.string("😀")])]), operation: insert)

        XCTAssertEqual(session.state, .object(["recent": .array([.string("😀")])]))
        XCTAssertEqual(performer.authorized.map(\.operation), [insert])
        XCTAssertEqual(performer.performed.map(\.operation), [insert])
        XCTAssertEqual(performer.performed.first?.target, Self.shownA)
        XCTAssertEqual(performer.performed.first?.action.commandID, session.action.commandID)
        XCTAssertFalse(session.isEnded, "The view stays until the outcome is known")

        performer.finish(0, .succeeded)

        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(renderer.closes, [.closedByPlugin])
        XCTAssertEqual(runner.runs.count, 1, "Nothing is delivered without notify")
        XCTAssertEqual(reported, [])
    }

    /// Scenario 02: a refusal keeps the view, shows the Host's own message
    /// inline, and reaches a script that asked to be told, naming no App.
    func testARefusedInsertionKeepsTheViewShowsWhyAndIsDeliveredWhenAsked() throws {
        let session = try start(state: .object([:]))
        session.send(.submitted(values: .null), insertionTarget: Self.shownA)
        let insert = RequestedHostOperation(perform: "selection.replace", input: .string("😀"), id: "insert",
                                            closesView: true, notify: true)
        finish(0, view: "picked", state: .object([:]), operation: insert)
        performer.finish(0, .refused(.targetChanged), message: "Spinnet showed App A, but App B is in front. Nothing was inserted.")

        XCTAssertFalse(session.isEnded, "closes_view applies to success only")
        XCTAssertEqual(renderer.presentations.last?.error?.message,
                       "Spinnet showed App A, but App B is in front. Nothing was inserted.")
        XCTAssertEqual(renderer.presentations.last?.error?.category, .insertionTargetChanged)
        XCTAssertEqual(runner.runs.count, 2)
        XCTAssertEqual(runner.runs[1].delivery.event?.json, .object([
            "type": .string("operation_finished"), "operation": .string("insert"), "perform": .string("selection.replace"),
            "outcome": .string("refused"), "reason": .string("target_changed")
        ]))
        XCTAssertEqual(runner.runs[1].delivery.insertionTarget, .notShown)
        XCTAssertEqual(reported, [], "The view showed it")
    }

    /// Scenario 05: a refused Capability refuses the whole answer: view,
    /// state and toast stay at the last good ones and nothing is requested.
    func testARefusedCapabilityRefusesTheWholeAnswer() throws {
        let session = try start(state: .object(["recent": .array([])]))
        performer.refusal = .capabilityDenied(.insertIntoFocusedApp)
        session.send(.submitted(values: .null), insertionTarget: Self.shownA)
        finish(0, view: "changed", state: .object(["recent": .array([.string("😀")])]), toast: "Done",
               operation: RequestedHostOperation(perform: "selection.replace", input: .string("😀"), closesView: true))

        XCTAssertEqual(session.state, .object(["recent": .array([])]))
        XCTAssertEqual(renderer.presentations.last?.view, Self.view("first"))
        XCTAssertEqual(renderer.presentations.last?.error?.category, .capabilityDenied)
        XCTAssertEqual(PluginViewRepairRoute(try XCTUnwrap(renderer.presentations.last?.error)), .pluginSettings)
        XCTAssertEqual(renderer.toasts, [])
        XCTAssertEqual(performer.performed.count, 0)
        XCTAssertFalse(session.isEnded)
    }

    /// Scenario 06: only an answer to a gesture may request an operation;
    /// any other ends the session as a protocol violation.
    func testOnlyAnAnswerToAGestureMayRequestAnOperation() throws {
        let events: [PluginViewEvent] = [
            .fieldChanged(field: "query", values: .null), .settingChanged(key: "tone", value: .string("warm")),
            .settingsSwapped(first: "a", second: "b"), .sectionDelivered(section: "s", response: .null)
        ]
        for event in events {
            setUp()
            let session = try start()
            session.send(event)
            clock.advance(by: 0.2)
            finish(0, operation: RequestedHostOperation(perform: "selection.replace", input: .string("x")))
            XCTAssertTrue(session.isEnded, "\(event)")
            guard case .failed(let failure)? = renderer.closes.last else { return XCTFail("\(event)") }
            XCTAssertEqual(failure.category, .runtimeProtocolFailed)
            XCTAssertTrue(failure.message.contains("only an answer to a gesture may"), failure.message)
            XCTAssertEqual(performer.authorized.count + performer.performed.count, 0)
        }
    }

    /// An answer to `operation_finished` is not a gesture either, so a script
    /// cannot loop by answering its result with another request.
    func testAnAnswerToAResultCannotRequestAnother() throws {
        let session = try start()
        session.send(.actionChosen("copy"))
        finish(0, operation: RequestedHostOperation(perform: "clipboard.write", input: .string("♥"), notify: true))
        performer.finish(0, .succeeded)
        finish(1, operation: RequestedHostOperation(perform: "clipboard.write", input: .string("again")))

        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(performer.performed.count, 1)
    }

    // MARK: - Pin

    /// Pin means the user keeps the panel beside their App: `closes_view`
    /// closes a view only when it is not pinned, for a requested operation
    /// and for a page or item action alike.
    func testClosesViewLeavesAPinnedViewOpen() throws {
        renderer.pinned = true
        let session = try start()
        session.send(.submitted(values: .null), insertionTarget: Self.shownA)
        let insert = RequestedHostOperation(perform: "selection.replace", input: .string("😀"), closesView: true)
        finish(0, view: "picked", operation: insert)
        performer.finish(0, .succeeded)
        XCTAssertFalse(session.isEnded, "A pinned view stays open")
        XCTAssertEqual(renderer.closes, [])

        session.perform(RequestedHostOperation(perform: "clipboard.write", input: .string("😀"), closesView: true),
                        insertionTarget: .notShown)
        performer.finish(1, .succeeded)
        XCTAssertFalse(session.isEnded, "A page or item action leaves a pinned view open too")

        renderer.pinned = false
        session.perform(RequestedHostOperation(perform: "clipboard.write", input: .string("😀"), closesView: true),
                        insertionTarget: .notShown)
        performer.finish(2, .succeeded)
        XCTAssertTrue(session.isEnded, "Once unpinned, closes_view closes the view")
        XCTAssertEqual(renderer.closes, [.closedByPlugin])
    }

    /// The Plugin's explicit `{close: true}` closes a pinned view.
    func testAnExplicitCloseClosesAPinnedView() throws {
        renderer.pinned = true
        let session = try start()
        session.send(.actionChosen("done"))
        runner.runs[0].finish(.succeeded(.object(["close": .bool(true)])))
        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(renderer.closes, [.closedByPlugin])
    }

    // MARK: - Busy

    /// Scenario 07: while an operation is outstanding, gestures wait in order
    /// and run with the state the previous answer committed; typing does not
    /// wait. Two quick Returns insert twice, in order.
    func testGesturesWaitBehindAnOutstandingOperationWhileTypingFlows() throws {
        let session = try start(state: .object(["count": .number(0)]))
        session.send(.submitted(values: .null), insertionTarget: Self.shownA)
        finish(0, view: "one", state: .object(["count": .number(1)]),
               operation: RequestedHostOperation(perform: "selection.replace", input: .string("1")))
        session.send(.submitted(values: .null), insertionTarget: Self.shownA)
        session.send(.fieldChanged(field: "query", values: .object(["query": .string("smi")])))
        clock.advance(by: 0.2)

        XCTAssertEqual(runner.runs.count, 2)
        XCTAssertEqual(runner.runs[1].delivery.event, .fieldChanged(field: "query", values: .object(["query": .string("smi")])),
                       "Typing is dispatched before the first outcome")
        finish(1, view: "typed", state: .object(["count": .number(1)]))
        XCTAssertEqual(runner.runs.count, 2, "The second Return still waits")

        performer.finish(0, .succeeded)

        XCTAssertEqual(runner.runs.count, 3)
        XCTAssertEqual(runner.runs[2].delivery.event, .submitted(values: .null))
        XCTAssertEqual(runner.runs[2].delivery.state, .object(["count": .number(1)]))
        XCTAssertEqual(runner.runs[2].delivery.insertionTarget, Self.shownA)
        finish(2, view: "two", state: .object(["count": .number(2)]),
               operation: RequestedHostOperation(perform: "selection.replace", input: .string("2")))
        XCTAssertEqual(performer.performed.map(\.operation.input), [.string("1"), .string("2")])
    }

    /// The view shows the operation's own busy state once it has run for
    /// the progress delay, and drops it with the outcome.
    func testALongOperationShowsItsOwnBusyState() throws {
        let session = try start()
        session.send(.actionChosen("copy"))
        finish(0, operation: RequestedHostOperation(perform: "clipboard.write", input: .string("♥")))
        XCTAssertEqual(renderer.presentations.last?.isPerformingOperation, false)
        clock.advance(by: ScriptedActionBudgets.progressDelay)
        XCTAssertEqual(renderer.presentations.last?.isPerformingOperation, true)
        XCTAssertEqual(renderer.presentations.last?.isBusy, false, "Distinct from an event's busy state")
        performer.finish(0, .succeeded)
        XCTAssertEqual(renderer.presentations.last?.isPerformingOperation, false)
        XCTAssertTrue(session.isPerformingOperation == false)
    }

    /// Scenario 09: with `notify`, the result is answered before the next
    /// gesture runs, and the slot frees once that invocation ends, however
    /// it ends.
    func testTheResultIsAnsweredBeforeTheNextGestureAndThenTheSlotFrees() throws {
        for ending in ["answered", "failed", "timed out"] {
            setUp()
            let session = try start(state: .object(["recent": .array([])]))
            session.send(.submitted(values: .null), insertionTarget: Self.shownA)
            finish(0, operation: RequestedHostOperation(perform: "selection.replace", input: .string("😀"), id: "insert",
                                                        notify: true))
            session.send(.actionChosen("favourites"))
            performer.finish(0, .succeeded)

            XCTAssertEqual(runner.runs.count, 2, ending)
            XCTAssertEqual(runner.runs[1].delivery.event,
                           .operationFinished(id: "insert", perform: "selection.replace", outcome: .succeeded))
            var waiter = false
            sessions.whenOperationSlotFree(for: session.pluginID) { waiter = true }
            XCTAssertFalse(waiter, "A Menu start waits too")
            switch ending {
            case "answered": finish(1, view: "noted", state: .object(["recent": .array([.string("😀")])]))
            case "failed": runner.runs[1].finish(.failed(ActionFailure(pluginID: session.pluginID, actionID: ActionID("e"),
                                                                       category: .scriptedActionFailed, message: "boom")))
            default: clock.advance(by: ScriptedActionBudgets.viewEventDeadline)
            }
            XCTAssertTrue(waiter, ending)
            XCTAssertEqual(runner.runs.count, 3, ending)
            XCTAssertEqual(runner.runs[2].delivery.event, .actionChosen("favourites"))
            if ending == "answered" { XCTAssertEqual(runner.runs[2].delivery.state, .object(["recent": .array([.string("😀")])])) }
        }
    }

    /// Scenario 09's note: once another Command handles the view, the
    /// outcome is shown by the Host and not delivered, and the slot frees.
    func testAnotherCommandHandlingTheViewDoesNotHearTheResult() throws {
        let session = try start()
        session.send(.submitted(values: .null), insertionTarget: Self.shownA)
        finish(0, operation: RequestedHostOperation(perform: "selection.replace", input: .string("x"), notify: true))
        try sessions.actionAnswered(Self.action(command: "example.other"), with: Self.answer(view: "other"))
        performer.finish(0, .refused(.noTarget), message: "No App is in front. Nothing was inserted.")

        XCTAssertEqual(runner.runs.count, 1, "The other Command runs no operation_finished")
        XCTAssertEqual(renderer.presentations.last?.error?.message, "No App is in front. Nothing was inserted.",
                       "The Host shows it in the view the session shows now")
        var free = false
        sessions.whenOperationSlotFree(for: session.pluginID) { free = true }
        XCTAssertTrue(free)
    }

    /// Presenting again with the same Command keeps a result not yet
    /// dispatched: the request belongs to the session, not to the page. One
    /// already being answered is dropped with the old view and never
    /// replayed, and another Command's view frees the slot instead.
    func testPresentingAgainKeepsAWaitingResultOnlyForTheSameCommand() throws {
        for sameCommand in [true, false] {
            setUp()
            let session = try start()
            session.send(.submitted(values: .null), insertionTarget: Self.shownA)
            finish(0, operation: RequestedHostOperation(perform: "selection.replace", input: .string("x"), notify: true))
            session.send(.fieldChanged(field: "query", values: .null))
            clock.advance(by: 0.2)
            performer.finish(0, .succeeded)
            XCTAssertEqual(runner.runs.count, 2, "The result waits behind the field change")

            try sessions.actionAnswered(Self.action(command: sameCommand ? "example.pick" : "example.other"),
                                        with: Self.answer(view: "again"))

            XCTAssertEqual(runner.runs[1].stopReason, .cancelled)
            var free = false
            sessions.whenOperationSlotFree(for: Self.pluginID) { free = true }
            if sameCommand {
                XCTAssertEqual(runner.runs.count, 3)
                XCTAssertEqual(runner.runs[2].delivery.event,
                               .operationFinished(id: nil, perform: "selection.replace", outcome: .succeeded))
                XCTAssertFalse(free, "The slot is held until the result is answered")
                finish(2)
                sessions.whenOperationSlotFree(for: Self.pluginID) { free = true }
            } else {
                XCTAssertEqual(runner.runs.count, 2, "Another Command does not hear it")
            }
            XCTAssertTrue(free)
        }
    }

    /// A result being answered when the view is presented again is dropped
    /// with the old view and not replayed; the slot frees.
    func testAResultBeingAnsweredIsNotReplayedAfterPresentingAgain() throws {
        let session = try start()
        session.send(.submitted(values: .null), insertionTarget: Self.shownA)
        finish(0, operation: RequestedHostOperation(perform: "selection.replace", input: .string("x"), notify: true))
        performer.finish(0, .succeeded)
        XCTAssertEqual(runner.runs.count, 2)
        try sessions.actionAnswered(Self.action(), with: Self.answer(view: "again"))
        XCTAssertEqual(runner.runs[1].stopReason, .cancelled)
        XCTAssertEqual(runner.runs.count, 2)
        var free = false
        sessions.whenOperationSlotFree(for: Self.pluginID) { free = true }
        XCTAssertTrue(free)
    }

    // MARK: - Ending

    /// Scenario 08: ending the session cancels a request that has not
    /// started; the Host says so unless the user closed the view.
    func testEndingTheSessionCancelsARequestThatHasNotStarted() throws {
        for reason in [PluginViewSessionEnd.pluginChanged, .capabilityRevoked, .viewClosed] {
            setUp()
            // A request without a view holds the slot, so the view's waits.
            try sessions.actionAnswered(Self.action(command: "example.copy"),
                                        with: .object(["operation": RequestedHostOperation(perform: "clipboard.write",
                                                                                           input: .string("a")).json]))
            try sessions.actionAnswered(Self.action(), with: .object([
                "view": Self.view("first"), "operation": RequestedHostOperation(perform: "clipboard.write", input: .string("b")).json
            ]))
            XCTAssertEqual(performer.performed.count, 1)

            sessions.end(pluginID: Self.pluginID, because: reason)
            performer.finish(0, .succeeded)

            XCTAssertEqual(performer.performed.map(\.operation.input), [.string("a")], "\(reason): never run")
            XCTAssertEqual(reported.count, reason == .viewClosed ? 0 : 1, "\(reason)")
        }
    }

    /// Updating the Plugin cancels a request without a view that has not
    /// started, too.
    func testUpdatingThePluginCancelsAWaitingRequestWithoutAView() throws {
        try sessions.actionAnswered(Self.action(command: "example.copy"),
                                    with: .object(["operation": RequestedHostOperation(perform: "clipboard.write", input: .string("a")).json]))
        try sessions.actionAnswered(Self.action(command: "example.copy"),
                                    with: .object(["operation": RequestedHostOperation(perform: "clipboard.write", input: .string("b")).json]))
        sessions.end(pluginID: Self.pluginID, because: .pluginChanged)
        performer.finish(0, .succeeded)
        XCTAssertEqual(performer.performed.map(\.operation.input), [.string("a")])
        XCTAssertEqual(reported, ["clipboard.write was cancelled: the Plugin was updated, disabled or removed"])
    }

    /// Scenario 08: a request that is running when its view closes
    /// finishes; the Host shows a failure itself and delivers nothing.
    func testARequestRunningWhenItsViewClosesFinishesAndIsShownByTheHost() throws {
        for outcome in [HostOperationOutcome.succeeded, .failed(.targetUnresponsive)] {
            setUp()
            let session = try start()
            session.send(.submitted(values: .null), insertionTarget: Self.shownA)
            finish(0, operation: RequestedHostOperation(perform: "selection.replace", input: .string("x"), notify: true))
            session.close()
            performer.finish(0, outcome, message: "Nothing was inserted")

            XCTAssertEqual(runner.runs.count, 1, "Nothing is delivered after the session ended")
            XCTAssertEqual(reported, outcome == .succeeded ? [] : ["Nothing was inserted"])
            var free = false
            sessions.whenOperationSlotFree(for: Self.pluginID) { free = true }
            XCTAssertTrue(free)
        }
    }

    /// A completion for a request that already has its outcome is a stale
    /// Host-internal race and changes nothing.
    func testALateSecondCompletionIsIgnored() throws {
        let session = try start()
        session.send(.actionChosen("copy"))
        finish(0, operation: RequestedHostOperation(perform: "clipboard.write", input: .string("x"), notify: true))
        performer.finish(0, .succeeded)
        performer.finish(0, .failed(.hostServiceFailed), message: "late")
        XCTAssertEqual(runner.runs.count, 2)
        XCTAssertNil(renderer.presentations.last?.error)
        XCTAssertEqual(reported, [])
    }

    // MARK: - Without a view

    /// Scenario 10: an Action without a view showed no target, so the Host
    /// performs its insertion request with none shown, which the performer
    /// refuses, and shows the refusal near the pointer.
    func testARequestWithoutAViewRunsWithNoTargetShownAndIsReportedByTheHost() throws {
        let showed = try sessions.actionAnswered(Self.action(command: "example.stamp"), with: .object([
            "operation": RequestedHostOperation(perform: "selection.replace", input: .string("2026-10-04")).json
        ]))
        XCTAssertTrue(showed, "The Host owns the outcome, so the Action reports no completion of its own")
        XCTAssertEqual(performer.performed.first?.target, .notShown)
        XCTAssertNil(sessions.session(for: Self.pluginID))
        performer.finish(0, .refused(.targetNotShown), message: "Nothing showed where the text would go, so nothing was inserted")
        XCTAssertEqual(reported, ["Nothing showed where the text would go, so nothing was inserted"])
    }

    /// An Action that starts with a view and a request owns it through the
    /// new session, but nothing was shown when the user acted.
    func testAnActionStartsRequestHasNoTargetShownEvenWithAView() throws {
        try sessions.actionAnswered(Self.action(), with: .object([
            "view": Self.view("first"), "operation": RequestedHostOperation(perform: "selection.replace", input: .string("x")).json
        ]))
        XCTAssertEqual(performer.performed.first?.target, .notShown)
        performer.finish(0, .refused(.targetNotShown), message: "Nothing was inserted")
        XCTAssertEqual(renderer.presentations.last?.error?.message, "Nothing was inserted")
    }

    /// A refused Capability refuses an Action's first answer whole: it
    /// throws, and nothing is shown or requested.
    func testARefusedCapabilityRefusesAnActionsFirstAnswer() throws {
        performer.refusal = .capabilityDenied(.writeClipboard)
        XCTAssertThrowsError(try sessions.actionAnswered(Self.action(), with: .object([
            "view": Self.view("first"), "operation": RequestedHostOperation(perform: "clipboard.write", input: .string("x")).json
        ]))) { XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.writeClipboard)) }
        XCTAssertNil(sessions.session(for: Self.pluginID))
        XCTAssertEqual(renderer.presentations, [])
        XCTAssertEqual(performer.performed.count, 0)
    }

    /// A Plugin that does not declare the candidate cannot request.
    func testALevelOnePluginsAnswerWithAnOperationIsAProtocolViolation() throws {
        sessions = PluginViewSessions(renderer: renderer, runEvent: runner.run, schedule: clock.schedule,
                                      showFeedback: { _ in }, operations: performer)
        XCTAssertThrowsError(try sessions.actionAnswered(Self.action(), with: .object([
            "operation": RequestedHostOperation(perform: "clipboard.write", input: .string("x")).json
        ]))) {
            XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation("The script's answer has unknown member operation"))
        }
        XCTAssertEqual(performer.performed.count, 0)
    }

    // MARK: - Support

    private static let pluginID = PluginID("com.example.operations")

    @discardableResult
    private func start(state: JSONValue = .null) throws -> PluginViewSession {
        try sessions.actionAnswered(Self.action(), with: Self.answer(view: "first", state: state))
        return try XCTUnwrap(sessions.session(for: Self.pluginID))
    }

    private func finish(_ index: Int, view: String? = nil, state: JSONValue = .null, toast: String? = nil,
                        operation: RequestedHostOperation? = nil) {
        var members: [String: JSONValue] = [:]
        if let view { members["view"] = Self.view(view); members["state"] = state }
        if let toast { members["toast"] = .string(toast) }
        if let operation { members["operation"] = operation.json }
        runner.runs[index].finish(.succeeded(.object(members)))
    }

    private static func action(command: String = "example.pick") throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID(command), pluginID: pluginID,
                                command: CommandDeclaration(id: CommandID(command), title: "Pick",
                                                            execution: .javascript, script: "pick.js"),
                                input: .null)
    }

    private static func view(_ title: String) -> JSONValue { .object(["title": .string(title)]) }

    private static func answer(view title: String, state: JSONValue = .null) -> JSONValue {
        .object(["view": view(title), "state": state])
    }
}

/// Records what was authorized and holds each operation until the test
/// finishes it.
final class HeldPerformer: HostOperationPerformer {
    struct Performed {
        let operation: RequestedHostOperation
        let action: ActionConfiguration
        let target: InsertionTargetCapture
        let completion: (HostOperationResult) -> Void
    }

    var refusal: PluginHostServiceError?
    private(set) var authorized: [(operation: RequestedHostOperation, action: ActionConfiguration)] = []
    private(set) var performed: [Performed] = []

    func authorize(_ operation: RequestedHostOperation, for action: ActionConfiguration) throws {
        if let refusal { throw refusal }
        authorized.append((operation, action))
    }

    func perform(_ operation: RequestedHostOperation, for action: ActionConfiguration, target: InsertionTargetCapture,
                 completion: @escaping (HostOperationResult) -> Void) {
        performed.append(Performed(operation: operation, action: action, target: target, completion: completion))
    }

    func finish(_ index: Int, _ outcome: HostOperationOutcome, message: String? = nil) {
        performed[index].completion(HostOperationResult(outcome, message: message))
    }
}
