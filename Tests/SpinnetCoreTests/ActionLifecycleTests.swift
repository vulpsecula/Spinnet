import XCTest
@testable import SpinnetCore

final class ActionLifecycleTests: XCTestCase {
    func testProgressAppearsAt500MillisecondsAndCancellationFinishesOnce() throws {
        let clock = LifecycleClock()
        let action = try makeAction()
        var completion: ((ActionOutcome) -> Void)?
        var updates: [ActionExecutionState] = []
        let lifecycle = ActionLifecycle(
            action: action,
            now: { clock.now },
            schedule: clock.schedule,
            execute: { _, _, finish in completion = finish },
            onChange: { updates.append($0) }
        )
        lifecycle.start()
        clock.advance(to: 0.499)
        XCTAssertEqual(lifecycle.state, .running(progressVisible: false))
        clock.advance(to: 0.5)
        XCTAssertEqual(lifecycle.state, .running(progressVisible: true))
        lifecycle.cancel()
        guard case .finished(let outcome) = lifecycle.state,
              case .failed(let failure) = outcome.terminal else {
            return XCTFail("Cancellation must clear Progress and publish a terminal result")
        }
        XCTAssertEqual(failure.category, .cancelled)
        XCTAssertEqual(failure.pluginID, action.pluginID)
        XCTAssertEqual(failure.actionID, action.id)
        let count = updates.count
        completion?(ActionOutcome(actionID: action.id, pluginID: action.pluginID,
                                  title: action.title, terminal: .succeeded(.null)))
        clock.advance(to: 4.25)
        XCTAssertEqual(updates.count, count)
    }

    func testDeadlineIncludesBlockedExecutionAndPublishesBy425Seconds() throws {
        let clock = LifecycleClock()
        var updates: [ActionExecutionState] = []
        let lifecycle = ActionLifecycle(action: try makeAction(), now: { clock.now },
            schedule: clock.schedule, execute: { _, _, _ in },
            onChange: { updates.append($0) })
        lifecycle.start()
        clock.advance(to: 3.999)
        XCTAssertEqual(lifecycle.state, .running(progressVisible: true))
        clock.advance(to: 4)
        guard case .finished(let outcome) = lifecycle.state,
              case .failed(let failure) = outcome.terminal else {
            return XCTFail("The deadline must finish even when execution never calls back")
        }
        XCTAssertEqual(failure.category, .timedOut)
        clock.advance(to: 4.25)
        XCTAssertEqual(updates.count, 3)
    }

    func testExplicitRetryHasNewActionIdentityAndPreservesConfiguration() throws {
        let action = try makeAction()
        let retry = try action.newInvocation()
        XCTAssertNotEqual(retry.id, action.id)
        XCTAssertNotEqual(try action.newInvocation().id, retry.id)
        XCTAssertEqual(retry.declaredCommand, action.declaredCommand)
        XCTAssertEqual(retry.input, action.input)
        XCTAssertEqual(retry.pluginID, action.pluginID)
    }

    func testImmediateSuccessNeverShowsProgressOrChangesToTimeout() throws {
        let action = try makeAction()
        let clock = LifecycleClock()
        var updates: [ActionExecutionState] = []
        let outcome = ActionOutcome(actionID: action.id, pluginID: action.pluginID,
                                    title: action.title, terminal: .succeeded(.string("done")))
        let lifecycle = ActionLifecycle(action: action, now: { clock.now }, schedule: clock.schedule,
            execute: { _, _, finish in finish(outcome); finish(outcome) },
            onChange: { updates.append($0) })
        lifecycle.start()
        clock.advance(to: 4.25)
        XCTAssertEqual(updates, [.running(progressVisible: false), .finished(outcome)])
    }

    func testEveryStableFailureClearsProgressWithoutReplay() throws {
        for category in [ActionFailureCategory.helperCrashed, .helperTerminated,
                         .runtimeProtocolFailed, .scriptedActionFailed] {
            let action = try makeAction()
            let clock = LifecycleClock()
            var finish: ((ActionOutcome) -> Void)?
            var calls = 0
            var states: [ActionExecutionState] = []
            let lifecycle = ActionLifecycle(action: action, now: { clock.now }, schedule: clock.schedule,
                execute: { _, _, completion in calls += 1; finish = completion },
                onChange: { states.append($0) })
            lifecycle.start()
            clock.advance(to: 0.5)
            let outcome = ActionOutcome(actionID: action.id, pluginID: action.pluginID, title: action.title,
                terminal: .failed(ActionFailure(pluginID: action.pluginID, actionID: action.id,
                                                category: category, message: "private diagnostic")))
            finish?(outcome)
            XCTAssertEqual(lifecycle.state, .finished(outcome))
            clock.advance(to: 0.75)
            XCTAssertEqual(lifecycle.state, .finished(outcome))
            clock.advance(to: 4.25)
            XCTAssertEqual(states.count, 3)
            XCTAssertEqual(calls, 1)
        }
    }

    private func makeAction() throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("action"), pluginID: PluginID("test.plugin"),
            command: CommandDeclaration(id: CommandID("run"), title: "Run",
                                        execution: .javascript, script: "run.js"), input: .null)
    }
}

private final class LifecycleClock {
    var now: TimeInterval = 0
    var events: [(TimeInterval, () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ operation: @escaping () -> Void) {
        events.append((now + delay, operation))
    }
    func advance(to instant: TimeInterval) {
        while let next = events.enumerated().filter({ $0.element.0 <= instant })
            .min(by: { $0.element.0 < $1.element.0 }) {
            events.remove(at: next.offset)
            now = next.element.0
            next.element.1()
        }
        now = instant
    }
}
