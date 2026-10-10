import Foundation
import Darwin
import IOKit.pwr_mgt
import SpinnetCore

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
    let input = try HomebrewTaskInput(record.input)
    let steps = try record.steps?.map(HomebrewTaskInput.init) ?? [input]
    guard !steps.isEmpty, steps.count <= 80, steps.allSatisfy({ !$0.arguments.isEmpty }),
          record.steps == nil || steps.allSatisfy({ $0.operation == "upgradeSelected" }),
          try HomebrewReadProfile.discover().path == record.executable else { exit(77) }
    let lock = NSLock(), finished = DispatchSemaphore(value: 0), log = HomebrewTaskLog()
    var sleepAssertion: IOPMAssertionID = 0
    guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Spinnet Homebrew Task" as CFString, &sleepAssertion) == kIOReturnSuccess else { exit(70) }
    defer { IOPMAssertionRelease(sleepAssertion) }
    ProcessInfo.processInfo.disableSuddenTermination(); ProcessInfo.processInfo.disableAutomaticTermination("Reviewed Homebrew Task")
    defer { ProcessInfo.processInfo.enableSuddenTermination(); ProcessInfo.processInfo.enableAutomaticTermination("Reviewed Homebrew Task") }
    var environment = HomebrewReadProfile.environment
    environment["HOMEBREW_NO_INSTALL_UPGRADE"] = "1"; environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
    record.runnerPID = getpid(); record.runnerIdentity = HomebrewTaskProcess.startIdentity(getpid())
    var lastResult: HomebrewTaskProcess.Result?
    for step in steps {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
            lastResult = .init(outcome: "stopped", exitStatus: 130, stop: "interrupted"); break
        }
        let arguments = record.package.value(atPointer: "/adopt") == .bool(true) && step.operation == "install" && step.kind == "cask"
            ? ["install", "--cask", "--adopt", "--", step.name] : step.arguments
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: record.executable), arguments: arguments, environment: environment)
        try process.start(output: { data in
            lock.lock(); defer { lock.unlock() }
            log.append(data); record.log = log.lines; record.stage = log.stage
            try? record.save(to: directory)
        }, finished: { result in
            lock.lock(); lastResult = result; lock.unlock(); finished.signal()
        })
        lock.lock(); record.processGroup = process.processIdentifier; record.processIdentity = HomebrewTaskProcess.startIdentity(process.processIdentifier)
        try record.save(to: directory); lock.unlock()
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) { process.stop() }
        }
        if lastResult?.outcome != "completed" { break }
    }
    lock.lock()
    log.finish(); record.log = log.lines; record.stage = log.stage
    var outcome: [String: JSONValue] = ["outcome": .string(lastResult?.outcome ?? "unknown")]
    if let stop = lastResult?.stop { outcome["stop"] = .string(stop) }
    if lastResult?.outcome == "failed" { outcome["reason"] = .string("tool_failed") }
    record.result = .object(outcome); record.ended = Date()
    try record.save(to: directory); lock.unlock()

} catch { exit(70) }
