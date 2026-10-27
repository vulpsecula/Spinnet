import Foundation
import Darwin
import IOKit.pwr_mgt
import SpinnetCore
import SpinnetReviewedTools

private func execNative(_ executable: URL, arguments: [String], environment: [String: String]) -> Never {
    let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
    let env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { argv.forEach { free($0) }; env.forEach { free($0) } }
    argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
        _ = execve(executable.path, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
    } }
    exit(70)
}

// A fixed signed worker validates credentials, then becomes the native brew
// process with exec. The PID/birth (and sudo's no-TTY parent cache) stays the
// same. Frozen typed inputs arrive from the authenticated runner, never from
// a second read of a mutable journal or a Plugin-supplied shell command.
if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--native-command" {
    do {
        try HomebrewAskpass.verifyRunnerParent()
        guard getpgrp() == getpid(), CommandLine.arguments[3].utf8.count <= 16 * 1024,
              ["adopt", "normal"].contains(CommandLine.arguments[4]) else { exit(77) }
        let input = try HomebrewTaskInput(JSONDecoder().decode(JSONValue.self, from: Data(CommandLine.arguments[3].utf8)))
        let executable = try HomebrewReadProfile.discover()
        guard HomebrewSystemAuthentication.applies(to: input), executable.path == CommandLine.arguments[2] else { exit(77) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[5], isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { exit(77) }
        let stopped = { FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) }
        guard !stopped() else { exit(130) }
        if HomebrewSystemAuthentication.isAvailable {
            print("==> Waiting for system administrator authentication (Touch ID when available)")
            fflush(stdout)
            let accepted = (try? HomebrewSystemAuthentication.validate(environment: ProcessInfo.processInfo.environment)) == true
            print(accepted ? "==> System authentication accepted" : "==> System authentication did not complete; Homebrew will request a password if needed")
            fflush(stdout)
        }
        guard !stopped() else { exit(130) }
        execNative(executable, arguments: input.nativeArguments(adopt: CommandLine.arguments[4] == "adopt"),
            environment: ProcessInfo.processInfo.environment)
    } catch { exit(70) }
}

// Opt-in hardware probe: only sudo validation and /usr/bin/true, with no
// password collection or Homebrew mutation. The child uses the production
// validation and exec path, including its isolated owned process group.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--verify-system-authentication" {
    do {
        let ended = DispatchSemaphore(value: 0)
        var result: HomebrewTaskProcess.Result?
        let process = HomebrewTaskProcess(executable: try HomebrewAskpass.sibling("SpinnetToolTaskRunner"),
            arguments: ["--system-authentication-probe-child"],
            environment: HomebrewAskpass.taskEnvironment(askpass: try HomebrewAskpass.sibling("SpinnetHomebrewAskpass"), socket: "/private/tmp/unused-system-auth-probe"))
        try process.start(output: { FileHandle.standardOutput.write($0) }, finished: { result = $0; ended.signal() })
        ended.wait()
        exit(result?.outcome == "completed" ? 0 : 77)
    } catch { exit(70) }
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--system-authentication-probe-child" {
    do {
        try HomebrewAskpass.verifyRunnerParent()
        guard getpgrp() == getpid(), HomebrewSystemAuthentication.isAvailable,
              try HomebrewSystemAuthentication.validate(environment: ProcessInfo.processInfo.environment) else { exit(77) }
        let code = "ok = system('/usr/bin/sudo', '-A', '-n', '--', '/usr/bin/true'); puts(ok ? 'Native Homebrew system authentication reuse: PASS' : 'Native Homebrew system authentication reuse: FAIL'); exit(ok ? 0 : 1)"
        execNative(try HomebrewReadProfile.discover(), arguments: ["ruby", "-e", code], environment: ProcessInfo.processInfo.environment)
    } catch { exit(70) }
}

if CommandLine.arguments.count == 2, ["--verify-askpass", "--verify-host-askpass", "--verify-sudo-askpass"].contains(CommandLine.arguments[1]) {
    func verifyAskpass() throws -> Int32 {
        if CommandLine.arguments[1] == "--verify-host-askpass" { try HomebrewAskpass.verifyHostParent() }
        let server = try HomebrewAskpass.Server { _ in }
        defer { server.stop() }
        let sudo = CommandLine.arguments[1] == "--verify-sudo-askpass"
        server.setCommand("Spinnet signed askpass connection check", verificationOnly: sudo)
        let askpass = try HomebrewAskpass.sibling("SpinnetHomebrewAskpass")
        let process = Process()
        process.executableURL = sudo ? URL(fileURLWithPath: "/usr/bin/sudo") : askpass
        // With a command, -k ignores cached credentials without changing the
        // user's timestamp. The callback always cancels; true cannot mutate.
        process.arguments = sudo ? ["-A", "-k", "--", "/usr/bin/true"] : ["--check"]
        process.environment = HomebrewAskpass.taskEnvironment(askpass: askpass, socket: server.path)
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return 70 }
        let diagnostics = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if sudo {
            guard process.terminationStatus != 0,
                  diagnostics.contains("Spinnet sudo askpass verified; cancelled without credentials") else {
                FileHandle.standardError.write(Data(diagnostics.utf8)); return 77
            }
            print("Real sudo → signed askpass verified; cancelled without credentials or command execution")
            return 0
        }
        guard process.terminationStatus == 0 else { return 77 }
        print("Signed Homebrew askpass connection verified; no password or sudo requested")
        return 0
    }
    do { exit(try verifyAskpass()) } catch { exit(70) }
}

// Packaging smoke check: no Task, source read, authorization or subprocess.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--verify-resources" {
    guard let askpass = try? HomebrewAskpass.sibling("SpinnetHomebrewAskpass"), FileManager.default.isExecutableFile(atPath: askpass.path) else { exit(70) }
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
    // A refusal must still replace the Host's pending-launch reservation
    // with this runner's proof that no command was spawned.
    try HomebrewAskpass.verifyHostParent()
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
    let askpass = try HomebrewAskpass.sibling("SpinnetHomebrewAskpass")
    guard FileManager.default.isExecutableFile(atPath: askpass.path) else { throw PluginHostServiceError.tool(.missing) }
    let server = try HomebrewAskpass.Server { waiting in
        lock.lock(); defer { lock.unlock() }
        guard record.result == nil else { return }
        record.stage = waiting ? "waiting for administrator password" : "running Homebrew"
        try? record.save(to: directory)
    }
    defer { server.stop() }
    let environment = HomebrewAskpass.taskEnvironment(askpass: askpass, socket: server.path)
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
        let uncertain = process.ownershipUncertain
        lease.ownershipUncertain = lease.ownershipUncertain || uncertain
        lease.observedAt = Date(); try lease.save(to: directory)
        // Preserve this census's verified Stop identities before refusing to
        // continue; incomplete ancestry never becomes permission to clear them.
        if uncertain { throw PluginHostServiceError.tool(.failed) }
    }
    func noSpawn(_ process: HomebrewTaskProcess) {
        guard process.processIdentifier == 0 else { return }
        lock.lock(); defer { lock.unlock() }
        lease.reservation = nil; lease.leaderPID = nil; lease.leaderIdentity = nil; lease.members = [:]; lease.observedAt = Date()
        try? lease.save(to: directory)
    }
    func reapedProcess(_ result: HomebrewTaskProcess.Result) {
        lock.lock(); defer { lock.unlock() }
        lease.recordReaping(result)
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
        server.setCommand("brew " + arguments.joined(separator: " "))
        let systemAuthentication = HomebrewSystemAuthentication.applies(to: step) && HomebrewSystemAuthentication.isAvailable
        let workerArguments = systemAuthentication
            ? ["--native-command", executable.path, String(decoding: try JSONEncoder().encode(step.json), as: UTF8.self), adopt ? "adopt" : "normal", directory.path]
            : arguments
        let process = HomebrewTaskProcess(executable: systemAuthentication ? try HomebrewAskpass.sibling("SpinnetToolTaskRunner") : executable,
            arguments: workerArguments, environment: environment, outputPolicy: .terminal)
        try reserveProcess()
        do { try process.start(output: { data in
            lock.lock(); defer { lock.unlock() }
            log.append(data); record.log = log.lines; record.output = log.output; record.outputTruncated = log.outputTruncated
            record.stage = server.isRequestingPassword ? "waiting for administrator password" : log.stage
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
                server.setCommand(nil); process.stop()
            }
        }
        server.setCommand(nil)
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
