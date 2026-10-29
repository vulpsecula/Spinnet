import Foundation
import SpinnetCore

/// The existing session module's dispatch interface, also used by deterministic
/// tests of the connection between invocation, feedback and answer commitment.
protocol HostActionSessions: AnyObject {
    func call(_ action: ActionConfiguration) -> Bool
    func whenOperationSlotFree(for pluginID: PluginID, _ work: @escaping () -> Void)
    func actionAnswered(_ action: ActionConfiguration, with value: JSONValue) throws -> Bool
}

extension PluginViewSessions: HostActionSessions {}

protocol HostActionFeedback: AnyObject {
    var onDismiss: (() -> Void)? { get set }
    func showMessage(_ message: String)
    func showProgress(for action: ActionConfiguration, cancel: @escaping () -> Void)
    func showOutcome(_ outcome: ActionOutcome, retry: (() -> Void)?)
    func dismiss()
}

extension HostFeedbackPresenter: HostActionFeedback {}

/// Owns the Host's invocation queues, running Action lifecycles and their
/// feedback. Its methods and session/feedback callbacks use the UI executor;
/// only execution crosses onto its owned queues.
final class HostActionDispatcher {
    /// Scheduling is an internal seam: production owns real serial queues,
    /// while tests can hold queued work and advance lifecycle timers explicitly.
    struct Scheduling {
        typealias Enqueue = (PluginID?, @escaping () -> Void) -> Void
        let enqueue: Enqueue
        let receive: (@escaping () -> Void) -> Void
        let now: () -> TimeInterval
        let schedule: ActionLifecycle.Schedule

        static func live() -> Scheduling {
            let queues = InvocationQueues()
            return Scheduling(
                enqueue: queues.enqueue,
                receive: { DispatchQueue.main.async(execute: $0) },
                now: { ProcessInfo.processInfo.systemUptime },
                schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
            )
        }
    }

    private let runner: HostActionRunner
    private let registry: PluginRegistry
    private let sessions: HostActionSessions
    private let feedback: HostActionFeedback
    private let makeFeedback: () -> HostActionFeedback
    private let scheduling: Scheduling
    private let willStart: () -> Void
    private let didDismiss: () -> Void
    private var executions: [ActionID: ActionLifecycle] = [:]
    private var executionFeedback: [ActionID: HostActionFeedback] = [:]
    private var isStopped = false

    init(runner: HostActionRunner, registry: PluginRegistry, sessions: HostActionSessions,
         feedback: HostActionFeedback,
         makeFeedback: @escaping () -> HostActionFeedback = { HostFeedbackPresenter() },
         scheduling: Scheduling = .live(),
         willStart: @escaping () -> Void = {}, didDismiss: @escaping () -> Void = {}) {
        self.runner = runner
        self.registry = registry
        self.sessions = sessions
        self.feedback = feedback
        self.makeFeedback = makeFeedback
        self.scheduling = scheduling
        self.willStart = willStart
        self.didDismiss = didDismiss
    }

    func invoke(_ configuredAction: ActionConfiguration) {
        guard !isStopped else { return }
        let runner = self.runner, registry = self.registry
        let receive = scheduling.receive
        guard configuredAction.execution == .javascript else {
            // Capture an Effect's owner before dispatch. Queueing cannot turn
            // an earlier registration/grant into a replacement owner's Effect.
            let invocation = runner.prepareInvocation(configuredAction, using: registry)
            scheduling.enqueue(nil) { [weak self] in
                let outcome = invocation()
                receive { [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.feedback.showOutcome(outcome, retry: nil)
                }
            }
            return
        }
        if sessions.call(configuredAction) { return }
        do {
            let action = try configuredAction.newInvocation()
            willStart()
            let presenter = makeFeedback()
            executionFeedback[action.id] = presenter
            let enqueue = scheduling.enqueue
            let lifecycle = ActionLifecycle(action: action, now: scheduling.now, schedule: scheduling.schedule,
                execute: { action, control, finish in
                    // Initial Actions keep their deadline while waiting on the
                    // Plugin queue. View Events restart theirs only when run.
                    enqueue(action.pluginID) {
                        let outcome = runner.invoke(action, using: registry, control: control)
                        receive { finish(outcome) }
                    }
                }, onChange: { [weak self, weak presenter] state in
                    guard let self, !self.isStopped, let presenter else { return }
                    switch state {
                    case .running(let visible):
                        if visible {
                            presenter.showProgress(for: action) { [weak self] in
                                self?.executions[action.id]?.cancel()
                            }
                        }
                    case .finished(let outcome):
                        self.executions.removeValue(forKey: action.id)
                        presenter.onDismiss = { [weak self] in
                            guard let self else { return }
                            self.executionFeedback.removeValue(forKey: action.id)
                            if !self.isStopped { self.didDismiss() }
                        }
                        var outcome = outcome
                        if case .succeeded(let answer) = outcome.terminal {
                            do {
                                if try self.sessions.actionAnswered(configuredAction, with: answer) {
                                    presenter.dismiss()
                                    return
                                }
                            } catch let refusal as PluginHostServiceError {
                                outcome = Self.failed(outcome, category: refusal.actionFailureCategory,
                                                      message: refusal.description)
                            } catch {
                                let violation = error as? PluginRuntimeError
                                    ?? .protocolViolation("The script's answer is invalid") // Not localized: a runtime failure, kept in the Action failure record
                                outcome = Self.failed(outcome, category: violation.failureCategory,
                                                      message: violation.description)
                            }
                        }
                        presenter.showOutcome(outcome, retry: { [weak self, weak presenter] in
                            presenter?.dismiss()
                            self?.executionFeedback.removeValue(forKey: action.id)
                            // A retry is a fresh user invocation and re-enters
                            // admission, session hand-off and operation waiting.
                            self?.invoke(configuredAction)
                        })
                    }
                })
            executions[action.id] = lifecycle
            sessions.whenOperationSlotFree(for: action.pluginID) { [weak lifecycle] in lifecycle?.start() }
        } catch {
            feedback.showMessage(localized("Action configuration is unavailable"))
        }
    }

    /// View Events share the Action's Plugin queue, but their bounded execution
    /// starts after queueing. Session-owned timers/feedback remain in sessions.
    func runEvent(_ action: ActionConfiguration, _ delivery: ViewEventDelivery, _ control: ActionExecutionControl,
                  _ started: @escaping () -> Void, _ finish: @escaping (ActionOutcome) -> Void) {
        let runner = self.runner, registry = self.registry
        let receive = scheduling.receive
        scheduling.enqueue(action.pluginID) {
            control.restartDeadline()
            receive(started)
            let outcome = runner.invoke(action, using: registry, control: control, delivering: delivery)
            receive { finish(outcome) }
        }
    }

    func shutdown() {
        guard !isStopped else { return }
        isStopped = true
        Array(executions.values).forEach { $0.cancel() }
        executions.removeAll()
        Array(executionFeedback.values).forEach { $0.dismiss() }
        executionFeedback.removeAll()
    }

    private static func failed(_ outcome: ActionOutcome, category: ActionFailureCategory, message: String) -> ActionOutcome {
        ActionOutcome(actionID: outcome.actionID, pluginID: outcome.pluginID, title: outcome.title,
            terminal: .failed(ActionFailure(pluginID: outcome.pluginID, actionID: outcome.actionID,
                                            category: category, message: message)))
    }
}

private final class InvocationQueues {
    private var plugins: [PluginID: DispatchQueue] = [:]
    private let host = DispatchQueue(label: "com.vulpsecula.Spinnet.action-invocation", qos: .userInitiated)

    func enqueue(_ pluginID: PluginID?, _ work: @escaping () -> Void) {
        guard let pluginID else { return host.async(execute: work) }
        let queue: DispatchQueue
        if let existing = plugins[pluginID] { queue = existing }
        else {
            queue = DispatchQueue(label: "com.vulpsecula.Spinnet.plugin.\(pluginID.rawValue)", qos: .userInitiated)
            plugins[pluginID] = queue
        }
        queue.async(execute: work)
    }
}
