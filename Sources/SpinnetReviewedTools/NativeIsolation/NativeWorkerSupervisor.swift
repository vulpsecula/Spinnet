import SpinnetCore
import Foundation
import Darwin

/// Supervises an already selected fixed worker. Its caller owns request and
/// directory validation, response proofs and any retained recovery resources.
/// Only the actual reap callback releases the caller's lane, even after unknown.
enum NativeWorkerSupervisor {
    enum Outcome {
        case unknown
        case reaped(result: HomebrewTaskProcess.Result?, bytes: Data, failure: ReviewedToolFailure?)
    }

    private final class Completion {
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var bytes = Data()
        var result: HomebrewTaskProcess.Result?
        var failure: ReviewedToolFailure?
    }

    static func run(_ process: HomebrewTaskProcess, timeout: TimeInterval, maximumOutputBytes: Int,
                    stopGrace: TimeInterval, isCancelled: @escaping () -> Bool,
                    willStart: (HomebrewTaskProcess) -> Bool,
                    didReap: @escaping (HomebrewTaskProcess) -> Void) throws -> Outcome {
        guard timeout.isFinite, timeout > 0, maximumOutputBytes >= 0,
              stopGrace.isFinite, (0...20).contains(stopGrace),
              !isCancelled(), willStart(process) else { throw PluginHostServiceError.tool(.planChanged) }
        let completion = Completion()
        do {
            try process.start(output: { data in
                completion.lock.lock()
                if data.count > maximumOutputBytes - completion.bytes.count {
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

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stopGraceState = NativeStopGrace()
        while completion.done.wait(timeout: .now() + 0.01) == .timedOut {
            let usage = residentUsage(of: process)
            completion.lock.lock()
            if usage.unknown, completion.failure == nil { completion.failure = .failed }
            if usage.bytes > 512 * 1024 * 1024 { completion.failure = .outputTooLarge }
            if completion.failure == nil, isCancelled() { completion.failure = .planChanged }
            if completion.failure == nil, ProcessInfo.processInfo.systemUptime >= deadline { completion.failure = .timedOut }
            let failure = completion.failure
            completion.lock.unlock()
            stopGraceState.observe(triggered: failure != nil, now: ProcessInfo.processInfo.systemUptime, grace: stopGrace) { process.stop() }
            if stopGraceState.hasExpired(at: ProcessInfo.processInfo.systemUptime) { return .unknown }
        }
        completion.lock.lock(); defer { completion.lock.unlock() }
        return .reaped(result: completion.result, bytes: completion.bytes, failure: completion.failure)
    }

    private static func residentUsage(of process: HomebrewTaskProcess) -> (bytes: UInt64, unknown: Bool) {
        var resident: UInt64 = 0, unknown = false
        // Include owned descendants in escaped groups, bound to their original
        // PID births. A recycled PID never acquires RSS or signal authority.
        for (pid, identity) in process.ownedProcessIdentities where HomebrewTaskProcess.startIdentity(pid) == identity {
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
            }
            if status == 0 {
                resident = resident > UInt64.max - usage.ri_resident_size ? UInt64.max : resident + usage.ri_resident_size
            } else if HomebrewTaskProcess.startIdentity(pid) == identity { unknown = true }
        }
        return (resident, unknown)
    }
}
