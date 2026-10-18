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
    public var privilegedCasks: [HomebrewPrivilegePlan.Cask] = []
    public var nativeInspection: HomebrewTaskNativeInspection? = nil
    public var requiresNativeInspection: Bool { nativeInspection?.disclosure == nil && nativeInspection != nil }
    public var activityID: String { "activity_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    public var needsPrivileges: Bool {
        if Self.packageNeedsPrivileges(package, operation: input.operation, includeZap: input.fields["zap"] == .bool(true)) { return true }
        if case .array(let records)? = package.value(atPointer: "/packages") { return records.contains { Self.packageNeedsPrivileges($0, operation: input.operation, includeZap: input.fields["zap"] == .bool(true)) } }
        return false
    }
    static func packageNeedsPrivileges(_ package: JSONValue, operation: String, includeZap: Bool = false) -> Bool {
        if ["link", "unlink", "pin", "unpin"].contains(operation) { return false }
        if operation == "uninstall" {
            return package.value(atPointer: "/uninstall_needs_privileges") == .bool(true)
                || (includeZap && package.value(atPointer: "/zap_needs_privileges") == .bool(true))
        }
        return (operation == "uninstall" && includeZap && package.value(atPointer: "/zap_needs_privileges") == .bool(true))
            || package.value(atPointer: "/needs_privileges") == .bool(true)
            || (["uninstall", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation)
                && package.value(atPointer: "/uninstall_needs_privileges") == .bool(true))
    }
    let generation: Int
}

/// Entirely Host-private authority. The Plugin sees only its start outcome
/// and the separately admitted Task; it cannot provide a draft or seal.
public struct HomebrewTaskNativeInspection {
    public let draft: HomebrewNativeInspection.Draft
    public let reservation: HomebrewNativeInspection.Reservation?
    public var disclosure: HomebrewNativeInspection.Disclosure?
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
    private let privilegeReview: (HomebrewTaskInput, JSONValue, URL, [HomebrewPrivilegePlan.Cask]?, HostFetchedSections.Cancellation) throws -> [HomebrewPrivilegePlan.Cask]
    private let nativeInspection: HomebrewNativeInspectionTransporting?
    private let inspectionDraft: (HomebrewTaskPlan) throws -> HomebrewNativeInspection.Draft
    private let prepareSystemAuthorization: () throws -> Void
    private let admitSystemAuthorization: (HomebrewPrivilegePlan) throws -> Void
    private let cancelSystemAuthorization: (String) -> Void
    private let lock = NSRecursiveLock()
    private var pending: HomebrewTaskPlan?
    private var preparationID: UUID?
    private var pendingCancellation: HostFetchedSections.Cancellation?
    private var pendingCancelRegistration: (() -> Void)?
    private var inspectionPolling = false
    private var recoveredInspection: (id: String, owner: PluginID, name: String)?
    private var pendingActivity: String?
    private var globalNativeLaneHeld = false
    private var globalNativeActivity: String?
    private let recoveryPower: PowerAssertions?
    private var recoveryPowerReleases: [String: () -> Void] = [:]
    private var orphanStopTimes: [String: TimeInterval] = [:]
    private var orphanedTasks = Set<String>()
    private let privilegedTaskIsRunning: (HomebrewPrivilegePlan) throws -> Bool
    private let stopPrivilegedTask: (HomebrewPrivilegePlan) throws -> Void
    private var rootTaskLiveness: [String: Bool] = [:]
    private var rootPollInFlight = Set<String>()
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
                privilegeReview: ((HomebrewTaskInput, JSONValue, URL) throws -> [HomebrewPrivilegePlan.Cask])? = nil,
                nativeInspection: HomebrewNativeInspectionTransporting? = HomebrewNativeInspectionTransport(),
                inspectionDraft: ((HomebrewTaskPlan) throws -> HomebrewNativeInspection.Draft)? = nil,
                prepareSystemAuthorization: @escaping () throws -> Void = HomebrewSystemAuthorization.prepareService,
                admitSystemAuthorization: @escaping (HomebrewPrivilegePlan) throws -> Void = HomebrewSystemAuthorization.admit,
                cancelSystemAuthorization: @escaping (String) -> Void = HomebrewSystemAuthorization.cancelAdmission,
                recoveryPower: PowerAssertions? = nil,
                privilegedTaskIsRunning: @escaping (HomebrewPrivilegePlan) throws -> Bool = HomebrewSystemAuthorization.taskIsRunning,
                stopPrivilegedTask: @escaping (HomebrewPrivilegePlan) throws -> Void = HomebrewSystemAuthorization.stopTask) {
        self.activities = activities; root = journal; self.runnerURL = runnerURL; self.executable = executable
        self.preflight = cancellablePreflight ?? preflight.map { work in { input, _ in try work(input) } }
            ?? { input, cancellation in try Self.preflight(input, executable: executable(), cancellation: cancellation) }
        self.trustedTaps = trustedTaps ?? { try Self.readTrustedTaps(executable: executable()) }
        self.trustedItems = trustedItems ?? { kind in try Self.readTrustedEntries(kind: kind, executable: executable()) }
        self.resolveCurrentTrust = trustedTaps == nil && trustedItems == nil ? { kind, name in
            try HomebrewReadProfile.explicitlyTrusted(name, kind: kind, executable: executable(), deadline: Date().addingTimeInterval(15))
        } : nil
        self.targetResolver = targetResolver
        self.privilegeReview = privilegeReview.map { work in { input, package, tool, _, _ in try work(input, package, tool) } }
            ?? { input, package, tool, expected, cancellation in try HomebrewPrivilegeReview.casksForInspection(input: input, package: package, executable: tool, expected: expected, cancellation: cancellation) }
        self.nativeInspection = nativeInspection
        self.inspectionDraft = inspectionDraft ?? { plan in
            try HomebrewNativeInspectionPlanning.draft(taskID: plan.activityID,
                prefix: HomebrewManagementReads.prefix(of: plan.executable).path, operation: plan.resolvedInput.operation,
                casks: plan.privilegedCasks, includeZap: plan.input.fields["zap"] == .bool(true))
        }
        self.prepareSystemAuthorization = prepareSystemAuthorization
        self.admitSystemAuthorization = admitSystemAuthorization; self.cancelSystemAuthorization = cancelSystemAuthorization
        self.recoveryPower = recoveryPower
        self.privilegedTaskIsRunning = privilegedTaskIsRunning; self.stopPrivilegedTask = stopPrivilegedTask
        recover()
        recoverInspection()
        if nativeInspection is HomebrewNativeInspectionTransport, HomebrewNativeInspectionAuthorization.isServiceEnabled {
            globalNativeLaneHeld = true; registerGlobalNativeLane(); refreshInspection()
        }
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
        return pending != nil || recoveredInspection != nil || globalNativeLaneHeld || taskRecoveryUnavailable || records.values.contains { executionHeld($0) }
    }
    public func ownerGeneration(_ owner: PluginID) -> Int { lock.lock(); defer { lock.unlock() }; return generations[owner, default: 0] }
    public func prepare(_ input: HomebrewTaskInput, owner: PluginID, pluginName: String,
                        scope: PluginCapabilityScope? = nil,
                        authorize: () throws -> Void = {}) throws -> HomebrewTaskPlan {
        if let scope { try input.authorize(in: scope) }
        try authorize()
        lock.lock()
        let locallyBusy = exiting || pending != nil || recoveredInspection != nil || taskRecoveryUnavailable || records.values.contains { executionHeld($0) }
        lock.unlock()
        guard !locallyBusy else { throw PluginHostServiceError.tool(.busy) }
        if let nativeInspection,
           !(nativeInspection is HomebrewNativeInspectionTransport) || HomebrewNativeInspectionAuthorization.isServiceEnabled {
            lock.lock(); globalNativeLaneHeld = true; lock.unlock()
            let status: HomebrewNativeInspection.Status
            do { status = try nativeInspection.laneStatus() }
            catch { registerGlobalNativeLane(); throw error }
            lock.lock(); globalNativeLaneHeld = status.laneHeld || status.workerUnreaped
            if !globalNativeLaneHeld, let activity = globalNativeActivity { activities.removeEndedTask(activity); globalNativeActivity = nil }
            lock.unlock()
            if status.laneHeld || status.workerUnreaped {
                registerGlobalNativeLane()
                throw PluginHostServiceError.tool(.busy)
            }
        }
        lock.lock()
        guard !exiting, pending == nil, recoveredInspection == nil, !taskRecoveryUnavailable, !records.values.contains(where: { executionHeld($0) }) else {
            lock.unlock(); throw PluginHostServiceError.tool(.busy)
        }
        let generation = generations[owner, default: 0]
        // Reserve before any potentially slow preflight or confirmation.
        let id = UUID()
        let reservation = HomebrewTaskPlan(id: id, owner: owner, pluginName: pluginName, input: input, resolvedInput: input,
            package: .null, executable: URL(fileURLWithPath: "/"), confirmation: .init(title: "", message: "", confirmTitle: "", isDestructive: true), generation: generation)
        let cancellation = HostFetchedSections.Cancellation()
        pending = reservation; preparationID = id; pendingCancellation = cancellation; lock.unlock()
        do {
            let executable = try self.executable()
            let (resolvedTarget, package) = try review(input, owner: owner, cancellation: cancellation)
            if let scope {
                let concreteSteps = try steps(resolvedTarget, package: package)
                for kind in concreteSteps.isEmpty ? [resolvedTarget.kind] : concreteSteps.map(\.kind) { try input.authorizeResolvedKind(kind, in: scope) }
            }
            guard try JSONEncoder().encode(package).count <= 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            try checkSource(package)
            try Self.checkOptions(input, package: package, prefix: HomebrewManagementReads.prefix(of: executable))
            let resolved = try resolvedInput(resolvedTarget, package: package)
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The Task preparation was cancelled") }
            try authorize()
            let target = resolved.name.isEmpty ? "eligible \(resolved.kind) packages" : resolved.name
            let from = Self.text(package, "installed_version"), to = Self.text(package, "version"), tap = Self.text(package, "tap")
            var disclosure = "Homebrew will \(input.displayOperation.lowercased()) \(target)."
            if ["link", "unlink"].contains(input.operation) {
                if !from.isEmpty { disclosure += " Installed version: \(from)." }
            } else if !from.isEmpty || !to.isEmpty { disclosure += " Version: \(from.isEmpty ? "not installed" : from) → \(to.isEmpty ? "current" : to)." }
            if !tap.isEmpty { disclosure += " Source: \(tap)." }
            if ["link", "unlink"].contains(input.operation), case .array(let changes)? = package.value(atPointer: "/link_preview/changes") {
                disclosure += " Concrete changes (no force or overwrite flag):\n" + changes.map { change in
                    let action = Self.text(change, "action"), path = Self.text(change, "path"), source = Self.text(change, "source")
                    switch action {
                    case "link": return "Link \(path) → \(source)"
                    case "unlink": return "Remove \(path)"
                    case "mkdir": return "Create directory \(path)"
                    case "rmdir": return "Remove empty directory \(path)"
                    default: return "Update info index \(path)"
                    }
                }.joined(separator: "\n")
                if case .array(let warnings)? = package.value(atPointer: "/link_preview/warnings") { disclosure += "\nHomebrew diagnostics:\n" + warnings.compactMap { if case .string(let warning) = $0 { return warning }; return nil }.joined(separator: "\n") }
                disclosure += " Changed links, sources or diagnostics require a new confirmation."
            }
            if ["update", "refreshCatalog"].contains(input.operation) { disclosure = "Homebrew will update Homebrew itself, all configured taps and package catalogs. This is a global change even when requested from one package. Later package actions reload metadata and recheck source trust. Stopping does not undo an update already applied." }
            if ["trust", "tap"].contains(input.operation) { disclosure += " This enables third-party code to run with your account's rights. Trust is your explicit choice." }
            if input.operation == "untap" || input.operation == "untrust" { disclosure += " Existing packages may become unavailable to Homebrew." }
            if case .string(let language)? = input.fields["language"] { disclosure += " Reinstalls the App with language \(language)." }
            if input.fields["zap"] == .bool(true) { disclosure += " Zap deletes related settings and files and may delete files shared by Apps." }
            if input.operation == "autoremove", case .array(let packages)? = package.value(atPointer: "/packages") {
                let names = packages.compactMap { item -> String? in if case .string(let name)? = item.value(atPointer: "/name") { return name }; return nil }
                disclosure = "Homebrew will uninstall formulae installed only as dependencies that are no longer needed. "
                    + (names.count <= 100 ? "Chosen formulae: " + names.joined(separator: ", ") + "." : "Every chosen formula is listed in the complete review below.")
                    + " Cask Apps and packages installed on request are retained. This differs from cleaning old versions and cached downloads."
            }
            if input.operation == "cleanup" { disclosure += input.fields["pruneAll"] == .bool(true) ? " All eligible Homebrew cache downloads and old package versions may be deleted." : " Eligible files older than the selected threshold and old package versions may be deleted." }
            if input.operation.hasPrefix("service") { disclosure += " Changes the selected user-owned service at login; this service may continue after Spinnet exits." }
            let reviewedPackages: [JSONValue] = { if case .array(let values)? = package.value(atPointer: "/packages") { return values }; return [package] }()
            if case .string(let summary)? = package.value(atPointer: "/repair_summary") { disclosure += " " + summary }
            if reviewedPackages.contains(where: { HomebrewTaskPlan.packageNeedsPrivileges($0, operation: input.operation, includeZap: input.fields["zap"] == .bool(true)) }) { disclosure += " macOS system authorization is required for reviewed privileged work." }
            if ["upgrade", "upgradeAll", "upgradeSelected", "uninstall", "changeLanguage"].contains(input.operation), reviewedPackages.contains(where: { $0.value(atPointer: "/quits_app") == .bool(true) }) { disclosure += " Homebrew may quit the affected App first." }
            disclosure += " Dependencies and dependents may also change. Stopping does not undo changes. This Task prevents idle system sleep until it ends."
            var plan = HomebrewTaskPlan(id: id, owner: owner, pluginName: String(pluginName.prefix(256)), input: input,
                resolvedInput: resolved, package: package, executable: executable,
                confirmation: .init(title: "Confirm Homebrew: \(input.displayOperation)", message: disclosure, confirmTitle: "Continue", isDestructive: true), generation: generation)
            plan.scope = scope
            plan.steps = try steps(resolved, package: package)
            if (!plan.steps.isEmpty || input.operation == "upgradeSelected"), input.operation != "doctorFix" {
                let targets = try HomebrewTaskNativeConfirmation.selectedPackages(plan).map(\.name)
                let concrete = targets.count <= 100 ? targets.joined(separator: ", ") : "Every selected package is listed in the complete review below."
                plan = HomebrewTaskPlan(id: plan.id, owner: plan.owner, pluginName: plan.pluginName, input: plan.input,
                    resolvedInput: plan.resolvedInput, package: plan.package, executable: plan.executable,
                    confirmation: .init(title: plan.confirmation.title, message: "Chosen packages: \(concrete). " + plan.confirmation.message,
                        confirmTitle: plan.confirmation.confirmTitle, isDestructive: true), scope: plan.scope, steps: plan.steps, generation: plan.generation)
            }
            if plan.needsPrivileges {
                let bindings = try privilegeReview(resolved, package, executable, nil, cancellation)
                try checkInstalledSources(bindings, package: package)
                let nativeDetails = nativeInspection == nil ? bindings.flatMap { cask -> [String] in
                    (cask.installedTap.map { ["Installed source recorded locally for \(cask.name): \($0), version \(cask.uninstallVersion ?? cask.version). This records local history; native receipt/file ownership is checked independently."] } ?? [])
                        + (cask.launchDaemons ?? []).map { "Remove system launch daemon \($0.label)." }
                        + (cask.receipts ?? []).map { "Remove \($0.fileCount) reviewed receipt-owned entries for \($0.identifier), then forget that receipt; nonempty directories remain." }
                }.joined(separator: " ") : ""
                guard nativeDetails.utf8.count <= 8 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                if !nativeDetails.isEmpty {
                    let previous = plan
                    plan = HomebrewTaskPlan(id: previous.id, owner: previous.owner, pluginName: previous.pluginName, input: previous.input,
                        resolvedInput: previous.resolvedInput, package: previous.package, executable: previous.executable,
                        confirmation: .init(title: previous.confirmation.title, message: previous.confirmation.message + " " + nativeDetails,
                            confirmTitle: previous.confirmation.confirmTitle, isDestructive: true), scope: previous.scope, steps: previous.steps, generation: previous.generation)
                }
                plan.privilegedCasks = bindings
                if nativeInspection != nil, bindings.contains(where: { !($0.receipts ?? []).isEmpty }) {
                    let draft = try inspectionDraft(plan)
                    plan.nativeInspection = .init(draft: draft, reservation: nil, disclosure: nil)
                    plan.confirmation = .init(title: "Inspect Homebrew Receipt Ownership",
                        message: "Inspect all installed receipts and their bounded ownership/path metadata to verify exclusive ownership for the selected packages: \(draft.packages.map(\.name).joined(separator: ", ")). This read-only inspection requires separate macOS system authorization and does not change installed packages. If needed, Spinnet registers its signed reviewed-tool helper and asks you to approve it in System Settings before inspection. Unselected receipt ownership data stays private to the Host. After inspection, the Host shows every concrete selected change and asks for a second confirmation and fresh mutation authorization. Cancel stops pre-admission work; a worker still stopping keeps the shared lane busy.",
                        confirmTitle: "Inspect", isDestructive: false)
                    try registerPendingInspection(plan)
                } else {
                    let details = try HomebrewTaskNativeConfirmation.details(plan,
                        disclosure: .init(receipts: [], targets: []), cancellation: cancellation)
                    let message = plan.needsSystemAuthorization ? plan.confirmation.message : plan.confirmation.message.replacingOccurrences(of: " macOS system authorization is required for reviewed privileged work.", with: "")
                    plan.confirmation = .init(title: plan.confirmation.title, message: message,
                        confirmTitle: plan.confirmation.confirmTitle, isDestructive: true, details: details)
                }
            }
            if (!plan.steps.isEmpty || ["upgradeSelected", "autoremove"].contains(input.operation)), !plan.requiresNativeInspection, plan.confirmation.details == nil {
                let details = try HomebrewTaskNativeConfirmation.details(plan, disclosure: .init(receipts: [], targets: []), cancellation: cancellation)
                plan.confirmation = .init(title: plan.confirmation.title, message: plan.confirmation.message,
                    confirmTitle: plan.confirmation.confirmTitle, isDestructive: true, details: details)
            }
            lock.lock(); defer { lock.unlock() }
            guard pending?.id == id, generations[owner, default: 0] == generation, !exiting else { throw PluginHostServiceError.unavailable("The admitted Task owner changed") }
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The Task preparation was cancelled") }
            pending = plan; preparationID = nil; return plan
        } catch {
            lock.lock(); let held = pending?.id == id ? pending : nil; preparationID = nil; lock.unlock()
            if let held { decline(held) } else { cancellation.cancel() }
            throw error
        }
    }
    /// Called only after the first Host Confirmation. No mutation right is
    /// configured until the complete final confirmation has answered.
    public func completeInspection(_ plan: HomebrewTaskPlan, authorize: () throws -> Void = {}) throws -> HomebrewTaskPlan {
        lock.lock()
        guard pending?.id == plan.id, plan.requiresNativeInspection, let inspection = plan.nativeInspection,
              let nativeInspection, let cancellation = pendingCancellation, !cancellation.isCancelled,
              generations[plan.owner, default: 0] == plan.generation, !exiting else {
            lock.unlock(); throw PluginHostServiceError.tool(.planChanged)
        }
        preparationID = plan.id; lock.unlock()
        do {
            try authorize()
            // Helper setup is an explicit consequence of the first trusted
            // confirmation, never a side effect of an ordinary metadata read.
            try prepareSystemAuthorization()
            try authorize()
            guard !cancellation.isCancelled else { throw HomebrewNativeInspection.Failure.authorizationCancelled }
            let reservation = try nativeInspection.reserve(inspection.draft, cancellation: cancellation)
            var reserved = plan
            reserved.nativeInspection = .init(draft: inspection.draft, reservation: reservation, disclosure: nil)
            lock.lock(); pending = reserved; lock.unlock()
            let forget = cancellation.onCancel { [weak self] in
                DispatchQueue.global(qos: .utility).async { nativeInspection.cancel(reservation.inspectionID); self?.refreshInspection() }
            }
            lock.lock(); pendingCancelRegistration = forget; lock.unlock()
            try persistInspection(reserved)
            let captured = try nativeInspection.inspect(reservation, draft: inspection.draft, cancellation: cancellation)
            let review = try HomebrewNativeInspectionReview(summary: captured.summary, draft: inspection.draft)
            let bytes = try HomebrewNativeInspection.encode(captured.disclosure)
            guard bytes.count == captured.summary.disclosureBytes,
                  HomebrewSystemAuthorization.digest(bytes) == captured.summary.disclosureSHA256,
                  captured.summary.inspectionID == reservation.inspectionID else { throw HomebrewNativeInspection.Failure.incompleteReview }
            // Verify the same full collector boundary even for a recorded
            // transport. No summary/partial page authorizes presentation.
            for offset in stride(from: 0, to: bytes.count, by: HomebrewNativeInspection.maximumPagePayloadBytes) {
                let end = min(bytes.count, offset + HomebrewNativeInspection.maximumPagePayloadBytes)
                let page = HomebrewNativeInspection.Page(inspectionID: captured.summary.inspectionID, seal: captured.summary.seal,
                    offset: offset, totalBytes: bytes.count, disclosureSHA256: captured.summary.disclosureSHA256, bytes: bytes.subdata(in: offset..<end))
                try review.append(page)
            }
            let disclosure = try review.finish()
            var final = plan
            final.privilegedCasks = try HomebrewNativeInspectionPlanning.finalizedCasks(plan.privilegedCasks, disclosure: disclosure)
            final.nativeInspection = .init(draft: inspection.draft, reservation: reservation, disclosure: disclosure)
            let details = try HomebrewTaskNativeConfirmation.details(final, disclosure: disclosure, cancellation: cancellation)
            final.confirmation = .init(title: "Confirm Homebrew: \(plan.input.displayOperation)",
                message: "The complete read-only ownership inspection is ready. Review all concrete changes below before continuing. Dependencies and dependents may also change. Stopping does not undo changes. This confirmed Task prevents idle system sleep until it ends. macOS requests fresh mutation authorization after this confirmation.",
                confirmTitle: "Continue", isDestructive: true, details: details)
            try authorize()
            lock.lock(); defer { lock.unlock() }
            guard pending?.id == plan.id, !cancellation.isCancelled, generations[plan.owner, default: 0] == plan.generation, !exiting else { throw PluginHostServiceError.tool(.planChanged) }
            pending = final; preparationID = nil
            if let pendingActivity { activities.updateStatus(pendingActivity, status: "Awaiting concrete mutation confirmation") }
            return final
        } catch {
            lock.lock(); if pending?.id == plan.id { preparationID = nil }; lock.unlock()
            decline(plan); throw error
        }
    }
    public func decline(_ plan: HomebrewTaskPlan) {
        lock.lock(); let cancellation = pending?.id == plan.id ? pendingCancellation : nil
        if pending?.id == plan.id, preparationID != plan.id, pending?.nativeInspection?.reservation == nil { pending = nil; pendingCancellation = nil; clearInspectionRecovery() }
        lock.unlock(); cancellation?.cancel()
        refreshInspection()
    }
    /// Stop pre-admission work, including a prepare call that has not returned
    /// a plan yet. Its reservation remains until the owned operation exits.
    public func cancelPending(for owner: PluginID? = nil) {
        lock.lock()
        guard let plan = pending, owner == nil || plan.owner == owner else { lock.unlock(); return }
        let cancellation = pendingCancellation
        if preparationID != plan.id, plan.nativeInspection?.reservation == nil { pending = nil; pendingCancellation = nil; clearInspectionRecovery() }
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
        var admitted: String?
        do {
            try authorize()
            guard !plan.requiresNativeInspection else { throw PluginHostServiceError.tool(.planChanged) }
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
            if plan.needsPrivileges {
                var bindings = try privilegeReview(plan.resolvedInput, currentPackage, plan.executable, plan.privilegedCasks, cancellation)
                if let disclosure = plan.nativeInspection?.disclosure { bindings = try HomebrewNativeInspectionPlanning.finalizedCasks(bindings, disclosure: disclosure) }
                guard bindings == plan.privilegedCasks else { throw PluginHostServiceError.tool(.planChanged) }
                try checkInstalledSources(plan.privilegedCasks, package: currentPackage)
                if plan.needsSystemAuthorization, plan.nativeInspection == nil { try prepareSystemAuthorization() }
            }
            try authorize()
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The Task preparation was cancelled") }
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
            if plan.needsPrivileges {
                let prefix = plan.executable.deletingLastPathComponent().deletingLastPathComponent().path
                let directories: [String] = { if case .array(let values)? = plan.package.value(atPointer: "/repair_directories") { return values.compactMap { if case .string(let path) = $0 { return path }; return nil } }; return [] }()
                let privilegePlan = try HomebrewPrivilegePlan(taskID: id, prefix: prefix, casks: plan.privilegedCasks, repairDirectories: directories, operation: plan.input.operation == "doctorFix" ? "doctorFix" : plan.resolvedInput.operation)
                record.privilegePlan = privilegePlan
                do {
                    if let inspection = plan.nativeInspection, let nativeInspection {
                        guard let disclosure = inspection.disclosure else { throw HomebrewNativeInspection.Failure.incompleteReview }
                        try HomebrewNativeInspectionPlanning.validateFinalPlan(privilegePlan, draft: inspection.draft, disclosure: disclosure)
                        guard let reservation = inspection.reservation else { throw HomebrewNativeInspection.Failure.incompleteReview }
                        try nativeInspection.admit(reservation, plan: privilegePlan, cancellation: cancellation)
                        admitted = id
                    } else if privilegePlan.requiresSystemAuthorization { try admitSystemAuthorization(privilegePlan); admitted = id }
                    try authorize()
                }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
            }
            lock.lock(); defer { lock.unlock() }
            guard pending?.id == plan.id, generations[plan.owner, default: 0] == plan.generation, !exiting, !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The admitted Task owner changed") }
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
            let ended = records.values.filter { $0.owner == record.owner && !executionHeld($0) }.sorted { ($0.ended ?? $0.started) < ($1.ended ?? $1.started) }
            if activities.list(for: plan.owner).count >= HostActivities.maximumPerPlugin, let oldest = ended.first {
                activities.removeEndedTask(oldest.id); records[oldest.id] = nil
                try? FileManager.default.removeItem(at: root.appendingPathComponent(oldest.id))
            }
            records[id] = record
            if let pendingActivity { activities.removeEndedTask(pendingActivity); self.pendingActivity = nil }
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
            clearInspectionRecovery()
            return id
        } catch {
            if let admitted { cancelSystemAuthorization(admitted) }
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
        if let plan = record.privilegePlan, plan.requiresSystemAuthorization {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                do { try self.stopPrivilegedTask(plan) }
                catch {
                    self.lock.lock(); defer { self.lock.unlock() }
                    if var current = self.records[id], self.executionHeld(current) {
                        current.stage = "Stop attempted; authenticated Root control unavailable; waiting for actual reaping"
                        self.records[id] = current; self.publish(current)
                    }
                }
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
        if pending?.owner == owner, preparationID != pending?.id, pending?.nativeInspection?.reservation == nil { pending = nil; pendingCancellation = nil; clearInspectionRecovery() }
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
        refreshInspection()
        lock.lock(); defer { lock.unlock() }
        for (id, held) in records {
            let directory = root.appendingPathComponent(id)
            guard var current = try? HomebrewTaskJournal.load(from: directory) else { continue }
            current.detached = held.detached || FileManager.default.fileExists(atPath: directory.appendingPathComponent("detached").path)
            let activeLease = (try? HomebrewTaskProcessLease.load(from: directory)).map { !$0.provesNoOwnedExecution } ?? false
            let rootPending = current.privilegePlan?.requiresSystemAuthorization == true && rootTaskLiveness[id] != false
            if current.result == nil || orphanedTasks.contains(id) || activeLease || rootPending {
                let runnerPID = held.runnerPID ?? current.runnerPID
                let identity = held.runnerIdentity ?? current.runnerIdentity
                if let runnerPID, let identity, HomebrewTaskProcess.startIdentity(runnerPID) != identity {
                    reconcileLostRunner(&current, directory: directory)
                }
            }
            if orphanedTasks.contains(id) { reconcileLostRunner(&current, directory: directory) }
            records[id] = current; publish(current)
            if !executionHeld(current), suddenTerminationAssertions.remove(id) != nil { ProcessInfo.processInfo.enableSuddenTermination() }
            if !executionHeld(current) { recoveryPowerReleases.removeValue(forKey: id)?(); orphanedTasks.remove(id); orphanStopTimes[id] = nil }
            if !executionHeld(current), let ended = current.ended, Date().timeIntervalSince(ended) > 3600 {
                activities.removeEndedTask(id); records[id] = nil; try? FileManager.default.removeItem(at: directory)
            }
        }
    }
    private func register(_ record: HomebrewTaskJournal) throws {
        _ = try activities.register(owner: PluginID(record.owner), pluginName: record.pluginName, kind: "task", status: "Starting — prevents idle system sleep",
            id: record.id, removesOnStop: false) { [weak self] in try? self?.stop(record.id) }
        publish(record)
        if executionHeld(record), suddenTerminationAssertions.insert(record.id).inserted { ProcessInfo.processInfo.disableSuddenTermination() }
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
            if record.result == nil || activeLease || rootPending,
               record.runnerPID == nil || record.runnerIdentity == nil || HomebrewTaskProcess.startIdentity(record.runnerPID!) != record.runnerIdentity {
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
        var rootBusy = false
        if let plan = record.privilegePlan, plan.requiresSystemAuthorization {
            rootBusy = rootTaskLiveness[record.id] ?? true
            if !rootPollInFlight.contains(record.id) {
                rootPollInFlight.insert(record.id)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    let busy = (try? self.privilegedTaskIsRunning(plan)) ?? true
                    self.lock.lock(); self.rootTaskLiveness[plan.taskID] = busy; self.rootPollInFlight.remove(plan.taskID); self.lock.unlock()
                }
            }
        }
        if sameRunner, lease?.provesNoOwnedExecution == true, !rootBusy {
            if record.result == nil { record.result = .object(["outcome": .string("unknown")]); record.ended = Date() }
            orphanedTasks.remove(record.id); recoveryPowerReleases.removeValue(forKey: record.id)?()
        } else {
            orphanedTasks.insert(record.id)
            record.stage = "unknown: runner lost; waiting for independently proven process reaping; no replay"
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
    private var inspectionRecoveryURL: URL { root.appendingPathComponent("pending-inspection.json") }
    private func persistInspection(_ plan: HomebrewTaskPlan) throws {
        guard let reservation = plan.nativeInspection?.reservation else { throw HomebrewNativeInspection.Failure.invalidDraft }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let metadata: JSONValue = .object(["id": .string(reservation.inspectionID),
            "owner": .string(plan.owner.rawValue), "name": .string(plan.pluginName)])
        try JSONEncoder().encode(metadata).write(to: inspectionRecoveryURL, options: .atomic)
    }
    private func registerPendingInspection(_ plan: HomebrewTaskPlan) throws {
        lock.lock()
        if activities.list(for: plan.owner).count >= HostActivities.maximumPerPlugin,
           let oldest = records.values.filter({ $0.owner == plan.owner.rawValue && !executionHeld($0) }).min(by: { ($0.ended ?? $0.started) < ($1.ended ?? $1.started) }) {
            activities.removeEndedTask(oldest.id); records[oldest.id] = nil
            try? FileManager.default.removeItem(at: root.appendingPathComponent(oldest.id))
        }
        lock.unlock()
        let id = "inspection_" + plan.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        _ = try activities.register(owner: plan.owner, pluginName: plan.pluginName, kind: "inspection",
            status: "Awaiting read-only receipt inspection", id: id, visibleToOwner: false, removesOnStop: false) { [weak self] in
                self?.cancelPending(for: plan.owner)
            }
        lock.lock(); pendingActivity = id; lock.unlock()
    }
    private func clearInspectionRecovery() {
        pendingCancelRegistration?(); pendingCancelRegistration = nil
        if let pendingActivity { activities.removeEndedTask(pendingActivity) }
        pendingActivity = nil; recoveredInspection = nil
        try? FileManager.default.removeItem(at: inspectionRecoveryURL)
    }
    private func recoverInspection() {
        guard nativeInspection != nil else { return }
        let fd = open(inspectionRecoveryURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size > 0, info.st_size <= 4096 else { return }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count == buffer.count, let metadata = try? JSONDecoder().decode(JSONValue.self, from: Data(buffer)),
              case .string(let id)? = metadata.value(atPointer: "/id"), id.range(of: "^inspection_[a-f0-9-]{36}$", options: .regularExpression) != nil,
              case .string(let owner)? = metadata.value(atPointer: "/owner"), owner.utf8.count <= 128,
              case .string(let name)? = metadata.value(atPointer: "/name"), name.utf8.count <= 256 else { return }
        recoveredInspection = (id, PluginID(owner), name)
        let activity = try? activities.register(owner: PluginID(owner), pluginName: name, kind: "inspection", status: "Recovering inspection status; never replaying work",
            visibleToOwner: false, removesOnStop: false) { [weak self] in self?.refreshInspection() }
        pendingActivity = activity?.id
        refreshInspection()
    }
    /// Transport I/O is never on the UI thread or under the Task lock. A
    /// failure retains the lane; cancellation alone cannot prove reaping.
    private func refreshInspection() {
        lock.lock()
        let held = pending?.nativeInspection?.reservation?.inspectionID
        let recovery = recoveredInspection?.id
        let global = held == nil && recovery == nil && globalNativeLaneHeld
        guard let nativeInspection, (held != nil || recovery != nil || global), !inspectionPolling else { lock.unlock(); return }
        let id = held ?? recovery ?? ""
        inspectionPolling = true; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let status: HomebrewNativeInspection.Status?
            do { status = try global ? nativeInspection.laneStatus() : recovery == nil ? nativeInspection.status(id) : nativeInspection.recoverStatus(id) }
            catch { status = nil }
            self.lock.lock(); defer { self.lock.unlock() }
            self.inspectionPolling = false
            if global {
                self.globalNativeLaneHeld = status == nil || status!.laneHeld || status!.workerUnreaped
                if !self.globalNativeLaneHeld, let activity = self.globalNativeActivity {
                    self.activities.removeEndedTask(activity); self.globalNativeActivity = nil
                }
                return
            }
            guard self.pending?.nativeInspection?.reservation?.inspectionID == id || self.recoveredInspection?.id == id else { return }
            if let status, !status.laneHeld, !status.workerUnreaped, self.preparationID == nil {
                self.pending = nil; self.pendingCancellation = nil; self.clearInspectionRecovery()
            } else if let activity = self.pendingActivity {
                let text = status.map { value in
                    value.workerUnreaped ? "Stopping inspection; waiting for owned worker to reap" : "Native inspection: \(value.state.rawValue)"
                } ?? "Inspection status unavailable; shared lane retained; no replay"
                self.activities.updateStatus(activity, status: text)
            }
        }
    }
    private func registerGlobalNativeLane() {
        lock.lock(); defer { lock.unlock() }
        guard globalNativeActivity == nil else { return }
        // This entry carries liveness alone. It has no old Plugin owner,
        // receipt authority, or ability to stop another account's mutation.
        let activity = try? activities.register(owner: .init("host-native-recovery"), pluginName: "Homebrew", kind: "native_lane",
            status: "Native lane busy or recovering; waiting for independent reaping; no replay",
            visibleToOwner: false, removesOnStop: false, stop: {})
        globalNativeActivity = activity?.id
    }
    private func checkInstalledSources(_ bindings: [HomebrewPrivilegePlan.Cask], package: JSONValue) throws {
        let packages: [JSONValue] = { if case .array(let values)? = package.value(atPointer: "/packages") { return values }; return [package] }()
        for binding in bindings {
            guard let tap = binding.installedTap else { continue }
            try checkSource(.object(["tap": .string(tap), "kind": .string("cask"), "name": .string(binding.name)]))
            if let selected = packages.first(where: { $0.value(atPointer: "/name") == .string(binding.name) }),
               case .string(let selectedTap)? = selected.value(atPointer: "/tap"), selectedTap != tap {
                throw PluginHostServiceError.tool(.sourceNotAllowed)
            }
        }
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
    private static func checkOptions(_ input: HomebrewTaskInput, package: JSONValue, prefix: URL) throws {
        if input.operation == "autoremove" {
            guard package.value(atPointer: "/available") == .bool(true), package.value(atPointer: "/succeeded") == .bool(true),
                  package.value(atPointer: "/complete") == .bool(true), package.value(atPointer: "/no_op") == .bool(false),
                  case .array(let packages)? = package.value(atPointer: "/packages"), (1...2000).contains(packages.count),
                  packages.allSatisfy({ record in
                      guard record.value(atPointer: "/kind") == .string("formula"), case .string(let name)? = record.value(atPointer: "/name") else { return false }
                      return HomebrewTaskInput.validPackageName(name)
                  }), Set(packages.compactMap { $0.value(atPointer: "/name") }).count == packages.count else { throw PluginHostServiceError.tool(.planChanged) }
        }
        if ["link", "unlink"].contains(input.operation) {
            guard package.value(atPointer: "/link_preview/succeeded") == .bool(true),
                  package.value(atPointer: "/link_preview/complete") == .bool(true),
                  package.value(atPointer: "/link_preview/no_op") == .bool(false),
                  package.value(atPointer: "/link_preview/truncated") == .bool(false),
                  case .string(let fingerprint)? = package.value(atPointer: "/link_preview/paths_fingerprint"), fingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  case .array(let values)? = package.value(atPointer: "/link_preview/paths"), (1...2000).contains(values.count), Set(values).count == values.count,
                  values.allSatisfy({ value in
                      guard case .string(let path) = value else { return false }
                      return path.utf8.count <= 2048 && path.hasPrefix(prefix.path + "/") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && URL(fileURLWithPath: path).standardizedFileURL.path == path
                  }), case .array(let changes)? = package.value(atPointer: "/link_preview/changes"), changes.count == values.count else { throw PluginHostServiceError.tool(.planChanged) }
            var destinations = Set<JSONValue>()
            for change in changes {
                guard case .object(let fields) = change, case .string(let action)? = fields["action"],
                      ["link", "unlink", "mkdir", "rmdir", "update_info_index"].contains(action),
                      let path = fields["path"], values.contains(path), destinations.insert(path).inserted,
                      Set(fields.keys) == (action == "link" ? Set(["action", "path", "source"]) : Set(["action", "path"])) else { throw PluginHostServiceError.tool(.planChanged) }
                if action == "link" {
                    guard case .string(let source)? = fields["source"], source.utf8.count <= 2048, source.hasPrefix("/"),
                          !source.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), URL(fileURLWithPath: source).standardizedFileURL.path == source else { throw PluginHostServiceError.tool(.planChanged) }
                }
            }
        }
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
            let current = try HomebrewReadProfile.executeCancellable(executable, ["services", "list", "--json"], HomebrewReadProfile.environment, Date().addingTimeInterval(15), cancellation)
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
        if ["link", "unlink"].contains(input.operation) {
            let preview = try profile.read(.object(["tool": .string("homebrew"), "operation": .string(input.operation == "link" ? "previewLink" : "previewUnlink"), "kind": .string(input.kind), "names": names]), owner: PluginID("host-task-preflight"), timeout: 15, cancellation: cancellation)
            guard case .object(var fields) = package else { throw PluginHostServiceError.tool(.planChanged) }
            fields["link_preview"] = preview
            let planned = JSONValue.object(fields)
            try checkOptions(input, package: planned, prefix: HomebrewManagementReads.prefix(of: executable))
            return planned
        }
        return package
    }
    public static func readTrustedTaps(executable: URL) throws -> [String] {
        try readTrustedEntries(kind: "tap", executable: executable)
    }
    private static func readTrustedEntries(kind: String, executable: URL) throws -> [String] {
        guard ["tap", "formula", "cask"].contains(kind) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let result = try HomebrewReadProfile.execute(executable, ["trust", "--" + kind, "--json=v1"], HomebrewReadProfile.environment, Date().addingTimeInterval(15))
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
