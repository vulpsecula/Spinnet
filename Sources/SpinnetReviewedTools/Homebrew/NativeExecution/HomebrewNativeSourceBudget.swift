import SpinnetCore
import Foundation
import Darwin

/// Aggregate expansion ledger for one native source capture. Input download
/// bytes are separately capped; every newly produced archive/payload tree is
/// charged once. Directory views of an already charged tree add no new bytes.
public struct HomebrewNativeSourceBudget {
    public let maximumBytes: Int64
    public let maximumEntries: Int
    public private(set) var usedBytes: Int64 = 0
    public private(set) var usedEntries: Int = 0
    public var remainingBytes: Int64 { maximumBytes - usedBytes }
    public var remainingEntries: Int { maximumEntries - usedEntries }
    public init(maximumBytes: Int64 = 8 * 1024 * 1024 * 1024, maximumEntries: Int = 50_000) throws {
        guard (1...8 * 1024 * 1024 * 1024).contains(maximumBytes), (0...50_000).contains(maximumEntries) else { throw PluginHostServiceError.tool(.outputTooLarge) }
        self.maximumBytes = maximumBytes; self.maximumEntries = maximumEntries
    }
    /// Worker-side only: blocking native tree reads are outer-supervised. This
    /// budget is data accounting, never publisher or administrator authority.
    public mutating func consume(_ tree: HomebrewArchiveStaging.SealedTree, deadline: Date,
                                 isCancelled: () -> Bool = { false }) throws {
        var bytes: Int64 = 0, entries = 0
        func check() throws {
            guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        }
        let root = open(tree.selectedURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard root >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(root) }
        func walk(_ fd: Int32, depth: Int) throws {
            try check()
            guard depth <= 64 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_uid == getuid(), before.st_mode & 0o022 == 0 else { throw PluginHostServiceError.tool(.planChanged) }
            if before.st_mode & S_IFMT == S_IFREG {
                guard before.st_size >= 0, before.st_nlink == 1, before.st_size <= remainingBytes - bytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
                entries += 1; bytes += before.st_size
                guard entries <= maximumEntries - usedEntries else { throw PluginHostServiceError.tool(.outputTooLarge) }
                return
            }
            guard before.st_mode & S_IFMT == S_IFDIR else { throw PluginHostServiceError.tool(.planChanged) }
            let copy = dup(fd)
            guard copy >= 0 else { throw PluginHostServiceError.tool(.failed) }
            guard let stream = fdopendir(copy) else { close(copy); throw PluginHostServiceError.tool(.failed) }; defer { closedir(stream) }
            while true {
                try check(); errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw PluginHostServiceError.tool(.failed) }; break
                }
                let length = Int(entry.pointee.d_namlen)
                guard (1...255).contains(length) else { throw PluginHostServiceError.tool(.planChanged) }
                let data = withUnsafeBytes(of: entry.pointee.d_name) { Data($0.prefix(length)) }
                guard let name = String(data: data, encoding: .utf8), !name.contains("/"), !name.contains("\0") else { throw PluginHostServiceError.tool(.planChanged) }
                if name == "." || name == ".." { continue }
                var status = stat()
                guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
                if status.st_mode & S_IFMT == S_IFLNK {
                    guard status.st_uid == getuid(), status.st_size >= 0, status.st_size <= remainingBytes - bytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    entries += 1; bytes += status.st_size
                } else {
                    if status.st_mode & S_IFMT == S_IFDIR { entries += 1 }
                    guard entries <= maximumEntries - usedEntries else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard child >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
                    do { try walk(child, depth: depth + 1); close(child) } catch { close(child); throw error }
                }
                guard entries <= maximumEntries - usedEntries else { throw PluginHostServiceError.tool(.outputTooLarge) }
            }
            var after = stat()
            guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
        }
        try walk(root, depth: 0)
        guard try HomebrewArchiveStaging.fingerprint(tree.selectedURL, maximumBytes: maximumBytes, deadline: deadline, isCancelled: isCancelled) == tree.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
        usedBytes += bytes; usedEntries += entries
    }
}
