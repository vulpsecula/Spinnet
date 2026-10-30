import SpinnetCore
import Foundation
import Darwin

public struct HomebrewTaskPlan {
    public let id: UUID
    public let owner: PluginID
    public let pluginName: String
    public let input: HomebrewTaskInput
    public let resolvedInput: HomebrewTaskInput
    public let package: JSONValue
    public let executable: URL
    public var confirmation: HostConfirmation
    public var scope: PluginCapabilityScope? = nil
    public var steps: [HomebrewTaskInput] = []
    /// Immutable discriminator written into a newly admitted runner journal.
    public let executionModel = "native-cli-v1"
    public var activityID: String { "activity_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    let generation: Int
}

/// Host-owned mutation admission, journals and activity projection. Closing
/// or hiding a Plugin View never calls this owner's invalidation methods.
public final class HostReviewedToolTasks {
    public typealias Preflight = (HomebrewTaskInput) throws -> JSONValue
    public typealias CancellablePreflight = (HomebrewTaskInput, HostFetchedSections.Cancellation) throws -> JSONValue
    public typealias TargetResolver = (String, PluginID) throws -> (HomebrewTaskInput, JSONValue)
    private let activities: HostActivities
    private let root: URL
    private let runnerURL: URL
    private let executable: () throws -> URL
    private let preflight: CancellablePreflight
    private let trustedTaps: () throws -> [String]
    private let trustedItems: (String) throws -> [String]
    private let resolveCurrentTrust: ((String, String) throws -> Bool)?
    private let targetResolver: TargetResolver
    private let legacyRecovery: LegacyHomebrewTaskRecovery
    private let hostIsCurrent: () throws -> Void
    private let lock = NSRecursiveLock()
    private var pending: HomebrewTaskPlan?
    private var preparationID: UUID?
    private var pendingCancellation: HostFetchedSections.Cancellation?
    private let recoveryPower: PowerAssertions?
    private var recoveryPowerReleases: [String: () -> Void] = [:]
    private var orphanStopTimes: [String: TimeInterval] = [:]
    private var orphanedTasks = Set<String>()
    private var taskRecoveryUnavailable = false
    private var generations: [PluginID: Int] = [:]
    private var records: [String: HomebrewTaskJournal] = [:]
    private var timer: DispatchSourceTimer?
    private var exiting = false
    private var suddenTerminationAssertions = Set<String>()

    public init(activities: HostActivities, journal: URL, runnerURL: URL,
                executable: @escaping () throws -> URL = HomebrewReadProfile.discover,
                preflight: Preflight? = nil, cancellablePreflight: CancellablePreflight? = nil, trustedTaps: (() throws -> [String])? = nil, trustedItems: ((String) throws -> [String])? = nil,
                targetResolver: @escaping TargetResolver = { _, _ in throw PluginHostServiceError.tool(.planChanged) },
                nativeInspection: HomebrewNativeInspectionTransporting? = HomebrewNativeInspectionTransport(),
                recoveryPower: PowerAssertions? = nil,
                privilegedTaskIsRunning: @escaping (HomebrewPrivilegePlan) throws -> Bool = HomebrewSystemAuthorization.taskIsRunning,
                stopPrivilegedTask: @escaping (HomebrewPrivilegePlan) throws -> Void = HomebrewSystemAuthorization.stopTask,
                hostIsCurrent: @escaping () throws -> Void = { try HostCodeCurrency.verify() }) {
        self.activities = activities; root = journal; self.runnerURL = runnerURL; self.executable = executable
        self.preflight = cancellablePreflight ?? preflight.map { work in { input, _ in try work(input) } }
            ?? { input, cancellation in try Self.preflight(input, executable: executable(), cancellation: cancellation) }
        self.trustedTaps = trustedTaps ?? { try Self.readTrustedTaps(executable: executable()) }
        self.trustedItems = trustedItems ?? { kind in try Self.readTrustedEntries(kind: kind, executable: executable()) }
        self.resolveCurrentTrust = trustedTaps == nil && trustedItems == nil ? { kind, name in
            try HomebrewReadProfile.explicitlyTrusted(name, kind: kind, executable: executable(), deadline: Date().addingTimeInterval(15))
        } : nil
        self.targetResolver = targetResolver
        legacyRecovery = LegacyHomebrewTaskRecovery(activities: activities, journal: journal, transport: nativeInspection,
            isRunning: privilegedTaskIsRunning, stop: stopPrivilegedTask)
        self.recoveryPower = recoveryPower
        self.hostIsCurrent = hostIsCurrent
        recover()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.refresh() }; self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel(); suddenTerminationAssertions.forEach { _ in ProcessInfo.processInfo.enableSuddenTermination() }; recoveryPowerReleases.values.forEach { $0() } }
    /// A recorded result and unresolved execution liveness are independent.
    /// Holding an orphan lane never erases the runner's actual terminal result.
    private func executionHeld(_ record: HomebrewTaskJournal) -> Bool { record.result == nil || orphanedTasks.contains(record.id) }
    public var hasRunningTasks: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending != nil || legacyRecovery.hasPendingInspection || taskRecoveryUnavailable || records.values.contains { executionHeld($0) }
    }
    public func ownerGeneration(_ owner: PluginID) -> Int { lock.lock(); defer { lock.unlock() }; return generations[owner, default: 0] }
    public func prepare(_ input: HomebrewTaskInput, owner: PluginID, pluginName: String,
                        scope: PluginCapabilityScope? = nil,
                        progress: @escaping (String) -> Void = { _ in },
                        authorize: () throws -> Void = {}) throws -> HomebrewTaskPlan {
        if let scope { try input.authorize(in: scope) }
        try authorize()
        // A replaced bundle makes the runner refuse this Host; say so before
        // the user confirms a Task that cannot start.
        try hostIsCurrent()
        lock.lock()
        let locallyBusy = exiting || pending != nil || legacyRecovery.hasPendingInspection || taskRecoveryUnavailable || records.values.contains { executionHeld($0) }
        lock.unlock()
        guard !locallyBusy else { throw PluginHostServiceError.tool(.busy) }
        lock.lock()
        guard !exiting, pending == nil, !legacyRecovery.hasPendingInspection, !taskRecoveryUnavailable, !records.values.contains(where: { executionHeld($0) }) else {
            lock.unlock(); throw PluginHostServiceError.tool(.busy)
        }
        let generation = generations[owner, default: 0]
        // Reserve before any potentially slow preflight or confirmation.
        let id = UUID()
        let reservation = HomebrewTaskPlan(id: id, owner: owner, pluginName: pluginName, input: input, resolvedInput: input,
            package: .null, executable: URL(fileURLWithPath: "/"), confirmation: .init(title: "", message: "", confirmTitle: "", isDestructive: true), generation: generation)
        let cancellation = HostFetchedSections.Cancellation()
        pending = reservation; preparationID = id; pendingCancellation = cancellation; lock.unlock()
        var preparation = ReviewedTaskPreparationDiagnostics(progress: progress)
        do {
            let executable = try self.executable()
            preparation.advance("reading selected package metadata")
            let (resolvedTarget, package) = try review(input, owner: owner, cancellation: cancellation)
            if let scope {
                let concreteSteps = try steps(resolvedTarget, package: package)
                for kind in concreteSteps.isEmpty ? [resolvedTarget.kind] : concreteSteps.map(\.kind) { try input.authorizeResolvedKind(kind, in: scope) }
            }
            guard try JSONEncoder().encode(package).count <= 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            preparation.advance("checking package source trust")
            try checkSource(package)
            try Self.checkOptions(input, package: package, prefix: HomebrewManagementReads.prefix(of: executable), preparing: true)
            if package.value(atPointer: "/privileged_repair") == .bool(true) {
                throw PluginHostServiceError.unavailable("This Doctor repair requires a manual command in Terminal; Spinnet does not run arbitrary elevated repair commands")
            }
            let resolved = try resolvedInput(resolvedTarget, package: package)
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The Task preparation was cancelled") }
            try authorize()
            // The Host shows these words in the interface language; names,
            // versions and sources stay as Homebrew reports them.
            let target = resolved.name.isEmpty ? HostText("eligible %@ packages", .verbatim(resolved.kind)) : .verbatim(resolved.name)
            let from = Self.text(package, "installed_version"), to = Self.text(package, "version"), tap = Self.text(package, "tap")
            var disclosure = [HostText("Homebrew will %@ %@.", HostText(key: input.displayOperation.lowercased(), arguments: []), target)]
            if ["link", "unlink"].contains(input.operation) {
                if !from.isEmpty { disclosure.append(HostText("Installed version: %@.", .verbatim(from))) }
            } else if !from.isEmpty || !to.isEmpty {
                disclosure.append(HostText("Version: %@ → %@.", from.isEmpty ? HostText("not installed") : .verbatim(from),
                                           to.isEmpty ? HostText("current") : .verbatim(to)))
            }
            if !tap.isEmpty { disclosure.append(HostText("Source: %@.", .verbatim(tap))) }
            if ["update", "refreshCatalog"].contains(input.operation) { disclosure = [HostText("Homebrew will update Homebrew itself, all configured taps and package catalogs. This is a global change even when requested from one package. Later package actions reload metadata and recheck source trust. Stopping does not undo an update already applied.")] }
            if ["trust", "tap"].contains(input.operation) { disclosure.append(HostText("This enables third-party code to run with your account's rights. Trust is your explicit choice.")) }
            if input.operation == "untap" || input.operation == "untrust" { disclosure.append(HostText("Existing packages may become unavailable to Homebrew.")) }
            if case .string(let language)? = input.fields["language"] { disclosure.append(HostText("Reinstalls the App with language %@.", .verbatim(language))) }
            if input.fields["zap"] == .bool(true) { disclosure.append(HostText("Zap deletes related settings and files and may delete files shared by Apps.")) }
            if input.operation == "autoremove", case .array(let packages)? = package.value(atPointer: "/packages") {
                let names = packages.compactMap { item -> String? in if case .string(let name)? = item.value(atPointer: "/name") { return name }; return nil }
                disclosure = [HostText("Homebrew will uninstall formulae installed only as dependencies that are no longer needed."),
                              names.count <= 100 ? HostText("Chosen formulae: %@.", .verbatim(names.joined(separator: ", ")))
                                  : HostText("Every chosen formula is listed in the complete review below."),
                              HostText("Cask Apps and packages installed on request are retained. This differs from cleaning old versions and cached downloads.")]
            }
            if input.operation == "cleanup" { disclosure.append(input.fields["pruneAll"] == .bool(true) ? HostText("All eligible Homebrew cache downloads and old package versions may be deleted.") : HostText("Eligible files older than the selected threshold and old package versions may be deleted.")) }
            if input.operation.hasPrefix("service") { disclosure.append(HostText("Changes the selected user-owned service at login; this service may continue after Spinnet exits.")) }
            let reviewedPackages: [JSONValue] = { if case .array(let values)? = package.value(atPointer: "/packages") { return values }; return [package] }()
            if case .string(let summary)? = package.value(atPointer: "/repair_summary") { disclosure.append(.verbatim(summary)) }
            disclosure.append(HostText("Homebrew runs with your account and manages its own installers and scripts. Cask changes first try system Touch ID when available and configured for sudo. If sudo still needs your login password, Spinnet will ask for it in a separate password window. It is passed to sudo and is never shared with the Plugin or saved by Spinnet."))
            if ["upgrade", "upgradeAll", "upgradeSelected", "uninstall", "changeLanguage"].contains(input.operation), reviewedPackages.contains(where: { $0.value(atPointer: "/quits_app") == .bool(true) }) { disclosure.append(HostText("Homebrew may quit the affected App first.")) }
            disclosure.append(HostText("Dependencies and dependents may also change. Stopping does not undo changes. This Task prevents idle system sleep until it ends."))
            var plan = HomebrewTaskPlan(id: id, owner: owner, pluginName: String(pluginName.prefix(256)), input: input,
                resolvedInput: resolved, package: package, executable: executable,
                confirmation: .init(title: HostText("Confirm Homebrew: %@", HostText(key: input.displayOperation, arguments: [])), message: disclosure,
                                    confirmTitle: HostText("Continue"), isDestructive: true), generation: generation)
            plan.scope = scope
            plan.steps = try steps(resolved, package: package)
            if (!plan.steps.isEmpty || input.operation == "upgradeSelected"), input.operation != "doctorFix" {
                let targets = try HomebrewTaskNativeConfirmation.selectedPackages(plan).map(\.name)
                let concrete = targets.count <= 100 ? HostText.verbatim(targets.joined(separator: ", ")) : HostText("Every selected package is listed in the complete review below.")
                plan = HomebrewTaskPlan(id: plan.id, owner: plan.owner, pluginName: plan.pluginName, input: plan.input,
                    resolvedInput: plan.resolvedInput, package: plan.package, executable: plan.executable,
                    confirmation: .init(title: plan.confirmation.titleText, message: [HostText("Chosen packages: %@.", concrete)] + plan.confirmation.messageText,
                        confirmTitle: plan.confirmation.confirmTitleText, isDestructive: true), scope: plan.scope, steps: plan.steps, generation: plan.generation)
            }
            if (!plan.steps.isEmpty || ["upgradeSelected", "autoremove"].contains(input.operation)), plan.confirmation.details == nil {
                let details = try HomebrewTaskNativeConfirmation.details(plan, cancellation: cancellation)
                plan.confirmation = plan.confirmation.with(details: details)
            }
            lock.lock(); defer { lock.unlock() }
            guard pending?.id == id, generations[owner, default: 0] == generation, !exiting else { throw PluginHostServiceError.unavailable("The admitted Task owner changed") }
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The Task preparation was cancelled") }
            pending = plan; preparationID = nil; preparation.finish(succeeded: true); return plan
        } catch {
            preparation.finish(succeeded: false)
            lock.lock(); let held = pending?.id == id ? pending : nil; preparationID = nil; lock.unlock()
            if let held { decline(held) } else { cancellation.cancel() }
            if error as? PluginHostServiceError == .tool(.failed) {
                throw PluginHostServiceError.toolReadFailed("Homebrew failed while \(preparation.stage). No Task was started.")
            }
            throw error
        }
    }
    public func decline(_ plan: HomebrewTaskPlan) {
        lock.lock(); let cancellation = pending?.id == plan.id ? pendingCancellation : nil
        if pending?.id == plan.id, preparationID != plan.id { pending = nil; pendingCancellation = nil }
        lock.unlock(); cancellation?.cancel()
        legacyRecovery.refreshInspection()
    }
    /// Stop pre-admission work, including a prepare call that has not returned
    /// a plan yet. Its reservation remains until the owned operation exits.
    public func cancelPending(for owner: PluginID? = nil) {
        lock.lock()
        guard let plan = pending, owner == nil || plan.owner == owner else { lock.unlock(); return }
        let cancellation = pendingCancellation
        if preparationID != plan.id { pending = nil; pendingCancellation = nil }
        lock.unlock(); cancellation?.cancel()
    }
    @discardableResult
    public func launch(_ plan: HomebrewTaskPlan, authorize: () throws -> Void = {}) throws -> String {
        lock.lock()
        guard pending?.id == plan.id, !exiting, generations[plan.owner, default: 0] == plan.generation,
              let cancellation = pendingCancellation, !cancellation.isCancelled else {
            lock.unlock(); throw PluginHostServiceError.unavailable("The admitted Task owner changed")
        }
        preparationID = plan.id; lock.unlock()
        do {
            try authorize()
            guard try executable() == plan.executable else { throw PluginHostServiceError.tool(.missing) }
            let (resolved, currentPackage) = try review(plan.input, owner: plan.owner, cancellation: cancellation)
            if let scope = plan.scope {
                let concreteSteps = try steps(resolved, package: currentPackage)
                for kind in concreteSteps.isEmpty ? [resolved.kind] : concreteSteps.map(\.kind) { try plan.input.authorizeResolvedKind(kind, in: scope) }
            }
            try checkSource(currentPackage)
            try Self.checkOptions(plan.input, package: currentPackage, prefix: HomebrewManagementReads.prefix(of: plan.executable))
            guard currentPackage == plan.package, try resolvedInput(resolved, package: currentPackage) == plan.resolvedInput else { throw PluginHostServiceError.tool(.planChanged) }
            guard try steps(resolved, package: currentPackage) == plan.steps else { throw PluginHostServiceError.tool(.planChanged) }
            try authorize()
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The Task preparation was cancelled") }
            try hostIsCurrent()
            let id = plan.activityID
            if records.count >= HostActivities.maximumTotal,
               let oldest = records.values.filter({ !executionHeld($0) }).min(by: { ($0.ended ?? $0.started) < ($1.ended ?? $1.started) }) {
                activities.removeEndedTask(oldest.id); records[oldest.id] = nil
                try FileManager.default.removeItem(at: root.appendingPathComponent(oldest.id))
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let directory = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var record = HomebrewTaskJournal(id: id, owner: plan.owner.rawValue, pluginName: plan.pluginName,
                input: plan.resolvedInput.json, package: plan.package, executable: plan.executable.path, started: Date(),
                detached: false, runnerPID: nil, runnerIdentity: nil, processGroup: nil, processIdentity: nil,
                stage: "starting", log: [], result: nil, ended: nil)
            lock.lock(); defer { lock.unlock() }
            guard pending?.id == plan.id, generations[plan.owner, default: 0] == plan.generation, !exiting, !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The admitted Task owner changed") }
            record.executionModel = plan.executionModel
            record.scope = plan.scope
            record.steps = plan.steps.isEmpty ? nil : plan.steps.map(\.json)
            if case .array(let values)? = plan.package.value(atPointer: "/doctor_steps") { record.stepMetadata = values.compactMap { $0.value(atPointer: "/metadata") } }
            try record.save(to: directory)
            // The independent runner replaces this with its own birth-bound
            // identity before reserving any command spawn. A Host crash in the
            // launch gap therefore cannot fabricate an empty execution lane.
            try HomebrewTaskProcessLease(taskID: id, runnerPID: getpid(),
                runnerIdentity: HomebrewTaskProcess.startIdentity(getpid()) ?? 1, runnerLaunchPending: true).save(to: directory)
            // Reserve a visible bounded Host control before spawning. A
            // resource-limit error must never leave a mutating orphan.
            records[id] = record
            do { try register(record) } catch { records[id] = nil; try? FileManager.default.removeItem(at: directory); throw error }
            let process = Process(); process.executableURL = runnerURL; process.arguments = ["--task-directory", directory.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            do { try process.run() } catch {
                records[id] = nil; activities.removeEndedTask(id)
                if suddenTerminationAssertions.remove(id) != nil { ProcessInfo.processInfo.enableSuddenTermination() }
                try? FileManager.default.removeItem(at: directory); throw error
            }
            record.runnerPID = process.processIdentifier; record.runnerIdentity = HomebrewTaskProcess.startIdentity(process.processIdentifier)
            // Runner alone writes task.json once launched. Host metadata is
            // separate so refresh cannot overwrite a just-finished result.
            try? JSONEncoder().encode(JSONValue.object(["pid": .number(Double(process.processIdentifier)), "identity": record.runnerIdentity.map { .number(Double($0)) } ?? .null])).write(to: directory.appendingPathComponent("runner.json"), options: .atomic)
            pending = nil; preparationID = nil; pendingCancellation = nil; records[id] = record
            return id
        } catch {
            lock.lock(); if pending?.id == plan.id { preparationID = nil }; lock.unlock()
            decline(plan); throw error
        }
    }
    public func stop(_ id: String, for owner: PluginID? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[id], owner == nil || (!record.detached && record.owner == owner?.rawValue) else { throw PluginHostServiceError.tool(.taskNotFound) }
        guard executionHeld(record) else { throw PluginHostServiceError.tool(.taskFinished) }
        try Data("stop\n".utf8).write(to: root.appendingPathComponent(id).appendingPathComponent("stop"), options: .atomic)
        if orphanedTasks.contains(id) {
            orphanStopTimes[id] = orphanStopTimes[id] ?? ProcessInfo.processInfo.systemUptime
            stopOrphan(record)
        }
        legacyRecovery.stopPrivilegedExecution(record) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if var current = self.records[id], self.executionHeld(current) {
                current.stage = "Stop attempted; authenticated Root control unavailable; waiting for actual reaping"
                self.records[id] = current; self.publish(current)
            }
        }
    }
    /// A revoked/disabled/removed owner is detached, never stopped or revived
    /// by a regrant. Its confirmed Task remains controllable by the Host.
    public func invalidate(_ owner: PluginID) {
        ownerChanged(owner, scope: nil)
    }
    public func ownerChanged(_ owner: PluginID, scope: PluginCapabilityScope?) {
        lock.lock()
        generations[owner, default: 0] += 1
        let cancellation = pending?.owner == owner ? pendingCancellation : nil
        if pending?.owner == owner, preparationID != pending?.id { pending = nil; pendingCancellation = nil }
        for id in records.keys where records[id]?.owner == owner.rawValue {
            if let scope, records[id]?.scope == scope, records[id]?.detached == false { continue }
            records[id]?.detached = true
            try? Data().write(to: root.appendingPathComponent(id).appendingPathComponent("detached"), options: .atomic)
            if let record = records[id] { publish(record) }
        }
        lock.unlock(); cancellation?.cancel()
    }
    public func revoke(_ revocation: PluginCapabilityRevocation) {
        if revocation.capability == nil || revocation.capability == .runReviewedToolTasks { invalidate(revocation.pluginID) }
    }
    public func beginExit() { lock.lock(); exiting = true; lock.unlock(); cancelPending() }
    public func cancelExit() { lock.lock(); exiting = false; lock.unlock() }
    public func stopAll() { cancelPending(); lock.lock(); let ids = records.values.filter { executionHeld($0) }.map(\.id); lock.unlock(); ids.forEach { try? stop($0) } }
    public func refresh() {
        legacyRecovery.refreshInspection()
        lock.lock(); defer { lock.unlock() }
        for (id, held) in records {
            let directory = root.appendingPathComponent(id)
            guard var current = try? HomebrewTaskJournal.load(from: directory) else { continue }
            current.detached = held.detached || FileManager.default.fileExists(atPath: directory.appendingPathComponent("detached").path)
            let activeLease = (try? HomebrewTaskProcessLease.load(from: directory)).map { !$0.provesNoOwnedExecution } ?? false
            let rootPending = legacyRecovery.mayHavePrivilegedExecution(current)
            // Terminal output can be committed before the runner exits. Its
            // unresolved lease/Root work still owns the lane and Host Stop.
            if current.result != nil && (activeLease || rootPending) { orphanedTasks.insert(id) }
            if current.result == nil || orphanedTasks.contains(id) || activeLease || rootPending {
                let runnerPID = held.runnerPID ?? current.runnerPID
                let identity = held.runnerIdentity ?? current.runnerIdentity
                if let runnerPID, let identity, HomebrewTaskProcess.startIdentity(runnerPID) != identity {
                    reconcileLostRunner(&current, directory: directory)
                }
            }
            if orphanedTasks.contains(id) { reconcileLostRunner(&current, directory: directory) }
            // After authenticated Root idleness AND an actually reaped runner,
            // legacy history must not require that daemon on every later Host
            // launch. Keep the outcome/output, retire only the spent authority.
            if !executionHeld(current), legacyRecovery.privilegePlanIsProvenIdle(current),
               let lease = try? HomebrewTaskProcessLease.load(from: directory), lease.provesNoOwnedExecution,
               lease.runnerPID == current.runnerPID, lease.runnerIdentity == current.runnerIdentity,
               HomebrewTaskProcess.startIdentity(lease.runnerPID) != lease.runnerIdentity {
                current.privilegePlan = nil
                try? current.save(to: directory)
            }
            records[id] = current; publish(current)
            if !executionHeld(current), suddenTerminationAssertions.remove(id) != nil { ProcessInfo.processInfo.enableSuddenTermination() }
            if !executionHeld(current) { recoveryPowerReleases.removeValue(forKey: id)?(); orphanedTasks.remove(id); orphanStopTimes[id] = nil }
        }
    }
    private func register(_ record: HomebrewTaskJournal) throws {
        let id = record.id
        _ = try activities.register(owner: PluginID(record.owner), pluginName: record.pluginName, kind: "task", status: "Starting — prevents idle system sleep",
            id: id, removesOnStop: false, onClear: { [weak self] in self?.clearHistory(id) }) { [weak self] in try? self?.stop(id) }
        publish(record)
        if executionHeld(record), suddenTerminationAssertions.insert(record.id).inserted { ProcessInfo.processInfo.disableSuddenTermination() }
    }
    private func clearHistory(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[id], !executionHeld(record) else { return }
        records[id] = nil
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }
    private func publish(_ record: HomebrewTaskJournal) {
        let stopping = FileManager.default.fileExists(atPath: root.appendingPathComponent(record.id).appendingPathComponent("stop").path)
        let held = executionHeld(record)
        let state = held ? stopping ? "stopping" : "running" : "ended"
        let input = try? HomebrewTaskInput(record.input)
        let preventsSleep = held && (!orphanedTasks.contains(record.id) || recoveryPowerReleases[record.id] != nil)
        var detail: [String: JSONValue] = ["id": .string(record.id), "kind": .string("task"), "tool": .string("homebrew"),
            "name": .string(String("\(input?.displayOperation ?? "Task") \(input?.name ?? "")".prefix(256))), "status": .string(state),
            "operation": .string(input?.operation ?? "unknown"), "stage": .string(stopping && held ? "stopping" : record.stage),
            "elapsed_seconds": .number(max(0, (held ? Date() : record.ended ?? Date()).timeIntervalSince(record.started)).rounded(.down)),
            "log": .array(record.log.suffix(20).map { .string(String($0.prefix(200))) }), "prevents_idle_sleep": .bool(preventsSleep)]
        if let input, !input.name.isEmpty { detail["package"] = .object(["name": .string(input.name), "kind": .string(input.kind)]) }
        if let output = record.output {
            detail["output"] = .string(HomebrewCommandOutput.tail(output))
            detail["output_truncated"] = .bool(record.outputTruncated ?? false)
        }
        if !held, let result = record.result { detail["result"] = result }
        activities.updateTask(record.id, status: held ? "\(state.capitalized): \(record.stage)" + (preventsSleep ? " — prevents idle system sleep" : " — idle sleep prevention unavailable") : "Ended: \(Self.text(record.result ?? .null, "outcome"))", detail: .object(detail), detached: record.detached)
    }
    private func recover() {
        var info = stat()
        if lstat(root.path, &info) != 0, errno == ENOENT { return }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { incompleteRecovery(); return }
        guard let inventory = fdopendir(fd) else { close(fd); incompleteRecovery(); return }
        defer { closedir(inventory) }
        var candidates: [URL] = [], inspected = 0
        while true {
            errno = 0
            guard let entry = readdir(inventory) else {
                if errno != 0 { incompleteRecovery(); return }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            inspected += 1
            guard inspected <= HomebrewTaskProcessLease.maximumRecoveryEntries else { incompleteRecovery(); return }
            if name.hasPrefix("activity_") {
                var child = stat()
                guard fstatat(fd, name, &child, AT_SYMLINK_NOFOLLOW) == 0, child.st_mode & S_IFMT == S_IFDIR,
                      candidates.count < HostActivities.maximumTotal else { incompleteRecovery(); return }
                candidates.append(root.appendingPathComponent(name))
            }
        }
        for directory in candidates {
            guard var record = try? HomebrewTaskJournal.load(from: directory), record.id == directory.lastPathComponent else { incompleteRecovery(); continue }
            do {
                if let runner = try HomebrewTaskProcessLease.loadRunnerIdentity(from: directory) {
                    record.runnerPID = runner.pid; record.runnerIdentity = runner.identity
                }
            } catch { incompleteRecovery(); continue }
            record.detached = FileManager.default.fileExists(atPath: directory.appendingPathComponent("detached").path)
            let activeLease = (try? HomebrewTaskProcessLease.load(from: directory)).map { !$0.provesNoOwnedExecution } ?? false
            let rootPending = record.privilegePlan?.requiresSystemAuthorization == true
            let terminalExecutionHeld = record.result != nil && (activeLease || rootPending)
            if record.result == nil || activeLease || rootPending,
               terminalExecutionHeld || record.runnerPID == nil || record.runnerIdentity == nil || HomebrewTaskProcess.startIdentity(record.runnerPID!) != record.runnerIdentity {
                reconcileLostRunner(&record, directory: directory)
            }
            records[record.id] = record
        }
        // Active Stop controls have priority over history within the same
        // bounded Host Activity inventory. No active record is silently idle.
        for record in records.values.sorted(by: { (executionHeld($0) ? 0 : 1, $0.started) < (executionHeld($1) ? 0 : 1, $1.started) }) {
            do { try register(record) }
            catch { if executionHeld(record) { incompleteRecovery() } }
        }
    }
    private func incompleteRecovery() {
        guard !taskRecoveryUnavailable else { return }
        taskRecoveryUnavailable = true
        if let recoveryPower {
            recoveryPowerReleases["incomplete-inventory"] = try? recoveryPower.acquire(.idleSystem, reason: "Spinnet incomplete Task recovery")
        }
        let sleep = recoveryPowerReleases["incomplete-inventory"] != nil ? "prevents idle system sleep" : "idle sleep prevention unavailable"
        _ = try? activities.register(owner: .init("host-task-recovery"), pluginName: "Homebrew", kind: "native_lane",
            status: "Task recovery inventory incomplete; new work blocked; Stop ownership unavailable; no replay; " + sleep,
            visibleToOwner: false, removesOnStop: false, stop: {})
    }
    private func reconcileLostRunner(_ record: inout HomebrewTaskJournal, directory: URL) {
        let lease = try? HomebrewTaskProcessLease.load(from: directory)
        let sameRunner = lease?.runnerPID == record.runnerPID && lease?.runnerIdentity == record.runnerIdentity
        let rootBusy = legacyRecovery.mayHavePrivilegedExecution(record, refresh: true)
        if sameRunner, lease?.provesNoOwnedExecution == true, !rootBusy {
            if record.result == nil { record.result = .object(["outcome": .string("unknown")]); record.ended = Date() }
            orphanedTasks.remove(record.id); recoveryPowerReleases.removeValue(forKey: record.id)?()
        } else {
            orphanedTasks.insert(record.id)
            let runnerAlive = record.runnerPID.flatMap { HomebrewTaskProcess.startIdentity($0) }.map { $0 == record.runnerIdentity } ?? false
            record.stage = "unknown: \(runnerAlive ? "execution ownership unresolved" : "runner lost"); waiting for independently proven process reaping; no replay"
            if recoveryPowerReleases[record.id] == nil, let recoveryPower {
                do { recoveryPowerReleases[record.id] = try recoveryPower.acquire(.idleSystem, reason: "Spinnet Homebrew Task recovery") }
                catch { record.stage += "; idle sleep prevention unavailable" }
            }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
                orphanStopTimes[record.id] = orphanStopTimes[record.id] ?? ProcessInfo.processInfo.systemUptime
                stopOrphan(record)
            }
        }
        try? record.save(to: directory)
    }
    private func stopOrphan(_ record: HomebrewTaskJournal) {
        guard let lease = try? HomebrewTaskProcessLease.load(from: root.appendingPathComponent(record.id)),
              lease.runnerPID == record.runnerPID, lease.runnerIdentity == record.runnerIdentity else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - (orphanStopTimes[record.id] ?? ProcessInfo.processInfo.systemUptime)
        let signal = elapsed < 10 ? SIGINT : elapsed < 15 ? SIGTERM : SIGKILL
        // The user-owned recovery file carries no Root admission. These are
        // exact same-account PID births; an absent/unknown PID never grants
        // authority over a numeric process group or an unrelated process.
        lease.stopVerifiedMembers(signal: signal)
    }
    private func checkSource(_ package: JSONValue) throws {
        if case .array(let packages)? = package.value(atPointer: "/packages") {
            for package in packages { try checkSource(package) }
        }
        let tap = Self.text(package, "tap")
        if !tap.isEmpty, !["homebrew/core", "homebrew/cask"].contains(tap), !(try trustedTaps()).contains(tap) {
            let kind = Self.text(package, "kind"), name = Self.text(package, "name")
            if let resolveCurrentTrust {
                if try resolveCurrentTrust("tap", tap) { return }
                guard ["formula", "cask"].contains(kind), HomebrewTaskInput.validPackageName(name),
                      try resolveCurrentTrust(kind, name.contains("/") ? name : tap + "/" + name) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                return
            }
            guard ["formula", "cask"].contains(kind), HomebrewTaskInput.validPackageName(name),
                  try trustedItems(kind).contains(name.contains("/") ? name : tap + "/" + name) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        }
    }
    private func review(_ input: HomebrewTaskInput, owner: PluginID, cancellation: HostFetchedSections.Cancellation = .init()) throws -> (HomebrewTaskInput, JSONValue) {
        if ["adopt", "doctorFix"].contains(input.operation) {
            let (resolved, metadata) = try targetResolver(input.name, owner)
            if input.operation == "doctorFix", case .array(let values)? = metadata.value(atPointer: "/doctor_steps") {
                guard (1...8).contains(values.count) else { throw PluginHostServiceError.tool(.planChanged) }
                var reviewedSteps: [JSONValue] = [], packages: [JSONValue] = [], summaries: [String] = [], directories: [JSONValue] = []
                for value in values {
                    guard let json = value.value(atPointer: "/input"), case .object(let metadata)? = value.value(atPointer: "/metadata") else { throw PluginHostServiceError.tool(.planChanged) }
                    let step = try HomebrewTaskInput(json)
                    guard ["cleanup", "link"].contains(step.operation), case .object(var fields) = try preflight(step, cancellation) else { throw PluginHostServiceError.tool(.planChanged) }
                    for (key, value) in metadata { fields[key] = value }
                    if let summary = value.value(atPointer: "/repair_summary") { fields["repair_summary"] = summary }
                    let package = JSONValue.object(fields)
                    packages.append(package)
                    reviewedSteps.append(.object(["input": step.json, "metadata": package]))
                    summaries.append(Self.text(package, "repair_summary").isEmpty ? step.displayOperation + (step.name.isEmpty ? "" : " " + step.name) : Self.text(package, "repair_summary"))
                    if case .array(let paths)? = package.value(atPointer: "/repair_directories") { directories += paths }
                }
                guard Set(directories).count <= 16 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                let privileged = packages.contains { $0.value(atPointer: "/needs_privileges") == .bool(true) }
                return (resolved, .object(["doctor_steps": .array(reviewedSteps), "packages": .array(packages), "repair_summary": .string(summaries.joined(separator: "; ")),
                    "repair_directories": .array(Array(Set(directories)).sorted { String(describing: $0) < String(describing: $1) }), "needs_privileges": .bool(privileged), "privileged_repair": .bool(privileged)]))
            }
            guard ["install", "link", "cleanup"].contains(resolved.operation),
                  input.operation != "adopt" || (resolved.operation == "install" && resolved.kind == "cask" && metadata.value(atPointer: "/adopt") == .bool(true)) else {
                throw PluginHostServiceError.tool(.planChanged)
            }
            let package = try preflight(resolved, cancellation)
            guard case .object(var fields) = package, case .object(let reviewed) = metadata else { throw PluginHostServiceError.tool(.planChanged) }
            for (key, value) in reviewed { fields[key] = value }
            return (resolved, .object(fields))
        }
        return (input, try preflight(input, cancellation))
    }
    private func resolvedInput(_ input: HomebrewTaskInput, package: JSONValue) throws -> HomebrewTaskInput {
        if input.operation == "upgradeAll" {
            guard case .array(let packages)? = package.value(atPointer: "/packages"), packages.count <= 2000 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            let names = packages.compactMap { record -> JSONValue? in
                guard record.value(atPointer: "/pinned") != .bool(true), case .string(let name)? = record.value(atPointer: "/name") else { return nil }; return .string(name)
            }
            guard !names.isEmpty else { throw PluginHostServiceError.tool(.notOutdated) }
            return input
        }
        if ["formula", "cask"].contains(input.kind) {
            var fields = input.fields
            if input.operation == "upgradeSelected", case .array(let records)? = package.value(atPointer: "/packages") {
                let names = records.compactMap { record -> JSONValue? in
                    guard record.value(atPointer: "/kind") == .string(input.kind), case .string(let name)? = record.value(atPointer: "/name"), HomebrewTaskInput.validPackageName(name) else { return nil }
                    return .string(name)
                }
                guard names.count == records.count else { throw PluginHostServiceError.tool(.planChanged) }
                fields["names"] = .array(names)
            } else if package.value(atPointer: "/kind") == .string(input.kind), case .string(let name)? = package.value(atPointer: "/name"), HomebrewTaskInput.validPackageName(name), !input.name.isEmpty {
                fields["name"] = .string(name)
            }
            return try HomebrewTaskInput(.object(fields))
        }
        return input
    }
    private func steps(_ input: HomebrewTaskInput, package: JSONValue) throws -> [HomebrewTaskInput] {
        if case .array(let values)? = package.value(atPointer: "/doctor_steps") {
            guard (1...8).contains(values.count) else { throw PluginHostServiceError.tool(.planChanged) }
            return try values.map { value in
                guard let json = value.value(atPointer: "/input") else { throw PluginHostServiceError.tool(.planChanged) }
                return try HomebrewTaskInput(json)
            }
        }
        guard input.operation == "upgradeAll", case .array(let packages)? = package.value(atPointer: "/packages") else { return [] }
        var result: [HomebrewTaskInput] = []
        for kind in input.kind == "both" ? ["formula", "cask"] : [input.kind] {
            let names = packages.filter { $0.value(atPointer: "/kind") == .string(kind) && $0.value(atPointer: "/pinned") != .bool(true) }.compactMap { $0.value(atPointer: "/name") }
            for offset in stride(from: 0, to: names.count, by: 50) {
                result.append(try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeSelected"), "kind": .string(kind), "names": .array(Array(names.dropFirst(offset).prefix(50))), "greedy": kind == "cask" ? input.fields["greedy"] ?? .bool(false) : .bool(false)])))
            }
        }
        guard !result.isEmpty else { throw PluginHostServiceError.tool(.notOutdated) }
        return result
    }
    private static func text(_ value: JSONValue, _ key: String) -> String { if case .string(let text)? = value.value(atPointer: "/" + key) { return text }; return "" }
    private static func checkOptions(_ input: HomebrewTaskInput, package: JSONValue, prefix: URL, preparing: Bool = false) throws {
        if input.operation == "autoremove" {
            guard package.value(atPointer: "/available") == .bool(true), package.value(atPointer: "/succeeded") == .bool(true),
                  package.value(atPointer: "/complete") == .bool(true),
                  case .array(let packages)? = package.value(atPointer: "/packages") else { throw PluginHostServiceError.tool(.planChanged) }
            if preparing, packages.isEmpty, package.value(atPointer: "/no_op") == .bool(true) {
                throw PluginHostServiceError.toolReadFailed("No unused Homebrew dependencies to remove. No Task was started.")
            }
            guard package.value(atPointer: "/no_op") == .bool(false), (1...2000).contains(packages.count),
                  packages.allSatisfy({ record in
                      guard record.value(atPointer: "/kind") == .string("formula"), case .string(let name)? = record.value(atPointer: "/name") else { return false }
                      return HomebrewTaskInput.validPackageName(name)
                  }), Set(packages.compactMap { $0.value(atPointer: "/name") }).count == packages.count else { throw PluginHostServiceError.tool(.planChanged) }
        }
        if ["link", "unlink"].contains(input.operation), package.value(atPointer: "/installed_version") == nil { throw PluginHostServiceError.tool(.planChanged) }
        if input.operation == "changeLanguage" {
            guard package.value(atPointer: "/installed_version") != nil,
                  case .array(let languages)? = package.value(atPointer: "/languages"),
                  let language = input.fields["language"], languages.contains(language) else { throw PluginHostServiceError.tool(.planChanged) }
        }
    }
    public static func preflight(_ input: HomebrewTaskInput, executable: URL, cancellation: HostFetchedSections.Cancellation = .init()) throws -> JSONValue {
        if input.operation == "autoremove" {
            return try HomebrewReadProfile(executable: { executable }).read(.object(["tool": .string("homebrew"), "operation": .string("previewAutoremove")]), owner: PluginID("host-task-preflight"), timeout: 15, cancellation: cancellation)
        }
        if ["tap", "untap", "trust", "untrust", "cleanup", "update", "refreshCatalog"].contains(input.operation) { return .object([:]) }
        if input.operation == "doctorFix" || input.operation == "adopt" { throw PluginHostServiceError.tool(.planChanged) }
        if input.operation.hasPrefix("service") {
            let current = try HomebrewReadProfile.executeReadCancellable(executable, ["services", "list", "--json"], HomebrewReadProfile.environment, Date().addingTimeInterval(15), cancellation)
            guard current.status == 0, let rows = try JSONSerialization.jsonObject(with: current.stdout) as? [[String: Any]],
                  let service = rows.first(where: { $0["name"] as? String == input.name }),
                  service["user"] == nil || service["user"] is NSNull || service["user"] as? String == "" || service["user"] as? String == NSUserName() else {
                throw PluginHostServiceError.tool(.sourceNotAllowed)
            }
        }
        let profile = HomebrewReadProfile(executable: { executable })
        if input.operation == "upgradeAll" {
            var request: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string("outdated"), "greedy": input.fields["greedy"] ?? .bool(false)]
            if input.kind != "both" { request["kind"] = .string(input.kind) }
            let outdated = try profile.read(.object(request), owner: PluginID("host-task-preflight"), timeout: 15, cancellation: cancellation)
            guard outdated.value(atPointer: "/truncated") != .bool(true), case .array(let packages)? = outdated.value(atPointer: "/packages") else { throw PluginHostServiceError.tool(.outputTooLarge) }
            var details: [JSONValue] = []
            for kind in ["formula", "cask"] {
                let names = packages.filter { $0.value(atPointer: "/kind") == .string(kind) && $0.value(atPointer: "/pinned") != .bool(true) }.compactMap { $0.value(atPointer: "/name") }
                for offset in stride(from: 0, to: names.count, by: 50) {
                    let info = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string(kind), "names": .array(Array(names.dropFirst(offset).prefix(50)))]), owner: PluginID("host-task-preflight"), timeout: 15, cancellation: cancellation)
                    guard info.value(atPointer: "/not_found") == nil, case .array(let records)? = info.value(atPointer: "/packages") else { throw PluginHostServiceError.tool(.planChanged) }
                    details += records
                }
            }
            return .object(["packages": .array(details)])
        }
        let names = input.fields["names"] ?? .array([.string(input.name)])
        let data = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string(input.kind), "names": names]), owner: PluginID("host-task-preflight"), timeout: 15, cancellation: cancellation)
        guard case .array(let packages)? = data.value(atPointer: "/packages"), let package = packages.first,
              data.value(atPointer: "/not_found") == nil else { throw PluginHostServiceError.tool(.packageNotFound) }
        if input.operation == "install", package.value(atPointer: "/installed_version") != nil { throw PluginHostServiceError.tool(.alreadyInstalled) }
        if input.operation == "upgrade", package.value(atPointer: "/outdated") != .bool(true) || package.value(atPointer: "/pinned") == .bool(true) { throw PluginHostServiceError.tool(.notOutdated) }
        if input.operation == "upgradeSelected" {
            guard packages.count == { if case .array(let requested) = names { return requested.count }; return 0 }(),
                  packages.allSatisfy({ $0.value(atPointer: "/outdated") == .bool(true) && $0.value(atPointer: "/pinned") != .bool(true) }) else { throw PluginHostServiceError.tool(.notOutdated) }
            return .object(["packages": .array(packages)])
        }
        return package
    }
    public static func readTrustedTaps(executable: URL) throws -> [String] {
        try readTrustedEntries(kind: "tap", executable: executable)
    }
    private static func readTrustedEntries(kind: String, executable: URL) throws -> [String] {
        guard ["tap", "formula", "cask"].contains(kind) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let result = try HomebrewReadProfile.executeReadCancellable(executable, ["trust", "--" + kind, "--json=v1"], HomebrewReadProfile.environment, Date().addingTimeInterval(15), .init())
        guard result.status == 0, let entries = try? JSONDecoder().decode([String].self, from: result.stdout), entries.count <= 2000 else { throw PluginHostServiceError.tool(.failed) }
        return entries
    }

}

/// The runner alone owns the journal after launch. It records outcomes, not
/// instructions to replay; neither Host recovery nor runner recovery spawns
/// a second mutation.
public struct HomebrewTaskJournal: Codable {
    public var id: String
    public var owner: String
    public var pluginName: String
    public var input: JSONValue
    public var package: JSONValue
    public var executable: String
    public var started: Date
    public var detached: Bool
    public var runnerPID: Int32?
    public var runnerIdentity: UInt64?
    public var processGroup: Int32?
    public var processIdentity: UInt64?
    public var stage: String
    public var log: [String]
    public var output: String? = nil
    public var outputTruncated: Bool? = nil
    public var result: JSONValue?
    public var ended: Date?
    public var scope: PluginCapabilityScope? = nil
    public var steps: [JSONValue]? = nil
    public var executionModel: String? = nil
    public var privilegePlan: HomebrewPrivilegePlan? = nil
    public var stepMetadata: [JSONValue]? = nil
    public func save(to directory: URL) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2 * 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        try data.write(to: directory.appendingPathComponent("task.json"), options: .atomic)
    }
    public static func load(from directory: URL) throws -> Self {
        let data = try Data(contentsOf: directory.appendingPathComponent("task.json"), options: .mappedIfSafe)
        guard data.count <= 2 * 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
