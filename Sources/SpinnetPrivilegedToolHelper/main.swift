import Foundation
import Security
import CryptoKit
import Darwin
import SpinnetCore

// launchd runs this signed helper as root. XPC checks every message's signing
// requirement (macOS 13+); PID lookup is used only for task ancestry/liveness,
// never as the source of code-signing authority.
enum NativeExecutionUnknownFailure: Error { case unknown(String) }
struct Approval {
    let pid: pid_t
    let identity: UInt64
    let right: String
    let expires: TimeInterval
}
struct HostAdmission {
    let plan: HomebrewPrivilegePlan
    let pid: pid_t
    let identity: UInt64
    let uid: uid_t
    let expires: TimeInterval
    var inspectionCapture: HomebrewNativeInspection.Capture? = nil
}
final class Task {
    let plan: HomebrewPrivilegePlan
    let pid: pid_t
    let identity: UInt64
    let uid: uid_t
    var usedAuthorizations = Set<String>()
    var approvals: [String: Approval] = [:]
    var process: HomebrewTaskProcess?
    var stopped = false
    var executing = false
    var ended = false
    var receipts: [String: HomebrewReceiptRemoval.Snapshot] = [:]
    var removedPaths = Set<String>()
    var completedReceipts: [String: HomebrewPrivilegePlan.Receipt] = [:]
    var completedDaemons: [String: HomebrewPrivilegePlan.LaunchDaemon] = [:]
    var sourceCatalogs: [String: HomebrewSignedCaskCatalog.Evidence] = [:]
    var pathManifests: [String: HomebrewPathManifest.Manifest] = [:]
    var completedPathActions = Set<String>()
    var ownershipIndex: HomebrewReceiptOwnership.Index?
    var origins: [String: HomebrewNativeOriginAdmission.Capture] = [:]
    var ownedStages = Set<String>()
    var retainedStages = Set<String>()
    var startedCodeActions = Set<String>()
    var completedRemovalCode = Set<String>()
    var launchManifests: [String: HomebrewNativeLaunchServices.Manifest] = [:]
    var completedLaunchPhases = Set<String>()
    var continuation: HomebrewNativeInstallerContinuation?
    var expandedSourceBytes: Int64 = 0
    var expandedSourceEntries = 0
    var inspectionOperation: NativeInspectionOperation?
    var recoveryLane: URL?
    let quarantine = URL(fileURLWithPath: "/private/var/tmp/spinnet-native-" + UUID().uuidString.lowercased())
    init(plan: HomebrewPrivilegePlan, pid: pid_t, identity: UInt64, uid: uid_t) {
        self.plan = plan; self.pid = pid; self.identity = identity; self.uid = uid
    }
}
final class State {
    var updating = false
    let lock = NSLock()
    var tasks: [String: Task] = [:]
    var admissions: [String: HostAdmission] = [:]
    var inspection: NativeInspectionOperation?
    var inspectionRecoveryUnavailable = false
    var terminalInspection: (HomebrewNativeInspection.Peer, HomebrewNativeInspection.Status)?
    func stop(_ id: String) { lock.lock(); let task = tasks[id]; task?.stopped = true; task?.process?.stop(); lock.unlock() }
}
let state = State()
private var loadedHelperRevision = ""
private func accountHome(_ uid: uid_t) throws -> String {
    var record = passwd(), result: UnsafeMutablePointer<passwd>?, buffer = [CChar](repeating: 0, count: 64 * 1024)
    let home = buffer.withUnsafeMutableBufferPointer { bytes -> String? in
        guard getpwuid_r(uid, &record, bytes.baseAddress!, bytes.count, &result) == 0, result != nil, let text = record.pw_dir else { return nil }
        return String(validatingUTF8: text)
    }
    guard let home else { throw PluginHostServiceError.tool(.planChanged) }; return home
}
private func nativeWillStart(_ process: HomebrewTaskProcess, task: Task) -> Bool {
    state.lock.lock(); defer { state.lock.unlock() }
    guard !task.stopped, task.process == nil else { return false }
    task.process = process; return true
}
private func nativeDidReap(_ process: HomebrewTaskProcess, task: Task) {
    state.lock.lock()
    if task.process === process { task.process = nil }
    let finished = task.process == nil && !task.executing && (task.ended || HomebrewTaskProcess.startIdentity(task.pid) != task.identity)
    if finished { state.tasks.removeValue(forKey: task.plan.taskID) }
    state.lock.unlock()
    if finished { cleanupKnownStages(task) }
}
private func cleanupKnownStages(_ task: Task) {
    for stage in task.ownedStages.subtracting(task.retainedStages) { try? FileManager.default.removeItem(at: URL(fileURLWithPath: stage)) }
    task.inspectionOperation?.cleanup()
    cleanupNativeTaskLane(task)
}
private func captureOwnership(_ identifiers: Set<String>, task: Task, deadline: Date) throws -> HomebrewReceiptOwnership.Index {
    try NativeReceiptInventoryWorker.capture(identifiers, deadline: deadline, maximumMetadataBytes: 64 * 1024 * 1024,
        isCancelled: { nativeCancelled(task) }, willStart: { nativeWillStart($0, task: task) },
        didReap: { nativeDidReap($0, task: task) })
}
private func validateOwnership(_ task: Task) throws {
    guard let reference = task.ownershipIndex else { return }
    let forgotten = Set(task.completedReceipts.keys)
    let remaining = Set(reference.exports.keys).subtracting(forgotten)
    let live = try captureOwnership(remaining, task: task, deadline: Date().addingTimeInterval(30))
    try HomebrewReceiptOwnership.validateLiveSources(reference: reference, live: live, forgotten: forgotten)
}
private func nativeCancelled(_ task: Task) -> Bool {
    state.lock.lock(); defer { state.lock.unlock() }
    return task.stopped || HomebrewTaskProcess.startIdentity(task.pid) != task.identity
}

final class HostEndpoint: NSObject, HomebrewPrivilegeHostProtocol {
    let pid: pid_t; let uid: uid_t; let identity: UInt64?
    init(_ connection: NSXPCConnection) { pid = connection.processIdentifier; uid = connection.effectiveUserIdentifier; identity = HomebrewTaskProcess.startIdentity(connection.processIdentifier) }
    func refreshForUpdate(_ expectedRevision: String, reply: @escaping (String, String) -> Void) {
        do {
            guard uid != 0, let identity, HomebrewTaskProcess.startIdentity(pid) == identity,
                  expectedRevision.range(of: "^[a-f0-9]{40,64}$", options: .regularExpression) != nil else { throw PluginHostServiceError.tool(.planChanged) }
            guard try HomebrewBackgroundUpdate.helperRevision(at: HomebrewBackgroundUpdate.currentExecutableURL()) == expectedRevision else { throw PluginHostServiceError.tool(.planChanged) }
            state.lock.lock(); defer { state.lock.unlock() }
            if state.updating { reply("restarting", ""); return }
            let busy = !state.tasks.isEmpty || !state.admissions.isEmpty || state.inspection != nil || state.inspectionRecoveryUnavailable
            if try HomebrewBackgroundUpdate.needsRestart(loadedRevision: loadedHelperRevision, expectedRevision: expectedRevision, hasWork: busy) {
                state.updating = true
                reply("restarting", "")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { exit(0) }
            } else { reply(loadedHelperRevision, "") }
        } catch { reply("", error.localizedDescription) }
    }
    func admit(_ data: Data, reply: @escaping (String) -> Void) {
        do {
            guard uid != 0, let identity = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.failed) }
            let plan = try HomebrewPrivilegePlan.decodeValidated(data)
            state.lock.lock(); defer { state.lock.unlock() }
            guard !state.updating, state.tasks.isEmpty, state.admissions.isEmpty, state.inspection == nil, !state.inspectionRecoveryUnavailable,
                  plan.casks.allSatisfy({ ($0.receipts ?? []).isEmpty }) else { throw PluginHostServiceError.tool(.busy) }
            state.admissions[plan.taskID] = HostAdmission(plan: plan, pid: pid, identity: identity, uid: uid, expires: ProcessInfo.processInfo.systemUptime + 60)
            reply("")
        } catch { reply("Authenticated Host admission was refused") }
    }
    func cancel(_ taskID: String, reply: @escaping () -> Void) {
        state.lock.lock()
        if let admission = state.admissions[taskID], admission.pid == pid, admission.uid == uid, HomebrewTaskProcess.startIdentity(pid) == admission.identity { state.admissions.removeValue(forKey: taskID) }
        state.lock.unlock(); reply()
    }
    func control(_ data: Data, stop: Bool, reply: @escaping (Bool, String) -> Void) {
        do {
            guard uid != 0, identity != nil, HomebrewTaskProcess.startIdentity(pid) == identity else { throw PluginHostServiceError.tool(.failed) }
            let plan = try HomebrewPrivilegePlan.decodeValidated(data)
            state.lock.lock(); defer { state.lock.unlock() }
            if let task = state.tasks[plan.taskID] {
                guard task.uid == uid, task.plan == plan else { throw PluginHostServiceError.tool(.planChanged) }
                if stop { task.stopped = true; task.process?.stop() }
                // The Root Task exists until its owned worker is actually
                // reaped. A new signed same-account Host may stop it without
                // receiving credentials, a PID, or execution admission.
                reply(true, "")
            } else if let admission = state.admissions[plan.taskID] {
                guard admission.uid == uid, admission.plan == plan else { throw PluginHostServiceError.tool(.planChanged) }
                if stop { state.admissions.removeValue(forKey: plan.taskID); reply(false, "") }
                else { reply(true, "") }
            } else {
                guard !state.inspectionRecoveryUnavailable else { throw HomebrewNativeInspection.Failure.workerUnreaped }
                reply(false, "")
            }
        } catch { reply(true, "Authenticated Root Task control is unavailable or the same-account admitted plan changed; no execution authority was granted") }
    }
}
final class RunnerEndpoint: NSObject, HomebrewPrivilegeRunnerProtocol {
    let pid: pid_t; let uid: uid_t
    init(_ connection: NSXPCConnection) { pid = connection.processIdentifier; uid = connection.effectiveUserIdentifier }
    func begin(_ data: Data, reply: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
        do {
            guard uid != 0, let identity = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.failed) }
            let plan = try HomebrewPrivilegePlan.decodeValidated(data)
            state.lock.lock()
            guard state.tasks.isEmpty, let admission = state.admissions[plan.taskID], admission.plan == plan, admission.uid == uid,
                  admission.expires > ProcessInfo.processInfo.systemUptime, HomebrewTaskProcess.startIdentity(admission.pid) == admission.identity,
                  HomebrewSystemAuthorization.processParent(pid) == admission.pid else { state.lock.unlock(); throw PluginHostServiceError.tool(.planChanged) }
            // Bind the authenticated runner before lengthy read-only work. A
            // later Host crash must not revoke this confirmed independent Task.
            let task = Task(plan: plan, pid: pid, identity: identity, uid: uid)
            let inspected = admission.inspectionCapture
            guard plan.casks.allSatisfy({ ($0.receipts ?? []).isEmpty }) || inspected != nil else { state.lock.unlock(); throw PluginHostServiceError.tool(.planChanged) }
            task.executing = true
            do { try persistNativeTaskLane(task) }
            catch {
                task.executing = false
                state.lock.unlock(); cleanupNativeTaskLane(task)
                throw error
            }
            if let operation = state.inspection, operation.session.record.draft.taskID == plan.taskID, operation.session.state == .admitted {
                task.inspectionOperation = operation; state.inspection = nil
            }
            state.admissions.removeValue(forKey: plan.taskID); state.tasks[plan.taskID] = task
            state.lock.unlock()
            var began = false
            defer {
                state.lock.lock(); task.executing = false
                if !began {
                    task.ended = true; task.stopped = true; task.process?.stop()
                    if task.process == nil { state.tasks.removeValue(forKey: plan.taskID) }
                }
                let cleanup = !began && task.process == nil
                state.lock.unlock()
                if cleanup { cleanupKnownStages(task) }
            }
            // Freeze every manifest before the first mutation. Directory
            // timestamps changed by another admitted receipt are not authority.
            var snapshots: [String: HomebrewReceiptRemoval.Snapshot] = [:]
            var deadline = Date().addingTimeInterval(30)
            var catalogs: [String: HomebrewSignedCaskCatalog.Evidence] = [:]
            var expandedOriginBytes: Int64 = 0, expandedOriginEntries = 0
            let originDeadline = Date().addingTimeInterval(180)
            for cask in plan.casks where !cask.sha256.isEmpty {
                guard let proof = cask.sourceProof, catalogs.count < 4 || catalogs[proof.envelopeSHA256] != nil else { throw PluginHostServiceError.tool(.outputTooLarge) }
                let evidence = try catalogs[proof.envelopeSHA256] ?? HomebrewSignedCaskCatalog.load(proof.envelope, deadline: deadline)
                catalogs[proof.envelopeSHA256] = evidence
                try cask.validatePublisherSource(prefix: plan.prefix, owner: uid, deadline: deadline, evidence: evidence)
                state.lock.lock(); let stopped = task.stopped; state.lock.unlock()
                guard !stopped else { throw PluginHostServiceError.tool(.planChanged) }
            }
            for cask in plan.casks {
                guard let code = cask.removalCode else { continue }
                let codeDeadline = min(originDeadline, Date().addingTimeInterval(15))
                let proof = code.source
                guard catalogs.count < 4 || catalogs[proof.envelopeSHA256] != nil else { throw PluginHostServiceError.tool(.outputTooLarge) }
                let evidence = try catalogs[proof.envelopeSHA256] ?? HomebrewSignedCaskCatalog.load(proof.envelope, deadline: codeDeadline)
                _ = try code.verify(owner: uid, prefix: plan.prefix, deadline: codeDeadline, evidence: evidence)
                catalogs[proof.envelopeSHA256] = evidence
                let installed = try HomebrewInstalledUninstall.read(name: cask.name, prefix: plan.prefix)
                guard installed.version == code.version, installed.tap == cask.installedTap,
                      installed.fingerprint == cask.installedFingerprint else { throw PluginHostServiceError.tool(.planChanged) }
                for original in code.origins ?? [] {
                    let captured: HomebrewNativeOriginAdmission.Capture
                    do { captured = try HomebrewNativeOriginAdmission.capture(source: code.source, name: cask.name,
                        evidence: evidence, download: code.download, recipeExecutable: original.recipeExecutable,
                        owner: uid, deadline: originDeadline, maximumBytes: 8 * 1024 * 1024 * 1024 - expandedOriginBytes,
                        maximumEntries: 50_000 - expandedOriginEntries, isCancelled: { nativeCancelled(task) },
                        willStart: { nativeWillStart($0, task: task) }, didReap: { nativeDidReap($0, task: task) }) }
                    catch NativeFileQuarantine.Failure.retained(let directory) {
                        task.ownedStages.insert(directory.path); task.retainedStages.insert(directory.path)
                        throw NativeExecutionUnknownFailure.unknown(directory.path)
                    }
                    task.ownedStages.insert(captured.directory.path)
                    guard captured.proof == original else { throw PluginHostServiceError.tool(.planChanged) }
                    expandedOriginBytes += captured.proof.expandedBytes; expandedOriginEntries += captured.proof.expandedEntries
                    guard expandedOriginBytes <= 8 * 1024 * 1024 * 1024, expandedOriginEntries <= 50_000 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    task.origins[cask.name + ":" + original.recipeExecutable] = captured
                    task.expandedSourceBytes = expandedOriginBytes; task.expandedSourceEntries = expandedOriginEntries
                }
            }
            let launchDeadline = Date().addingTimeInterval(30)
            for cask in plan.casks { for grant in cask.launchServiceRemovals ?? [] {
                guard grant.context.uid == uid, grant.manifestURL.path.hasPrefix(grant.context.home.path + "/Library/Application Support/Spinnet/native-source-evidence/") else { throw PluginHostServiceError.tool(.planChanged) }
                let frozen = try grant.load(owner: uid, deadline: launchDeadline)
                let actual = try HomebrewNativeLaunchServiceCapture.capture(context: grant.context, declarations: grant.declarations,
                    deadline: launchDeadline, isCancelled: { nativeCancelled(task) }, willStart: { nativeWillStart($0, task: task) }, didReap: { nativeDidReap($0, task: task) })
                guard actual == frozen else { throw PluginHostServiceError.tool(.planChanged) }
                task.launchManifests[cask.name + ":" + grant.phase.rawValue] = frozen
            } }
            let identifiers = Set(plan.casks.flatMap { ($0.receipts ?? []).map(\.identifier) })
            let receiptDeadline = Date().addingTimeInterval(30)
            if !identifiers.isEmpty {
                var exclusions: [String: Set<String>] = [:]
                for cask in plan.casks {
                    var paths = Set((cask.launchDaemons ?? []).map(\.path))
                    for grant in cask.launchServiceRemovals ?? [] { guard let manifest = task.launchManifests[cask.name + ":" + grant.phase.rawValue] else { throw PluginHostServiceError.tool(.planChanged) }; paths.formUnion(manifest.entries.flatMap(\.plists).filter(\.removeFile).map { $0.path.path }) }
                    if let grant = cask.kernelExtensionRemoval?.paths { paths.formUnion(try grant.load(owner: uid, deadline: receiptDeadline).entries.map(\.path)) }
                    for receipt in cask.receipts ?? [] { exclusions[receipt.identifier, default: []].formUnion(paths) }
                }
                let launchContext = try HomebrewNativeLaunchServices.Context(uid: uid, home: URL(fileURLWithPath: task.launchManifests.values.first?.context.home.path ?? accountHome(uid)))
                let captured = try NativeReceiptInventoryWorker.captureManifests(.init(selected: identifiers, excludedPaths: exclusions, launchContext: launchContext), deadline: receiptDeadline,
                    isCancelled: { nativeCancelled(task) }, willStart: { nativeWillStart($0, task: task) }, didReap: { nativeDidReap($0, task: task) })
                guard let complete = captured.snapshots, let ownership = captured.index else { throw PluginHostServiceError.tool(.failed) }
                if let inspected {
                    try HomebrewNativeInspectionReceipts.validateLive(inspected, live: ownership)
                    let reference = try JSONDecoder().decode(NativeReceiptInventoryWorker.Response.self, from: inspected.privateInventory)
                    guard let original = reference.index else { throw PluginHostServiceError.tool(.planChanged) }
                    task.ownershipIndex = original
                } else { task.ownershipIndex = ownership }
                for cask in plan.casks { for receipt in cask.receipts ?? [] {
                    guard let snapshot = complete[receipt.identifier], snapshot.receipt == receipt else { throw PluginHostServiceError.tool(.planChanged) }
                    snapshots[cask.name + ":" + receipt.identifier] = snapshot
                } }
            }
            deadline = Date().addingTimeInterval(60)
            var pathManifests: [String: HomebrewPathManifest.Manifest] = [:]
            if plan.casks.contains(where: { !($0.pathRemovals ?? []).isEmpty || $0.kernelExtensionRemoval != nil }) {
                var account = passwd(), accountResult: UnsafeMutablePointer<passwd>?, buffer = [CChar](repeating: 0, count: 16 * 1024)
                let home: String? = buffer.withUnsafeMutableBufferPointer { bytes in
                    guard getpwuid_r(uid, &account, bytes.baseAddress!, bytes.count, &accountResult) == 0,
                          accountResult != nil, let value = account.pw_dir else { return nil }
                    return String(validatingUTF8: value)
                }
                guard let home else { throw PluginHostServiceError.tool(.planChanged) }
                let tools = try NativeSignedToolStaging.capture(["SpinnetPathInventory"], deadline: deadline, isCancelled: {
                    state.lock.lock(); defer { state.lock.unlock() }; return task.stopped
                })
                defer { tools.remove() }
                let worker = try HomebrewPathManifest.WorkerConfiguration(executable: tools.tools["SpinnetPathInventory"]!)
                for cask in plan.casks {
                    if let kernel = cask.kernelExtensionRemoval {
                        guard kernel.valid, kernel.context.home.path == home, kernel.context.prefix.path == plan.prefix else { throw PluginHostServiceError.tool(.planChanged) }
                        let actual = try HomebrewNativeKextRemoval.capture(identifiers: kernel.identifiers, context: kernel.context, worker: worker, deadline: deadline, isCancelled: {
                            state.lock.lock(); defer { state.lock.unlock() }; return task.stopped
                        })
                        try kernel.verify(actual)
                        if let grant = kernel.paths {
                            guard grant.manifestURL.path.hasPrefix(home + "/Library/Application Support/Spinnet/native-source-evidence/") else { throw PluginHostServiceError.tool(.planChanged) }
                            let frozen = try grant.load(owner: uid, deadline: deadline)
                            guard actual.manifest == frozen else { throw PluginHostServiceError.tool(.planChanged) }
                            pathManifests[cask.name + ":kernel"] = frozen
                        }
                    }
                    for (index, action) in (cask.pathRemovals ?? []).enumerated() {
                        let grant = action.grant
                        guard action.valid, grant.context.home.path == home, grant.context.prefix.path == plan.prefix,
                              grant.manifestURL.path.hasPrefix(home + "/Library/Application Support/Spinnet/native-source-evidence/") else { throw PluginHostServiceError.tool(.planChanged) }
                        let frozen = try grant.load(owner: uid, deadline: deadline)
                        let actual = try HomebrewPathManifest.capture(grant.directives, context: grant.context, worker: worker, deadline: deadline, isCancelled: {
                            state.lock.lock(); defer { state.lock.unlock() }; return task.stopped
                        })
                        guard actual == frozen else { throw PluginHostServiceError.tool(.planChanged) }
                        pathManifests[cask.name + ":" + String(index)] = frozen
                    }
                }
            }
            state.lock.lock(); defer { state.lock.unlock() }
            guard !task.stopped, HomebrewTaskProcess.startIdentity(pid) == identity else { throw PluginHostServiceError.tool(.planChanged) }
            try NativeFileQuarantine.makePrivateDirectory(task.quarantine)
            task.receipts = snapshots
            task.sourceCatalogs = catalogs; task.pathManifests = pathManifests
            began = true
            reply("")
        } catch NativeExecutionUnknownFailure.unknown(let directory) { reply("Read-only native source admission is incomplete or unknown; no mutation/replay. Recovery stage retained at " + directory) }
        catch { reply("The privileged Task plan was refused") }
        }
    }
    func stop(_ taskID: String, reply: @escaping () -> Void) { owned(taskID) { state.stop(taskID) }; reply() }
    func continuation(_ taskID: String, reply: @escaping (String) -> Void) {
        var result = ""
        owned(taskID) { state.lock.lock(); result = state.tasks[taskID]?.continuation?.rawValue ?? ""; state.lock.unlock() }
        reply(result)
    }
    func end(_ taskID: String, reply: @escaping () -> Void) {
        owned(taskID) {
            state.stop(taskID)
            state.lock.lock(); state.tasks[taskID]?.ended = true
            let finished = state.tasks[taskID].flatMap { $0.process == nil && !$0.executing ? $0 : nil }
            if finished != nil { state.tasks.removeValue(forKey: taskID) }; state.lock.unlock()
            if let finished { cleanupKnownStages(finished) }
        }; reply()
    }
    private func owned(_ id: String, operation: () -> Void) {
        state.lock.lock(); let task = state.tasks[id]; state.lock.unlock()
        if let task, task.pid == pid, task.uid == uid, HomebrewTaskProcess.startIdentity(pid) == task.identity { operation() }
    }

}
final class ClientEndpoint: NSObject, HomebrewPrivilegeClientProtocol {
    let pid: pid_t; let uid: uid_t
    init(_ connection: NSXPCConnection) { pid = connection.processIdentifier; uid = connection.effectiveUserIdentifier }
    func prepare(_ data: Data, reply: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in prepareRequest(data, reply: reply) }
    }
    private func prepareRequest(_ data: Data, reply: @escaping (String) -> Void) {
        do {
            guard data.count <= 16 * 1024, let identity = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.failed) }
            let request = try JSONDecoder().decode(HomebrewPrivilegeRequest.self, from: data)
            state.lock.lock(); let task = state.tasks[request.taskID]; state.lock.unlock()
            guard let task, task.uid == uid, !task.stopped, HomebrewSystemAuthorization.descends(pid, from: task.pid, identity: task.identity) else { throw PluginHostServiceError.tool(.planChanged) }
            try task.plan.validate(request)
            state.lock.lock()
            guard !task.stopped, !task.executing, task.process == nil, task.approvals.isEmpty else { state.lock.unlock(); throw PluginHostServiceError.tool(.busy) }
            task.executing = true; state.lock.unlock()
            defer { state.lock.lock(); task.executing = false; state.lock.unlock() }
            if request.operation == .removeLaunchServices,
               let cask = task.plan.casks.first(where: { $0.name == request.package }),
               let grant = cask.launchServiceRemovals?.first(where: { $0.phase.rawValue == request.source }),
               let frozen = task.launchManifests[cask.name + ":" + request.source] {
                let key = cask.name + ":launch:" + request.source
                guard !task.completedLaunchPhases.contains(key), !task.startedCodeActions.contains(key) else { throw PluginHostServiceError.tool(.planChanged) }
                if try grant.revalidateEmptyRemoval(frozen, capture: {
                    try HomebrewNativeLaunchServiceCapture.capture(context: grant.context, declarations: grant.declarations,
                        deadline: Date().addingTimeInterval(30), isCancelled: { nativeCancelled(task) },
                        willStart: { nativeWillStart($0, task: task) }, didReap: { nativeDidReap($0, task: task) })
                }) {
                    guard !nativeCancelled(task) else { throw PluginHostServiceError.tool(.planChanged) }
                    task.completedLaunchPhases.insert(key)
                    reply(HomebrewSystemAuthorization.noLaunchServicesToRemove); return
                }
            }
            let right = HomebrewSystemAuthorization.right + "." + UUID().uuidString.lowercased()
            try HomebrewSystemAuthorization.configureRight(right)
            state.lock.lock()
            guard !task.stopped, task.approvals.isEmpty else { state.lock.unlock(); HomebrewSystemAuthorization.removeRight(right); throw PluginHostServiceError.tool(.busy) }
            task.approvals[HomebrewSystemAuthorization.digest(data)] = Approval(pid: pid, identity: identity, right: right, expires: ProcessInfo.processInfo.systemUptime + 120)
            state.lock.unlock()
            reply(right)
        } catch { reply("Cannot prepare the reviewed operation: " + error.localizedDescription) }
    }
    func perform(_ data: Data, authorization: Data, reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                guard data.count <= 16 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                let request = try JSONDecoder().decode(HomebrewPrivilegeRequest.self, from: data)
                state.lock.lock(); let task = state.tasks[request.taskID]; state.lock.unlock()
                guard let task, task.uid == uid, !task.stopped,
                      HomebrewSystemAuthorization.descends(pid, from: task.pid, identity: task.identity) else { throw PluginHostServiceError.tool(.planChanged) }
                try task.plan.validate(request)
                let key = HomebrewSystemAuthorization.digest(authorization)
                state.lock.lock()
                let approval = task.approvals.removeValue(forKey: HomebrewSystemAuthorization.digest(data))
                let fresh = task.usedAuthorizations.count < task.plan.authorizationLimit && task.usedAuthorizations.insert(key).inserted && task.process == nil && !task.executing && !task.stopped
                if fresh { task.executing = true }
                state.lock.unlock()
                defer {
                    if fresh {
                        state.lock.lock(); task.executing = false
                        let finished = task.process == nil && (task.ended || HomebrewTaskProcess.startIdentity(task.pid) != task.identity)
                        if finished { state.tasks.removeValue(forKey: task.plan.taskID) }
                        state.lock.unlock()
                        if finished { cleanupKnownStages(task) }
                    }
                }
                guard let approval else { throw PluginHostServiceError.tool(.planChanged) }
                defer { HomebrewSystemAuthorization.removeRight(approval.right) }
                guard fresh, approval.pid == pid, HomebrewTaskProcess.startIdentity(pid) == approval.identity, approval.expires > ProcessInfo.processInfo.systemUptime, HomebrewSystemAuthorization.check(authorization, rightName: approval.right) else { throw PluginHostServiceError.unavailable("System authorization refused or already consumed") }
                switch request.operation {
                case .removeLaunchServices:
                    try removeLaunchServices(request, task: task, reply: reply)
                case .removePaths:
                    try removePaths(request, task: task, reply: reply)
                case .removeKernelExtensions:
                    try removeKernelExtensions(request, task: task, reply: reply)
                case .executeRemovalCode:
                    try executeRemovalCode(request, task: task, reply: reply)
                case .executeVendorScript:
                    try executeVendor(request, task: task, reply: reply)
                case .installPackage: try install(request, task: task, reply: reply)
                case .removeReceipt:
                    try removeReceipt(request, task: task)
                    reply(0, "Reviewed receipt-owned files removed and receipt forgotten; nonempty directories retained. Changes are not rolled back")
                case .removeLaunchDaemon:
                    try removeLaunchDaemon(request, task: task)
                    reply(0, "Reviewed system launch daemon removed; changes are not rolled back")
                case .repairOwnership:
                    try repair(request.source, task: task)
                    reply(0, "Reviewed ownership repair completed")
                }
            } catch NativeExecutionUnknownFailure.unknown(let recovery) {
                reply(70, "The native command did not reap within its Stop/deadline grace; outcome is unknown. Its execution lane and recovery records are retained; no replay. Recovery records at " + recovery)
            } catch NativeFileQuarantine.Failure.retained(let retained) {
                // This concrete root-owned recovery location stays on disk.
                // Never run an automatic recursive cleanup after a collision.
                reply(70, "Native cleanup could not restore a quarantined item. Outcome remains incomplete; no replay. Root-owned recovery item retained at " + retained.path)
            } catch { reply(77, "Reviewed privileged operation refused, failed or stopped; partial changes are not rolled back and no replay was performed") }
        }
    }
    private func removePaths(_ request: HomebrewPrivilegeRequest, task: Task, reply: @escaping (Int32, String) -> Void) throws {
        let key = request.package + ":" + request.source
        guard let manifest = task.pathManifests[key], manifest.sha256 == request.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
        if task.completedPathActions.contains(key) {
            guard !cancelled(task) else { throw PluginHostServiceError.tool(.planChanged) }
            reply(0, "This exact confirmed cleanup phase already finished; it was not replayed"); return
        }
        let outcome = try executePathManifest(manifest, task: task)
        if let progress = outcome.response?.result { task.removedPaths.formUnion(progress.removed) }
        switch outcome.state {
        case .completed:
            guard let progress = outcome.response?.result else { throw PluginHostServiceError.tool(.failed) }
            task.completedPathActions.insert(key)
            reply(0, "Confirmed native cleanup finished: \(progress.removed.count) removed, \(progress.retained.count) nonempty directories retained. Changes are not rolled back")
        case .failed:
            state.stop(task.plan.taskID)
            let removed = outcome.response?.result?.removed.count ?? 0, retained = outcome.response?.result?.retained.count ?? 0
            reply(77, "Native cleanup refused, stopped or partially failed: \(removed) known removed, \(retained) retained. No completion or replay; recovery records at " + task.quarantine.path)
        case .unknown:
            state.stop(task.plan.taskID)
            reply(70, "Native cleanup outcome is unknown after Stop/deadline/invalid response; no replay. Recovery records retained at " + task.quarantine.path)
        }
    }
    private func executePathManifest(_ manifest: HomebrewPathManifest.Manifest, task: Task) throws -> HomebrewNativePathExecution.Outcome {
        return try HomebrewNativePathExecution.execute(manifest, staging: task.quarantine, deadline: Date().addingTimeInterval(60),
            isCancelled: { self.cancelled(task) }, willStart: { nativeWillStart($0, task: task) }, didReap: { nativeDidReap($0, task: task) })
    }
    private func removeKernelExtensions(_ request: HomebrewPrivilegeRequest, task: Task, reply: @escaping (Int32, String) -> Void) throws {
        guard let cask = task.plan.casks.first(where: { $0.name == request.package }), let grant = cask.kernelExtensionRemoval else { throw PluginHostServiceError.tool(.planChanged) }
        let key = cask.name + ":kernel"
        guard !task.completedPathActions.contains(key) else { throw PluginHostServiceError.tool(.planChanged) }
        var requestedUnload = false
        for identifier in grant.identifiers {
            guard HomebrewNativeKextRemoval.validIdentifier(identifier) else { throw PluginHostServiceError.tool(.planChanged) }
            var loadedOutput = Data()
            let queried = try runNative("/usr/bin/kmutil", ["showloaded", "--variant-suffix", "release", "--optional-identifier", identifier, "--list-only", "--no-kernel-components"], task: task, timeout: 30, captureOutput: { loadedOutput = $0 })
            guard queried.outcome == "completed", queried.exitStatus == 0 else { throw PluginHostServiceError.unavailable("macOS kernel-extension loaded state could not be verified; no unload or cleanup was performed") }
            guard try HomebrewNativeKextRemoval.isLoaded(loadedOutput, identifier: identifier) else { continue }
            let result = try runNative("/usr/bin/kmutil", ["unload", "--bundle-identifier", identifier], task: task, timeout: 120)
            guard result.outcome == "completed", result.exitStatus == 0 else {
                reply(result.exitStatus, "macOS refused or could not unload the confirmed kernel extension. Security consent or restart may be required; uninstall is incomplete and no retry was performed"); return
            }
            requestedUnload = true
        }
        if let manifest = task.pathManifests[key] {
            let outcome = try executePathManifest(manifest, task: task)
            if let progress = outcome.response?.result { task.removedPaths.formUnion(progress.removed) }
            guard outcome.state == .completed else {
                state.stop(task.plan.taskID)
                reply(outcome.state == .unknown ? 70 : 77, "Kernel extension unload was requested, but bundle cleanup is incomplete or unknown; restart may be required. No replay; recovery records at " + task.quarantine.path); return
            }
        } else { guard grant.paths == nil else { throw PluginHostServiceError.tool(.planChanged) } }
        task.completedPathActions.insert(key)
        if requestedUnload { task.continuation = .requireRestart; reply(79, "Confirmed kernel-extension unload/removal was requested. macOS requires restart to finish unloading; the Task remains incomplete until restart. No automatic restart or replay was performed") }
        else { reply(0, "The exact confirmed extension IDs are absent from the verified loaded list; frozen bundle cleanup completed") }
    }
    private func install(_ request: HomebrewPrivilegeRequest, task: Task, reply: @escaping (Int32, String) -> Void) throws {
        guard let cask = task.plan.casks.first(where: { $0.name == request.package }), !request.archive.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        try installImmutable(cask, request: request, task: task, reply: reply)
    }
    private func installImmutable(_ cask: HomebrewPrivilegePlan.Cask, request: HomebrewPrivilegeRequest, task: Task, sourcePurpose: HomebrewNativeSourceStaging.Purpose? = nil, reply: @escaping (Int32, String) -> Void) throws {
        let captured = try stageSource(cask, archive: request.archive, purpose: sourcePurpose ?? .packageInstaller(path: request.relativePackage), task: task)
        let staging = captured.directory
        defer { discardStageIfReaped(staging, task: task) }
        guard captured.proof.selectedMember == request.relativePackage else { throw PluginHostServiceError.tool(.planChanged) }
        let payload = staging.appendingPathComponent(captured.proof.resourceDirectory)
        guard try HomebrewArchiveStaging.fingerprint(payload, deadline: Date().addingTimeInterval(120), isCancelled: { self.cancelled(task) }) == captured.proof.resourceTreeSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
        let target = captured.proof.installerFile.map { staging.appendingPathComponent($0) } ?? payload.appendingPathComponent(captured.proof.selectedMember)
        let options = cask.packageInstallers?.first(where: { $0.path == request.relativePackage }) ?? .init(path: request.relativePackage)
        var arguments = ["-pkg", target.path, "-target", "/"]
        if options.allowUntrusted { arguments.append("-allowUntrusted") }
        if let xml = try options.choicesXML() {
            let choices = staging.appendingPathComponent("choices.plist")
            let fd = open(choices.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(fd) }
            try xml.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard written > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += written
                }
            }
            guard fsync(fd) == 0 else { throw PluginHostServiceError.tool(.failed) }
            arguments += ["-applyChoiceChangesXML", choices.path]
        }
        // Even read-only Installer metadata may evaluate a distribution's
        // code. Consume this confirmed package action before the first tool
        // entry, rather than permitting metadata-query replay.
        try consumeCode(cask.name + ":package:" + HomebrewSystemAuthorization.digest(try JSONEncoder().encode(captured.proof.purpose)), sourceSHA256: captured.proof.sourceSHA256, downloadSHA256: captured.proof.downloadSHA256, task: task)
        var restartMetadata = Data()
        let query = try runNative("/usr/sbin/installer", ["-query", "RestartAction", "-pkg", target.path], task: task, timeout: 30, captureOutput: { restartMetadata = $0 })
        let continuation = try HomebrewNativeInstallerContinuation.parse(restartMetadata, exitStatus: query.exitStatus)
        let result = try runNative("/usr/sbin/installer", arguments, task: task, timeout: 7200)
        if result.exitStatus == 0, result.outcome == "completed", let reason = continuation.reason {
            task.continuation = continuation
            reply(79, "The verified macOS installer requires \(reason) to finish. The Task remains incomplete; no automatic logout, shutdown, restart or installer replay occurred")
            return
        }
        reply(result.outcome == "stopped" ? 130 : result.exitStatus, result.outcome == "completed" ? "Reviewed macOS package installation completed" : "The macOS installer failed or was stopped; changes are not rolled back")
    }
    private func executeVendor(_ request: HomebrewPrivilegeRequest, task: Task, reply: @escaping (Int32, String) -> Void) throws {
        guard let cask = task.plan.casks.first(where: { $0.name == request.package }), let index = Int(request.source),
              let scripts = cask.nativeScripts, scripts.indices.contains(index), scripts[index].phase == .install,
              cask.sourceProof != nil else { throw PluginHostServiceError.tool(.planChanged) }
        try consumeCode(cask.name + ":vendor-install:" + request.source, sourceSHA256: cask.sourceProof!.envelopeSHA256, downloadSHA256: cask.sha256, task: task)
        try executeImmutableVendor(cask, script: scripts[index], archivePath: request.archive, task: task, reply: reply)
    }
    private func consumeCode(_ key: String, sourceSHA256: String, downloadSHA256: String, task: Task) throws {
        guard !task.startedCodeActions.contains(key) else { throw PluginHostServiceError.unavailable("This confirmed native code action was already attempted; no replay") }
        try writeNativeRecovery(try JSONSerialization.data(withJSONObject: ["taskID": task.plan.taskID, "action": key,
            "sourceSHA256": sourceSHA256, "downloadSHA256": downloadSHA256, "state": "consumed", "replay": false]),
            to: task.quarantine.appendingPathComponent("consumed-code-" + HomebrewSystemAuthorization.digest(Data(key.utf8)) + ".json"))
        task.startedCodeActions.insert(key)
    }
    private func executeRemovalCode(_ request: HomebrewPrivilegeRequest, task: Task, reply: @escaping (Int32, String) -> Void) throws {
        guard let cask = task.plan.casks.first(where: { $0.name == request.package }), let code = cask.removalCode,
              let index = Int(request.source), code.actions.indices.contains(index),
              let evidence = task.sourceCatalogs[code.source.envelopeSHA256] else { throw PluginHostServiceError.tool(.planChanged) }
        _ = try code.verify(owner: task.uid, prefix: task.plan.prefix, deadline: Date().addingTimeInterval(15), evidence: evidence)
        let installed = try HomebrewInstalledUninstall.read(name: cask.name, prefix: task.plan.prefix)
        guard installed.version == code.version, installed.tap == cask.installedTap, installed.fingerprint == cask.installedFingerprint else { throw PluginHostServiceError.tool(.planChanged) }
        let action = code.actions[index]
        let key = cask.name + ":removal:" + request.source
        try consumeCode(key, sourceSHA256: code.source.envelopeSHA256, downloadSHA256: code.download.sha256, task: task)
        let source = HomebrewPrivilegePlan.Cask(name: cask.name, version: code.version, sha256: code.download.sha256,
            packages: action.package.map { [$0.path] } ?? [], packageInstallers: action.package.map { [$0] },
            nativeScripts: [action.script], generatedResources: code.generatedResources, sourceProof: code.source,
            downloadURL: code.download.sourceURL.absoluteString)
        let completed: (Int32, String) -> Void = { status, message in
            do {
                if status == 0 {
                    // Record only previously frozen receipt entries observed
                    // absent after the confirmed immutable native code action.
                    // Existing modified entries remain refusal, never adoption.
                    for receipt in cask.receipts ?? [] {
                        guard let snapshot = task.receipts[cask.name + ":" + receipt.identifier] else { throw PluginHostServiceError.tool(.planChanged) }
                        for entry in snapshot.entries + snapshot.accountedEntries {
                            if try !NativeFileQuarantine.existsWithoutFollowing(URL(fileURLWithPath: entry.path)) { task.removedPaths.insert(entry.path) }
                        }
                    }
                    task.completedRemovalCode.insert(key)
                }
                reply(status, message)
            } catch { reply(77, "Confirmed native removal ran, but receipt cleanup evidence changed or is incomplete; no replay") }
        }
        if let original = (code.origins ?? []).first(where: { $0.recipeExecutable == action.recipeExecutable }) {
            guard action.kind == .vendor, let capture = task.origins[cask.name + ":" + action.recipeExecutable], capture.proof == original else { throw PluginHostServiceError.tool(.planChanged) }
            let payload = capture.directory.appendingPathComponent(original.resourceDirectory)
            guard try HomebrewArchiveStaging.fingerprint(payload, deadline: Date().addingTimeInterval(120), isCancelled: { self.cancelled(task) }) == original.match.resourceTreeSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
            try executeStagedVendor(source, script: action.script, payload: payload, task: task, reply: completed)
        } else if action.kind == .package, let package = action.package {
            let typed = HomebrewPrivilegeRequest(taskID: task.plan.taskID, package: cask.name, operation: .installPackage,
                source: "", sha256: code.download.sha256, archive: code.download.fileURL.path, relativePackage: package.path)
            try installImmutable(source, request: typed, task: task, sourcePurpose: .packageRemoval(path: package.path), reply: { status, message in
                if status != 0, ![70, 78, 79, 130].contains(status), !action.script.mustSucceed, !self.cancelled(task) {
                    completed(0, "The optional independently reviewed package uninstaller failed; continuing as its source permits. " + message)
                } else { completed(status, message) }
            })
        } else {
            try executeImmutableVendor(source, script: action.script, archivePath: code.download.fileURL.path, task: task, reply: completed)
        }
    }
    private func executeImmutableVendor(_ cask: HomebrewPrivilegePlan.Cask, script: HomebrewPrivilegePlan.NativeScript, archivePath: String,
                                         task: Task, reply: @escaping (Int32, String) -> Void) throws {
        let purpose: HomebrewNativeSourceStaging.Purpose
        if script.phase == .install { purpose = .vendorInstaller(executable: script.executable) }
        else {
            guard let code = task.plan.casks.first(where: { $0.name == cask.name })?.removalCode,
                  let action = code.actions.first(where: { $0.script == script }) else { throw PluginHostServiceError.tool(.planChanged) }
            purpose = .relativeRemoval(recipeExecutable: action.recipeExecutable)
        }
        let captured = try stageSource(cask, archive: archivePath, purpose: purpose, task: task)
        defer { discardStageIfReaped(captured.directory, task: task) }
        guard captured.proof.selectedMember == script.executable else { throw PluginHostServiceError.tool(.planChanged) }
        let payload = captured.directory.appendingPathComponent(captured.proof.resourceDirectory)
        guard try HomebrewArchiveStaging.fingerprint(payload, deadline: Date().addingTimeInterval(120), isCancelled: { self.cancelled(task) }) == captured.proof.resourceTreeSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
        try executeStagedVendor(cask, script: script, payload: payload, task: task, reply: reply)
    }
    private func executeStagedVendor(_ cask: HomebrewPrivilegePlan.Cask, script: HomebrewPrivilegePlan.NativeScript, payload: URL,
                                     task: Task, reply: @escaping (Int32, String) -> Void) throws {
        let executable = payload.appendingPathComponent(script.executable)
        var generatedEnvironment: [String: String] = [:]
        if !(cask.generatedResources ?? []).isEmpty {
            guard let proof = cask.sourceProof, let source = task.sourceCatalogs[proof.envelopeSHA256] else { throw PluginHostServiceError.tool(.planChanged) }
            let neutral = try HomebrewNativeGeneratedScript.neutralConfiguration(languages: proof.configuration.languages)
            let token = String(cask.name.split(separator: "/").last!)
            let metadata = try source.catalog.project(token, configuration: neutral)
            let selection = try HomebrewNativeArtifacts.select(metadata, prefix: neutral.prefix.path, token: token, version: cask.version)
            guard selection.generatedResources.map(\.path) == (cask.generatedResources ?? []).map(\.path),
                  script.generatedContent == nil || selection.generatedResources.contains(where: { $0.path == script.executable }) else { throw PluginHostServiceError.tool(.planChanged) }
            let resources = try selection.generatedResources.map { resource -> HomebrewNativeGeneratedResources.Resource in
                let completedTemplate = HomebrewNativeCompletionPolicy.adapt(resource.content, token: token, version: cask.version) ?? resource.content
                let rendered = try HomebrewNativeGeneratedScript.render(template: completedTemplate, home: proof.configuration.home, prefix: proof.configuration.prefix,
                    appDirectory: proof.configuration.appDirectory, payload: payload, stagedRelativePrefix: "/Caskroom/" + token + "/" + cask.version + "/")
                for (key, value) in rendered.environment {
                    guard generatedEnvironment[key] == nil || generatedEnvironment[key] == value else { throw PluginHostServiceError.tool(.planChanged) }
                    generatedEnvironment[key] = value
                }
                return .init(path: resource.path, content: rendered.content)
            }
            try HomebrewNativeGeneratedResources.stage(resources, into: payload, deadline: Date().addingTimeInterval(30), isCancelled: { self.cancelled(task) })
        }
        let (parent, name) = try NativeFileQuarantine.openParent(executable); defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0, info.st_nlink == 1,
              info.st_mode & 0o077 == 0, fchmod(fd, 0o700) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let result = try runNative(executable.path, script.arguments, task: task, timeout: 7200, standardInput: script.input.map { Data($0.utf8) }, environmentOverrides: generatedEnvironment)
        if result.exitStatus == 78 && HomebrewNativeCompletionPolicy.hasManualOutcome(script, cask: cask) {
            task.continuation = .manualInstallation
            reply(78, "The reviewed installer requires manual action; installation remains incomplete")
        } else if result.outcome == "completed" { reply(0, "Reviewed immutable vendor action completed") }
        else if !script.mustSucceed && result.outcome == "failed" { reply(0, "Optional reviewed vendor action failed; continuing as its verified metadata allows") }
        else { reply(result.exitStatus, "Reviewed vendor action failed or stopped; changes are not rolled back") }
    }
    private func stageSource(_ cask: HomebrewPrivilegePlan.Cask, archive: String, purpose: HomebrewNativeSourceStaging.Purpose, task: Task) throws -> HomebrewNativeOriginAdmission.SourceCapture {
        guard let proof = cask.sourceProof, let evidence = task.sourceCatalogs[proof.envelopeSHA256],
              task.expandedSourceBytes < 8 * 1024 * 1024 * 1024, task.expandedSourceEntries < 50_000 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let snapshot = cask.downloadSnapshot ?? task.plan.casks.first(where: { $0.name == cask.name })?.removalCode.flatMap { $0.noPublisherChecksum == true ? $0.download : nil }
        do {
            let capture = try HomebrewNativeOriginAdmission.stage(source: proof, name: cask.name, evidence: evidence,
                originalDownload: URL(fileURLWithPath: archive), downloadSHA256: cask.sha256, confirmedSnapshot: snapshot,
                purpose: purpose, owner: task.uid, deadline: Date().addingTimeInterval(180),
                maximumBytes: 8 * 1024 * 1024 * 1024 - task.expandedSourceBytes, maximumEntries: 50_000 - task.expandedSourceEntries,
                isCancelled: { self.cancelled(task) }, willStart: { nativeWillStart($0, task: task) }, didReap: { nativeDidReap($0, task: task) })
            task.ownedStages.insert(capture.directory.path)
            task.expandedSourceBytes += capture.proof.expandedBytes; task.expandedSourceEntries += capture.proof.expandedEntries
            return capture
        } catch NativeFileQuarantine.Failure.retained(let directory) {
            task.ownedStages.insert(directory.path); task.retainedStages.insert(directory.path)
            throw NativeExecutionUnknownFailure.unknown(directory.path)
        }
    }
    private func discardStageIfReaped(_ staging: URL, task: Task) {
        state.lock.lock(); let retained = task.process != nil; state.lock.unlock()
        if !retained && !task.retainedStages.contains(staging.path) { try? FileManager.default.removeItem(at: staging) }
        else {
            // Never erase a resource tree that an unknown live process may
            // still read. This is a concrete Root-owned recovery pointer.
            let file = task.quarantine.appendingPathComponent("pending-stage-" + UUID().uuidString.lowercased() + ".json")
            if let data = try? JSONSerialization.data(withJSONObject: ["taskID": task.plan.taskID, "stage": staging.path, "outcome": "unknown", "replay": false]) {
                try? writeNativeRecovery(data, to: file)
            }
        }
    }
    private func writeNativeRecovery(_ data: Data, to file: URL) throws {
        let (parent, name) = try NativeFileQuarantine.openParent(file); defer { close(parent) }
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += written
            }
        }
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw PluginHostServiceError.tool(.failed) }
    }
    private func runNative(_ executable: String, _ arguments: [String], task: Task, timeout: TimeInterval, standardInput: Data? = nil, environmentOverrides: [String: String] = [:], captureOutput: ((Data) -> Void)? = nil) throws -> HomebrewTaskProcess.Result {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        guard Set(environmentOverrides.keys).isSubset(of: ["SPINNET_GENERATED_HOME", "SPINNET_GENERATED_PREFIX", "SPINNET_GENERATED_APPDIR", "SPINNET_GENERATED_PAYLOAD"]) else { throw PluginHostServiceError.tool(.planChanged) }
        environment.merge(environmentOverrides) { _, generated in generated }
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: executable), arguments: arguments,
            environment: environment, interruptGrace: 10, terminateGrace: 5, standardInput: standardInput)
        let record = task.quarantine.appendingPathComponent("native-attempt-" + UUID().uuidString.lowercased() + ".json")
        try writeNativeRecovery(try JSONSerialization.data(withJSONObject: ["taskID": task.plan.taskID, "executable": executable,
            "argumentsSHA256": HomebrewSystemAuthorization.digest(try JSONEncoder().encode(arguments)), "state": "pending", "replay": false]), to: record)
        let outcome = try HomebrewNativeCommandExecution.execute(process, timeout: timeout, maximumOutputBytes: captureOutput == nil ? 0 : 64 * 1024,
            isCancelled: { self.cancelled(task) || HomebrewTaskProcess.startIdentity(task.pid) != task.identity },
            willStart: { nativeWillStart($0, task: task) }, didReap: { nativeDidReap($0, task: task) })
        guard outcome.state == .completed, let result = outcome.result else {
            state.stop(task.plan.taskID); throw NativeExecutionUnknownFailure.unknown(task.quarantine.path)
        }
        captureOutput?(outcome.output)
        let completed = record.deletingPathExtension().appendingPathExtension("completed.json")
        try writeNativeRecovery(try JSONSerialization.data(withJSONObject: ["taskID": task.plan.taskID, "state": result.outcome,
            "exitStatus": result.exitStatus, "replay": false]), to: completed)
        return result
    }
    private func removeLaunchServices(_ request: HomebrewPrivilegeRequest, task: Task, reply: @escaping (Int32, String) -> Void) throws {
        guard let cask = task.plan.casks.first(where: { $0.name == request.package }),
              let phase = HomebrewNativeLaunchServiceGrant.Phase(rawValue: request.source),
              let grant = cask.launchServiceRemovals?.first(where: { $0.phase == phase }),
              let frozen = task.launchManifests[cask.name + ":" + phase.rawValue], frozen.sha256 == grant.manifestSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
        let key = cask.name + ":launch:" + phase.rawValue
        guard !task.completedLaunchPhases.contains(key), !task.startedCodeActions.contains(key) else { throw PluginHostServiceError.unavailable("This confirmed launch-service phase was already attempted; no replay") }
        try validateOwnership(task)
        let actual = try HomebrewNativeLaunchServiceCapture.capture(context: grant.context, declarations: grant.declarations,
            deadline: Date().addingTimeInterval(30), isCancelled: { nativeCancelled(task) }, willStart: { nativeWillStart($0, task: task) }, didReap: { nativeDidReap($0, task: task) })
        guard actual == frozen else { throw PluginHostServiceError.tool(.planChanged) }
        try consumeCode(key, sourceSHA256: grant.bytesSHA256, downloadSHA256: grant.manifestSHA256, task: task)
        for entry in frozen.entries {
            guard !cancelled(task) else { throw PluginHostServiceError.tool(.planChanged) }
            if entry.job != nil {
                let result = try runNative("/bin/launchctl", ["bootout", entry.domain.target + "/" + entry.label], task: task, timeout: 30)
                guard result.exitStatus == 0, result.outcome == "completed" else { throw PluginHostServiceError.unavailable("Confirmed launch-service stop failed or was refused; no service/path replay") }
            }
            for file in entry.plists where file.removeFile {
                let result = try NativeFileQuarantine.remove(file.path, expected: file.frozen, staging: task.quarantine, expectedParent: file.parent,
                    deadline: Date().addingTimeInterval(30), isCancelled: { self.cancelled(task) }, mutation: { action in try self.mutate(task, action: action) })
                guard result == .removed else { throw PluginHostServiceError.tool(.planChanged) }
                task.removedPaths.insert(file.path.path)
            }
        }
        task.completedLaunchPhases.insert(key)
        reply(0, "The confirmed system/current-user launch jobs stopped and only their exact owned plist targets were removed; aliases and other-user services were retained. Changes are not rolled back")
    }
    private func removeLaunchDaemon(_ request: HomebrewPrivilegeRequest, task: Task) throws {
        try validateOwnership(task)
        guard let daemon = task.plan.casks.first(where: { $0.name == request.package })?.launchDaemons?.first(where: { $0.label == request.source }) else { throw PluginHostServiceError.tool(.planChanged) }
        let target = "system/" + daemon.label
        if let completed = task.completedDaemons[daemon.label] {
            guard completed == daemon, !cancelled(task), try !NativeFileQuarantine.existsWithoutFollowing(URL(fileURLWithPath: daemon.path)),
                  try runNative("/bin/launchctl", ["print", target], task: task, timeout: 15).exitStatus == 113 else { throw PluginHostServiceError.tool(.planChanged) }
            return
        }
        guard try HomebrewPrivilegePlan.captureLaunchDaemon(daemon.label) == daemon else { throw PluginHostServiceError.tool(.planChanged) }
        let existing = try runNative("/bin/launchctl", ["print", target], task: task, timeout: 15)
        // launchctl's fixed missing-service outcome is ESRCH-domain 113;
        // permission and other failures never become successful removals.
        if existing.exitStatus == 0 {
            let stopped = try runNative("/bin/launchctl", ["bootout", target], task: task, timeout: 30)
            guard stopped.exitStatus == 0 else { throw PluginHostServiceError.tool(.failed) }
        } else if existing.exitStatus != 113 { throw PluginHostServiceError.tool(.failed) }
        let absent = try runNative("/bin/launchctl", ["print", target], task: task, timeout: 15)
        guard absent.exitStatus == 113, try HomebrewPrivilegePlan.captureLaunchDaemon(daemon.label) == daemon else { throw PluginHostServiceError.tool(.planChanged) }
        guard let frozen = daemon.frozen else { throw PluginHostServiceError.tool(.planChanged) }
        guard try NativeFileQuarantine.remove(URL(fileURLWithPath: daemon.path), expected: frozen, staging: task.quarantine, isCancelled: { self.cancelled(task) }, mutation: { try self.mutate(task, action: $0) }) == .removed else { throw PluginHostServiceError.tool(.planChanged) }
        task.removedPaths.insert(daemon.path)
        task.completedDaemons[daemon.label] = daemon
    }
    private func removeReceipt(_ request: HomebrewPrivilegeRequest, task: Task) throws {
        guard let cask = task.plan.casks.first(where: { $0.name == request.package }),
              let receipt = cask.receipts?.first(where: { $0.identifier == request.source }) else { throw PluginHostServiceError.tool(.planChanged) }
        if let completed = task.completedReceipts[receipt.identifier] {
            guard completed == receipt, !cancelled(task) else { throw PluginHostServiceError.tool(.planChanged) }
            guard let snapshot = task.receipts[cask.name + ":" + receipt.identifier] else { throw PluginHostServiceError.tool(.planChanged) }
            try verifyRemovals(snapshot, task: task, deadline: Date().addingTimeInterval(30))
            return
        }
        guard let snapshot = task.receipts[cask.name + ":" + receipt.identifier] else { throw PluginHostServiceError.tool(.planChanged) }
        guard snapshot.receipt == receipt else { throw PluginHostServiceError.tool(.planChanged) }
        try validateOwnership(task)
        try HomebrewReceiptRemoval.validateReceipt(snapshot)
        for entry in snapshot.accountedEntries {
            guard task.removedPaths.contains(entry.path), try !NativeFileQuarantine.existsWithoutFollowing(URL(fileURLWithPath: entry.path)) else { throw PluginHostServiceError.tool(.planChanged) }
        }
        let deadline = Date().addingTimeInterval(30)
        // Every file was checked before mutation. Each protected parent stays
        // open through the final identity check and descriptor-relative unlink.
        let files = snapshot.entries.filter { !$0.directory }
        let directories = snapshot.entries.filter(\.directory).sorted { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }
        for entry in files + directories {
            try HomebrewReceiptRemoval.validateFilesystem(snapshot, deadline: deadline)
            if task.removedPaths.contains(entry.path) {
                guard try !NativeFileQuarantine.existsWithoutFollowing(URL(fileURLWithPath: entry.path)) else { throw PluginHostServiceError.tool(.planChanged) }; continue
            }
            let current = try HomebrewReceiptRemoval.captureEntry(entry.path, deadline: deadline, isCancelled: { self.cancelled(task) })
            guard current == entry else { throw PluginHostServiceError.tool(.planChanged) }
            let outcome = try NativeFileQuarantine.remove(URL(fileURLWithPath: entry.path), expected: entry.frozen, staging: task.quarantine, deadline: deadline, isCancelled: { self.cancelled(task) }, mutation: { try self.mutate(task, action: $0) })
            if outcome == .removed { task.removedPaths.insert(entry.path) }
        }
        try verifyRemovals(snapshot, task: task, deadline: deadline)
        try validateOwnership(task)
        let forgotten = try runNative("/usr/sbin/pkgutil", ["--forget", receipt.identifier], task: task, timeout: 30)
        guard forgotten.exitStatus == 0 else { throw PluginHostServiceError.tool(.failed) }
        task.completedReceipts[receipt.identifier] = receipt
    }
    private func verifyRemovals(_ snapshot: HomebrewReceiptRemoval.Snapshot, task: Task, deadline: Date) throws {
        for entry in snapshot.entries + snapshot.accountedEntries {
            guard !cancelled(task), Date() < deadline else { throw PluginHostServiceError.tool(.planChanged) }
            if try NativeFileQuarantine.existsWithoutFollowing(URL(fileURLWithPath: entry.path)) {
                guard entry.directory, try HomebrewReceiptRemoval.captureEntry(entry.path, deadline: deadline, isCancelled: { self.cancelled(task) }) == entry else { throw PluginHostServiceError.tool(.planChanged) }
            }
        }
    }
    private func cancelled(_ task: Task) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return task.stopped || HomebrewTaskProcess.startIdentity(task.pid) != task.identity
    }
    private func mutate(_ task: Task, action: () throws -> Void) throws {
        // Hold Stop's lock only for the concrete filesystem operation. Hashing
        // remains cancellable outside this lock and cannot delay Stop.
        state.lock.lock(); defer { state.lock.unlock() }
        guard !task.stopped, HomebrewTaskProcess.startIdentity(task.pid) == task.identity else { throw PluginHostServiceError.tool(.planChanged) }
        try action()
    }
    private func repair(_ path: String, task: Task) throws {
        // Descriptor-relative traversal refuses symlinks and multiple hard
        // links. No path returned by an untrusted directory can escape the
        // selected prefix, and every changed inode stays open during chown.
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path else { throw PluginHostServiceError.tool(.planChanged) }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        // Refuse unsupported entries before starting the repair. Each inode
        // is checked again during the second traversal before any mutation.
        var count = 0
        try visit(descriptor, device: info.st_dev, depth: 0, count: &count, deadline: deadline, task: task, mutate: false)
        count = 0
        try visit(descriptor, device: info.st_dev, depth: 0, count: &count, deadline: deadline, task: task, mutate: true)
    }
    private func visit(_ descriptor: Int32, device: dev_t, depth: Int, count: inout Int, deadline: TimeInterval, task: Task, mutate: Bool) throws {
        state.lock.lock(); let stopped = task.stopped; state.lock.unlock()
        count += 1
        guard !stopped, depth <= 64, count <= 100_000, ProcessInfo.processInfo.systemUptime < deadline,
              HomebrewTaskProcess.startIdentity(task.pid) == task.identity else { throw PluginHostServiceError.tool(.planChanged) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_dev == device,
              info.st_mode & S_IFMT == S_IFDIR || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else { throw PluginHostServiceError.tool(.planChanged) }
        if info.st_mode & S_IFMT == S_IFDIR {
            let duplicate = dup(descriptor)
            guard duplicate >= 0 else { throw PluginHostServiceError.tool(.failed) }
            guard let directory = fdopendir(duplicate) else { close(duplicate); throw PluginHostServiceError.tool(.failed) }
            defer { closedir(directory) }
            rewinddir(directory)
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    guard errno == 0 else { throw PluginHostServiceError.tool(.failed) }; break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                guard !name.contains("/"), !name.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
                let child = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard child >= 0 else { throw PluginHostServiceError.unavailable("Ownership repair refuses symbolic links and unreadable entries; use the displayed manual guidance") }
                defer { close(child) }
                try visit(child, device: device, depth: depth + 1, count: &count, deadline: deadline, task: task, mutate: mutate)
            }
        }
        if mutate, info.st_uid == 0, fchown(descriptor, task.uid, gid_t.max) != 0 { throw PluginHostServiceError.tool(.failed) }
    }
}
final class Listener: NSObject, NSXPCListenerDelegate {
    enum Endpoint { case host, runner, client, inspectionHost, inspectionClient }
    let endpoint: Endpoint
    init(_ endpoint: Endpoint) { self.endpoint = endpoint }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        switch endpoint {
        case .host: connection.exportedInterface = NSXPCInterface(with: HomebrewPrivilegeHostProtocol.self); connection.exportedObject = HostEndpoint(connection)
        case .runner: connection.exportedInterface = NSXPCInterface(with: HomebrewPrivilegeRunnerProtocol.self); connection.exportedObject = RunnerEndpoint(connection)
        case .client: connection.exportedInterface = NSXPCInterface(with: HomebrewPrivilegeClientProtocol.self); connection.exportedObject = ClientEndpoint(connection)
        case .inspectionHost:
            guard let peer = try? HomebrewNativeInspectionAuthorization.hostPeer(connection) else { return false }
            connection.exportedInterface = NSXPCInterface(with: HomebrewNativeInspectionHostProtocol.self); connection.exportedObject = NativeInspectionHostEndpoint(peer)
        case .inspectionClient:
            connection.exportedInterface = NSXPCInterface(with: HomebrewNativeInspectionClientProtocol.self); connection.exportedObject = NativeInspectionClientEndpoint(connection)
        }
        connection.resume(); return true
    }
}
do {
    // Read-only packaged validation also exercises launchd's relative argv[0].
    // It must not initialize recovery, listen on XPC or request authorization.
    if CommandLine.arguments == [CommandLine.arguments[0], "--verify-signature"] {
        print(try HomebrewBackgroundUpdate.helperRevision(at: HomebrewBackgroundUpdate.currentExecutableURL()))
        exit(0)
    }
    guard getuid() == 0 else { exit(77) }
    loadedHelperRevision = try HomebrewBackgroundUpdate.helperRevision(at: HomebrewBackgroundUpdate.currentExecutableURL())
    try initializeNativeInspectionRecovery()
    let hostDelegate = Listener(.host), runnerDelegate = Listener(.runner), clientDelegate = Listener(.client)
    let inspectionHostDelegate = Listener(.inspectionHost), inspectionClientDelegate = Listener(.inspectionClient)
    let host = NSXPCListener(machServiceName: HomebrewSystemAuthorization.service + ".host")
    let runner = NSXPCListener(machServiceName: HomebrewSystemAuthorization.service + ".runner")
    let client = NSXPCListener(machServiceName: HomebrewSystemAuthorization.service + ".client")
    let inspectionHost = NSXPCListener(machServiceName: HomebrewNativeInspectionAuthorization.hostService)
    let inspectionClient = NSXPCListener(machServiceName: HomebrewNativeInspectionAuthorization.clientService)
    host.setConnectionCodeSigningRequirement(try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.hostIdentifier))
    runner.setConnectionCodeSigningRequirement(try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.runnerIdentifier))
    client.setConnectionCodeSigningRequirement(try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.clientIdentifier))
    inspectionHost.setConnectionCodeSigningRequirement(try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.hostIdentifier))
    inspectionClient.setConnectionCodeSigningRequirement(try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.clientIdentifier))
    host.delegate = hostDelegate; runner.delegate = runnerDelegate; client.delegate = clientDelegate; host.resume(); runner.resume(); client.resume()
    inspectionHost.delegate = inspectionHostDelegate; inspectionClient.delegate = inspectionClientDelegate; inspectionHost.resume(); inspectionClient.resume()
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler {
        tickNativeInspection()
        state.lock.lock()
        state.admissions = state.admissions.filter { $0.value.expires > ProcessInfo.processInfo.systemUptime && HomebrewTaskProcess.startIdentity($0.value.pid) == $0.value.identity }
        let tasks = Array(state.tasks.values); state.lock.unlock()
        for task in tasks {
            state.lock.lock()
            let expired = task.approvals.filter { $0.value.expires < ProcessInfo.processInfo.systemUptime || task.stopped || HomebrewTaskProcess.startIdentity($0.value.pid) != $0.value.identity }
            for key in expired.keys { task.approvals.removeValue(forKey: key) }
            state.lock.unlock()
            expired.values.forEach { HomebrewSystemAuthorization.removeRight($0.right) }
            guard HomebrewTaskProcess.startIdentity(task.pid) != task.identity else { continue }
            state.stop(task.plan.taskID)
            state.lock.lock(); let finished = task.process == nil && !task.executing
            if finished { state.tasks.removeValue(forKey: task.plan.taskID) }; state.lock.unlock()
            if finished { cleanupKnownStages(task) }
        }
    }; timer.resume()
    RunLoop.current.run()
} catch {
    FileHandle.standardError.write(Data(("Spinnet background component startup failed: \(error.localizedDescription)\n").utf8))
    exit(77)
}
