import Foundation
import Darwin

/// Owns process lifetimes separately from the thread performing an Action.
/// The condition protects startup, retirement and per-Plugin queue admission.
final class PluginHelperPool {
    final class Lease {
        let pluginID: PluginID
        var helper: PluginHelperProcess?
        var retired = false
        var busy = false
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
        condition.lock()
        defer { condition.unlock() }
        guard !stopped else { throw PluginRuntimeError.helperTerminated }
        try control.check()
        let lease = leases[pluginID] ?? Lease(pluginID: pluginID)
        leases[pluginID] = lease
        while lease.busy && !lease.retired {
            try control.check()
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
        }
        try control.check()
        guard !lease.retired, !stopped else { throw PluginRuntimeError.helperTerminated }
        lease.busy = true
        lease.idleToken = UUID()
        return lease
    }

    func start(_ lease: Lease, create: () throws -> PluginHelperProcess) throws -> PluginHelperProcess {
        condition.lock()
        defer { condition.unlock() }
        guard !lease.retired, !stopped else { throw PluginRuntimeError.helperTerminated }
        if let helper = lease.helper, helper.isUsable { return helper }
        lease.helper?.terminate()
        let helper = try create()
        lease.helper = helper
        return helper
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

    func terminate(_ lease: Lease) {
        condition.lock()
        retire(lease)
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
        for (token, entry) in retiring where entry.pluginID == pluginID {
            entry.helper.terminate()
            retiring.removeValue(forKey: token)
        }
        condition.unlock()
    }

    private func retire(_ lease: Lease) {
        lease.retired = true
        lease.helper?.terminate()
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
    let input: FileHandle
    private let output: FileHandle
    private let condition = NSCondition()
    private var frame: Data?
    private var failure: PluginRuntimeError?
    private var awaitingMessage = false
    private var exiting = false

    init(process: Process, input: Pipe, output: Pipe) {
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { self.readMessages() }
    }

    var isUsable: Bool {
        condition.lock()
        defer { condition.unlock() }
        return failure == nil && !exiting && process.isRunning
    }

    func beginInvocation() throws {
        condition.lock()
        defer { condition.unlock() }
        if let failure { throw failure }
        guard !exiting, !awaitingMessage, frame == nil else {
            throw PluginRuntimeError.protocolViolation("Invocation is out of order")
        }
        awaitingMessage = true
    }

    func readFrame(timeout: TimeInterval) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while frame == nil && failure == nil {
            guard condition.wait(until: deadline) else { throw PluginRuntimeError.timedOut }
        }
        // A valid terminal can precede normal EOF from a helper. Deliver it.
        if let frame {
            self.frame = nil
            condition.broadcast()
            return frame
        }
        throw failure ?? .helperTerminated
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

    func terminate() {
        condition.lock()
        exiting = true
        if failure == nil { failure = .helperTerminated }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        try? input.close()
        condition.broadcast()
        condition.unlock()
        waitForExit()
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
                if type == .terminal { awaitingMessage = false }
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
            } else {
                error = .protocolViolation("Terminal result is missing")
            }
            fail(error)
        } catch {
            fail((error as? PluginRuntimeError) ?? .protocolViolation("Plugin message could not be read"))
            terminate()
        }
    }

    private func fail(_ error: PluginRuntimeError) {
        condition.lock()
        if failure == nil { failure = error }
        condition.broadcast()
        condition.unlock()
    }
}
