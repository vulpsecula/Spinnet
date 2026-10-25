import Foundation
import Darwin

#if SPINNET_BACKGROUND_LIFECYCLE_FIXTURE
import ServiceManagement
import SpinnetCore

// This executable and its extra XPC method exist only in an isolated test build.
// Normal packaging never ships this product or selects its service identifiers.
private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw PluginHostServiceError.unavailable(message) }
}
private func emit(_ values: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
private func service() -> SMAppService {
    SMAppService.daemon(plistName: HomebrewSystemAuthorization.helperIdentifier + ".plist")
}
private func snapshot() throws -> [String: Any] {
    try require(service().status == .enabled, "Fixture service is not enabled")
    let connection = try HomebrewSystemAuthorization.hostConnection()
    defer { connection.invalidate() }
    let done = DispatchSemaphore(value: 0), lock = NSLock()
    var result: [String: Any]?
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in done.signal() }) as? HomebrewPrivilegeHostProtocol else {
        throw PluginHostServiceError.tool(.failed)
    }
    proxy.lifecycleSnapshot { pid, revision, variant in
        lock.lock(); result = ["pid": pid, "revision": revision, "variant": variant]; lock.unlock(); done.signal()
    }
    try require(done.wait(timeout: .now() + 5) == .success, "Fixture XPC response timed out")
    lock.lock(); defer { lock.unlock() }
    guard var value = result else { throw PluginHostServiceError.unavailable("Fixture signed XPC connection failed") }
    value["status"] = service().status.rawValue
    return value
}
private func waitUntil(_ predicate: () throws -> Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    while try !predicate() {
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Fixture recovery timed out")
        Thread.sleep(forTimeInterval: 0.1)
    }
}
private final class RecoveryPower: PowerAssertions {
    private let lock = NSLock()
    private var count = 0
    var held: Int { lock.lock(); defer { lock.unlock() }; return count }
    func acquire(_ assertion: KeepAwakeAssertion, reason: String) throws -> () -> Void {
        lock.lock(); count += 1; lock.unlock()
        return { self.lock.lock(); self.count -= 1; self.lock.unlock() }
    }
}
private func recoveryHost(_ journal: URL, activities: HostActivities, power: RecoveryPower) -> HostReviewedToolTasks {
    HostReviewedToolTasks(activities: activities, journal: journal,
        runnerURL: URL(fileURLWithPath: "/fixture-must-never-launch-a-runner"), nativeInspection: nil, recoveryPower: power)
}
private func holdRecovery(_ journal: URL, ready: URL) throws {
    let id = "activity_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let directory = journal.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // Reap a real harmless user-owned subprocess. No Homebrew command is run.
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["0.2"]
    try child.run()
    let pid = child.processIdentifier
    guard let birth = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.failed) }
    child.waitUntilExit()
    try require(child.terminationStatus == 0, "Fixture subprocess did not end normally")
    let plan = try HomebrewPrivilegePlan(taskID: id, prefix: "/opt/homebrew", casks: [
        .init(name: "lifecycle-fixture", version: "1", sha256: String(repeating: "a", count: 64), packages: ["NeverExecuted.pkg"])
    ])
    let record: [String: Any] = ["id": id, "owner": "lifecycle-fixture", "pluginName": "Lifecycle Fixture",
        "input": ["tool": "homebrew", "operation": "install", "kind": "cask", "name": "lifecycle-fixture"],
        "package": [:], "executable": "/fixture-must-never-launch-homebrew", "started": Date().timeIntervalSinceReferenceDate,
        "ended": Date().timeIntervalSinceReferenceDate, "detached": false, "runnerPID": pid, "runnerIdentity": birth,
        "stage": "finished", "log": [], "result": ["outcome": "completed"],
        "privilegePlan": try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))]
    try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("task.json"), options: .atomic)
    try HomebrewTaskProcessLease(taskID: id, runnerPID: pid, runnerIdentity: birth).save(to: directory)
    // Admission reserves the real Root lane but grants no execution to a runner.
    // Killing this Host tests Root's production owner-loss/expiry cleanup.
    try HomebrewSystemAuthorization.admit(plan)
    defer { HomebrewSystemAuthorization.cancelAdmission(id) }
    try require(try HomebrewSystemAuthorization.taskIsRunning(plan), "Root admission was not held")
    let activities = HostActivities(), power = RecoveryPower()
    let host = recoveryHost(journal, activities: activities, power: power)
    try require(host.hasRunningTasks && power.held == 1, "Terminal task was released before Root confirmed idle")
    try JSONSerialization.data(withJSONObject: ["taskID": id, "pid": getpid()]).write(to: ready, options: .atomic)
    let deadline = ProcessInfo.processInfo.systemUptime + 45
    while ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.1) }
    throw PluginHostServiceError.unavailable("Lifecycle controller did not complete the Host restart")
}
private func recover(_ journal: URL) throws {
    let activities = HostActivities(), power = RecoveryPower()
    let host = recoveryHost(journal, activities: activities, power: power)
    try waitUntil { host.refresh(); return !host.hasRunningTasks }
    let entries = activities.list()
    try require(entries.count == 1, "Expected the one retained terminal task")
    try require(entries[0].json.value(atPointer: "/result/outcome") == .string("completed"), "Recorded result was lost")
    try require(entries[0].json.value(atPointer: "/status") == .string("ended"), "Terminal task remains active")
    try require(power.held == 0, "Recovery retained a sleep assertion")
    try emit(["recovery": "passed", "activeTasks": 0, "heldRecoveryAssertions": power.held, "result": "completed"])
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    try require(getuid() != 0, "Run the fixture Host as the logged-in user")
    switch args.first {
    case "status": try emit(["status": service().status.rawValue])
    case "register":
        // The exact production registration state machine, with Settings UI
        // suppressed. A pending system decision is reported as exit 77.
        do {
            try HomebrewSystemAuthorization.prepareService(status: { service().status }, register: { try service().register() },
                openSettings: {}, bundledServiceExists: true)
        } catch {
            if service().status == .requiresApproval {
                try emit(["status": service().status.rawValue, "approvalRequired": true]); exit(77)
            }
            throw error
        }
        try emit(["status": service().status.rawValue])
    case "unregister":
        let done = DispatchSemaphore(value: 0), lock = NSLock()
        var failure: Error?
        service().unregister { error in lock.lock(); failure = error; lock.unlock(); done.signal() }
        try require(done.wait(timeout: .now() + 15) == .success, "Fixture unregister timed out")
        lock.lock(); let error = failure; lock.unlock(); if let error { throw error }
        let status = service().status
        try require(status == .notRegistered || status == .notFound, "Fixture registration was retained after unregister")
        try emit(["unregistered": true, "status": service().status.rawValue])
    case "probe":
        try require(service().status == .enabled, "Fixture service needs explicit system approval")
        try HomebrewBackgroundUpdate.refreshEnabledService()
        try emit(snapshot())
    case "snapshot": try emit(snapshot())
    case "hold" where args.count == 3: try holdRecovery(URL(fileURLWithPath: args[1]), ready: URL(fileURLWithPath: args[2]))
    case "recover" where args.count == 2: try recover(URL(fileURLWithPath: args[1]))
    default: throw PluginHostServiceError.unavailable("Expected status, register, unregister, probe, snapshot, hold or recover")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
#else
FileHandle.standardError.write(Data("This test product requires SPINNET_BACKGROUND_LIFECYCLE_FIXTURE and is never shipped.\n".utf8))
exit(64)
#endif
