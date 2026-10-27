import SpinnetCore
import Foundation
import CryptoKit
import Darwin

/// Descriptor-based native mutation boundary. Its callers must first bind a
/// concrete target to authenticated Host authority. This exposes no Plugin API.
public enum NativeFileQuarantine {
    public struct Snapshot: Codable, Equatable {
        public let device: UInt64
        public let inode: UInt64
        public let owner: UInt32
        public let group: UInt32
        public let mode: UInt32
        public let links: UInt64
        public let directory: Bool
        public let size: Int64
        public let modifiedSeconds: Int64
        public let modifiedNanoseconds: Int64
        public let sha256: String
        public let aclSHA256: String
        public let writableACL: Bool
        public var symbolicLink: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFLNK) }
    }
    public enum Removal: Equatable { case removed, keptNonemptyDirectory }
    public enum Failure: Error { case retained(URL) }
    public static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let (parent, name) = try openParent(url); defer { close(parent) }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(descriptor) }
        guard let acl = acl_init(0) else { throw PluginHostServiceError.tool(.failed) }; defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var flags: acl_flagset_t?
        guard acl_get_flagset_np(UnsafeMutableRawPointer(acl), &flags) == 0, let flags, acl_add_flag_np(flags, ACL_FLAG_NO_INHERIT) == 0,
              acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0, fchmod(descriptor, 0o700) == 0 else { throw PluginHostServiceError.tool(.failed) }
    }
    public static func openParent(_ url: URL) throws -> (Int32, String) {
        var path = url.standardizedFileURL.path
        // Canonical macOS system aliases; arbitrary ancestor symlinks remain
        // forbidden. Foundation's URL resolver can retain /var in test runners.
        if path.hasPrefix("/var/") { path = "/private" + path }
        if path.hasPrefix("/tmp/") { path = "/private" + path }
        let components = path.split(separator: "/").map(String.init)
        guard path.utf8.count <= 2048, (1...64).contains(components.count), !components.contains("..") else { throw PluginHostServiceError.tool(.planChanged) }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
        do {
            for part in components.dropLast() {
                let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; close(descriptor); descriptor = next
            }
            return (descriptor, components.last!)
        } catch { close(descriptor); throw error }
    }
    public static func existsWithoutFollowing(_ url: URL) throws -> Bool {
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        let components = path.split(separator: "/").map(String.init)
        guard components.count <= 64, !components.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(descriptor) }
        for part in components.dropLast() {
            let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 { if errno == ENOENT { return false }; throw PluginHostServiceError.tool(.planChanged) }
            close(descriptor); descriptor = next
        }
        var status = stat()
        if fstatat(descriptor, components.last!, &status, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw PluginHostServiceError.tool(.planChanged) }; return false
    }
    public static func capture(_ url: URL, maximumBytes: Int64 = 8 * 1024 * 1024 * 1024, deadline: Date = Date().addingTimeInterval(30), isCancelled: () -> Bool = { false }) throws -> Snapshot {
        let (parent, name) = try openParent(url); defer { close(parent) }
        return try capture(parent: parent, name: name, maximumBytes: maximumBytes, deadline: deadline, isCancelled: isCancelled)
    }
    private static func capture(parent: Int32, name: String, maximumBytes: Int64 = 8 * 1024 * 1024 * 1024, deadline: Date, isCancelled: () -> Bool = { false }) throws -> Snapshot {
        guard (0...8 * 1024 * 1024 * 1024).contains(maximumBytes) else { throw PluginHostServiceError.tool(.planChanged) }
        let expires = ProcessInfo.processInfo.systemUptime + max(0, deadline.timeIntervalSinceNow)
        func check() throws {
            guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
            guard ProcessInfo.processInfo.systemUptime < expires else { throw PluginHostServiceError.tool(.timedOut) }
        }
        try check()
        var before = stat()
        guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        if before.st_mode & S_IFMT == S_IFLNK {
            guard before.st_nlink == 1, before.st_size > 0, before.st_size <= 2048, Date() < deadline else { throw PluginHostServiceError.tool(.planChanged) }
            guard before.st_size <= maximumBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            var bytes = [UInt8](repeating: 0, count: 2049), after = stat()
            let count = readlinkat(parent, name, &bytes, bytes.count)
            guard count > 0, count <= 2048, fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
            // Delete only this frozen link. Its target is never opened, hashed,
            // copied or traversed, including during private quarantine.
            return Snapshot(device: UInt64(before.st_dev), inode: UInt64(before.st_ino), owner: before.st_uid, group: before.st_gid, mode: UInt32(before.st_mode), links: UInt64(before.st_nlink), directory: false, size: Int64(count), modifiedSeconds: Int64(before.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(before.st_mtimespec.tv_nsec), sha256: HomebrewSystemAuthorization.digest(Data(bytes.prefix(count))), aclSHA256: "", writableACL: false)
        }
        guard
              before.st_mode & S_IFMT == S_IFDIR || (before.st_mode & S_IFMT == S_IFREG && before.st_nlink == 1) else { throw PluginHostServiceError.tool(.planChanged) }
        let directory = before.st_mode & S_IFMT == S_IFDIR
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
        guard file >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(file) }
        var opened = stat(), after = stat()
        guard fstat(file, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino else { throw PluginHostServiceError.tool(.planChanged) }
        var capturedACL = acl_get_fd_np(file, ACL_TYPE_EXTENDED)
        if capturedACL == nil && errno == ENOENT { capturedACL = acl_init(0) }
        guard let acl = capturedACL else { throw PluginHostServiceError.tool(.planChanged) }; defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var textLength: ssize_t = 0
        guard let text = acl_to_text(acl, &textLength), textLength >= 0, textLength <= 64 * 1024 else { throw PluginHostServiceError.tool(.planChanged) }; defer { acl_free(text) }
        let aclDigest = HomebrewSystemAuthorization.digest(Data(bytes: text, count: textLength))
        var writableACL = false, entry: acl_entry_t?, index = ACL_FIRST_ENTRY
        while acl_get_entry(acl, index.rawValue, &entry) == 0 {
            index = ACL_NEXT_ENTRY
            guard let entry else { throw PluginHostServiceError.tool(.planChanged) }
            var tag = ACL_UNDEFINED_TAG, permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset(entry, &permissions) == 0, let permissions else { throw PluginHostServiceError.tool(.planChanged) }
            if tag == ACL_EXTENDED_ALLOW {
                for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                    if acl_get_perm_np(permissions, permission) == 1 { writableACL = true }
                }
            }
        }
        var digest = "", size: Int64 = 0
        if !directory {
            guard opened.st_size >= 0, opened.st_size <= maximumBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 128 * 1024)
            while true {
                try check()
                let count = Darwin.read(file, &buffer, buffer.count)
                guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
                size += Int64(count); guard size <= opened.st_size else { throw PluginHostServiceError.tool(.planChanged) }
                hasher.update(data: Data(buffer.prefix(count)))
            }
            guard size == opened.st_size else { throw PluginHostServiceError.tool(.planChanged) }
            digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        try check()
        guard fstat(file, &after) == 0, opened.st_dev == after.st_dev, opened.st_ino == after.st_ino,
              directory || (opened.st_size == after.st_size && opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec) else { throw PluginHostServiceError.tool(.planChanged) }
        return Snapshot(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino), owner: opened.st_uid, group: opened.st_gid, mode: UInt32(opened.st_mode), links: directory ? 0 : UInt64(opened.st_nlink), directory: directory, size: size,
            modifiedSeconds: directory ? 0 : Int64(opened.st_mtimespec.tv_sec), modifiedNanoseconds: directory ? 0 : Int64(opened.st_mtimespec.tv_nsec), sha256: digest, aclSHA256: aclDigest, writableACL: writableACL)
    }
    public static func remove(_ url: URL, expected: Snapshot, staging: URL, expectedParent: Snapshot? = nil, deadline: Date = Date().addingTimeInterval(30), isCancelled: () -> Bool = { false }, mutation: (_ action: () throws -> Void) throws -> Void = { try $0() }) throws -> Removal {
        let (parent, name) = try openParent(url); defer { close(parent) }
        if let expectedParent { guard try NativePathParentSnapshot.captureDirectoryDescriptor(parent, deadline: deadline) == expectedParent else { throw PluginHostServiceError.tool(.planChanged) } }
        let (stageParent, stageName) = try openParent(staging); defer { close(stageParent) }
        let stage = openat(stageParent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(stage) }
        var status = stat()
        let frozenStage = try capture(parent: stageParent, name: stageName, deadline: deadline, isCancelled: isCancelled)
        guard fstat(stage, &status) == 0, status.st_uid == getuid(), status.st_mode & 0o077 == 0,
              UInt64(status.st_dev) == frozenStage.device, UInt64(status.st_ino) == frozenStage.inode,
              !frozenStage.writableACL,
              !isCancelled(), try capture(parent: parent, name: name, deadline: deadline, isCancelled: isCancelled) == expected else { throw PluginHostServiceError.tool(.planChanged) }
        // Retain unrelated contents in place whenever possible. A final empty
        // check still happens after quarantine, where a race cannot redirect it.
        if expected.directory {
            let file = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0, let directory = fdopendir(file) else { if file >= 0 { close(file) }; throw PluginHostServiceError.tool(.planChanged) }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
                if name != "." && name != ".." { return .keptNonemptyDirectory }
            }
        }
        let quarantineName = UUID().uuidString.lowercased()
        guard !isCancelled(), Date() < deadline else { throw PluginHostServiceError.tool(.planChanged) }
        try mutation {
            if let expectedParent { guard try NativePathParentSnapshot.captureDirectoryDescriptor(parent, deadline: deadline) == expectedParent else { throw PluginHostServiceError.tool(.planChanged) } }
            guard renameatx_np(parent, name, stage, quarantineName, UInt32(RENAME_EXCL)) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        }
        do {
            guard !isCancelled(), try capture(parent: stage, name: quarantineName, deadline: deadline, isCancelled: isCancelled) == expected,
                  !isCancelled(), Date() < deadline else { throw PluginHostServiceError.tool(.planChanged) }
            var removed = false, failure: Int32 = 0
            try mutation { removed = unlinkat(stage, quarantineName, expected.directory ? AT_REMOVEDIR : 0) == 0; failure = errno }
            if removed { return .removed }
            if expected.directory && failure == ENOTEMPTY {
                guard renameatx_np(stage, quarantineName, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw Failure.retained(staging.appendingPathComponent(quarantineName)) }
                return .keptNonemptyDirectory
            }
            throw PluginHostServiceError.tool(.failed)
        } catch {
            if renameatx_np(stage, quarantineName, parent, name, UInt32(RENAME_EXCL)) != 0 { throw Failure.retained(staging.appendingPathComponent(quarantineName)) }
            throw error
        }
    }
}
