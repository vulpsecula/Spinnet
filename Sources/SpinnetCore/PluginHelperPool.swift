import Foundation
import Darwin

/// Owns process lifetimes separately from the thread performing an Action.
/// The condition protects startup, retirement and per-Plugin queue admission.
final class PluginHelperPool {
    enum StartError: Error {
        case replacementRequired
    }

    struct StartedHelper {
        let lease: Lease
        let helper: PluginHelperProcess
    }

    final class Lease {
        final class Waiter {
            let wasBusyAtArrival: Bool

            init(wasBusyAtArrival: Bool) {
                self.wasBusyAtArrival = wasBusyAtArrival
            }
        }

        let pluginID: PluginID
        var helper: PluginHelperProcess?
        var retired = false
        var busy = false
        var waiters: [Waiter] = []
        var retirementReason: PluginRuntimeError?
        var retirementAllowsReplacement = false
        // Set for the Action currently owning this lease. A waiter that was
        // already behind a busy helper must observe a retirement instead of
        // starting replacement work on the new helper generation.
        var waitedForBusy = false
        var idleToken = UUID()
        init(pluginID: PluginID) { self.pluginID = pluginID }
    }

    private let condition = NSCondition()
    private var leases: [PluginID: Lease] = [:]
    private var retiring: [UUID: (pluginID: PluginID, helper: PluginHelperProcess)] = [:]
    private var stopped = false
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.schedule = schedule
    }

    func acquire(pluginID: PluginID, control: ActionExecutionControl) throws -> Lease {
        while true {
            condition.lock()
            guard !stopped else {
                condition.unlock()
                throw PluginRuntimeError.helperTerminated
            }
            do {
                try control.check()
            } catch {
                condition.unlock()
                throw error
            }

            let lease = leases[pluginID] ?? Lease(pluginID: pluginID)
            leases[pluginID] = lease
            if !lease.busy, lease.waiters.isEmpty, !lease.retired {
                lease.busy = true
                lease.waitedForBusy = false
                lease.idleToken = UUID()
                condition.unlock()
                return lease
            }

            // Keep explicit arrivals behind an already queued Action. This
            // prevents a new caller from stealing the idle window after the
            // previous Action releases the lease but before its waiter wakes.
            let waiter = Lease.Waiter(wasBusyAtArrival: lease.busy)
            lease.waiters.append(waiter)
            while true {
                do {
                    try control.check()
                } catch {
                    remove(waiter, from: lease)
                    condition.unlock()
                    throw error
                }
                if lease.retired {
                    remove(waiter, from: lease)
                    let reason = lease.retirementReason ?? .helperTerminated
                    condition.unlock()
                    if waiter.wasBusyAtArrival || !lease.retirementAllowsReplacement {
                        throw reason
                    }
                    // An explicit Action that arrived after the lease became
                    // idle may retry against the fresh lease generation.
                    break
                }
                if !lease.busy, lease.waiters.first === waiter {
                    lease.waiters.removeFirst()
                    lease.busy = true
                    lease.waitedForBusy = waiter.wasBusyAtArrival
                    lease.idleToken = UUID()
                    condition.unlock()
                    return lease
                }
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
    }

    private func remove(_ waiter: Lease.Waiter, from lease: Lease) {
        if let index = lease.waiters.firstIndex(where: { $0 === waiter }) {
            lease.waiters.remove(at: index)
            condition.broadcast()
        }
    }

    func waitingActionCount(for pluginID: PluginID) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return leases[pluginID]?.waiters.count ?? 0
    }

    func start(
        _ lease: Lease,
        control: ActionExecutionControl,
        create: (Lease) throws -> PluginHelperProcess,
        allowLeaseReplacement: Bool = true
    ) throws -> StartedHelper {
        condition.lock()
        let waitedForBusy = lease.waitedForBusy
        lease.waitedForBusy = false
        guard !stopped else {
            condition.unlock()
            throw PluginRuntimeError.helperTerminated
        }
        if lease.retired {
            let reason = lease.retirementReason ?? .helperTerminated
            let allowsReplacement = lease.retirementAllowsReplacement
            condition.unlock()
            if waitedForBusy || !allowsReplacement { throw reason }
            guard allowLeaseReplacement else { throw StartError.replacementRequired }
            let replacement = try acquire(pluginID: lease.pluginID, control: control)
            do {
                return try start(
                    replacement,
                    control: control,
                    create: create,
                    allowLeaseReplacement: true
                )
            } catch {
                release(replacement)
                throw error
            }
        }
        if let helper = lease.helper, helper.isUsable {
            condition.unlock()
            return StartedHelper(lease: lease, helper: helper)
        }
        if let helper = lease.helper {
            if let failure = helper.failureIfUnusable() {
                if waitedForBusy {
                    retire(lease, reason: failure, allowsReplacement: true)
                    condition.unlock()
                    throw failure
                }
                retire(lease, reason: failure, allowsReplacement: true)
                condition.unlock()
                guard allowLeaseReplacement else { throw StartError.replacementRequired }
                let replacement = try acquire(pluginID: lease.pluginID, control: control)
                do {
                    return try start(
                        replacement,
                        control: control,
                        create: create,
                        allowLeaseReplacement: true
                    )
                } catch {
                    release(replacement)
                    throw error
                }
            }
            helper.terminate()
            lease.helper = nil
        }
        let helper: PluginHelperProcess
        do {
            helper = try create(lease)
            lease.helper = helper
        } catch {
            condition.unlock()
            throw error
        }
        condition.unlock()
        helper.startResourceMonitor()
        return StartedHelper(lease: lease, helper: helper)
    }

    func release(_ lease: Lease) {
        condition.lock()
        lease.busy = false
        let token = UUID()
        lease.idleToken = token
        let shouldSchedule = !lease.retired && lease.helper != nil
        if lease.helper == nil, leases[lease.pluginID] === lease {
            lease.retired = true
            leases.removeValue(forKey: lease.pluginID)
        }
        condition.broadcast()
        condition.unlock()
        guard shouldSchedule else { return }
        schedule(30) { [weak self, weak lease] in
            guard let self, let lease else { return }
            self.retireIdle(lease, token: token)
        }
    }

    private func retireIdle(_ lease: Lease, token: UUID) {
        condition.lock()
        guard !lease.retired, !lease.busy, lease.idleToken == token,
              let helper = lease.helper else { condition.unlock(); return }
        lease.retired = true
        leases.removeValue(forKey: lease.pluginID)
        retiring[token] = (lease.pluginID, helper)
        helper.requestExit()
        condition.unlock()
        schedule(0.25) { [weak self] in
            guard let self else { return }
            self.condition.lock()
            self.retiring.removeValue(forKey: token)?.helper.terminate()
            self.condition.unlock()
        }
    }

    func terminate(_ lease: Lease, reason: PluginRuntimeError = .helperTerminated) {
        condition.lock()
        retire(lease, reason: reason)
        condition.unlock()
    }

    func terminate(
        _ lease: Lease,
        helper: PluginHelperProcess,
        reason: PluginRuntimeError = .helperTerminated,
        preservingCompletedTerminal: Bool = false
    ) {
        condition.lock()
        guard !lease.retired, lease.helper === helper else {
            condition.unlock()
            return
        }
        retire(
            lease,
            reason: reason,
            preservingCompletedTerminal: preservingCompletedTerminal,
            allowsReplacement: true
        )
        condition.unlock()
    }

    func cancellation(for lease: Lease) -> () -> Void {
        condition.lock()
        let token = lease.idleToken
        condition.unlock()
        return { [weak self, weak lease] in
            guard let self, let lease else { return }
            self.condition.lock()
            defer { self.condition.unlock() }
            // A stop callback may already have been copied by an earlier
            // Action's control when that Action hands the helper back.
            guard lease.busy, lease.idleToken == token else { return }
            self.retire(lease)
        }
    }

    func terminate(pluginID: PluginID) {
        condition.lock()
        if let lease = leases[pluginID] { retire(lease) }
        for token in Array(retiring.keys) {
            guard let entry = retiring[token], entry.pluginID == pluginID else { continue }
            entry.helper.terminate()
            retiring.removeValue(forKey: token)
        }
        condition.unlock()
    }

    private func retire(
        _ lease: Lease,
        reason: PluginRuntimeError = .helperTerminated,
        preservingCompletedTerminal: Bool = false,
        allowsReplacement: Bool = false
    ) {
        guard !lease.retired else { return }
        lease.retired = true
        lease.retirementReason = reason
        lease.retirementAllowsReplacement = allowsReplacement
        lease.helper?.terminate(
            reason: reason,
            preservingCompletedTerminal: preservingCompletedTerminal
        )
        if leases[lease.pluginID] === lease { leases.removeValue(forKey: lease.pluginID) }
        condition.broadcast()
    }

    func shutdown() {
        condition.lock()
        stopped = true
        for lease in Array(leases.values) { retire(lease) }
        for entry in retiring.values { entry.helper.terminate() }
        retiring.removeAll()
        condition.unlock()
    }
}

/// A single reader owns stdout for the entire connection, including idle time.
/// Only one message can wait for the Action thread; unsolicited output retires
/// the process without buffering unbounded data or replaying a finished Action.
final class PluginHelperProcess {
    let process: Process
    // Keep the Pipe owners alive for the whole warm connection. Retaining only
    // their file handles lets the temporary Pipe deallocate after launch,
    // closing stdin/stdout and making the helper mistake that for Host EOF.
    private let inputPipe: Pipe
    private let outputPipe: Pipe
    let input: FileHandle
    private let output: FileHandle
    private let pluginID: PluginID
    private let resourceLimitBytes: UInt64
    private let onFailure: ((PluginHelperProcess, PluginRuntimeError, Bool) -> Void)?
    private var resourceMonitor: PluginHelperResourceMonitor?
    private let condition = NSCondition()
    private var frame: Data?
    private var failure: PluginRuntimeError?
    private var invalidatesBufferedFrame = false
    private var bufferedTerminal = false
    private var terminalDelivered = false
    private var awaitingMessage = false
    private var exiting = false

    init(
        process: Process,
        input: Pipe,
        output: Pipe,
        pluginID: PluginID,
        resourceSampler: @escaping PluginHelperResourceMonitor.Sample,
        resourceSchedule: @escaping PluginHelperResourceMonitor.Schedule,
        resourceLimitBytes: UInt64,
        onFailure: ((PluginHelperProcess, PluginRuntimeError, Bool) -> Void)? = nil
    ) {
        self.process = process
        self.inputPipe = input
        self.outputPipe = output
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
        self.pluginID = pluginID
        self.resourceLimitBytes = resourceLimitBytes
        self.onFailure = onFailure
        self.resourceMonitor = PluginHelperResourceMonitor(
            process: process,
            sample: resourceSampler,
            schedule: resourceSchedule,
            limitBytes: resourceLimitBytes,
            onLimitExceeded: { [weak self] footprint in
                self?.resourceLimitExceeded(footprint: footprint)
            }
        )
        // The reader blocks on the helper pipe for the whole warm connection.
        // Give each helper its own thread so one idle Plugin cannot consume a
        // shared global-queue worker needed by another Plugin.
        Thread.detachNewThread { [self] in readMessages() }
    }

    var isUsable: Bool {
        condition.lock()
        defer { condition.unlock() }
        return failure == nil && !exiting && process.isRunning
    }

    /// Returns a fault that must retire this helper. A cleanly exited helper
    /// can be replaced for a later Action; callers that were queued behind a
    /// busy helper retire the lease so they observe a fault instead.
    func failureIfUnusable() -> PluginRuntimeError? {
        condition.lock()
        defer { condition.unlock() }
        if invalidatesBufferedFrame { return failure ?? .helperTerminated }
        if let failure { return failure }
        if exiting { return .helperTerminated }
        guard !process.isRunning else { return .helperTerminated }
        if process.terminationReason == .exit, process.terminationStatus == 0 {
            return nil
        }
        if process.terminationReason == .uncaughtSignal {
            switch process.terminationStatus {
            case SIGTERM, SIGKILL: return .helperTerminated
            default: return .helperCrashed(signal: process.terminationStatus)
            }
        }
        return .helperTerminated
    }

    func beginInvocation() throws {
        condition.lock()
        defer { condition.unlock() }
        if let failure { throw failure }
        guard !exiting, !awaitingMessage, frame == nil else {
            throw PluginRuntimeError.protocolViolation("Invocation is out of order")
        }
        terminalDelivered = false
        awaitingMessage = true
    }

    func readFrame(timeout: TimeInterval) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while frame == nil && failure == nil {
            guard condition.wait(until: deadline) else { throw PluginRuntimeError.timedOut }
        }
        if invalidatesBufferedFrame, let failure {
            frame = nil
            condition.broadcast()
            throw failure
        }
        // A valid terminal can precede normal EOF from a helper. Deliver it.
        if let frame {
            self.frame = nil
            if bufferedTerminal {
                terminalDelivered = true
                bufferedTerminal = false
            }
            condition.broadcast()
            return frame
        }
        throw failure ?? .helperTerminated
    }

    func checkForInvalidation() throws {
        condition.lock()
        defer { condition.unlock() }
        guard invalidatesBufferedFrame else { return }
        throw failure ?? .helperTerminated
    }

    func invalidationError() -> PluginRuntimeError? {
        condition.lock()
        defer { condition.unlock() }
        guard invalidatesBufferedFrame else { return nil }
        return failure ?? .helperTerminated
    }

    func startResourceMonitor() {
        resourceMonitor?.start()
    }

    func requestExit() {
        condition.lock()
        defer { condition.unlock() }
        guard !exiting else { return }
        exiting = true
        // An idle helper has no request in flight, so this small write cannot
        // fill its input pipe. EOF is also a graceful Host-disconnect signal.
        try? input.write(contentsOf: Data("{\"type\":\"shutdown\",\"protocol_version\":\"1.0\"}\n".utf8))
        try? input.close()
    }

    func terminate(
        reason: PluginRuntimeError = .helperTerminated,
        preservingCompletedTerminal: Bool = false
    ) {
        resourceMonitor?.stop()
        condition.lock()
        exiting = true
        if failure == nil { failure = reason }
        let preserveTerminal = preservingCompletedTerminal
            && !process.isRunning
            && (terminalDelivered || bufferedTerminal)
        if !preserveTerminal {
            invalidatesBufferedFrame = true
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        try? input.close()
        condition.broadcast()
        condition.unlock()
        if !preserveTerminal { waitForExit() }
    }

    private func resourceLimitExceeded(footprint: UInt64) {
        PluginRuntimeDiagnostics.helperResourceExceeded(
            pluginID: pluginID,
            processID: process.processIdentifier,
            footprint: footprint,
            limit: resourceLimitBytes
        )
        onFailure?(self, .helperResourceExceeded, false)
        terminate(reason: .helperResourceExceeded)
    }

    private func waitForExit() {
        // Foundation's waitUntilExit spins the calling thread's run loop.
        // Concurrent reader/shutdown waits can leave an AppKit main thread
        // stuck in that loop even after the process has exited. Observe the
        // Process exit state without starting a nested run loop instead.
        while process.isRunning { Thread.sleep(forTimeInterval: 0.001) }
    }

    private func readMessages() {
        defer { try? output.close() }
        do {
            while let data = try PluginRuntimeProtocol.readFrame(from: output, label: "Plugin message") {
                let type = try PluginRuntimeProtocol.decodeMessageType(data)
                condition.lock()
                guard awaitingMessage, frame == nil, !exiting else {
                    condition.unlock()
                    throw PluginRuntimeError.protocolViolation("Unexpected message from Plugin helper")
                }
                if type == .terminal {
                    awaitingMessage = false
                    bufferedTerminal = true
                }
                frame = data
                condition.broadcast()
                // Host Service replies are written only after consuming this
                // frame. A second unsolicited message must never overwrite it.
                condition.unlock()
            }
            waitForExit()
            let error: PluginRuntimeError
            if process.terminationReason == .uncaughtSignal {
                switch process.terminationStatus {
                case SIGTERM, SIGKILL: error = .helperTerminated
                default: error = .helperCrashed(signal: process.terminationStatus)
                }
                fail(error, invalidatesBufferedFrame: true)
                if !isExitingNow { onFailure?(self, error, false) }
                return
            } else if isExitingNormally {
                return
            } else if hasCompletedTerminal,
                      process.terminationReason == .exit,
                      process.terminationStatus != 0 {
                fail(.helperTerminated)
                if !isExitingNow { onFailure?(self, .helperTerminated, true) }
                return
            } else if hasCompletedTerminal {
                return
            } else {
                error = .protocolViolation("Terminal result is missing")
            }
            fail(error, invalidatesBufferedFrame: true)
            if !isExitingNow { onFailure?(self, error, false) }
        } catch {
            let runtimeError = (error as? PluginRuntimeError)
                ?? .protocolViolation("Plugin message could not be read")
            fail(runtimeError, invalidatesBufferedFrame: true)
            if !isExitingNow { onFailure?(self, runtimeError, false) }
            terminate(reason: runtimeError)
        }
    }

    private func fail(_ error: PluginRuntimeError, invalidatesBufferedFrame: Bool = false) {
        condition.lock()
        if failure == nil { failure = error }
        if invalidatesBufferedFrame { self.invalidatesBufferedFrame = true }
        condition.broadcast()
        condition.unlock()
    }

    private var isExitingNormally: Bool {
        condition.lock()
        defer { condition.unlock() }
        return exiting && process.terminationReason == .exit && process.terminationStatus == 0
    }

    private var hasCompletedTerminal: Bool {
        condition.lock()
        defer { condition.unlock() }
        return terminalDelivered || bufferedTerminal
    }

    private var isExitingNow: Bool {
        condition.lock()
        defer { condition.unlock() }
        return exiting
    }
}
