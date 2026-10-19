import Foundation
import Darwin

/// OS process boundary for a reviewed mutation. No Plugin supplies any of
/// these executable, argv or environment values. The independent runner
/// holds this boundary across a Host crash.
public final class HomebrewTaskProcess {
    public enum InputPolicy { case vendor, nativeManifest }
    public enum GroupPolicy { case independentGroup, inheritWorkerGroup }
    /// Output only; a terminal never becomes an input or authorization channel.
    public enum OutputPolicy { case pipe, terminal }
    public struct Result: Equatable {
        public let outcome: String
        public let exitStatus: Int32
        public let stop: String?
        public init(outcome: String, exitStatus: Int32, stop: String?) { self.outcome = outcome; self.exitStatus = exitStatus; self.stop = stop }
    }
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let standardInput: Data?
    private let inputPolicy: InputPolicy
    private let groupPolicy: GroupPolicy
    private let outputPolicy: OutputPolicy
    private let interruptGrace: TimeInterval
    private let terminateGrace: TimeInterval
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var stopAt: TimeInterval?
    private var ended = false
    private var observedIdentities: [pid_t: UInt64] = [:]
    public init(executable: URL, arguments: [String], environment: [String: String],
                interruptGrace: TimeInterval = 10, terminateGrace: TimeInterval = 5, standardInput: Data? = nil, inputPolicy: InputPolicy = .vendor,
                groupPolicy: GroupPolicy = .independentGroup, outputPolicy: OutputPolicy = .pipe) {
        self.executable = executable; self.arguments = arguments
        var outputEnvironment = environment
        // The output-only PTY supports cursor redraws. `dumb` suppresses
        // Homebrew's download renderer even when both output streams are TTYs.
        if outputPolicy == .terminal {
            outputEnvironment["TERM"] = "xterm-256color"
            outputEnvironment["COLUMNS"] = "200"
        }
        self.environment = outputEnvironment
        self.interruptGrace = interruptGrace; self.terminateGrace = terminateGrace
        self.standardInput = standardInput; self.inputPolicy = inputPolicy
        self.groupPolicy = groupPolicy
        self.outputPolicy = outputPolicy
    }
    public var processIdentifier: Int32 { lock.lock(); defer { lock.unlock() }; return pid }
    /// Resource supervision sees only identities captured for this Task. PID
    /// reuse never becomes signal or RSS authority for an unrelated process.
    public var ownedProcessIdentities: [Int32: UInt64] {
        lock.lock(); let held = observedIdentities; lock.unlock()
        return held.filter { Self.startIdentity($0.key) == $0.value }
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if !ended, stopAt == nil { stopAt = ProcessInfo.processInfo.systemUptime }
    }
    public func start(output: @escaping (Data) -> Void, finished: @escaping (Result) -> Void) throws {
        // Only a deliberately isolated worker may use this fixed child lane.
        // Its inner Stop never acquires authority over the inherited group.
        let ownsGroup = groupPolicy == .independentGroup
        guard ownsGroup || getpgrp() == getpid() else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        // A bounded anonymous native file supplies exact bytes and EOF. It
        // cannot block a writer thread when a vendor never reads stdin.
        var input: Int32 = -1
        if let standardInput {
            guard standardInput.count <= (inputPolicy == .vendor ? 256 * 1024 : 32 * 1024 * 1024) else { throw PluginHostServiceError.tool(.outputTooLarge) }
            let directory = URL(fileURLWithPath: "/private/var/tmp/spinnet-task-input-" + UUID().uuidString)
            try NativeFileQuarantine.makePrivateDirectory(directory)
            let path = directory.appendingPathComponent("input").path
            defer { try? FileManager.default.removeItem(at: directory) }
            input = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard input >= 0 else { throw PluginHostServiceError.tool(.failed) }
            do {
                guard unlink(path) == 0 else { throw PluginHostServiceError.tool(.failed) }
                try standardInput.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let written = Darwin.write(input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        guard written > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += written
                    }
                }
                guard lseek(input, 0, SEEK_SET) == 0 else { throw PluginHostServiceError.tool(.failed) }
            } catch { close(input); throw error }
        }
        defer { if input >= 0 { close(input) } }
        var descriptors: [Int32] = [0, 0]
        if outputPolicy == .terminal {
            // A fixed width keeps vendor progress within the published line
            // bound. Only stdout/stderr use the slave; stdin remains EOF or
            // the separately bounded native input, never a terminal session.
            var size = winsize(ws_row: 24, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
            var master: Int32 = -1, slave: Int32 = -1
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw PluginHostServiceError.tool(.failed) }
            descriptors = [master, slave]
        } else {
            guard pipe(&descriptors) == 0 else { throw PluginHostServiceError.tool(.failed) }
        }
        var outputWrite = descriptors[1], transferredReader = false
        defer { if outputWrite >= 0 { close(outputWrite) }; if !transferredReader { close(descriptors[0]) } }
        guard descriptors.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else { throw PluginHostServiceError.tool(.failed) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw PluginHostServiceError.tool(.failed) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw PluginHostServiceError.tool(.failed) }
        defer { posix_spawnattr_destroy(&attributes) }
        if input >= 0 {
            guard posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0,
                  posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO) == 0 else { throw PluginHostServiceError.tool(.failed) }
        } else { guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0 else { throw PluginHostServiceError.tool(.failed) } }
        guard posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO) == 0,
              descriptors.allSatisfy({ posix_spawn_file_actions_addclose(&actions, $0) == 0 }) else { throw PluginHostServiceError.tool(.failed) }
        var signals = sigset_t(); sigemptyset(&signals)
        guard posix_spawnattr_setsigmask(&attributes, &signals) == 0 else { throw PluginHostServiceError.tool(.failed) }
        sigfillset(&signals)
        let spawnFlags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | (ownsGroup ? POSIX_SPAWN_SETPGROUP : 0)
        guard posix_spawnattr_setsigdefault(&attributes, &signals) == 0,
              posix_spawnattr_setflags(&attributes, Int16(spawnFlags)) == 0,
              !ownsGroup || posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw PluginHostServiceError.tool(.failed) }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for item in argv + env { if let item { free(item) } } }
        var child: pid_t = 0
        // Stop and launch share one lock: after Stop is acknowledged no new
        // native process can escape into this Task. A Task is single-use.
        lock.lock()
        guard stopAt == nil, pid == 0, !ended else { lock.unlock(); throw PluginHostServiceError.tool(.planChanged) }
        let status = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            posix_spawn(&child, executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
        } }
        close(outputWrite); outputWrite = -1
        let leaderIdentity = status == 0 ? Self.identityIncludingZombie(child) : nil
        if status == 0 { pid = child; if let leaderIdentity { observedIdentities[child] = leaderIdentity } }
        lock.unlock()
        guard status == 0 else { throw PluginHostServiceError.tool(.failed) }
        let leader = child, reader = descriptors[0]
        transferredReader = true
        _ = fcntl(reader, F_SETFL, O_NONBLOCK)
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { close(reader) }
            var exitStatus: Int32 = 0, reaped = false, lastSignal: Int32 = 0, pipeOpen = true
            var descendants: [pid_t: UInt64] = [:]
            while true {
                // Reserve the original leader's zombie PID through a final
                // census. Reaping a leader that exits after the census would
                // otherwise lose a fast, newly reparented inherited child.
                var exitInfo = siginfo_t()
                let exitedBeforeCensus = !reaped && waitid(P_PID, id_t(leader), &exitInfo, WEXITED | WNOHANG | WNOWAIT) == 0 && exitInfo.si_pid == leader
                // Remember identity before reparenting. A recycled PID can
                // never receive one of this Task's stop signals.
                let processes = Self.processes()
                let current = Dictionary(processes.map { (Int32($0.pbi_pid), Self.identity($0)) }, uniquingKeysWith: { first, _ in first })
                var known = descendants.filter { current[$0.key] == $0.value }
                if let leaderIdentity, Self.startIdentity(leader) == leaderIdentity { known[leader] = leaderIdentity }
                // Group members are admitted only while the original leader
                // is live or an original member still binds that kernel group.
                let originalGroup = ownsGroup && (exitedBeforeCensus || (!reaped && leaderIdentity.map { Self.identityIncludingZombie(leader) == $0 } == true) || known.contains { pid, identity in
                    current[pid] == identity && processes.contains { Int32($0.pbi_pid) == pid && Int32($0.pbi_pgid) == leader }
                })
                if originalGroup {
                    for info in processes where Int32(info.pbi_pgid) == leader && descendants.count < 4096 {
                        if Int32(info.pbi_pid) != leader { descendants[Int32(info.pbi_pid)] = Self.identity(info) }
                    }
                }
                // Rebind each parent by start identity before discovering a
                // child; a recycled parent PID cannot authorize descendants.
                for _ in 0..<64 {
                    var discovered = false
                    var parents = descendants.filter { current[$0.key] == $0.value }
                    if let leaderIdentity, current[leader] == leaderIdentity { parents[leader] = leaderIdentity }
                    for info in processes where parents[Int32(info.pbi_ppid)] == current[Int32(info.pbi_ppid)] && parents[Int32(info.pbi_ppid)] != nil && descendants.count < 4096 {
                        let child = Int32(info.pbi_pid), identity = Self.identity(info)
                        if descendants[child] != identity { descendants[child] = identity; discovered = true }
                    }
                    if !discovered { break }
                }
                var buffer = [UInt8](repeating: 0, count: 8192)
                let bytes = Darwin.read(reader, &buffer, buffer.count)
                if bytes > 0 { output(Data(buffer.prefix(bytes))) }
                // A PTY reports EIO once its final slave is closed on some
                // systems, rather than the zero-byte EOF used by a pipe.
                else if bytes == 0 || (bytes < 0 && errno == EIO && outputPolicy == .terminal) { pipeOpen = false }
                if !reaped, exitedBeforeCensus || leaderIdentity == nil { reaped = waitpid(leader, &exitStatus, WNOHANG) == leader }
                lock.lock(); let stopping = stopAt; lock.unlock()
                let liveDescendants = descendants.filter { key, identity in Self.startIdentity(key) == identity }
                let leaderAlive = leaderIdentity.map { Self.startIdentity(leader) == $0 } ?? false
                let groupExists = ownsGroup && (leaderAlive || processes.contains { info in
                    Int32(info.pbi_pgid) == leader && liveDescendants[Int32(info.pbi_pid)] == Self.identity(info)
                })
                lock.lock()
                observedIdentities = liveDescendants
                if leaderAlive, let leaderIdentity { observedIdentities[leader] = leaderIdentity }
                lock.unlock()
                if reaped, !groupExists, liveDescendants.isEmpty, !pipeOpen { break }
                if let stopping {
                    let elapsed = ProcessInfo.processInfo.systemUptime - stopping
                    let signal = elapsed < interruptGrace ? SIGINT : elapsed < interruptGrace + terminateGrace ? SIGTERM : SIGKILL
                    if signal != lastSignal {
                        if groupExists { kill(-leader, signal) }
                        if !ownsGroup, leaderAlive, Self.startIdentity(leader) == leaderIdentity { kill(leader, signal) }
                        for (child, identity) in liveDescendants where Self.startIdentity(child) == identity { kill(child, signal) }
                        lastSignal = signal
                    } else if signal == SIGKILL {
                        // Sweep newly discovered escaped descendants too.
                        if groupExists { kill(-leader, signal) }
                        if !ownsGroup, leaderAlive, Self.startIdentity(leader) == leaderIdentity { kill(leader, signal) }
                        for (child, identity) in liveDescendants where Self.startIdentity(child) == identity { kill(child, signal) }
                    }
                }
                usleep(10_000)
            }
            lock.lock(); ended = true; observedIdentities = [:]; let wasStopped = stopAt != nil; lock.unlock()
            let signaled = exitStatus & 0x7f
            let code = signaled == 0 ? (exitStatus >> 8) & 0xff : 128 + signaled
            finished(Result(outcome: wasStopped ? "stopped" : code == 0 ? "completed" : "failed", exitStatus: code,
                stop: wasStopped ? lastSignal == SIGKILL ? "killed" : lastSignal == SIGTERM ? "terminated" : "interrupted" : nil))
        }
    }
    static func identity(_ info: proc_bsdinfo) -> UInt64 { info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec }
    private static func identityIncludingZombie(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return identity(info)
    }
    public static func startIdentity(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { return nil }
        return identity(info)
    }
    private static func processes() -> [proc_bsdinfo] {
        let count = proc_listallpids(nil, 0)
        guard count > 0, count <= 65_536 else { return [] }
        var ids = [pid_t](repeating: 0, count: Int(count) + 64)
        let actual = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return ids.prefix(Int(max(0, actual))).compactMap { pid in
            var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != SZOMB ? info : nil
        }
    }
}
