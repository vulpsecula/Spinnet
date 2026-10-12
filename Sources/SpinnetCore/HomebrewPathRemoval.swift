import Foundation
import CryptoKit
import Darwin

/// Execute only an independently reconstructed, concrete data manifest inside
/// the isolated mutation worker. No recursive rm, new glob expansion authority,
/// arbitrary executable, or missing-path success is provided.
public enum HomebrewPathRemoval {
    public struct Retained: Codable, Equatable { public let path: String; public let reason: String }
    public struct Result: Codable, Equatable {
        public let removed: [String]
        public let retained: [Retained]
        public let quarantined: [String]
        public init(removed: [String] = [], retained: [Retained] = [], quarantined: [String] = []) { self.removed = removed; self.retained = retained; self.quarantined = quarantined }
    }
    public struct Failure: Error { public let failure: ReviewedToolFailure; public let result: Result }
    public struct PendingOperation: Codable {
        public let version: Int
        public let manifestSHA256: String
        public let path: String
        public let operation: HomebrewPathManifest.Operation
        public let snapshot: NativeFileQuarantine.Snapshot
        public let parent: HomebrewPathManifest.FrozenPath
        public let quarantineName: String
    }
    public struct Request: Codable {
        public let version: Int
        public let manifest: HomebrewPathManifest.Manifest
        public let staging: URL
        public let deadline: Date
        public init(manifest: HomebrewPathManifest.Manifest, staging: URL, deadline: Date) { version = 1; self.manifest = manifest; self.staging = staging; self.deadline = deadline }
    }
    public struct Response: Codable {
        public let version: Int
        public let result: Result?
        public let failure: ReviewedToolFailure?
        public let unavailable: String?
        public init(result: Result? = nil, failure: ReviewedToolFailure? = nil, unavailable: String? = nil) { version = 1; self.result = result; self.failure = failure; self.unavailable = unavailable }
    }
    public static func remove(_ manifest: HomebrewPathManifest.Manifest, staging: URL, deadline: Date,
                              isCancelled: @escaping () -> Bool = { false },
                              mutation: (_ action: () throws -> Void) throws -> Void = { try $0() }) throws -> Result {
        try manifest.validateSeal()
        return try Engine(manifest, staging: staging, deadline: deadline, isCancelled: isCancelled).run(mutation)
    }
    private final class Engine {
        let manifest: HomebrewPathManifest.Manifest, staging: URL, deadline: Date, expires: TimeInterval
        let cancelled: () -> Bool
        var stage: Int32 = -1
        var parents: [String: Int32] = [:]
        var removed: [String] = [], retained: [Retained] = [], quarantined: [String] = []
        var stageSnapshot: NativeFileQuarantine.Snapshot?
        var protectedIdentities = Set<String>()
        lazy var frozenParents = Dictionary(uniqueKeysWithValues: manifest.ancestors.map { ($0.path, $0) })
        init(_ manifest: HomebrewPathManifest.Manifest, staging: URL, deadline: Date, isCancelled: @escaping () -> Bool) {
            self.manifest = manifest; self.staging = staging; self.deadline = min(deadline, Date().addingTimeInterval(60)); cancelled = isCancelled
            expires = ProcessInfo.processInfo.systemUptime + max(0, self.deadline.timeIntervalSinceNow)
        }
        deinit { if stage >= 0 { close(stage) }; for fd in parents.values { close(fd) } }
        var result: Result { .init(removed: removed, retained: retained, quarantined: quarantined) }
        func check() throws { guard !cancelled() else { throw PluginHostServiceError.tool(.planChanged) }; guard ProcessInfo.processInfo.systemUptime < expires else { throw PluginHostServiceError.tool(.timedOut) } }
        func run(_ mutation: (_ action: () throws -> Void) throws -> Void) throws -> Result {
            do {
                try check(); try preflight()
                let conditional = manifest.retainedDirectories.map { HomebrewPathManifest.Entry(path: $0.path, operation: .rmdir, snapshot: $0.snapshot, childrenSHA256: $0.childrenSHA256) }
                let entries = (manifest.entries + conditional).sorted { a, b in let left = a.path.split(separator: "/").count, right = b.path.split(separator: "/").count; return left == right ? a.path.utf8.lexicographicallyPrecedes(b.path.utf8) : left > right }
                for entry in entries { try remove(entry, mutation) }
                return result
            } catch {
                guard removed.isEmpty && quarantined.isEmpty else {
                    let failure: ReviewedToolFailure
                    if case PluginHostServiceError.tool(let value) = error { failure = value } else { failure = .failed }
                    throw Failure(failure: failure, result: result)
                }
                throw error
            }
        }
        func canonical(_ path: String) -> String { if path == "/var" || path == "/tmp" || path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { return "/private" + path }; return path }
        func parent(_ path: String) -> String { canonical(URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        func expectedParent(_ path: String) throws -> HomebrewPathManifest.FrozenPath {
            let name = parent(path)
            guard let frozen = frozenParents[name] else { throw PluginHostServiceError.tool(.planChanged) }
            return frozen
        }
        func preflight() throws {
            guard Set(manifest.ancestors.map(\.path)).count == manifest.ancestors.count,
                  Set(manifest.entries.map(\.path) + manifest.retainedDirectories.map(\.path)).count == manifest.entries.count + manifest.retainedDirectories.count else { throw PluginHostServiceError.tool(.planChanged) }
            let topology = try NativeReceiptTopology.capture(deadline: deadline)
            guard topology.fingerprint == manifest.topologySHA256 else { throw PluginHostServiceError.tool(.planChanged) }
            for item in manifest.ancestors { try check(); try NativePathParentSnapshot.revalidate(item, deadline: deadline) }
            // Rmdir is exact conditional-empty directory authority. Its old
            // contents may be removed by an earlier approved uninstall phase;
            // those contents never become deletion authority here.
            let deletes = manifest.directives.filter { $0.kind != .rmdir }
            let expectedDeletes = manifest.entries.filter { $0.operation == .delete }
            if !deletes.isEmpty {
                let current = try HomebrewPathManifest.inventoryInWorker(.init(context: manifest.context, directives: deletes, deadline: deadline))
                guard current.topologySHA256 == manifest.topologySHA256,
                      current.entries == expectedDeletes else { throw PluginHostServiceError.tool(.planChanged) }
            } else { guard expectedDeletes.isEmpty else { throw PluginHostServiceError.tool(.planChanged) } }
            if !manifest.retainedDirectories.isEmpty { guard manifest.directives.contains(where: { $0.kind == .rmdir }) else { throw PluginHostServiceError.tool(.planChanged) } }
            let allPaths = manifest.entries.map(\.path) + manifest.retainedDirectories.map(\.path)
            let savedEntries = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) })
            let savedRetained = Dictionary(uniqueKeysWithValues: manifest.retainedDirectories.map { ($0.path, $0.snapshot) })
            try captureProtectedIdentities()
            let uniqueParents = Set(allPaths.map(parent))
            var limit = rlimit(); guard getrlimit(RLIMIT_NOFILE, &limit) == 0,
                uniqueParents.count <= 4096, UInt64(uniqueParents.count + 64) < limit.rlim_cur else { throw PluginHostServiceError.unavailable("Native cleanup exceeds the retained descriptor bound") }
            let (stageParent, stageName) = try NativeFileQuarantine.openParent(staging); defer { close(stageParent) }
            stage = openat(stageParent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard stage >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
            let stageState = try NativePathParentSnapshot.captureDirectoryDescriptor(stage, deadline: deadline)
            guard stageState.owner == getuid(), stageState.mode & 0o7777 == 0o700 else { throw PluginHostServiceError.tool(.planChanged) }
            try noACL(stage)
            var stageInfo = stat(); guard fstat(stage, &stageInfo) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
            try NativeReceiptTopology.prove(staging.path, status: stageInfo, mounts: topology)
            stageSnapshot = stageState
            for path in allPaths {
                try check()
                let (fd, name) = try NativeFileQuarantine.openParent(URL(fileURLWithPath: path))
                let key = parent(path)
                if let prior = parents[key] { close(fd); guard try NativePathParentSnapshot.captureDirectoryDescriptor(prior, deadline: deadline) == expectedParent(path).snapshot else { throw PluginHostServiceError.tool(.planChanged) } }
                else { parents[key] = fd; guard try NativePathParentSnapshot.captureDirectoryDescriptor(fd, deadline: deadline) == expectedParent(path).snapshot else { throw PluginHostServiceError.tool(.planChanged) } }
                guard let held = parents[key] else { throw PluginHostServiceError.tool(.planChanged) }
                let entry = savedEntries[path]
                let saved = try entry?.snapshot ?? savedRetained[path].unwrap()
                let current = try capture(held, name)
                guard current == saved, current.device == stageState.device else { throw PluginHostServiceError.tool(.planChanged) }
                var info = stat(); guard fstatat(held, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
                try NativeReceiptTopology.prove(path, status: info, mounts: topology)
                try protectedIdentity(info)
                if entry?.operation == .delete, current.directory { guard try childrenDigest(held, name) == entry?.childrenSHA256 else { throw PluginHostServiceError.tool(.planChanged) } }
            }
            try check()
        }
        func remove(_ entry: HomebrewPathManifest.Entry, _ mutation: (_ action: () throws -> Void) throws -> Void) throws {
            try check()
            guard let fd = parents[parent(entry.path)], let stageSnapshot else { throw PluginHostServiceError.tool(.planChanged) }
            let name = URL(fileURLWithPath: entry.path).lastPathComponent
            let frozenParent = try expectedParent(entry.path)
            try NativePathParentSnapshot.revalidate(frozenParent, deadline: deadline)
            guard try NativePathParentSnapshot.captureDirectoryDescriptor(fd, deadline: deadline) == frozenParent.snapshot,
                  try NativePathParentSnapshot.captureDirectoryDescriptor(stage, deadline: deadline) == stageSnapshot,
                  try capture(fd, name) == entry.snapshot else { throw PluginHostServiceError.tool(.planChanged) }
            if entry.snapshot.directory, !(try empty(fd, name, expected: entry.snapshot)) { retained.append(.init(path: entry.path, reason: "nonempty")); return }
            let temporary = "removed-" + UUID().uuidString.lowercased()
            let pending = try persist(entry, parent: frozenParent, quarantine: temporary)
            var renamed = false
            var deleted = false
            do {
                try mutation {
                    guard renameatx_np(fd, name, stage, temporary, UInt32(RENAME_EXCL)) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
                    renamed = true
                }
                guard renamed else { throw PluginHostServiceError.tool(.planChanged) }
                guard fsync(fd) == 0, fsync(stage) == 0 else { throw PluginHostServiceError.tool(.failed) }
            } catch {
                if !renamed { try clearPending(pending) }
                else if try exists(stage, temporary) { try restore(fd, name, temporary, entry.path); try clearPending(pending) }
                throw error
            }
            do {
                try check()
                guard try capture(stage, temporary) == entry.snapshot else { throw PluginHostServiceError.tool(.planChanged) }
                if entry.snapshot.directory, !(try empty(stage, temporary, expected: entry.snapshot)) {
                    try restore(fd, name, temporary, entry.path); try clearPending(pending); retained.append(.init(path: entry.path, reason: "nonempty")); return
                }
                var failure: Int32 = 0
                try mutation { deleted = unlinkat(stage, temporary, entry.snapshot.directory ? AT_REMOVEDIR : 0) == 0; failure = errno }
                if deleted { removed.append(entry.path); guard fsync(stage) == 0 else { throw PluginHostServiceError.tool(.failed) }; try clearPending(pending); return }
                if entry.snapshot.directory, failure == ENOTEMPTY {
                    try restore(fd, name, temporary, entry.path); try clearPending(pending); retained.append(.init(path: entry.path, reason: "nonempty")); return
                }
                throw PluginHostServiceError.tool(.failed)
            } catch {
                // Once removed, never restore or replay an action whose outcome
                // is known. The caller gets exact irreversible partial progress.
                if deleted, !removed.contains(entry.path) { removed.append(entry.path) }
                if !removed.contains(entry.path), !quarantined.contains(staging.appendingPathComponent(temporary).path), try exists(stage, temporary) { try restore(fd, name, temporary, entry.path) }
                if !quarantined.contains(staging.appendingPathComponent(temporary).path) { try clearPending(pending) }
                throw error
            }
        }
        func restore(_ fd: Int32, _ name: String, _ temporary: String, _ original: String) throws {
            if renameatx_np(stage, temporary, fd, name, UInt32(RENAME_EXCL)) != 0 {
                quarantined.append(staging.appendingPathComponent(temporary).path)
                retained.append(.init(path: original, reason: "restoreFailed"))
                throw PluginHostServiceError.tool(.planChanged)
            }
            guard fsync(fd) == 0, fsync(stage) == 0 else { throw PluginHostServiceError.tool(.failed) }
        }
        func persist(_ entry: HomebrewPathManifest.Entry, parent: HomebrewPathManifest.FrozenPath, quarantine: String) throws -> String {
            let pending = PendingOperation(version: 1, manifestSHA256: manifest.sha256, path: entry.path, operation: entry.operation, snapshot: entry.snapshot, parent: parent, quarantineName: quarantine)
            let bytes = try JSONEncoder().encode(pending)
            guard bytes.count <= 16 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            let name = "pending-" + quarantine + ".json"
            let file = openat(stage, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(file) }
            do {
                try bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let size = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if size < 0 && errno == EINTR { continue }
                        guard size > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += size
                    }
                }
                guard fsync(file) == 0, fchmod(file, 0o400) == 0, fsync(stage) == 0 else { throw PluginHostServiceError.tool(.failed) }
            } catch { unlinkat(stage, name, 0); throw error }
            return name
        }
        func clearPending(_ name: String) throws {
            // Only called after a known removed/restored/not-renamed outcome.
            let status = unlinkat(stage, name, 0)
            guard status == 0 || errno == ENOENT, fsync(stage) == 0 else { throw PluginHostServiceError.tool(.failed) }
        }
        func exists(_ fd: Int32, _ name: String) throws -> Bool {
            var status = stat(); if fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            guard errno == ENOENT else { throw PluginHostServiceError.tool(.planChanged) }; return false
        }
        func noACL(_ fd: Int32) throws {
            if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }; var entry: acl_entry_t?
                guard acl_valid(acl) == 0, acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0 else { throw PluginHostServiceError.tool(.planChanged) }
            } else if errno != ENOENT { throw PluginHostServiceError.tool(.planChanged) }
        }
        func protectedIdentity(_ selected: stat) throws {
            guard selected.st_flags & UInt32(SF_RESTRICTED) == 0 else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            guard !protectedIdentities.contains("\(selected.st_dev):\(selected.st_ino)") else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        }
        func captureProtectedIdentities() throws {
            let home = manifest.context.home.path, prefix = manifest.context.prefix.path
            var paths = HomebrewPathProtection.system + HomebrewPathProtection.user.map { $0 == "~/" ? home : home + String($0.dropFirst()) }
            paths += HomebrewPathProtection.credentials.map { home + "/" + $0 } + HomebrewPathProtection.protectedSystemSubtrees
            paths += [home, prefix, manifest.context.appDirectory.path] + ["bin", "sbin", "lib", "share", "etc", "include", "var", "opt", "Cellar", "Caskroom", "Library", "Library/Homebrew"].map { prefix + "/" + $0 }
            for path in paths {
                try check(); var value = stat()
                if lstat(path, &value) == 0 { protectedIdentities.insert("\(value.st_dev):\(value.st_ino)") }
                else if errno != ENOENT && errno != ENOTDIR { throw PluginHostServiceError.unavailable("Protected cleanup identity is unavailable") }
            }
        }
        func empty(_ parent: Int32, _ name: String, expected: NativeFileQuarantine.Snapshot) throws -> Bool {
            try check()
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
            var info = stat()
            guard fstat(fd, &info) == 0, UInt64(info.st_dev) == expected.device, UInt64(info.st_ino) == expected.inode else { close(fd); throw PluginHostServiceError.tool(.planChanged) }
            guard let directory = fdopendir(fd) else { close(fd); throw PluginHostServiceError.tool(.planChanged) }; defer { closedir(directory) }
            while true {
                try check(); errno = 0
                guard let row = readdir(directory) else { guard errno == 0 else { throw PluginHostServiceError.tool(.planChanged) }; return true }
                let name = withUnsafePointer(to: &row.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(row.pointee.d_namlen) + 1) { String(cString: $0) } }
                if name != "." && name != ".." { return false }
            }
        }
        func capture(_ parent: Int32, _ name: String) throws -> NativeFileQuarantine.Snapshot {
            try check(); var before = stat(), after = stat()
            guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0, before.st_flags & UInt32(SF_RESTRICTED) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
            let kind = before.st_mode & S_IFMT
            if kind == S_IFLNK {
                guard before.st_nlink == 1, before.st_size > 0, before.st_size <= 2048 else { throw PluginHostServiceError.tool(.planChanged) }
                var bytes = [UInt8](repeating: 0, count: 2049)
                let count = readlinkat(parent, name, &bytes, bytes.count)
                guard count > 0, count == before.st_size, fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0, stable(before, after) else { throw PluginHostServiceError.tool(.planChanged) }
                return .init(device: UInt64(before.st_dev), inode: UInt64(before.st_ino), owner: before.st_uid, group: before.st_gid, mode: UInt32(before.st_mode), links: 1, directory: false, size: Int64(count), modifiedSeconds: Int64(before.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(before.st_mtimespec.tv_nsec), sha256: hash(Data(bytes.prefix(count))), aclSHA256: "", writableACL: false)
            }
            guard kind == S_IFDIR || (kind == S_IFREG && before.st_nlink == 1) else { throw PluginHostServiceError.tool(.planChanged) }
            let directory = kind == S_IFDIR
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(fd) }
            var opened = stat(); guard fstat(fd, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino else { throw PluginHostServiceError.tool(.planChanged) }
            var captured = acl_get_fd_np(fd, ACL_TYPE_EXTENDED); if captured == nil && errno == ENOENT { captured = acl_init(0) }
            guard let acl = captured, acl_valid(acl) == 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var length: ssize_t = 0
            guard let text = acl_to_text(acl, &length), length >= 0, length <= 64 * 1024 else { throw PluginHostServiceError.tool(.planChanged) }; defer { acl_free(text) }
            let aclDigest = hash(Data(bytes: text, count: length))
            var writable = false, entry: acl_entry_t?, index = ACL_FIRST_ENTRY
            while acl_get_entry(acl, index.rawValue, &entry) == 0 {
                index = ACL_NEXT_ENTRY; guard let entry else { throw PluginHostServiceError.tool(.planChanged) }
                var tag = ACL_UNDEFINED_TAG, permissions: acl_permset_t?
                guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset(entry, &permissions) == 0, let permissions else { throw PluginHostServiceError.tool(.planChanged) }
                if tag == ACL_EXTENDED_ALLOW { for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] { if acl_get_perm_np(permissions, permission) == 1 { writable = true } } }
            }
            var size: Int64 = 0, sha = ""
            if !directory {
                guard opened.st_size >= 0, opened.st_size <= 8 * 1024 * 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 128 * 1024)
                while true {
                    try check(); let count = Darwin.read(fd, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
                    size += Int64(count); guard size <= opened.st_size else { throw PluginHostServiceError.tool(.planChanged) }; digest.update(data: Data(buffer.prefix(count)))
                }
                guard size == opened.st_size else { throw PluginHostServiceError.tool(.planChanged) }; sha = digest.finalize().map { String(format: "%02x", $0) }.joined()
            }
            guard fstat(fd, &after) == 0, stable(opened, after) else { throw PluginHostServiceError.tool(.planChanged) }
            return .init(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino), owner: opened.st_uid, group: opened.st_gid, mode: UInt32(opened.st_mode), links: directory ? 0 : UInt64(opened.st_nlink), directory: directory, size: size, modifiedSeconds: directory ? 0 : Int64(opened.st_mtimespec.tv_sec), modifiedNanoseconds: directory ? 0 : Int64(opened.st_mtimespec.tv_nsec), sha256: sha, aclSHA256: aclDigest, writableACL: writable)
        }
        func stable(_ before: stat, _ after: stat) -> Bool {
            before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_mode == after.st_mode && before.st_uid == after.st_uid && before.st_gid == after.st_gid && before.st_nlink == after.st_nlink && before.st_size == after.st_size && before.st_flags == after.st_flags && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        }
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func childrenDigest(_ parent: Int32, _ name: String) throws -> String {
            struct Child: Encodable { let name: String, identity: String, mode: UInt32, flags: UInt32, size: Int64, seconds: Int64, nanoseconds: Int64 }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0, let directory = fdopendir(fd) else { if fd >= 0 { close(fd) }; throw PluginHostServiceError.tool(.planChanged) }; defer { closedir(directory) }
            var values: [Child] = []
            while true {
                try check(); errno = 0
                guard let row = readdir(directory) else { guard errno == 0 else { throw PluginHostServiceError.tool(.planChanged) }; break }
                let name = withUnsafePointer(to: &row.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(row.pointee.d_namlen) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                var info = stat(); guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
                values.append(.init(name: name, identity: NativeReceiptTopology.key(info), mode: UInt32(info.st_mode), flags: info.st_flags, size: Int64(info.st_size), seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec)))
                guard values.count <= HomebrewPathManifest.maximumEntries else { throw PluginHostServiceError.tool(.outputTooLarge) }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return hash(try encoder.encode(values.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }))
        }
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped { guard let value = self else { throw PluginHostServiceError.tool(.planChanged) }; return value }
}
