import Foundation
import Darwin

/// Read-only, provenance-verified metadata for the Host's native cask plan.
/// Its resource and argv are fixed Host code, never Plugin-supplied paths/code.
public enum HomebrewPrivilegeMetadata {
    public struct Snapshot {
        public let metadata: [String: JSONValue]
        public let officialEvidence: HomebrewSignedCaskCatalog.Evidence?
        public let configuration: HomebrewSignedCaskCatalog.Configuration?
        fileprivate init(metadata: [String: JSONValue], officialEvidence: HomebrewSignedCaskCatalog.Evidence?, configuration: HomebrewSignedCaskCatalog.Configuration?) {
            self.metadata = metadata; self.officialEvidence = officialEvidence; self.configuration = configuration
        }
        /// Persist the held publisher envelope into the Host's Task stage. The
        /// journal/XPC carries this fixed file and SHA, not the full catalog.
        public func persistOfficialEvidence(in directory: URL) throws -> URL {
            guard let evidence = officialEvidence else { throw PluginHostServiceError.unavailable("No independent official source evidence is available") }
            let (parent, name) = try NativeFileQuarantine.openParent(directory); defer { close(parent) }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw PluginHostServiceError.tool(.planChanged) }
            if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                guard acl_valid(acl) == 0, acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0 else { throw PluginHostServiceError.tool(.planChanged) }
            } else if errno != ENOENT { throw PluginHostServiceError.tool(.planChanged) }
            let result = directory.appendingPathComponent("homebrew-source.jws.json")
            let file = openat(fd, "homebrew-source.jws.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if file < 0 && errno == EEXIST {
                let existing = try HomebrewSignedCaskCatalog.read(result)
                guard existing.envelopeSHA256 == evidence.catalog.envelopeSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
                return result
            }
            guard file >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(file) }
            do {
                try evidence.envelope.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += count
                    }
                }
                guard fsync(file) == 0 else { throw PluginHostServiceError.tool(.failed) }
            } catch { unlinkat(fd, "homebrew-source.jws.json", 0); throw error }
            return result
        }

    }
    public static func read(_ package: String, language: String? = nil,
                            executable: URL? = nil, environment: [String: String]? = nil,
                            deadline: Date = Date().addingTimeInterval(15),
                            execute: HomebrewReadProfile.Executor = HomebrewReadProfile.execute) throws -> [String: JSONValue] {
        try readEvidence(package, language: language, executable: executable, environment: environment, deadline: deadline, execute: execute).metadata
    }
    public static func readEvidence(_ package: String, language: String? = nil,
                            executable: URL? = nil, environment: [String: String]? = nil,
                            deadline: Date = Date().addingTimeInterval(15),
                            execute: HomebrewReadProfile.Executor = HomebrewReadProfile.execute) throws -> Snapshot {
        try readBatch([package], language: language, executable: executable, environment: environment, deadline: deadline, execute: execute)[0]
    }
    public static func readBatch(_ packages: [String], language: String? = nil,
                            executable: URL? = nil, environment: [String: String]? = nil,
                            deadline: Date = Date().addingTimeInterval(15),
                            execute: HomebrewReadProfile.Executor = HomebrewReadProfile.execute) throws -> [Snapshot] {
        guard (1...100).contains(packages.count), packages.allSatisfy({ HomebrewReadInput.validPackageName($0) && $0.utf8.count <= 200 }),
              (language ?? "").utf8.count <= 64,
              (language ?? "").range(of: "^(?:[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)?$", options: .regularExpression) != nil else {
            throw PluginHostServiceError.invalidInput("Native cask metadata requires a package identity and bounded language")
        }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        let tool = try executable ?? HomebrewReadProfile.discover()
        let adapter = Bundle.module.url(forResource: "HomebrewPrivilegeMetadata", withExtension: "rb")!
        var nativeEnvironment = environment ?? HomebrewReadProfile.environment
        nativeEnvironment["HOMEBREW_NO_BOOTSNAP"] = "1"
        let selectors = packages.flatMap { [$0, language ?? ""] }
        let result = try execute(tool, ["ruby", "--", adapter.path] + selectors, nativeEnvironment, deadline)
        guard result.stdout.count <= 1024 * 1024, result.stderr.count <= ReviewedToolReads.stderrBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        if result.status == 77 { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        if result.status == 78 { throw PluginHostServiceError.unavailable("Verified Homebrew native metadata is unavailable") }
        if result.status == 79 { throw PluginHostServiceError.unavailable("Native Homebrew metadata source revision needs review") }
        guard result.status == 0, case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: result.stdout) else { throw PluginHostServiceError.tool(.failed) }
        let records: [[String: JSONValue]]
        if packages.count == 1 { records = [root] }
        else {
            guard case .array(let values)? = root["records"], values.count == packages.count else { throw PluginHostServiceError.tool(.failed) }
            records = try values.map { value in guard case .object(let object) = value else { throw PluginHostServiceError.tool(.failed) }; return object }
        }
        var evidence: HomebrewSignedCaskCatalog.Evidence?
        return try zip(packages, records).map { package, record in
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            return try admit(record, package: package, language: language, tool: tool, nativeEnvironment: nativeEnvironment, deadline: deadline, evidence: &evidence)
        }
    }
    private static func admit(_ record: [String: JSONValue], package: String, language: String?, tool: URL, nativeEnvironment: [String: String], deadline: Date, evidence: inout HomebrewSignedCaskCatalog.Evidence?) throws -> Snapshot {
        guard case .string(let name)? = record["name"], HomebrewReadInput.validPackageName(name),
              name == package || (!package.contains("/") && name == "homebrew/cask/" + package),
              case .string? = record["version"], case .string? = record["url"],
              case .string(let payloadHash)? = record["sha256"], payloadHash == "no_check" || HomebrewPrivilegePlan.validDigest(payloadHash),
              case .array? = record["artifacts"], case .object? = record["config"],
              case .object(let source)? = record["source"],
              case .string(let kind)? = source["kind"], ["verified-api-jws", "trusted-git-blob"].contains(kind),
              case .string(let hash)? = source["sha256"], HomebrewPrivilegePlan.validDigest(hash) else { throw PluginHostServiceError.tool(.failed) }
        if kind == "verified-api-jws" {
            guard name.hasPrefix("homebrew/cask/"), source["tap"] == .string("homebrew/cask"),
                  case .string(let recordHash)? = source["record_sha256"], HomebrewPrivilegePlan.validDigest(recordHash),
                  case .string(let head)? = source["git_head"], head.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw PluginHostServiceError.tool(.failed) }
        } else {
            guard case .string(let tap)? = source["tap"], name.hasPrefix(tap + "/"),
                  case .string(let head)? = source["git_head"], head.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw PluginHostServiceError.tool(.failed) }
        }
        if kind == "verified-api-jws" {
            let prefix = HomebrewManagementReads.prefix(of: tool)
            let token = String(name.split(separator: "/").last!)
            let configuration = try controlledConfiguration(token: token, language: language, prefix: prefix)
            let cache = URL(fileURLWithPath: nativeEnvironment["HOMEBREW_CACHE"] ?? NSHomeDirectory() + "/Library/Caches/Homebrew")
            let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            let names = [13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe", 27: "golden_gate"]
            guard let name = names[version] else { throw PluginHostServiceError.unavailable("This macOS Homebrew catalog source needs review") }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let source = cache.appendingPathComponent("api/internal/packages.\(architecture)_\(name).jws.json")
            if evidence == nil { evidence = try HomebrewSignedCaskCatalog.load(source, deadline: deadline) }
            guard let held = evidence else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            try held.catalog.validate(record, token: token, configuration: configuration)
            return Snapshot(metadata: record, officialEvidence: held, configuration: configuration)
        }
        // Local HEAD equality is checkout integrity, not independent publisher
        // evidence. Root must not grant generated/vendor authority from this tag.
        return Snapshot(metadata: record, officialEvidence: nil, configuration: nil)
    }
    public static func effectiveConfiguration(name: String, prefix: URL) throws -> HomebrewSignedCaskCatalog.Configuration {
        guard HomebrewReadInput.validPackageName(name), ["/opt/homebrew", "/usr/local"].contains(prefix.path) else { throw PluginHostServiceError.tool(.planChanged) }
        return try controlledConfiguration(token: String(name.split(separator: "/").last!), language: nil, prefix: prefix)
    }
    private static func controlledConfiguration(token: String, language: String?, prefix: URL) throws -> HomebrewSignedCaskCatalog.Configuration {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let path = prefix.appendingPathComponent("Caskroom/\(token)/.metadata/config.json")
        var explicit: [String: JSONValue] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try boundedConfiguration(path)
            guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw PluginHostServiceError.tool(.planChanged) }
            if case .object(let object)? = root["explicit"] { explicit = object }
        }
        var selected: [String] = []
        if let language { selected.append(language) }
        else if case .array(let languages)? = explicit["languages"] { selected = languages.compactMap { if case .string(let text) = $0 { return text }; return nil } }
        let defaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? Locale.preferredLanguages
        selected += defaults.filter { !selected.contains($0) }
        var directory = "/Applications"
        if case .string(let custom)? = explicit["appdir"] { directory = custom }
        if directory == "~" || directory.hasPrefix("~/") { directory = home.path + directory.dropFirst() }
        guard directory.hasPrefix("/"), directory.utf8.count <= 2048 else { throw PluginHostServiceError.tool(.planChanged) }
        return try .init(languages: selected, home: home, prefix: prefix, appDirectory: URL(fileURLWithPath: directory))
    }
    private static func boundedConfiguration(_ path: URL) throws -> Data {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= 256 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
            guard bytes.count + count <= 256 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }; bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, bytes.count == before.st_size, after.st_size == before.st_size,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
        return bytes
    }
}
