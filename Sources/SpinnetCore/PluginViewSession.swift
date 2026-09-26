import Foundation

/// What a Plugin View shows at one moment: the view the script last
/// described, whether an event is running, and why the last one failed.
public struct PluginViewPresentation: Equatable {
    /// The view description, opaque here; the renderer reads it.
    public let view: JSONValue
    /// An event is in flight. The view shows its own busy state; the Host
    /// shows no Action progress for View Events.
    public let isBusy: Bool
    /// The failure of the last event, shown inline with a repair route
    /// chosen by its category; nil once an event succeeds.
    public let error: ActionFailure?

    public init(view: JSONValue, isBusy: Bool, error: ActionFailure?) {
        self.view = view
        self.isBusy = isBusy
        self.error = error
    }
}

/// Why a View Session ended.
public enum PluginViewSessionEnd: Equatable {
    /// The view was closed: by the user, or by the Host, as when an unpinned
    /// view loses focus or the Host cannot show it.
    case viewClosed
    /// The script answered `{close: true}`.
    case closedByPlugin
    /// The Plugin was updated, disabled or removed.
    case pluginChanged
    /// The user revoked a Capability the Plugin holds.
    case capabilityRevoked
    /// The script broke the Documented Plugin Interface.
    case failed(ActionFailure)
}

/// The seam between View Sessions and whatever draws Plugin Views. All calls
/// arrive on the sessions' executor.
public protocol PluginViewRenderer: AnyObject {
    /// Shows the session's view, or updates it in place when it is already
    /// on screen.
    func present(_ presentation: PluginViewPresentation, of session: PluginViewSession)
    /// Shows a toast inside the session's view.
    func showToast(_ toast: String, in session: PluginViewSession)
    /// Removes the session's view; the session has ended and sends nothing
    /// more.
    func close(_ session: PluginViewSession, because reason: PluginViewSessionEnd)
}

/// One View Session (ADR 0010): the Host keeps the view's state and hands
/// each user interaction to the Command script as a View Event, one bounded
/// invocation at a time.
///
/// Confined to one serial executor, like `ActionLifecycle`: `runEvent` and
/// `schedule` call back on it. A pending field change waits out the
/// debounce and coalesces to the latest; other events queue in order. Every
/// dispatched event gets a new generation, and only the answer for the
/// generation in flight is read; ending, replacing or timing out moves on,
/// so a late answer is dropped without side effects.
public final class PluginViewSession {
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    /// Runs the Command script once for a View Event, through the same
    /// broker and invocation path as the Action itself, and calls back with
    /// its outcome.
    public typealias RunEvent = (ActionConfiguration, ViewEventDelivery, ActionExecutionControl,
                                 @escaping (ActionOutcome) -> Void) -> Void

    /// The configured Action whose Command presented the view.
    public private(set) var action: ActionConfiguration
    public var pluginID: PluginID { action.pluginID }
    public private(set) var view: JSONValue
    /// The state from the last answer that had a view: the last good state.
    public private(set) var state: JSONValue
    public private(set) var error: ActionFailure?
    public private(set) var generation = 0
    public private(set) var isEnded = false
    public var isBusy: Bool { inFlight != nil }

    private weak var renderer: PluginViewRenderer?
    private let runEvent: RunEvent
    private let schedule: Schedule
    private let showFeedback: (String) -> Void
    private let onEnd: (PluginViewSession) -> Void
    private var inFlight: (generation: Int, control: ActionExecutionControl)?
    private var queue: [PluginViewEvent] = []
    private var debouncing: PluginViewEvent?
    private var debounceToken = 0

    init(action: ActionConfiguration, view: JSONValue, state: JSONValue, renderer: PluginViewRenderer,
         runEvent: @escaping RunEvent, schedule: @escaping Schedule, showFeedback: @escaping (String) -> Void,
         onEnd: @escaping (PluginViewSession) -> Void) {
        self.action = action
        self.view = view
        self.state = state
        self.renderer = renderer
        self.runEvent = runEvent
        self.schedule = schedule
        self.showFeedback = showFeedback
        self.onEnd = onEnd
    }

    /// Hands one user interaction to the script.
    public func send(_ event: PluginViewEvent) {
        guard !isEnded else { return }
        if event.coalesces {
            debouncing = event
            debounceToken += 1
            let token = debounceToken
            schedule(ScriptedActionBudgets.fieldChangeDebounce) { [weak self] in
                guard let self, !self.isEnded, self.debounceToken == token else { return }
                self.flushDebounced()
                self.dispatchNext()
            }
            return
        }
        // A pending change happened first, so it goes first.
        flushDebounced()
        enqueue(event)
        dispatchNext()
    }

    /// The view was closed. Its renderer calls this when the user closes it
    /// or the Host does.
    public func close() { end(.viewClosed) }

    func present() {
        guard !isEnded else { return }
        renderer?.present(PluginViewPresentation(view: view, isBusy: isBusy, error: error), of: self)
    }

    func showToast(_ toast: String?) {
        guard !isEnded, let toast else { return }
        renderer?.showToast(toast, in: self)
    }

    /// Presenting again replaces the view in place. Events meant for the old
    /// view, in flight or waiting, are dropped.
    func replace(action: ActionConfiguration, view: JSONValue, state: JSONValue) {
        guard !isEnded else { return }
        abandonEvents()
        self.action = action
        self.view = view
        self.state = state
        error = nil
        present()
    }

    /// Ends the session at once: the event in flight is cancelled, waiting
    /// ones are dropped, and nothing that arrives later has any effect.
    func end(_ reason: PluginViewSessionEnd) {
        guard !isEnded else { return }
        isEnded = true
        abandonEvents()
        renderer?.close(self, because: reason)
        onEnd(self)
    }

    private func abandonEvents() {
        generation += 1
        inFlight?.control.stop(.cancelled)
        inFlight = nil
        queue.removeAll()
        debouncing = nil
        debounceToken += 1
    }

    private func flushDebounced() {
        guard let pending = debouncing else { return }
        debouncing = nil
        debounceToken += 1
        enqueue(pending)
    }

    private func enqueue(_ event: PluginViewEvent) {
        if event.coalesces, let last = queue.last, last.coalesces {
            queue[queue.count - 1] = event
        } else {
            queue.append(event)
        }
    }

    private func dispatchNext() {
        guard !isEnded, inFlight == nil, !queue.isEmpty else { return }
        let event = queue.removeFirst()
        generation += 1
        let dispatched = generation
        let control = ActionExecutionControl()
        inFlight = (dispatched, control)
        present()
        schedule(ScriptedActionBudgets.viewEventDeadline) { [weak self] in self?.expire(dispatched) }
        // Each event is a new invocation, so it never reuses an Action ID.
        let invocation = (try? action.newInvocation()) ?? action
        runEvent(invocation, ViewEventDelivery(event: event, state: state), control) { [weak self] outcome in
            self?.receive(outcome, for: dispatched)
        }
    }

    private func expire(_ dispatched: Int) {
        guard let current = inFlight, current.generation == dispatched else { return }
        current.control.stop(.timedOut)
        inFlight = nil
        let error = PluginRuntimeError.timedOut
        self.error = ActionFailure(pluginID: action.pluginID, actionID: action.id,
                                   category: error.failureCategory, message: error.description)
        present()
        dispatchNext()
    }

    private func receive(_ outcome: ActionOutcome, for dispatched: Int) {
        guard !isEnded, let current = inFlight, current.generation == dispatched else { return }
        inFlight = nil
        switch outcome.terminal {
        case .succeeded(let value):
            let answer: PluginScriptAnswer
            do {
                answer = try PluginScriptAnswer(parsing: value)
            } catch {
                let violation = error as? PluginRuntimeError ?? .protocolViolation("The script's answer is invalid")
                end(.failed(ActionFailure(pluginID: outcome.pluginID, actionID: outcome.actionID,
                                          category: violation.failureCategory, message: violation.description)))
                return
            }
            if answer.close {
                end(.closedByPlugin)
                if let toast = answer.toast { showFeedback(toast) }
                return
            }
            if let view = answer.view {
                self.view = view
                state = answer.state
            }
            error = nil
            present()
            showToast(answer.toast)
        case .failed(let failure):
            guard failure.category != .runtimeProtocolFailed else {
                end(.failed(failure))
                return
            }
            // A refusal, a crash, a timeout or a script error keeps the view
            // and the last good state; the next event may succeed.
            error = failure
            present()
        }
        dispatchNext()
    }
}

/// The View Sessions of every Plugin, at most one each. It reads the answer
/// an Action's first invocation gave, starts, replaces or closes the
/// Plugin's session from it, and ends a session when its Plugin changes or
/// loses a Capability.
public final class PluginViewSessions {
    private let renderer: PluginViewRenderer
    private let runEvent: PluginViewSession.RunEvent
    private let schedule: PluginViewSession.Schedule
    private let showFeedback: (String) -> Void
    private var sessions: [PluginID: PluginViewSession] = [:]
    private var registry: PluginRegistry?
    private var grantStore: PluginCapabilityGrantStore?
    private var registryObserver: UUID?
    private var grantObserver: UUID?

    /// `showFeedback` shows a toast without a view as the Host's feedback
    /// near the pointer.
    public init(renderer: PluginViewRenderer, runEvent: @escaping PluginViewSession.RunEvent,
                schedule: @escaping PluginViewSession.Schedule, showFeedback: @escaping (String) -> Void) {
        self.renderer = renderer
        self.runEvent = runEvent
        self.schedule = schedule
        self.showFeedback = showFeedback
    }

    deinit {
        if let registryObserver { registry?.removeInvalidationObserver(registryObserver) }
        if let grantObserver { grantStore?.removeRevocationObserver(grantObserver) }
    }

    public func session(for pluginID: PluginID) -> PluginViewSession? { sessions[pluginID] }

    /// Ends a Plugin's session when the Plugin is updated, disabled or
    /// removed, or a Capability it holds is revoked. The observers fire on
    /// whichever thread made the change, so `executor` brings the ending
    /// onto the sessions' own.
    public func observe(registry: PluginRegistry, grantStore: PluginCapabilityGrantStore,
                        on executor: @escaping (@escaping () -> Void) -> Void) {
        self.registry = registry
        self.grantStore = grantStore
        registryObserver = registry.observeInvalidation { [weak self] pluginID in
            executor { self?.end(pluginID: pluginID, because: .pluginChanged) }
        }
        grantObserver = grantStore.observeRevocation { [weak self] pluginID in
            executor { self?.end(pluginID: pluginID, because: .capabilityRevoked) }
        }
    }

    /// Acts on what the Action's first invocation answered and says whether
    /// that showed the user anything: a view, a closed view, or a toast.
    /// Throws a protocol violation, and starts nothing, for a value that is
    /// no answer.
    @discardableResult
    public func actionAnswered(_ action: ActionConfiguration, with value: JSONValue) throws -> Bool {
        let answer = try PluginScriptAnswer(parsing: value)
        let existing = sessions[action.pluginID]
        if let view = answer.view {
            if let existing {
                existing.replace(action: action, view: view, state: answer.state)
                existing.showToast(answer.toast)
                return true
            }
            let session = PluginViewSession(action: action, view: view, state: answer.state, renderer: renderer,
                                            runEvent: runEvent, schedule: schedule, showFeedback: showFeedback,
                                            onEnd: { [weak self] ended in
                                                guard self?.sessions[ended.pluginID] === ended else { return }
                                                self?.sessions.removeValue(forKey: ended.pluginID)
                                            })
            sessions[action.pluginID] = session
            session.present()
            session.showToast(answer.toast)
            return true
        }
        if answer.close { existing?.end(.closedByPlugin) }
        if let toast = answer.toast { showFeedback(toast) }
        return answer.toast != nil || (answer.close && existing != nil)
    }

    public func end(pluginID: PluginID, because reason: PluginViewSessionEnd) {
        sessions[pluginID]?.end(reason)
    }
}
