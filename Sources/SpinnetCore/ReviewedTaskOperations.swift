import Foundation

/// Trusted confirmation and current ownership for a task-start request.
/// Only the start outcome belongs to the View Session; the Task belongs
/// to the Host and reports its eventual end through activities.
public final class ReviewedTaskOperationPerformer {
    private struct Waiting {
        let serial: UUID
        let plan: HomebrewTaskPlan
        let completion: (HostOperationResult) -> Void
        let cancel: () -> Void
    }
    private let tasks: HostReviewedToolTasks
    private let confirmations: HostConfirming
    private let registry: PluginRegistry
    private let background: (@escaping () -> Void) -> Void
    private let executor: (@escaping () -> Void) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var waiting: [PluginID: Waiting] = [:]
    private var generations: [PluginID: Int] = [:]
    public init(tasks: HostReviewedToolTasks, confirmations: HostConfirming, registry: PluginRegistry,
                background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
                executor: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }) {
        self.tasks = tasks; self.confirmations = confirmations; self.registry = registry
        self.background = background; self.executor = executor; self.schedule = schedule
    }
    public func accept(owner: PluginID) -> AcceptedHostOperationTarget {
        .reviewedTaskOwner(registry.ownerAdmission(for: owner), tasks.ownerGeneration(owner))
    }
    public func perform(_ input: HomebrewTaskInput, for action: ActionConfiguration, accepted: AcceptedHostOperationTarget,
                        authorize: @escaping () throws -> Void, completion: @escaping (HostOperationResult) -> Void) {
        guard case .reviewedTaskOwner(let registration?, let generation) = accepted,
              let package = registry.package(for: action.pluginID) else {
            return completion(.init(.refused(.commandUnavailable), message: "The Task owner was not current when accepted"))
        }
        let operationGeneration = generations[action.pluginID, default: 0]
        let currentAuthority = { [self] in
            guard registry.isCurrent(registration, for: package), tasks.ownerGeneration(action.pluginID) == generation else {
                throw PluginHostServiceError.unavailable("The accepted Task authority changed")
            }
            try authorize()
        }
        background { [weak self] in
            guard let self else { return }
            do {
                let plan = try self.tasks.prepare(input, owner: action.pluginID, pluginName: package.manifest.name,
                    scope: package.manifest.scope(for: .runReviewedToolTasks), authorize: currentAuthority)
                self.executor {
                    guard self.generations[action.pluginID, default: 0] == operationGeneration else {
                        self.tasks.decline(plan); completion(.init(.cancelled)); return
                    }
                    do { try currentAuthority() } catch { self.tasks.decline(plan); completion(.refusal(error)); return }
                    let serial = UUID()
                    // Reserve before presenting because a recorded/system
                    // confirmation may answer synchronously.
                    self.waiting[action.pluginID] = Waiting(serial: serial, plan: plan, completion: completion, cancel: {})
                    let cancel = self.confirmations.confirm(plan.confirmation, for: action) { [weak self] answer in
                        self?.answered(action.pluginID, serial: serial, answer: answer, authorize: currentAuthority)
                    }
                    if let held = self.waiting[action.pluginID], held.serial == serial {
                        self.waiting[action.pluginID] = Waiting(serial: serial, plan: plan, completion: completion, cancel: cancel)
                    } else { cancel() }
                    self.schedule(HostConfirmation.expiry) { [weak self] in
                        guard let self, let held = self.waiting[action.pluginID], held.serial == serial else { return }
                        self.waiting[action.pluginID] = nil; held.cancel(); self.tasks.decline(held.plan); held.completion(.init(.expired))
                    }
                }
            } catch { self.executor { completion(.refusal(error)) } }
        }
    }
    private func answered(_ owner: PluginID, serial: UUID, answer: HostConfirmationAnswer, authorize: @escaping () throws -> Void) {
        guard let pending = waiting[owner], pending.serial == serial else { return }
        waiting[owner] = nil; pending.cancel()
        switch answer {
        case .confirmed:
            background { [weak self] in
                guard let self else { return }
                let result: HostOperationResult
                do { _ = try self.tasks.launch(pending.plan, authorize: authorize); result = .init(.succeeded) }
                catch { result = .refusal(error) }
                self.executor { pending.completion(result) }
            }
        case .declined: tasks.decline(pending.plan); pending.completion(.init(.declined))
        }
    }
    public func abandon(_ owner: PluginID, because reason: PluginViewSessionEnd) {
        generations[owner, default: 0] += 1
        if let pending = waiting.removeValue(forKey: owner) {
            pending.cancel(); tasks.decline(pending.plan); pending.completion(.init(.cancelled))
        }
    }
}
