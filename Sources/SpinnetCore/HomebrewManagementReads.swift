import Foundation

/// Reviewed Homebrew management reads. Plugin input never supplies argv, a path,
/// a script, an environment or a URL. Old #87 reads keep their offline executor.
public final class HomebrewManagementReads {
    public static let operations = ["version", "taps", "services", "vulnerabilities", "vulnerabilityDetail", "doctor", "previewInstall", "previewUpgrade", "adoptionCandidates", "adoptionPreview", "packageAnalytics"]
    private let remote: HomebrewManagementRemoteReads
    private let applications: () -> [HomebrewAdoptionApplication]
    private let lock = NSLock()
    private var appSnapshots: [String: HomebrewAdoptionApplication] = [:]
    private let targets: HomebrewManagementTargets
    public convenience init() { self.init(targets: .shared) }
    public init(targets: HomebrewManagementTargets, applications: @escaping () -> [HomebrewAdoptionApplication] = HomebrewAdoptionApplication.discover,
                transport: HTTPSTransport? = nil) {
        self.targets = targets; self.applications = applications; self.remote = HomebrewManagementRemoteReads(transport: transport)
    }
    public convenience init(transport: HTTPSTransport) { self.init(targets: .shared, transport: transport) }
    public func invalidateTargets(owner: PluginID) { targets.invalidate(owner: owner) }
    public static func validate(_ input: JSONValue) throws {
        guard case .object(let fields) = input, fields["tool"] == .string("homebrew"), case .string(let operation)? = fields["operation"], operations.contains(operation) else { throw invalid() }
        let global = ["version", "doctor", "adoptionCandidates"]
        if operation == "services" {
            guard Set(fields.keys).isSubset(of: ["tool", "operation", "kind"]), fields["kind"] == nil || fields["kind"] == .string("formula") else { throw invalid() }
            return
        }
        if operation == "taps" {
            guard Set(fields.keys).isSubset(of: ["tool", "operation", "tap"]) else { throw invalid() }
            if let value = fields["tap"] {
                guard case .string(let tap) = value, tap.count <= 96, tap.range(of: "^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$", options: .regularExpression) != nil else { throw invalid() }
            }
            return
        }
        if global.contains(operation) { guard Set(fields.keys) == ["tool", "operation"] else { throw invalid() }; return }
        if operation == "vulnerabilityDetail" {
            guard Set(fields.keys) == ["tool", "operation", "id"], case .string(let id)? = fields["id"], HomebrewManagementRemoteReads.validID(id) else { throw invalid() }
            return
        }
        if operation == "vulnerabilities" {
            guard Set(fields.keys).isSubset(of: ["tool", "operation", "names", "offset"]), !(fields["names"] != nil && fields["offset"] != nil) else { throw invalid() }
            if let names = fields["names"] {
                guard case .array(let values) = names, (1...20).contains(values.count), Set(values).count == values.count,
                      values.allSatisfy({ if case .string(let name) = $0 { return HomebrewReadInput.validPackageName(name) }; return false }) else { throw invalid() }
            }
            if let offset = fields["offset"] { guard case .number(let n) = offset, n.rounded() == n, (0...1999).contains(n) else { throw invalid() } }
            return
        }
        if ["previewInstall", "previewUpgrade", "packageAnalytics"].contains(operation) {
            let allowed: Set<String> = ["tool", "operation", "kind", "names"]
            guard Set(fields.keys) == allowed, case .string(let kind)? = fields["kind"], ["formula", "cask"].contains(kind),
                  case .array(let names)? = fields["names"], (1...20).contains(names.count), Set(names).count == names.count,
                  names.allSatisfy({ if case .string(let name) = $0 { return HomebrewReadInput.validPackageName(name) }; return false }) else { throw invalid() }
            if operation == "packageAnalytics", names.count != 1 { throw invalid() }
            return
        }
        if operation == "adoptionPreview" {
            guard Set(fields.keys) == ["tool", "operation", "target", "name"], case .string(let target)? = fields["target"],
                  target.hasPrefix("app_"), target.count <= 80, case .string(let name)? = fields["name"], HomebrewReadInput.validPackageName(name) else { throw invalid() }
            return
        }
        throw invalid()
    }
    static func prefix(of executable: URL) -> URL {
        let path = executable.resolvingSymlinksInPath().path
        if path.hasPrefix("/opt/homebrew/") { return URL(fileURLWithPath: "/opt/homebrew") }
        if path.hasPrefix("/usr/local/") { return URL(fileURLWithPath: "/usr/local") }
        return executable.deletingLastPathComponent().deletingLastPathComponent()
    }
    static func safeURL(_ text: String) -> String? {
        guard text.utf8.count <= 2048, let url = URL(string: text), ["https", "http"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return text
    }
    static func clean(_ text: String, maximum: Int = 2048) -> String {
        let scrubbed = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: "(?i)(bearer\\s+|(?:token|password|secret|api[_-]?key)[=:]\\s*)[^\\s,;]+", with: "$1[redacted]", options: .regularExpression)
        return String(String(String.UnicodeScalarView(scrubbed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" })).prefix(maximum))
    }
    private static func invalid() -> PluginHostServiceError { .invalidInput("Unsupported reviewed Homebrew management read") }
    public func read(_ input: JSONValue, owner: PluginID, executable: URL, deadline: Date, cancellation: HostFetchedSections.Cancellation,
                     execute: HomebrewReadProfile.CancellableExecutor, stillAuthorized: () throws -> Void) throws -> JSONValue {
        try Self.validate(input)
        guard case .string(let operation)? = input.value(atPointer: "/operation") else { throw Self.invalid() }
        func run(_ args: [String]) throws -> HomebrewReadOutput {
            try stillAuthorized()
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let answer = try execute(executable, args, HomebrewReadProfile.environment, deadline, cancellation)
            guard answer.stdout.count <= ReviewedToolReads.stdoutBytes, answer.stderr.count <= ReviewedToolReads.stderrBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            try stillAuthorized()
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            return answer
        }
        var result: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string(operation)]
        let versionOutput = try run(["--version"])
        guard versionOutput.status == 0, let version = String(data: versionOutput.stdout, encoding: .utf8)?.split(separator: "\n").first?.split(separator: " ").dropFirst().first,
              version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+([.-][a-zA-Z0-9.-]+)?$", options: .regularExpression) != nil else { throw PluginHostServiceError.tool(.failed) }
        let major = Int(version.split(separator: ".")[0]) ?? 0
        result["version"] = .string(String(version))
        if operation == "version" {
            result["features"] = .object(["vulnerabilities": .bool(major >= 7), "doctorJSON": .bool(major >= 7), "trust": .bool(major >= 7)])
            return .object(result)
        }
        if ["vulnerabilityDetail", "packageAnalytics"].contains(operation) {
            if operation == "vulnerabilityDetail", major < 7 { result["available"] = .bool(false); result["reason"] = .string("requires_homebrew_7"); return .object(result) }
            let prefix = Self.prefix(of: executable)
            result.merge(try remote.read(operation: operation, input: input, prefix: prefix, deadline: deadline,
                cancellation: cancellation, stillAuthorized: stillAuthorized), uniquingKeysWith: { _, new in new })
            result["available"] = .bool(true)
            return .object(result)
        }
        if operation == "vulnerabilities" {
            guard major >= 7 else { result["available"] = .bool(false); result["reason"] = .string("requires_homebrew_7"); return .object(result) }
            let answer = try run(["list", "--formula", "--versions"])
            guard answer.status == 0, let output = String(data: answer.stdout, encoding: .utf8) else { throw PluginHostServiceError.tool(.failed) }
            let inventory: [(name: String, version: String)] = output.split(separator: "\n").prefix(2000).compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 2, HomebrewReadInput.validToken(parts[0]) else { return nil }
                return (parts[0], parts[1])
            }.sorted(by: { $0.name < $1.name })
            let offset: Int = { if case .number(let n)? = input.value(atPointer: "/offset") { return Int(n) }; return 0 }()
            let selected: [(name: String, version: String)]
            if case .array(let values)? = input.value(atPointer: "/names") {
                let names = values.compactMap { if case .string(let name) = $0 { return name.split(separator: "/").last.map(String.init) }; return nil }
                selected = inventory.filter { names.contains($0.name) }
            } else { selected = Array(inventory.dropFirst(offset).prefix(20)) }
            result.merge(try remote.read(operation: operation, input: input, inventory: selected, prefix: Self.prefix(of: executable), deadline: deadline,
                cancellation: cancellation, stillAuthorized: stillAuthorized), uniquingKeysWith: { _, new in new })
            result["available"] = .bool(true); result["offset"] = .number(Double(offset)); result["total"] = .number(Double(inventory.count))
            if input.value(atPointer: "/names") == nil, offset + 20 < inventory.count { result["next_offset"] = .number(Double(offset + 20)) }
            return .object(result)
        }
        if ["previewInstall", "previewUpgrade"].contains(operation) {
            guard case .string(let kind)? = input.value(atPointer: "/kind"), case .array(let names)? = input.value(atPointer: "/names") else { throw Self.invalid() }
            let selected = names.compactMap { if case .string(let name) = $0 { return name }; return nil }
            let answer = try run(["info", "--json=v2", "--" + kind, "--"] + selected)
            guard answer.status == 0, let raw = try JSONSerialization.jsonObject(with: answer.stdout) as? [String: Any],
                  let packages = raw[kind == "formula" ? "formulae" : "casks"] as? [[String: Any]] else { throw PluginHostServiceError.tool(.failed) }
            result["packages"] = .array(packages.prefix(20).compactMap { HomebrewReadProfile.project($0, kind: kind, outdated: false, prefix: Self.prefix(of: executable)) })
            result["estimated"] = .bool(true)
            result["summary"] = .string("Estimated plan from local metadata. Homebrew rechecks dependencies, pins and source trust before a confirmed task; this is not a brew dry-run.")
            return .object(result)
        }
        if operation == "adoptionCandidates" {
            targets.invalidate(owner: owner, domain: "adoptionCandidate")
            let snapshots = applications().prefix(128)
            result["applications"] = .array(snapshots.map { app in
                let target = HomebrewManagementTarget(operation: "adoptionCandidate", kind: "cask", name: app.name, arguments: [], needsPrivileges: false,
                    summary: "Review adoption of " + app.name, metadata: .object(["bundle_id": .string(app.bundleID), "version": .string(app.version)]))
                let key = targets.issue(target, owner: owner, domain: "adoptionCandidate", current: { [applications] in applications().contains(app) })
                lock.withLock { if appSnapshots.count >= 256 { appSnapshots.removeAll() }; appSnapshots[key] = app }
                return .object(["target": .string(key), "name": .string(app.name), "bundle_id": .string(app.bundleID), "version": .string(app.version)])
            })
            return .object(result)
        }
        if operation == "adoptionPreview" {
            guard case .string(let key)? = input.value(atPointer: "/target"), case .string(let name)? = input.value(atPointer: "/name"),
                  let app = lock.withLock({ appSnapshots[key] }) else { throw Self.invalid() }
            _ = try targets.resolve(target: key, owner: owner)
            let answer = try run(["info", "--json=v2", "--cask", "--", name])
            guard answer.status == 0, let raw = try JSONSerialization.jsonObject(with: answer.stdout) as? [String: Any],
                  let cask = (raw["casks"] as? [[String: Any]])?.first, let caskVersion = cask["version"] as? String,
                  let artifacts = cask["artifacts"] as? [[String: Any]],
                  artifacts.contains(where: { ($0["app"] as? [Any])?.contains(where: { ($0 as? String)?.split(separator: "/").last.map(String.init) == app.url.lastPathComponent }) == true }),
                  !artifacts.contains(where: { $0["pkg"] != nil || $0["installer"] != nil }),
                  caskVersion.split(separator: ",").first.map(String.init) == app.version,
                  cask["installed"] == nil || cask["installed"] is NSNull || (cask["installed"] as? [Any])?.isEmpty == true else {
                throw PluginHostServiceError.invalidInput("This cask does not match the installed App and version, is already managed, or needs an installer; choose a matching application-only cask")
            }
            let target = HomebrewManagementTarget(operation: "install", kind: "cask", name: name,
                arguments: ["install", "--cask", "--adopt", "--", name], needsPrivileges: false,
                summary: "Adopt " + app.name + " as Homebrew cask " + name,
                metadata: .object(["adopt": .bool(true), "bundle_id": .string(app.bundleID), "version": .string(app.version)]))
            result["target"] = .string(targets.issue(target, owner: owner, domain: "adoption", current: { [applications] in applications().contains(app) }))
            result["name"] = .string(name); result["kind"] = .string("cask"); result["summary"] = .string(target.summary)
            return .object(result)
        }
        if operation == "doctor" {
            guard major >= 7 else { result["available"] = .bool(false); result["reason"] = .string("requires_homebrew_7"); return .object(result) }
            let answer = try run(["doctor", "--json"])
            guard [0, 1].contains(answer.status), let report = try JSONSerialization.jsonObject(with: answer.stdout) as? [String: Any],
                  let findings = report["findings"] as? [[String: Any]] else { throw PluginHostServiceError.tool(.failed) }
            targets.invalidate(owner: owner, domain: "doctor")
            result["available"] = .bool(true)
            result["tier"] = .string(Self.clean(String(describing: report["tier"] ?? 1), maximum: 20))
            result["findings"] = .array(findings.prefix(100).enumerated().map { index, finding in
                let remediation = finding["remediation"] as? [String: Any]
                let commands = (remediation?["commands"] as? [String] ?? []).prefix(8)
                var repairs: [JSONValue] = []
                for command in commands {
                    let value: HomebrewManagementTarget?
                    if command == "brew cleanup" {
                        value = .init(operation: "cleanup", kind: "formula", name: "", arguments: ["cleanup", "--prune=120"],
                            needsPrivileges: false, summary: "Clean Homebrew's stale downloads and old package versions", metadata: .object(["days": .number(120)]))
                    } else if command.hasPrefix("brew link ") {
                        let name = String(command.dropFirst(10))
                        value = HomebrewReadInput.validToken(name) ? .init(operation: "link", kind: "formula", name: name,
                            arguments: ["link", "--formula", "--", name], needsPrivileges: false, summary: "Link " + name,
                            metadata: .object(["doctor_repair": .bool(true)])) : nil
                    } else { value = HomebrewOwnershipRepair.resolve(command: command, prefix: executable.deletingLastPathComponent().deletingLastPathComponent()) }
                    if let value {
                        repairs.append(.object(["target": .string(targets.issue(value, owner: owner, domain: "doctor", current: { value.metadata.value(atPointer: "/privileged_repair") != .bool(true) || HomebrewOwnershipRepair.isCurrent(value.metadata) })), "title": .string(value.summary)]))
                    }
                }
                var value: [String: JSONValue] = ["id": .string("finding-" + String(index)),
                    "text": .string(Self.clean(finding["text"] as? String ?? "Homebrew finding")),
                    "links": .array((finding["links"] as? [String] ?? []).prefix(8).compactMap { Self.safeURL($0).map(JSONValue.string) }),
                    "commands": .array(commands.map { .string(Self.clean($0, maximum: 512)) }), "repairs": .array(repairs)]
                if let text = remediation?["text"] as? String { value["guidance"] = .string(Self.clean(text)) }
                return .object(value)
            })
            if findings.count > 100 { result["truncated"] = .bool(true) }
            return .object(result)
        }
        if operation == "taps" {
            let selected: String? = { if case .string(let tap)? = input.value(atPointer: "/tap") { return tap }; return nil }()
            let answer = try run(selected.map { ["tap-info", "--json=v1", "--", $0] } ?? ["tap-info", "--installed", "--json=v1"])
            guard answer.status == 0, let records = try JSONSerialization.jsonObject(with: answer.stdout) as? [[String: Any]] else { throw PluginHostServiceError.tool(.failed) }
            result["taps"] = .array(records.prefix(200).compactMap { record in
                guard let name = record["name"] as? String, name.range(of: "^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$", options: .regularExpression) != nil, name.count <= 96 else { return nil }
                var tap: [String: JSONValue] = ["name": .string(name), "official": .bool(record["official"] as? Bool == true),
                    "trusted": .bool(record["trusted"] as? Bool == true),
                    "formula_count": .number(Double((record["formula_names"] as? [String])?.count ?? 0)),
                    "cask_count": .number(Double((record["cask_tokens"] as? [String])?.count ?? 0))]
                if let text = record["remote"] as? String, let url = Self.safeURL(text) { tap["remote"] = .string(url) }
                if selected != nil {
                    let formulae = (record["formula_names"] as? [String] ?? []).filter(HomebrewReadInput.validPackageName)
                    let casks = (record["cask_tokens"] as? [String] ?? []).filter(HomebrewReadInput.validPackageName)
                    tap["packages"] = .array((formulae.map { .object(["kind": .string("formula"), "name": .string($0)]) as JSONValue } + casks.map { .object(["kind": .string("cask"), "name": .string($0)]) as JSONValue }).prefix(1000).map { $0 })
                    if formulae.count + casks.count > 1000 { tap["truncated"] = .bool(true) }
                }
                return .object(tap)
            })
            if records.count > 200 { result["truncated"] = .bool(true) }
            return .object(result)
        }
        if operation == "services" {
            let answer = try run(["services", "list", "--json"])
            guard answer.status == 0, let records = try JSONSerialization.jsonObject(with: answer.stdout) as? [[String: Any]] else { throw PluginHostServiceError.tool(.failed) }
            result["services"] = .array(records.prefix(2000).compactMap { record in
                guard let name = record["name"] as? String, HomebrewReadInput.validToken(name),
                      let status = record["status"] as? String, ["started", "scheduled", "stopped", "none", "error", "unknown", "other"].contains(status),
                      record["user"] == nil || record["user"] is NSNull || record["user"] as? String == NSUserName() || record["user"] as? String == "" else { return nil }
                return .object(["name": .string(name), "status": .string(status), "user_owned": .bool(true)])
            })
            if records.count > 2000 { result["truncated"] = .bool(true) }
            return .object(result)
        }
        throw PluginHostServiceError.unavailable("This management read is not yet implemented")
    }
}
