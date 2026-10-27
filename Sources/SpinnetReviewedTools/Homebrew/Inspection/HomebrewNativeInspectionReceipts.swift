import SpinnetCore
import Foundation
import Darwin

/// Fixed read-only receipt adapter. Root reconstructs publisher/history facts
/// before invoking the signed worker. No Installer query, vendor code, helper
/// registration or mutation occurs in this operation.
public enum HomebrewNativeInspectionReceipts {
    public static func accountHome(_ uid: UInt32) throws -> String {
        guard uid != 0 else { throw HomebrewNativeInspection.Failure.invalidPeer }
        var account = passwd(), found: UnsafeMutablePointer<passwd>?, buffer = [CChar](repeating: 0, count: 16 * 1024)
        let home: String? = buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(uid, &account, bytes.baseAddress!, bytes.count, &found) == 0, found != nil, let path = account.pw_dir else { return nil }
            return String(validatingUTF8: path)
        }
        guard let home, HomebrewNativeInspection.validPath(home), home != "/" else { throw HomebrewNativeInspection.Failure.invalidPeer }
        return home
    }
    /// Receipt expressions must be in the independently signed installed-
    /// version projection. Additional native bodies have their own fixed Root
    /// adapters; absence of that adapter is an explicit refusal, never a skip.
    public static func verifyDraft(_ draft: HomebrewNativeInspection.Draft, deadline: Date,
        verifyAdditionalDeclarations: (HomebrewNativeInspection.Package, [String: JSONValue]) throws -> Void = { package, _ in
            guard package.declarations.allSatisfy({ $0.kind == .publisherSource }) else {
                throw PluginHostServiceError.unavailable("Additional native declarations require their separately reviewed inspection adapter")
            }
        }) throws {
        try draft.validate()
        guard try accountHome(draft.uid) == draft.home else { throw HomebrewNativeInspection.Failure.invalidPeer }
        var catalogs: [String: HomebrewSignedCaskCatalog.Evidence] = [:]
        for package in draft.packages {
            if package.declarations.count == 1, package.declarations[0].kind == .installedData {
                let installed = try HomebrewInstalledUninstall.read(name: package.name, prefix: draft.prefix)
                let body = package.declarations[0].body
                let declaration = try JSONDecoder().decode(HomebrewNativeInspectionPlanning.InstalledData.self, from: body)
                let artifacts = try JSONDecoder().decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: installed.artifacts))
                guard installed.version == package.version, installed.tap == package.tap, installed.fingerprint == package.installedFingerprint,
                      declaration.artifacts == artifacts, package.sourceEnvelopeSHA256 == installed.fingerprint,
                      package.sourceProjectionSHA256 == HomebrewSystemAuthorization.digest(body),
                      package.configurationSHA256 == HomebrewSystemAuthorization.digest(Data((draft.prefix + "\n" + draft.home + "\n" + draft.operation.rawValue).utf8)),
                      declaration.includeZap == (draft.includeZap == true) else { throw HomebrewNativeInspection.Failure.planChanged }
                let patterns = try receiptPatterns(["artifacts": .array(artifacts)], includeZap: declaration.includeZap)
                guard Set(patterns) == Set(package.receiptPatterns.keys) else { throw HomebrewNativeInspection.Failure.planChanged }
                for pattern in patterns { guard try HomebrewReceiptRemoval.resolvePatterns([pattern], deadline: deadline) == package.receiptPatterns[pattern] else { throw HomebrewNativeInspection.Failure.planChanged } }
                continue
            }
            guard Date() < deadline, package.tap == "homebrew/cask" else { throw PluginHostServiceError.unavailable("Independent installed-version publisher evidence is required for receipt inspection") }
            let installed = try HomebrewInstalledUninstall.read(name: package.name, prefix: draft.prefix)
            guard installed.version == package.version, installed.tap == package.tap,
                  installed.fingerprint == package.installedFingerprint else { throw HomebrewNativeInspection.Failure.planChanged }
            let sourceDeclarations = package.declarations.filter { $0.kind == .publisherSource }
            guard sourceDeclarations.count == 1 else { throw HomebrewNativeInspection.Failure.invalidDraft }
            let proof = try JSONDecoder().decode(HomebrewPrivilegePlan.SourceProof.self, from: sourceDeclarations[0].body)
            guard proof.envelopeSHA256 == package.sourceEnvelopeSHA256, proof.projectionSHA256 == package.sourceProjectionSHA256,
                  catalogs.count < 4 || catalogs[proof.envelopeSHA256] != nil else { throw HomebrewNativeInspection.Failure.planChanged }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard HomebrewSystemAuthorization.digest(try encoder.encode(proof.configuration)) == package.configurationSHA256 else { throw HomebrewNativeInspection.Failure.planChanged }
            let evidence = try catalogs[proof.envelopeSHA256] ?? HomebrewSignedCaskCatalog.load(proof.envelope, deadline: deadline)
            catalogs[proof.envelopeSHA256] = evidence
            let projection = try proof.verifiedProjection(name: package.name, prefix: draft.prefix, owner: draft.uid, deadline: deadline, evidence: evidence)
            guard projection["version"] == .string(package.version) else { throw HomebrewNativeInspection.Failure.planChanged }
            let publishedPatterns = try receiptPatterns(projection)
            guard Set(package.receiptPatterns.keys) == Set(publishedPatterns) else { throw HomebrewNativeInspection.Failure.planChanged }
            for pattern in publishedPatterns {
                guard try HomebrewReceiptRemoval.resolvePatterns([pattern], deadline: deadline) == package.receiptPatterns[pattern] else { throw HomebrewNativeInspection.Failure.planChanged }
            }
            try verifyAdditionalDeclarations(package, projection)
        }
    }
    private static func receiptPatterns(_ metadata: [String: JSONValue], includeZap: Bool = false) throws -> [String] {
        guard case .array(let artifacts)? = metadata["artifacts"] else { throw HomebrewNativeInspection.Failure.planChanged }
        var patterns: [String] = []
        for artifact in artifacts {
            for key in includeZap ? ["uninstall", "zap"] : ["uninstall"] {
            guard let uninstall = artifact.value(atPointer: "/" + key) else { continue }
            let directives: [JSONValue]
            if case .array(let values) = uninstall { directives = values } else { directives = [uninstall] }
            for directive in directives {
                guard let pkgutil = directive.value(atPointer: "/pkgutil") else { continue }
                switch pkgutil {
                case .string(let pattern): patterns.append(pattern)
                case .array(let values):
                    for value in values { guard case .string(let pattern) = value else { throw HomebrewNativeInspection.Failure.planChanged }; patterns.append(pattern) }
                default: throw HomebrewNativeInspection.Failure.planChanged
                }
            }
            }
        }
        guard !patterns.isEmpty, patterns.count <= 16, Set(patterns).count == patterns.count else { throw HomebrewNativeInspection.Failure.planChanged }
        return patterns.sorted()
    }
    public static func capture(_ draft: HomebrewNativeInspection.Draft, excludedPaths: [String: Set<String>] = [:],
        launchContext: HomebrewNativeLaunchServices.Context? = nil, deadline: Date, isCancelled: @escaping () -> Bool,
        willStart: (HomebrewTaskProcess) -> Bool, didStart: (HomebrewTaskProcess) -> Void = { _ in }, didReap: @escaping (HomebrewTaskProcess) -> Void) throws -> HomebrewNativeInspection.Capture {
        guard Date() < deadline, deadline.timeIntervalSinceNow <= HomebrewNativeInspection.inventoryLifetime,
              !isCancelled() else { throw HomebrewNativeInspection.Failure.expired }
        let request = NativeReceiptInventoryWorker.ManifestRequest(selected: draft.selectedReceiptIDs, excludedPaths: excludedPaths, launchContext: launchContext)
        let response = try NativeReceiptInventoryWorker.captureManifests(request, deadline: deadline,
            isCancelled: isCancelled, willStart: willStart, didStart: didStart, didReap: didReap)
        return try freeze(response, draft: draft, accountedPaths: Set(excludedPaths.values.flatMap { $0 }), launchContext: launchContext)
    }
    /// Public native worker contract seam. Does not manufacture a missing or
    /// zero-file receipt's checksum: even metadata-only recovery requires its
    /// real exported plist and the complete source index.
    public static func freeze(_ response: NativeReceiptInventoryWorker.Response, draft: HomebrewNativeInspection.Draft,
        accountedPaths: Set<String> = [], launchContext: HomebrewNativeLaunchServices.Context? = nil) throws -> HomebrewNativeInspection.Capture {
        try draft.validate()
        let selected = draft.selectedReceiptIDs
        if let launchContext {
            try launchContext.validate()
            guard launchContext.uid == draft.uid, launchContext.home.path == draft.home else { throw HomebrewNativeInspection.Failure.invalidPeer }
        }
        guard response.version == 1, response.failure == nil, response.unavailable == nil,
              let index = response.index, let snapshots = response.snapshots, Set(snapshots.keys) == selected,
              Set(index.exports.keys) == selected, Set(index.locations.keys) == selected, Set(index.relativePaths.keys) == selected,
              (1...2000).contains(index.receiptFingerprints.count), selected.isSubset(of: Set(index.receiptFingerprints.keys)),
              index.receiptFingerprints.values.allSatisfy({ $0.count == 2 && $0.allSatisfy(HomebrewPrivilegePlan.validDigest) }),
              HomebrewPrivilegePlan.validDigest(index.filesystemSHA256) else { throw HomebrewNativeInspection.Failure.planChanged }
        var completeSources = index.receiptFingerprints
        completeSources["$filesystem"] = [index.filesystemSHA256]
        let sourceBytes = try JSONSerialization.data(withJSONObject: completeSources, options: [.sortedKeys])
        guard HomebrewSystemAuthorization.digest(sourceBytes) == index.fingerprint else { throw HomebrewNativeInspection.Failure.planChanged }
        var byPath: [String: HomebrewNativeInspection.Target] = [:], receipts: [HomebrewNativeInspection.Receipt] = []
        for id in selected.sorted() {
            guard let snapshot = snapshots[id], let exported = index.exports[id], !exported.isEmpty,
                  snapshot.receipt.identifier == id, snapshot.ownershipSHA256 == index.fingerprint,
                  snapshot.filesystemSHA256 == index.filesystemSHA256,
                  snapshot.receipt.fileCount == snapshot.entries.count + snapshot.accountedEntries.count,
                  Set((snapshot.entries + snapshot.accountedEntries).map(\.path)).count == snapshot.receipt.fileCount else { throw HomebrewNativeInspection.Failure.planChanged }
            guard let value = try PropertyListSerialization.propertyList(from: exported, format: nil) as? [String: Any],
                  value["pkgid"] as? String == id, let volume = value["volume"] as? String,
                  let rawLocation = value["install-location"] as? String, let paths = value["paths"] as? [String: Any],
                  !paths.isEmpty, paths.count <= 10_000,
                  try HomebrewReceiptRemoval.installLocation(volume: volume, location: rawLocation) == index.locations[id],
                  paths.keys.map({ $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }).sorted() == index.relativePaths[id] else { throw HomebrewNativeInspection.Failure.planChanged }
            let manifest = try HomebrewReceiptRemoval.manifestDigest(exported: exported, entries: snapshot.entries + snapshot.accountedEntries)
            guard snapshot.receipt.manifestSHA256 == HomebrewSystemAuthorization.digest(Data((manifest + index.fingerprint).utf8)),
                  snapshot.exportSHA256 == (try HomebrewReceiptRemoval.manifestDigest(exported: exported, entries: [])) else { throw HomebrewNativeInspection.Failure.planChanged }
            receipts.append(.init(identifier: id, manifestSHA256: snapshot.receipt.manifestSHA256, fileCount: snapshot.receipt.fileCount))
            for (entries, accounted) in [(snapshot.entries, false), (snapshot.accountedEntries, true)] {
                for entry in entries {
                    let userAgent = accounted && accountedPaths.contains(entry.path) && launchContext.map { HomebrewReceiptRemoval.accountedUserAgent(entry.path, context: $0) } == true
                    let userOwned = userAgent && entry.frozen.owner == launchContext?.uid && !entry.directory && !entry.frozen.symbolicLink
                        && entry.frozen.links == 1 && entry.frozen.mode & 0o022 == 0 && !entry.frozen.writableACL
                    guard (HomebrewReceiptRemoval.validPath(entry.path) && entry.frozen.owner == 0) || userOwned else { throw HomebrewNativeInspection.Failure.planChanged }
                    guard entry.frozen.size >= 0,
                          let owners = index.owners[entry.path], owners.contains(id), owners.isSubset(of: selected),
                          !accounted || accountedPaths.contains(entry.path) else { throw HomebrewNativeInspection.Failure.planChanged }
                    let type = entry.frozen.mode & UInt32(S_IFMT)
                    let identity = String(entry.device) + ":" + String(entry.inode) + ":" + String(type) + ":" + String(entry.directory ? 0 : entry.frozen.links)
                    guard index.selectedIdentities[entry.path] == identity,
                          entry.directory == (type == UInt32(S_IFDIR)) else { throw HomebrewNativeInspection.Failure.planChanged }
                    let action: HomebrewNativeInspection.Target.Action = accounted ? .handledByDeclaration : entry.directory ? .removeEmptyDirectory : .removeFile
                    let size = entry.directory ? 0 : entry.frozen.size, frozenSHA = try HomebrewNativeInspection.digest(entry)
                    if let previous = byPath[entry.path] {
                        guard previous.action == action, previous.size == size, previous.frozenSHA256 == frozenSHA else { throw HomebrewNativeInspection.Failure.planChanged }
                        byPath[entry.path] = .init(receiptIDs: (previous.receiptIDs + [id]).sorted(), path: entry.path, action: action, size: size, frozenSHA256: frozenSHA)
                    } else { byPath[entry.path] = .init(receiptIDs: [id], path: entry.path, action: action, size: size, frozenSHA256: frozenSHA) }
                }
            }
        }
        let privateBytes = try HomebrewNativeInspection.encode(response)
        let result = HomebrewNativeInspection.Capture(draftSHA256: try draft.sha256, ownershipSHA256: index.fingerprint,
            filesystemSHA256: index.filesystemSHA256, disclosure: .init(receipts: receipts, targets: byPath.keys.sorted().map { byPath[$0]! }), privateInventory: privateBytes)
        try result.validate(draft: draft); return result
    }
    /// Before admission, no approved ID may disappear. During the admitted
    /// Task, only exact durably forgotten approved IDs may leave this reference.
    public static func validateLive(_ capture: HomebrewNativeInspection.Capture, live: HomebrewReceiptOwnership.Index,
        forgotten: Set<String> = []) throws {
        let response = try JSONDecoder().decode(NativeReceiptInventoryWorker.Response.self, from: capture.privateInventory)
        guard let reference = response.index, reference.fingerprint == capture.ownershipSHA256,
              reference.filesystemSHA256 == capture.filesystemSHA256 else { throw HomebrewNativeInspection.Failure.planChanged }
        try HomebrewReceiptOwnership.validateLiveSources(reference: reference, live: live, forgotten: forgotten)
    }
}
