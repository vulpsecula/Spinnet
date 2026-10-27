import SpinnetCore
import Foundation
import Darwin

/// Code origin is a byte match to a selected immutable download member. This
/// data-only comparison cannot itself grant publisher or administrator authority.
/// Run native reads inside a fixed supervised worker, never the Host UI thread.
public enum HomebrewNativeVendorOrigin {
    public enum Kind: String, Codable { case publisherChecksum, confirmedHostSnapshotMatch }
    public struct Selection {
        public let kind: Kind
        public let token: String
        public let version: String
        public let sourceURL: URL
        public let downloadSHA256: String
        public let sourceSHA256: String
        public let projectionSHA256: String
        public let configurationSHA256: String
        public let recipeExecutable: String
        public let installedURL: URL
        public let member: String?
        public let packages: [String]
    }
    public struct Proof: Codable, Equatable {
        public let kind: Kind
        public let token: String
        public let version: String
        public let sourceSHA256: String
        public let projectionSHA256: String
        public let configurationSHA256: String
        public let downloadSHA256: String
        public let recipeExecutable: String
        public let archiveTreeSHA256: String
        public let match: Match
        public let package: String?
        public let component: String?
        public let resourceDirectory: String
        public let expandedBytes: Int64
        public let expandedEntries: Int
        public let packageInfoSHA256: String?
        public let payloadSHA256: String?
        public let installLocation: String?
    }
    public struct Match: Codable, Equatable {
        public let member: String
        public let resolvedMember: String
        public let executableSHA256: String
        public let installed: NativeFileQuarantine.Snapshot
        public let resourceTreeSHA256: String
    }
    public struct PackagePayload {
        public let tree: HomebrewArchiveStaging.SealedTree
        public let installLocation: String
        public let packageInfoSHA256: String
        public let payloadSHA256: String
    }
    public struct ComponentPayload {
        public let component: String?
        public let resourceDirectory: String
        public let payload: PackagePayload
    }
    public struct ComponentMatch {
        public let component: ComponentPayload
        public let match: Match
    }
    /// Root calls this with its independently verified retained publisher
    /// envelope and frozen effective configuration. Selection has no public
    /// initializer/decoder, so raw installed JSON cannot manufacture authority.
    /// A no_check Result must be the exact pre-confirmation Host journal value;
    /// this method never downloads/reconfirms a latest body as historical bytes.
    public static func select(evidence: HomebrewSignedCaskCatalog.Evidence,
                              configuration: HomebrewSignedCaskCatalog.Configuration, token: String,
                              recipeExecutable: String, confirmedSnapshot: HomebrewNoCheckSnapshot.Result? = nil) throws -> Selection {
        guard !token.contains("/"), HomebrewReadInput.validPackageName(token), recipeExecutable.utf8.count <= 2048,
              !recipeExecutable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PluginHostServiceError.tool(.planChanged) }
        let metadata = try evidence.catalog.project(token, configuration: configuration)
        let projection = try evidence.catalog.projectionDigest(token, configuration: configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let configDigest = HomebrewSystemAuthorization.digest(try encoder.encode(configuration))
        guard case .string(let version)? = metadata["version"], case .string(let text)? = metadata["url"],
              let url = URL(string: text), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              case .string(let checksum)? = metadata["sha256"], case .array(let artifacts)? = metadata["artifacts"], artifacts.count <= 128 else { throw PluginHostServiceError.tool(.planChanged) }
        let kind: Kind, downloadSHA: String
        if HomebrewPrivilegePlan.validDigest(checksum) {
            guard confirmedSnapshot == nil else { throw PluginHostServiceError.tool(.planChanged) }
            kind = .publisherChecksum; downloadSHA = checksum
        } else {
            guard checksum == "no_check", let frozen = confirmedSnapshot,
                  frozen.sourceURL == url, frozen.sourceSHA256 == evidence.catalog.envelopeSHA256,
                  frozen.projectionSHA256 == projection, frozen.configurationSHA256 == configDigest,
                  HomebrewPrivilegePlan.validDigest(frozen.sha256), (1...HomebrewNoCheckSnapshot.maximumBytes).contains(frozen.byteCount) else { throw PluginHostServiceError.unavailable("No exact pre-confirmation snapshot authority exists for this no_check vendor source") }
            kind = .confirmedHostSnapshotMatch; downloadSHA = frozen.sha256
        }
        var declared = false, packages: [String] = [], mappings: [(String, String)] = []
        for artifact in artifacts {
            if case .array(let values)? = artifact.value(atPointer: "/pkg"), case .string(let path)? = values.first {
                guard HomebrewArchiveStaging.validRelativePath(path), packages.count < 32 else { throw PluginHostServiceError.tool(.planChanged) }; packages.append(path)
            }
            if case .array(let values)? = artifact.value(atPointer: "/app"), case .string(let source)? = values.first {
                let target: String
                if values.count > 1, case .string(let explicit)? = values[1].value(atPointer: "/target") { target = explicit }
                else { target = URL(fileURLWithPath: source).lastPathComponent }
                guard HomebrewArchiveStaging.validRelativePath(source), HomebrewArchiveStaging.validRelativePath(target), !target.contains("/") else { throw PluginHostServiceError.tool(.planChanged) }
                mappings.append((configuration.appDirectory.path + "/" + target + "/", source + "/"))
            }
            for phase in ["uninstall", "zap"] {
                if case .array(let values)? = artifact.value(atPointer: "/" + phase) {
                    for value in values {
                        for name in ["script", "early_script"] {
                            if value.value(atPointer: "/" + name + "/executable") == .string(recipeExecutable),
                               value.value(atPointer: "/" + name + "/sudo") == .bool(true) { declared = true }
                        }
                    }
                }
            }
        }
        guard declared, recipeExecutable != "/usr/sbin/installer" else { throw PluginHostServiceError.unavailable("Publisher metadata does not declare this native vendor executable") }
        let staged = configuration.prefix.path + "/Caskroom/" + token + "/" + version + "/"
        let installed: URL, member: String?
        if !recipeExecutable.hasPrefix("/") {
            guard HomebrewArchiveStaging.validRelativePath(recipeExecutable) else { throw PluginHostServiceError.tool(.planChanged) }
            installed = URL(fileURLWithPath: staged + recipeExecutable); member = recipeExecutable
        } else {
            guard absolute(recipeExecutable) else { throw PluginHostServiceError.tool(.planChanged) }
            installed = URL(fileURLWithPath: recipeExecutable)
            if recipeExecutable.hasPrefix(staged) { member = String(recipeExecutable.dropFirst(staged.count)) }
            else {
                let matching = mappings.filter { recipeExecutable.hasPrefix($0.0) }
                guard matching.count <= 1 else { throw PluginHostServiceError.tool(.planChanged) }
                if let map = matching.first { member = map.1 + recipeExecutable.dropFirst(map.0.count) }
                else { member = nil }
            }
        }
        guard member.map(HomebrewArchiveStaging.validRelativePath) ?? !packages.isEmpty else { throw PluginHostServiceError.unavailable("Immutable original source is missing for this absolute installed program") }
        return .init(kind: kind, token: token, version: version, sourceURL: url, downloadSHA256: downloadSHA,
                     sourceSHA256: evidence.catalog.envelopeSHA256, projectionSHA256: projection, configurationSHA256: configDigest,
                     recipeExecutable: recipeExecutable, installedURL: installed, member: member, packages: packages)
    }
    public static func select(snapshot: HomebrewPrivilegeMetadata.Snapshot, recipeExecutable: String,
                              confirmedSnapshot: HomebrewNoCheckSnapshot.Result? = nil) throws -> Selection {
        guard let evidence = snapshot.officialEvidence, let configuration = snapshot.configuration,
              case .string(let name)? = snapshot.metadata["name"], name.hasPrefix("homebrew/cask/") else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let token = String(name.dropFirst("homebrew/cask/".count))
        try evidence.catalog.validate(snapshot.metadata, token: token, configuration: configuration)
        return try select(evidence: evidence, configuration: configuration, token: token, recipeExecutable: recipeExecutable, confirmedSnapshot: confirmedSnapshot)
    }
    /// Verify original download bytes before any installed program comparison.
    /// Root supplies a private task directory and its sealed decoder siblings.
    public static func capture(_ selection: Selection, originalDownload: URL, into directory: URL,
                               decoder: HomebrewArchiveStaging.DecoderConfiguration, deadline: Date,
                               maximumBytes: Int64 = 8 * 1024 * 1024 * 1024,
                               maximumEntries: Int = 50_000,
                               isCancelled: @escaping () -> Bool = { false }) throws -> Proof {
        var budget = try HomebrewNativeSourceBudget(maximumBytes: maximumBytes, maximumEntries: maximumEntries)
        let tree: HomebrewArchiveStaging.SealedTree
        let sourceKind = try sourceKind(originalDownload, deadline: deadline)
        let image = sourceKind == .unknown ? try HomebrewNativeVendorImage.identifiesVerified(originalDownload, checksum: selection.downloadSHA256,
            deadline: deadline, maximumBytes: maximumBytes, isCancelled: isCancelled) : false
        if image {
            tree = try HomebrewNativeVendorImage.extractVerified(originalDownload, checksum: selection.downloadSHA256,
                into: directory.appendingPathComponent("original"), deadline: deadline, maximumBytes: maximumBytes, maximumEntries: budget.remainingEntries, isCancelled: isCancelled)
        } else {
            tree = try HomebrewArchiveStaging.extractVerified(originalDownload, checksum: selection.downloadSHA256,
                into: directory.appendingPathComponent("original"), selected: ".", decoder: decoder, deadline: deadline,
                maximumBytes: maximumBytes, maximumEntries: budget.remainingEntries, isCancelled: isCancelled)
        }
        try budget.consume(tree, deadline: deadline, isCancelled: isCancelled)
        let match: Match
        var selectedPackage: String?, selectedComponent: String?, infoSHA: String?, payloadSHA: String?, location: String?
        var resourceDirectory = "original"
        if let member = selection.member {
            match = try compareMember(tree, member: member, installed: selection.installedURL, deadline: deadline, maximumBytes: maximumBytes, isCancelled: isCancelled)
        } else {
            var candidates: [(String, ComponentMatch)] = []
            for (index, package) in selection.packages.enumerated() {
                let packaged: HomebrewArchiveStaging.SealedTree
                if sourceKind == .xar, selection.packages.count == 1 { packaged = tree }
                else {
                    let url = tree.selectedURL.appendingPathComponent(package)
                    let frozen = try NativeFileQuarantine.capture(url, deadline: deadline)
                    if frozen.directory { packaged = .init(selectedURL: url, sha256: try HomebrewArchiveStaging.fingerprint(url, maximumBytes: maximumBytes, deadline: deadline, isCancelled: isCancelled)) }
                    else {
                        guard budget.remainingBytes > 0 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                        packaged = try HomebrewArchiveStaging.extractVerified(url, checksum: frozen.sha256, into: directory.appendingPathComponent("package-\(index)"), selected: ".", decoder: decoder, deadline: deadline, maximumBytes: budget.remainingBytes, maximumEntries: budget.remainingEntries, isCancelled: isCancelled)
                        try budget.consume(packaged, deadline: deadline, isCancelled: isCancelled)
                    }
                }
                let components = try extractPackagePayloads(packaged, into: directory, artifactIndex: index, decoder: decoder,
                    deadline: deadline, budget: &budget, isCancelled: isCancelled)
                let matches = try matchingComponents(components, installed: selection.installedURL, deadline: deadline,
                    maximumBytes: maximumBytes, isCancelled: isCancelled)
                candidates.append(contentsOf: matches.map { (package, $0) })
            }
            guard candidates.count == 1, let candidate = candidates.first else { throw PluginHostServiceError.unavailable("Original package payload does not unambiguously contain this installed executable; installer-generated code requires reviewed generator provenance") }
            match = candidate.1.match
            let component = candidate.1.component
            selectedPackage = candidate.0; selectedComponent = component.component; resourceDirectory = component.resourceDirectory
            infoSHA = component.payload.packageInfoSHA256; payloadSHA = component.payload.payloadSHA256; location = component.payload.installLocation
        }
        guard try HomebrewArchiveStaging.fingerprint(tree.selectedURL, maximumBytes: maximumBytes, deadline: deadline, isCancelled: isCancelled) == tree.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
        return .init(kind: selection.kind, token: selection.token, version: selection.version, sourceSHA256: selection.sourceSHA256,
                     projectionSHA256: selection.projectionSHA256, configurationSHA256: selection.configurationSHA256,
                     downloadSHA256: selection.downloadSHA256, recipeExecutable: selection.recipeExecutable, archiveTreeSHA256: tree.sha256,
                     match: match, package: selectedPackage, component: selectedComponent, resourceDirectory: resourceDirectory,
                     expandedBytes: budget.usedBytes, expandedEntries: budget.usedEntries,
                     packageInfoSHA256: infoSHA, payloadSHA256: payloadSHA, installLocation: location)
    }
    private enum SourceKind { case archive, xar, unknown }
    private static func sourceKind(_ source: URL, deadline: Date) throws -> SourceKind {
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        let (parent, name) = try NativeFileQuarantine.openParent(source); defer { close(parent) }
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(file) }
        var info = stat(), prefix = [UInt8](repeating: 0, count: 512)
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let count = Darwin.pread(file, &prefix, prefix.count, 0)
        guard count > 0 else { throw PluginHostServiceError.tool(.failed) }
        let bytes = Array(prefix.prefix(count))
        func starts(_ value: [UInt8]) -> Bool { bytes.starts(with: value) }
        if starts(Array("xar!".utf8)) { return .xar }
        if starts([0x50,0x4b]) || starts([0x1f,0x8b]) || starts(Array("BZh".utf8)) ||
            starts([0xfd,0x37,0x7a,0x58,0x5a,0]) || starts(Array("pbzx".utf8)) ||
            starts(Array("070707".utf8)) || starts(Array("070701".utf8)) || starts(Array("070702".utf8)) ||
            (bytes.count >= 262 && Array(bytes[257..<262]) == Array("ustar".utf8)) { return .archive }
        return .unknown
    }
    public static func matchPackagePayloads(_ components: [ComponentPayload], installed: URL, deadline: Date,
        maximumBytes: Int64 = 8 * 1024 * 1024 * 1024, isCancelled: () -> Bool = { false }) throws -> ComponentMatch {
        let matches = try matchingComponents(components, installed: installed, deadline: deadline,
            maximumBytes: maximumBytes, isCancelled: isCancelled)
        guard matches.count == 1, let match = matches.first else { throw PluginHostServiceError.unavailable("Original package components do not unambiguously match installed vendor bytes") }
        return match
    }
    private static func matchingComponents(_ components: [ComponentPayload], installed: URL, deadline: Date,
        maximumBytes: Int64, isCancelled: () -> Bool) throws -> [ComponentMatch] {
        guard components.count <= 2048, installed.isFileURL, absolute(installed.path) else { throw PluginHostServiceError.tool(.planChanged) }
        var result: [ComponentMatch] = []
        for component in components {
            guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let payload = component.payload
            let prefix = payload.installLocation == "/" ? "/" : payload.installLocation + "/"
            guard installed.path.hasPrefix(prefix) else { continue }
            let member = String(installed.path.dropFirst(prefix.count))
            guard HomebrewArchiveStaging.validRelativePath(member) else { throw PluginHostServiceError.tool(.planChanged) }
            guard try NativeFileQuarantine.existsWithoutFollowing(payload.tree.selectedURL.appendingPathComponent(member)) else { continue }
            do {
                let match = try compareMember(payload.tree, member: member, installed: installed,
                    deadline: deadline, maximumBytes: maximumBytes, isCancelled: isCancelled)
                result.append(.init(component: component, match: match))
            } catch PluginHostServiceError.unavailable { continue }
        }
        return result
    }
    /// Data-only product views; no Distribution JavaScript or installer scripts
    /// are evaluated. Only fixed component locations within the sealed package
    /// are considered, sorted by UTF-8 bytes. Every new Payload is charged.
    public static func extractPackagePayloads(_ package: HomebrewArchiveStaging.SealedTree, into directory: URL,
        artifactIndex: Int, decoder: HomebrewArchiveStaging.DecoderConfiguration, deadline: Date,
        budget: inout HomebrewNativeSourceBudget, isCancelled: @escaping () -> Bool = { false }) throws -> [ComponentPayload] {
        guard (0..<32).contains(artifactIndex),
              try HomebrewArchiveStaging.fingerprint(package.selectedURL, maximumBytes: budget.maximumBytes, deadline: deadline, isCancelled: isCancelled) == package.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
        func check() throws {
            guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        }
        func hasPayload(_ view: URL) throws -> Bool {
            try NativeFileQuarantine.existsWithoutFollowing(view.appendingPathComponent("PackageInfo")) &&
                NativeFileQuarantine.existsWithoutFollowing(view.appendingPathComponent("Payload"))
        }
        var views: [String] = []
        if try hasPayload(package.selectedURL) { views = [""] }
        else {
            for base in ["", "Packages", "Contents/Packages"] {
                try check()
                let container = base.isEmpty ? package.selectedURL : package.selectedURL.appendingPathComponent(base)
                guard try NativeFileQuarantine.existsWithoutFollowing(container) else { continue }
                guard try NativeFileQuarantine.capture(container, deadline: deadline).directory else { continue }
                let names = try FileManager.default.contentsOfDirectory(atPath: container.path)
                guard names.count <= 50_000 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                for name in names {
                    try check()
                    guard ["pkg", "mpkg"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { continue }
                    guard HomebrewArchiveStaging.validRelativePath(name), !name.contains("/") else { throw PluginHostServiceError.tool(.planChanged) }
                    let view = container.appendingPathComponent(name)
                    guard try NativeFileQuarantine.capture(view, deadline: deadline).directory, try hasPayload(view) else { continue }
                    views.append(base.isEmpty ? name : base + "/" + name)
                    guard views.count <= 64 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                }
            }
        }
        guard !views.isEmpty else { throw PluginHostServiceError.unavailable("Immutable package components contain no reviewed original Payload; generated outputs need generator provenance") }
        views.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var result: [ComponentPayload] = []
        for (index, component) in views.enumerated() {
            try check()
            guard budget.remainingBytes > 0 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            let view = component.isEmpty ? package : HomebrewArchiveStaging.SealedTree(selectedURL: package.selectedURL.appendingPathComponent(component),
                sha256: try HomebrewArchiveStaging.fingerprint(package.selectedURL.appendingPathComponent(component), maximumBytes: budget.maximumBytes, deadline: deadline, isCancelled: isCancelled))
            let resource = "payload-\(artifactIndex)-\(index)"
            let payload = try extractPackagePayload(view, into: directory.appendingPathComponent(resource), decoder: decoder,
                deadline: deadline, maximumBytes: budget.remainingBytes, maximumEntries: budget.remainingEntries, isCancelled: isCancelled)
            try budget.consume(payload.tree, deadline: deadline, isCancelled: isCancelled)
            result.append(.init(component: component.isEmpty ? nil : component, resourceDirectory: resource, payload: payload))
        }
        guard try HomebrewArchiveStaging.fingerprint(package.selectedURL, maximumBytes: budget.maximumBytes, deadline: deadline, isCancelled: isCancelled) == package.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
        return result
    }
    /// The package tree must itself be extracted from an authenticated original
    /// download. PackageInfo is bounded data, never installer script authority.
    public static func extractPackagePayload(_ package: HomebrewArchiveStaging.SealedTree, into output: URL,
                                              decoder: HomebrewArchiveStaging.DecoderConfiguration, deadline: Date,
                                              maximumBytes: Int64 = 8 * 1024 * 1024 * 1024,
                                              maximumEntries: Int = 50_000,
                                              isCancelled: @escaping () -> Bool = { false }) throws -> PackagePayload {
        guard try HomebrewArchiveStaging.fingerprint(package.selectedURL, maximumBytes: maximumBytes, deadline: deadline, isCancelled: isCancelled) == package.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
        let infoURL = package.selectedURL.appendingPathComponent("PackageInfo"), payloadURL = package.selectedURL.appendingPathComponent("Payload")
        let info = try NativeFileQuarantine.capture(infoURL, deadline: deadline)
        let payload = try NativeFileQuarantine.capture(payloadURL, deadline: deadline)
        guard info.mode & UInt32(S_IFMT) == UInt32(S_IFREG), info.size > 0, info.size <= 64 * 1024,
              payload.mode & UInt32(S_IFMT) == UInt32(S_IFREG), payload.size > 0, payload.size <= maximumBytes else { throw PluginHostServiceError.tool(.planChanged) }
        let held = open(infoURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard held >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(held) }
        var bytes = [UInt8](repeating: 0, count: Int(info.size) + 1)
        let count = Darwin.read(held, &bytes, bytes.count)
        guard count == info.size else { throw PluginHostServiceError.tool(.planChanged) }
        let data = Data(bytes.prefix(count))
        guard HomebrewSystemAuthorization.digest(data) == info.sha256,
              let text = String(data: data, encoding: .utf8), !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw PluginHostServiceError.tool(.planChanged) }
        let parser = XMLParser(data: data), selection = PackageLocation()
        parser.shouldResolveExternalEntities = false; parser.delegate = selection
        guard parser.parse(), let location = selection.location, absolute(location) else { throw PluginHostServiceError.tool(.planChanged) }
        let tree = try HomebrewArchiveStaging.extractVerified(payloadURL, checksum: payload.sha256, into: output, selected: ".", decoder: decoder, deadline: deadline, maximumBytes: maximumBytes, maximumEntries: maximumEntries, isCancelled: isCancelled)
        guard try HomebrewArchiveStaging.fingerprint(package.selectedURL, maximumBytes: maximumBytes, deadline: deadline, isCancelled: isCancelled) == package.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
        return .init(tree: tree, installLocation: location, packageInfoSHA256: info.sha256, payloadSHA256: payload.sha256)
    }
    private final class PackageLocation: NSObject, XMLParserDelegate {
        var location: String?, count = 0
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            count += 1
            guard count <= 256 else { parser.abortParsing(); return }
            if count == 1 { guard elementName == "pkg-info", let value = attributes["install-location"] else { parser.abortParsing(); return }; location = value }
            else if elementName == "pkg-info" { parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    }
    private static func absolute(_ path: String) -> Bool {
        path == "/" || (path.hasPrefix("/") && HomebrewArchiveStaging.validRelativePath(String(path.dropFirst())))
    }
    public static func compareMember(_ original: HomebrewArchiveStaging.SealedTree, member: String,
                                     installed: URL, deadline: Date, maximumBytes: Int64 = 8 * 1024 * 1024 * 1024,
                                     isCancelled: () -> Bool = { false }) throws -> Match {
        guard HomebrewArchiveStaging.validRelativePath(member), installed.isFileURL, absolute(installed.path),
              installed.query == nil, installed.fragment == nil,
              HomebrewPrivilegePlan.validDigest(original.sha256), maximumBytes > 0,
              maximumBytes <= 8 * 1024 * 1024 * 1024 else { throw PluginHostServiceError.tool(.planChanged) }
        func check() throws {
            guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        }
        try check()
        guard try HomebrewArchiveStaging.fingerprint(original.selectedURL, maximumBytes: maximumBytes, deadline: deadline, isCancelled: isCancelled) == original.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
        let resolved = try resolveMember(original.selectedURL, member: member)
        let source = original.selectedURL.appendingPathComponent(resolved)
        let bytes = try NativeFileQuarantine.capture(source, deadline: deadline)
        let installedBytes = try NativeFileQuarantine.capture(installed, deadline: deadline)
        guard bytes.mode & UInt32(S_IFMT) == UInt32(S_IFREG), installedBytes.mode & UInt32(S_IFMT) == UInt32(S_IFREG),
              bytes.mode & 0o100 != 0, installedBytes.mode & 0o100 != 0,
              bytes.size <= maximumBytes, bytes.size == installedBytes.size,
              bytes.sha256 == installedBytes.sha256, bytes.links == 1, installedBytes.links == 1 else { throw PluginHostServiceError.unavailable("Installed vendor bytes do not match an immutable original archive member") }
        try check()
        guard try HomebrewArchiveStaging.fingerprint(original.selectedURL, maximumBytes: maximumBytes, deadline: deadline, isCancelled: isCancelled) == original.sha256,
              try NativeFileQuarantine.capture(installed, deadline: deadline) == installedBytes else { throw PluginHostServiceError.tool(.planChanged) }
        return .init(member: member, resolvedMember: resolved, executableSHA256: bytes.sha256, installed: installedBytes, resourceTreeSHA256: original.sha256)
    }
    private static func resolveMember(_ root: URL, member: String) throws -> String {
        var parts = member.split(separator: "/").map(String.init), stack: [String] = [], links = 0, steps = 0
        while !parts.isEmpty {
            steps += 1; guard steps <= 512, stack.count <= 64 else { throw PluginHostServiceError.tool(.planChanged) }
            let next = parts.removeFirst()
            if next == "." { continue }
            if next == ".." { guard !stack.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }; stack.removeLast(); continue }
            let path = (stack + [next]).joined(separator: "/")
            guard HomebrewArchiveStaging.validRelativePath(path) else { throw PluginHostServiceError.tool(.planChanged) }
            let (parent, leaf) = try NativeFileQuarantine.openParent(root.appendingPathComponent(path)); defer { close(parent) }
            var info = stat(); guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
            if info.st_mode & S_IFMT == S_IFLNK {
                links += 1; guard links <= 128 else { throw PluginHostServiceError.tool(.planChanged) }
                var bytes = [UInt8](repeating: 0, count: 2049)
                let size = readlinkat(parent, leaf, &bytes, bytes.count)
                guard size > 0, size <= 2048, let target = String(bytes: bytes.prefix(size), encoding: .utf8),
                      !target.hasPrefix("/"), !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PluginHostServiceError.tool(.planChanged) }
                parts = target.split(separator: "/").map(String.init) + parts
            } else { stack.append(next) }
        }
        let result = stack.joined(separator: "/")
        guard HomebrewArchiveStaging.validRelativePath(result) else { throw PluginHostServiceError.tool(.planChanged) }; return result
    }
}
