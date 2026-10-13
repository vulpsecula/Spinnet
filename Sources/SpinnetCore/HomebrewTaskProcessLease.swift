import Foundation
import Darwin

/// Small durable execution evidence. It never supplies executable arguments,
/// privileged authority, or replay instructions. A pending reservation without
/// a final actual-reap commit remains unknown even if recorded PIDs vanished.
public struct HomebrewTaskProcessLease: Codable {
    public let version: Int
    public let taskID: String
    public let runnerPID: Int32
    public let runnerIdentity: UInt64
    public var runnerLaunchPending: Bool
    public var ownershipUncertain: Bool
    public var reservation: String?
    public var leaderPID: Int32?
    public var leaderIdentity: UInt64?
    public var members: [String: UInt64]
    public var observedAt: Date
    public static let maximumBytes = 192 * 1024
    public static let maximumMembers = 4096
    public static let maximumProcessInventory = 65_536
    public static let maximumDiscoveryDepth = 64
    public static let maximumRecoveryEntries = 128
    public init(taskID: String, runnerPID: Int32, runnerIdentity: UInt64, runnerLaunchPending: Bool = false,
                reservation: String? = nil, leaderPID: Int32? = nil, leaderIdentity: UInt64? = nil, members: [String: UInt64] = [:]) {
        self.version = 1; self.taskID = taskID; self.runnerPID = runnerPID; self.runnerIdentity = runnerIdentity
        self.runnerLaunchPending = runnerLaunchPending; self.ownershipUncertain = false; self.reservation = reservation
        self.leaderPID = leaderPID; self.leaderIdentity = leaderIdentity; self.members = members; observedAt = Date()
    }
    public var provesNoOwnedExecution: Bool { !ownershipUncertain && !runnerLaunchPending && reservation == nil && leaderPID == nil && leaderIdentity == nil && members.isEmpty }
    private func validate() throws {
        guard version == 1, taskID.range(of: "^activity_[A-Za-z0-9_-]{1,55}$", options: .regularExpression) != nil,
              runnerPID > 1, runnerIdentity > 0, observedAt.timeIntervalSinceReferenceDate.isFinite,
              reservation == nil || reservation!.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil,
              (leaderPID == nil) == (leaderIdentity == nil), leaderPID == nil || (leaderPID! > 1 && leaderIdentity! > 0),
              members.count <= Self.maximumMembers, members.allSatisfy({ Int32($0.key).map { $0 > 1 } == true && $0.value > 0 }),
              reservation != nil || (leaderPID == nil && members.isEmpty) else { throw PluginHostServiceError.tool(.planChanged) }
    }
    public func save(to directory: URL) throws {
        try validate()
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= Self.maximumBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let temporary = ".process-state-" + UUID().uuidString.lowercased()
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw PluginHostServiceError.tool(.failed) }
        defer { close(file); unlinkat(fd, temporary, 0) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += count
            }
        }
        guard fsync(file) == 0, renameat(fd, temporary, fd, "process-state.json") == 0, fsync(fd) == 0 else { throw PluginHostServiceError.tool(.failed) }
    }
    public static func load(from directory: URL) throws -> Self {
        let fd = open(directory.appendingPathComponent("process-state.json").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_mode & 0o077 == 0, before.st_size > 0, before.st_size <= Self.maximumBytes else { throw PluginHostServiceError.tool(.planChanged) }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += count
            }
        }
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
        let value = try JSONDecoder().decode(Self.self, from: bytes); try value.validate()
        guard value.taskID == directory.lastPathComponent else { throw PluginHostServiceError.tool(.planChanged) }; return value
    }
    /// Signal only exact same-account PID births, never an unowned/reused PGID.
    /// A bounded live census may add children of still-validated owned parents.
    public func stopVerifiedMembers(signal: Int32 = SIGTERM) {
        var owned = members
        if let leaderPID, let leaderIdentity { owned[String(leaderPID)] = leaderIdentity }
        var live: [Int32: UInt64] = [:]
        for (key, birth) in owned {
            guard let pid = Int32(key), HomebrewTaskProcess.startIdentity(pid) == birth else { continue }
            var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() { live[pid] = birth }
        }
        // An incomplete census cannot discover additional children, but it
        // cannot prevent Stop of already verified same-account PID births.
        if let processInfo = Self.processInventory() {
            for _ in 0..<Self.maximumDiscoveryDepth {
                var changed = false
                for info in processInfo where live.count < Self.maximumMembers {
                    let parent = Int32(info.pbi_ppid), pid = Int32(info.pbi_pid), birth = HomebrewTaskProcess.identity(info)
                    if let parentBirth = live[parent], HomebrewTaskProcess.startIdentity(parent) == parentBirth, live[pid] == nil {
                        live[pid] = birth; changed = true
                    }
                }
                if !changed { break }
            }
        }
        for (pid, birth) in live where HomebrewTaskProcess.startIdentity(pid) == birth { kill(pid, signal) }
    }
    private static func processInventory() -> [proc_bsdinfo]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0, count <= maximumProcessInventory else { return nil }
        var ids = [pid_t](repeating: 0, count: Int(count) + maximumDiscoveryDepth)
        let actual = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0, actual <= ids.count else { return nil }
        return ids.prefix(Int(actual)).compactMap { pid in
            var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == getuid() && info.pbi_status != SZOMB ? info : nil
        }
    }
}
