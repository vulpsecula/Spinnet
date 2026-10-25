import Foundation
import CryptoKit
import Darwin

/// Host-owned native staging. Archive parsing runs only in the fixed,
/// unprivileged decoder; this side treats its pipe as untrusted input.
public enum HomebrewArchiveStaging {
    public struct DecoderConfiguration {
        public let bootstrap: URL
        public let uid: uid_t
        public let gid: gid_t
        /// Production supplies a private copy of both signature-verified
        /// tools, not the mutable application bundle paths.
        public init(bootstrap: URL, uid: uid_t, gid: gid_t) { self.bootstrap = bootstrap; self.uid = uid; self.gid = gid }
    }
    public struct SealedTree: Equatable {
        public let selectedURL: URL
        public let sha256: String
    }
    public static func validRelativePath(_ value: String) -> Bool {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty && value.utf8.count <= 2048 && pieces.count <= 64 && !value.hasPrefix("/")
            && !pieces.contains(where: { ["", ".", ".."].contains(String($0)) })
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private struct Entry {
        let kind: UInt8
        let executable: Bool
        let link: String
    }
    public static func extractVerified(_ archive: URL, checksum: String, into output: URL, selected: String,
                                       decoder: DecoderConfiguration, deadline: Date = Date().addingTimeInterval(120),
                                       maximumBytes: Int64 = 8 * 1024 * 1024 * 1024,
                                       maximumEntries: Int = 50_000,
                                       isCancelled: @escaping () -> Bool = { false }) throws -> SealedTree {
        let started = ProcessInfo.processInfo.systemUptime
        let duration = max(0, deadline.timeIntervalSinceNow)
        func check() throws {
            if isCancelled() { throw PluginHostServiceError.tool(.planChanged) }
            if ProcessInfo.processInfo.systemUptime - started >= duration { throw PluginHostServiceError.tool(.timedOut) }
        }
        guard decoder.uid != 0, maximumBytes >= 0, maximumBytes <= 8 * 1024 * 1024 * 1024, (0...50_000).contains(maximumEntries),
              HomebrewPrivilegePlan.validDigest(checksum), selected == "." || validRelativePath(selected),
              archive.path == archive.resolvingSymlinksInPath().path,
              output.deletingLastPathComponent().path == output.deletingLastPathComponent().resolvingSymlinksInPath().path else { throw PluginHostServiceError.tool(.planChanged) }
        let source = open(archive.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(source) }
        var sourceInfo = stat()
        guard fstat(source, &sourceInfo) == 0, sourceInfo.st_mode & S_IFMT == S_IFREG, sourceInfo.st_uid == getuid(),
              sourceInfo.st_mode & 0o022 == 0, sourceInfo.st_nlink == 1, sourceInfo.st_size > 0,
              sourceInfo.st_size <= 8 * 1024 * 1024 * 1024 else { throw PluginHostServiceError.tool(.planChanged) }
        guard try hashFile(source, maximumBytes: 8 * 1024 * 1024 * 1024, check: check) == checksum,
              lseek(source, 0, SEEK_SET) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        var after = stat()
        guard fstat(source, &after) == 0, sourceInfo.st_size == after.st_size,
              sourceInfo.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, sourceInfo.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              sourceInfo.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, sourceInfo.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
        try requireNoACL(source)
        let parent = open(output.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(parent) }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == getuid(), parentInfo.st_mode & 0o077 == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        try requireNoACL(parent)
        guard mkdirat(parent, output.lastPathComponent, 0o700) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let destination = openat(parent, output.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destination >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(destination) }
        do {
            try makePrivateACL(destination)
            let child = try DecoderProcess(configuration: decoder, source: source, check: check)
            defer { child.finish() }
            var entries: [String: Entry] = [:], explicit = Set<String>(), aliases: [String: String] = [:]
            var expanded: Int64 = 0, entryCount = 0
            func register(_ name: String, _ entry: Entry, implicit: Bool = false) throws {
                let alias = name.precomposedStringWithCanonicalMapping.lowercased()
                guard aliases[alias] == nil || aliases[alias] == name,
                      entries[name] == nil || (entries[name]!.kind == 2 && entry.kind == 2 && !explicit.contains(name)),
                      implicit || explicit.insert(name).inserted else { throw PluginHostServiceError.tool(.planChanged) }
                aliases[alias] = name; entries[name] = entry
                guard entries.count <= maximumEntries else { throw PluginHostServiceError.tool(.outputTooLarge) }
            }
            func openParent(_ name: String) throws -> (Int32, String) {
                let parts = name.split(separator: "/").map(String.init)
                var fd = dup(destination), prefix = ""
                guard fd >= 0 else { throw PluginHostServiceError.tool(.failed) }
                do {
                    for component in parts.dropLast() {
                        prefix = prefix.isEmpty ? component : prefix + "/" + component
                        if entries[prefix] == nil {
                            try register(prefix, Entry(kind: 2, executable: false, link: ""), implicit: true)
                            guard mkdirat(fd, component, 0o700) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
                        }
                        guard entries[prefix]?.kind == 2 else { throw PluginHostServiceError.tool(.planChanged) }
                        let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard next >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
                        close(fd); fd = next
                    }
                    return (fd, parts.last!)
                } catch { close(fd); throw error }
            }
            while true {
                try check()
                let header = try child.readExactly(24)
                guard Array(header.prefix(4)) == [83,80,65,49], header[6] == 0, header[7] == 0 else { throw PluginHostServiceError.tool(.failed) }
                func number(_ range: Range<Int>) -> UInt64 { header[range].reduce(0) { ($0 << 8) | UInt64($1) } }
                let kind = header[4], execute = header[5], pathSize = number(8..<12), linkSize = number(12..<16), size = number(16..<24)
                if kind == 0 {
                    guard execute == 0, pathSize == 0, linkSize == 0, size == 0 else { throw PluginHostServiceError.tool(.failed) }
                    try child.requireSuccess(); break
                }
                entryCount += 1
                guard (1...4).contains(kind), execute <= 1, pathSize > 0, pathSize <= 2048, linkSize <= 2048,
                      entryCount <= 50_001, size <= UInt64(maximumBytes - expanded),
                      (kind == 1 && linkSize == 0) || (kind == 2 && size == 0 && linkSize == 0) || (kind >= 3 && size == 0 && linkSize > 0) else { throw PluginHostServiceError.tool(.outputTooLarge) }
                guard let rawName = String(data: try child.readExactly(Int(pathSize)), encoding: .utf8),
                      let link = String(data: try child.readExactly(Int(linkSize)), encoding: .utf8) else { throw PluginHostServiceError.tool(.planChanged) }
                var name = kind == 2 && rawName.hasSuffix("/") ? String(rawName.dropLast()) : rawName
                // Ordinary tar represents its root as ./ and descendants as
                // ./name. Strip only complete leading dot components; an
                // internal dot, traversal or absolute path is still refused.
                while name.hasPrefix("./") { name.removeFirst(2) }
                if kind == 2 && (name.isEmpty || name == ".") { continue }
                guard validRelativePath(name), !link.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PluginHostServiceError.tool(.planChanged) }
                let old = entries[name]
                try register(name, Entry(kind: kind, executable: execute == 1, link: link))
                let (fd, leaf) = try openParent(name); defer { close(fd) }
                if kind == 2 {
                    if old == nil { guard mkdirat(fd, leaf, 0o700) == 0 else { throw PluginHostServiceError.tool(.planChanged) } }
                } else if kind == 1 {
                    let file = openat(fd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard file >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(file) }
                    var left = size
                    while left > 0 { let data = try child.readExactly(Int(min(left, 65536))); try writeAll(file, data); left -= UInt64(data.count) }
                    expanded += Int64(size)
                    guard fchmod(file, execute == 1 ? 0o700 : 0o600) == 0, fsync(file) == 0 else { throw PluginHostServiceError.tool(.failed) }
                }
            }
            func resolve(_ path: String, active: Set<String> = [], budget: Int = 0) throws -> String {
                guard budget < 128, !active.contains(path) else { throw PluginHostServiceError.tool(.planChanged) }
                var stack: [String] = []
                for part in path.split(separator: "/") {
                    if part == "." { continue }
                    if part == ".." { guard !stack.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }; stack.removeLast(); continue }
                    stack.append(String(part))
                    let current = stack.joined(separator: "/")
                    guard let entry = entries[current] else { throw PluginHostServiceError.tool(.planChanged) }
                    if entry.kind == 3 || entry.kind == 4 {
                        guard !entry.link.isEmpty, !entry.link.hasPrefix("/") else { throw PluginHostServiceError.tool(.planChanged) }
                        let base = entry.kind == 3 ? stack.dropLast().joined(separator: "/") : ""
                        let target = base.isEmpty ? entry.link : base + "/" + entry.link
                        stack = try resolve(target, active: active.union([current]), budget: budget + 1).split(separator: "/").map(String.init)
                    }
                }
                return stack.joined(separator: "/")
            }
            for (name, entry) in entries.sorted(by: { $0.key < $1.key }) where entry.kind >= 3 {
                try check()
                let target = try resolve(name)
                guard let targetEntry = entries[target], entry.kind != 4 || targetEntry.kind == 1 else { throw PluginHostServiceError.tool(.planChanged) }
                let (fd, leaf) = try openParent(name); defer { close(fd) }
                if entry.kind == 3 {
                    guard Int64(entry.link.utf8.count) <= maximumBytes - expanded else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    expanded += Int64(entry.link.utf8.count)
                    guard symlinkat(entry.link, fd, leaf) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
                } else {
                    let sourceFile = try openRegular(destination, target); defer { close(sourceFile) }
                    let file = openat(fd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard file >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(file) }
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while true {
                        try check(); let count = Darwin.read(sourceFile, &buffer, buffer.count)
                        guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
                        guard Int64(count) <= maximumBytes - expanded else { throw PluginHostServiceError.tool(.outputTooLarge) }
                        expanded += Int64(count); try writeAll(file, Data(buffer.prefix(count)))
                    }
                    guard fchmod(file, targetEntry.executable ? 0o700 : 0o600) == 0, fsync(file) == 0 else { throw PluginHostServiceError.tool(.failed) }
                    entries[name] = Entry(kind: 1, executable: targetEntry.executable, link: "")
                }
            }
            var finalSource = stat()
            guard fstat(source, &finalSource) == 0, finalSource.st_size == sourceInfo.st_size,
                  finalSource.st_ctimespec.tv_sec == sourceInfo.st_ctimespec.tv_sec, finalSource.st_ctimespec.tv_nsec == sourceInfo.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
            if selected != "." {
                guard let selection = entries[selected], selection.kind == 1 || selection.kind == 2 else { throw PluginHostServiceError.tool(.planChanged) }
            }
            let result = selected == "." ? output : output.appendingPathComponent(selected)
            let remaining = max(0, duration - (ProcessInfo.processInfo.systemUptime - started))
            return SealedTree(selectedURL: result, sha256: try fingerprint(result, maximumBytes: maximumBytes, deadline: Date().addingTimeInterval(remaining), isCancelled: isCancelled))
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
    private static func requireNoACL(_ descriptor: Int32) throws {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw PluginHostServiceError.tool(.planChanged)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0 else { throw PluginHostServiceError.tool(.planChanged) }
    }
    private static func makePrivateACL(_ descriptor: Int32) throws {
        guard let acl = acl_init(0) else { throw PluginHostServiceError.tool(.failed) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var flags: acl_flagset_t?
        guard acl_get_flagset_np(UnsafeMutableRawPointer(acl), &flags) == 0, let flags,
              acl_add_flag_np(flags, ACL_FLAG_NO_INHERIT) == 0,
              acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else { throw PluginHostServiceError.tool(.failed) }
    }
    private static func writeAll(_ file: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += count
            }
        }
    }
    private static func openRegular(_ root: Int32, _ path: String) throws -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        var fd = dup(root); guard fd >= 0 else { throw PluginHostServiceError.tool(.failed) }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); close(fd)
            guard next >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; fd = next
        }
        let result = openat(fd, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC); close(fd)
        guard result >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; return result
    }
    private static func hashFile(_ file: Int32, maximumBytes: Int64, check: () throws -> Void) throws -> String {
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 65536), total: Int64 = 0
        while true {
            try check(); let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
            total += Int64(count); guard total <= maximumBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            hash.update(data: Data(buffer.prefix(count)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Rechecks the entire selected bundle/package, including links and every
    /// code-bearing file. A digest of only an installer executable is insufficient.
    public static func fingerprint(_ tree: URL, maximumBytes: Int64 = 8 * 1024 * 1024 * 1024,
                                   deadline: Date = Date().addingTimeInterval(120), isCancelled: () -> Bool = { false }) throws -> String {
        let started = ProcessInfo.processInfo.systemUptime, duration = max(0, deadline.timeIntervalSinceNow)
        func check() throws {
            if isCancelled() { throw PluginHostServiceError.tool(.planChanged) }
            if ProcessInfo.processInfo.systemUptime - started >= duration { throw PluginHostServiceError.tool(.timedOut) }
        }
        struct Node { let path: String; let kind: UInt8; let mode: UInt16; let size: UInt64; let content: String }
        var nodes: [Node] = [], bytes: Int64 = 0
        func walk(_ parent: Int32, _ name: String, _ relative: String, _ depth: Int) throws {
            try check()
            guard depth <= 64, nodes.count < 50_001 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid() else { throw PluginHostServiceError.tool(.planChanged) }
            let mode = info.st_mode & 0o7777, type = info.st_mode & S_IFMT
            if type == S_IFLNK {
                var buffer = [UInt8](repeating: 0, count: 2049)
                let count = readlinkat(parent, name, &buffer, buffer.count)
                guard count > 0, count <= 2048, let target = String(bytes: buffer.prefix(count), encoding: .utf8),
                      !target.hasPrefix("/"), !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PluginHostServiceError.tool(.planChanged) }
                nodes.append(Node(path: relative, kind: 3, mode: UInt16(mode), size: 0, content: target)); return
            }
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (type == S_IFDIR ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(fd) }
            var held = stat()
            guard fstat(fd, &held) == 0, info.st_ino == held.st_ino, info.st_dev == held.st_dev else { throw PluginHostServiceError.tool(.planChanged) }
            try requireNoACL(fd)
            if type == S_IFREG {
                guard info.st_nlink == 1, mode == 0o600 || mode == 0o700, info.st_size >= 0, info.st_size <= maximumBytes - bytes else { throw PluginHostServiceError.tool(.planChanged) }
                bytes += info.st_size
                let digest = try hashFile(fd, maximumBytes: info.st_size, check: check)
                var after = stat()
                guard fstat(fd, &after) == 0, after.st_size == info.st_size,
                      after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
                nodes.append(Node(path: relative, kind: 1, mode: UInt16(mode), size: UInt64(info.st_size), content: digest))
            } else if type == S_IFDIR {
                guard mode == 0o700 else { throw PluginHostServiceError.tool(.planChanged) }
                nodes.append(Node(path: relative, kind: 2, mode: 0o700, size: 0, content: ""))
                guard let directory = fdopendir(dup(fd)) else { throw PluginHostServiceError.tool(.failed) }; defer { closedir(directory) }
                var names: [String] = []
                errno = 0
                while let entry = readdir(directory) {
                    let value = withUnsafePointer(to: entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingUTF8: $0) } }
                    guard let value else { throw PluginHostServiceError.tool(.planChanged) }
                    if value == "." || value == ".." { continue }
                    guard validRelativePath(value), names.count + nodes.count < 50_001 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    names.append(value); try check(); errno = 0
                }
                guard errno == 0 else { throw PluginHostServiceError.tool(.failed) }
                for child in names.sorted() { try walk(fd, child, relative == "." ? child : relative + "/" + child, depth + 1) }
                var after = stat()
                guard fstat(fd, &after) == 0, after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                      after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
            } else { throw PluginHostServiceError.tool(.planChanged) }
        }
        let parent = open(tree.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(parent) }
        try walk(parent, tree.lastPathComponent, ".", 0)
        let map = Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) })
        func resolve(_ path: String, active: Set<String> = [], budget: Int = 0) throws -> String {
            guard budget < 128 else { throw PluginHostServiceError.tool(.planChanged) }
            var parts: [String] = []
            for component in path.split(separator: "/") {
                if component == "." { continue }
                if component == ".." { guard !parts.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }; parts.removeLast(); continue }
                parts.append(String(component)); let current = parts.joined(separator: "/")
                guard let node = map[current] else { throw PluginHostServiceError.tool(.planChanged) }
                if node.kind == 3 {
                    guard !active.contains(current) else { throw PluginHostServiceError.tool(.planChanged) }
                    let base = parts.dropLast().joined(separator: "/")
                    parts = try resolve(base.isEmpty ? node.content : base + "/" + node.content, active: active.union([current]), budget: budget + 1).split(separator: "/").map(String.init)
                }
            }
            return parts.isEmpty ? "." : parts.joined(separator: "/")
        }
        for node in nodes where node.kind == 3 { _ = try resolve(node.path) }
        var hasher = SHA256()
        func field(_ data: Data) { var length = UInt64(data.count).bigEndian; hasher.update(data: withUnsafeBytes(of: &length) { Data($0) }); hasher.update(data: data) }
        field(Data("Spinnet sealed native tree v1".utf8))
        for node in nodes.sorted(by: { $0.path < $1.path }) {
            try check(); field(Data(node.path.utf8)); field(Data([node.kind])); var mode = node.mode.bigEndian, size = node.size.bigEndian
            field(withUnsafeBytes(of: &mode) { Data($0) }); field(withUnsafeBytes(of: &size) { Data($0) }); field(Data(node.content.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class DecoderProcess {
        private var pid: pid_t = 0
        private var output: Int32 = -1, diagnostic: Int32 = -1
        private var eof = false, reaped = false, exitStatus: Int32 = 0, diagnosticBytes = 0
        private let check: () throws -> Void
        init(configuration: DecoderConfiguration, source: Int32, check: @escaping () throws -> Void) throws {
            self.check = check
            var out = [Int32](repeating: -1, count: 2), err = [Int32](repeating: -1, count: 2)
            guard pipe(&out) == 0 else { throw PluginHostServiceError.tool(.failed) }
            guard pipe(&err) == 0 else { close(out[0]); close(out[1]); throw PluginHostServiceError.tool(.failed) }
            defer { close(out[1]); close(err[1]) }
            output = out[0]; diagnostic = err[0]
            let null = open("/dev/null", O_RDONLY | O_CLOEXEC); guard null >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(null) }
            var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attr) == 0 else { throw PluginHostServiceError.tool(.failed) }
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
            var empty = sigset_t(), defaults = sigset_t(); sigemptyset(&empty); sigemptyset(&defaults)
            for signal in [SIGINT, SIGTERM, SIGPIPE, SIGALRM] { sigaddset(&defaults, signal) }
            guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
                  posix_spawnattr_setpgroup(&attr, 0) == 0, posix_spawnattr_setsigmask(&attr, &empty) == 0, posix_spawnattr_setsigdefault(&attr, &defaults) == 0,
                  posix_spawn_file_actions_adddup2(&actions, null, 0) == 0, posix_spawn_file_actions_adddup2(&actions, out[1], 1) == 0,
                  posix_spawn_file_actions_adddup2(&actions, err[1], 2) == 0, posix_spawn_file_actions_adddup2(&actions, source, 3) == 0, posix_spawn_file_actions_addinherit_np(&actions, 3) == 0 else { throw PluginHostServiceError.tool(.failed) }
            let args = [configuration.bootstrap.path, String(configuration.uid), String(configuration.gid)].map { (value: String) in value.withCString { strdup($0) } }
            let env = ["LANG=C", "LC_ALL=C"].map { (value: String) in value.withCString { strdup($0) } }
            defer { args.forEach { free($0) }; env.forEach { free($0) } }
            var argv = args + [nil], envp = env + [nil]
            let status = argv.withUnsafeMutableBufferPointer { a in envp.withUnsafeMutableBufferPointer { e in posix_spawn(&pid, configuration.bootstrap.path, &actions, &attr, a.baseAddress!, e.baseAddress!) } }
            guard status == 0 else { throw PluginHostServiceError.tool(.failed) }
            guard fcntl(output, F_SETFL, O_NONBLOCK) == 0, fcntl(diagnostic, F_SETFL, O_NONBLOCK) == 0 else { finish(); throw PluginHostServiceError.tool(.failed) }
        }
        deinit { finish() }
        func finish() {
            if pid > 0 && !reaped { kill(-pid, SIGKILL); while waitpid(pid, &exitStatus, 0) < 0 && errno == EINTR {}; reaped = true }
            if output >= 0 { close(output); output = -1 }; if diagnostic >= 0 { close(diagnostic); diagnostic = -1 }
        }
        private func supervise() throws {
            try check()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(diagnostic, &bytes, bytes.count)
                if count > 0 { diagnosticBytes += count; guard diagnosticBytes <= 32768 else { throw PluginHostServiceError.tool(.outputTooLarge) }; continue }
                if count < 0 && errno != EAGAIN && errno != EINTR { throw PluginHostServiceError.tool(.failed) }; break
            }
            if !reaped { let value = waitpid(pid, &exitStatus, WNOHANG); if value == pid { reaped = true }; if value < 0 && errno != EINTR { throw PluginHostServiceError.tool(.failed) } }
            if reaped && exitStatus != 0 { throw PluginHostServiceError.tool(.failed) }
        }
        func readExactly(_ size: Int) throws -> Data {
            guard size <= 65536 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            var data = Data(), bytes = [UInt8](repeating: 0, count: max(size, 1))
            while data.count < size {
                try supervise()
                let count = Darwin.read(output, &bytes, size - data.count)
                if count > 0 { data.append(contentsOf: bytes.prefix(count)); continue }
                if count == 0 { eof = true; throw PluginHostServiceError.tool(.failed) }
                guard errno == EAGAIN || errno == EINTR else { throw PluginHostServiceError.tool(.failed) }
                var fd = pollfd(fd: output, events: Int16(POLLIN | POLLHUP), revents: 0); _ = poll(&fd, 1, 25)
            }
            return data
        }
        func requireSuccess() throws {
            var byte: UInt8 = 0
            while !eof || !reaped {
                try supervise()
                if !eof {
                    let count = Darwin.read(output, &byte, 1)
                    guard count <= 0 else { throw PluginHostServiceError.tool(.failed) }
                    if count == 0 { eof = true } else if errno != EAGAIN && errno != EINTR { throw PluginHostServiceError.tool(.failed) }
                }
                if !eof || !reaped { var fd = pollfd(fd: output, events: Int16(POLLIN | POLLHUP), revents: 0); _ = poll(&fd, 1, 25) }
            }
            guard exitStatus == 0 else { throw PluginHostServiceError.tool(.failed) }
        }
    }
}
