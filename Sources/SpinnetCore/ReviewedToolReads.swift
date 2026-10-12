import Foundation
import Darwin

public enum ReviewedToolReads {
    public static let id = "tools.read"
    public static let members: [PluginInterfaceMember] = [.hostService(id), .source(id)]
    public static let callDeadline: TimeInterval = 3
    public static let sourceDeadline: TimeInterval = 15
    public static let stdoutBytes = 4 * 1024 * 1024
    public static let stderrBytes = 64 * 1024
    public static let resultBytes = 512 * 1024
    public static let maximumPackages = 2000
    public static let maximumConcurrentReadsPerPlugin = 1
    public static let maximumConcurrentReads = 2
}

/// Validates the complete typed request before any executable discovery or process launch.
public struct HomebrewReadInput {
    public static let operations = ["installed", "outdated", "search", "info"] + HomebrewManagementReads.operations
    public let rawInput: JSONValue
    public let operation: String
    public let kind: String?
    public let query: String?
    public let names: [String]
    public let greedy: Bool
    public var kinds: [String] {
        if ["version", "taps", "doctor"].contains(operation) { return [] }
        if ["adoptionCandidates", "adoptionPreview"].contains(operation) { return ["cask"] }
        if ["services", "vulnerabilities", "vulnerabilityDetail"].contains(operation) { return ["formula"] }
        return kind.map { [$0] } ?? ["formula", "cask"]
    }
    public init(_ input: JSONValue) throws {
        rawInput = input
        guard case .object(let fields) = input, fields["tool"] == .string("homebrew"),
              case .string(let operation)? = fields["operation"], Self.operations.contains(operation) else { throw Self.invalid() }
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
        if HomebrewManagementReads.operations.contains(operation) {
            try HomebrewManagementReads.validate(input)
            return
        }
        let allowed: Set<String>
        switch operation {
        case "installed": allowed = ["tool", "operation", "kind"]
        case "outdated": allowed = ["tool", "operation", "kind", "greedy"]
        case "search":
            allowed = ["tool", "operation", "kind", "query"]
            guard let query, Self.validToken(query, search: true) else { throw Self.invalid() }
        default:
            allowed = ["tool", "operation", "kind", "names"]
            guard kind != nil, (1...50).contains(names.count), Set(names).count == names.count, names.allSatisfy({ Self.validPackageName($0) }) else { throw Self.invalid() }
        }
        guard Set(fields.keys).isSubset(of: allowed) else { throw Self.invalid() }
    }
    static func invalid() -> PluginHostServiceError { .invalidInput("tools.read contains unsupported members, names or kinds") }
    public static func validPackageName(_ text: String) -> Bool {
        text.count <= 160 && text.range(of: "^([a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*/)?[a-z0-9][a-z0-9+_.@-]*$", options: .regularExpression) != nil
    }
    static func validToken(_ text: String, search: Bool = false) -> Bool {
        guard ((search ? 2 : 1)...64).contains(text.count) else { return false }
        return text.range(of: search ? "^[a-z0-9+_.@][a-z0-9+_.@-]*$" : "^[a-z0-9][a-z0-9+_.@-]*$", options: .regularExpression) != nil
    }
    public func authorize(in scope: PluginCapabilityScope?) throws {
        guard let tool = scope?.reviewedTools.first(where: { $0.tool == "homebrew" }),
              tool.operations.contains(operation), kinds.allSatisfy(tool.kinds.contains) else {
            throw PluginHostServiceError.capabilityScopeDenied(.readReviewedTools)
        }
    }
    public func arguments(kind: String? = nil, names: [String]? = nil) -> [String] {
        let flag = (kind ?? self.kind).map { ["--" + $0] } ?? []
        switch operation {
        case "installed": return ["info", "--json=v2", "--installed"] + flag
        case "outdated": return ["outdated", "--json=v2"] + flag + (greedy ? ["--greedy"] : [])
        case "search": return ["search"] + flag + ["--", query!]
        default: return ["info", "--json=v2"] + flag + ["--"] + (names ?? self.names)
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
    func take(_ owner: PluginID, until deadline: Date, cancellation: HostFetchedSections.Cancellation) throws {
        condition.lock(); defer { condition.unlock() }
        while owners.filter({ $0 == owner }).count >= ReviewedToolReads.maximumConcurrentReadsPerPlugin
            || owners.count >= ReviewedToolReads.maximumConcurrentReads {
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
        guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        owners.insert(owner)
    }
    func release(_ owner: PluginID) { condition.lock(); owners.remove(owner); condition.broadcast(); condition.unlock() }
}
public final class HomebrewReadProfile {
    public typealias Executor = (URL, [String], [String: String], Date) throws -> HomebrewReadOutput
    public typealias CancellableExecutor = (URL, [String], [String: String], Date, HostFetchedSections.Cancellation) throws -> HomebrewReadOutput
    private let executable: () throws -> URL
    private let execute: CancellableExecutor
    private let management: HomebrewManagementReads
    public init(executable: @escaping () throws -> URL = HomebrewReadProfile.discover, execute: Executor? = nil, management: HomebrewManagementReads = HomebrewManagementReads()) {
        self.executable = executable
        self.management = management
        self.execute = execute.map { operation in { executable, arguments, environment, deadline, _ in try operation(executable, arguments, environment, deadline) } } ?? Self.executeCancellable
    }
    public init(executable: @escaping () throws -> URL, executeCancellable: @escaping CancellableExecutor, management: HomebrewManagementReads = HomebrewManagementReads()) {
        self.executable = executable; self.execute = executeCancellable; self.management = management
    }
    public func invalidateManagementTargets(owner: PluginID) { management.invalidateTargets(owner: owner) }
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
        for key in ["NO_AUTO_UPDATE", "NO_BOOTSNAP", "NO_ANALYTICS", "NO_ENV_HINTS", "NO_COLOR", "NO_EMOJI", "NO_GITHUB_API", "NO_SUDO", "NO_INSECURE_REDIRECT"] { result["HOMEBREW_" + key] = "1" }
        return result
    }
    public func read(_ input: JSONValue, owner: PluginID, timeout: TimeInterval = ReviewedToolReads.callDeadline,
                     cancellation: HostFetchedSections.Cancellation = .init(), stillAuthorized: () throws -> Void = {}) throws -> JSONValue {
        let request = try HomebrewReadInput(input), deadline = Date().addingTimeInterval(min(timeout, ReviewedToolReads.sourceDeadline))
        try stillAuthorized(); try HomebrewReadAdmission.shared.take(owner, until: deadline, cancellation: cancellation)
        defer { HomebrewReadAdmission.shared.release(owner) }
        try stillAuthorized()
        let executable = try executable()
        if HomebrewManagementReads.operations.contains(request.operation) {
            let result = try management.read(request.rawInput, owner: owner, executable: executable, deadline: deadline,
                cancellation: cancellation, execute: execute, stillAuthorized: stillAuthorized)
            guard try JSONEncoder().encode(result).count <= ReviewedToolReads.resultBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            try stillAuthorized(); return result
        }
        var packages: [JSONValue] = [], notFound: [String] = []
        var officialOrigins: [String: Bool] = [:]
        var runs: [(String?, [String])] = request.operation == "search" ? request.kinds.map { ($0, []) } : [(request.kind, request.names)]
        while !runs.isEmpty {
            let (kind, names) = runs.removeFirst()
            try stillAuthorized()
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
            let arguments = request.arguments(kind: kind, names: names)
            let output = try execute(executable, arguments, Self.environment, deadline, cancellation)
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
                var canonicalSelectors = Set<String>()
                for (key, packageKind) in [("formulae", "formula"), ("casks", "cask")] {
                    guard let records = raw[key] as? [[String: Any]] else { continue }
                    if let chosen = request.kind, chosen != packageKind { continue }
                    for var record in records {
                        // Metadata from an official-looking namespace does not
                        // establish where that checkout actually comes from.
                        record.removeValue(forKey: "_spinnet_official_source")
                        if request.operation == "info", let tap = record["tap"] as? String, ["homebrew/core", "homebrew/cask"].contains(tap) {
                            if officialOrigins[tap] == nil {
                                try stillAuthorized()
                                let proof = try execute(executable, ["tap-info", "--json=v1", tap], Self.environment, deadline, cancellation)
                                guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
                                try stillAuthorized()
                                guard proof.stdout.count <= ReviewedToolReads.stdoutBytes, proof.stderr.count <= ReviewedToolReads.stderrBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
                                let rows = try? JSONSerialization.jsonObject(with: proof.stdout) as? [[String: Any]]
                                let expected = "https://github.com/homebrew/homebrew-" + (tap == "homebrew/core" ? "core" : "cask")
                                let allowed = [expected, expected + ".git", expected.replacingOccurrences(of: "https://github.com/", with: "git@github.com:") + ".git", expected.replacingOccurrences(of: "https://", with: "ssh://git@") + ".git"]
                                officialOrigins[tap] = proof.status == 0 && rows?.contains(where: { row in
                                    row["name"] as? String == tap && row["installed"] as? Bool == true && allowed.contains((row["remote"] as? String ?? "").lowercased())
                                }) == true
                            }
                            record["_spinnet_official_source"] = officialOrigins[tap] == true
                        }
                        if let projected = Self.project(record, kind: packageKind, outdated: request.operation == "outdated", prefix: HomebrewManagementReads.prefix(of: executable), includeConfiguration: request.operation == "info") {
                            packages.append(projected)
                            if let tap = record["tap"] as? String {
                                for key in packageKind == "formula" ? ["aliases", "oldnames"] : ["old_tokens"] {
                                    for alias in (record[key] as? [String] ?? []).prefix(2000) where HomebrewReadInput.validPackageName(alias) {
                                        if alias.contains("/") { canonicalSelectors.insert(alias) }
                                        else { canonicalSelectors.insert(alias); canonicalSelectors.insert(tap + "/" + alias) }
                                    }
                                }
                            }
                        }
                    }
                }
                if request.operation == "info" {
                    let found = packages.compactMap { value -> String? in
                        guard case .object(let record) = value, case .string(let name)? = record["name"] else { return nil }
                        return name
                    }
                    notFound += names.filter { requested in
                        !canonicalSelectors.contains(requested) && !found.contains(requested) && !found.contains(where: { returned in
                            // A bare alias or an official tap-qualified name may
                            // be canonicalized by Homebrew; a third-party tap's
                            // qualified identity must match in full.
                            let official = requested.hasPrefix("homebrew/core/") || requested.hasPrefix("homebrew/cask/")
                            return (!requested.contains("/") || official) && returned.split(separator: "/").last == requested.split(separator: "/").last
                        })
                    }
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
    static func project(_ raw: [String: Any], kind: String, outdated: Bool, prefix: URL? = nil, includeConfiguration: Bool = false) -> JSONValue? {
        guard let name = (raw[kind == "formula" ? "full_name" : "full_token"] ?? (raw[kind == "formula" ? "name" : "token"] ?? raw["name"])) as? String, validReturnedName(name) else { return nil }
        var result: [String: JSONValue] = ["kind": .string(kind), "name": .string(name)]
        if outdated { result["outdated"] = .bool(true) }
        func string(_ key: String, _ value: Any?) { if let text = value as? String, !text.isEmpty { result[key] = .string(String(clean(text).prefix(key.contains("version") ? 80 : 200))) } }
        if let tap = raw["tap"] as? String, tap.count <= 96, tap.range(of: "^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$", options: .regularExpression) != nil { string("tap", tap) }
        if raw["_spinnet_official_source"] as? Bool == true { result["official"] = .bool(true) }
        string("title", (raw["name"] as? [String])?.first); string("description", raw["desc"])
        string("version", kind == "formula" ? (raw["versions"] as? [String: Any])?["stable"] : raw["version"])
        if kind == "formula" { string("installed_version", (raw["installed"] as? [[String: Any]])?.first?["version"]) }
        else { string("installed_version", (raw["installed"] as? [String])?.first ?? raw["installed"] as? String) }
        for key in ["outdated", "pinned", "auto_updates", "deprecated", "disabled"] where raw[key] as? Bool == true { result[key] = .bool(true) }
        string("installed_version", (raw["installed_versions"] as? [String])?.first); string("version", raw["current_version"])
        if let artifacts = raw["artifacts"] as? [[String: Any]] {
            if artifacts.contains(where: { $0["pkg"] != nil || $0["installer"] != nil }) { result["needs_privileges"] = .bool(true) }
            let directives = artifacts.flatMap { artifact -> [[String: Any]] in
                if let values = artifact["uninstall"] as? [[String: Any]] { return values }
                if let value = artifact["uninstall"] as? [String: Any] { return [value] }
                return []
            }
            if directives.contains(where: { $0["quit"] != nil }) { result["quits_app"] = .bool(true) }
            if directives.contains(where: { directive in
                ["launchctl", "pkgutil", "kext", "delete"].contains { directive[$0] != nil }
                    || ["script", "early_script"].contains { (directive[$0] as? [String: Any])?["sudo"] as? Bool == true }
            }) { result["uninstall_needs_privileges"] = .bool(true) }
        }
        if kind == "cask", includeConfiguration, result["installed_version"] != nil, let prefix {
            if let installed = try? HomebrewInstalledUninstall.read(name: name, prefix: prefix.path) {
                let installedDirectives = installed.artifacts.flatMap { artifact -> [[String: Any]] in
                    artifact["uninstall"] as? [[String: Any]] ?? (artifact["uninstall"] as? [String: Any]).map { [$0] } ?? []
                }
                if installedDirectives.contains(where: { $0["quit"] != nil }) { result["quits_app"] = .bool(true) }
                if HomebrewInstalledUninstall.requiresPrivileges(installed.artifacts) { result["uninstall_needs_privileges"] = .bool(true) }
                else { result.removeValue(forKey: "uninstall_needs_privileges") }
            } else if let token = name.split(separator: "/").last,
                      FileManager.default.fileExists(atPath: prefix.appendingPathComponent("Caskroom/" + token).path) {
                // Native review will refuse missing/executable/corrupt history
                // before confirmation, rather than allowing an unreviewed sudo.
                result["uninstall_needs_privileges"] = .bool(true)
            }
        }
        if let dependencies = raw["dependencies"] as? [String] {
            result["dependencies"] = .array(dependencies.prefix(128).filter(HomebrewReadInput.validPackageName).map(JSONValue.string))
        }
        for key in ["homepage"] { if let value = raw[key] as? String, let safe = HomebrewManagementReads.safeURL(value) { result[key] = .string(safe) } }
        if let source = (kind == "cask" ? raw["url"] : ((raw["urls"] as? [String: Any])?["stable"] as? [String: Any])?["url"]) as? String,
           let safe = HomebrewManagementReads.safeURL(source) { result["download_url"] = .string(safe) }
        if let installed = raw["installed"] as? [[String: Any]], let first = installed.first {
            if let flag = first["installed_on_request"] as? Bool { result["installed_on_request"] = .bool(flag) }
            if let flag = first["installed_as_dependency"] as? Bool { result["installed_as_dependency"] = .bool(flag) }
        }
        result.merge(HomebrewPackageMetadata.project(raw, kind: kind, name: name, prefix: prefix, includeConfiguration: includeConfiguration)) { _, new in new }
        return .object(result)
    }
    /// A separate process group, bounded pipes and no stdin. Stop attempts never undo work.
    public static func execute(_ executable: URL, _ arguments: [String], _ environment: [String: String], _ deadline: Date) throws -> HomebrewReadOutput {
        try executeCancellable(executable, arguments, environment, deadline, .init())
    }
    public static func executeCancellable(_ executable: URL, _ arguments: [String], _ environment: [String: String], _ deadline: Date,
                                          _ cancellation: HostFetchedSections.Cancellation) throws -> HomebrewReadOutput {
        // Validate the reviewed bootstrap/loader files before brew can preload
        // global and IRB helpers. The guard inside Ruby checks its loader files
        // again; neither check claims to freeze the user-owned live tree.
        if executable.lastPathComponent == "brew" {
            try HomebrewReadSource.validate(executable: executable, deadline: deadline, cancellation: cancellation)
            try HomebrewBootstrapOptions.validate(executable: executable, environment: environment, deadline: deadline, cancellation: cancellation)
        }
        let commands = ["info", "outdated", "search", "list", "tap-info", "services", "doctor", "trust"]
        let isReviewedCommand = commands.contains(arguments.first ?? "")
        let guarded = isReviewedCommand
            ? ["ruby", "--", Bundle.module.url(forResource: "HomebrewRead", withExtension: "rb")!.path] + arguments : arguments
        let output = try executeBounded(executable, guarded, environment, deadline, cancellation, stdoutLimit: ReviewedToolReads.stdoutBytes, readOnly: isReviewedCommand || arguments.first == "ruby" || arguments.first == "--version" || executable.lastPathComponent == "brew")
        if output.status == 77 && String(decoding: output.stderr, as: UTF8.self).contains("__SPINNET_SOURCE_NOT_ALLOWED__") { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        if output.status == 79 && String(decoding: output.stderr, as: UTF8.self).contains("__SPINNET_SOURCE_ADAPTER_UNREVIEWED__") { throw PluginHostServiceError.unavailable("This Homebrew loader source revision needs review before metadata reads") }
        if output.status == 78 && String(decoding: output.stderr, as: UTF8.self).contains("__SPINNET_INSTALLED_HISTORY_UNAVAILABLE__") { throw PluginHostServiceError.unavailable("Installed Ruby history lacks immutable source provenance; this read accepts installed JSON only") }
        return output
    }
    /// Internal native metadata lane. The Plugin contract cannot select these
    /// argv or increase tools.read's cap; mutation commands are never admitted.
    public static func executeNativeReceipt(_ arguments: [String], deadline: Date) throws -> HomebrewReadOutput {
        guard arguments == ["--pkgs"] || (arguments.count == 2 && ["--pkg-info-plist", "--export-plist", "--files"].contains(arguments[0])
            && arguments[1].utf8.count <= 200 && arguments[1].range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]+$", options: .regularExpression) != nil) else {
            throw PluginHostServiceError.invalidInput("Native receipt inspection accepts only exact read commands")
        }
        let cap = arguments.first == "--files" ? 16 * 1024 * 1024 : 4 * 1024 * 1024
        return try executeBounded(URL(fileURLWithPath: "/usr/sbin/pkgutil"), arguments, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"], deadline, .init(), stdoutLimit: cap, readOnly: true)
    }
    private static func executeBounded(_ executable: URL, _ arguments: [String], _ environment: [String: String], _ deadline: Date,
        _ cancellation: HostFetchedSections.Cancellation, stdoutLimit: Int, readOnly: Bool) throws -> HomebrewReadOutput {
        // Network denial applies to Homebrew and every descendant, including
        // missing/corrupt API-cache fallback and the user's brew.env overrides.
        // Deny package-prefix writes as well: bootstrap cannot install Ruby.
        let sandbox = readOnly || arguments.prefix(3) == ["ruby", "--", HomebrewDryRunReads.adapter.path] ? "(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (literal \"/dev/null\"))" : "(version 1)(allow default)(deny network*)(deny file-write* (subpath \"/opt/homebrew\") (subpath \"/usr/local/Homebrew\") (subpath \"/usr/local/Cellar\") (subpath \"/usr/local/Caskroom\"))"
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
        guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        let spawn = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            posix_spawn(&pid, launcher, &actions, &attributes, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
        } }
        guard spawn == 0 else { throw PluginHostServiceError.tool(.failed) }
        let childGroup = pid
        let forgetCancellation = cancellation.onCancel { kill(-childGroup, SIGKILL) }
        defer { forgetCancellation() }
        close(out[1]); close(err[1]); out[1] = -1; err[1] = -1
        _ = fcntl(out[0], F_SETFL, O_NONBLOCK); _ = fcntl(err[0], F_SETFL, O_NONBLOCK)
        var stdout = Data(), stderr = Data(), status: Int32 = 0, ended = false, open = [true, true]
        defer { kill(-pid, SIGKILL); if !ended { while waitpid(pid, &status, 0) == -1 && errno == EINTR {} } }
        while !ended || open.contains(true) {
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
            guard Date() < deadline else { kill(-pid, SIGKILL); throw PluginHostServiceError.tool(.timedOut) }
            for (index, fd) in [out[0], err[0]].enumerated() where open[index] {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { if index == 0 { stdout.append(contentsOf: buffer.prefix(count)) } else { stderr.append(contentsOf: buffer.prefix(count)) } }
                else if count == 0 { open[index] = false }
                else if errno != EAGAIN && errno != EINTR { throw PluginHostServiceError.tool(.failed) }
            }
            guard stdout.count <= stdoutLimit, stderr.count <= ReviewedToolReads.stderrBytes else { kill(-pid, SIGKILL); throw PluginHostServiceError.tool(.outputTooLarge) }
            if !ended { ended = waitpid(pid, &status, WNOHANG) == pid }
            if !ended || open.contains(true) { usleep(2000) }
        }
        return HomebrewReadOutput(status: (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f), stdout: stdout, stderr: stderr)
    }
}
public enum ReviewedToolFailure: String, Codable, Equatable {
    case missing = "tool_missing", timedOut = "tool_timed_out", failed = "tool_failed", outputTooLarge = "output_too_large"
    case busy = "tool_busy", packageNotFound = "package_not_found", sourceNotAllowed = "source_not_allowed"
    case alreadyInstalled = "already_installed", notOutdated = "not_outdated", taskNotFound = "task_not_found", taskFinished = "task_finished", planChanged = "plan_changed"
    public var message: String {
        switch self {
        case .missing: return "Homebrew is unavailable at /opt/homebrew/bin/brew or /usr/local/bin/brew. See https://brew.sh for installation information."
        case .timedOut: return "The reviewed Homebrew read exceeded its deadline."
        case .failed: return "Homebrew could not complete the reviewed read."
        case .outputTooLarge: return "Homebrew output exceeded the reviewed read limit."
        case .busy: return "Another reviewed Homebrew Task is running or awaiting confirmation."
        case .packageNotFound: return "The selected package is no longer available."
        case .sourceNotAllowed: return "The package source is not currently trusted in Homebrew."
        case .alreadyInstalled: return "This package is already installed."
        case .notOutdated: return "This package has no eligible update or is pinned."
        case .taskNotFound: return "No Task of this Plugin has this handle."
        case .taskFinished: return "This Task has already ended."
        case .planChanged: return "The reviewed plan changed. Review and confirm it again."
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
