import Foundation
import Darwin

public enum ReviewedToolReads {
    public static let id = "tools.read"
    public static let members: [PluginInterfaceMember] = [.hostService(id)]
    public static let callDeadline: TimeInterval = 3
    public static let sourceDeadline: TimeInterval = 15
    public static let stdoutBytes = 4 * 1024 * 1024
    public static let stderrBytes = 64 * 1024
    public static let resultBytes = 512 * 1024
    public static let maximumPackages = 2000
}

/// Validates the complete typed request before any executable discovery or process launch.
public struct HomebrewReadInput {
    public let operation: String
    public let kind: String?
    public let query: String?
    public let names: [String]
    public let greedy: Bool
    public var kinds: [String] { kind.map { [$0] } ?? ["formula", "cask"] }
    public init(_ input: JSONValue) throws {
        guard case .object(let fields) = input, fields["tool"] == .string("homebrew"),
              case .string(let operation)? = fields["operation"], ["installed", "outdated", "search", "info"].contains(operation) else { throw Self.invalid() }
        self.operation = operation
        if let value = fields["kind"] {
            guard case .string(let kind) = value, ["formula", "cask"].contains(kind) else { throw Self.invalid() }
            self.kind = kind
        } else { kind = nil }
        query = fields["query"].flatMap { if case .string(let text) = $0 { return text }; return nil }
        if case .array(let values)? = fields["names"], values.allSatisfy({ if case .string = $0 { return true }; return false }) {
            names = values.map { if case .string(let text) = $0 { return text }; return "" }
        } else { names = [] }
        if let value = fields["greedy"] { guard case .bool(let flag) = value else { throw Self.invalid() }; greedy = flag } else { greedy = false }
        let allowed: Set<String>
        switch operation {
        case "installed": allowed = ["tool", "operation", "kind"]
        case "outdated": allowed = ["tool", "operation", "kind", "greedy"]
        case "search":
            allowed = ["tool", "operation", "kind", "query"]
            guard let query, Self.validToken(query, search: true) else { throw Self.invalid() }
        default:
            allowed = ["tool", "operation", "kind", "names"]
            guard kind != nil, (1...50).contains(names.count), Set(names).count == names.count, names.allSatisfy({ Self.validToken($0) }) else { throw Self.invalid() }
        }
        guard Set(fields.keys).isSubset(of: allowed) else { throw Self.invalid() }
    }
    static func invalid() -> PluginHostServiceError { .invalidInput("tools.read contains unsupported members, names or kinds") }
    static func validToken(_ text: String, search: Bool = false) -> Bool {
        guard ((search ? 2 : 1)...64).contains(text.count) else { return false }
        return text.range(of: search ? "^[a-z0-9+_.@][a-z0-9+_.@-]*$" : "^[a-z0-9][a-z0-9+_.@-]*$", options: .regularExpression) != nil
    }
    public func authorize(in scope: PluginCapabilityScope?) throws {
        guard let tool = scope?.reviewedTools.first(where: { $0.tool == "homebrew" }),
              tool.operations.contains(operation), kinds.allSatisfy(tool.kinds.contains) else {
            throw PluginHostServiceError.capabilityDenied(.readReviewedTools)
        }
    }
    public func arguments(kind: String? = nil) -> [String] {
        let flag = (kind ?? self.kind).map { ["--" + $0] } ?? []
        switch operation {
        case "installed": return ["info", "--json=v2", "--installed"] + flag
        case "outdated": return ["outdated", "--json=v2"] + flag + (greedy ? ["--greedy"] : [])
        case "search": return ["search"] + flag + ["--", query!]
        default: return ["info", "--json=v2"] + flag + ["--"] + names
        }
    }
}
public struct HomebrewReadOutput {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public init(status: Int32, stdout: Data, stderr: Data = Data()) { self.status = status; self.stdout = stdout; self.stderr = stderr }
}
private final class HomebrewReadAdmission {
    static let shared = HomebrewReadAdmission()
    let condition = NSCondition()
    var owners = Set<PluginID>()
    func take(_ owner: PluginID, until deadline: Date) throws {
        condition.lock(); defer { condition.unlock() }
        while owners.contains(owner) || owners.count >= 2 {
            guard condition.wait(until: deadline) else { throw PluginHostServiceError.tool(.timedOut) }
        }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        owners.insert(owner)
    }
    func release(_ owner: PluginID) { condition.lock(); owners.remove(owner); condition.broadcast(); condition.unlock() }
}
public final class HomebrewReadProfile {
    public typealias Executor = (URL, [String], [String: String], Date) throws -> HomebrewReadOutput
    private let executable: () throws -> URL
    private let execute: Executor
    public init(executable: @escaping () throws -> URL = HomebrewReadProfile.discover, execute: @escaping Executor = HomebrewReadProfile.execute) {
        self.executable = executable; self.execute = execute
    }
    public static func discover() throws -> URL {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            let url = URL(fileURLWithPath: path), resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let prefix = url.deletingLastPathComponent().deletingLastPathComponent().path + "/"
            var link = stat(), info = stat()
            guard lstat(path, &link) == 0, resolved.path.hasPrefix(prefix), stat(resolved.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() || info.st_uid == 0,
                  info.st_mode & 0o022 == 0, access(resolved.path, X_OK) == 0 else { continue }
            if link.st_mode & S_IFMT == S_IFLNK {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { continue }
                let first = target.hasPrefix("/") ? target : url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
                var targetInfo = stat()
                guard lstat(first, &targetInfo) == 0, targetInfo.st_mode & S_IFMT != S_IFLNK else { continue }
            }
            return resolved
        }
        throw PluginHostServiceError.tool(.missing)
    }
    public static var environment: [String: String] {
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "LOGNAME": NSUserName(), "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8", "NONINTERACTIVE": "1"]
        for key in ["NO_AUTO_UPDATE", "NO_ANALYTICS", "NO_ENV_HINTS", "NO_COLOR", "NO_EMOJI", "NO_GITHUB_API", "NO_SUDO", "NO_INSECURE_REDIRECT"] { result["HOMEBREW_" + key] = "1" }
        return result
    }
    public func read(_ input: JSONValue, owner: PluginID, timeout: TimeInterval = ReviewedToolReads.callDeadline, stillAuthorized: () throws -> Void = {}) throws -> JSONValue {
        let request = try HomebrewReadInput(input), deadline = Date().addingTimeInterval(min(timeout, ReviewedToolReads.sourceDeadline))
        try stillAuthorized(); try HomebrewReadAdmission.shared.take(owner, until: deadline)
        defer { HomebrewReadAdmission.shared.release(owner) }
        try stillAuthorized()
        let executable = try executable()
        var packages: [JSONValue] = [], notFound: [String] = []
        var runs: [(String?, [String])] = request.operation == "search" ? request.kinds.map { ($0, []) } : [(request.kind, request.names)]
        while !runs.isEmpty {
            let (kind, names) = runs.removeFirst()
            try stillAuthorized()
            let arguments = request.operation == "info" ? ["info", "--json=v2", "--" + kind!, "--"] + names : request.arguments(kind: kind)
            let output = try execute(executable, arguments, Self.environment, deadline)
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            try stillAuthorized()
            guard output.stdout.count <= ReviewedToolReads.stdoutBytes, output.stderr.count <= ReviewedToolReads.stderrBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            guard output.status == 0 || (output.status == 1 && ["search", "info"].contains(request.operation)) else { throw PluginHostServiceError.tool(.failed) }
            if request.operation == "search" {
                if output.status == 1 {
                    let diagnostic = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard output.stdout.isEmpty, diagnostic == "Error: No formulae or casks found for \"\(request.query!)\"." else { throw PluginHostServiceError.tool(.failed) }
                    continue
                }
                for line in String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace) where Self.validReturnedName(String(line)) {
                    packages.append(.object(["kind": .string(kind!), "name": .string(Self.clean(String(line)))]))
                }
            } else {
                guard let raw = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
                    if request.operation == "info", output.status == 1, output.stdout.isEmpty {
                        let diagnostic = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        let missing = names.filter {
                            diagnostic == "Error: No available formula with the name \"\($0)\"."
                                || diagnostic == "Error: Cask '\($0)' is unavailable: No Cask with this name exists."
                        }
                        guard !missing.isEmpty else { throw PluginHostServiceError.tool(.failed) }
                        notFound += missing
                        let remaining = names.filter { !missing.contains($0) }
                        if !remaining.isEmpty { runs.append((kind, remaining)) }
                        continue
                    }
                    throw PluginHostServiceError.tool(.failed)
                }
                for (key, packageKind) in [("formulae", "formula"), ("casks", "cask")] {
                    guard let records = raw[key] as? [[String: Any]] else { continue }
                    if let chosen = request.kind, chosen != packageKind { continue }
                    for record in records { if let projected = Self.project(record, kind: packageKind, outdated: request.operation == "outdated") { packages.append(projected) } }
                }
                if request.operation == "info" {
                    let found = packages.compactMap { value -> String? in
                        guard case .object(let record) = value, case .string(let name)? = record["name"] else { return nil }
                        return name.split(separator: "/").last.map(String.init)
                    }
                    notFound += names.filter { !found.contains($0) }
                }
            }
        }
        var result: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string(request.operation)]
        if !notFound.isEmpty { result["not_found"] = .array(notFound.map(JSONValue.string)) }
        var truncated = packages.count > ReviewedToolReads.maximumPackages
        // Account for the envelope and potential truncation flag once, then
        // encode each record once. Large lists must not turn projection into
        // quadratic work inside the same three-second call deadline.
        result["packages"] = .array([]); result["truncated"] = .bool(true)
        var bytes = try JSONEncoder().encode(JSONValue.object(result)).count
        var bounded: [JSONValue] = []
        for package in packages.prefix(ReviewedToolReads.maximumPackages) {
            let extra = try JSONEncoder().encode(package).count + (bounded.isEmpty ? 0 : 1)
            guard bytes + extra <= ReviewedToolReads.resultBytes else { truncated = true; break }
            bytes += extra; bounded.append(package)
        }
        result["packages"] = .array(bounded)
        if !truncated { result.removeValue(forKey: "truncated") }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        try stillAuthorized(); return .object(result)
    }
    private static func validReturnedName(_ name: String) -> Bool { name.range(of: "^([a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*/)?[a-z0-9][a-z0-9+_.@-]*$", options: .regularExpression) != nil && name.count <= 160 }
    private static func clean(_ text: String) -> String { String(String.UnicodeScalarView(text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        .replacingOccurrences(of: "(?i)(bearer\\s+|(?:token|password|secret|api[_-]?key)[=:]\\s*)[^\\s,;]+", with: "$1[redacted]", options: .regularExpression)
        .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(200)) }
    private static func project(_ raw: [String: Any], kind: String, outdated: Bool) -> JSONValue? {
        guard let name = (raw[kind == "formula" ? "full_name" : "full_token"] ?? (raw[kind == "formula" ? "name" : "token"] ?? raw["name"])) as? String, validReturnedName(name) else { return nil }
        var result: [String: JSONValue] = ["kind": .string(kind), "name": .string(name)]
        if outdated { result["outdated"] = .bool(true) }
        func string(_ key: String, _ value: Any?) { if let text = value as? String, !text.isEmpty { result[key] = .string(String(clean(text).prefix(key.contains("version") ? 80 : 200))) } }
        if let tap = raw["tap"] as? String, tap.count <= 96, tap.range(of: "^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$", options: .regularExpression) != nil { string("tap", tap) }
        if let tap = raw["tap"] as? String, tap == (kind == "formula" ? "homebrew/core" : "homebrew/cask") { result["official"] = .bool(true) }
        string("title", (raw["name"] as? [String])?.first); string("description", raw["desc"])
        string("version", kind == "formula" ? (raw["versions"] as? [String: Any])?["stable"] : raw["version"])
        if kind == "formula" { string("installed_version", (raw["installed"] as? [[String: Any]])?.first?["version"]) }
        else { string("installed_version", (raw["installed"] as? [String])?.first ?? raw["installed"] as? String) }
        for key in ["outdated", "pinned", "auto_updates", "deprecated", "disabled"] where raw[key] as? Bool == true { result[key] = .bool(true) }
        string("installed_version", (raw["installed_versions"] as? [String])?.first); string("version", raw["current_version"])
        if let artifacts = raw["artifacts"] as? [[String: Any]] {
            if artifacts.contains(where: { $0["pkg"] != nil || $0["installer"] != nil }) { result["needs_privileges"] = .bool(true) }
            if artifacts.contains(where: { ($0["uninstall"] as? [String: Any])?["quit"] != nil }) { result["quits_app"] = .bool(true) }
        }
        return .object(result)
    }
    /// A separate process group, bounded pipes and no stdin. Stop attempts never undo work.
    public static func execute(_ executable: URL, _ arguments: [String], _ environment: [String: String], _ deadline: Date) throws -> HomebrewReadOutput {
        // Network denial applies to Homebrew and every descendant, including
        // missing/corrupt API-cache fallback and the user's brew.env overrides.
        // Deny package-prefix writes as well: bootstrap cannot install Ruby.
        let sandbox = "(version 1)(allow default)(deny network*)(deny file-write* (subpath \"/opt/homebrew\") (subpath \"/usr/local/Homebrew\") (subpath \"/usr/local/Cellar\") (subpath \"/usr/local/Caskroom\"))"
        let launcher = "/usr/bin/sandbox-exec"
        let sandboxArguments = ["-p", sandbox, executable.path] + arguments
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw PluginHostServiceError.tool(.failed) }
        guard pipe(&err) == 0 else { close(out[0]); close(out[1]); throw PluginHostServiceError.tool(.failed) }
        defer { for fd in out + err where fd >= 0 { close(fd) } }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO); posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        for fd in out + err { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)); posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([launcher] + sandboxArguments).map { strdup($0) } + [nil], env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for item in argv + env { if let item { free(item) } } }
        var pid: pid_t = 0
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        let spawn = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            posix_spawn(&pid, launcher, &actions, &attributes, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
        } }
        guard spawn == 0 else { throw PluginHostServiceError.tool(.failed) }
        close(out[1]); close(err[1]); out[1] = -1; err[1] = -1
        _ = fcntl(out[0], F_SETFL, O_NONBLOCK); _ = fcntl(err[0], F_SETFL, O_NONBLOCK)
        var stdout = Data(), stderr = Data(), status: Int32 = 0, ended = false, open = [true, true]
        defer { kill(-pid, SIGKILL); if !ended { while waitpid(pid, &status, 0) == -1 && errno == EINTR {} } }
        while !ended || open.contains(true) {
            guard Date() < deadline else { kill(-pid, SIGKILL); throw PluginHostServiceError.tool(.timedOut) }
            for (index, fd) in [out[0], err[0]].enumerated() where open[index] {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { if index == 0 { stdout.append(contentsOf: buffer.prefix(count)) } else { stderr.append(contentsOf: buffer.prefix(count)) } }
                else if count == 0 { open[index] = false }
                else if errno != EAGAIN && errno != EINTR { throw PluginHostServiceError.tool(.failed) }
            }
            guard stdout.count <= ReviewedToolReads.stdoutBytes, stderr.count <= ReviewedToolReads.stderrBytes else { kill(-pid, SIGKILL); throw PluginHostServiceError.tool(.outputTooLarge) }
            if !ended { ended = waitpid(pid, &status, WNOHANG) == pid }
            if !ended || open.contains(true) { usleep(2000) }
        }
        return HomebrewReadOutput(status: (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f), stdout: stdout, stderr: stderr)
    }
}
public enum ReviewedToolFailure: String, Codable, Equatable {
    case missing = "tool_missing", timedOut = "tool_timed_out", failed = "tool_failed", outputTooLarge = "output_too_large"
    public var message: String {
        switch self {
        case .missing: return "Homebrew is unavailable at /opt/homebrew/bin/brew or /usr/local/bin/brew. See https://brew.sh for installation information."
        case .timedOut: return "The reviewed Homebrew read exceeded its deadline."
        case .failed: return "Homebrew could not complete the reviewed read."
        case .outputTooLarge: return "Homebrew output exceeded the reviewed read limit."
        }
    }
}

/// A grant revoked during admission/read stays retired even after a regrant.
final class ReviewedToolReadValidity {
    private let lock = NSLock()
    private var revoked = false
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return !revoked }
    func revoke() { lock.lock(); revoked = true; lock.unlock() }
}
