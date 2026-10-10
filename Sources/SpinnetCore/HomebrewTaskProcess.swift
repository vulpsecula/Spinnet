import Foundation
import Darwin

/// OS process boundary for a reviewed mutation. No Plugin supplies any of
/// these executable, argv or environment values. The independent runner
/// holds this boundary across a Host crash.
public final class HomebrewTaskProcess {
    public struct Result: Equatable {
        public let outcome: String
        public let exitStatus: Int32
        public let stop: String?
        public init(outcome: String, exitStatus: Int32, stop: String?) { self.outcome = outcome; self.exitStatus = exitStatus; self.stop = stop }
    }
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let interruptGrace: TimeInterval
    private let terminateGrace: TimeInterval
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var stopAt: TimeInterval?
    private var ended = false
    public init(executable: URL, arguments: [String], environment: [String: String],
                interruptGrace: TimeInterval = 10, terminateGrace: TimeInterval = 5) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.interruptGrace = interruptGrace; self.terminateGrace = terminateGrace
    }
    public var processIdentifier: Int32 { lock.lock(); defer { lock.unlock() }; return pid }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if !ended, stopAt == nil { stopAt = ProcessInfo.processInfo.systemUptime }
    }
    public func start(output: @escaping (Data) -> Void, finished: @escaping (Result) -> Void) throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw PluginHostServiceError.tool(.failed) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        descriptors.forEach { posix_spawn_file_actions_addclose(&actions, $0) }
        var signals = sigset_t(); sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        sigfillset(&signals); posix_spawnattr_setsigdefault(&attributes, &signals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for item in argv + env { if let item { free(item) } } }
        var child: pid_t = 0
        let status = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            posix_spawn(&child, executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
        } }
        close(descriptors[1])
        guard status == 0 else { close(descriptors[0]); throw PluginHostServiceError.tool(.failed) }
        lock.lock(); pid = child; lock.unlock()
        let leader = child, reader = descriptors[0]
        _ = fcntl(reader, F_SETFL, O_NONBLOCK)
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { close(reader) }
            var exitStatus: Int32 = 0, reaped = false, lastSignal: Int32 = 0, pipeOpen = true
            var descendants: [pid_t: UInt64] = [:]
            while true {
                // Remember identity before reparenting. A recycled PID can
                // never receive one of this Task's stop signals.
                let known = Set(descendants.keys).union([leader])
                let processes = Self.processes()
                for info in processes where known.contains(Int32(info.pbi_ppid)) && descendants.count < 4096 {
                    descendants[Int32(info.pbi_pid)] = Self.identity(info)
                }
                var buffer = [UInt8](repeating: 0, count: 8192)
                let bytes = Darwin.read(reader, &buffer, buffer.count)
                if bytes > 0 { output(Data(buffer.prefix(bytes))) }
                else if bytes == 0 { pipeOpen = false }
                if !reaped { reaped = waitpid(leader, &exitStatus, WNOHANG) == leader }
                lock.lock(); let stopping = stopAt; lock.unlock()
                let liveDescendants = descendants.filter { key, identity in Self.startIdentity(key) == identity }
                let groupExists = processes.contains { Int32($0.pbi_pgid) == leader }
                if reaped, !groupExists, liveDescendants.isEmpty, !pipeOpen { break }
                if let stopping {
                    let elapsed = ProcessInfo.processInfo.systemUptime - stopping
                    let signal = elapsed < interruptGrace ? SIGINT : elapsed < interruptGrace + terminateGrace ? SIGTERM : SIGKILL
                    if signal != lastSignal {
                        if groupExists { kill(-leader, signal) }
                        for (child, identity) in liveDescendants where Self.startIdentity(child) == identity { kill(child, signal) }
                        lastSignal = signal
                    } else if signal == SIGKILL {
                        // Sweep newly discovered escaped descendants too.
                        if groupExists { kill(-leader, signal) }
                        for (child, identity) in liveDescendants where Self.startIdentity(child) == identity { kill(child, signal) }
                    }
                }
                usleep(10_000)
            }
            lock.lock(); ended = true; let wasStopped = stopAt != nil; lock.unlock()
            let signaled = exitStatus & 0x7f
            let code = signaled == 0 ? (exitStatus >> 8) & 0xff : 128 + signaled
            finished(Result(outcome: wasStopped ? "stopped" : code == 0 ? "completed" : "failed", exitStatus: code,
                stop: wasStopped ? lastSignal == SIGKILL ? "killed" : lastSignal == SIGTERM ? "terminated" : "interrupted" : nil))
        }
    }
    static func identity(_ info: proc_bsdinfo) -> UInt64 { info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec }
    public static func startIdentity(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { return nil }
        return identity(info)
    }
    private static func processes() -> [proc_bsdinfo] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var ids = [pid_t](repeating: 0, count: Int(count) + 64)
        let actual = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return ids.prefix(Int(max(0, actual))).compactMap { pid in
            var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != SZOMB ? info : nil
        }
    }
}
