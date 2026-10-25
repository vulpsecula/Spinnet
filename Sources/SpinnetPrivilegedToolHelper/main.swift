import Foundation
import Darwin
import SpinnetCore

// launchd runs this signed helper as root. XPC checks every message's signing
// requirement (macOS 13+); PID lookup is used only for task ancestry/liveness,
// never as the source of code-signing authority.
struct HostAdmission {
    let plan: HomebrewPrivilegePlan
    let pid: pid_t
    let identity: UInt64
    let uid: uid_t
    let expires: TimeInterval
}
final class Task {
    let plan: HomebrewPrivilegePlan
    let pid: pid_t
    let identity: UInt64
    let uid: uid_t
    var process: HomebrewTaskProcess?
    var stopped = false
    var executing = false
    var ended = false
    var ownedStages = Set<String>()
    var retainedStages = Set<String>()
    var inspectionOperation: NativeInspectionOperation?
    var recoveryLane: URL?
    var continuation: HomebrewNativeInstallerContinuation?
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
let retiredExecutionMessage = "Legacy Root execution is retired. New Homebrew Tasks use the native CLI; existing Task status and Stop remain available."
private func cleanupKnownStages(_ task: Task) {
    for stage in task.ownedStages.subtracting(task.retainedStages) { try? FileManager.default.removeItem(at: URL(fileURLWithPath: stage)) }
    task.inspectionOperation?.cleanup()
    cleanupNativeTaskLane(task)
}

final class HostEndpoint: NSObject, HomebrewPrivilegeHostProtocol {
    #if SPINNET_BACKGROUND_LIFECYCLE_FIXTURE
    func lifecycleSnapshot(reply: @escaping (Int32, String, String) -> Void) {
        #if SPINNET_BACKGROUND_LIFECYCLE_NEXT
        reply(getpid(), loadedHelperRevision, "next")
        #else
        reply(getpid(), loadedHelperRevision, "baseline")
        #endif
    }
    #endif
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
        #if SPINNET_BACKGROUND_LIFECYCLE_FIXTURE
        // The isolated lifecycle fixture holds only an admission lane. Even
        // this build's runner and mutation clients cannot execute old plans.
        do {
            guard uid != 0, let identity = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.failed) }
            let plan = try HomebrewPrivilegePlan.decodeValidated(data)
            state.lock.lock(); defer { state.lock.unlock() }
            guard !state.updating, state.tasks.isEmpty, state.admissions.isEmpty, state.inspection == nil, !state.inspectionRecoveryUnavailable,
                  plan.casks.allSatisfy({ ($0.receipts ?? []).isEmpty }) else { throw PluginHostServiceError.tool(.busy) }
            state.admissions[plan.taskID] = HostAdmission(plan: plan, pid: pid, identity: identity, uid: uid, expires: ProcessInfo.processInfo.systemUptime + 60)
            reply("")
        } catch { reply("Authenticated Host admission was refused") }
        #else
        reply(retiredExecutionMessage)
        #endif
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
        reply(retiredExecutionMessage)
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
/// Protocol tombstone for previously signed clients. No request can create
/// an authorization right, stage an artifact or perform a Root mutation.
final class ClientEndpoint: NSObject, HomebrewPrivilegeClientProtocol {
    init(_ connection: NSXPCConnection) {}
    func prepare(_ data: Data, reply: @escaping (String) -> Void) {
        reply(retiredExecutionMessage)
    }
    func perform(_ data: Data, authorization: Data, reply: @escaping (Int32, String) -> Void) {
        reply(77, retiredExecutionMessage)
    }
}

/// Exercises the actual exported endpoint implementations before Root startup.
/// No connection is resumed and no recovery directory or listener is created.
private func verifyRetiredEntrypoints() throws {
    #if SPINNET_BACKGROUND_LIFECYCLE_FIXTURE
    throw PluginHostServiceError.unavailable("Verify retirement using the production helper, not the isolated lifecycle fixture")
    #else
    let connection = NSXPCConnection(machServiceName: "com.vulpsecula.Spinnet.retirement-verification")
    defer { connection.invalidate() }
    let host = HostEndpoint(connection), runner = RunnerEndpoint(connection), client = ClientEndpoint(connection)
    let peer = HomebrewNativeInspection.Peer(uid: getuid(), pid: getpid(), startIdentity: HomebrewTaskProcess.startIdentity(getpid()) ?? 1,
        auditSession: 0, designatedRequirementSHA256: String(repeating: "a", count: 64))
    let inspectionHost = NativeInspectionHostEndpoint(peer), inspectionClient = NativeInspectionClientEndpoint(connection)
    let plan = try HomebrewPrivilegePlan(taskID: "activity_1234567890abcdef1234567890abcdef", prefix: "/opt/homebrew", casks: [
        .init(name: "retirement-fixture", version: "1", sha256: String(repeating: "a", count: 64), packages: ["NeverExecuted.pkg"])
    ])
    let valid = try JSONEncoder().encode(plan)
    _ = try HomebrewPrivilegePlan.decodeValidated(valid)
    let id = "inspection_12345678-1234-1234-1234-123456789abc"
    var refused: [String: Int] = [:]
    func check(_ name: String, _ invoke: (@escaping (String) -> Void) -> Void) throws {
        var replies: [String] = []
        invoke { replies.append($0) }
        guard replies == [retiredExecutionMessage], state.tasks.isEmpty, state.admissions.isEmpty,
              state.inspection == nil, !state.inspectionRecoveryUnavailable, !state.updating else {
            throw PluginHostServiceError.unavailable("Retired entrypoint accepted authority or changed Root state: " + name)
        }
        refused[name, default: 0] += 1
    }
    for data in [Data(), Data([0xff]), valid] {
        try check("host.admit") { host.admit(data, reply: $0) }
        try check("runner.begin") { runner.begin(data, reply: $0) }
        try check("client.prepare") { client.prepare(data, reply: $0) }
        try check("client.perform") { reply in
            client.perform(data, authorization: valid) { status, message in reply(status == 77 ? message : "Unexpected execution status") }
        }
        try check("inspection.reserve") { reply in
            inspectionHost.reserve(data) { body, message in reply(body.isEmpty ? message : "Unexpected inspection reservation") }
        }
        try check("inspection.confirmInspection") { reply in
            inspectionHost.confirmInspection(id) { right, message in reply(right.isEmpty ? message : "Unexpected inspection right") }
        }
        try check("inspection.acknowledgeReview") { inspectionHost.acknowledgeReview(data, reply: $0) }
        try check("inspection.confirmMutation") { reply in
            inspectionHost.confirmMutation(data) { right, message in reply(right.isEmpty ? message : "Unexpected mutation right") }
        }
        try check("inspection.inspect") { reply in
            inspectionClient.inspect(data, authorization: valid) { body, message in reply(body.isEmpty ? message : "Unexpected inspection capture") }
        }
        try check("inspection.validateAdmission") { inspectionClient.validateAdmission(data, authorization: valid, reply: $0) }
    }
    let report: [String: Any] = ["retiredEndpoints": refused, "requestsRefused": refused.values.reduce(0, +),
                               "rootStateUntouched": true, "rootStartupSkipped": true]
    let body = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print(String(decoding: body, as: UTF8.self))
    #endif
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
    if CommandLine.arguments == [CommandLine.arguments[0], "--verify-retired-entrypoints"] {
        try verifyRetiredEntrypoints()
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
