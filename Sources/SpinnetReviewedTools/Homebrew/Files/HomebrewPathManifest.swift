import SpinnetCore
import Foundation
import CryptoKit
import Darwin

/// Concrete data-only delete/rmdir/Zap authority. This never interprets Ruby,
/// invokes a shell, removes files, or asserts exclusive receipt ownership.
public enum HomebrewPathManifest {
    public static let maximumEntries = 20_000
    public static let maximumResponseBytes = 32 * 1024 * 1024
    public enum Kind: String, Codable { case delete, rmdir, zap }
    public enum Operation: String, Codable { case delete, rmdir }
    public struct Directive: Codable, Equatable {
        public let kind: Kind
        public let patterns: [String]
        public init(kind: Kind, patterns: [String]) throws {
            guard (1...128).contains(patterns.count), patterns.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw PluginHostServiceError.tool(.outputTooLarge) }
            self.kind = kind; self.patterns = patterns
        }
    }
    public struct Context: Codable, Equatable {
        public let home: URL
        public let prefix: URL
        public let appDirectory: URL
        public init(home: URL, prefix: URL, appDirectory: URL) throws {
            guard [home, prefix, appDirectory].allSatisfy(Self.validURL) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            guard !HomebrewPathProtection.protectedSystemSubtrees.contains(where: { within(home.path, $0) || within(prefix.path, $0) || within(appDirectory.path, $0) }) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            self.home = home; self.prefix = prefix; self.appDirectory = appDirectory
        }
        private static func validURL(_ value: URL) -> Bool {
            guard value.isFileURL, value.host == nil, value.query == nil, value.fragment == nil else { return false }
            return validPath(value.path) && value.path != "/"
        }
        private enum CodingKeys: String, CodingKey { case home, prefix, appDirectory }
        public init(from decoder: Decoder) throws {
            let value = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(home: value.decode(URL.self, forKey: .home), prefix: value.decode(URL.self, forKey: .prefix), appDirectory: value.decode(URL.self, forKey: .appDirectory))
        }
    }
    public struct FrozenPath: Codable, Equatable {
        public let path: String
        public let snapshot: NativeFileQuarantine.Snapshot
    }
    public struct Entry: Codable, Equatable {
        public let path: String
        public let operation: Operation
        public let snapshot: NativeFileQuarantine.Snapshot
        public let childrenSHA256: String?
    }
    public struct RetainedDirectory: Codable, Equatable {
        public let path: String
        public let snapshot: NativeFileQuarantine.Snapshot
        public let childrenSHA256: String
        public let reason: String
    }
    public struct Manifest: Codable, Equatable {
        public let context: Context
        public let directives: [Directive]
        public let entries: [Entry]
        public let retainedDirectories: [RetainedDirectory]
        public let unmatchedPatterns: [String]
        public let ancestors: [FrozenPath]
        public let topologySHA256: String
        public let sha256: String
        public var concreteCount: Int { entries.count }
        public var regularFileBytes: Int64 { entries.filter { $0.snapshot.mode & UInt32(S_IFMT) == UInt32(S_IFREG) }.reduce(0) { $0 + $1.snapshot.size } }
        public func validateSeal() throws {
            guard entries.count + retainedDirectories.count <= maximumEntries, unmatchedPatterns.count <= 512,
                  ancestors.count <= maximumEntries, HomebrewPrivilegePlan.validDigest(topologySHA256),
                  HomebrewPrivilegePlan.validDigest(sha256), try Self.seal(context: context, directives: directives, entries: entries, retained: retainedDirectories, unmatched: unmatchedPatterns, ancestors: ancestors, topology: topologySHA256) == sha256 else { throw PluginHostServiceError.tool(.planChanged) }
            let policy = Policy(context)
            for entry in entries {
                try policy.admit(entry.path)
                guard validSnapshot(entry.snapshot), entry.childrenSHA256 == nil || HomebrewPrivilegePlan.validDigest(entry.childrenSHA256!), entry.snapshot.directory == (entry.childrenSHA256 != nil) else { throw PluginHostServiceError.tool(.planChanged) }
            }
            for item in retainedDirectories { try policy.admit(item.path); guard item.snapshot.directory, validSnapshot(item.snapshot), HomebrewPrivilegePlan.validDigest(item.childrenSHA256), item.reason == "nonempty" else { throw PluginHostServiceError.tool(.planChanged) } }
        }
        private static func seal(context: Context, directives: [Directive], entries: [Entry], retained: [RetainedDirectory], unmatched: [String], ancestors: [FrozenPath], topology: String) throws -> String {
            struct Body: Encodable {
                let context: Context, directives: [Directive], entries: [Entry], retained: [RetainedDirectory], unmatched: [String], ancestors: [FrozenPath], topology: String
            }
            return try digest(Body(context: context, directives: directives, entries: entries, retained: retained, unmatched: unmatched, ancestors: ancestors, topology: topology))
        }
        fileprivate init(context: Context, directives: [Directive], entries: [Entry], retained: [RetainedDirectory], unmatched: [String], ancestors: [FrozenPath], topology: String) throws {
            self.context = context; self.directives = directives; self.entries = entries; retainedDirectories = retained; unmatchedPatterns = unmatched; self.ancestors = ancestors; topologySHA256 = topology
            sha256 = try Self.seal(context: context, directives: directives, entries: entries, retained: retained, unmatched: unmatched, ancestors: ancestors, topology: topology)
        }
    }
    public struct WorkerConfiguration {
        public let executable: URL
        /// Production supplies the matching fixed binary sealed by
        /// NativeSignedToolStaging. No Plugin-resolvable executable is accepted.
        public init(executable: URL) throws {
            guard executable.isFileURL, executable.lastPathComponent == "SpinnetPathInventory", validPath(executable.path) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            self.executable = executable
        }
    }
    public struct Request: Codable {
        public let version: Int
        public let context: Context
        public let directives: [Directive]
        public let deadline: Date
        public init(context: Context, directives: [Directive], deadline: Date) { version = 1; self.context = context; self.directives = directives; self.deadline = deadline }
    }
    public struct Response: Codable {
        public let version: Int
        public let manifest: Manifest?
        public let failure: ReviewedToolFailure?
        public let unavailable: String?
        public init(manifest: Manifest? = nil, failure: ReviewedToolFailure? = nil, unavailable: String? = nil) { version = 1; self.manifest = manifest; self.failure = failure; self.unavailable = unavailable }
    }
    public static func capture(_ directives: [Directive], context: Context, worker: WorkerConfiguration, deadline: Date, isCancelled: @escaping () -> Bool = { false }) throws -> Manifest {
        let request = Request(context: context, directives: directives, deadline: min(deadline, Date().addingTimeInterval(60)))
        try validateRequest(request)
        let response = try NativePathInventorySupervisor.capture(request, worker: worker, isCancelled: isCancelled)
        guard response.version == 1, [response.manifest != nil, response.failure != nil, response.unavailable != nil].filter({ $0 }).count == 1 else { throw PluginHostServiceError.tool(.failed) }
        if let failure = response.failure { throw PluginHostServiceError.tool(failure) }
        if let message = response.unavailable { guard message.utf8.count <= 1024 else { throw PluginHostServiceError.tool(.failed) }; throw PluginHostServiceError.unavailable(message) }
        guard let manifest = response.manifest, manifest.context == context, manifest.directives == directives else { throw PluginHostServiceError.tool(.failed) }
        try manifest.validateSeal()
        return manifest
    }
    /// Fixed read-only executable entry point. Blocking syscalls stay in the
    /// supervised worker, never the Host's capture/confirmation thread.
    public static func inventoryInWorker(_ request: Request) throws -> Manifest {
        try validateRequest(request)
        return try Inventory(request).run()
    }
    private static func validateRequest(_ request: Request) throws {
        guard request.version == 1, (1...64).contains(request.directives.count), request.directives.reduce(0, { $0 + $1.patterns.count }) <= 128 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        for item in request.directives { _ = try Directive(kind: item.kind, patterns: item.patterns) }
        guard Date() < request.deadline, request.deadline.timeIntervalSinceNow <= 60 else { throw PluginHostServiceError.tool(.timedOut) }
    }
    private static func validSnapshot(_ value: NativeFileQuarantine.Snapshot) -> Bool {
        let kind = value.mode & UInt32(S_IFMT)
        return value.inode > 0 && [UInt32(S_IFDIR), UInt32(S_IFREG), UInt32(S_IFLNK)].contains(kind) && (value.directory || value.links == 1) && (value.directory || HomebrewPrivilegePlan.validDigest(value.sha256)) && value.size >= 0 && value.size <= 8 * 1024 * 1024 * 1024
    }
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.hasPrefix("/") && path.utf8.count <= 2048 && parts.count <= 65 && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && !parts.dropFirst().contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    }
    private static func within(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    private struct Policy {
        let context: Context
        let essential: Set<String>
        let credentialRoots: [String]
        init(_ context: Context) {
            self.context = context
            let system = HomebrewPathProtection.system
            let user = HomebrewPathProtection.user.map { value in value == "~/" ? context.home.path : context.home.path + String(value.dropFirst()) }
            let prefix = ["", "/bin", "/sbin", "/etc", "/include", "/lib", "/libexec", "/opt", "/share", "/var", "/Frameworks", "/Cellar", "/Caskroom", "/Library"].map { context.prefix.path + $0 }
            essential = Set((system + user + prefix + [context.home.path, context.appDirectory.path, "/usr/local", "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/share", "/usr/local/etc", "/usr/local/include", "/usr/local/opt", "/usr/local/var"]).map(HomebrewPathProtection.ascii))
            credentialRoots = HomebrewPathProtection.credentials.map { context.home.path + "/" + $0 } + HomebrewPathProtection.protectedSystemSubtrees + [context.prefix.path + "/Library/Homebrew"]
        }
        func admit(_ path: String) throws {
            guard validPath(path), !essential.contains(HomebrewPathProtection.ascii(path)),
                  !credentialRoots.contains(where: { within(HomebrewPathProtection.ascii(path), HomebrewPathProtection.ascii($0)) }),
                  [context.home.path, context.prefix.path, context.appDirectory.path, "/Library", "/usr/local"].contains(where: { path != $0 && within(path, $0) }) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        }
        func expand(_ source: String) throws -> String {
            var path = source
            if path.hasPrefix("~/") { path = context.home.path + path.dropFirst() }
            path = path.replacingOccurrences(of: "/$HOME", with: context.home.path).replacingOccurrences(of: "$HOMEBREW_PREFIX", with: context.prefix.path).replacingOccurrences(of: "$HOMEBREW_CELLAR", with: context.prefix.appendingPathComponent("Cellar").path).replacingOccurrences(of: "$APPDIR", with: context.appDirectory.path)
            guard !path.contains("$"), validPath(path), !path.contains("\\") else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            // Wildcards can select named descendants, never an unrestricted
            // system namespace. Concrete matches are independently admitted.
            let base = path.split(separator: "/").prefix { !$0.contains(where: { "*?[{".contains($0) }) }.joined(separator: "/")
            let literalBase = "/" + base
            guard [context.home.path, context.prefix.path, context.appDirectory.path, "/Library", "/usr/local"].contains(where: { within(literalBase, $0) || within(path, $0) }) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            return path
        }
    }
    private struct Child: Encodable, Equatable {
        let name: String, identity: String, mode: UInt32, flags: UInt32, size: Int64
        let seconds: Int64, nanoseconds: Int64
    }
    private final class Inventory {
        let request: Request, policy: Policy, expires: TimeInterval
        var mounts: NativeReceiptTopology.Mounts?
        var entries: [String: Entry] = [:], retained: [String: RetainedDirectory] = [:], ancestors: [String: FrozenPath] = [:]
        var nativeNames: [String: String] = [:], protectedIdentities = Set<String>(), credentialIdentities = Set<String>()
        var unmatched = Set<String>(), visited = 0, bytes: Int64 = 0
        init(_ request: Request) { self.request = request; policy = Policy(request.context); expires = ProcessInfo.processInfo.systemUptime + max(0, request.deadline.timeIntervalSinceNow) }
        func check() throws { guard ProcessInfo.processInfo.systemUptime < expires else { throw PluginHostServiceError.tool(.timedOut) } }
        func step() throws { try check(); visited += 1; guard visited <= 100_000 else { throw PluginHostServiceError.tool(.outputTooLarge) } }
        func run() throws -> Manifest {
            mounts = try NativeReceiptTopology.capture(deadline: request.deadline)
            try freezeProtectedIdentities()
            for directive in request.directives {
                for pattern in directive.patterns {
                    for expanded in try braces(policy.expand(pattern)) {
                        let paths = try glob(expanded)
                        if paths.isEmpty { try policy.admit(expanded); unmatched.insert(expanded) }
                        for path in paths { try collect(path, operation: directive.kind == .rmdir ? .rmdir : .delete, depth: 0) }
                    }
                }
            }
            for parent in ancestors.values { guard try NativePathParentSnapshot.capture(parent.path, deadline: request.deadline) == parent.snapshot else { throw PluginHostServiceError.tool(.planChanged) } }
            let finalMounts = try NativeReceiptTopology.capture(deadline: request.deadline)
            guard finalMounts.fingerprint == mounts?.fingerprint else { throw PluginHostServiceError.tool(.planChanged) }
            let ordered = entries.values.sorted { a, b in let left = a.path.split(separator: "/").count, right = b.path.split(separator: "/").count; return left == right ? a.path.utf8.lexicographicallyPrecedes(b.path.utf8) : left > right }
            let result = try Manifest(context: request.context, directives: request.directives, entries: ordered, retained: retained.values.sorted { $0.path < $1.path }, unmatched: unmatched.sorted(), ancestors: ancestors.values.sorted { $0.path < $1.path }, topology: finalMounts.fingerprint)
            try result.validateSeal(); return result
        }
        func freezeProtectedIdentities() throws {
            var paths = HomebrewPathProtection.system + HomebrewPathProtection.user.map { $0 == "~/" ? request.context.home.path : request.context.home.path + String($0.dropFirst()) } + policy.credentialRoots
            paths += [request.context.home.path, request.context.prefix.path, request.context.appDirectory.path]
            for path in paths {
                try step(); var status = stat()
                if lstat(path, &status) == 0 {
                    let key = NativeReceiptTopology.key(status)
                    protectedIdentities.insert(key)
                    if policy.credentialRoots.contains(path) { credentialIdentities.insert(key) }
                }
                else if errno != ENOENT && errno != ENOTDIR { throw PluginHostServiceError.unavailable("Protected native directory identity is unavailable") }
            }
        }
        func status(_ path: String) throws -> stat? {
            try step()
            guard validPath(path) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            if !(try NativeFileQuarantine.existsWithoutFollowing(URL(fileURLWithPath: path))) { return nil }
            let (parent, name) = try NativeFileQuarantine.openParent(URL(fileURLWithPath: path)); defer { close(parent) }
            var status = stat()
            guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw PluginHostServiceError.unavailable("Native cleanup identity is unavailable; filesystem/privacy permission may be required") }
            return status
        }
        func freezeParents(_ path: String) throws {
            var physical = path
            // Match the quarantine boundary's fixed macOS /var and /tmp
            // aliases. Arbitrary symlink ancestors still refuse.
            if physical.hasPrefix("/var/") || physical.hasPrefix("/tmp/") { physical = "/private" + physical }
            let components = physical.split(separator: "/").map(String.init)
            var parent = ""
            for part in components.dropLast() {
                parent += "/" + part
                let captured = try NativePathParentSnapshot.capture(parent, deadline: request.deadline)
                guard captured.directory else { throw PluginHostServiceError.tool(.planChanged) }
                let key = String(captured.device) + ":" + String(captured.inode) + ":" + String(captured.mode & UInt32(S_IFMT)) + ":0"
                guard !credentialIdentities.contains(key) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                if let known = ancestors[parent] { guard known.snapshot == captured else { throw PluginHostServiceError.tool(.planChanged) } }
                else { ancestors[parent] = .init(path: parent, snapshot: captured) }
                guard ancestors.count <= maximumEntries else { throw PluginHostServiceError.tool(.outputTooLarge) }
            }
        }
        func collect(_ path: String, operation: Operation, depth: Int) throws {
            try check(); try policy.admit(path)
            guard depth <= 64, let initial = try status(path), let mounts else { throw PluginHostServiceError.tool(.planChanged) }
            guard initial.st_flags & UInt32(SF_RESTRICTED) == 0 else { throw PluginHostServiceError.unavailable("SIP-protected cleanup targets are unsupported") }
            let key = NativeReceiptTopology.key(initial)
            guard !protectedIdentities.contains(key) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            if let old = nativeNames[key], Data(old.utf8) != Data(path.utf8) { throw PluginHostServiceError.unavailable("Duplicate native cleanup aliases require one concrete path") }
            nativeNames[key] = path
            if let old = entries[path] { guard old.operation == operation || (old.operation == .delete && operation == .rmdir) else { throw PluginHostServiceError.tool(.planChanged) }; return }
            if retained[path] != nil { guard operation == .rmdir else { throw PluginHostServiceError.tool(.planChanged) }; return }
            try freezeParents(path)
            try NativeReceiptTopology.prove(path, status: initial, mounts: mounts)
            let captured = try NativeFileQuarantine.capture(URL(fileURLWithPath: path), deadline: request.deadline)
            guard captured.device == UInt64(initial.st_dev), captured.inode == UInt64(initial.st_ino) else { throw PluginHostServiceError.tool(.planChanged) }
            if !captured.directory {
                guard operation == .delete else { throw PluginHostServiceError.unavailable("rmdir cannot delete files or symbolic links") }
                bytes += captured.size; guard bytes <= 8 * 1024 * 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                entries[path] = .init(path: path, operation: operation, snapshot: captured, childrenSHA256: nil)
            } else {
                let children = try list(path)
                var nonempty = false
                for child in children {
                    let target = path + "/" + child.name
                    if operation == .delete { try collect(target, operation: .delete, depth: depth + 1) }
                    else if child.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) { try collect(target, operation: .rmdir, depth: depth + 1); if retained[target] != nil { nonempty = true } }
                    else if entries[target]?.operation != .delete { nonempty = true }
                }
                guard try list(path) == children, try NativeFileQuarantine.capture(URL(fileURLWithPath: path), deadline: request.deadline) == captured else { throw PluginHostServiceError.tool(.planChanged) }
                let childHash = try digest(children)
                if nonempty { retained[path] = .init(path: path, snapshot: captured, childrenSHA256: childHash, reason: "nonempty") }
                else { entries[path] = .init(path: path, operation: operation, snapshot: captured, childrenSHA256: childHash) }
            }
            guard entries.count + retained.count <= maximumEntries else { throw PluginHostServiceError.tool(.outputTooLarge) }
        }
        func list(_ path: String) throws -> [Child] {
            try check()
            let (parent, name) = try NativeFileQuarantine.openParent(URL(fileURLWithPath: path)); defer { close(parent) }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0, let directory = fdopendir(fd) else { if fd >= 0 { close(fd) }; throw PluginHostServiceError.unavailable("Native cleanup directory enumeration is unavailable") }
            defer { closedir(directory) }
            var values: [Child] = []
            while true {
                try step(); errno = 0
                guard let row = readdir(directory) else { guard errno == 0 else { throw PluginHostServiceError.tool(.planChanged) }; break }
                let name = withUnsafePointer(to: &row.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(row.pointee.d_namlen) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                guard !name.contains("/"), !name.isEmpty, name.utf8.count <= 255, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                var status = stat()
                guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
                values.append(Child(name: name, identity: NativeReceiptTopology.key(status), mode: UInt32(status.st_mode), flags: status.st_flags, size: Int64(status.st_size), seconds: Int64(status.st_mtimespec.tv_sec), nanoseconds: Int64(status.st_mtimespec.tv_nsec)))
                guard values.count <= maximumEntries else { throw PluginHostServiceError.tool(.outputTooLarge) }
            }
            return values.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        }
        func glob(_ pattern: String) throws -> [String] {
            let components = pattern.split(separator: "/").map(String.init)
            var results = Set<String>()
            func walk(_ parent: String, _ index: Int, _ depth: Int) throws {
                try check(); guard depth <= 64 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                if index > 0, let value = try status(parent), credentialIdentities.contains(NativeReceiptTopology.key(value)) { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                if index == components.count { if !(try status(parent) == nil) { results.insert(parent) }; return }
                let component = components[index]
                if component == "**" {
                    try walk(parent, index + 1, depth)
                    guard let value = try status(parent), value.st_mode & S_IFMT == S_IFDIR else { return }
                    for child in try list(parent) where child.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) { try walk(parent + "/" + child.name, index, depth + 1) }
                } else if component.contains(where: { "*?[".contains($0) }) {
                    guard let value = try status(parent), value.st_mode & S_IFMT == S_IFDIR else { return }
                    for child in try list(parent) where fnmatch(component, child.name, FNM_PERIOD) == 0 { try walk(parent + "/" + child.name, index + 1, depth + 1) }
                } else {
                    let next = parent == "/" ? "/" + component : parent + "/" + component
                    if try status(next) != nil { try walk(next, index + 1, depth + 1) }
                }
                guard results.count <= maximumEntries else { throw PluginHostServiceError.tool(.outputTooLarge) }
            }
            try walk("/", 0, 0)
            return results.sorted()
        }
        func braces(_ pattern: String) throws -> [String] {
            guard let opening = pattern.firstIndex(of: "{") else { guard !pattern.contains("}") else { throw PluginHostServiceError.tool(.sourceNotAllowed) }; return [pattern] }
            var nesting = 0, closing: String.Index?, separators: [String.Index] = []
            for index in pattern.indices where index >= opening {
                if pattern[index] == "{" { nesting += 1 }
                else if pattern[index] == "}" { nesting -= 1; if nesting == 0 { closing = index; break } }
                else if pattern[index] == ",", nesting == 1 { separators.append(index) }
            }
            guard let closing, !separators.isEmpty else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            var starts = [pattern.index(after: opening)] + separators.map { pattern.index(after: $0) }
            let ends = separators + [closing]
            var expanded: [String] = []
            for end in ends {
                let start = starts.removeFirst(); guard start < end else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                let candidate = String(pattern[..<opening]) + pattern[start..<end] + pattern[pattern.index(after: closing)...]
                expanded += try braces(candidate)
                guard expanded.count <= 256 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            }
            return expanded
        }
    }
}
