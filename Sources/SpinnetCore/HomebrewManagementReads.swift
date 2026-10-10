import Foundation

/// Reviewed Homebrew management reads. Plugin input never supplies argv, a path,
/// a script, an environment or a URL. Old #87 reads keep their offline executor.
public final class HomebrewManagementReads {
    public static let operations = ["version", "taps", "services", "vulnerabilities", "vulnerabilityDetail", "doctor", "previewInstall", "previewUpgrade", "previewUpgradeAll", "adoptionCandidates", "adoptionPreview", "packageAnalytics"]
    private let remote: HomebrewManagementRemoteReads
    private let previewTransport: HTTPSTransport?
    private let applications: () -> [HomebrewAdoptionApplication]
    private let lock = NSLock()
    private var appSnapshots: [String: HomebrewAdoptionApplication] = [:]
    private let targets: HomebrewManagementTargets
    public convenience init() { self.init(targets: .shared) }
    public init(targets: HomebrewManagementTargets, applications: @escaping () -> [HomebrewAdoptionApplication] = HomebrewAdoptionApplication.discover,
                transport: HTTPSTransport? = nil) {
        self.previewTransport = transport
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
        if operation == "previewUpgradeAll" {
            guard Set(fields.keys).isSubset(of: ["tool", "operation", "kind", "greedy"]),
                  fields["kind"] == nil || [JSONValue.string("formula"), .string("cask")].contains(fields["kind"]!) else { throw invalid() }
            if let greedy = fields["greedy"], case .bool = greedy {} else if fields["greedy"] != nil { throw invalid() }
            return
        }
        if ["previewInstall", "previewUpgrade", "packageAnalytics"].contains(operation) {
            let allowed: Set<String> = ["tool", "operation", "kind", "names", "greedy"]
            guard Set(fields.keys).isSubset(of: allowed), case .string(let kind)? = fields["kind"], ["formula", "cask"].contains(kind),
                  case .array(let names)? = fields["names"], (1...(operation == "packageAnalytics" ? 20 : 50)).contains(names.count), Set(names).count == names.count,
                  names.allSatisfy({ if case .string(let name) = $0 { return HomebrewReadInput.validPackageName(name) }; return false }) else { throw invalid() }
            if operation != "previewUpgrade", fields["greedy"] != nil { throw invalid() }
            if let greedy = fields["greedy"], case .bool = greedy {} else if fields["greedy"] != nil { throw invalid() }
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
    private static func appToken(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    private static func adoptionMatch(app: HomebrewAdoptionApplication, cask: [String: Any]) -> JSONValue? {
        guard let token = cask["token"] as? String, HomebrewReadInput.validToken(token) else { return nil }
        let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
        let appNames = artifacts.flatMap { $0["app"] as? [String] ?? [] }.map { URL(fileURLWithPath: $0).lastPathComponent }
        let names = [token] + (cask["name"] as? [String] ?? []) + appNames.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        guard names.contains(where: { appToken($0) == appToken(app.name) }) else { return nil }
        let exactArtifact = appNames.contains(app.url.lastPathComponent)
        let quits = artifacts.flatMap { $0["uninstall"] as? [[String: Any]] ?? [] }.flatMap { record -> [String] in
            if let value = record["quit"] as? String { return [value] }; return record["quit"] as? [String] ?? []
        }
        let sameVersion = (cask["version"] as? String)?.split(separator: ",").first.map(String.init) == app.version
        let managed = cask["installed"] != nil && !(cask["installed"] is NSNull) && (cask["installed"] as? [Any])?.isEmpty != true
        let installer = artifacts.contains { $0["pkg"] != nil || $0["installer"] != nil }
        let confidence: String, reason: String
        if managed { confidence = "cannot"; reason = "Already managed by Homebrew" }
        else if installer { confidence = "cannot"; reason = "Installer artifacts cannot adopt an existing App" }
        else if !sameVersion && cask["auto_updates"] as? Bool != true { confidence = "cannot"; reason = "Installed App version differs from the current cask; Homebrew would refuse adoption" }
        else if !exactArtifact { confidence = "unlikely"; reason = "Name matches but the cask App filename differs" }
        else if quits.contains(app.bundleID) { confidence = "ready"; reason = "Cask bundle identifier and App artifact match; Host review is still required" }
        else { confidence = "likely"; reason = "App filename and compatible version match; bundle identity is unverified" }
        return .object(["name": .string(token), "confidence": .string(confidence), "reason": .string(reason)])
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
            var recipes: [String: JSONValue] = [:]
            if !selected.isEmpty {
                let metadata = try run(["info", "--json=v2", "--formula", "--"] + selected.map(\.name))
                if metadata.status == 0, let document = try? JSONDecoder().decode(JSONValue.self, from: metadata.stdout),
                   case .array(let records)? = document.value(atPointer: "/formulae") {
                    for record in records.prefix(20) {
                        if case .string(let name)? = record.value(atPointer: "/name"), selected.contains(where: { $0.name == name }) { recipes[name] = record }
                    }
                }
            }
            result.merge(try remote.read(operation: operation, input: input, inventory: selected, recipes: recipes, prefix: Self.prefix(of: executable), deadline: deadline,
                cancellation: cancellation, stillAuthorized: stillAuthorized), uniquingKeysWith: { _, new in new })
            result["available"] = .bool(true); result["offset"] = .number(Double(offset)); result["total"] = .number(Double(inventory.count))
            if input.value(atPointer: "/names") == nil, offset + 20 < inventory.count { result["next_offset"] = .number(Double(offset + 20)) }
            return .object(result)
        }
        if ["previewInstall", "previewUpgrade", "previewUpgradeAll"].contains(operation) {
            guard String(version).hasPrefix("7.0.") else {
                result["available"] = .bool(false); result["reason"] = .string("requires_reviewed_homebrew_version")
                result["estimated"] = .bool(false); result["summary"] = .string("Actual previews currently require reviewed Homebrew 7.0.x")
                result["packages"] = .array([]); return .object(result)
            }
            var selections: [(String, [String])] = []
            let greedy = input.value(atPointer: "/greedy") == .bool(true)
            if operation == "previewUpgradeAll" {
                let kind: String? = { if case .string(let k)? = input.value(atPointer: "/kind") { return k }; return nil }()
                let args = ["outdated", "--json=v2"] + (kind.map { ["--" + $0] } ?? []) + (greedy ? ["--greedy"] : [])
                let out = try run(args)
                guard out.status == 0, let raw = try JSONSerialization.jsonObject(with: out.stdout) as? [String: Any] else { throw PluginHostServiceError.tool(.failed) }
                for kind in kind.map({ [$0] }) ?? ["formula", "cask"] {
                    guard let rows = raw[kind == "formula" ? "formulae" : "casks"] as? [[String: Any]], rows.count <= 2000 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    let names = rows.filter { $0["pinned"] as? Bool != true }.compactMap { $0["full_name"] as? String ?? $0["full_token"] as? String ?? $0["name"] as? String ?? $0["token"] as? String }
                    guard names.count == rows.filter({ $0["pinned"] as? Bool != true }).count, names.allSatisfy(HomebrewReadInput.validPackageName) else { throw PluginHostServiceError.tool(.failed) }
                    for offset in stride(from: 0, to: names.count, by: 50) { selections.append((kind, Array(names.dropFirst(offset).prefix(50)))) }
                }
            } else {
                guard case .string(let kind)? = input.value(atPointer: "/kind"), case .array(let names)? = input.value(atPointer: "/names") else { throw Self.invalid() }
                selections = [(kind, names.compactMap { if case .string(let n) = $0 { return n }; return nil })]
            }
            var projected: [JSONValue] = [], stages: [JSONValue] = [], warnings: [JSONValue] = [], stdout = "", stderr = "", succeeded = true, exitStatus: JSONValue = .number(0)
            func trusted(_ packages: [[String: Any]], kind: String) throws {
                let thirdParty = packages.compactMap { $0["tap"] as? String }.filter { !["homebrew/core", "homebrew/cask"].contains($0) }
                guard packages.allSatisfy({ ($0["tap"] as? String)?.isEmpty == false }) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                if !thirdParty.isEmpty {
                    let out = try run(["trust", "--tap", "--json=v1"])
                    guard out.status == 0, let allowed = try? JSONDecoder().decode([String].self, from: out.stdout), thirdParty.allSatisfy(allowed.contains) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                }
            }
            var networkBytes = 0, metadataRequests = 0
            for (kind, names) in selections {
                let args = ["info", "--json=v2", "--" + kind, "--"] + names
                let before = try run(args)
                guard before.status == 0, let raw = try JSONSerialization.jsonObject(with: before.stdout) as? [String: Any],
                      let packages = raw[kind == "formula" ? "formulae" : "casks"] as? [[String: Any]], packages.count == names.count else { throw PluginHostServiceError.tool(.packageNotFound) }
                try trusted(packages, kind: kind)
                projected += packages.compactMap { HomebrewReadProfile.project($0, kind: kind, outdated: false, prefix: Self.prefix(of: executable)) }
                let dry = try HomebrewDryRunReads.read(operation: operation, kind: kind, names: names, greedy: greedy && kind == "cask",
                    executable: executable, deadline: deadline, cancellation: cancellation, execute: execute, networkBytes: &networkBytes, metadataRequests: &metadataRequests, transport: previewTransport, stillAuthorized: stillAuthorized)
                let after = try run(args)
                guard after.status == 0, try JSONSerialization.jsonObject(with: after.stdout) as? NSDictionary == raw as NSDictionary else { throw PluginHostServiceError.tool(.planChanged) }
                try trusted(packages, kind: kind)
                if case .array(let v)? = dry["stages"] { stages += v }
                if case .array(let v)? = dry["warnings"] { warnings += v }
                if case .string(let v)? = dry["stdout"] { stdout += v + "\n" }
                if case .string(let v)? = dry["stderr"] { stderr += v + "\n" }
                if dry["succeeded"] == .bool(false) { succeeded = false; exitStatus = dry["exit_status"] ?? .number(1) }
                guard stdout.utf8.count + stderr.utf8.count <= 128 * 1024, stages.count <= 256, warnings.count <= 128 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            }
            result.merge(["packages": .array(projected), "estimated": .bool(false), "dry_run": .bool(true), "available": .bool(true),
                "succeeded": .bool(succeeded), "exit_status": exitStatus, "stdout": .string(stdout), "stderr": .string(stderr),
                "stages": .array(stages), "warnings": .array(warnings),
                "summary": .string(selections.isEmpty ? "No eligible unpinned upgrades in the current inventory." : succeeded ? "Homebrew dry-run. Versions, dependencies and warnings below come from Homebrew. Missing download sizes are unknown." : "Homebrew refused the dry-run. Review its diagnostics before choosing a Task.")]) { _, new in new }
            return .object(result)
        }
        if operation == "adoptionCandidates" {
            targets.invalidate(owner: owner, domain: "adoptionCandidate")
            let snapshots = Array(applications().prefix(128))
            var casks: [[String: Any]] = []
            let tokens = Array(Set(snapshots.map { Self.appToken($0.name) }.filter { !$0.isEmpty })).sorted().prefix(128)
            if !tokens.isEmpty {
                let search = try run(["search", "--cask", "--", "/(" + tokens.joined(separator: "|") + ")/"])
                if search.status == 0, let text = String(data: search.stdout, encoding: .utf8) {
                    let names = Array(Set(text.split(whereSeparator: \.isWhitespace).map(String.init).filter { HomebrewReadInput.validToken($0) })).sorted()
                    let selected = Array(names.prefix(50))
                    if !selected.isEmpty {
                        let answer = try run(["info", "--json=v2", "--cask", "--"] + selected)
                        if answer.status == 0, let raw = try? JSONSerialization.jsonObject(with: answer.stdout) as? [String: Any] { casks = Array((raw["casks"] as? [[String: Any]] ?? []).prefix(50)) }
                    }
                    if names.count > 50 { result["truncated"] = .bool(true) }
                }
            }
            result["applications"] = .array(snapshots.map { app in
                let target = HomebrewManagementTarget(operation: "adoptionCandidate", kind: "cask", name: app.name, arguments: [], needsPrivileges: false,
                    summary: "Review adoption of " + app.name, metadata: .object(["bundle_id": .string(app.bundleID), "version": .string(app.version)]))
                let key = targets.issue(target, owner: owner, domain: "adoptionCandidate", current: { [applications] in applications().contains(app) })
                lock.withLock { if appSnapshots.count >= 256 { appSnapshots.removeAll() }; appSnapshots[key] = app }
                let matches: [JSONValue] = casks.compactMap { Self.adoptionMatch(app: app, cask: $0) }.sorted { left, right in
                    let ranks = ["ready": 0, "likely": 1, "unlikely": 2, "cannot": 3]
                    func rank(_ value: JSONValue) -> Int { if case .string(let text)? = value.value(atPointer: "/confidence") { return ranks[text] ?? 3 }; return 3 }
                    return rank(left) < rank(right)
                }
                return .object(["target": .string(key), "name": .string(app.name), "bundle_id": .string(app.bundleID), "version": .string(app.version), "candidates": .array(Array(matches.prefix(4)))])
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
                  (caskVersion.split(separator: ",").first.map(String.init) == app.version || cask["auto_updates"] as? Bool == true),
                  cask["installed"] == nil || cask["installed"] is NSNull || (cask["installed"] as? [Any])?.isEmpty == true else {
                throw PluginHostServiceError.invalidInput("This cask does not match the installed App and version, is already managed, or needs an installer; choose a matching application-only cask")
            }
            guard String(version).hasPrefix("7.0.") else { throw PluginHostServiceError.unavailable("Actual adoption preview requires reviewed Homebrew 7.0.x") }
            var networkBytes = 0, metadataRequests = 0
            let dry = try HomebrewDryRunReads.read(operation: "previewInstall", kind: "cask", names: [name], adopt: true,
                executable: executable, deadline: deadline, cancellation: cancellation, execute: execute,
                networkBytes: &networkBytes, metadataRequests: &metadataRequests, stillAuthorized: stillAuthorized)
            result.merge(dry) { _, new in new }
            result["name"] = .string(name); result["kind"] = .string("cask")
            guard dry["succeeded"] == .bool(true) else { return .object(result) }
            _ = try targets.resolve(target: key, owner: owner)
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
            var reviewedSet: [(key: String, value: HomebrewManagementTarget)] = []
            var issuedRepairs: [(key: String, value: HomebrewManagementTarget)] = []
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
                    } else { value = HomebrewOwnershipRepair.resolve(command: command, prefix: Self.prefix(of: executable)) }
                    if let value {
                        let key: String
                        if let existing = issuedRepairs.first(where: { $0.value.operation == value.operation && $0.value.kind == value.kind && $0.value.name == value.name && $0.value.metadata == value.metadata }) { key = existing.key }
                        else {
                            guard issuedRepairs.count < 128 else { result["truncated"] = .bool(true); continue }
                            key = targets.issue(value, owner: owner, domain: "doctor", current: { value.metadata.value(atPointer: "/privileged_repair") != .bool(true) || HomebrewOwnershipRepair.isCurrent(value.metadata) })
                            issuedRepairs.append((key, value))
                        }

                        repairs.append(.object(["target": .string(key), "title": .string(value.summary)]))
                        if reviewedSet.count < 8, !reviewedSet.contains(where: { $0.value.operation == value.operation && $0.value.kind == value.kind && $0.value.name == value.name && $0.value.metadata == value.metadata }) { reviewedSet.append((key, value)) }
                    }
                }
                var value: [String: JSONValue] = ["id": .string("finding-" + String(index)),
                    "text": .string(Self.clean(finding["text"] as? String ?? "Homebrew finding")),
                    "links": .array((finding["links"] as? [String] ?? []).prefix(8).compactMap { Self.safeURL($0).map(JSONValue.string) }),
                    "commands": .array(commands.map { .string(Self.clean($0, maximum: 512)) }), "repairs": .array(repairs)]
                if let text = remediation?["text"] as? String { value["guidance"] = .string(Self.clean(text)) }
                return .object(value)
            })
            if !reviewedSet.isEmpty {
                let frozen = reviewedSet
                let steps: [JSONValue] = frozen.map { entry in
                    let value = entry.value
                    var input: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string(value.operation)]
                    if value.operation != "cleanup" { input["kind"] = .string(value.kind) }
                    if !value.name.isEmpty { input["name"] = .string(value.name) }
                    if value.operation == "cleanup" { input["days"] = .number(120) }
                    return .object(["input": .object(input), "metadata": value.metadata, "repair_summary": .string(value.summary)])
                }
                let title = "Run " + String(frozen.count) + " Host-reviewed Doctor repairs: " + frozen.map { $0.value.summary }.joined(separator: "; ")
                let batch = HomebrewManagementTarget(operation: "doctorBatch", kind: "formula", name: "", arguments: [],
                    needsPrivileges: frozen.contains { $0.value.needsPrivileges }, summary: title,
                    metadata: .object(["doctor_steps": .array(steps)]))
                let key = targets.issue(batch, owner: owner, domain: "doctor", current: { [targets] in frozen.allSatisfy { targets.isCurrent(target: $0.key, owner: owner) } })
                result["fix_all"] = .object(["target": .string(key), "title": .string(title), "count": .number(Double(frozen.count))])
            }
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
