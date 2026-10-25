import Foundation
import Darwin

/// Read-only worker lifetime. The caller retains the exact sealed tool copies
/// and any Task lane until didReap; unknown never grants removal authority.
public enum HomebrewNativeLaunchServiceExecution {
    public enum State { case completed, unknown }
    public struct Outcome {
        public let state: State
        public let response: HomebrewNativeLaunchServiceInventory.Response?
        public let process: HomebrewTaskProcess
        public let diagnostic: String?
        init(state: State, response: HomebrewNativeLaunchServiceInventory.Response?, process: HomebrewTaskProcess, diagnostic: String? = nil) {
            self.state = state; self.response = response; self.process = process; self.diagnostic = diagnostic
        }
    }
    private final class Completion {
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var bytes = Data(), failure: ReviewedToolFailure?, result: HomebrewTaskProcess.Result?
    }
    public static func capture(_ request: HomebrewNativeLaunchServiceInventory.Request, toolsDirectory: URL,
        stopGrace: TimeInterval = 2, isCancelled: @escaping () -> Bool = { false },
        willStart: (HomebrewTaskProcess) -> Bool = { _ in true }, didReap: @escaping (HomebrewTaskProcess) -> Void = { _ in }) throws -> Outcome {
        try request.context.validate()
        let remaining = request.deadline.timeIntervalSinceNow
        guard request.version == 1, request.deadline.timeIntervalSince1970.isFinite, remaining > 0, remaining <= 30,
              stopGrace.isFinite, (0...20).contains(stopGrace), !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
        let input = try JSONEncoder().encode(request)
        guard input.count <= HomebrewNativeLaunchServiceInventory.maximumRequestBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        if getuid() == 0 {
            let path = toolsDirectory.path
            guard path.hasPrefix("/private/var/tmp/spinnet-native-tools-"), !path.dropFirst("/private/var/tmp/".count).contains("/") else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            let frozen = try NativeFileQuarantine.capture(toolsDirectory)
            guard frozen.directory, frozen.owner == 0, frozen.mode & 0o022 == 0, !frozen.writableACL else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        }
        let process = HomebrewTaskProcess(executable: toolsDirectory.appendingPathComponent("SpinnetLaunchServiceInventory"), arguments: ["--capture"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
            interruptGrace: 0.2, terminateGrace: 0.2, standardInput: input)
        let completion = Completion()
        guard !isCancelled(), willStart(process) else { throw PluginHostServiceError.tool(.planChanged) }
        do {
            try process.start(output: { data in
                completion.lock.lock()
                if completion.bytes.count + data.count > HomebrewNativeLaunchServiceInventory.maximumOutputBytes { completion.failure = .outputTooLarge }
                else { completion.bytes.append(data) }
                let stop = completion.failure != nil; completion.lock.unlock()
                if stop { process.stop() }
            }, finished: { result in
                completion.lock.lock(); completion.result = result; completion.lock.unlock()
                didReap(process); completion.done.signal()
            })
        } catch { didReap(process); throw error }
        let deadline = ProcessInfo.processInfo.systemUptime + remaining
        var stopGraceState = NativeStopGrace()
        while completion.done.wait(timeout: .now() + 0.01) == .timedOut {
            var resident: UInt64 = 0, unknown = false
            for (pid, identity) in process.ownedProcessIdentities where HomebrewTaskProcess.startIdentity(pid) == identity {
                var usage = rusage_info_v2()
                let status = withUnsafeMutablePointer(to: &usage) { pointer in
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
                }
                if status == 0 { resident = resident > UInt64.max - usage.ri_resident_size ? UInt64.max : resident + usage.ri_resident_size }
                else if HomebrewTaskProcess.startIdentity(pid) == identity { unknown = true }
            }
            completion.lock.lock()
            if unknown, completion.failure == nil { completion.failure = .failed }
            if resident > 512 * 1024 * 1024 { completion.failure = .outputTooLarge }
            if completion.failure == nil, isCancelled() { completion.failure = .planChanged }
            if completion.failure == nil, ProcessInfo.processInfo.systemUptime >= deadline { completion.failure = .timedOut }
            let failure = completion.failure; completion.lock.unlock()
            stopGraceState.observe(triggered: failure != nil, now: ProcessInfo.processInfo.systemUptime, grace: stopGrace) { process.stop() }
            if stopGraceState.hasExpired(at: ProcessInfo.processInfo.systemUptime) { return .init(state: .unknown, response: nil, process: process) }
        }
        completion.lock.lock(); let result = completion.result, failure = completion.failure, bytes = completion.bytes; completion.lock.unlock()
        let execution = "worker \(result?.outcome ?? "unknown"), exit \(result.map { String($0.exitStatus) } ?? "unknown"), \(bytes.count) output bytes"
        if let failure { return .init(state: .completed, response: .init(failure: failure), process: process, diagnostic: "\(execution); process resource inspection failed") }
        guard result?.outcome == "completed", result?.exitStatus == 0,
              let response = try? JSONDecoder().decode(HomebrewNativeLaunchServiceInventory.Response.self, from: bytes), response.version == 1,
              (response.manifest != nil ? 1 : 0) + (response.failure != nil ? 1 : 0) + (response.unavailable != nil ? 1 : 0) == 1,
              response.unavailable?.utf8.count ?? 0 <= 4096 else { return .init(state: .completed, response: .init(failure: .failed), process: process, diagnostic: "\(execution); no valid inventory reply") }
        if let manifest = response.manifest {
            do { try HomebrewNativeLaunchServices.validateNative(manifest, context: request.context, declarations: request.declarations) }
            catch { return .init(state: .completed, response: .init(failure: .sourceNotAllowed), process: process) }
        }
        return .init(state: .completed, response: response, process: process, diagnostic: response.failure == .failed ? "\(execution); inventory reported failure" : nil)
    }
}
