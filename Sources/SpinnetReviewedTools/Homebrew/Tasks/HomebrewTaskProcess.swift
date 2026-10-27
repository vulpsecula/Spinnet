import SpinnetCore
import Foundation
import Darwin

/// OS process boundary for a reviewed mutation. No Plugin supplies any of
/// these executable, argv or environment values. The independent runner
/// holds this boundary across a Host crash.
public final class HomebrewTaskProcess {
    /// Fits Homebrew's 720pt minimum page at the Host's readable mono size,
    /// leaving room for package names and a complete native download bar.
    public static let terminalColumns = 80
    public enum InputPolicy { case vendor, nativeManifest }
    public enum GroupPolicy { case independentGroup, inheritWorkerGroup }
    /// Output only; a terminal never becomes an input or authorization channel.
    public enum OutputPolicy { case pipe, terminal }
    public struct Result: Equatable {
        public let outcome: String
        public let exitStatus: Int32
        public let stop: String?
        public let ownershipUncertain: Bool
        public init(outcome: String, exitStatus: Int32, stop: String?, ownershipUncertain: Bool = false) {
            self.outcome = outcome; self.exitStatus = exitStatus; self.stop = stop; self.ownershipUncertain = ownershipUncertain
        }
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
    private var uncertainOwnership = false
    // Internal supervision seam; configured before start by census regressions.
    var processInventory: () -> [proc_bsdinfo]? = HomebrewTaskProcess.processes
    public init(executable: URL, arguments: [String], environment: [String: String],
                interruptGrace: TimeInterval = 10, terminateGrace: TimeInterval = 5, standardInput: Data? = nil, inputPolicy: InputPolicy = .vendor,
                groupPolicy: GroupPolicy = .independentGroup, outputPolicy: OutputPolicy = .pipe) {
        self.executable = executable; self.arguments = arguments
        var outputEnvironment = environment
        // The output-only PTY supports cursor redraws. `dumb` suppresses
        // Homebrew's download renderer even when both output streams are TTYs.
        if outputPolicy == .terminal {
            outputEnvironment["TERM"] = "xterm-256color"
            outputEnvironment["COLUMNS"] = String(Self.terminalColumns)
        }
        self.environment = outputEnvironment
        self.interruptGrace = interruptGrace; self.terminateGrace = terminateGrace
        self.standardInput = standardInput; self.inputPolicy = inputPolicy
        self.groupPolicy = groupPolicy
        self.outputPolicy = outputPolicy
    }
    public var processIdentifier: Int32 { lock.lock(); defer { lock.unlock() }; return pid }
    public var ownershipUncertain: Bool { lock.lock(); defer { lock.unlock() }; return uncertainOwnership }
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
            var size = winsize(ws_row: 24, ws_col: UInt16(Self.terminalColumns), ws_xpixel: 0, ws_ypixel: 0)
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
        if status == 0 {
            pid = child
            if let leaderIdentity { observedIdentities[child] = leaderIdentity }
            else { uncertainOwnership = true }
        }
        lock.unlock()
        guard status == 0 else { throw PluginHostServiceError.tool(.failed) }
        let leader = child, reader = descriptors[0]
        transferredReader = true
        _ = fcntl(reader, F_SETFL, O_NONBLOCK)
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { close(reader) }
            var exitStatus: Int32 = 0, reaped = false, lastSignal: Int32 = 0, pipeOpen = true
            var census = Census()
            while true {
                // Reserve the original leader's zombie PID through a final
                // census. Reaping a leader that exits after the census would
                // otherwise lose a fast, newly reparented inherited child.
                var exitInfo = siginfo_t()
                let exitedBeforeCensus = !reaped && waitid(P_PID, id_t(leader), &exitInfo, WEXITED | WNOHANG | WNOWAIT) == 0 && exitInfo.si_pid == leader
                // Remember identity before reparenting. A recycled PID can
                // never receive one of this Task's stop signals.
                let inventory = processInventory()
                let processes = inventory ?? []
                census.observe(inventory, leader: leader, leaderIdentity: leaderIdentity, ownsGroup: ownsGroup,
                    leaderGroupBound: exitedBeforeCensus || (!reaped && leaderIdentity.map { Self.identityIncludingZombie(leader) == $0 } == true),
                    identity: Self.startIdentity)
                var buffer = [UInt8](repeating: 0, count: 8192)
                let bytes = Darwin.read(reader, &buffer, buffer.count)
                if bytes > 0 { output(Data(buffer.prefix(bytes))) }
                // A PTY reports EIO once its final slave is closed on some
                // systems, rather than the zero-byte EOF used by a pipe.
                else if bytes == 0 || (bytes < 0 && errno == EIO && outputPolicy == .terminal) { pipeOpen = false }
                if !reaped, exitedBeforeCensus || leaderIdentity == nil { reaped = waitpid(leader, &exitStatus, WNOHANG) == leader }
                lock.lock(); let stopping = stopAt; lock.unlock()
                let liveDescendants = census.members.filter { key, identity in Self.startIdentity(key) == identity }
                let leaderAlive = leaderIdentity.map { Self.startIdentity(leader) == $0 } ?? false
                let groupExists = ownsGroup && (leaderAlive || processes.contains { info in
                    Int32(info.pbi_pgid) == leader && liveDescendants[Int32(info.pbi_pid)] == Self.identity(info)
                })
                lock.lock()
                uncertainOwnership = uncertainOwnership || census.ownershipUncertain
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
            lock.lock(); ended = true; observedIdentities = [:]
            let wasStopped = stopAt != nil, uncertain = uncertainOwnership; lock.unlock()
            let signaled = exitStatus & 0x7f
            let code = signaled == 0 ? (exitStatus >> 8) & 0xff : 128 + signaled
            finished(Result(outcome: uncertain ? "unknown" : wasStopped ? "stopped" : code == 0 ? "completed" : "failed", exitStatus: code,
                stop: wasStopped ? lastSignal == SIGKILL ? "killed" : lastSignal == SIGTERM ? "terminated" : "interrupted" : nil,
                ownershipUncertain: uncertain))
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
    private static func processes() -> [proc_bsdinfo]? {
        guard let ids = processIDs(proc_listallpids) else { return nil }
        return ids.compactMap { pid in
            var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != SZOMB ? info : nil
        }
    }
    static func processIDs(_ list: (UnsafeMutableRawPointer?, Int32) -> Int32) -> [pid_t]? {
        let count = list(nil, 0)
        guard count > 0, count <= HomebrewTaskProcessLease.maximumProcessInventory else { return nil }
        var ids = [pid_t](repeating: 0, count: Int(count) + 64)
        let actual = ids.withUnsafeMutableBytes { list($0.baseAddress, Int32($0.count)) }
        // A full buffer may be truncated by concurrent process creation.
        guard actual > 0, actual < ids.count, actual <= HomebrewTaskProcessLease.maximumProcessInventory else { return nil }
        return Array(ids.prefix(Int(actual)))
    }

    /// Bounded live ancestry evidence. Once a census misses possible children,
    /// later PID disappearance cannot reconstruct their lost ancestry.
    struct Census {
        private(set) var members: [pid_t: UInt64] = [:]
        private(set) var ownershipUncertain = false

        private mutating func add(_ info: proc_bsdinfo, leader: pid_t, maximumMembers: Int) -> Bool {
            let pid = Int32(info.pbi_pid), birth = HomebrewTaskProcess.identity(info)
            guard pid != leader, members[pid] != birth else { return false }
            guard members.count < max(0, maximumMembers - 1) else { ownershipUncertain = true; return false }
            members[pid] = birth; return true
        }

        mutating func observe(_ inventory: [proc_bsdinfo]?, leader: pid_t, leaderIdentity: UInt64?,
                              ownsGroup: Bool, leaderGroupBound: Bool, identity: (pid_t) -> UInt64?,
                              maximumMembers: Int = HomebrewTaskProcessLease.maximumMembers) {
            // The budget counts live births, not every PID seen during a long
            // upgrade. A reused PID never inherits its previous ownership.
            members = members.filter { identity($0.key) == $0.value }
            guard let inventory else { ownershipUncertain = true; return }
            let current = Dictionary(inventory.map { (Int32($0.pbi_pid), HomebrewTaskProcess.identity($0)) }, uniquingKeysWith: { first, _ in first })
            let originalGroup = ownsGroup && (leaderGroupBound || inventory.contains {
                Int32($0.pbi_pgid) == leader && members[Int32($0.pbi_pid)] == HomebrewTaskProcess.identity($0)
            })
            func candidates(_ parents: [pid_t: UInt64]) -> [proc_bsdinfo] {
                inventory.filter {
                    let parent = Int32($0.pbi_ppid)
                    return parents[parent] != nil && parents[parent] == current[parent]
                }
            }
            // Reserve one member slot for the leader in the durable lease.
            if originalGroup {
                for info in inventory where Int32(info.pbi_pgid) == leader { _ = add(info, leader: leader, maximumMembers: maximumMembers) }
            }
            for round in 0..<HomebrewTaskProcessLease.maximumDiscoveryDepth {
                var parents = members.filter { current[$0.key] == $0.value }
                if let leaderIdentity, current[leader] == leaderIdentity { parents[leader] = leaderIdentity }
                var discovered = false
                for info in candidates(parents) { if add(info, leader: leader, maximumMembers: maximumMembers) { discovered = true } }
                if !discovered { break }
                if round == HomebrewTaskProcessLease.maximumDiscoveryDepth - 1 {
                    var finalParents = members.filter { current[$0.key] == $0.value }
                    if let leaderIdentity, current[leader] == leaderIdentity { finalParents[leader] = leaderIdentity }
                    if candidates(finalParents).contains(where: { Int32($0.pbi_pid) != leader && members[Int32($0.pbi_pid)] != HomebrewTaskProcess.identity($0) }) {
                        ownershipUncertain = true
                    }
                }
            }
        }
    }
}
