import Darwin
import Foundation
import SpinnetCore

/// Private developer snapshots, independent of Task journals and their retention.
/// The control file is shared with the runner so a change also reaches an
/// already-running Task. Its lock serializes the switch with snapshot writes.
public final class DeveloperTaskLogs {
    public static let maximumFiles = 64
    public static let maximumBytes = 64 * 1024
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var isEnabled: Bool {
        (try? withControl(create: false) { fd in Self.enabled(fd) }) ?? false
    }

    public func setEnabled(_ enabled: Bool) throws {
        try withControl(create: enabled) { fd in
            var value: UInt8 = enabled ? 49 : 48
            guard pwrite(fd, &value, 1, 0) == 1, ftruncate(fd, 1) == 0, fsync(fd) == 0 else {
                throw Self.fileError()
            }
        }
    }

    /// Writes only the already-sanitized summary, never raw command output or
    /// Task metadata. A disabled switch leaves earlier snapshots untouched.
    public func record(_ log: HomebrewTaskLog, taskID: String) throws {
        guard Self.validTaskID(taskID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try withControl(create: false) { fd in
            guard Self.enabled(fd) else { return }
            let file = directory.appendingPathComponent(taskID + ".log")
            if !FileManager.default.fileExists(atPath: file.path) { try makeRoom(for: file) }
            let lines = log.lines
            let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            let bounded = HomebrewCommandOutput.tail(text, maximumBytes: Self.maximumBytes)
            try Data(bounded.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func makeRoom(for file: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "log" && Self.validTaskID($0.deletingPathExtension().lastPathComponent) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
            }
        for old in files.prefix(max(0, files.count - Self.maximumFiles + 1)) where old != file {
            try FileManager.default.removeItem(at: old)
        }
    }

    private func withControl<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T? {
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            if errno == ENOENT && !create { return nil }
            throw Self.fileError()
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let path = directory.appendingPathComponent("recording").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.fileError() }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard flock(fd, LOCK_EX) == 0 else { throw Self.fileError() }
        defer { flock(fd, LOCK_UN) }
        return try body(fd)
    }

    private static func enabled(_ fd: Int32) -> Bool {
        var value: UInt8 = 0
        return pread(fd, &value, 1, 0) == 1 && value == 49
    }

    private static func validTaskID(_ id: String) -> Bool {
        guard id.hasPrefix("activity_"), id.utf8.count == 41 else { return false }
        return id.dropFirst(9).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func fileError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
