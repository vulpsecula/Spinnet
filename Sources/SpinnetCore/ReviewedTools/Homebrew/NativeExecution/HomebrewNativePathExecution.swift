import Foundation
import Darwin

/// Fixed signed mutation process supervision. Root authorization and task
/// admission remain in the caller; no Plugin can choose this executable,
/// argv, environment, native manifest or recovery directory.
public enum HomebrewNativePathExecution {
    public enum State { case completed, failed, unknown }
    public struct Outcome {
        public let state: State
        public let response: HomebrewPathRemoval.Response?
    }
    public static func execute(_ manifest: HomebrewPathManifest.Manifest, staging: URL, deadline: Date,
                               isCancelled: @escaping () -> Bool = { false },
                               willStart: @escaping (HomebrewTaskProcess) -> Bool = { _ in true },
                               didReap: @escaping (HomebrewTaskProcess) -> Void = { _ in }) throws -> Outcome {
        try manifest.validateSeal()
        guard Date() < deadline, !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
        let selectedDeadline = min(deadline, Date().addingTimeInterval(60))
        let tools = try NativeSignedToolStaging.capture(["SpinnetPathRemoval"], deadline: min(selectedDeadline, Date().addingTimeInterval(15)), isCancelled: isCancelled)
        let input: Data
        do { input = try JSONEncoder().encode(HomebrewPathRemoval.Request(manifest: manifest, staging: staging, deadline: selectedDeadline)) }
        catch { tools.remove(); throw error }
        guard input.count <= 32 * 1024 * 1024 else { tools.remove(); throw PluginHostServiceError.tool(.outputTooLarge) }
        let process = HomebrewTaskProcess(executable: tools.tools["SpinnetPathRemoval"]!, arguments: ["--remove"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "C"],
            interruptGrace: 10, terminateGrace: 5, standardInput: input, inputPolicy: .nativeManifest)
        let done = DispatchSemaphore(value: 0), lock = NSLock()
        var output = Data(), processResult: HomebrewTaskProcess.Result?, exceeded = false
        // The caller retains the process before spawn. Stop can prevent launch
        // even while the fixed bounded stdin file is being prepared.
        guard willStart(process) else { tools.remove(); throw PluginHostServiceError.tool(.planChanged) }
        do {
            try process.start(output: { chunk in
                lock.lock()
                if output.count + chunk.count > 32 * 1024 * 1024 { exceeded = true }
                else if !exceeded { output.append(chunk) }
                let stop = exceeded; lock.unlock()
                if stop { process.stop() }
            }, finished: { result in
                lock.lock(); processResult = result; lock.unlock()
                didReap(process); tools.remove(); done.signal()
            })
        } catch { didReap(process); tools.remove(); throw error }
        let absolute = ProcessInfo.processInfo.systemUptime + max(0, selectedDeadline.timeIntervalSinceNow)
        var stopSince: TimeInterval?
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            var usage = rusage_info_v4()
            let memory = withUnsafeMutablePointer(to: &usage) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(process.processIdentifier, RUSAGE_INFO_V4, $0) } }
            lock.lock()
            if memory == 0 && usage.ri_phys_footprint > 512 * 1024 * 1024 { exceeded = true }
            // A live process with unavailable native accounting cannot prove
            // its memory bound. A reaped leader may briefly await pipe drain.
            if memory != 0 && HomebrewTaskProcess.startIdentity(process.processIdentifier) != nil { exceeded = true }
            let overBudget = exceeded; lock.unlock()
            if isCancelled() || overBudget || ProcessInfo.processInfo.systemUptime > absolute {
                if stopSince == nil { stopSince = ProcessInfo.processInfo.systemUptime }
                process.stop()
            }
            // A blocked kernel call can outlive kill. Journals and the caller's
            // lane survive until the async reaper completes; no automatic replay.
            if let stopSince, ProcessInfo.processInfo.systemUptime - stopSince > 20 { return .init(state: .unknown, response: nil) }
        }
        lock.lock(); let bytes = output, result = processResult, tooLarge = exceeded; lock.unlock()
        guard !tooLarge, let result, let response = try? JSONDecoder().decode(HomebrewPathRemoval.Response.self, from: bytes),
              validResponse(response, manifest: manifest, staging: staging) else { return .init(state: .unknown, response: nil) }
        if response.failure == nil, response.unavailable == nil, result.outcome == "completed" {
            guard let progress = response.result, progress.quarantined.isEmpty, progress.retained.allSatisfy({ $0.reason == "nonempty" }),
                  Set(manifest.entries.map(\.path) + manifest.retainedDirectories.map(\.path)).isSubset(of: Set(progress.removed + progress.retained.map(\.path))) else {
                return .init(state: .unknown, response: nil)
            }
            return .init(state: .completed, response: response)
        }
        return .init(state: .failed, response: response)
    }
    private static func validResponse(_ response: HomebrewPathRemoval.Response, manifest: HomebrewPathManifest.Manifest, staging: URL) -> Bool {
        guard response.version == 1, response.unavailable == nil || response.unavailable!.utf8.count <= 1024 else { return false }
        if response.unavailable != nil { return response.result == nil && response.failure == nil }
        guard let progress = response.result else { return response.failure != nil }
        let allowed = Set(manifest.entries.map(\.path) + manifest.retainedDirectories.map(\.path))
        let removed = Set(progress.removed), retained = Set(progress.retained.map(\.path))
        return progress.removed.count <= HomebrewPathManifest.maximumEntries && removed.count == progress.removed.count
            && progress.retained.count <= HomebrewPathManifest.maximumEntries && retained.count == progress.retained.count
            && removed.isSubset(of: allowed) && retained.isSubset(of: allowed) && removed.isDisjoint(with: retained)
            && progress.retained.allSatisfy({ ["nonempty", "restoreFailed"].contains($0.reason) })
            && progress.quarantined.count <= HomebrewPathManifest.maximumEntries
            && progress.quarantined.allSatisfy({ path in
                guard path.hasPrefix(staging.path + "/"), path.utf8.count <= 2048 else { return false }
                let leaf = String(path.dropFirst(staging.path.count + 1))
                return leaf.hasPrefix("removed-") && UUID(uuidString: String(leaf.dropFirst(8))) != nil
            })
    }
}
