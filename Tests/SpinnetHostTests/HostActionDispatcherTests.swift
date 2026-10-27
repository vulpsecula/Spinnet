import Foundation
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class HostActionDispatcherTests: XCTestCase {
    func testWaitsForOperationThenCommitsTheAnswerAndDismissesProgress() throws {
        let harness = try DispatcherHarness()
        harness.sessions.holdsOperation = true
        harness.sessions.handlesAnswer = true
        harness.script.answer = .object(["view": .object(["title": .string("Result")])])

        harness.dispatcher.invoke(harness.action)
        XCTAssertTrue(harness.scheduling.work.isEmpty)
        harness.scheduling.advance(to: 20)
        XCTAssertEqual(harness.presenters.first?.progress.count, 0, "The operation slot owns the wait")

        harness.sessions.releaseOperation()
        harness.scheduling.advance(to: 20.5)
        let feedback = try XCTUnwrap(harness.presenters.first)
        XCTAssertEqual(feedback.progress.count, 1)
        harness.scheduling.runNext()

        XCTAssertEqual(harness.script.calls.count, 1)
        XCTAssertEqual(harness.sessions.answers.map(\.0), [harness.action],
                       "Answer commitment uses the saved Action, rather than its invocation identity")
        XCTAssertEqual(feedback.dismissals, 1)
        XCTAssertTrue(feedback.outcomes.isEmpty, "A view is already the Action's feedback")
        XCTAssertEqual(harness.didDismiss, 1)
    }

    func testExistingSessionTakesTheExplicitCallWithoutAnotherLifecycle() throws {
        let harness = try DispatcherHarness()
        harness.sessions.acceptsCalls = true

        harness.dispatcher.invoke(harness.action)

        XCTAssertEqual(harness.sessions.calls, [harness.action])
        XCTAssertTrue(harness.scheduling.work.isEmpty)
        XCTAssertTrue(harness.presenters.isEmpty)
        XCTAssertEqual(harness.willStart, 0)
    }

    func testRetryReentersOperationWaitingAndRechecksTheCurrentRegistration() throws {
        let harness = try DispatcherHarness()
        harness.script.failure = .scriptFailed("Try again explicitly")
        harness.dispatcher.invoke(harness.action)
        harness.scheduling.runNext()
        let first = try XCTUnwrap(harness.presenters.first)
        let initial = try XCTUnwrap(first.outcomes.first)
        XCTAssertEqual(harness.script.calls.count, 1, "A failure does not replay itself")

        try harness.registry.setEnabled(false, for: harness.action.pluginID)
        harness.sessions.holdsOperation = true
        try XCTUnwrap(first.retry)()
        XCTAssertEqual(first.dismissals, 1)
        XCTAssertEqual(harness.sessions.calls, [harness.action, harness.action])
        XCTAssertTrue(harness.scheduling.work.isEmpty, "Retry must wait on the operation slot again")

        harness.sessions.releaseOperation()
        harness.scheduling.runNext()
        let retried = try XCTUnwrap(harness.presenters.last?.outcomes.first)
        XCTAssertEqual(failureCategory(retried), .commandUnavailable)
        XCTAssertEqual(harness.script.calls.count, 1, "A now-disabled Plugin cannot execute on retry")
        XCTAssertNotEqual(initial.actionID, harness.action.id)
        XCTAssertNotEqual(retried.actionID, initial.actionID)
    }

    func testQueuedInitialActionKeepsItsLifecycleDeadlineAndIgnoresLateCompletion() throws {
        let harness = try DispatcherHarness()
        harness.dispatcher.invoke(harness.action)
        harness.scheduling.advance(to: ScriptedActionBudgets.actionDeadline)

        let feedback = try XCTUnwrap(harness.presenters.first)
        XCTAssertEqual(feedback.outcomes.count, 1)
        XCTAssertEqual(failureCategory(try XCTUnwrap(feedback.outcomes.first)), .timedOut)
        XCTAssertTrue(harness.script.calls.isEmpty, "Execution has been held on the Plugin queue")

        harness.scheduling.runNext()
        XCTAssertEqual(feedback.outcomes.count, 1)
        XCTAssertTrue(harness.sessions.answers.isEmpty)
    }

    func testActionAndViewEventShareThePluginLaneAndOnlyEventRestartsItsDeadline() throws {
        let harness = try DispatcherHarness()
        harness.dispatcher.invoke(harness.action)
        let control = ActionExecutionControl()
        let deadlineBeforeQueueing = control.deadline
        let delivery = ViewEventDelivery(event: .submitted(values: .string("edited")), state: .string("state"))
        var started = false
        var result: ActionOutcome?
        harness.dispatcher.runEvent(harness.action, delivery, control, { started = true }, { result = $0 })

        XCTAssertEqual(harness.scheduling.work.map(\.0), [harness.action.pluginID, harness.action.pluginID])
        XCTAssertFalse(started)
        harness.scheduling.runNext()
        XCTAssertFalse(started)
        harness.scheduling.runNext()

        XCTAssertTrue(started)
        XCTAssertNotNil(result)
        XCTAssertEqual(harness.script.calls.map(\.delivery), [.actionStart, delivery])
        XCTAssertGreaterThan(control.deadline, deadlineBeforeQueueing)
        XCTAssertEqual(harness.presenters.count, 1, "View Events have session-owned progress, not another Action panel")
    }

    func testProgressCancellationAndShutdownRetireFeedbackWithoutLateAnswers() throws {
        let harness = try DispatcherHarness()
        harness.dispatcher.invoke(harness.action)
        harness.scheduling.advance(to: ScriptedActionBudgets.progressDelay)
        let feedback = try XCTUnwrap(harness.presenters.first)
        try XCTUnwrap(feedback.cancel)()
        XCTAssertEqual(failureCategory(try XCTUnwrap(feedback.outcomes.first)), .cancelled)

        harness.dispatcher.shutdown()
        harness.scheduling.runNext()
        harness.dispatcher.invoke(harness.action)
        XCTAssertEqual(feedback.outcomes.count, 1)
        XCTAssertEqual(feedback.dismissals, 1)
        XCTAssertTrue(harness.sessions.answers.isEmpty)
        XCTAssertEqual(harness.presenters.count, 1)
    }

    private func failureCategory(_ outcome: ActionOutcome) -> ActionFailureCategory? {
        guard case .failed(let failure) = outcome.terminal else { return nil }
        return failure.category
    }
}

private final class DispatcherHarness {
    let registry = PluginRegistry()
    let sessions = DispatcherSessions()
    let feedback = DispatcherFeedback()
    let script = DispatcherScript()
    let scheduling = DispatcherScheduling()
    let action: ActionConfiguration
    var dispatcher: HostActionDispatcher!
    var presenters: [DispatcherFeedback] = []
    var willStart = 0
    var didDismiss = 0

    init() throws {
        let command = CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript, script: "run.js")
        let manifest = try PluginManifest(id: PluginID("example.dispatch"), name: "Dispatch", version: "1.0.0",
                                          commands: [command])
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/unused/dispatch.spinnetplugin"), manifest: manifest))
        action = try ActionConfiguration(id: ActionID("configured"), pluginID: manifest.id, command: command, input: .string("saved"))
        dispatcher = HostActionDispatcher(
            runner: HostActionRunner(executor: DispatcherHostExecutor(), scriptedExecutor: script),
            registry: registry, sessions: sessions, feedback: feedback,
            makeFeedback: { [unowned self] in
                let presenter = DispatcherFeedback()
                presenters.append(presenter)
                return presenter
            },
            scheduling: .init(enqueue: scheduling.enqueue, receive: { $0() }, now: { [scheduling] in scheduling.now },
                              schedule: scheduling.schedule),
            willStart: { [unowned self] in willStart += 1 }, didDismiss: { [unowned self] in didDismiss += 1 }
        )
    }
}

private final class DispatcherSessions: HostActionSessions {
    var acceptsCalls = false
    var handlesAnswer = false
    var holdsOperation = false
    var calls: [ActionConfiguration] = []
    var answers: [(ActionConfiguration, JSONValue)] = []
    private var waiting: [() -> Void] = []

    func call(_ action: ActionConfiguration) -> Bool { calls.append(action); return acceptsCalls }
    func whenOperationSlotFree(for pluginID: PluginID, _ work: @escaping () -> Void) {
        if holdsOperation { waiting.append(work) } else { work() }
    }
    func actionAnswered(_ action: ActionConfiguration, with value: JSONValue) throws -> Bool {
        answers.append((action, value)); return handlesAnswer
    }
    func releaseOperation() {
        holdsOperation = false
        let work = waiting; waiting = []
        work.forEach { $0() }
    }
}

private final class DispatcherFeedback: HostActionFeedback {
    var onDismiss: (() -> Void)?
    var progress: [ActionConfiguration] = []
    var outcomes: [ActionOutcome] = []
    var cancel: (() -> Void)?
    var retry: (() -> Void)?
    var dismissals = 0

    func showMessage(_ message: String) {}
    func showProgress(for action: ActionConfiguration, cancel: @escaping () -> Void) {
        progress.append(action); self.cancel = cancel
    }
    func showOutcome(_ outcome: ActionOutcome, retry: (() -> Void)?) {
        outcomes.append(outcome); self.retry = retry
    }
    func dismiss() { dismissals += 1; onDismiss?() }
}

private final class DispatcherScript: ScriptedActionExecutor {
    struct Call { let action: ActionConfiguration; let delivery: ViewEventDelivery }
    var answer = JSONValue.null
    var failure: PluginRuntimeError?
    var calls: [Call] = []

    func execute(_ action: ActionConfiguration, in package: PluginPackage, using hostServiceBroker: PluginHostServiceBroker?,
                 control: ActionExecutionControl, delivering delivery: ViewEventDelivery) throws -> JSONValue {
        try control.check()
        calls.append(Call(action: action, delivery: delivery))
        if let failure { throw failure }
        return answer
    }
    func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue {
        try execute(action, in: package, using: nil, control: ActionExecutionControl(), delivering: .actionStart)
    }
}

private struct DispatcherHostExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}

private final class DispatcherScheduling {
    var now: TimeInterval = 0
    var work: [(PluginID?, () -> Void)] = []
    private var timers: [(TimeInterval, () -> Void)] = []

    func enqueue(_ pluginID: PluginID?, _ work: @escaping () -> Void) { self.work.append((pluginID, work)) }
    func runNext() { work.removeFirst().1() }
    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { timers.append((now + delay, work)) }
    func advance(to instant: TimeInterval) {
        while let next = timers.enumerated().filter({ $0.element.0 <= instant }).min(by: { $0.element.0 < $1.element.0 }) {
            timers.remove(at: next.offset)
            now = next.element.0
            next.element.1()
        }
        now = instant
    }
}
