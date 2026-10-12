import Foundation
import Darwin

/// Fixed source-worker supervision. The authenticated caller supplies immutable
/// signed sibling copies, retains them and the private stage until didReap.
/// An unknown result never permits replay, stage removal or lane release.
public enum HomebrewNativeVendorOriginExecution {
    public enum State: String { case completed, unknown }
    public struct Outcome {
        public let state: State
        public let response: HomebrewNativeVendorOriginWorker.Response?
        public let process: HomebrewTaskProcess
    }
    private final class Completion {
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var bytes = Data()
        var result: HomebrewTaskProcess.Result?
        var failure: ReviewedToolFailure?
    }
    public static func capture(_ request: HomebrewNativeVendorOriginWorker.Request, toolsDirectory: URL,
                               stopGrace: TimeInterval = 2, isCancelled: @escaping () -> Bool = { false },
                               willStart: (HomebrewTaskProcess) -> Bool = { _ in true },
                               didReap: @escaping (HomebrewTaskProcess) -> Void = { _ in }) throws -> Outcome {
        let remaining = request.deadline.timeIntervalSinceNow
        guard request.version == 1, request.deadline.timeIntervalSince1970.isFinite,
              remaining > 0, remaining <= 180, stopGrace.isFinite, (0...20).contains(stopGrace),
              !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
        let input = try JSONEncoder().encode(request)
        guard input.count <= HomebrewNativeVendorOriginWorker.maximumMessageBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let worker = toolsDirectory.appendingPathComponent("SpinnetVendorOrigin")
        // Root's NativeSignedToolStaging supplies the sealed same-Team triple.
        // This path cannot be resolved through Plugin fields or environment.
        if getuid() == 0 {
            let path = toolsDirectory.path
            guard path.hasPrefix("/private/var/tmp/spinnet-native-tools-"),
                  !path.dropFirst("/private/var/tmp/".count).contains("/") else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            let directory = try NativeFileQuarantine.capture(toolsDirectory)
            guard directory.directory, directory.owner == 0, directory.mode & 0o066 == 0,
                  !directory.writableACL else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        }
        let process = HomebrewTaskProcess(executable: worker, arguments: ["--capture"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
            interruptGrace: 0.2, terminateGrace: 0.2, standardInput: input)
        let completion = Completion()
        guard !isCancelled(), willStart(process) else { throw PluginHostServiceError.tool(.planChanged) }
        do {
            try process.start(output: { data in
                completion.lock.lock()
                if completion.bytes.count + data.count > HomebrewNativeVendorOriginWorker.maximumMessageBytes {
                    completion.failure = .outputTooLarge
                } else { completion.bytes.append(data) }
                let stopping = completion.failure != nil
                completion.lock.unlock()
                if stopping { process.stop() }
            }, finished: { result in
                completion.lock.lock(); completion.result = result; completion.lock.unlock()
                didReap(process); completion.done.signal()
            })
        } catch { didReap(process); throw error }
        let deadline = ProcessInfo.processInfo.systemUptime + remaining
        var stopDeadline: TimeInterval?
        while completion.done.wait(timeout: .now() + 0.01) == .timedOut {
            var resident: UInt64 = 0
            var resourceFailure = false
            // Use the mutation boundary's actual identity-bound ownership map,
            // including Foundation children in escaped groups. An unrelated or
            // recycled PID never becomes an RSS/signal target here.
            for (pid, identity) in process.ownedProcessIdentities {
                if HomebrewTaskProcess.startIdentity(pid) == identity {
                    var usage = rusage_info_v2()
                    let status = withUnsafeMutablePointer(to: &usage) { pointer in
                        proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
                    }
                    if status == 0 {
                        resident = resident > UInt64.max - usage.ri_resident_size ? UInt64.max : resident + usage.ri_resident_size
                    } else if HomebrewTaskProcess.startIdentity(pid) == identity { resourceFailure = true }
                }
            }
            completion.lock.lock()
            if resourceFailure, completion.failure == nil { completion.failure = .failed }
            if resident > 512 * 1024 * 1024 { completion.failure = .outputTooLarge }
            if completion.failure == nil, isCancelled() { completion.failure = .planChanged }
            if completion.failure == nil, ProcessInfo.processInfo.systemUptime >= deadline { completion.failure = .timedOut }
            let failure = completion.failure
            completion.lock.unlock()
            if stopDeadline == nil, failure != nil { process.stop(); stopDeadline = ProcessInfo.processInfo.systemUptime + stopGrace }
            if let stopDeadline, ProcessInfo.processInfo.systemUptime >= stopDeadline {
                return Outcome(state: .unknown, response: nil, process: process)
            }
        }
        completion.lock.lock(); let result = completion.result, bytes = completion.bytes, failure = completion.failure; completion.lock.unlock()
        // Even after process reap, a killed/invalid worker may have mounted an
        // image before losing its response. Keep the private source stage for
        // explicit recovery; never infer detach from process termination.
        if let failure { return Outcome(state: .completed, response: .init(failure: failure, recoveryDirectory: request.staging), process: process) }
        guard result?.outcome == "completed", result?.exitStatus == 0,
              let response = try? JSONDecoder().decode(HomebrewNativeVendorOriginWorker.Response.self, from: bytes),
              response.version == 1,
              (response.proof != nil ? 1 : 0) + (response.sourceTreeProof != nil ? 1 : 0) + (response.failure != nil ? 1 : 0) + (response.unavailable != nil ? 1 : 0) == 1,
              response.unavailable?.utf8.count ?? 0 <= 4096,
              response.recoveryDirectory == nil || response.unavailable != nil || response.failure != nil else {
            return Outcome(state: .completed, response: .init(failure: .failed, recoveryDirectory: request.staging), process: process)
        }
        let configurationEncoder = JSONEncoder(); configurationEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let configurationSHA = HomebrewSystemAuthorization.digest(try configurationEncoder.encode(request.configuration))
        if let proof = response.proof {
            guard request.operation == nil || request.operation == .vendorOrigin,
                  proof.sourceSHA256 == request.sourceSHA256, proof.projectionSHA256 == request.projectionSHA256,
                  proof.configurationSHA256 == configurationSHA,
                  proof.token == request.token, proof.recipeExecutable == request.recipeExecutable,
                  proof.expandedBytes >= 0, proof.expandedBytes <= request.maximumBytes,
                  proof.expandedEntries >= 0, proof.expandedEntries <= request.maximumEntries,
                  proof.resourceDirectory == "original" || proof.resourceDirectory.range(of: "^payload-[0-9]{1,2}-[0-9]{1,2}$", options: .regularExpression) != nil else {
                return Outcome(state: .completed, response: .init(failure: .sourceNotAllowed, recoveryDirectory: request.staging), process: process)
            }
        }
        if let proof = response.sourceTreeProof {
            guard case .sourceTree(let purpose)? = request.operation, request.recipeExecutable.isEmpty,
                  proof.purpose == purpose, HomebrewArchiveStaging.validRelativePath(proof.selectedMember),
                  proof.sourceSHA256 == request.sourceSHA256, proof.projectionSHA256 == request.projectionSHA256,
                  proof.configurationSHA256 == configurationSHA, (1...1024).contains(proof.version.utf8.count),
                  proof.token == request.token, proof.resourceDirectory == "original",
                  proof.installerFile == nil || (proof.installerFile == "original-installer.pkg" && proof.container == .package),
                  HomebrewPrivilegePlan.validDigest(proof.resourceTreeSHA256), HomebrewPrivilegePlan.validDigest(proof.downloadSHA256),
                  HomebrewPrivilegePlan.validDigest(proof.configurationSHA256),
                  proof.expandedBytes >= 0, proof.expandedBytes <= request.maximumBytes,
                  proof.expandedEntries >= 0, proof.expandedEntries <= request.maximumEntries else {
                return Outcome(state: .completed, response: .init(failure: .sourceNotAllowed, recoveryDirectory: request.staging), process: process)
            }
            if proof.installerFile != nil {
                switch purpose {
                case .packageInstaller, .packageRemoval: break
                default: return Outcome(state: .completed, response: .init(failure: .sourceNotAllowed, recoveryDirectory: request.staging), process: process)
                }
            }
        }
        if let recovery = response.recoveryDirectory {
            func physicalAlias(_ path: String) -> String { path.hasPrefix("/tmp/") || path.hasPrefix("/var/") ? "/private" + path : path }
            let path = physicalAlias(recovery.path), stage = physicalAlias(request.staging.path)
            guard recovery.isFileURL, recovery.query == nil, recovery.fragment == nil,
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  path == stage || path.hasPrefix(stage + "/") else {
                return Outcome(state: .completed, response: .init(failure: .failed, recoveryDirectory: request.staging), process: process)
            }
        }
        return Outcome(state: .completed, response: response, process: process)
    }
}
