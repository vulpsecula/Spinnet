import Foundation
import Darwin

/// The Host freezes source-byte origin before confirmation; Root independently
/// recaptures it before mutation. Only the fixed worker reads archives or the
/// possibly blocking installed filesystem. This lane accepts no Plugin paths.
public enum HomebrewNativeOriginAdmission {
    public struct Capture {
        public let proof: HomebrewNativeVendorOrigin.Proof
        public let directory: URL
    }
    public static func capture(source: HomebrewPrivilegePlan.SourceProof, name: String,
                               evidence: HomebrewSignedCaskCatalog.Evidence, download: HomebrewNoCheckSnapshot.Result,
                               recipeExecutable: String, owner: uid_t, deadline: Date,
                               maximumBytes: Int64 = 8 * 1024 * 1024 * 1024,
                               maximumEntries: Int = 50_000,
                               isCancelled: @escaping () -> Bool = { false },
                               willStart: (HomebrewTaskProcess) -> Bool = { _ in true },
                               didReap: @escaping (HomebrewTaskProcess) -> Void = { _ in }) throws -> Capture {
        guard !isCancelled(), Date() < deadline, owner > 0, source.envelopeSHA256 == evidence.catalog.envelopeSHA256,
              download.sourceSHA256 == source.envelopeSHA256, download.projectionSHA256 == source.projectionSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
        let metadata = try source.verifiedProjection(name: name, prefix: source.configuration.prefix.path, owner: owner,
            deadline: deadline, evidence: evidence)
        let frozen = metadata["sha256"] == .string("no_check") ? download : nil
        let selection = try HomebrewNativeVendorOrigin.select(evidence: evidence, configuration: source.configuration,
            token: String(name.split(separator: "/").last!), recipeExecutable: recipeExecutable, confirmedSnapshot: frozen)
        guard selection.downloadSHA256 == download.sha256, selection.sourceURL == download.sourceURL else { throw PluginHostServiceError.tool(.planChanged) }
        let captured = try run(source: source, name: name, evidence: evidence, recipeExecutable: recipeExecutable,
            operation: nil, originalDownload: download.fileURL, frozen: frozen, owner: owner, deadline: deadline,
            maximumBytes: maximumBytes, maximumEntries: maximumEntries, isCancelled: isCancelled, willStart: willStart, didReap: didReap)
        var accepted = false
        defer { if !accepted { try? FileManager.default.removeItem(at: captured.directory) } }
        guard let proof = captured.response.proof, proof.token == selection.token, proof.version == selection.version,
              proof.recipeExecutable == recipeExecutable, proof.kind == selection.kind,
              proof.sourceSHA256 == selection.sourceSHA256, proof.projectionSHA256 == selection.projectionSHA256,
              proof.configurationSHA256 == selection.configurationSHA256, proof.downloadSHA256 == download.sha256 else { throw PluginHostServiceError.tool(.planChanged) }
        accepted = true
        return Capture(proof: proof, directory: captured.directory)
    }
    public struct SourceCapture {
        public let proof: HomebrewNativeSourceStaging.Proof
        public let directory: URL
    }
    public static func stage(source: HomebrewPrivilegePlan.SourceProof, name: String,
                             evidence: HomebrewSignedCaskCatalog.Evidence, originalDownload: URL,
                             downloadSHA256: String, confirmedSnapshot: HomebrewNoCheckSnapshot.Result?,
                             purpose: HomebrewNativeSourceStaging.Purpose, owner: uid_t, deadline: Date,
                             maximumBytes: Int64 = 8 * 1024 * 1024 * 1024, maximumEntries: Int = 50_000,
                             isCancelled: @escaping () -> Bool = { false },
                             willStart: (HomebrewTaskProcess) -> Bool = { _ in true },
                             didReap: @escaping (HomebrewTaskProcess) -> Void = { _ in }) throws -> SourceCapture {
        _ = try source.verifiedProjection(name: name, prefix: source.configuration.prefix.path, owner: owner, deadline: deadline, evidence: evidence)
        let selected = try HomebrewNativeSourceStaging.select(evidence: evidence, configuration: source.configuration,
            token: String(name.split(separator: "/").last!), purpose: purpose, confirmedSnapshot: confirmedSnapshot)
        guard selected.sourceSHA256 == source.envelopeSHA256, selected.projectionSHA256 == source.projectionSHA256,
              selected.downloadSHA256 == downloadSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
        let captured = try run(source: source, name: name, evidence: evidence, recipeExecutable: "",
            operation: .sourceTree(purpose), originalDownload: originalDownload, frozen: confirmedSnapshot, owner: owner, deadline: deadline,
            maximumBytes: maximumBytes, maximumEntries: maximumEntries, isCancelled: isCancelled, willStart: willStart, didReap: didReap)
        var accepted = false
        defer { if !accepted { try? FileManager.default.removeItem(at: captured.directory) } }
        guard let proof = captured.response.sourceTreeProof, proof.kind == selected.kind, proof.token == selected.token,
              proof.version == selected.version, proof.sourceSHA256 == selected.sourceSHA256,
              proof.projectionSHA256 == selected.projectionSHA256, proof.configurationSHA256 == selected.configurationSHA256,
              proof.downloadSHA256 == selected.downloadSHA256, proof.purpose == purpose, proof.selectedMember == selected.selectedMember else { throw PluginHostServiceError.tool(.planChanged) }
        accepted = true
        return SourceCapture(proof: proof, directory: captured.directory)
    }
    private static func run(source: HomebrewPrivilegePlan.SourceProof, name: String,
                            evidence: HomebrewSignedCaskCatalog.Evidence, recipeExecutable: String,
                            operation: HomebrewNativeVendorOriginWorker.Operation?, originalDownload: URL,
                            frozen: HomebrewNoCheckSnapshot.Result?, owner: uid_t, deadline: Date,
                            maximumBytes: Int64, maximumEntries: Int, isCancelled: @escaping () -> Bool,
                            willStart: (HomebrewTaskProcess) -> Bool,
                            didReap: @escaping (HomebrewTaskProcess) -> Void) throws -> (response: HomebrewNativeVendorOriginWorker.Response, directory: URL) {
        guard !isCancelled(), Date() < deadline, owner > 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let directory = URL(fileURLWithPath: "/private/var/tmp/spinnet-origin-" + UUID().uuidString.lowercased())
        try NativeFileQuarantine.makePrivateDirectory(directory)
        var retain = false
        defer { if !retain { try? FileManager.default.removeItem(at: directory) } }
        let envelope = directory.appendingPathComponent("homebrew-source.jws.json")
        let fd = open(envelope.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(fd) }
        try evidence.envelope.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard !isCancelled(), Date() < deadline else { throw PluginHostServiceError.tool(.planChanged) }
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), min(65536, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += count
            }
        }
        guard fchmod(fd, 0o400) == 0, fsync(fd) == 0 else { throw PluginHostServiceError.tool(.failed) }
        let tools = try NativeSignedToolStaging.capture(["SpinnetVendorOrigin", "SpinnetArchiveBootstrap", "SpinnetArchiveDecoder"], deadline: deadline,
            allowUserExecution: true, isCancelled: isCancelled)
        // Actual process reap owns binary cleanup, including an unknown reply.
        // Data remains for explicit recovery whenever detach cannot be proved.
        var started = false
        defer { if !started { tools.remove() } }
        let request = HomebrewNativeVendorOriginWorker.Request(envelope: envelope, sourceSHA256: source.envelopeSHA256,
            projectionSHA256: source.projectionSHA256, configuration: source.configuration,
            token: String(name.split(separator: "/").last!), recipeExecutable: recipeExecutable, confirmedSnapshot: frozen,
            originalDownload: originalDownload, staging: directory, ownerUID: owner,
            deadline: min(deadline, Date().addingTimeInterval(180)), maximumBytes: maximumBytes, maximumEntries: maximumEntries, operation: operation)
        let outcome = try HomebrewNativeVendorOriginExecution.capture(request, toolsDirectory: tools.directory,
            isCancelled: isCancelled, willStart: { process in
                guard willStart(process) else { return false }; started = true; return true
            }, didReap: { process in tools.remove(); didReap(process) })
        if outcome.state == .unknown || outcome.response?.recoveryDirectory != nil {
            retain = true; throw NativeFileQuarantine.Failure.retained(directory)
        }
        guard let response = outcome.response else { throw PluginHostServiceError.tool(.failed) }
        if let failure = response.failure { throw PluginHostServiceError.tool(failure) }
        if let unavailable = response.unavailable { throw PluginHostServiceError.unavailable(unavailable) }
        retain = true
        return (response, directory)
    }
}
