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

    /// The failure to show for an outcome other than success, with the
    /// category that picks its repair route.
    func failure(for action: ActionConfiguration) -> ActionFailure? {
        let category: ActionFailureCategory
        switch outcome {
        case .succeeded: return nil
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
            case .hostServiceFailed, .targetNotShown, .noTarget, .secureInput, .targetUnresponsive:
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
    /// Performs a committed operation for `action`: checks its authority and
    /// target again, then performs it and reports one result. `target` is
    /// what the Host showed as where text would go when the user made the
    /// gesture.
    func perform(_ operation: RequestedHostOperation, for action: ActionConfiguration,
                 target: InsertionTargetCapture, completion: @escaping (HostOperationResult) -> Void)
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

    /// Takes a request that committed with its answer. It starts at once
    /// when the Plugin's slot is free, in the same executor turn.
    func commit(_ operation: RequestedHostOperation, for action: ActionConfiguration, owner: PluginViewSession?,
                target: InsertionTargetCapture) {
        serials += 1
        let request = Request(serial: serials, operation: operation, action: action, owner: owner, target: target)
        waiting[action.pluginID, default: []].append(request)
        startNext(action.pluginID)
    }

    /// The owning session ended: requests it committed that have not
    /// started are cancelled, and one waiting for its result to be answered
    /// frees the slot. One that runs finishes, its outcome shown by the Host.
    func ownerEnded(_ session: PluginViewSession, because reason: PluginViewSessionEnd) {
        let pluginID = session.pluginID
        let (cancelled, kept) = (waiting[pluginID] ?? []).partitioned { $0.owner === session }
        waiting[pluginID] = kept
        for request in cancelled { cancel(request, because: reason) }
        if let current = active[pluginID], current.request.owner === session, current.phase == .awaitingAnswer {
            release(pluginID, serial: current.request.serial)
        } else {
            freeIfIdle(pluginID)
        }
    }

    /// The Plugin was updated, disabled or removed, or lost a Capability:
    /// every request of it that has not started is cancelled, with or
    /// without a view.
    func cancelWaiting(of pluginID: PluginID, because reason: PluginViewSessionEnd) {
        let cancelled = waiting.removeValue(forKey: pluginID) ?? []
        for request in cancelled { cancel(request, because: reason) }
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
        performer.perform(request.operation, for: request.action, target: request.target) { [weak self] result in
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
                                             outcome: result.outcome),
                          answering: serial, requestedBy: request.action)
        } else {
            release(pluginID, serial: serial)
        }
    }

    private func cancel(_ request: Request, because reason: PluginViewSessionEnd) {
        // The user's own close needs no word; any other end is the Host's
        // doing, which the user should hear of.
        guard reason != .viewClosed else { return }
        let message = request.operation.perform == "selection.replace"
            ? "Nothing was inserted: \(Self.describe(reason))"
            : "\(request.operation.perform) was cancelled: \(Self.describe(reason))"
        report(request.action, message)
    }

    private static func describe(_ reason: PluginViewSessionEnd) -> String {
        switch reason {
        case .viewClosed: return "the view was closed"
        case .closedByPlugin: return "the Plugin closed its view"
        case .pluginChanged: return "the Plugin was updated, disabled or removed"
        case .capabilityRevoked: return "a Capability it uses was revoked"
        case .failed(let failure): return failure.message
        }
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

private extension Array {
    func partitioned(by belongs: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if belongs(element) { matching.append(element) } else { rest.append(element) }
        }
        return (matching, rest)
    }
}
