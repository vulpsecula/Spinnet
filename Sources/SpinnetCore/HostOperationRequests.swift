import Foundation

/// What a Requested Host Operation came to: its one outcome, and what the
/// Host shows the user for it. The message may name Apps; it is shown by
/// the Host and never reaches the Plugin.
public struct HostOperationResult: Equatable {
    public let outcome: HostOperationOutcome
    public let message: String?

    public init(_ outcome: HostOperationOutcome, message: String? = nil) {
        self.outcome = outcome
        self.message = message
    }

    /// The refusal of an operation whose authority, read again when it
    /// starts, threw `error`: the reason a call of the same ID fails with,
    /// or `command_unavailable` for a failure without one, such as the
    /// Plugin or its Command gone.
    public static func refusal(_ error: Error) -> HostOperationResult {
        guard let error = error as? PluginHostServiceError else {
            return HostOperationResult(.refused(.commandUnavailable), message: error.localizedDescription)
        }
        let reason = HostOperationReason(error)
        return HostOperationResult(.refused(reason == .hostServiceFailed ? .commandUnavailable : reason),
                                   message: error.description)
    }

    /// The failure to show for an outcome other than success, with the
    /// category that picks its repair route.
    func failure(for action: ActionConfiguration) -> ActionFailure? {
        let category: ActionFailureCategory
        switch outcome {
        case .succeeded: return nil
        // The user declined a Host Confirmation, or closed the view it was
        // in: their own answer needs no word.
        case .declined where message == nil, .cancelled where message == nil: return nil
        case .declined, .expired, .cancelled: category = .cancelled
        case .refused(let reason), .failed(let reason):
            switch reason {
            case .capabilityDenied: category = .capabilityDenied
            case .systemPermissionDenied: category = .systemPermissionDenied
            case .automationPermissionDenied: category = .automationPermissionDenied
            case .externalAppMissing: category = .externalAppMissing
            case .externalAppOperationUnsupported: category = .externalAppOperationUnsupported
            case .commandUnavailable: category = .commandUnavailable
            case .targetChanged: category = .insertionTargetChanged
            case .hostServiceFailed, .targetNotShown, .noTarget, .secureInput, .targetUnresponsive, .targetProtected:
                category = .hostServiceFailed
            }
        }
        return ActionFailure(pluginID: action.pluginID, actionID: action.id, category: category,
                             message: message ?? "\(outcome.name) (\(outcome.reason?.rawValue ?? "no reason"))")
    }
}

/// What performs Requested Host Operations for the View Sessions: in the
/// Host, its broker and desktop. Every call arrives on the sessions'
/// executor, and `perform` calls `completion` back there.
public protocol HostOperationPerformer: AnyObject {
    /// Checks at commit that `action` may request `operation`: its Command
    /// declares the Capability, the user granted it, and macOS grants the
    /// System Permission. Throws what a call of the same ID would.
    func authorize(_ operation: RequestedHostOperation, for action: ActionConfiguration) throws
    /// The Host accepted `operation` for `action`: its answer committed, or
    /// the user chose its page action. Binds what the operation acts on now,
    /// when the operation defines its target so.
    func accept(_ operation: RequestedHostOperation, for action: ActionConfiguration) -> AcceptedHostOperationTarget
    /// Performs a committed operation for `action`: checks its authority and
    /// target again, then performs it and reports one result. `target` is
    /// what the Host showed as where text would go when the user made the
    /// gesture, and `accepted` what `accept` bound.
    func perform(_ operation: RequestedHostOperation, for action: ActionConfiguration,
                 target: InsertionTargetCapture, accepted: AcceptedHostOperationTarget,
                 completion: @escaping (HostOperationResult) -> Void)
    /// The owner of the Plugin's running operation ended, or the Plugin
    /// changed: an operation still waiting for a Host Confirmation stops
    /// waiting and is cancelled. One already performing its effect finishes.
    func abandon(_ pluginID: PluginID, because reason: PluginViewSessionEnd)
}

public extension HostOperationPerformer {
    func accept(_ operation: RequestedHostOperation, for action: ActionConfiguration) -> AcceptedHostOperationTarget {
        .none
    }

    func abandon(_ pluginID: PluginID, because reason: PluginViewSessionEnd) {}
}

/// What the Host bound a request to when it accepted it, before the
/// operation starts.
public enum AcceptedHostOperationTarget: Hashable {
    /// Nothing: the operation names its target in its input, or resolves it
    /// when it starts.
    case none
    /// `apps.quit` and `apps.close`: the App in front when the Host accepted
    /// it, or nil when Spinnet, no App or an App the Host cannot name was.
    /// Without a target, the App it acts on; with one, the App it may close
    /// or quit gracefully without a Host Confirmation.
    case appInFront(RunningAppIdentity?)
    /// #84: ownership/authority captured when the effect request commits,
    /// before waiting or off-main dispatch. No incarnation is refreshed.
    case keepAwakeOwner(KeepAwakeAdmission?)
}

/// The Requested Host Operations of every Plugin (ADR 0018), confined to the
/// View Sessions' executor. Each Plugin has one operation slot: a request
/// holds it from execution until its outcome, and, when it asked to be
/// told, until the invocation answering `operation_finished` ends. Requests
/// committed meanwhile wait in order, and so do gestures. A request belongs
/// to the View Session that committed it, or to nothing when it came
/// without a view; ending the session cancels it unless it is running.
final class HostOperationRequests {
    private struct Request {
        /// The Host's own request ID, never shown to the Plugin: a completion
        /// for any other is stale and ignored.
        let serial: Int
        let operation: RequestedHostOperation
        let action: ActionConfiguration
        weak var owner: PluginViewSession?
        let target: InsertionTargetCapture
        /// What the performer bound when the Host accepted the request.
        let accepted: AcceptedHostOperationTarget
        /// The Plugin declares `host_operations` r2: an outcome it asked to
        /// hear reaches it after its view closed.
        let deliversAfterClose: Bool
        /// The owner's last good state when it ended while this request ran,
        /// and why it ended.
        var ownerEnded: (state: JSONValue, reason: PluginViewSessionEnd)?
    }

    private enum Phase {
        case executing
        /// The outcome was delivered as `operation_finished`; the slot frees
        /// when that invocation ends.
        case awaitingAnswer
    }

    private let performer: HostOperationPerformer
    private let schedule: PluginViewSession.Schedule
    /// Shows an outcome the user could not see in a view, near the pointer.
    private let report: (ActionConfiguration, String) -> Void
    private var serials = 0
    private var active: [PluginID: (request: Request, phase: Phase)] = [:]
    private var waiting: [PluginID: [Request]] = [:]
    private var slotWaiters: [PluginID: [() -> Void]] = [:]
    /// Called once a Plugin's slot is free, so its sessions dispatch the
    /// gestures that waited.
    var onSlotFree: (PluginID) -> Void = { _ in }
    /// Runs `operation_finished` in a viewless invocation of the Action that
    /// requested it, from the state its view last had, and calls back once
    /// that invocation has ended however it ended (`host_operations` r2).
    var deliverAfterClose: (ActionConfiguration, PluginViewEvent, JSONValue, @escaping () -> Void) -> Void = { _, _, _, done in
        done()
    }

    init(performer: HostOperationPerformer, schedule: @escaping PluginViewSession.Schedule,
         report: @escaping (ActionConfiguration, String) -> Void) {
        self.performer = performer
        self.schedule = schedule
        self.report = report
    }

    /// Whether a gesture of the Plugin has to wait.
    func isBusy(_ pluginID: PluginID) -> Bool {
        active[pluginID] != nil || !(waiting[pluginID] ?? []).isEmpty
    }

    /// Runs `work` once the Plugin has no outstanding operation: at once if
    /// it has none now.
    func whenFree(_ pluginID: PluginID, _ work: @escaping () -> Void) {
        guard isBusy(pluginID) else { return work() }
        slotWaiters[pluginID, default: []].append(work)
    }

    func authorize(_ operation: RequestedHostOperation, for action: ActionConfiguration) throws {
        try performer.authorize(operation, for: action)
    }

    /// Takes a request that committed with its answer, binding what it acts
    /// on now. It starts at once when the Plugin's slot is free, in the same
    /// executor turn.
    func commit(_ operation: RequestedHostOperation, for action: ActionConfiguration, owner: PluginViewSession?,
                target: InsertionTargetCapture, deliversAfterClose: Bool = false) {
        serials += 1
        let request = Request(serial: serials, operation: operation, action: action, owner: owner, target: target,
                              accepted: performer.accept(operation, for: action),
                              deliversAfterClose: deliversAfterClose)
        waiting[action.pluginID, default: []].append(request)
        startNext(action.pluginID)
    }

    /// The owning session ended: requests it committed that have not
    /// started are cancelled, and one waiting for its result to be answered
    /// frees the slot. One that runs finishes, its outcome shown by the Host
    /// and, under `host_operations` r2, delivered after the close when it
    /// asked to be told.
    func ownerEnded(_ session: PluginViewSession, because reason: PluginViewSessionEnd) {
        let pluginID = session.pluginID
        let (cancelled, kept) = (waiting[pluginID] ?? []).partitioned { $0.owner === session }
        waiting[pluginID] = kept
        for request in cancelled { cancel(request, because: reason) }
        if var current = active[pluginID], current.request.owner === session {
            if current.phase == .awaitingAnswer {
                return release(pluginID, serial: current.request.serial)
            }
            current.request.ownerEnded = (session.state, reason)
            active[pluginID] = current
            performer.abandon(pluginID, because: reason)
        }
        freeIfIdle(pluginID)
    }

    /// The Plugin was updated, disabled or removed, or lost a Capability:
    /// every request of it that has not started is cancelled, with or
    /// without a view.
    func cancelWaiting(of pluginID: PluginID, because reason: PluginViewSessionEnd) {
        let cancelled = waiting.removeValue(forKey: pluginID) ?? []
        for request in cancelled { cancel(request, because: reason) }
        if active[pluginID]?.phase == .executing { performer.abandon(pluginID, because: reason) }
        freeIfIdle(pluginID)
    }

    /// The invocation answering `operation_finished` ended, whether it
    /// answered, failed, timed out or was dropped.
    func resultAnswered(_ pluginID: PluginID, serial: Int) {
        guard let current = active[pluginID], current.request.serial == serial, current.phase == .awaitingAnswer else { return }
        release(pluginID, serial: serial)
    }

    // MARK: Running

    private func startNext(_ pluginID: PluginID) {
        guard active[pluginID] == nil, var queue = waiting[pluginID], !queue.isEmpty else { return }
        let request = queue.removeFirst()
        waiting[pluginID] = queue
        active[pluginID] = (request, .executing)
        let serial = request.serial
        // The view shows the operation's own busy state once it has run for
        // a while, as an Action shows its progress.
        schedule(ScriptedActionBudgets.progressDelay) { [weak self] in
            guard let self, let current = self.active[pluginID], current.request.serial == serial,
                  current.phase == .executing else { return }
            current.request.owner?.setPerformingOperation(true)
        }
        performer.perform(request.operation, for: request.action, target: request.target,
                          accepted: request.accepted) { [weak self] result in
            self?.finish(pluginID, serial: serial, with: result)
        }
    }

    private func finish(_ pluginID: PluginID, serial: Int, with result: HostOperationResult) {
        // Each request reaches one outcome, reported at most once.
        guard let current = active[pluginID], current.request.serial == serial, current.phase == .executing else { return }
        let request = current.request
        let owner = request.owner.flatMap { $0.isEnded ? nil : $0 }
        owner?.setPerformingOperation(false)
        if let owner {
            owner.show(result, of: request.operation, for: request.action)
        } else if let failure = result.failure(for: request.action) {
            report(request.action, failure.message)
        }
        // Delivered only while the session exists and the requesting Action
        // still handles it, so Commands do not combine authority through
        // shared state.
        if request.operation.notify, let owner, !owner.isEnded, owner.action.isSameConfiguration(as: request.action) {
            active[pluginID] = (request, .awaitingAnswer)
            owner.deliver(.operationFinished(id: request.operation.id, perform: request.operation.perform,
                                             outcome: result.outcome, item: request.operation.item),
                          answering: serial, requestedBy: request.action)
            return
        }
        // Under `host_operations` r2 an outcome whose view closed while the
        // operation ran, by the user, by the Host or by its own
        // `closes_view`, still reaches the Action that asked, once and
        // without a view. One whose Plugin changed, lost a Capability or
        // broke the interface does not. A cancelled operation is never
        // delivered so; closing a view cancels a Host Confirmation in it, so
        // no `declined` or `expired` reaches here after a close either.
        if request.operation.notify, request.deliversAfterClose, result.outcome != .cancelled,
           let ended = active[pluginID]?.request.ownerEnded, ended.reason == .viewClosed || ended.reason == .closedByPlugin {
            active[pluginID]?.phase = .awaitingAnswer
            deliverAfterClose(request.action,
                              .operationFinished(id: request.operation.id, perform: request.operation.perform,
                                                 outcome: result.outcome, viewClosed: true, item: request.operation.item),
                              ended.state) { [weak self] in
                self?.resultAnswered(pluginID, serial: serial)
            }
            return
        }
        release(pluginID, serial: serial)
    }

    private func cancel(_ request: Request, because reason: PluginViewSessionEnd) {
        // The user's own close needs no word; any other end is the Host's
        // doing, which the user should hear of.
        guard reason != .viewClosed else { return }
        let message = request.operation.perform == "selection.replace"
            ? "Nothing was inserted: \(reason.explanation)"
            : "\(request.operation.perform) was cancelled: \(reason.explanation)"
        report(request.action, message)
    }

    private func release(_ pluginID: PluginID, serial: Int) {
        guard active[pluginID]?.request.serial == serial else { return }
        active[pluginID] = nil
        startNext(pluginID)
        freeIfIdle(pluginID)
    }

    private func freeIfIdle(_ pluginID: PluginID) {
        guard !isBusy(pluginID) else { return }
        let waiters = slotWaiters.removeValue(forKey: pluginID) ?? []
        onSlotFree(pluginID)
        waiters.forEach { $0() }
    }
}

extension Array {
    func partitioned(by belongs: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if belongs(element) { matching.append(element) } else { rest.append(element) }
        }
        return (matching, rest)
    }
}
