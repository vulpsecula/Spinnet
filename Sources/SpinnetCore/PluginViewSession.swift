import Foundation

/// What a Plugin View shows at one moment: the view the script last
/// described, whether an event is running, and why the last one failed.
public struct PluginViewPresentation: Equatable {
    /// The view description, opaque here; the renderer reads it. For a page
    /// it is the page as the script wrote it.
    public let view: JSONValue
    /// The page shown, under Candidate Contract `collections`, already read;
    /// nil for a Level 1 view.
    public let page: PluginPage?
    /// An event is in flight. The view shows its own busy state; the Host
    /// shows no Action progress for View Events.
    public let isBusy: Bool
    /// The failure of the last event, or of a Requested Host Operation,
    /// shown inline with a repair route chosen by its category; nil once an
    /// event succeeds.
    public let error: ActionFailure?
    /// A Requested Host Operation the view committed has run for longer
    /// than the progress delay: the view shows the operation's own busy
    /// state, distinct from an event's.
    public let isPerformingOperation: Bool

    public init(view: JSONValue, isBusy: Bool, error: ActionFailure?, isPerformingOperation: Bool = false,
                page: PluginPage? = nil) {
        self.view = view
        self.page = page
        self.isBusy = isBusy
        self.error = error
        self.isPerformingOperation = isPerformingOperation
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

    /// Why, as the Host tells the user of work the end cancelled.
    var explanation: String {
        switch self {
        case .viewClosed: return "the view was closed"
        case .closedByPlugin: return "the Plugin closed its view"
        case .pluginChanged: return "the Plugin was updated, disabled or removed"
        case .capabilityRevoked: return "a Capability it uses was revoked"
        case .failed(let failure): return failure.message
        }
    }
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
    /// Brings the session's view to the front where it is and gives it the
    /// keyboard, as when the user calls the Plugin again while it is open.
    func bringForward(_ session: PluginViewSession)
}

public extension PluginViewRenderer {
    func bringForward(_ session: PluginViewSession) {}
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
    /// broker and invocation path as the Action itself. It calls `started`
    /// when the script begins, after waiting its turn on the Plugin's queue,
    /// and then back with its outcome.
    public typealias RunEvent = (ActionConfiguration, ViewEventDelivery, ActionExecutionControl,
                                 _ started: @escaping () -> Void,
                                 _ finish: @escaping (ActionOutcome) -> Void) -> Void
    /// Reads a view the script described before it is drawn, and throws a
    /// protocol violation for one the Host would not draw.
    public typealias ReadView = (ActionConfiguration, JSONValue) throws -> Void
    /// Which interface members the declarations of an Action's Plugin offer.
    public typealias Permitting = (ActionConfiguration) -> (PluginInterfaceMember) -> Bool

    /// The configured Action whose Command presented the view: the
    /// session's handler. Under `collections` r2 an explicit call's Action
    /// becomes the handler when its answer commits a view.
    public private(set) var action: ActionConfiguration
    public var pluginID: PluginID { action.pluginID }
    public private(set) var view: JSONValue
    /// The page shown, when the last description was a page (Candidate
    /// Contract `collections`); nil while a Level 1 view is shown.
    public private(set) var page: PluginPage?
    /// The state from the last answer that had a view: the last good state.
    public private(set) var state: JSONValue
    public private(set) var error: ActionFailure?
    /// The event whose failure `error` is, when an event failed.
    public private(set) var errorEvent: PluginViewEvent?
    public private(set) var generation = 0
    /// How many times an Action has presented the view: 1 when the session
    /// starts, and one more each time presenting again replaces it. An
    /// event's answer updates the view without counting, so a renderer can
    /// tell the two apart.
    public private(set) var presentationCount = 1
    /// Counts every view the script answered with, starting at 1: each
    /// presentation and each event's answer that has a view, even the same
    /// view again. Busy and error changes do not count.
    public private(set) var viewRevision = 1
    /// The event whose answer is the view shown now, or nil when an Action
    /// presented it.
    public private(set) var answeredEvent: PluginViewEvent?
    public private(set) var isEnded = false
    public var isBusy: Bool { inFlight != nil }
    /// A Requested Host Operation the session committed has been running
    /// longer than the progress delay.
    public private(set) var isPerformingOperation = false
    /// Which interface members the Plugin's declarations offer; one
    /// declaring `host_operations` may answer a gesture with an operation.
    public let permits: (PluginInterfaceMember) -> Bool

    private weak var renderer: PluginViewRenderer?
    private let runEvent: RunEvent
    private let readView: ReadView
    private let schedule: Schedule
    private let showFeedback: (String) -> Void
    private let onEnd: (PluginViewSession) -> Void
    /// Tells the view's Host-Fetched Sections how the script took a
    /// `section_delivered` event: answered, failed, or dropped unrun.
    private let sectionDelivery: (String, JSONValue, HostFetchedSections.Delivery) -> Void
    /// One event waiting or in flight, with what the Host showed as where
    /// text would go when the user made it, and for `operation_finished`
    /// the request it reports.
    private struct Entry {
        let event: PluginViewEvent
        let insertionTarget: InsertionTargetCapture
        let result: (serial: Int, requestedBy: ActionConfiguration)?
        /// For an event of a page, the page and component it was made in.
        let origin: PageIdentity.Stamp?
        /// For `called`, the complete Action the user called, which runs it
        /// and under which its answer is read; every other event runs under
        /// the handler.
        let call: ActionConfiguration?

        init(_ event: PluginViewEvent, insertionTarget: InsertionTargetCapture = .notShown,
             result: (serial: Int, requestedBy: ActionConfiguration)? = nil, origin: PageIdentity.Stamp? = nil,
             call: ActionConfiguration? = nil) {
            self.event = event
            self.insertionTarget = insertionTarget
            self.result = result
            self.origin = origin
            self.call = call
        }

        /// Whether a view that replaces the one it was made in drops it:
        /// an event of a Level 1 view, which has no page provenance.
        var isLevelOneViewEvent: Bool {
            switch event {
            case .fieldChanged, .submitted, .actionChosen, .sectionDelivered: return true
            default: return false
            }
        }
    }

    private var inFlight: (generation: Int, control: ActionExecutionControl, entry: Entry)?
    private var queue: [Entry] = []
    private var debouncing: Entry?
    /// Which page and components are on screen, for page event provenance.
    private var identity = PageIdentity()
    private var debounceToken = 0
    /// The Plugin's Requested Host Operations, when the Host performs any.
    private weak var operations: HostOperationRequests?
    /// Tells the user of an explicit call the session's end cancelled.
    private let reportCall: (ActionConfiguration, String) -> Void
    /// Another Command now handles the session.
    private let commandChanged: () -> Void

    init(action: ActionConfiguration, view: JSONValue, page: PluginPage? = nil, state: JSONValue,
         renderer: PluginViewRenderer,
         runEvent: @escaping RunEvent, readView: @escaping ReadView, schedule: @escaping Schedule,
         showFeedback: @escaping (String) -> Void,
         sectionDelivery: @escaping (String, JSONValue, HostFetchedSections.Delivery) -> Void = { _, _, _ in },
         permits: @escaping (PluginInterfaceMember) -> Bool = { _ in false },
         operations: HostOperationRequests? = nil,
         reportCall: @escaping (ActionConfiguration, String) -> Void = { _, _ in },
         commandChanged: @escaping () -> Void = {},
         onEnd: @escaping (PluginViewSession) -> Void) {
        self.action = action
        self.view = view
        self.page = page
        self.state = state
        self.renderer = renderer
        self.runEvent = runEvent
        self.readView = readView
        self.schedule = schedule
        self.showFeedback = showFeedback
        self.sectionDelivery = sectionDelivery
        self.permits = permits
        self.operations = operations
        self.reportCall = reportCall
        self.commandChanged = commandChanged
        self.onEnd = onEnd
        identity.show(page)
    }

    /// Whether the Plugin's insertions follow `host_operations`: the
    /// target the Host shows, compared at execution.
    public var showsInsertionTargets: Bool { permits(HostOperationsContract.executionTimeInsertionTarget) }

    /// Hands one user interaction to the script. `insertionTarget` is what
    /// the Host showed as where text would go when the user made it, for a
    /// gesture of a Plugin declaring `host_operations`.
    ///
    /// An event of a page (Candidate Contract `collections`) is stamped with
    /// the page and component it came from; one whose page is not on screen
    /// is dropped at once, and one whose page or component changed kind or
    /// was reset before it runs is dropped then, without a run or feedback.
    public func send(_ event: PluginViewEvent, insertionTarget: InsertionTargetCapture = .notShown) {
        guard !isEnded else { return }
        var origin: PageIdentity.Stamp?
        if let made = event.pageOrigin {
            var component = made.component
            if case .pageActionChosen(_, let action, _, _) = event {
                guard let holder = page?.actionsComponent(holding: action) else { return }
                component = holder
            }
            guard let stamp = identity.stamp(page: made.page, component: component) else { return }
            origin = stamp
        }
        let entry = Entry(event, insertionTarget: event.isGesture ? insertionTarget : .notShown, origin: origin)
        if event.coalesces {
            debouncing = entry
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
        enqueue(entry)
        dispatchNext()
    }

    /// Whether an event matching `matches` waits out the debounce, waits in
    /// the queue or runs.
    public func isPending(where matches: (PluginViewEvent) -> Bool) -> Bool {
        debouncing.map { matches($0.event) } == true || queue.contains { matches($0.event) }
            || inFlight.map { matches($0.entry.event) } == true
    }

    /// Whether a field change has yet to be answered.
    public var hasPendingFieldChange: Bool { isPending(where: \.coalesces) }

    /// Sends a field change waiting out the debounce at once, as Return in a
    /// page's search field does before acting on what was typed (C1).
    public func flushFieldChanges() {
        guard !isEnded, debouncing != nil else { return }
        flushDebounced()
        dispatchNext()
    }

    /// Performs a page action or item action that names a Host Service, as
    /// the Host performs a standard action: without a View Event, under the
    /// Action's authority, in the Plugin's operation slot after anything it
    /// requested before. A refusal shows in the view with its repair route;
    /// one that closes the view closes it once it succeeds.
    public func perform(_ operation: RequestedHostOperation, insertionTarget: InsertionTargetCapture) {
        guard !isEnded else { return }
        do {
            guard let operations else {
                throw PluginHostServiceError.unavailable("This Host performs no Host Services for page actions")
            }
            try operations.authorize(operation, for: action)
        } catch {
            let refusal = error as? PluginHostServiceError ?? .failed(error.localizedDescription)
            self.error = ActionFailure(pluginID: action.pluginID, actionID: action.id,
                                       category: refusal.actionFailureCategory, message: refusal.description)
            errorEvent = nil
            present()
            return
        }
        operations?.commit(operation, for: action, owner: self, target: insertionTarget)
    }

    /// The view was closed. Its renderer calls this when the user closes it
    /// or the Host does.
    public func close() { end(.viewClosed) }

    /// Queues an explicit call of `action`, a complete Action of the
    /// session's Plugin (Candidate Contract `collections` r2): it runs as
    /// `called` in order behind what is waiting, never merged with another
    /// call, from the last good state when its turn comes, and as a gesture
    /// waits while the Plugin has an operation outstanding. The view comes
    /// forward now; the deadline starts when the script does. Nothing showed
    /// where text would go, so an insertion it makes or requests is refused.
    func call(_ action: ActionConfiguration) {
        guard !isEnded else { return }
        // A pending change happened first, so it goes first.
        flushDebounced()
        enqueue(Entry(.called, call: action))
        renderer?.bringForward(self)
        dispatchNext()
    }

    func present() {
        guard !isEnded else { return }
        renderer?.present(PluginViewPresentation(view: view, isBusy: isBusy, error: error,
                                                 isPerformingOperation: isPerformingOperation, page: page), of: self)
    }

    func showToast(_ toast: String?) {
        guard !isEnded, let toast else { return }
        renderer?.showToast(toast, in: self)
    }

    /// Presenting again replaces the view in place. Events meant for the old
    /// view, in flight or waiting, are dropped.
    func replace(action: ActionConfiguration, view: JSONValue, page: PluginPage? = nil, state: JSONValue) {
        guard !isEnded else { return }
        let results = abandonEvents()
        self.action = action
        self.view = view
        self.page = page
        identity.show(page)
        self.state = state
        error = nil
        errorEvent = nil
        presentationCount += 1
        viewRevision += 1
        answeredEvent = nil
        present()
        // A committed operation is not the old view's: its result, not yet
        // dispatched, still reaches the Action that requested it, if that
        // Action handles the view that replaces it.
        for entry in results { queueResult(entry) }
    }

    /// Ends the session at once: the event in flight is cancelled, waiting
    /// ones are dropped, and nothing that arrives later has any effect. Each
    /// explicit call it cancels is reported and never replayed.
    func end(_ reason: PluginViewSessionEnd) {
        guard !isEnded else { return }
        isEnded = true
        let calls = ([inFlight?.entry].compactMap { $0 } + queue).compactMap(\.call)
        abandonEvents()
        for call in calls { reportCall(call, "Cancelled: \(reason.explanation)") }
        renderer?.close(self, because: reason)
        operations?.ownerEnded(self, because: reason)
        onEnd(self)
    }

    /// Drops the events meant for the view shown now and returns the
    /// results not yet dispatched, for a view that replaces it.
    @discardableResult
    private func abandonEvents() -> [Entry] {
        generation += 1
        inFlight?.control.stop(.cancelled)
        // A delivery dropped with the old view is delivered again to the
        // one that replaces it; after the session ends nothing is. A result
        // already being answered is not delivered again: no outcome is
        // replayed.
        if let result = inFlight?.entry.result {
            operations?.resultAnswered(pluginID, serial: result.serial)
        }
        let dropped = ([inFlight?.entry].compactMap { $0 } + queue)
        let waitingResults = queue.filter { $0.result != nil }
        inFlight = nil
        queue.removeAll()
        if !isEnded {
            for case .sectionDelivered(let section, let response) in dropped.map(\.event) {
                sectionDelivery(section, response, .abandoned)
            }
        }
        debouncing = nil
        debounceToken += 1
        return waitingResults
    }

    private func flushDebounced() {
        guard let pending = debouncing else { return }
        debouncing = nil
        debounceToken += 1
        enqueue(pending)
    }

    private func enqueue(_ entry: Entry) {
        if entry.event.coalesces, let last = queue.last, last.event.coalesces {
            queue[queue.count - 1] = entry
        } else {
            queue.append(entry)
        }
    }

    /// Dispatches the next event that may run: the first waiting one, but
    /// while the Plugin has an operation outstanding the first that is no
    /// gesture, so typing never waits for an insertion and the requesting
    /// Action answers its result before the next gesture runs.
    func dispatchNext() {
        guard !isEnded, inFlight == nil else { return }
        let busy = operations?.isBusy(pluginID) ?? false
        guard let index = queue.firstIndex(where: { !busy || !$0.event.isGesture }) else { return }
        let entry = queue.remove(at: index)
        if let origin = entry.origin, !identity.isCurrent(origin) {
            // The page or component it was made in was replaced, changed
            // kind or was reset: the user is looking at what replaced it.
            return dispatchNext()
        }
        if let result = entry.result, !action.isSameConfiguration(as: result.requestedBy) {
            // Another Command handles the view now; the outcome was shown by
            // the Host and is not this Command's to read.
            operations?.resultAnswered(pluginID, serial: result.serial)
            return dispatchNext()
        }
        generation += 1
        let dispatched = generation
        let control = ActionExecutionControl()
        inFlight = (dispatched, control, entry)
        present()
        // Each event is a new invocation, so it never reuses an Action ID. A
        // call runs the Action called; every other event the handler.
        let runner = entry.call ?? action
        let invocation = (try? runner.newInvocation()) ?? runner
        runEvent(invocation, ViewEventDelivery(event: entry.event, state: state, insertionTarget: entry.insertionTarget),
                 control, { [weak self] in
            self?.started(dispatched)
        }, { [weak self] outcome in
            self?.receive(outcome, for: dispatched)
        })
    }

    /// The event's budget starts when its script does, not while it waits
    /// behind another run of the Plugin.
    private func started(_ dispatched: Int) {
        guard !isEnded, let current = inFlight, current.generation == dispatched else { return }
        schedule(ScriptedActionBudgets.viewEventDeadline) { [weak self] in self?.expire(dispatched) }
    }

    private func expire(_ dispatched: Int) {
        guard let current = inFlight, current.generation == dispatched else { return }
        current.control.stop(.timedOut)
        inFlight = nil
        let error = PluginRuntimeError.timedOut
        let action = current.entry.call ?? self.action
        self.error = ActionFailure(pluginID: action.pluginID, actionID: action.id,
                                   category: error.failureCategory, message: error.description)
        errorEvent = current.entry.event
        present()
        finished(current.entry, .failed(error.description))
        dispatchNext()
    }

    private func receive(_ outcome: ActionOutcome, for dispatched: Int) {
        guard !isEnded, let current = inFlight, current.generation == dispatched else { return }
        inFlight = nil
        let event = current.entry.event
        // The answer is read under the Action that generated it: a call's
        // own, else the handler's.
        let action = current.entry.call ?? self.action
        switch outcome.terminal {
        case .succeeded(let value):
            let answer: PluginScriptAnswer
            do {
                answer = try PluginScriptAnswer(parsing: value, answering: event, permits: permits)
                if let view = answer.view { try readView(action, view) }
            } catch {
                let violation = error as? PluginRuntimeError ?? .protocolViolation("The script's answer is invalid")
                finished(current.entry, nil)
                end(.failed(ActionFailure(pluginID: outcome.pluginID, actionID: outcome.actionID,
                                          category: violation.failureCategory, message: violation.description)))
                return
            }
            if let operation = answer.operation {
                // A refused Capability or System Permission refuses the whole
                // answer, as a refused Host Service refuses an invocation:
                // the last good view and state stay, and nothing is requested.
                do {
                    guard let operations else {
                        throw PluginHostServiceError.unavailable("This Host performs no Requested Host Operations")
                    }
                    try operations.authorize(operation, for: action)
                } catch {
                    let refusal = error as? PluginHostServiceError ?? .failed(error.localizedDescription)
                    self.error = ActionFailure(pluginID: action.pluginID, actionID: action.id,
                                               category: refusal.actionFailureCategory, message: refusal.description)
                    errorEvent = event
                    present()
                    finished(current.entry, .failed(refusal.description))
                    dispatchNext()
                    return
                }
            }
            if answer.close {
                finished(current.entry, .answered)
                end(.closedByPlugin)
                if let toast = answer.toast { showFeedback(toast) }
                return
            }
            if let description = answer.description {
                // Only a view or page commits a call's Action as handler.
                if current.entry.call != nil { handOver(to: action) }
                self.view = description
                page = answer.page
                identity.show(answer.page)
                state = answer.state
                viewRevision += 1
                answeredEvent = event
            }
            error = nil
            errorEvent = nil
            present()
            showToast(answer.toast)
            // The request commits in the same turn as the view and state, so
            // nothing can see one without the other.
            if let operation = answer.operation {
                operations?.commit(operation, for: action, owner: self, target: current.entry.insertionTarget)
            }
            finished(current.entry, .answered)
        case .failed(let failure):
            guard failure.category != .runtimeProtocolFailed else {
                finished(current.entry, nil)
                end(.failed(failure))
                return
            }
            // A refusal, a crash, a timeout or a script error keeps the view
            // and the last good state; the next event may succeed.
            error = failure
            errorEvent = event
            present()
            finished(current.entry, .failed(failure.message))
        }
        dispatchNext()
    }

    /// A call's answer committed a view: its Action handles the session
    /// from now on. Another Command's view may not rely on what the first
    /// one was allowed to fetch, so its sections end. Events of a Level 1
    /// view, which have no page provenance, are dropped as when Level 1
    /// presents again, a delivery to be redelivered if its section is still
    /// shown; page events keep their provenance, and calls, Settings
    /// notifications and results stay.
    private func handOver(to caller: ActionConfiguration) {
        if caller.commandID != action.commandID { commandChanged() }
        action = caller
        let (dropped, kept) = queue.partitioned { $0.isLevelOneViewEvent }
        queue = kept
        if let pending = debouncing, pending.isLevelOneViewEvent {
            debouncing = nil
            debounceToken += 1
        }
        for case .sectionDelivered(let section, let response) in dropped.map(\.event) {
            sectionDelivery(section, response, .abandoned)
        }
    }

    /// An event's invocation ended: a section delivery hears how, and the
    /// Plugin's operation slot, held while it answered a result, frees.
    private func finished(_ entry: Entry, _ outcome: HostFetchedSections.Delivery?) {
        if let result = entry.result { operations?.resultAnswered(pluginID, serial: result.serial) }
        guard let outcome, !isEnded, case .sectionDelivered(let section, let response) = entry.event else { return }
        sectionDelivery(section, response, outcome)
    }

    // MARK: Requested Host Operations

    func setPerformingOperation(_ performing: Bool) {
        guard !isEnded, isPerformingOperation != performing else { return }
        isPerformingOperation = performing
        present()
    }

    /// Shows a committed operation's outcome where the user is looking: a
    /// refusal or failure inline with its repair route, and a success that
    /// asked to close the view by closing it.
    func show(_ result: HostOperationResult, of operation: RequestedHostOperation, for requester: ActionConfiguration) {
        guard !isEnded else { return }
        if let failure = result.failure(for: requester) {
            error = failure
            errorEvent = nil
            present()
        } else if operation.closesView {
            end(.closedByPlugin)
        }
    }

    /// Queues `operation_finished` for the Action that requested it, behind
    /// the events already waiting and ahead of any gesture that waits for
    /// the operation slot.
    func deliver(_ event: PluginViewEvent, answering serial: Int, requestedBy requester: ActionConfiguration) {
        guard !isEnded else {
            operations?.resultAnswered(pluginID, serial: serial)
            return
        }
        enqueue(Entry(event, result: (serial, requester)))
        dispatchNext()
    }

    private func queueResult(_ entry: Entry) {
        guard let result = entry.result else { return }
        if action.isSameConfiguration(as: result.requestedBy) {
            enqueue(entry)
            dispatchNext()
        } else {
            operations?.resultAnswered(pluginID, serial: result.serial)
        }
    }
}

/// The View Sessions of every Plugin, at most one each. It reads the answer
/// an Action's first invocation gave, starts, replaces or closes the
/// Plugin's session from it, and ends a session when its Plugin changes or
/// loses a Capability.
public final class PluginViewSessions {
    private let renderer: PluginViewRenderer
    private let runEvent: PluginViewSession.RunEvent
    private let readView: PluginViewSession.ReadView
    private let schedule: PluginViewSession.Schedule
    private let showFeedback: (String) -> Void
    private let fetchedSections: HostFetchedSections?
    private let permitting: PluginViewSession.Permitting
    /// The Requested Host Operations of every Plugin, when the Host was
    /// given something to perform them.
    private let operations: HostOperationRequests?
    /// Tells the user of an outcome no view shows.
    private let report: (ActionConfiguration, String) -> Void
    private var sessions: [PluginID: PluginViewSession] = [:]
    private var registry: PluginRegistry?
    private var grantStore: PluginCapabilityGrantStore?
    private var registryObserver: UUID?
    private var grantObserver: UUID?

    /// `showFeedback` shows a toast without a view as the Host's feedback
    /// near the pointer. `readView` reads every view before it is drawn, so
    /// one the renderer could not draw is the script's protocol violation;
    /// by default any object passes. `fetchedSections` sends the Host-Fetched
    /// Sections of these sessions' views; it delivers responses through them,
    /// and every session that ends cancels its sections.
    ///
    /// `permitting` says which interface members an Action's Plugin may use,
    /// so a Plugin declaring `host_operations` may answer a gesture with an
    /// operation, which `operations` checks and performs after the answer
    /// commits; `reportOperation` tells the user of an outcome no view
    /// shows, by default as feedback near the pointer.
    public init(renderer: PluginViewRenderer, runEvent: @escaping PluginViewSession.RunEvent,
                schedule: @escaping PluginViewSession.Schedule, showFeedback: @escaping (String) -> Void,
                readView: @escaping PluginViewSession.ReadView = { _, _ in },
                fetchedSections: HostFetchedSections? = nil,
                permitting: @escaping PluginViewSession.Permitting = { _ in { _ in false } },
                operations performer: HostOperationPerformer? = nil,
                reportOperation: ((ActionConfiguration, String) -> Void)? = nil) {
        self.renderer = renderer
        self.runEvent = runEvent
        self.readView = readView
        self.schedule = schedule
        self.showFeedback = showFeedback
        self.fetchedSections = fetchedSections
        self.permitting = permitting
        let report = reportOperation ?? { _, message in showFeedback(message) }
        self.report = report
        operations = performer.map {
            HostOperationRequests(performer: $0, schedule: schedule, report: report)
        }
        fetchedSections?.sessions = self
        operations?.onSlotFree = { [weak self] pluginID in self?.sessions[pluginID]?.dispatchNext() }
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

    /// Runs `work`, such as an Action's start from the Menu, once the Plugin
    /// has no Requested Host Operation outstanding: a gesture waits behind
    /// one. Runs it at once when there is none.
    public func whenOperationSlotFree(for pluginID: PluginID, _ work: @escaping () -> Void) {
        guard let operations else { return work() }
        operations.whenFree(pluginID, work)
    }

    /// Calls `action` into its Plugin's open View Session and says whether
    /// the session took it. A Plugin declaring `collections` r2 takes every
    /// explicit call of a scripted Action while its session is open: the
    /// call is queued as `called` and the view comes forward. Otherwise,
    /// with no session open, for a Plugin under Level 1's rule, and for a
    /// Host Command, which keeps its native path, the caller starts the
    /// Action as usual, and an answer with a view replaces the session's.
    public func call(_ action: ActionConfiguration) -> Bool {
        guard action.execution == .javascript, let session = sessions[action.pluginID], !session.isEnded,
              permitting(action)(CollectionsContract.repeatedCallsIntoSession) else { return false }
        session.call(action)
        return true
    }

    /// Acts on what the Action's first invocation answered and says whether
    /// that showed the user anything: a view, a closed view, or a toast.
    /// Throws a protocol violation, and starts nothing, for a value that is
    /// no answer.
    ///
    /// An answer that requests an operation commits it with the view it
    /// shows, if any, which then owns it. Nothing was shown where text would
    /// go when the Action started, so an insertion it requests is refused.
    /// A refused Capability or System Permission refuses the whole answer:
    /// this throws the `PluginHostServiceError`, and nothing is shown.
    @discardableResult
    public func actionAnswered(_ action: ActionConfiguration, with value: JSONValue) throws -> Bool {
        let permits = permitting(action)
        let answer = try PluginScriptAnswer(parsing: value, permits: permits)
        if let operation = answer.operation {
            guard let operations else {
                throw PluginHostServiceError.unavailable("This Host performs no Requested Host Operations")
            }
            if let view = answer.view { try readView(action, view) }
            try operations.authorize(operation, for: action)
        }
        let existing = sessions[action.pluginID]
        if let view = answer.description {
            if answer.page == nil { try readView(action, view) }
            if let existing {
                // Another Command's view may not rely on what the first one
                // was allowed to fetch.
                if existing.action.commandID != action.commandID {
                    fetchedSections?.end(pluginID: action.pluginID)
                }
                existing.replace(action: action, view: view, page: answer.page, state: answer.state)
                existing.showToast(answer.toast)
                commit(answer.operation, for: action, owner: existing)
                return true
            }
            let pluginID = action.pluginID
            let session = PluginViewSession(action: action, view: view, page: answer.page, state: answer.state,
                                            renderer: renderer,
                                            runEvent: runEvent, readView: readView, schedule: schedule,
                                            showFeedback: showFeedback,
                                            sectionDelivery: { [weak fetchedSections] section, response, outcome in
                                                fetchedSections?.delivery(of: section, response: response,
                                                                          for: pluginID, outcome)
                                            },
                                            permits: permits,
                                            operations: operations,
                                            reportCall: report,
                                            commandChanged: { [weak fetchedSections] in
                                                fetchedSections?.end(pluginID: pluginID)
                                            },
                                            onEnd: { [weak self] ended in
                                                guard self?.sessions[ended.pluginID] === ended else { return }
                                                self?.sessions.removeValue(forKey: ended.pluginID)
                                                self?.fetchedSections?.end(pluginID: ended.pluginID)
                                            })
            sessions[action.pluginID] = session
            session.present()
            session.showToast(answer.toast)
            commit(answer.operation, for: action, owner: session)
            return true
        }
        if answer.close { existing?.end(.closedByPlugin) }
        if let toast = answer.toast { showFeedback(toast) }
        // Without a view the request belongs to the Action alone; the Host
        // shows its outcome near the pointer.
        commit(answer.operation, for: action, owner: nil)
        return answer.toast != nil || (answer.close && existing != nil) || answer.operation != nil
    }

    private func commit(_ operation: RequestedHostOperation?, for action: ActionConfiguration, owner: PluginViewSession?) {
        guard let operation else { return }
        operations?.commit(operation, for: action, owner: owner, target: .notShown)
    }

    /// Ends the Plugin's session, and when its Plugin changed or lost a
    /// Capability cancels its requests that have not started, a view's or not.
    public func end(pluginID: PluginID, because reason: PluginViewSessionEnd) {
        sessions[pluginID]?.end(reason)
        if reason == .pluginChanged || reason == .capabilityRevoked {
            operations?.cancelWaiting(of: pluginID, because: reason)
        }
    }
}

/// Which View Page is on screen and which instance of each of its
/// components, so an event of a page reaches the script only while the page
/// and the component it was made in are unchanged: same page ID, not reset,
/// the component still there with the same kind and not reset since.
/// Changing page and coming back is a new instance of the page.
struct PageIdentity {
    struct Stamp: Equatable {
        let page: Int
        let component: String
        let instance: Int
    }

    private(set) var pageID: String?
    private var pageInstance = 0
    private var components: [String: (kind: PluginPageComponent.Kind, instance: Int)] = [:]
    private var counter = 0

    /// A page, or a Level 1 view when nil, was committed.
    mutating func show(_ page: PluginPage?) {
        guard let page else {
            pageID = nil
            counter += 1
            pageInstance = counter
            components = [:]
            return
        }
        if pageID != page.id || page.reset == .page {
            counter += 1
            pageInstance = counter
            components = [:]
        }
        pageID = page.id
        var shown: [String: (kind: PluginPageComponent.Kind, instance: Int)] = [:]
        for component in page.components {
            if let kept = components[component.id], kept.kind == component.kind, page.reset?.resets(component.id) != true {
                shown[component.id] = kept
            } else {
                counter += 1
                shown[component.id] = (component.kind, counter)
            }
        }
        components = shown
    }

    func stamp(page: String, component: String) -> Stamp? {
        guard pageID == page, let shown = components[component] else { return nil }
        return Stamp(page: pageInstance, component: component, instance: shown.instance)
    }

    func isCurrent(_ stamp: Stamp) -> Bool {
        stamp.page == pageInstance && components[stamp.component]?.instance == stamp.instance
    }
}
