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
    environment["HOMEBREW_NO_INSTALL_UPGRADE"] = "1"; environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
    record.runnerPID = getpid(); record.runnerIdentity = HomebrewTaskProcess.startIdentity(getpid())
    var privilegeConnection: NSXPCConnection?
    var privilegeProxy: HomebrewPrivilegeRunnerProtocol?
    if let privilegePlan = record.privilegePlan {
        let connection = try HomebrewSystemAuthorization.runnerConnection()
        let ready = DispatchSemaphore(value: 0)
        var failure = "The signed privileged helper is unavailable"
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in ready.signal() }) as? HomebrewPrivilegeRunnerProtocol else { exit(77) }
        proxy.begin(try JSONEncoder().encode(privilegePlan)) { failure = $0; ready.signal() }
        guard ready.wait(timeout: .now() + 15) == .success, failure.isEmpty else {
            record.result = .object(["outcome": .string("failed"), "reason": .string("system_authorization_unavailable")]); record.ended = Date(); try record.save(to: directory); exit(77)
        }
        privilegeConnection = connection; privilegeProxy = proxy
        environment["SPINNET_TASK_ID"] = record.id
    }
    defer { privilegeConnection?.invalidate() }
    var lastResult: HomebrewTaskProcess.Result?
    for (index, step) in steps.enumerated() {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
            lastResult = .init(outcome: "stopped", exitStatus: 130, stop: "interrupted"); break
        }
        let metadata = record.stepMetadata?[index] ?? record.package
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
                try process.start(output: { data in lock.lock(); log.append(data); record.log = log.lines; try? record.save(to: directory); lock.unlock() }, finished: { result in lastResult = result; finished.signal() })
                while finished.wait(timeout: .now() + 0.1) == .timedOut {
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) { process.stop(); privilegeProxy?.stop(record.id) {} }
                }
                if lastResult?.outcome != "completed" { break }
            }
            if lastResult?.outcome != "completed" { break }
            continue
        }
        if let privilegePlan = record.privilegePlan, !privilegePlan.casks.isEmpty, step.kind == "cask" {
            guard let bridge = Bundle.module.url(forResource: "HomebrewPrivilegeBridge", withExtension: "rb") else { exit(70) }
            let client = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("SpinnetToolAuthorizationClient")
            let context: [String: JSONValue] = ["arguments": .array(arguments.map(JSONValue.string)), "client": .string(client.path),
                "casks": .array(privilegePlan.casks.map { .object(["name": .string($0.name), "version": .string($0.version), "sha256": .string($0.sha256), "packages": .array($0.packages.map(JSONValue.string))]) })]
            let contextURL = directory.appendingPathComponent("privilege-context.json")
            try JSONEncoder().encode(JSONValue.object(context)).write(to: contextURL, options: .atomic)
            arguments = ["ruby", bridge.path, contextURL.path]
        }
        let process = HomebrewTaskProcess(executable: executable, arguments: arguments, environment: environment)
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
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
                process.stop(); privilegeProxy?.stop(record.id) {}
            }
        }
        if lastResult?.outcome != "completed" { break }
    }
    if let privilegeProxy {
        let ended = DispatchSemaphore(value: 0)
        privilegeProxy.end(record.id) { ended.signal() }
        if ended.wait(timeout: .now() + 30) != .success { lastResult = .init(outcome: "unknown", exitStatus: 70, stop: nil) }
    }
    lock.lock()
    log.finish(); record.log = log.lines; record.stage = log.stage
    var outcome: [String: JSONValue] = ["outcome": .string(lastResult?.outcome ?? "unknown")]
    if let stop = lastResult?.stop { outcome["stop"] = .string(stop) }
    if lastResult?.outcome == "failed" { outcome["reason"] = .string("tool_failed") }
    record.result = .object(outcome); record.ended = Date()
    try record.save(to: directory); lock.unlock()

} catch { exit(70) }
