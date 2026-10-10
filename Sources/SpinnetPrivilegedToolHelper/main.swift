import Foundation
import Security
import CryptoKit
import Darwin
import SpinnetCore

// launchd runs this signed helper as root. XPC checks every message's signing
// requirement (macOS 13+); PID lookup is used only for task ancestry/liveness,
// never as the source of code-signing authority.
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
    init(plan: HomebrewPrivilegePlan, pid: pid_t, identity: UInt64, uid: uid_t) {
        self.plan = plan; self.pid = pid; self.identity = identity; self.uid = uid
    }
}
final class State {
    let lock = NSLock()
    var tasks: [String: Task] = [:]
    var admissions: [String: HostAdmission] = [:]
    func stop(_ id: String) { lock.lock(); let task = tasks[id]; task?.stopped = true; task?.process?.stop(); lock.unlock() }
}
let state = State()
final class HostEndpoint: NSObject, HomebrewPrivilegeHostProtocol {
    let pid: pid_t; let uid: uid_t
    init(_ connection: NSXPCConnection) { pid = connection.processIdentifier; uid = connection.effectiveUserIdentifier }
    func admit(_ data: Data, reply: @escaping (String) -> Void) {
        do {
            guard data.count <= 64 * 1024, uid != 0, let identity = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.failed) }
            let decoded = try JSONDecoder().decode(HomebrewPrivilegePlan.self, from: data)
            let plan = try HomebrewPrivilegePlan(taskID: decoded.taskID, prefix: decoded.prefix, casks: decoded.casks, repairDirectories: decoded.repairDirectories, operation: decoded.operation)
            state.lock.lock(); defer { state.lock.unlock() }
            guard state.tasks.isEmpty, state.admissions.isEmpty else { throw PluginHostServiceError.tool(.busy) }
            state.admissions[plan.taskID] = HostAdmission(plan: plan, pid: pid, identity: identity, uid: uid, expires: ProcessInfo.processInfo.systemUptime + 60)
            reply("")
        } catch { reply("Authenticated Host admission was refused") }
    }
    func cancel(_ taskID: String, reply: @escaping () -> Void) {
        state.lock.lock()
        if let admission = state.admissions[taskID], admission.pid == pid, admission.uid == uid, HomebrewTaskProcess.startIdentity(pid) == admission.identity { state.admissions.removeValue(forKey: taskID) }
        state.lock.unlock(); reply()
    }
}
final class RunnerEndpoint: NSObject, HomebrewPrivilegeRunnerProtocol {
    let pid: pid_t; let uid: uid_t
    init(_ connection: NSXPCConnection) { pid = connection.processIdentifier; uid = connection.effectiveUserIdentifier }
    func begin(_ data: Data, reply: @escaping (String) -> Void) {
        do {
            guard data.count <= 64 * 1024, uid != 0, let identity = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.failed) }
            let decoded = try JSONDecoder().decode(HomebrewPrivilegePlan.self, from: data)
            let plan = try HomebrewPrivilegePlan(taskID: decoded.taskID, prefix: decoded.prefix, casks: decoded.casks, repairDirectories: decoded.repairDirectories, operation: decoded.operation)
            state.lock.lock(); defer { state.lock.unlock() }
            guard state.tasks.isEmpty, let admission = state.admissions[plan.taskID], admission.plan == plan, admission.uid == uid,
                  admission.expires > ProcessInfo.processInfo.systemUptime, HomebrewTaskProcess.startIdentity(admission.pid) == admission.identity,
                  HomebrewSystemAuthorization.processParent(pid) == admission.pid else { throw PluginHostServiceError.tool(.planChanged) }
            state.admissions.removeValue(forKey: plan.taskID)
            state.tasks[plan.taskID] = Task(plan: plan, pid: pid, identity: identity, uid: uid)
            reply("")
        } catch { reply("The privileged Task plan was refused") }
    }
    func stop(_ taskID: String, reply: @escaping () -> Void) { owned(taskID) { state.stop(taskID) }; reply() }
    func end(_ taskID: String, reply: @escaping () -> Void) {
        owned(taskID) {
            state.stop(taskID)
            state.lock.lock(); if state.tasks[taskID]?.process == nil { state.tasks.removeValue(forKey: taskID) }; state.lock.unlock()
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
        do {
            guard data.count <= 16 * 1024, let identity = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.failed) }
            let request = try JSONDecoder().decode(HomebrewPrivilegeRequest.self, from: data)
            state.lock.lock(); let task = state.tasks[request.taskID]; state.lock.unlock()
            guard let task, task.uid == uid, !task.stopped, HomebrewSystemAuthorization.descends(pid, from: task.pid, identity: task.identity) else { throw PluginHostServiceError.tool(.planChanged) }
            try task.plan.validate(request)
            let right = HomebrewSystemAuthorization.right + "." + UUID().uuidString.lowercased()
            try HomebrewSystemAuthorization.configureRight(right)
            state.lock.lock()
            guard !task.stopped, task.approvals.isEmpty else { state.lock.unlock(); HomebrewSystemAuthorization.removeRight(right); throw PluginHostServiceError.tool(.busy) }
            task.approvals[HomebrewSystemAuthorization.digest(data)] = Approval(pid: pid, identity: identity, right: right, expires: ProcessInfo.processInfo.systemUptime + 120)
            state.lock.unlock()
            reply(right)
        } catch { reply("") }
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
                let fresh = task.usedAuthorizations.insert(key).inserted && task.usedAuthorizations.count <= 100 && task.process == nil && !task.stopped
                state.lock.unlock()
                guard let approval else { throw PluginHostServiceError.tool(.planChanged) }
                defer { HomebrewSystemAuthorization.removeRight(approval.right) }
                guard fresh, approval.pid == pid, HomebrewTaskProcess.startIdentity(pid) == approval.identity, approval.expires > ProcessInfo.processInfo.systemUptime, HomebrewSystemAuthorization.check(authorization, rightName: approval.right) else { throw PluginHostServiceError.unavailable("System authorization refused or already consumed") }
                switch request.operation {
                case .installPackage: try install(request, task: task, reply: reply)
                case .repairOwnership:
                    try repair(request.source, task: task)
                    reply(0, "Reviewed ownership repair completed")
                }
            } catch { reply(77, "Reviewed privileged operation refused or cancelled; no unreviewed command was executed") }
        }
    }
    private func install(_ request: HomebrewPrivilegeRequest, task: Task, reply: @escaping (Int32, String) -> Void) throws {
        let staging = URL(fileURLWithPath: "/private/var/tmp").appendingPathComponent("spinnet-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let cask = task.plan.casks.first(where: { $0.name == request.package }), !request.archive.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        let kind = URL(fileURLWithPath: request.archive).pathExtension.lowercased()
        guard ["pkg", "dmg"].contains(kind) else { throw PluginHostServiceError.unavailable("This cask container has no reviewed native extraction adapter") }
        // Verify the original immutable cask download in root-owned staging.
        // Extracting from user-owned Caskroom is never an elevation authority.
        let archive = staging.appendingPathComponent("download." + kind)
        try copyVerified(request.archive, to: archive.path, expected: cask.sha256, task: task)
        let target = staging.appendingPathComponent("reviewed.pkg")
        if kind == "pkg" {
            guard cask.sha256 == request.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
            try FileManager.default.moveItem(at: archive, to: target)
        } else {
            let mount = staging.appendingPathComponent("volume")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let mounted = try runNative("/usr/bin/hdiutil", ["attach", archive.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path], task: task, timeout: 120)
            guard mounted.exitStatus == 0 else { throw PluginHostServiceError.tool(.failed) }
            defer { detach(mount) }
            let source = mount.appendingPathComponent(request.relativePackage)
            guard source.resolvingSymlinksInPath().path.hasPrefix(mount.path + "/") else { throw PluginHostServiceError.tool(.planChanged) }
            try copyVerified(source.path, to: target.path, expected: request.sha256, task: task)
        }
        let result = try runNative("/usr/sbin/installer", ["-pkg", target.path, "-target", "/"], task: task, timeout: 7200)
        reply(result.exitStatus, result.outcome == "completed" ? "Reviewed macOS package installation completed" : "The macOS installer failed or was stopped; changes are not rolled back")
    }
    private func copyVerified(_ path: String, to destinationPath: String, expected: String, task: Task) throws {
        let source = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 8 * 1024 * 1024 * 1024 else { throw PluginHostServiceError.tool(.planChanged) }
        let destination = open(destinationPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw PluginHostServiceError.tool(.failed) }
        defer { close(destination) }
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 128 * 1024), total: Int64 = 0
        while true {
            state.lock.lock(); let stopped = task.stopped; state.lock.unlock()
            guard !stopped, HomebrewTaskProcess.startIdentity(task.pid) == task.identity else { throw PluginHostServiceError.tool(.planChanged) }
            let count = Darwin.read(source, &buffer, buffer.count)
            guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
            total += Int64(count); guard total <= info.st_size else { throw PluginHostServiceError.tool(.planChanged) }
            let chunk = Data(buffer.prefix(count)); hasher.update(data: chunk)
            try chunk.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count { let written = Darwin.write(destination, bytes.baseAddress!.advanced(by: offset), bytes.count - offset); guard written > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += written }
            }
        }
        guard total == info.st_size, hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected, fsync(destination) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
    }
    private func runNative(_ executable: String, _ arguments: [String], task: Task, timeout: TimeInterval) throws -> HomebrewTaskProcess.Result {
        let done = DispatchSemaphore(value: 0)
        var result: HomebrewTaskProcess.Result?
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: executable), arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"], interruptGrace: 10, terminateGrace: 5)
        state.lock.lock(); guard !task.stopped, task.process == nil else { state.lock.unlock(); throw PluginHostServiceError.tool(.planChanged) }; task.process = process; state.lock.unlock()
        defer { state.lock.lock(); task.process = nil; state.lock.unlock() }
        // Output from privileged tools is never forwarded verbatim. A fixed
        // bounded outcome crosses back; no password or installer script text.
        try process.start(output: { _ in }, finished: { value in result = value; done.signal() })
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if HomebrewTaskProcess.startIdentity(task.pid) != task.identity || ProcessInfo.processInfo.systemUptime > deadline { state.stop(task.plan.taskID) }
        }
        guard let result else { throw PluginHostServiceError.tool(.failed) }; return result
    }
    private func detach(_ mount: URL) {
        let done = DispatchSemaphore(value: 0)
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", "-force", mount.path], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], interruptGrace: 1, terminateGrace: 1)
        do { try process.start(output: { _ in }, finished: { _ in done.signal() }) } catch { return }
        if done.wait(timeout: .now() + 10) != .success { process.stop(); _ = done.wait(timeout: .now() + 5) }
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
    enum Endpoint { case host, runner, client }
    let endpoint: Endpoint
    init(_ endpoint: Endpoint) { self.endpoint = endpoint }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        switch endpoint {
        case .host: connection.exportedInterface = NSXPCInterface(with: HomebrewPrivilegeHostProtocol.self); connection.exportedObject = HostEndpoint(connection)
        case .runner: connection.exportedInterface = NSXPCInterface(with: HomebrewPrivilegeRunnerProtocol.self); connection.exportedObject = RunnerEndpoint(connection)
        case .client: connection.exportedInterface = NSXPCInterface(with: HomebrewPrivilegeClientProtocol.self); connection.exportedObject = ClientEndpoint(connection)
        }
        connection.resume(); return true
    }
}
do {
    guard getuid() == 0 else { exit(77) }
    let hostDelegate = Listener(.host), runnerDelegate = Listener(.runner), clientDelegate = Listener(.client)
    let host = NSXPCListener(machServiceName: HomebrewSystemAuthorization.service + ".host")
    let runner = NSXPCListener(machServiceName: HomebrewSystemAuthorization.service + ".runner")
    let client = NSXPCListener(machServiceName: HomebrewSystemAuthorization.service + ".client")
    host.setConnectionCodeSigningRequirement(try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.hostIdentifier))
    runner.setConnectionCodeSigningRequirement(try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.runnerIdentifier))
    client.setConnectionCodeSigningRequirement(try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.clientIdentifier))
    host.delegate = hostDelegate; runner.delegate = runnerDelegate; client.delegate = clientDelegate; host.resume(); runner.resume(); client.resume()
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler {
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
            state.lock.lock(); if task.process == nil { state.tasks.removeValue(forKey: task.plan.taskID) }; state.lock.unlock()
        }
    }; timer.resume()
    RunLoop.current.run()
} catch { exit(77) }
