import Foundation
import Darwin
import IOKit.pwr_mgt
import SpinnetCore

// Read-only signed packaging check; no system prompt or credential handling.
if CommandLine.arguments.count == 2, ["--verify-resources", "--verify-host-environment"].contains(CommandLine.arguments[1]) {
    do {
        if CommandLine.arguments[1] == "--verify-host-environment" { try HomebrewSystemAuthentication.verifyHostParent() }
        guard HomebrewSystemAuthentication.taskEnvironment["SUDO_ASKPASS"] == nil else { exit(77) }
        print("Native Homebrew environment verified; authentication belongs to macOS")
        exit(0)
    } catch { exit(70) }
}

// Opt-in hardware probe runs exactly the production output-only process path.
// No credential cache preflight: native Homebrew's sudo opens system UI when
// it needs authentication. -k ignores the cache for this harmless true only.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--verify-system-authentication" {
    do {
        let ended = DispatchSemaphore(value: 0)
        var result: HomebrewTaskProcess.Result?
        let code = "ok = system('/usr/bin/sudo', '-k', '--', '/usr/bin/true'); puts(ok ? 'Native Homebrew system authentication: PASS' : 'Native Homebrew system authentication: FAIL'); exit(ok ? 0 : 1)"
        let process = HomebrewTaskProcess(executable: try HomebrewReadProfile.discover(),
            arguments: ["ruby", "-e", code], environment: HomebrewSystemAuthentication.taskEnvironment, outputPolicy: .terminal)
        try process.start(output: { FileHandle.standardOutput.write($0) }, finished: { result = $0; ended.signal() })
        ended.wait()
        exit(result?.outcome == "completed" ? 0 : 77)
    } catch { exit(70) }
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
    // A refusal must still replace the Host's pending-launch reservation
    // with this runner's proof that no command was spawned.
    try HomebrewSystemAuthentication.verifyHostParent()
    guard record.executionModel == "native-cli-v1", record.privilegePlan == nil else { exit(77) }
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
    let environment = HomebrewSystemAuthentication.taskEnvironment
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
            record.log = log.lines; record.output = log.output; record.outputTruncated = log.outputTruncated; try record.save(to: directory)
        }
        let adopt = metadata.value(atPointer: "/adopt") == .bool(true)
        let arguments = step.nativeArguments(adopt: adopt)
        let executable = URL(fileURLWithPath: record.executable)
        guard metadata.value(atPointer: "/privileged_repair") != .bool(true) else {
            throw PluginHostServiceError.unavailable("This Doctor repair must be run manually in Terminal")
        }
        let process = HomebrewTaskProcess(executable: executable, arguments: arguments,
            environment: environment, outputPolicy: .terminal)
        try reserveProcess()
        do { try process.start(output: { data in
            lock.lock(); defer { lock.unlock() }
            log.append(data); record.log = log.lines; record.output = log.output; record.outputTruncated = log.outputTruncated
            record.stage = log.stage
            try? record.save(to: directory)
        }, finished: { result in
            reapedProcess(result)
        }) } catch { noSpawn(process); throw error }
        do { try observeProcess(process) } catch { process.stop() }
        lock.lock(); record.processGroup = process.processIdentifier; record.processIdentity = HomebrewTaskProcess.startIdentity(process.processIdentifier)
        do { try record.save(to: directory) } catch { process.stop() }; lock.unlock()
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            do { try observeProcess(process) } catch { process.stop() }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
                process.stop()
            }
        }
        if lastResult?.outcome != "completed" { break }
    }
    lock.lock()
    log.finish(); record.log = log.lines; record.output = log.output; record.outputTruncated = log.outputTruncated; record.stage = log.stage
    var outcome: [String: JSONValue] = ["outcome": .string(lastResult?.outcome ?? "unknown")]
    if let stop = lastResult?.stop { outcome["stop"] = .string(stop) }
    if lastResult?.outcome == "failed" { outcome["reason"] = .string("tool_failed") }
    record.result = .object(outcome); record.ended = Date()
    try record.save(to: directory); lock.unlock()

} catch { exit(70) }
