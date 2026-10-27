import SpinnetCore
import Foundation
import Darwin

/// Fixed native kernel-extension selection. Bundle IDs select data manifests;
/// they never become shell arguments, Apple IDs, arbitrary paths or code grants.
public enum HomebrewNativeKextRemoval {
    /// Parse only fixed `kmutil showloaded --variant-suffix release
    /// --optional-identifier ID --list-only --no-kernel-components` output.
    /// Errors, changed formats or extra rows never become evidence of absence.
    public static func isLoaded(_ output: Data, identifier: String) throws -> Bool {
        guard validIdentifier(identifier), output.count <= 64 * 1024, let text = String(data: output, encoding: .utf8),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else { throw PluginHostServiceError.tool(.planChanged) }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count <= 1 else { throw PluginHostServiceError.tool(.planChanged) }
        guard let line = lines.first else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: identifier)
        let pattern = "^[0-9]+[ \\t]+[0-9]+[ \\t]+0x[0-9a-fA-F]+[ \\t]+0x[0-9a-fA-F]+[ \\t]+0x[0-9a-fA-F]+[ \\t]+" + escaped + "[ \\t]+\\([^\\s()]{1,128}\\)[ \\t]+[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(?:[ \\t]+<[0-9 \\t]*>)?$"
        guard line.range(of: pattern, options: .regularExpression) != nil else { throw PluginHostServiceError.tool(.planChanged) }
        return true
    }
    public static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 200 && value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*(?:\\.[A-Za-z0-9][A-Za-z0-9_-]*)+$", options: .regularExpression) != nil
            && !value.lowercased().hasPrefix("com.apple.") && value.lowercased() != "com.apple"
    }
    public struct Request: Codable {
        public let version: Int
        public let identifiers: [String]
        public let context: HomebrewPathManifest.Context
        public let deadline: Date
        public init(identifiers: [String], context: HomebrewPathManifest.Context, deadline: Date) {
            version = 1; self.identifiers = identifiers; self.context = context; self.deadline = deadline
        }
    }
    public struct Match: Codable, Equatable {
        public let identifier: String
        public let path: String
        public let infoSHA256: String
    }
    public struct Inventory: Codable, Equatable {
        public let identifiers: [String]
        public let context: HomebrewPathManifest.Context
        public let root: String
        public let matches: [Match]
        public let manifest: HomebrewPathManifest.Manifest?
        public let sha256: String
        public func validateSeal() throws {
            guard (1...16).contains(identifiers.count), Set(identifiers).count == identifiers.count, identifiers.allSatisfy(validIdentifier),
                  matches.count <= 128, Set(matches.map(\.path)).count == matches.count,
                  matches.allSatisfy({ identifiers.contains($0.identifier) && HomebrewPrivilegePlan.validDigest($0.infoSHA256)
                    && $0.path.hasPrefix(root + "/") && $0.path.dropFirst(root.count + 1).hasSuffix(".kext") && !$0.path.dropFirst(root.count + 1).contains("/") }),
                  matches.isEmpty == (manifest == nil), sha256 == (try Self.digest(identifiers: identifiers, context: context, root: root, matches: matches, manifestSHA256: manifest?.sha256)) else { throw PluginHostServiceError.tool(.planChanged) }
            if let manifest {
                try manifest.validateSeal()
                guard manifest.context == context, manifest.directives.count == 1, manifest.directives[0].kind == .delete,
                      manifest.directives[0].patterns == matches.map(\.path).sorted() else { throw PluginHostServiceError.tool(.planChanged) }
            }
        }
        fileprivate static func digest(identifiers: [String], context: HomebrewPathManifest.Context, root: String, matches: [Match], manifestSHA256: String?) throws -> String {
            struct Body: Encodable { let identifiers: [String]; let context: HomebrewPathManifest.Context; let root: String; let matches: [Match]; let manifestSHA256: String? }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return HomebrewSystemAuthorization.digest(try encoder.encode(Body(identifiers: identifiers, context: context, root: root, matches: matches, manifestSHA256: manifestSHA256)))
        }
    }
    public struct Response: Codable {
        public let version: Int
        public let inventory: Inventory?
        public let failure: ReviewedToolFailure?
        public let unavailable: String?
        public init(inventory: Inventory? = nil, failure: ReviewedToolFailure? = nil, unavailable: String? = nil) {
            version = 1; self.inventory = inventory; self.failure = failure; self.unavailable = unavailable
        }
    }
    public struct Grant: Codable, Equatable {
        public let identifiers: [String]
        public let context: HomebrewPathManifest.Context
        public let matches: [Match]
        public let paths: HomebrewNativePathGrant?
        public let sha256: String
        public var valid: Bool {
            (1...16).contains(identifiers.count) && Set(identifiers).count == identifiers.count && identifiers.allSatisfy(validIdentifier)
                && matches.count <= 128 && matches.allSatisfy { identifiers.contains($0.identifier) && $0.path.hasPrefix("/Library/Extensions/") && $0.path.hasSuffix(".kext") && HomebrewPrivilegePlan.validDigest($0.infoSHA256) }
                && matches.isEmpty == (paths == nil) && (paths == nil || paths!.context == context) && HomebrewPrivilegePlan.validDigest(sha256)
        }
        public func verify(_ inventory: Inventory) throws {
            try inventory.validateSeal()
            guard valid, inventory.root == "/Library/Extensions", inventory.identifiers == identifiers, inventory.context == context,
                  inventory.matches == matches, inventory.sha256 == sha256, inventory.manifest?.sha256 == paths?.manifestSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
        }
        public var confirmationDetails: String {
            "Unload only these non-Apple kernel extension IDs: " + identifiers.joined(separator: ", ") + ". Remove frozen matching bundles: " + matches.map(\.path).joined(separator: ", ") + ". macOS requires a restart for unloading; the Task remains incomplete until restart. Security policy may refuse unloading."
        }
    }
    public static func capture(identifiers: [String], context: HomebrewPathManifest.Context, worker: HomebrewPathManifest.WorkerConfiguration,
                               deadline: Date, isCancelled: @escaping () -> Bool = { false }) throws -> Inventory {
        let request = Request(identifiers: identifiers.sorted(), context: context, deadline: min(deadline, Date().addingTimeInterval(60)))
        try validate(request)
        let response = try NativePathInventorySupervisor.captureKext(request, worker: worker, isCancelled: isCancelled)
        guard response.version == 1, [response.inventory != nil, response.failure != nil, response.unavailable != nil].filter({ $0 }).count == 1 else { throw PluginHostServiceError.tool(.failed) }
        if let failure = response.failure { throw PluginHostServiceError.tool(failure) }
        if let message = response.unavailable { guard message.utf8.count <= 1024 else { throw PluginHostServiceError.tool(.failed) }; throw PluginHostServiceError.unavailable(message) }
        guard let inventory = response.inventory, inventory.root == "/Library/Extensions", inventory.context == context, inventory.identifiers == request.identifiers else { throw PluginHostServiceError.tool(.failed) }
        try inventory.validateSeal(); return inventory
    }
    public static func freeze(_ inventory: Inventory, in directory: URL) throws -> Grant {
        try inventory.validateSeal()
        guard inventory.root == "/Library/Extensions" else { throw PluginHostServiceError.tool(.planChanged) }
        let paths = try inventory.manifest.map { try HomebrewNativePathGrant.persist($0, in: directory) }
        let grant = Grant(identifiers: inventory.identifiers, context: inventory.context, matches: inventory.matches, paths: paths, sha256: inventory.sha256)
        guard grant.valid else { throw PluginHostServiceError.tool(.planChanged) }; return grant
    }
    /// Only the fixed supervised executable calls this production entry point.
    public static func inventoryInWorker(_ request: Request) throws -> Inventory {
        try inventory(request, root: URL(fileURLWithPath: "/Library/Extensions"))
    }
    /// Disposable native fixture proof cannot become a production Root grant.
    public static func inventoryInOwnedFixture(_ request: Request, root: URL) throws -> Inventory {
        guard getuid() != 0 else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let (parent, name) = try NativeFileQuarantine.openParent(root); defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        return try inventory(request, root: root)
    }
    private static func validate(_ request: Request) throws {
        guard request.version == 1, (1...16).contains(request.identifiers.count), Set(request.identifiers).count == request.identifiers.count,
              request.identifiers.allSatisfy(validIdentifier) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        guard Date() < request.deadline, request.deadline.timeIntervalSinceNow <= 60 else { throw PluginHostServiceError.tool(.timedOut) }
    }
    private static func inventory(_ request: Request, root: URL) throws -> Inventory {
        try validate(request)
        let (parent, basename) = try NativeFileQuarantine.openParent(root); defer { close(parent) }
        let fd = openat(parent, basename, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PluginHostServiceError.unavailable("Native kernel-extension inventory root is unavailable") }
        guard let directory = fdopendir(fd) else { close(fd); throw PluginHostServiceError.tool(.failed) }; defer { closedir(directory) }
        var matches: [Match] = [], inspected = 0
        while let entry = readdir(directory) {
            guard Date() < request.deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            inspected += 1; guard inspected <= 512 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            guard name.hasSuffix(".kext") else { continue }
            let bundle = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard bundle >= 0 else { throw PluginHostServiceError.unavailable("Kernel-extension inventory contains a linked or unavailable bundle") }; defer { close(bundle) }
            let content = openat(bundle, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            defer { if content >= 0 { close(content) } }
            if content < 0 && errno != ENOENT { throw PluginHostServiceError.tool(.planChanged) }
            let infoFile = openat(content >= 0 ? content : bundle, "Info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard infoFile >= 0 else { throw PluginHostServiceError.unavailable("A kernel-extension bundle has missing native identity metadata") }; defer { close(infoFile) }
            var before = stat(), after = stat()
            guard fstat(infoFile, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_size > 0, before.st_size <= 256 * 1024 else { throw PluginHostServiceError.tool(.planChanged) }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                guard Date() < request.deadline else { throw PluginHostServiceError.tool(.timedOut) }
                let count = Darwin.read(infoFile, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count)); guard data.count <= 256 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            }
            guard fstat(infoFile, &after) == 0, before.st_size == after.st_size, before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec, data.count == before.st_size,
                  let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let identifier = info["CFBundleIdentifier"] as? String else { throw PluginHostServiceError.tool(.planChanged) }
            if request.identifiers.contains(identifier) {
                guard matches.count < 128 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                matches.append(Match(identifier: identifier, path: root.appendingPathComponent(name).path, infoSHA256: HomebrewSystemAuthorization.digest(data)))
            }
        }
        matches.sort { $0.path < $1.path }
        let manifest: HomebrewPathManifest.Manifest?
        if matches.isEmpty { manifest = nil }
        else {
            let directive = try HomebrewPathManifest.Directive(kind: .delete, patterns: matches.map(\.path))
            manifest = try HomebrewPathManifest.inventoryInWorker(.init(context: request.context, directives: [directive], deadline: request.deadline))
        }
        return Inventory(identifiers: request.identifiers, context: request.context, root: root.path, matches: matches, manifest: manifest,
            sha256: try Inventory.digest(identifiers: request.identifiers, context: request.context, root: root.path, matches: matches, manifestSHA256: manifest?.sha256))
    }
}
