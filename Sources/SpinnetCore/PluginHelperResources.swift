import Foundation
import Darwin

/// The resource budget enforced for every Plugin helper process.
public enum PluginHelperResourceLimits {
    public static let physFootprintBytes: UInt64 = 64 * 1024 * 1024
    public static let sampleInterval: TimeInterval = 0.1
    public static let consecutiveSamplesRequired = 2
}

public typealias PluginHelperResourceSamplerClosure = (Int32) -> UInt64?
public typealias PluginHelperResourceScheduler =
    (TimeInterval, @escaping () -> Void) -> Void

/// Samples a helper's physical footprint without asking for a task port.
/// `proc_pid_rusage` is available to the Host for its child processes and
/// reports the same `phys_footprint` accounting used by the macOS process
/// tools.
public enum PluginHelperResourceSampler {
    public static func physFootprint(processID: Int32) -> UInt64? {
        guard processID > 0 else { return nil }

        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(processID, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return usage.ri_phys_footprint
    }

    public static func physFootprint(for processID: Int32) -> UInt64? {
        physFootprint(processID: processID)
    }
}

/// Repeatedly samples one helper and reports a limit breach after the
/// required number of consecutive samples. Scheduled callbacks are weak so a
/// retired helper does not stay alive solely because a timer is pending.
final class PluginHelperResourceMonitor {
    typealias Sample = PluginHelperResourceSamplerClosure
    typealias Schedule = PluginHelperResourceScheduler

    private let process: Process
    private let sample: Sample
    private let schedule: Schedule
    private let limitBytes: UInt64
    private let onLimitExceeded: (UInt64) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var consecutiveHighSamples = 0

    init(
        process: Process,
        sample: @escaping Sample,
        schedule: @escaping Schedule,
        limitBytes: UInt64,
        onLimitExceeded: @escaping (UInt64) -> Void
    ) {
        self.process = process
        self.sample = sample
        self.schedule = schedule
        self.limitBytes = limitBytes
        self.onLimitExceeded = onLimitExceeded
    }

    func start() {
        scheduleNext(after: 0)
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private func scheduleNext(after delay: TimeInterval) {
        schedule(delay) { [weak self] in
            self?.sampleAndSchedule()
        }
    }

    private func sampleAndSchedule() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard process.isRunning else {
            stop()
            return
        }

        let footprint = sample(process.processIdentifier)
        var limitExceeded = false
        var exceededBytes: UInt64 = 0

        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        if let footprint, footprint >= limitBytes {
            consecutiveHighSamples += 1
            if consecutiveHighSamples >= PluginHelperResourceLimits.consecutiveSamplesRequired {
                stopped = true
                limitExceeded = true
                exceededBytes = footprint
            }
        } else {
            consecutiveHighSamples = 0
        }
        lock.unlock()

        if limitExceeded {
            onLimitExceeded(exceededBytes)
        } else {
            scheduleNext(after: PluginHelperResourceLimits.sampleInterval)
        }
    }
}
