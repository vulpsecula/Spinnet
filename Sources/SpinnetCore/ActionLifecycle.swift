import Foundation

public enum ActionExecutionState: Equatable {
    case running(progressVisible: Bool)
    case finished(ActionOutcome)
}

/// Host-visible lifecycle. Callbacks and public methods belong to the same
/// serial UI executor. Execution itself must return immediately and finish
/// asynchronously on that executor, so a blocked service cannot block timers.
public final class ActionLifecycle {
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    public typealias Execute = (ActionConfiguration, ActionExecutionControl, @escaping (ActionOutcome) -> Void) -> Void

    public let action: ActionConfiguration
    public private(set) var state: ActionExecutionState = .running(progressVisible: false)
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private let execute: Execute
    private let onChange: (ActionExecutionState) -> Void
    private var control: ActionExecutionControl?
    private var startedAt: TimeInterval?

    public init(
        action: ActionConfiguration,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Schedule = { delay, operation in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: operation)
        },
        execute: @escaping Execute,
        onChange: @escaping (ActionExecutionState) -> Void
    ) {
        self.action = action
        self.now = now
        self.schedule = schedule
        self.execute = execute
        self.onChange = onChange
    }

    public func start() {
        guard startedAt == nil else { return }
        let control = ActionExecutionControl()
        self.control = control
        startedAt = now()
        onChange(state)
        schedule(ScriptedActionBudgets.progressDelay) { [weak self] in
            guard let self, case .running = self.state else { return }
            self.state = .running(progressVisible: true)
            self.onChange(self.state)
        }
        schedule(ScriptedActionBudgets.actionDeadline) { [weak self] in self?.stop(.timedOut) }
        execute(action, control) { [weak self] outcome in self?.finish(outcome) }
    }

    public func cancel() { stop(.cancelled) }

    private func stop(_ error: PluginRuntimeError) {
        guard case .running = state else { return }
        control?.stop(error)
        publish(ActionOutcome(actionID: action.id, pluginID: action.pluginID, title: action.title,
            terminal: .failed(ActionFailure(pluginID: action.pluginID, actionID: action.id,
                category: error.failureCategory, message: error.description))))
    }

    private func finish(_ outcome: ActionOutcome) {
        guard case .running = state else { return }
        if let startedAt, now() - startedAt >= ScriptedActionBudgets.actionDeadline {
            stop(.timedOut)
        } else {
            publish(outcome)
        }
    }

    private func publish(_ outcome: ActionOutcome) {
        state = .finished(outcome)
        onChange(state)
    }
}

/// A cancellation signal shared with the isolated execution. Registration and
/// stop are synchronized so cancellation during helper startup cannot be lost.
public final class ActionExecutionControl {
    private let lock = NSLock()
    private var error: PluginRuntimeError?
    private var termination: (() -> Void)?
    public let deadline: TimeInterval

    public init() {
        deadline = ProcessInfo.processInfo.systemUptime + ScriptedActionBudgets.actionDeadline
    }

    public func check() throws {
        lock.lock()
        let failure = error
        lock.unlock()
        if let failure { throw failure }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw PluginRuntimeError.timedOut }
    }

    public func stop(_ reason: PluginRuntimeError) {
        lock.lock()
        guard error == nil else { lock.unlock(); return }
        error = reason
        let terminate = termination
        lock.unlock()
        terminate?()
    }

    func registerTermination(_ operation: @escaping () -> Void) {
        lock.lock()
        termination = operation
        let stopped = error != nil
        lock.unlock()
        if stopped { operation() }
    }

    func clearTermination() {
        lock.lock()
        termination = nil
        lock.unlock()
    }
}

public extension ActionConfiguration {
    /// An explicit invocation (including Retry) never reuses an execution ID.
    func newInvocation() throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID(UUID().uuidString), pluginID: pluginID,
                                command: declaredCommand, input: input)
    }
}
