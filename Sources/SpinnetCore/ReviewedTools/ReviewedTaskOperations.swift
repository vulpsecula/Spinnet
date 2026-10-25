import Foundation

/// Trusted confirmation and current ownership for a task-start request.
/// Only the start outcome belongs to the View Session; the Task belongs
/// to the Host and reports its eventual end through activities.
public final class ReviewedTaskOperationPerformer {
    private struct Waiting {
        let serial: UUID
        let plan: HomebrewTaskPlan
        let action: ActionConfiguration
        let generation: Int
        let completion: (HostOperationResult) -> Void
        let progress: (String) -> Void
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
                        authorize: @escaping () throws -> Void, progress: @escaping (String) -> Void = { _ in },
                        completion: @escaping (HostOperationResult) -> Void) {
        guard case .reviewedTaskOwner(let registration?, let generation) = accepted,
              let package = registry.package(for: action.pluginID) else {
            return completion(.init(.refused(.commandUnavailable), message: "The Task owner was not current when accepted"))
        }
        do {
            try HomebrewAutoremove.check(input.json, service: ReviewedToolTasksAddition.id, manifest: package.manifest)
            try HomebrewCatalogRefresh.check(input.json, manifest: package.manifest)
        }
        catch { return completion(.refusal(error)) }
        let operationGeneration = generations[action.pluginID, default: 0]
        progress("Preparing Homebrew…")
        let preparing: (String) -> Void = { [weak self] message in
            self?.executor { [weak self] in
                guard let self, self.generations[action.pluginID, default: 0] == operationGeneration else { return }
                progress(message)
            }
        }
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
                    scope: package.manifest.scope(for: .runReviewedToolTasks), progress: preparing, authorize: currentAuthority)
                self.executor {
                    guard self.generations[action.pluginID, default: 0] == operationGeneration else {
                        self.tasks.decline(plan); completion(.init(.cancelled)); return
                    }
                    do { try currentAuthority() } catch { self.tasks.decline(plan); completion(.refusal(error)); return }
                    if input.operation == HomebrewCatalogRefresh.operation {
                        progress("Starting Homebrew catalog update…")
                        // The distinct refreshCatalog scope is the user's
                        // consent for automatic entry updates. It never admits
                        // a package change or accepts caller-supplied flags.
                        self.background {
                            do {
                                _ = try self.tasks.launch(plan, authorize: currentAuthority)
                                self.executor { completion(.init(.succeeded)) }
                            } catch {
                                self.executor {
                                    completion(self.generations[action.pluginID, default: 0] == operationGeneration ? .refusal(error) : .init(.cancelled))
                                }
                            }
                        }
                    } else {
                        self.present(plan, for: action, generation: operationGeneration, authorize: currentAuthority, progress: progress, completion: completion)
                    }
                }
            } catch { self.executor { completion(.refusal(error)) } }
        }
    }
    private func present(_ plan: HomebrewTaskPlan, for action: ActionConfiguration, generation: Int,
                         authorize: @escaping () throws -> Void, progress: @escaping (String) -> Void,
                         completion: @escaping (HostOperationResult) -> Void) {
        let serial = UUID()
        progress("Waiting for your confirmation…")
        waiting[action.pluginID] = Waiting(serial: serial, plan: plan, action: action, generation: generation, completion: completion, progress: progress, cancel: {})
        let cancel = confirmations.confirm(plan.confirmation, for: action) { [weak self] answer in
            self?.answered(action.pluginID, serial: serial, answer: answer, authorize: authorize)
        }
        if let held = waiting[action.pluginID], held.serial == serial {
            waiting[action.pluginID] = Waiting(serial: serial, plan: plan, action: action, generation: generation, completion: completion, progress: progress, cancel: cancel)
        } else { cancel() }
        schedule(HostConfirmation.expiry) { [weak self] in
            guard let self, let held = self.waiting[action.pluginID], held.serial == serial else { return }
            self.waiting[action.pluginID] = nil; held.cancel(); self.tasks.decline(held.plan); held.completion(.init(.expired))
        }
    }
    private func answered(_ owner: PluginID, serial: UUID, answer: HostConfirmationAnswer, authorize: @escaping () throws -> Void) {
        guard let pending = waiting[owner], pending.serial == serial else { return }
        waiting[owner] = nil; pending.cancel()
        switch answer {
        case .confirmed:
            pending.progress(pending.plan.requiresNativeInspection ? "Inspecting installed package files…" : "Starting Homebrew…")
            background { [weak self] in
                guard let self else { return }
                do {
                    if pending.plan.requiresNativeInspection {
                        let final = try self.tasks.completeInspection(pending.plan, authorize: authorize)
                        self.executor {
                            guard self.generations[owner, default: 0] == pending.generation else {
                                self.tasks.decline(final); pending.completion(.init(.cancelled)); return
                            }
                            do { try authorize() } catch { self.tasks.decline(final); pending.completion(.refusal(error)); return }
                            self.present(final, for: pending.action, generation: pending.generation, authorize: authorize, progress: pending.progress, completion: pending.completion)
                        }
                    } else {
                        _ = try self.tasks.launch(pending.plan, authorize: authorize)
                        self.executor { pending.completion(.init(.succeeded)) }
                    }
                } catch {
                    self.executor {
                        pending.completion(self.generations[owner, default: 0] == pending.generation ? .refusal(error) : .init(.cancelled))
                    }
                }
            }
        case .declined: tasks.decline(pending.plan); pending.completion(.init(.declined))
        }
    }
    public func abandon(_ owner: PluginID, because reason: PluginViewSessionEnd) {
        generations[owner, default: 0] += 1
        tasks.cancelPending(for: owner)
        if let pending = waiting.removeValue(forKey: owner) {
            pending.cancel(); tasks.decline(pending.plan); pending.completion(.init(.cancelled))
        }
    }
}
