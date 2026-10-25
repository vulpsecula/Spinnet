import Foundation
import Darwin

/// Authenticated whole-source staging, without authority to execute or install.
/// Potentially blocking capture runs only inside the fixed supervised worker.
public enum HomebrewNativeSourceStaging {
    public enum Kind: String, Codable { case publisherChecksum, confirmedHostSnapshot }
    public enum Purpose: Codable, Equatable {
        case packageInstaller(path: String)
        case packageRemoval(path: String)
        case vendorInstaller(executable: String)
        case manualInstaller(path: String)
        case relativeRemoval(recipeExecutable: String)
        public var member: String {
            switch self {
            case .packageInstaller(let path), .packageRemoval(let path), .manualInstaller(let path): return path
            case .vendorInstaller(let executable), .relativeRemoval(let executable): return executable
            }
        }
    }
    public enum Container: String, Codable { case archive, package, diskImage }
    public struct Selection {
        public let kind: Kind
        public let token: String
        public let version: String
        public let sourceURL: URL
        public let downloadSHA256: String
        public let sourceSHA256: String
        public let projectionSHA256: String
        public let configurationSHA256: String
        public let purpose: Purpose
        public let selectedMember: String
        /// A raw download may stand for only one exact signed installation
        /// artifact; multiple declarations need concrete source members.
        public let rawInstallerArtifact: String?
        let generatedResource: Bool
    }
    public struct Proof: Codable, Equatable {
        public let kind: Kind
        public let token: String
        public let version: String
        public let sourceSHA256: String
        public let projectionSHA256: String
        public let configurationSHA256: String
        public let downloadSHA256: String
        public let purpose: Purpose
        public let selectedMember: String
        public let container: Container
        public let resourceDirectory: String
        public let installerFile: String?
        public let resourceTreeSHA256: String
        public let expandedBytes: Int64
        public let expandedEntries: Int
    }
    public static func select(evidence: HomebrewSignedCaskCatalog.Evidence,
        configuration: HomebrewSignedCaskCatalog.Configuration, token: String, purpose: Purpose,
        confirmedSnapshot: HomebrewNoCheckSnapshot.Result? = nil) throws -> Selection {
        guard HomebrewReadInput.validPackageName(token), !token.contains("/"), purpose.member.utf8.count <= 2048,
              !purpose.member.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PluginHostServiceError.tool(.planChanged) }
        let metadata = try evidence.catalog.project(token, configuration: configuration)
        guard case .string(let version)? = metadata["version"], case .string(let text)? = metadata["url"],
              let sourceURL = URL(string: text), sourceURL.scheme == "https", sourceURL.host != nil,
              sourceURL.user == nil, sourceURL.password == nil, case .string(let checksum)? = metadata["sha256"],
              case .array(let artifacts)? = metadata["artifacts"], artifacts.count <= 128 else { throw PluginHostServiceError.tool(.planChanged) }
        let selectedMember: String
        if case .relativeRemoval(let recipe) = purpose, recipe.hasPrefix("/") {
            let staged = configuration.prefix.path + "/Caskroom/" + token + "/" + version + "/"
            if recipe.hasPrefix(staged) { selectedMember = String(recipe.dropFirst(staged.count)) }
            else {
                var candidates: [String] = []
                for artifact in artifacts {
                    guard case .array(let values)? = artifact.value(atPointer: "/app"), case .string(let source)? = values.first else { continue }
                    let target: String
                    if values.count > 1, case .string(let declared)? = values[1].value(atPointer: "/target") { target = declared }
                    else { target = URL(fileURLWithPath: source).lastPathComponent }
                    guard HomebrewArchiveStaging.validRelativePath(source), HomebrewArchiveStaging.validRelativePath(target), !target.contains("/") else { throw PluginHostServiceError.tool(.planChanged) }
                    let prefix = configuration.appDirectory.path + "/" + target + "/"
                    if recipe.hasPrefix(prefix) { candidates.append(source + "/" + recipe.dropFirst(prefix.count)) }
                }
                guard candidates.count == 1, let member = candidates.first else { throw PluginHostServiceError.unavailable("Absolute installed program needs an independently byte-matched vendor origin") }
                selectedMember = member
            }
        } else { selectedMember = purpose.member }
        guard HomebrewArchiveStaging.validRelativePath(selectedMember) else { throw PluginHostServiceError.tool(.planChanged) }
        var generated: [String: String] = [:], generatedBytes = 0
        for artifact in artifacts {
            guard let declaration = artifact.value(atPointer: "/generated_script") else { continue }
            guard case .array(let values) = declaration, values.count == 2, case .string(let path) = values[0],
                  case .string(let body)? = values[1].value(atPointer: "/content"), HomebrewArchiveStaging.validRelativePath(path),
                  !body.isEmpty, body.utf8.count <= 256 * 1024, !body.contains("\0"), generated[path] == nil,
                  generated.count < 32 else { throw PluginHostServiceError.tool(.planChanged) }
            generatedBytes += body.utf8.count
            guard generatedBytes <= 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            generated[path] = body
        }
        var declared = false
        for artifact in artifacts {
            switch purpose {
            case .packageInstaller(let path):
                if case .array(let values)? = artifact.value(atPointer: "/pkg"), values.first == .string(path) { declared = true }
            case .vendorInstaller(let executable):
                if case .array(let values)? = artifact.value(atPointer: "/installer") {
                    declared = declared || values.contains { $0.value(atPointer: "/script/executable") == .string(executable) && $0.value(atPointer: "/script/sudo") == .bool(true) }
                }
            case .manualInstaller(let path):
                if case .array(let values)? = artifact.value(atPointer: "/installer") { declared = declared || values.contains { $0.value(atPointer: "/manual") == .string(path) } }
            case .relativeRemoval(let executable):
                for phase in ["uninstall", "zap"] {
                    if case .array(let values)? = artifact.value(atPointer: "/" + phase) {
                        for value in values { for name in ["script", "early_script"] {
                            if value.value(atPointer: "/" + name + "/executable") == .string(executable),
                               value.value(atPointer: "/" + name + "/sudo") == .bool(true) { declared = true }
                        } }
                    }
                }
            case .packageRemoval(let path):
                for phase in ["uninstall", "zap"] {
                    if case .array(let values)? = artifact.value(atPointer: "/" + phase) {
                        for value in values { for name in ["script", "early_script"] {
                            guard case .object(let options)? = value.value(atPointer: "/" + name),
                                  options["executable"] == .string("/usr/sbin/installer"), options["sudo"] == .bool(true) else { continue }
                            guard Set(options.keys).isSubset(of: ["executable", "args", "input", "must_succeed", "sudo", "print_stdout", "print_stderr"]),
                                  ["must_succeed", "sudo", "print_stdout", "print_stderr"].allSatisfy({ options[$0] == nil || options[$0] == .bool(true) || options[$0] == .bool(false) }),
                                  options["input"] == nil, ["pkg", "mpkg"].contains(URL(fileURLWithPath: path).pathExtension),
                                  case .array(let arguments)? = options["args"], arguments.count == 4,
                                  arguments[0] == .string("-pkg"), arguments[2] == .string("-target"), arguments[3] == .string("/"),
                                  case .string(let package) = arguments[1] else {
                                throw PluginHostServiceError.unavailable("Signed uninstall package needs exact typed installer arguments and source-bound options")
                            }
                            let staged = configuration.prefix.path + "/Caskroom/" + token + "/" + version + "/"
                            guard package.hasPrefix(staged), HomebrewArchiveStaging.validRelativePath(String(package.dropFirst(staged.count))),
                                  ["pkg", "mpkg"].contains(URL(fileURLWithPath: package).pathExtension) else { throw PluginHostServiceError.tool(.planChanged) }
                            if package == staged + path { declared = true }
                        } }
                    }
                }
            }
        }
        guard declared else { throw PluginHostServiceError.unavailable("Independently signed source does not declare this native staging purpose") }
        let projection = try evidence.catalog.projectionDigest(token, configuration: configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let configurationSHA = HomebrewSystemAuthorization.digest(try encoder.encode(configuration))
        let kind: Kind, downloadSHA: String
        if HomebrewPrivilegePlan.validDigest(checksum) {
            guard confirmedSnapshot == nil else { throw PluginHostServiceError.tool(.planChanged) }
            kind = .publisherChecksum; downloadSHA = checksum
        } else {
            guard checksum == "no_check", let frozen = confirmedSnapshot, frozen.sourceURL == sourceURL,
                  frozen.sourceSHA256 == evidence.catalog.envelopeSHA256, frozen.projectionSHA256 == projection,
                  frozen.configurationSHA256 == configurationSHA, HomebrewPrivilegePlan.validDigest(frozen.sha256),
                  (1...HomebrewNoCheckSnapshot.maximumBytes).contains(frozen.byteCount) else {
                throw PluginHostServiceError.unavailable("Native staging requires the exact independently signed URL and pre-confirmation frozen no_check snapshot")
            }
            kind = .confirmedHostSnapshot; downloadSHA = frozen.sha256
        }
        if case .relativeRemoval = purpose, kind == .confirmedHostSnapshot, generated[selectedMember] == nil {
            throw PluginHostServiceError.unavailable("No_check vendor removal requires an independently installed-byte-matched origin")
        }
        var installationPackages: [String] = []
        for artifact in artifacts {
            guard let declaration = artifact.value(atPointer: "/pkg") else { continue }
            guard case .array(let values) = declaration, case .string(let path)? = values.first,
                  HomebrewArchiveStaging.validRelativePath(path), installationPackages.count < 32 else { throw PluginHostServiceError.tool(.planChanged) }
            installationPackages.append(path)
        }
        let rawInstallerArtifact: String?
        switch purpose {
        case .packageInstaller, .packageRemoval:
            rawInstallerArtifact = installationPackages.count == 1 && installationPackages.first == purpose.member ? purpose.member : nil
        default: rawInstallerArtifact = nil
        }
        return .init(kind: kind, token: token, version: version, sourceURL: sourceURL, downloadSHA256: downloadSHA,
            sourceSHA256: evidence.catalog.envelopeSHA256, projectionSHA256: projection, configurationSHA256: configurationSHA, purpose: purpose, selectedMember: selectedMember,
            rawInstallerArtifact: rawInstallerArtifact, generatedResource: generated[selectedMember] != nil)
    }
    public static func capture(_ selection: Selection, originalDownload: URL, into directory: URL,
        decoder: HomebrewArchiveStaging.DecoderConfiguration, deadline: Date, maximumBytes: Int64 = 8 * 1024 * 1024 * 1024,
        maximumEntries: Int = 50_000, isCancelled: @escaping () -> Bool = { false }) throws -> Proof {
        let kind = try bodyKind(originalDownload, deadline: deadline, isCancelled: isCancelled)
        let retainInstaller: Bool
        switch selection.purpose {
        case .packageInstaller, .packageRemoval: retainInstaller = kind == .package && selection.rawInstallerArtifact != nil
        default: retainInstaller = false
        }
        let retainedBytes: Int64, retainedEntries: Int
        if retainInstaller {
            let raw = try NativeFileQuarantine.capture(originalDownload, deadline: deadline, isCancelled: isCancelled)
            guard !raw.directory, raw.owner == getuid(), raw.links == 1, !raw.writableACL, raw.mode & 0o022 == 0,
                  raw.size > 0, raw.sha256 == selection.downloadSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
            guard raw.size < maximumBytes, maximumEntries > 0 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            retainedBytes = raw.size; retainedEntries = 1
        } else { retainedBytes = 0; retainedEntries = 0 }
        // Transient inputs have their own cap. A raw PKG retained for Installer
        // is output authority and shares the Root task's total resource budget.
        var budget = try HomebrewNativeSourceBudget(maximumBytes: maximumBytes - retainedBytes, maximumEntries: maximumEntries - retainedEntries)
        let tree: HomebrewArchiveStaging.SealedTree, container: Container
        if kind == .unknown, try HomebrewNativeVendorImage.identifiesVerified(originalDownload, checksum: selection.downloadSHA256,
            deadline: deadline, maximumBytes: maximumBytes, isCancelled: isCancelled) {
            container = .diskImage
            tree = try HomebrewNativeVendorImage.extractVerified(originalDownload, checksum: selection.downloadSHA256,
                into: directory.appendingPathComponent("original"), deadline: deadline, maximumBytes: budget.remainingBytes,
                maximumEntries: budget.remainingEntries, isCancelled: isCancelled)
        } else {
            container = kind == .package ? .package : .archive
            tree = try HomebrewArchiveStaging.extractVerified(originalDownload, checksum: selection.downloadSHA256,
                into: directory.appendingPathComponent("original"), selected: ".", decoder: decoder, deadline: deadline,
                maximumBytes: budget.remainingBytes, maximumEntries: budget.remainingEntries, isCancelled: isCancelled)
        }
        try budget.consume(tree, deadline: deadline, isCancelled: isCancelled)
        switch selection.purpose {
        case .packageInstaller:
            // A raw flat/product package is the signed source itself. Otherwise
            // its declared member must exist in the immutable original tree.
            if !retainInstaller { try requireMember(selection.selectedMember, tree: tree, deadline: deadline, isCancelled: isCancelled) }
        case .packageRemoval:
            if !retainInstaller { try requireMember(selection.selectedMember, tree: tree, deadline: deadline, isCancelled: isCancelled) }
        case .manualInstaller:
            try requireMember(selection.selectedMember, tree: tree, deadline: deadline, isCancelled: isCancelled)
        case .relativeRemoval:
            if !selection.generatedResource { try requireMember(selection.selectedMember, tree: tree, deadline: deadline, isCancelled: isCancelled) }
        case .vendorInstaller:
            // Generated bodies are independently reviewed/bound by Root's code
            // grant; staging only freezes their signed original resource tree.
            break
        }
        guard try HomebrewArchiveStaging.fingerprint(tree.selectedURL, maximumBytes: maximumBytes, deadline: deadline, isCancelled: isCancelled) == tree.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
        return .init(kind: selection.kind, token: selection.token, version: selection.version,
            sourceSHA256: selection.sourceSHA256, projectionSHA256: selection.projectionSHA256,
            configurationSHA256: selection.configurationSHA256, downloadSHA256: selection.downloadSHA256,
            purpose: selection.purpose, selectedMember: selection.selectedMember, container: container, resourceDirectory: "original",
            installerFile: retainInstaller ? "original-installer.pkg" : nil, resourceTreeSHA256: tree.sha256,
            expandedBytes: budget.usedBytes + retainedBytes, expandedEntries: budget.usedEntries + retainedEntries)
    }
    private static func requireMember(_ member: String, tree: HomebrewArchiveStaging.SealedTree, deadline: Date, isCancelled: () -> Bool) throws {
        guard !isCancelled(), Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        guard try NativeFileQuarantine.existsWithoutFollowing(tree.selectedURL.appendingPathComponent(member)) else {
            throw PluginHostServiceError.unavailable("Signed native artifact is absent from the immutable source tree")
        }
    }
    private enum BodyKind { case archive, package, unknown }
    private static func bodyKind(_ source: URL, deadline: Date, isCancelled: () -> Bool) throws -> BodyKind {
        guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        let (parent, name) = try NativeFileQuarantine.openParent(source); defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(fd) }
        var info = stat(), bytes = [UInt8](repeating: 0, count: 512)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let count = pread(fd, &bytes, bytes.count, 0); guard count > 0 else { throw PluginHostServiceError.tool(.failed) }
        let prefix = Array(bytes.prefix(count))
        if prefix.starts(with: Array("xar!".utf8)) { return .package }
        if prefix.starts(with: [0x50,0x4b]) || prefix.starts(with: [0x1f,0x8b]) || prefix.starts(with: Array("BZh".utf8)) ||
            prefix.starts(with: [0xfd,0x37,0x7a,0x58,0x5a,0]) || prefix.starts(with: Array("pbzx".utf8)) ||
            ["070707", "070701", "070702"].contains(where: { prefix.starts(with: Array($0.utf8)) }) ||
            (count >= 262 && Array(prefix[257..<262]) == Array("ustar".utf8)) { return .archive }
        return .unknown
    }
}
