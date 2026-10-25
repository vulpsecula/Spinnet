import Foundation
import Darwin
import Security

/// Fixed worker protocol for potentially blocking source/installed-file APIs.
/// Only the Host and authenticated Root helper construct this request. The
/// caller supervises the worker, its exact descendants and RSS until real reap.
public enum HomebrewNativeVendorOriginWorker {
    public static let maximumMessageBytes = 64 * 1024
    public enum Operation: Codable, Equatable {
        case vendorOrigin
        case sourceTree(HomebrewNativeSourceStaging.Purpose)
    }
    public struct Request: Codable {
        public let version: Int
        public let envelope: URL
        public let sourceSHA256: String
        public let projectionSHA256: String
        public let configuration: HomebrewSignedCaskCatalog.Configuration
        public let token: String
        public let recipeExecutable: String
        public let confirmedSnapshot: HomebrewNoCheckSnapshot.Result?
        public let originalDownload: URL
        public let staging: URL
        public let ownerUID: uid_t
        public let deadline: Date
        public let maximumBytes: Int64
        public let maximumEntries: Int
        public let operation: Operation?
        public init(envelope: URL, sourceSHA256: String, projectionSHA256: String,
                    configuration: HomebrewSignedCaskCatalog.Configuration, token: String,
                    recipeExecutable: String, confirmedSnapshot: HomebrewNoCheckSnapshot.Result? = nil,
                    originalDownload: URL, staging: URL, ownerUID: uid_t, deadline: Date,
                    maximumBytes: Int64 = 8 * 1024 * 1024 * 1024, maximumEntries: Int = 50_000,
                    operation: Operation? = nil) {
            version = 1; self.envelope = envelope; self.sourceSHA256 = sourceSHA256
            self.projectionSHA256 = projectionSHA256; self.configuration = configuration
            self.token = token; self.recipeExecutable = recipeExecutable; self.confirmedSnapshot = confirmedSnapshot
            self.originalDownload = originalDownload; self.staging = staging; self.ownerUID = ownerUID
            self.deadline = deadline; self.maximumBytes = maximumBytes
            self.maximumEntries = maximumEntries
            self.operation = operation
        }
    }
    public struct Response: Codable {
        public let version: Int
        public let proof: HomebrewNativeVendorOrigin.Proof?
        public let sourceTreeProof: HomebrewNativeSourceStaging.Proof?
        public let failure: ReviewedToolFailure?
        public let unavailable: String?
        public let recoveryDirectory: URL?
        public init(proof: HomebrewNativeVendorOrigin.Proof? = nil, sourceTreeProof: HomebrewNativeSourceStaging.Proof? = nil, failure: ReviewedToolFailure? = nil,
                    unavailable: String? = nil, recoveryDirectory: URL? = nil) {
            version = 1; self.proof = proof; self.sourceTreeProof = sourceTreeProof; self.failure = failure
            self.unavailable = unavailable; self.recoveryDirectory = recoveryDirectory
        }
    }
    /// Synchronous worker-side entry point. Never run it in Host/Root threads;
    /// use the fixed supervised executable. Development tests use owned files.
    public static func run(_ request: Request, toolsDirectory: URL,
                           isCancelled: @escaping () -> Bool = { false }) -> Response {
        do {
            func check() throws {
                guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
                guard Date() < request.deadline else { throw PluginHostServiceError.tool(.timedOut) }
            }
            guard request.version == 1, request.deadline.timeIntervalSince1970.isFinite,
                  request.deadline.timeIntervalSinceNow <= 180, request.maximumBytes > 0,
                  request.maximumBytes <= 8 * 1024 * 1024 * 1024,
                  (0...50_000).contains(request.maximumEntries),
                  request.ownerUID > 0, getuid() == 0 || request.ownerUID == getuid(),
                  HomebrewReadInput.validPackageName(request.token), !request.token.contains("/"),
                  request.recipeExecutable.utf8.count <= 2048,
                  [request.envelope, request.originalDownload, request.staging, toolsDirectory].allSatisfy(validFileURL),
                  validSHA(request.sourceSHA256), validSHA(request.projectionSHA256),
                  let account = getpwuid(request.ownerUID), let home = account.pointee.pw_dir else {
                throw PluginHostServiceError.tool(.planChanged)
            }
            let gid = account.pointee.pw_gid
            guard request.configuration.home.path == String(cString: home) else { throw PluginHostServiceError.tool(.planChanged) }
            try check()
            try validateStage(request.staging)
            // Native quarantine has already rejected arbitrary symlink
            // ancestors. Preserve the reviewed /tmp and /var physical aliases
            // when handing the fixed output tree to the strict archive seam.
            let staging = request.staging.resolvingSymlinksInPath()
            guard canonical(request.envelope) == canonical(request.staging.appendingPathComponent("homebrew-source.jws.json")) else {
                throw PluginHostServiceError.tool(.planChanged)
            }
            let source = try NativeFileQuarantine.capture(request.envelope, deadline: request.deadline, isCancelled: isCancelled)
            guard !source.directory, source.links == 1, source.owner == getuid(),
                  source.mode & 0o022 == 0, !source.writableACL, source.sha256 == request.sourceSHA256,
                  source.size <= HomebrewSignedCaskCatalog.maximumEnvelopeBytes else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            let evidence = try HomebrewSignedCaskCatalog.load(request.envelope, deadline: request.deadline)
            guard evidence.catalog.envelopeSHA256 == request.sourceSHA256,
                  try evidence.catalog.projectionDigest(request.token, configuration: request.configuration) == request.projectionSHA256,
                  try NativeFileQuarantine.capture(request.envelope, deadline: request.deadline, isCancelled: isCancelled) == source else {
                throw PluginHostServiceError.tool(.sourceNotAllowed)
            }
            let selection: HomebrewNativeVendorOrigin.Selection?
            let sourceSelection: HomebrewNativeSourceStaging.Selection?
            let downloadSHA: String
            switch request.operation ?? .vendorOrigin {
            case .vendorOrigin:
                let value = try HomebrewNativeVendorOrigin.select(evidence: evidence, configuration: request.configuration,
                    token: request.token, recipeExecutable: request.recipeExecutable, confirmedSnapshot: request.confirmedSnapshot)
                selection = value; sourceSelection = nil; downloadSHA = value.downloadSHA256
            case .sourceTree(let purpose):
                guard request.recipeExecutable.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
                let value = try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: request.configuration,
                    token: request.token, purpose: purpose, confirmedSnapshot: request.confirmedSnapshot)
                selection = nil; sourceSelection = value; downloadSHA = value.downloadSHA256
            }
            let download = try NativeFileQuarantine.capture(request.originalDownload, deadline: request.deadline, isCancelled: isCancelled)
            guard !download.directory, download.links == 1, download.owner == getuid() || download.owner == request.ownerUID, download.mode & 0o022 == 0,
                  !download.writableACL, download.size > 0, download.size <= 8 * 1024 * 1024 * 1024,
                  download.sha256 == downloadSHA else { throw PluginHostServiceError.tool(.planChanged) }
            if let confirmed = request.confirmedSnapshot {
                guard download.size == confirmed.byteCount else { throw PluginHostServiceError.tool(.planChanged) }
            }
            // The authenticated caller supplies the exact frozen source path.
            // Potentially blocking raw-source reads/copies happen only here,
            // under the outer fixed worker supervisor, never on a Root thread.
            let privateDownload = try copyDownload(request.originalDownload, snapshot: download,
                into: staging.appendingPathComponent("original-download"), deadline: request.deadline,
                maximumBytes: 8 * 1024 * 1024 * 1024, isCancelled: isCancelled)
            try check()
            if getuid() == 0 {
                let tools = try NativeFileQuarantine.capture(toolsDirectory, deadline: request.deadline, isCancelled: isCancelled)
                let path = canonical(toolsDirectory)
                guard path.hasPrefix("/private/var/tmp/spinnet-native-tools-"),
                      path.dropFirst("/private/var/tmp/".count).contains("/") == false,
                      tools.directory, tools.owner == 0, tools.mode & 0o066 == 0, !tools.writableACL else {
                    throw PluginHostServiceError.tool(.sourceNotAllowed)
                }
            }
            let bootstrap = toolsDirectory.appendingPathComponent("SpinnetArchiveBootstrap")
            for name in ["SpinnetArchiveBootstrap", "SpinnetArchiveDecoder"] {
                let binary = toolsDirectory.appendingPathComponent(name)
                let bytes = try NativeFileQuarantine.capture(binary, deadline: request.deadline, isCancelled: isCancelled)
                guard !bytes.directory, bytes.links == 1, bytes.owner == getuid(), bytes.mode & 0o022 == 0,
                      bytes.mode & 0o111 != 0, !bytes.writableACL else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                if getuid() == 0 {
                    let identifier = name == "SpinnetArchiveBootstrap" ? "archive-bootstrap" : "archive-decoder"
                    var code: SecStaticCode?, requirement: SecRequirement?
                    guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
                          SecRequirementCreateWithString(try HomebrewSystemAuthorization.requirement(identifier: "com.vulpsecula.SpinnetHost." + identifier) as CFString, [], &requirement) == errSecSuccess,
                          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
                        throw PluginHostServiceError.tool(.sourceNotAllowed)
                    }
                }
            }
            let response: Response
            let decoder = HomebrewArchiveStaging.DecoderConfiguration(bootstrap: bootstrap, uid: request.ownerUID, gid: gid)
            if let selection {
                response = .init(proof: try HomebrewNativeVendorOrigin.capture(selection, originalDownload: privateDownload,
                    into: staging, decoder: decoder, deadline: request.deadline, maximumBytes: request.maximumBytes,
                    maximumEntries: request.maximumEntries, isCancelled: isCancelled))
            } else if let sourceSelection {
                response = .init(sourceTreeProof: try HomebrewNativeSourceStaging.capture(sourceSelection, originalDownload: privateDownload,
                    into: staging, decoder: decoder, deadline: request.deadline, maximumBytes: request.maximumBytes,
                    maximumEntries: request.maximumEntries, isCancelled: isCancelled))
            } else { throw PluginHostServiceError.tool(.planChanged) }
            try check()
            // Retain raw PKG bytes only for the typed Installer artifact;
            // success otherwise needs no transient source/JWS copies. Both
            // retained raw bytes and expanded trees share the task budget.
            let (stageParent, stageName) = try NativeFileQuarantine.openParent(staging)
            defer { close(stageParent) }
            let stageFD = openat(stageParent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stageFD >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(stageFD) }
            guard try NativeFileQuarantine.capture(request.envelope, deadline: request.deadline, isCancelled: isCancelled) == source,
                  try NativeFileQuarantine.capture(privateDownload, deadline: request.deadline, isCancelled: isCancelled).sha256 == downloadSHA else {
                throw PluginHostServiceError.tool(.planChanged)
            }
            if let installerFile = response.sourceTreeProof?.installerFile {
                guard installerFile == "original-installer.pkg" else { throw PluginHostServiceError.tool(.planChanged) }
                let frozen = try NativeFileQuarantine.capture(privateDownload, deadline: request.deadline, isCancelled: isCancelled)
                let raw = openat(stageFD, "original-download", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard raw >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(raw) }
                var info = stat()
                guard fstat(raw, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(),
                      UInt64(info.st_dev) == frozen.device, UInt64(info.st_ino) == frozen.inode, info.st_size == frozen.size,
                      frozen.sha256 == downloadSHA, renameatx_np(stageFD, "original-download", stageFD, "original-installer.pkg", UInt32(RENAME_EXCL)) == 0 else {
                    throw PluginHostServiceError.tool(.planChanged)
                }
                let preserved = try NativeFileQuarantine.capture(staging.appendingPathComponent("original-installer.pkg"), deadline: request.deadline, isCancelled: isCancelled)
                guard preserved.device == frozen.device, preserved.inode == frozen.inode, preserved.size == frozen.size,
                      preserved.sha256 == downloadSHA, preserved.links == 1, preserved.owner == getuid() else { throw PluginHostServiceError.tool(.planChanged) }
            } else {
                guard unlinkat(stageFD, "original-download", 0) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
            }
            guard unlinkat(stageFD, "homebrew-source.jws.json", 0) == 0, fsync(stageFD) == 0 else {
                throw PluginHostServiceError.tool(.planChanged)
            }
            return response
        } catch let recovery as HomebrewNativeVendorImage.Recovery {
            return .init(unavailable: String(recovery.reason.prefix(1024)), recoveryDirectory: recovery.directory)
        } catch PluginHostServiceError.tool(let failure) { return .init(failure: failure) }
        catch PluginHostServiceError.unavailable(let message) { return .init(unavailable: String(message.prefix(1024))) }
        catch { return .init(failure: .failed) }
    }
    private static func validSHA(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
    private static func copyDownload(_ source: URL, snapshot: NativeFileQuarantine.Snapshot, into output: URL,
                                     deadline: Date, maximumBytes: Int64, isCancelled: () -> Bool) throws -> URL {
        let (parent, name) = try NativeFileQuarantine.openParent(source)
        defer { close(parent) }
        let input = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, UInt64(before.st_dev) == snapshot.device, UInt64(before.st_ino) == snapshot.inode,
              before.st_mode & S_IFMT == S_IFREG, before.st_uid == snapshot.owner,
              before.st_nlink == 1, before.st_size == snapshot.size else { throw PluginHostServiceError.tool(.planChanged) }
        let destination = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(destination) }
        var complete = false
        defer { if !complete { _ = unlink(output.path) } }
        var total: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
            total += Int64(count)
            guard total <= snapshot.size, total <= maximumBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += written
                }
            }
        }
        guard total == snapshot.size, fsync(destination) == 0, fchmod(destination, 0o400) == 0,
              try NativeFileQuarantine.capture(source, deadline: deadline, isCancelled: isCancelled) == snapshot,
              try NativeFileQuarantine.capture(output, deadline: deadline, isCancelled: isCancelled).sha256 == snapshot.sha256 else {
            throw PluginHostServiceError.tool(.planChanged)
        }
        complete = true; return output
    }
    private static func validFileURL(_ value: URL) -> Bool {
        value.isFileURL && (value.host == nil || value.host == "localhost") && value.user == nil && value.password == nil &&
        value.query == nil && value.fragment == nil && value.port == nil && value.path.hasPrefix("/") && value.path.utf8.count <= 2048 &&
        !value.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
        !value.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    private static func canonical(_ value: URL) -> String {
        let path = value.path
        if path.hasPrefix("/tmp/") || path.hasPrefix("/var/") { return "/private" + path }
        return path
    }
    private static func validateStage(_ directory: URL) throws {
        let path = canonical(directory)
        guard directory.isFileURL, path.utf8.count <= 2048,
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw PluginHostServiceError.tool(.planChanged) }
        let stage = try NativeFileQuarantine.capture(directory)
        guard stage.directory, stage.owner == getuid(), stage.mode & 0o077 == 0, !stage.writableACL else { throw PluginHostServiceError.tool(.planChanged) }
        if getuid() == 0 {
            guard path.hasPrefix("/private/var/tmp/spinnet-") else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            var current = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            for component in path.dropFirst("/private/var/tmp/".count).split(separator: "/") {
                current.appendPathComponent(String(component), isDirectory: true)
                let identity = try NativeFileQuarantine.capture(current)
                guard identity.directory, identity.owner == 0, identity.mode & 0o077 == 0,
                      !identity.writableACL else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            }
        }
    }
}
