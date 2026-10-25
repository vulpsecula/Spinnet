import Foundation
import Darwin

/// A separate old-version code grant keeps upgrade installation authority from
/// accidentally authorizing a different uninstaller. Installed history remains
/// data: publisher code is independently reselected from its retained signature.
public enum HomebrewNativeRemovalCode {
    public struct Selection {
        public let name: String
        public let version: String
        public let includeZap: Bool
        public let source: HomebrewPrivilegePlan.SourceProof
        public let sourceURL: URL
        public let publishedSHA256: String
        public let actions: [HomebrewNativeUninstallArtifacts.Action]
        public let generatedResources: [HomebrewNativeGeneratedResources.Resource]
        public let origins: [HomebrewNativeVendorOrigin.Proof]
        public let noPublisherChecksum: Bool
    }
    public struct Grant: Codable, Equatable {
        public let name: String
        public let version: String
        public let includeZap: Bool
        public let source: HomebrewPrivilegePlan.SourceProof
        public let download: HomebrewNoCheckSnapshot.Result
        public let actions: [HomebrewNativeUninstallArtifacts.Action]
        public let generatedResources: [HomebrewNativeGeneratedResources.Resource]
        public let origins: [HomebrewNativeVendorOrigin.Proof]?
        public let noPublisherChecksum: Bool?
        public var valid: Bool {
            HomebrewTaskInput.validPackageName(name) && !version.isEmpty && version.utf8.count <= 80 && !version.contains("/")
                && source.valid && (1...32).contains(actions.count) && actions.allSatisfy(\.valid)
                && actions.allSatisfy({ $0.script.phase != .install && (includeZap || ![.earlyZap, .zap].contains($0.script.phase)) })
                && generatedResources.count <= 32 && generatedResources.allSatisfy(\.valid)
                && (origins ?? []).count <= 32 && Set((origins ?? []).map(\.recipeExecutable)).count == (origins ?? []).count
                && Set(generatedResources.map(\.path)).count == generatedResources.count
                && download.fileURL.isFileURL && download.fileURL.path == download.fileURL.standardizedFileURL.path
                && download.fileURL.path.utf8.count <= 2048 && download.fileURL.lastPathComponent.hasPrefix("native-payload-")
                && download.fileURL.pathExtension == "archive" && HomebrewPrivilegePlan.validDigest(download.sha256)
                && (1...HomebrewNoCheckSnapshot.maximumBytes).contains(download.byteCount)
                && download.sourceSHA256 == source.envelopeSHA256 && download.projectionSHA256 == source.projectionSHA256
                && HomebrewPrivilegePlan.validDigest(download.configurationSHA256)
        }
        /// Codable and a local file hash cannot manufacture Root authority.
        /// Root calls this before staging any old-version executable bytes.
        @discardableResult
        public func verify(owner: uid_t, prefix: String, deadline: Date,
                           evidence: HomebrewSignedCaskCatalog.Evidence? = nil) throws -> Selection {
            guard valid, source.configuration.prefix.path == prefix else { throw PluginHostServiceError.tool(.planChanged) }
            let selection = try HomebrewNativeRemovalCode.selectSource(proof: source, name: name, installedVersion: version,
                includeZap: includeZap, owner: owner, deadline: deadline, evidence: evidence, origins: origins ?? [], confirmedSnapshot: download)
            guard selection.actions == actions, selection.generatedResources == generatedResources,
                  selection.sourceURL == download.sourceURL, selection.publishedSHA256 == download.sha256,
                  selection.noPublisherChecksum == (noPublisherChecksum ?? false) else { throw PluginHostServiceError.tool(.planChanged) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard HomebrewSystemAuthorization.digest(try encoder.encode(source.configuration)) == download.configurationSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
            return selection
        }
        public var confirmationDetails: String {
            "Old-version code \(name) \(version), independently signed source \(source.envelopeSHA256.prefix(12)), frozen \(download.byteCount) bytes from \(download.sourceURL.absoluteString), SHA-256 \(download.sha256). "
                + (noPublisherChecksum == true ? "No publisher checksum: this exact source download was frozen before confirmation. Ordinary vendor code additionally matches installed bytes; generated code and typed package execution are independently bound to the verified declaration. This does not prove historical release provenance. " : "")
                + actions.map { action in
                    "\(action.script.phase.rawValue): immutable \(action.kind.rawValue) \(action.recipeExecutable), arguments \(action.script.arguments.joined(separator: " ")), input \(action.script.input?.utf8.count ?? 0) bytes; \(action.script.mustSucceed ? "failure stops the Task" : "optional failure is allowed by its verified source")."
                }.joined(separator: " ")
        }
    }
    public static func selectSource(proof: HomebrewPrivilegePlan.SourceProof, name: String, installedVersion: String,
                                    includeZap: Bool, owner: uid_t = getuid(), deadline: Date,
                                    evidence: HomebrewSignedCaskCatalog.Evidence? = nil,
                                    origins: [HomebrewNativeVendorOrigin.Proof] = [], confirmedSnapshot: HomebrewNoCheckSnapshot.Result? = nil) throws -> Selection {
        guard HomebrewTaskInput.validPackageName(name) else { throw PluginHostServiceError.tool(.planChanged) }
        let metadata = try proof.verifiedProjection(name: name, prefix: proof.configuration.prefix.path, owner: owner, deadline: deadline, evidence: evidence)
        guard metadata["version"] == .string(installedVersion), case .string(let text)? = metadata["url"],
              let source = URL(string: text), source.scheme == "https", source.host != nil, source.user == nil, source.password == nil,
              source.fragment == nil, case .string(let checksum)? = metadata["sha256"], HomebrewPrivilegePlan.validDigest(checksum) || checksum == "no_check" else {
            throw PluginHostServiceError.unavailable("Independently signed original-version source and immutable publisher bytes are unavailable for this uninstaller")
        }
        let token = String(name.split(separator: "/").last!)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let configurationSHA = HomebrewSystemAuthorization.digest(try encoder.encode(proof.configuration))
        let sourceChecksum: String
        if checksum == "no_check" {
            guard let frozen = confirmedSnapshot, frozen.sourceURL == source, frozen.sourceSHA256 == proof.envelopeSHA256,
                  frozen.projectionSHA256 == proof.projectionSHA256, frozen.configurationSHA256 == configurationSHA,
                  HomebrewPrivilegePlan.validDigest(frozen.sha256), (1...HomebrewNoCheckSnapshot.maximumBytes).contains(frozen.byteCount) else { throw PluginHostServiceError.unavailable("A frozen pre-confirmation source snapshot is required for this no_check uninstaller") }
            sourceChecksum = frozen.sha256
        } else { sourceChecksum = checksum }
        guard origins.count <= 32, Set(origins.map(\.recipeExecutable)).count == origins.count,
              origins.allSatisfy({ origin in
                  origin.kind == (checksum == "no_check" ? .confirmedHostSnapshotMatch : .publisherChecksum) && origin.token == token && origin.version == installedVersion
                    && origin.sourceSHA256 == proof.envelopeSHA256 && origin.projectionSHA256 == proof.projectionSHA256
                    && origin.configurationSHA256 == configurationSHA && origin.downloadSHA256 == sourceChecksum
                    && [origin.archiveTreeSHA256, origin.match.resourceTreeSHA256, origin.match.executableSHA256, origin.match.installed.sha256].allSatisfy(HomebrewPrivilegePlan.validDigest)
                    && origin.match.executableSHA256 == origin.match.installed.sha256 && !origin.match.installed.directory
                    && HomebrewArchiveStaging.validRelativePath(origin.match.member) && HomebrewArchiveStaging.validRelativePath(origin.match.resolvedMember)
              }) else { throw PluginHostServiceError.tool(.planChanged) }
        let actions = try HomebrewNativeUninstallArtifacts.select(metadata, includeZap: includeZap, prefix: proof.configuration.prefix.path,
            token: token, version: installedVersion, appDirectory: proof.configuration.appDirectory.path, origins: origins)
        guard origins.allSatisfy({ origin in actions.contains { $0.recipeExecutable == origin.recipeExecutable && $0.kind == .vendor && $0.script.executable == origin.match.resolvedMember } }) else { throw PluginHostServiceError.tool(.planChanged) }
        guard checksum != "no_check" || actions.allSatisfy({ action in action.kind == .package || action.script.generatedContent != nil || origins.contains { $0.recipeExecutable == action.recipeExecutable } }) else { throw PluginHostServiceError.unavailable("The frozen no_check source lacks a verified installed-byte origin for an executable") }
        guard !actions.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        var generated: [HomebrewNativeGeneratedResources.Resource] = []
        if case .array(let artifacts)? = metadata["artifacts"] {
            for artifact in artifacts {
                guard case .array(let values)? = artifact.value(atPointer: "/generated_script") else { continue }
                guard values.count == 2, case .string(let path) = values[0], case .object(let options) = values[1],
                      Set(options.keys) == ["content"], case .string(let body)? = options["content"] else { throw PluginHostServiceError.tool(.planChanged) }
                let resource = HomebrewNativeGeneratedResources.Resource(path: path, content: body)
                guard resource.valid, !generated.contains(where: { $0.path == path }), generated.count < 32 else { throw PluginHostServiceError.tool(.planChanged) }
                generated.append(resource)
            }
        }
        return Selection(name: name, version: installedVersion, includeZap: includeZap, source: proof, sourceURL: source,
            publishedSHA256: sourceChecksum, actions: actions, generatedResources: generated.sorted { $0.path < $1.path }, origins: origins, noPublisherChecksum: checksum == "no_check")
    }
    public static func freeze(_ selection: Selection, download: HomebrewNoCheckSnapshot.Result) throws -> Grant {
        let result = Grant(name: selection.name, version: selection.version, includeZap: selection.includeZap, source: selection.source,
            download: download, actions: selection.actions, generatedResources: selection.generatedResources, origins: selection.origins.isEmpty ? nil : selection.origins,
            noPublisherChecksum: selection.noPublisherChecksum ? true : nil)
        _ = try result.verify(owner: getuid(), prefix: selection.source.configuration.prefix.path, deadline: Date().addingTimeInterval(15))
        return result
    }
    public static func prepare(name: String, installed: HomebrewInstalledUninstall.Record, includeZap: Bool,
                               executable: URL, evidenceDirectory: URL, expected: Grant? = nil,
                               fetch: HomebrewNoCheckSnapshot.Fetch = HomebrewNoCheckSnapshot.download,
                               deadline: Date, cancellation: HostFetchedSections.Cancellation? = nil, isCancelled: @escaping () -> Bool = { false }) throws -> Grant {
        guard !isCancelled(), cancellation?.isCancelled != true else { throw PluginHostServiceError.tool(.planChanged) }
        guard installed.tap == "homebrew/cask" else { throw PluginHostServiceError.unavailable("Independent retained publisher evidence is unavailable for this third-party uninstaller") }
        let prefix = executable.deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try HomebrewPrivilegeMetadata.effectiveConfiguration(name: name, prefix: prefix)
        let proof: HomebrewPrivilegePlan.SourceProof
        if let expected {
            guard expected.name == name, expected.version == installed.version, expected.includeZap == includeZap,
                  expected.source.configuration == configuration else { throw PluginHostServiceError.tool(.planChanged) }
            proof = expected.source
        } else {
            // A missing retained index may use a freshly verified source only
            // when its actual signed version equals the installed version.
            do { proof = try HomebrewNativeSourceRetention.lookup(name: name, version: installed.version, configuration: configuration, in: evidenceDirectory, deadline: min(deadline, Date().addingTimeInterval(15))) }
            catch let error as PluginHostServiceError {
                guard case .unavailable = error else { throw error }
                let snapshot = try HomebrewPrivilegeMetadata.readEvidence(name, executable: executable, deadline: min(deadline, Date().addingTimeInterval(30)), execute: { try HomebrewReadProfile.executeCancellable($0, $1, $2, $3, cancellation ?? .init()) })
                guard let official = snapshot.officialEvidence, snapshot.configuration == configuration,
                      snapshot.metadata["version"] == .string(installed.version) else { throw PluginHostServiceError.unavailable("The installed version has no retained independent publisher signature; the current version cannot authorize its code") }
                let directory = evidenceDirectory.appendingPathComponent(official.catalog.envelopeSHA256)
                if !FileManager.default.fileExists(atPath: directory.path) { try NativeFileQuarantine.makePrivateDirectory(directory) }
                let envelope = try snapshot.persistOfficialEvidence(in: directory)
                proof = .init(envelope: envelope, envelopeSHA256: official.catalog.envelopeSHA256,
                    projectionSHA256: try official.catalog.projectionDigest(String(name.split(separator: "/").last!), configuration: configuration), configuration: configuration)
                try HomebrewNativeSourceRetention.retain(proof, name: name, version: installed.version, in: evidenceDirectory)
            }
        }
        let directory: URL
        if let expected { directory = expected.download.fileURL.deletingLastPathComponent() }
        else { directory = evidenceDirectory.appendingPathComponent("old-code-" + UUID().uuidString); try NativeFileQuarantine.makePrivateDirectory(directory) }
        let download = try HomebrewNoCheckSnapshot.capturePinnedSource(proof: proof, name: name, into: directory,
            deadline: deadline, expectedSHA256: expected?.download.sha256, isCancelled: isCancelled, allowConfirmedSourceMatch: true, fetch: fetch)
        let evidence = try HomebrewSignedCaskCatalog.load(proof.envelope, deadline: min(deadline, Date().addingTimeInterval(15)))
        let metadata = try proof.verifiedProjection(name: name, prefix: prefix.path, owner: getuid(), deadline: deadline, evidence: evidence)
        var origins: [HomebrewNativeVendorOrigin.Proof] = []
        // Relative publisher-pinned members already have an immutable source.
        // Absolute installed programs and all no_check vendor bytes require a
        // fresh worker proof; their user-owned file is never executed by Root.
        if metadata["sha256"] == .string("no_check") || (try? selectSource(proof: proof, name: name, installedVersion: installed.version,
            includeZap: includeZap, deadline: deadline, evidence: evidence, confirmedSnapshot: download)) == nil {
            for recipe in try vendorRecipes(metadata, includeZap: includeZap) {
                let origin = try HomebrewNativeOriginAdmission.capture(source: proof, name: name, evidence: evidence,
                    download: download, recipeExecutable: recipe, owner: getuid(), deadline: deadline, isCancelled: isCancelled)
                origins.append(origin.proof)
                try? FileManager.default.removeItem(at: origin.directory)
            }
        }
        let selection = try selectSource(proof: proof, name: name, installedVersion: installed.version, includeZap: includeZap,
            deadline: deadline, evidence: evidence, origins: origins, confirmedSnapshot: download)
        let installedBytes = try JSONSerialization.data(withJSONObject: ["artifacts": installed.artifacts])
        guard case .object(let installedMetadata) = try JSONDecoder().decode(JSONValue.self, from: installedBytes) else { throw PluginHostServiceError.tool(.planChanged) }
        let recordedActions = try HomebrewNativeUninstallArtifacts.select(installedMetadata, includeZap: includeZap, prefix: prefix.path,
            token: String(name.split(separator: "/").last!), version: installed.version, appDirectory: configuration.appDirectory.path, origins: origins)
        guard recordedActions == selection.actions else { throw PluginHostServiceError.tool(.planChanged) }
        let frozen = try freeze(selection, download: download)
        guard expected == nil || expected == frozen else { throw PluginHostServiceError.tool(.planChanged) }
        return frozen
    }
    private static func vendorRecipes(_ metadata: [String: JSONValue], includeZap: Bool) throws -> [String] {
        guard case .array(let artifacts)? = metadata["artifacts"] else { throw PluginHostServiceError.tool(.planChanged) }
        let generated = Set(artifacts.compactMap { artifact -> String? in
            guard case .array(let values)? = artifact.value(atPointer: "/generated_script"), case .string(let path)? = values.first else { return nil }; return path
        })
        var recipes = Set<String>()
        for artifact in artifacts {
            for scope in includeZap ? ["uninstall", "zap"] : ["uninstall"] {
                guard case .array(let directives)? = artifact.value(atPointer: "/" + scope) else { continue }
                for directive in directives {
                    for kind in ["script", "early_script"] {
                        guard let options = directive.value(atPointer: "/" + kind), options.value(atPointer: "/sudo") == .bool(true),
                              case .string(let executable)? = options.value(atPointer: "/executable") else { continue }
                        if executable == "/usr/sbin/installer" || generated.contains(executable) { continue }
                        recipes.insert(executable)
                        guard recipes.count <= 32 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    }
                }
            }
        }
        return recipes.sorted()
    }
}
