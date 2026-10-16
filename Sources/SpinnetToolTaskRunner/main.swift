import Foundation
import Darwin
import IOKit.pwr_mgt
import SpinnetCore

// Packaging smoke check: no Task, source read, authorization or subprocess.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--verify-resources" {
    guard Bundle.module.url(forResource: "HomebrewPrivilegeBridge", withExtension: "rb") != nil else { exit(70) }
    print("Reviewed Task runner resources available")
    exit(0)
}

// Fixed Host-owned journal entry, never arbitrary Plugin process input. The
// directory is private to this account; the runner refuses symlinked roots,
// mismatched handles, an already-started record or any inherited mutation.
do {
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--task-directory" else { exit(64) }
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { exit(77) }
    var record = try HomebrewTaskJournal.load(from: directory)
    guard record.id == directory.lastPathComponent, record.result == nil, record.processGroup == nil else { exit(77) }
    defer {
        if record.result == nil {
            record.result = .object(["outcome": .string("failed"), "reason": .string("runner_refused")])
            record.ended = Date(); try? record.save(to: directory)
        }
    }
    guard let runnerBirth = HomebrewTaskProcess.startIdentity(getpid()) else { throw PluginHostServiceError.tool(.failed) }
    var lease = HomebrewTaskProcessLease(taskID: record.id, runnerPID: getpid(), runnerIdentity: runnerBirth)
    try lease.save(to: directory)
    record.runnerPID = getpid(); record.runnerIdentity = runnerBirth; try record.save(to: directory)
    let input = try HomebrewTaskInput(record.input)
    let steps = try record.steps?.map(HomebrewTaskInput.init) ?? [input]
    guard !steps.isEmpty, steps.count <= 80, steps.allSatisfy({ !$0.arguments.isEmpty }),
          record.steps == nil || steps.allSatisfy({ $0.operation == "upgradeSelected" }) || (record.stepMetadata?.count == steps.count && steps.count <= 8 && steps.allSatisfy({ ["cleanup", "link"].contains($0.operation) })),
          try HomebrewReadProfile.discover().path == record.executable else { exit(77) }
    let lock = NSLock(), finished = DispatchSemaphore(value: 0), log = HomebrewTaskLog()
    var sleepAssertion: IOPMAssertionID = 0
    guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Spinnet Homebrew Task" as CFString, &sleepAssertion) == kIOReturnSuccess else { exit(70) }
    defer { IOPMAssertionRelease(sleepAssertion) }
    ProcessInfo.processInfo.disableSuddenTermination(); ProcessInfo.processInfo.disableAutomaticTermination("Reviewed Homebrew Task")
    defer { ProcessInfo.processInfo.enableSuddenTermination(); ProcessInfo.processInfo.enableAutomaticTermination("Reviewed Homebrew Task") }
    var environment = HomebrewReadProfile.environment
    environment["HOMEBREW_NO_BOOTSNAP"] = "1"
    environment["HOMEBREW_NO_INSTALL_UPGRADE"] = "1"; environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
    environment["TERM"] = "dumb"
    record.runnerPID = getpid(); record.runnerIdentity = HomebrewTaskProcess.startIdentity(getpid())
    var privilegeConnection: NSXPCConnection?
    var privilegeProxy: HomebrewPrivilegeRunnerProtocol?
    if let privilegePlan = record.privilegePlan, privilegePlan.requiresSystemAuthorization {
        let connection = try HomebrewSystemAuthorization.runnerConnection()
        let ready = DispatchSemaphore(value: 0)
        var failure = "The signed privileged helper is unavailable"
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in ready.signal() }) as? HomebrewPrivilegeRunnerProtocol else { exit(77) }
        proxy.begin(try JSONEncoder().encode(privilegePlan)) { failure = $0; ready.signal() }
        // Receipt inventory is bounded30s; immutable source origin admission
        // has one aggregate180s worker budget, followed by30s receipt
        // manifest and60s typed-path admission budgets. Stop remains responsive while
        // read-only admission runs; it never starts a brew/install replay.
        let admissionDeadline = ProcessInfo.processInfo.systemUptime + 330
        var admissionReady = false
        var cancelledAdmission = false
        while true {
            if ready.wait(timeout: .now() + 0.1) == .success { admissionReady = failure.isEmpty; break }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) || ProcessInfo.processInfo.systemUptime >= admissionDeadline {
                cancelledAdmission = FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path)
                proxy.stop(record.id) {}; break
            }
        }
        cancelledAdmission = cancelledAdmission || FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path)
        guard admissionReady, !cancelledAdmission else {
            proxy.stop(record.id) {}
            record.result = cancelledAdmission ? .object(["outcome": .string("stopped"), "stop": .string("interrupted")]) : .object(["outcome": .string("failed"), "reason": .string("system_authorization_unavailable")]); record.ended = Date(); try record.save(to: directory)
            connection.invalidate(); exit(cancelledAdmission ? 130 : 77)
        }
        privilegeConnection = connection; privilegeProxy = proxy
        environment["HOMEBREW_SPINNET_TASK_ID"] = record.id
    }
    defer { privilegeConnection?.invalidate() }
    var lastResult: HomebrewTaskProcess.Result?
    func reserveProcess() throws {
        lock.lock(); defer { lock.unlock() }
        lease.reservation = UUID().uuidString.lowercased(); lease.leaderPID = nil; lease.leaderIdentity = nil; lease.members = [:]; lease.observedAt = Date()
        try lease.save(to: directory)
    }
    func observeProcess(_ process: HomebrewTaskProcess) throws {
        lock.lock(); defer { lock.unlock() }
        guard lease.reservation != nil else { return }
        let identities = process.ownedProcessIdentities
        if identities.count > HomebrewTaskProcessLease.maximumMembers { lease.ownershipUncertain = true; try lease.save(to: directory); throw PluginHostServiceError.tool(.outputTooLarge) }
        if let birth = identities[process.processIdentifier] { lease.leaderPID = process.processIdentifier; lease.leaderIdentity = birth }
        lease.members = Dictionary(uniqueKeysWithValues: identities.map { (String($0.key), $0.value) })
        lease.observedAt = Date(); try lease.save(to: directory)
    }
    func noSpawn(_ process: HomebrewTaskProcess) {
        guard process.processIdentifier == 0 else { return }
        lock.lock(); defer { lock.unlock() }
        lease.reservation = nil; lease.leaderPID = nil; lease.leaderIdentity = nil; lease.members = [:]; lease.observedAt = Date()
        try? lease.save(to: directory)
    }
    func reapedProcess(_ result: HomebrewTaskProcess.Result) {
        lock.lock(); defer { lock.unlock() }
        if !lease.ownershipUncertain { lease.reservation = nil; lease.leaderPID = nil; lease.leaderIdentity = nil; lease.members = [:] }
        lease.observedAt = Date()
        do { try lease.save(to: directory); lastResult = lease.ownershipUncertain ? .init(outcome: "unknown", exitStatus: 70, stop: result.stop) : result }
        catch { lastResult = .init(outcome: "unknown", exitStatus: 70, stop: result.stop) }
        finished.signal()
    }

    for (index, step) in steps.enumerated() {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
            lastResult = .init(outcome: "stopped", exitStatus: 130, stop: "interrupted"); break
        }
        let metadata = record.stepMetadata?[index] ?? record.package
        if step.operation == "autoremove" {
            // Repeat the guarded preview in the independent runner, before its
            // one mutation spawn. A drifted command or inventory never retargets
            // the Host-confirmed global operation.
            guard try HostReviewedToolTasks.preflight(step, executable: URL(fileURLWithPath: record.executable)) == metadata else { throw PluginHostServiceError.tool(.planChanged) }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
                lastResult = .init(outcome: "stopped", exitStatus: 130, stop: "interrupted"); break
            }
            log.append(Data("Reviewed operation: brew autoremove\n".utf8))
            if case .string(let output)? = metadata.value(atPointer: "/stdout") { log.append(Data(output.utf8)) }
            record.log = log.lines; try record.save(to: directory)
        }
        var arguments = metadata.value(atPointer: "/adopt") == .bool(true) && step.operation == "install" && step.kind == "cask"
            ? ["install", "--cask", "--adopt", "--", step.name] : step.arguments
        var executable = URL(fileURLWithPath: record.executable)
        if metadata.value(atPointer: "/privileged_repair") == .bool(true) {
            guard record.privilegePlan != nil, HomebrewOwnershipRepair.isCurrent(metadata), case .array(let values)? = metadata.value(atPointer: "/repair_directories") else { throw PluginHostServiceError.tool(.planChanged) }
            executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("SpinnetToolAuthorizationClient")
            // Each fixed directory requests its own fresh system authorization.
            // The root helper also checks this source against the runner's plan.
            for value in values {
                guard case .string(let path) = value else { throw PluginHostServiceError.tool(.planChanged) }
                let process = HomebrewTaskProcess(executable: executable, arguments: ["--repair-directory", path], environment: environment)
                try reserveProcess()
                do { try process.start(output: { data in lock.lock(); log.append(data); record.log = log.lines; try? record.save(to: directory); lock.unlock() }, finished: { result in reapedProcess(result) }) }
                catch { noSpawn(process); throw error }
                do { try observeProcess(process) } catch { process.stop(); privilegeProxy?.stop(record.id) {} }
                while finished.wait(timeout: .now() + 0.1) == .timedOut {
                    do { try observeProcess(process) } catch { process.stop(); privilegeProxy?.stop(record.id) {} }
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) { process.stop(); privilegeProxy?.stop(record.id) {} }
                }
                if lastResult?.outcome != "completed" { break }
            }
            if lastResult?.outcome != "completed" { break }
            continue
        }
        if let privilegePlan = record.privilegePlan, !privilegePlan.casks.isEmpty, step.kind == "cask" {
            guard let bridge = Bundle.module.url(forResource: "HomebrewPrivilegeBridge", withExtension: "rb") else { throw PluginHostServiceError.tool(.failed) }
            let client = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("SpinnetToolAuthorizationClient")
            let context: [String: JSONValue] = ["arguments": .array(arguments.map(JSONValue.string)), "client": .string(client.path),
                "manualOutcome": .string(directory.appendingPathComponent("manual-outcome.json").path), "taskID": .string(record.id),
                "casks": .array(try privilegePlan.casks.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) })]
            let contextURL = directory.appendingPathComponent("privilege-context.json")
            try JSONEncoder().encode(JSONValue.object(context)).write(to: contextURL, options: .atomic)
            arguments = ["ruby", bridge.path, contextURL.path]
        }
        let process = HomebrewTaskProcess(executable: executable, arguments: arguments, environment: environment, outputPolicy: .terminal)
        try reserveProcess()
        do { try process.start(output: { data in
            lock.lock(); defer { lock.unlock() }
            log.append(data); record.log = log.lines; record.stage = log.stage
            try? record.save(to: directory)
        }, finished: { result in
            reapedProcess(result)
        }) } catch { noSpawn(process); throw error }
        do { try observeProcess(process) } catch { process.stop(); privilegeProxy?.stop(record.id) {} }
        lock.lock(); record.processGroup = process.processIdentifier; record.processIdentity = HomebrewTaskProcess.startIdentity(process.processIdentifier)
        do { try record.save(to: directory) } catch { process.stop(); privilegeProxy?.stop(record.id) {} }; lock.unlock()
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            do { try observeProcess(process) } catch { process.stop(); privilegeProxy?.stop(record.id) {} }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
                process.stop(); privilegeProxy?.stop(record.id) {}
            }
        }
        if lastResult?.outcome != "completed" { break }
    }
    var nativeContinuation: HomebrewNativeInstallerContinuation?
    if let privilegeProxy, [78, 79].contains(lastResult?.exitStatus ?? 0) {
        let queried = DispatchSemaphore(value: 0)
        privilegeProxy.continuation(record.id) { nativeContinuation = HomebrewNativeInstallerContinuation(rawValue: $0); queried.signal() }
        if queried.wait(timeout: .now() + 30) != .success { lastResult = .init(outcome: "unknown", exitStatus: 70, stop: nil) }
    }
    if let privilegeProxy {
        let ended = DispatchSemaphore(value: 0)
        privilegeProxy.end(record.id) { ended.signal() }
        if ended.wait(timeout: .now() + 30) != .success { lastResult = .init(outcome: "unknown", exitStatus: 70, stop: nil) }
    }
    lock.lock()
    log.finish(); record.log = log.lines; record.stage = log.stage
    let lostPrivilegedResult = record.privilegePlan?.requiresSystemAuthorization == true && lastResult?.exitStatus == 70
    var outcome: [String: JSONValue] = ["outcome": .string(lostPrivilegedResult ? "unknown" : lastResult?.outcome ?? "unknown")]
    if let stop = lastResult?.stop { outcome["stop"] = .string(stop) }
    if lostPrivilegedResult { outcome["reason"] = .string("privileged_result_lost") }
    else if lastResult?.exitStatus == 79, let continuation = nativeContinuation, let reason = continuation.reason, let stage = continuation.stage { outcome["reason"] = .string(reason); record.stage = stage }
    else if lastResult?.exitStatus == 78 && (nativeContinuation == .manualInstallation || record.privilegePlan.map { HomebrewNativeManualOutcome.confirmed(in: directory, plan: $0) } == true) { outcome["reason"] = .string("manual_installation_required"); record.stage = "awaiting manual installation" }
    else if lastResult?.outcome == "failed" { outcome["reason"] = .string("tool_failed") }
    record.result = .object(outcome); record.ended = Date()
    try record.save(to: directory); lock.unlock()

} catch { exit(70) }
