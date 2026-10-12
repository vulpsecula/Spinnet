import Foundation
import Darwin

/// Read-only inventory worker protocol. No executable, environment, argv or
/// alternate source roots can be supplied by a Plugin or request.
public enum HomebrewNativeLaunchServiceInventory {
    public static let maximumRequestBytes = 64 * 1024
    public static let maximumOutputBytes = 1024 * 1024
    public struct Request: Codable {
        public let version: Int
        public let context: HomebrewNativeLaunchServices.Context
        public let declarations: [HomebrewNativeLaunchServices.Declaration]
        public let deadline: Date
        public init(context: HomebrewNativeLaunchServices.Context, declarations: [HomebrewNativeLaunchServices.Declaration], deadline: Date) {
            version = 1; self.context = context; self.declarations = declarations; self.deadline = deadline
        }
    }
    public struct Response: Codable {
        public let version: Int
        public let manifest: HomebrewNativeLaunchServices.Manifest?
        public let failure: ReviewedToolFailure?
        public let unavailable: String?
        public init(manifest: HomebrewNativeLaunchServices.Manifest? = nil, failure: ReviewedToolFailure? = nil, unavailable: String? = nil) {
            version = 1; self.manifest = manifest; self.failure = failure; self.unavailable = unavailable
        }
    }
    public static func run(_ request: Request, isCancelled: @escaping () -> Bool = { false }) -> Response {
        do {
            guard request.version == 1, request.deadline.timeIntervalSince1970.isFinite,
                  request.deadline.timeIntervalSinceNow <= 30, getuid() == 0 || getuid() == request.context.uid else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            try request.context.validate()
            let capture = LaunchCapture(context: request.context, declarations: request.declarations,
                deadline: request.deadline, isCancelled: isCancelled)
            return .init(manifest: try capture.native())
        } catch PluginHostServiceError.tool(let failure) { return .init(failure: failure) }
        catch PluginHostServiceError.unavailable(let reason) { return .init(unavailable: String(reason.prefix(1024))) }
        catch { return .init(failure: .failed) }
    }
}

extension HomebrewNativeLaunchServices {
    /// Explicitly fixture-only seam: Root can never accept its manifest as
    /// native evidence, and the production CLI never accepts alternate roots.
    public static func captureOwnedFixture(context: Context, declarations: [Declaration], root: URL,
        jobs: [Job], deadline: Date) throws -> Manifest {
        guard getuid() != 0, context.uid == getuid() else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        try context.validate()
        let frozen = try NativeFileQuarantine.capture(root, deadline: deadline)
        guard frozen.directory, frozen.owner == getuid(), frozen.mode & 0o077 == 0, !frozen.writableACL else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let capture = LaunchCapture(context: context, declarations: declarations, deadline: deadline, isCancelled: { false })
        return try capture.fixture(root: root, jobs: jobs)
    }
    public static func validateNative(_ manifest: Manifest, context: Context, declarations: [Declaration]) throws {
        try context.validate()
        guard manifest.version == 1, manifest.evidence == .nativeReadOnly, manifest.context == context,
              manifest.declarations == declarations, manifest.entries.count <= 16,
              manifest.unmatched.allSatisfy(declarations.contains), manifest.coverage.count == 3,
              Set(manifest.coverage.map(\.scope)).count == 3,
              manifest.coverage.allSatisfy({ (0...4096).contains($0.fileCount) }),
              try LaunchCapture.seal(manifest) == manifest.sha256 else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        var seen: Set<String> = []
        for entry in manifest.entries {
            guard validLabel(entry.label), seen.insert(entry.domain.target + "/" + entry.label).inserted,
                  entry.plists.count <= 3, entry.retainedDomains.count <= 1,
                  entry.retainedDomains.allSatisfy({ entry.domain == .gui(context.uid) && $0 == .user(context.uid) }),
                  entry.domain == .system || entry.domain == .gui(context.uid) || entry.domain == .user(context.uid) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            for file in entry.plists {
                let root = LaunchCapture.root(file.scope, context: context)
                guard file.path.isFileURL, file.path.host == nil, file.path.query == nil, file.path.fragment == nil,
                      file.path.deletingLastPathComponent().path == root.path, file.path.pathExtension == "plist",
                      (entry.domain == .system ? file.scope != .userAgents : file.scope != .systemDaemons),
                      file.label == entry.label, !file.frozen.directory, !file.frozen.symbolicLink, file.frozen.links == 1,
                      file.frozen.owner == (file.scope == .userAgents ? context.uid : 0), file.frozen.mode & 0o022 == 0,
                      !file.frozen.writableACL, file.parent.directory, file.parent.owner == (file.scope == .userAgents ? context.uid : 0),
                      !file.parent.writableACL, file.parent.mode & 0o022 == 0,
                      !file.removeFile || file.path.lastPathComponent == entry.label + ".plist" else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            }
            if let job = entry.job {
                guard job.domain == entry.domain, job.label == entry.label, !job.program.isEmpty,
                      job.program.utf8.count <= 2048, job.program.hasPrefix("/"), !job.program.contains("\0"), job.state.utf8.count <= 128,
                      job.domain == .system || job.expectedUID == context.uid,
                      job.observedUID == nil || job.observedUID == job.expectedUID,
                      job.pid == nil || (job.pid! > 0 && job.startIdentity != nil && job.observedUID == job.expectedUID && job.processProgram != nil) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            } else { guard !entry.plists.isEmpty else { throw PluginHostServiceError.tool(.sourceNotAllowed) } }
        }
    }
}

private final class LaunchCapture {
    typealias Model = HomebrewNativeLaunchServices
    let context: Model.Context, declarations: [Model.Declaration], deadline: Date
    let cancelled: () -> Bool
    var commandBytes = 0
    init(context: Model.Context, declarations: [Model.Declaration], deadline: Date, isCancelled: @escaping () -> Bool) {
        self.context = context; self.declarations = declarations; self.deadline = deadline; cancelled = isCancelled
    }
    func check() throws {
        guard !cancelled() else { throw PluginHostServiceError.tool(.planChanged) }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        guard declarations.count <= 16, Set(declarations.map(\.pattern)).count == declarations.count else { throw PluginHostServiceError.tool(.outputTooLarge) }
    }
    static func root(_ scope: Model.Scope, context: Model.Context) -> URL {
        switch scope {
        case .systemDaemons: return URL(fileURLWithPath: "/Library/LaunchDaemons")
        case .systemAgents: return URL(fileURLWithPath: "/Library/LaunchAgents")
        case .userAgents: return context.home.appendingPathComponent("Library/LaunchAgents")
        }
    }
    func fixture(root: URL, jobs: [Model.Job]) throws -> Model.Manifest {
        try check()
        guard jobs.count <= 32, jobs.allSatisfy({ $0.domain == .system || $0.domain == .gui(context.uid) || $0.domain == .user(context.uid) }),
              Set(jobs.map { $0.domain.target + "/" + $0.label }).count == jobs.count else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        return try collect(evidence: .ownedFixture, roots: [.systemDaemons: root.appendingPathComponent("systemDaemons"), .systemAgents: root.appendingPathComponent("systemAgents"), .userAgents: root.appendingPathComponent("userAgents")], jobs: jobs,
            table: Dictionary(grouping: jobs, by: \.domain).mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0.label, $0.pid ?? 0) }) })
    }
    func native() throws -> Model.Manifest {
        try check()
        var tables: [Model.Domain: [String: Int32]] = [:]
        for domain in [Model.Domain.system, .gui(context.uid), .user(context.uid)] {
            let result = try command(["print", domain.target])
            guard result.status == 0 else { throw PluginHostServiceError.unavailable("Launch-service domain state is unavailable; no absence or removal authority was inferred") }
            tables[domain] = try table(result.data, domain: domain)
        }
        let roots = Dictionary(uniqueKeysWithValues: [Model.Scope.systemDaemons, .systemAgents, .userAgents].map { ($0, Self.root($0, context: context)) })
        return try collect(evidence: .nativeReadOnly, roots: roots, jobs: [], table: tables)
    }
    func collect(evidence: Model.Evidence, roots: [Model.Scope: URL], jobs: [Model.Job], table: [Model.Domain: [String: Int32]]) throws -> Model.Manifest {
        try check()
        var selected: Set<String> = []
        for declaration in declarations {
            if !declaration.wildcard { selected.insert(declaration.pattern) }
            else {
                for rows in table.values { for (label, pid) in rows where declaration.matches(label: label, pid: pid) { selected.insert(label) } }
            }
        }
        guard selected.count <= 16 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        var coverage: [Model.Coverage] = [], files: [String: [Model.Plist]] = [:]
        for scope in [Model.Scope.systemDaemons, .systemAgents, .userAgents] {
            try check(); let directory = roots[scope]!
            guard try NativeFileQuarantine.existsWithoutFollowing(directory) else {
                coverage.append(.init(scope: scope, directoryExists: false, fileCount: 0)); continue
            }
            let (parent, name) = try NativeFileQuarantine.openParent(directory); defer { close(parent) }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw PluginHostServiceError.tool(.sourceNotAllowed) }; defer { close(fd) }
            let before = try NativePathParentSnapshot.captureDirectoryDescriptor(fd, deadline: deadline)
            guard before.owner == (evidence == .ownedFixture || scope == .userAgents ? context.uid : 0), before.mode & 0o022 == 0, !before.writableACL else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            let names = try names(fd)
            coverage.append(.init(scope: scope, directoryExists: true, fileCount: names.count))
            for label in selected.sorted() where names.contains(label + ".plist") {
                let file = try plist(scope: scope, directory: directory, parent: fd, parentSnapshot: before, name: label + ".plist", label: label, fixture: evidence == .ownedFixture, remove: true)
                files[label, default: []].append(file)
            }
            guard try NativePathParentSnapshot.captureDirectoryDescriptor(fd, deadline: deadline) == before else { throw PluginHostServiceError.tool(.planChanged) }
        }
        var entries: [Model.Entry] = [], unmatched: [Model.Declaration] = []
        for label in selected.sorted() {
            let same = files[label] ?? []
            if table[.system]?[label] != nil || same.contains(where: { $0.scope == .systemDaemons }) {
                let scoped = same.filter { $0.scope == .systemDaemons || (table[.system]?[label] != nil && $0.scope == .systemAgents) }
                let state = try state(domain: .system, label: label, table: table, files: scoped, fixtureJobs: evidence == .ownedFixture ? jobs : nil, roots: roots)
                entries.append(.init(domain: .system, label: label, plists: state.plists, job: state.job, retainedDomains: []))
            }
            let gui = Model.Domain.gui(context.uid), user = Model.Domain.user(context.uid)
            let domain = table[gui]?[label] != nil ? gui : (table[user]?[label] != nil ? user : gui)
            let scoped = same.filter { $0.scope == .userAgents || (table[.system]?[label] == nil && $0.scope == .systemAgents) }
            if table[domain]?[label] != nil || !scoped.isEmpty {
                let state = try state(domain: domain, label: label, table: table, files: scoped, fixtureJobs: evidence == .ownedFixture ? jobs : nil, roots: roots)
                entries.append(.init(domain: domain, label: label, plists: state.plists, job: state.job, retainedDomains: domain == gui && table[user]?[label] != nil ? [user] : []))
            }
        }
        guard entries.count <= 16 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        for declaration in declarations where !entries.contains(where: { declaration.matches(label: $0.label, pid: $0.job?.pid ?? 0) }) { unmatched.append(declaration) }
        let blank = Model.Manifest(version: 1, evidence: evidence, context: context, declarations: declarations, entries: entries, unmatched: unmatched, coverage: coverage, sha256: "")
        return .init(version: 1, evidence: evidence, context: context, declarations: declarations, entries: entries, unmatched: unmatched, coverage: coverage, sha256: try Self.seal(blank))
    }
    static func seal(_ manifest: Model.Manifest) throws -> String {
        let blank = Model.Manifest(version: manifest.version, evidence: manifest.evidence, context: manifest.context, declarations: manifest.declarations, entries: manifest.entries, unmatched: manifest.unmatched, coverage: manifest.coverage, sha256: "")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return HomebrewSystemAuthorization.digest(try encoder.encode(blank))
    }
    func names(_ fd: Int32) throws -> Set<String> {
        let copy = dup(fd); guard copy >= 0 else { throw PluginHostServiceError.tool(.failed) }
        guard let stream = fdopendir(copy) else { close(copy); throw PluginHostServiceError.tool(.failed) }; defer { closedir(stream) }
        var result: Set<String> = [], count = 0
        while true {
            try check(); errno = 0; guard let entry = readdir(stream) else { guard errno == 0 else { throw PluginHostServiceError.tool(.failed) }; break }
            let length = Int(entry.pointee.d_namlen)
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { Data($0.prefix(length)) }
            guard let name = String(data: bytes, encoding: .utf8) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            if name == "." || name == ".." { continue }
            count += 1; guard count <= 4096 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            if name.hasSuffix(".plist") { result.insert(name) }
        }
        return result
    }
    func plist(scope: Model.Scope, directory: URL, parent: Int32, parentSnapshot: NativeFileQuarantine.Snapshot,
        name: String, label: String, fixture: Bool, remove: Bool) throws -> Model.Plist {
        try check()
        try proveParent(parent, directory: directory)
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PluginHostServiceError.tool(.sourceNotAllowed) }; defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 256 * 1024 else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try check(); let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
            guard bytes.count + count <= 256 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }; bytes.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              let value = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
              let actualLabel = value["Label"] as? String, actualLabel.utf8.elementsEqual(label.utf8) else { throw PluginHostServiceError.tool(.planChanged) }
        let program = (value["Program"] as? String) ?? ((value["ProgramArguments"] as? [String])?.first ?? "")
        guard program.hasPrefix("/"), program.utf8.count <= 2048, !program.contains("\0") else { throw PluginHostServiceError.unavailable("Launch-service program is not a concrete absolute executable") }
        let uid: uid_t
        if scope == .systemDaemons {
            if value["UserName"] != nil {
                guard let name = value["UserName"] as? String else { throw PluginHostServiceError.unavailable("Launch-service owner has an unknown type") }
                guard name.utf8.count <= 64, !name.contains("\0"), let account = getpwnam(name) else { throw PluginHostServiceError.unavailable("Launch-service owner could not be resolved") }
                uid = account.pointee.pw_uid
            } else { uid = 0 }
        } else { guard value["UserName"] == nil else { throw PluginHostServiceError.unavailable("Agent owner override is unsupported") }; uid = context.uid }
        let path = directory.appendingPathComponent(name), frozen = try NativeFileQuarantine.capture(path, deadline: deadline, isCancelled: cancelled)
        guard frozen.device == UInt64(before.st_dev), frozen.inode == UInt64(before.st_ino), frozen.sha256 == HomebrewSystemAuthorization.digest(bytes),
              frozen.owner == (fixture || scope == .userAgents ? context.uid : 0), frozen.mode & 0o022 == 0, !frozen.writableACL else { throw PluginHostServiceError.tool(.planChanged) }
        return .init(scope: scope, path: path, label: label, program: program, expectedUID: uid, removeFile: remove, frozen: frozen, parent: parentSnapshot)
    }
    func proveParent(_ fd: Int32, directory: URL) throws {
        try check()
        var fs = statfs(), status = stat()
        guard fstatfs(fd, &fs) == 0, fstat(fd, &status) == 0,
              withUnsafeBytes(of: fs.f_fstypename, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == "apfs",
              fs.f_flags & UInt32(MNT_UNION) == 0 else { throw PluginHostServiceError.unavailable("Selected launch configuration directory has no reviewed native alias proof") }
        struct Capabilities { var length: UInt32 = 0; var value = vol_capabilities_attr_t() }
        var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT); attributes.volattr = ATTR_VOL_INFO | UInt32(ATTR_VOL_CAPABILITIES)
        var capabilities = Capabilities(); let bit = UInt32(VOL_CAP_FMT_DIR_HARDLINKS)
        guard fgetattrlist(fd, &attributes, &capabilities, MemoryLayout<Capabilities>.size, 0) == 0,
              capabilities.length == MemoryLayout<Capabilities>.size, capabilities.value.valid.0 & bit != 0,
              capabilities.value.capabilities.0 & bit == 0 else { throw PluginHostServiceError.unavailable("Selected launch configuration directory may have native hardlink aliases") }
        var visible = [CChar](repeating: 0, count: Int(MAXPATHLEN)), physical = visible
        guard fcntl(fd, F_GETPATH, &visible) == 0, fcntl(fd, F_GETPATH_NOFIRMLINK, &physical) == 0 else { throw PluginHostServiceError.unavailable("Selected launch configuration directory endpoints are unavailable") }
        let names = [String(cString: visible), String(cString: physical)]
        let leaf = directory.lastPathComponent
        for path in names {
            var actual = stat()
            guard lstat(path, &actual) == 0, actual.st_dev == status.st_dev, actual.st_ino == status.st_ino,
                  URL(fileURLWithPath: path).lastPathComponent.utf8.elementsEqual(leaf.utf8) ||
                    NativeReceiptTopology.ascii(URL(fileURLWithPath: path).lastPathComponent) == NativeReceiptTopology.ascii(leaf) && NativeReceiptTopology.ascii(leaf) != nil else { throw PluginHostServiceError.tool(.planChanged) }
        }
        let mount = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var root = stat()
        guard lstat(mount, &root) == 0, root.st_dev != status.st_dev || root.st_ino != status.st_ino else { throw PluginHostServiceError.unavailable("Launch configuration directory is a native mount-root alias") }
    }
    func state(domain: Model.Domain, label: String, table: [Model.Domain: [String: Int32]], files: [Model.Plist], fixtureJobs: [Model.Job]?, roots: [Model.Scope: URL]) throws -> (job: Model.Job?, plists: [Model.Plist]) {
        guard let pid = table[domain]?[label] else { return (nil, files) }
        if let fixtureJobs {
            let expected = domain == .system ? (files.first(where: { $0.scope == .systemDaemons })?.expectedUID ?? 0) : context.uid
            guard let job = fixtureJobs.first(where: { $0.domain == domain && $0.label == label }), job.expectedUID == expected,
                  files.allSatisfy({ $0.program == job.program && (domain == .system && $0.scope == .systemAgents || $0.expectedUID == job.expectedUID) }) else { throw PluginHostServiceError.tool(.planChanged) }
            return (job, files)
        }
        let result = try command(["print", domain.target + "/" + label])
        guard result.status == 0, let text = String(data: result.data, encoding: .utf8), text.hasPrefix(domain.target + "/" + label + " = {\n") else { throw PluginHostServiceError.tool(.planChanged) }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.dropFirst().components(separatedBy: " = "); guard parts.count == 2 else { continue }
            let key = parts[0], value = parts[1]
            if ["program", "path", "pid", "state", "user id"].contains(key) { guard values[key] == nil else { throw PluginHostServiceError.tool(.planChanged) }; values[key] = value }
        }
        guard let program = values["program"], program.hasPrefix("/"), program.utf8.count <= 2048,
              let state = values["state"], state.utf8.count <= 128 else { throw PluginHostServiceError.unavailable("Registered launch-service program/identity is unavailable; no owner was guessed") }
        let origin = values["path"]?.hasPrefix("/") == true ? values["path"] : nil
        var ownedFiles = files
        if let origin {
            let url = URL(fileURLWithPath: origin)
            guard let scope = roots.first(where: { $0.value.path == url.deletingLastPathComponent().path })?.key, url.pathExtension == "plist" else { throw PluginHostServiceError.unavailable("Launch-service configuration is outside the declared cask launch roots") }
            if !ownedFiles.contains(where: { $0.path.path == url.path }) {
                let (parent, name) = try NativeFileQuarantine.openParent(url); defer { close(parent) }
                ownedFiles.append(try plist(scope: scope, directory: url.deletingLastPathComponent(), parent: parent,
                    parentSnapshot: NativePathParentSnapshot.captureDirectoryDescriptor(parent, deadline: deadline), name: name, label: label, fixture: false, remove: false))
            }
        }
        let expected = domain == .system ? (ownedFiles.first(where: { $0.scope == .systemDaemons })?.expectedUID ?? (ownedFiles.contains(where: { $0.scope == .systemAgents }) ? uid_t(0) : nil)) : context.uid
        guard let expected, ownedFiles.allSatisfy({ $0.program == program && (domain == .system && $0.scope == .systemAgents || $0.expectedUID == expected) }) else { throw PluginHostServiceError.unavailable("Launch-service program/owner differs from its concrete plist") }
        var observedUID: uid_t?, identity: UInt64?, processProgram: String?
        if let reported = values["user id"] {
            guard let uid = uid_t(reported), uid == expected else { throw PluginHostServiceError.tool(.planChanged) }
            observedUID = uid
        }
        if pid > 0 {
            guard values["pid"].flatMap(Int32.init) == pid, let before = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.planChanged) }
            // Public libproc.h defines PROC_PIDPATHINFO_MAXSIZE as 4*MAXPATHLEN.
            var info = proc_bsdinfo(), buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_uid == expected, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  HomebrewTaskProcess.startIdentity(pid) == before else { throw PluginHostServiceError.tool(.planChanged) }
            let path = String(cString: buffer)
            guard URL(fileURLWithPath: program).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path else { throw PluginHostServiceError.tool(.planChanged) }
            observedUID = info.pbi_uid; identity = before; processProgram = path
        } else { guard values["pid"] == nil || values["pid"] == "0" else { throw PluginHostServiceError.tool(.planChanged) } }
        return (.init(domain: domain, label: label, program: program, configurationPath: origin, expectedUID: expected,
            pid: pid > 0 ? pid : nil, startIdentity: identity, observedUID: observedUID, processProgram: processProgram, state: state), ownedFiles)
    }
    func table(_ data: Data, domain: Model.Domain) throws -> [String: Int32] {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(domain.target + " = {\n") else { throw PluginHostServiceError.unavailable("Unknown launch-service registry format") }
        var rows: [String: Int32] = [:], inside = false, found = false, closed = false, count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "\tservices = {" { guard !found else { throw PluginHostServiceError.tool(.planChanged) }; inside = true; found = true; continue }
            if inside, line == "\t}" { inside = false; closed = true; continue }
            guard inside else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), pid >= 0 else { throw PluginHostServiceError.unavailable("Unknown launch-service registry row") }
            count += 1; guard count <= 8192 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            let label = String(fields[2]); guard Model.validLabel(label) else { continue }
            guard rows[label] == nil else { throw PluginHostServiceError.tool(.planChanged) }; rows[label] = pid
        }
        guard found, closed else { throw PluginHostServiceError.unavailable("Launch-service registry enumeration was incomplete") }
        return rows
    }
    func command(_ arguments: [String]) throws -> (status: Int32, data: Data) {
        try check()
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"], groupPolicy: .inheritWorkerGroup)
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var bytes = Data(), result: HomebrewTaskProcess.Result?, oversized = false
        try process.start(output: { data in
            lock.lock(); if bytes.count + data.count > HomebrewNativeLaunchServiceInventory.maximumOutputBytes { oversized = true } else { bytes.append(data) }; let stop = oversized; lock.unlock()
            if stop { process.stop() }
        }, finished: { value in lock.lock(); result = value; lock.unlock(); done.signal() })
        while done.wait(timeout: .now() + 0.01) == .timedOut {
            if cancelled() || Date() >= deadline { process.stop(); throw PluginHostServiceError.tool(cancelled() ? .planChanged : .timedOut) }
        }
        lock.lock(); let output = bytes, finished = result, large = oversized; lock.unlock()
        commandBytes += output.count
        guard !large, commandBytes <= HomebrewNativeLaunchServiceInventory.maximumOutputBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        guard finished?.outcome == "completed", let status = finished?.exitStatus else { throw PluginHostServiceError.tool(.failed) }
        return (status, output)
    }
}
