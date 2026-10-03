import Foundation
import Darwin
import SpinnetCore

/// Monotonic time in nanoseconds, the clock every sample is taken with.
enum Clock {
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(Int64(end) - Int64(start)) / 1_000_000
    }

    static func sleep(until deadline: UInt64) {
        while true {
            let now = now()
            guard now < deadline else { return }
            let remaining = deadline - now
            var interval = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
            nanosleep(&interval, nil)
        }
    }

    static func sleep(milliseconds: Int) { sleep(until: now() + UInt64(milliseconds) * 1_000_000) }
}

/// One View Event's run through the Action runner, as the Plugin queue saw it.
struct EventRun {
    let event: PluginViewEvent?
    /// When the session handed the event to the Plugin queue.
    let dispatched: UInt64
    /// When the queue began it; the script's deadline starts here.
    let began: UInt64
    /// When the runner returned its outcome.
    let ended: UInt64
}

/// What one timed interaction produced, before it becomes a sample.
struct Interaction {
    /// When the last input reached the session.
    var lastInput: UInt64 = 0
    /// When the session presented the answer to it, not busy.
    var answered: UInt64 = 0
    var failure: String?
    var runs: [EventRun] = []
    var helperLaunches = 0
}

/// The Host's View Session wiring, as `SpinnetHost/main.swift` builds it, over
/// the real `SpinnetPluginHelper`: one serial Plugin queue at user-initiated
/// QoS, the Action runner and its registry, the sessions confined to the main
/// queue, and the debounce and deadlines scheduled on it. Only the renderer
/// is replaced, by one that records when each presentation arrives; nothing
/// is drawn.
final class ViewSessionRig {
    let package: PluginPackage
    let action: ActionConfiguration
    let supervisor: PluginRuntimeSupervisor
    private let registry = PluginRegistry()
    private let runner: HostActionRunner
    private let processes = HelperProcesses()
    private let renderer = ObservingRenderer()
    private let pluginQueue: DispatchQueue
    private let runLog = RunLog()
    /// Main-queue confined.
    private var sessions: PluginViewSessions!

    /// With `grantStore`, revoking a Capability ends the session and retires
    /// the helper, as the Host wires both to its own store.
    init(helperURL: URL, fixtureURL: URL, grantStore: PluginCapabilityGrantStore? = nil) throws {
        package = try PluginManifestLoader.load(packageAt: fixtureURL)
        try registry.register(package)
        guard let command = package.manifest.commands.first(where: { $0.execution == .javascript }) else {
            throw MeasurementError("\(fixtureURL.lastPathComponent) declares no scripted Command")
        }
        action = try ActionConfiguration(id: ActionID("measure"), pluginID: package.manifest.id, command: command,
                                         input: .null)
        let processes = self.processes
        supervisor = PluginRuntimeSupervisor(
            helperURL: helperURL, registry: registry, grantStore: grantStore,
            processFactory: { processes.make() },
            environment: { PluginRuntimeEnvironment(hostVersion: "0.0.0", preferredLanguage: "en") }
        )
        runner = HostActionRunner(executor: NoHostCommands(), scriptedExecutor: supervisor)
        pluginQueue = DispatchQueue(label: "com.vulpsecula.Spinnet.measure.plugin", qos: .userInitiated)
        let registry = self.registry
        let runner = self.runner
        let runLog = self.runLog
        let pluginQueue = self.pluginQueue
        let settingsFields = package.manifest.settingsFields
        onMain {
            sessions = PluginViewSessions(
                renderer: renderer,
                runEvent: { action, delivery, control, started, finish in
                    let dispatched = Clock.now()
                    pluginQueue.async {
                        control.restartDeadline()
                        let began = Clock.now()
                        DispatchQueue.main.async(execute: started)
                        let outcome = runner.invoke(action, using: registry, control: control, delivering: delivery)
                        runLog.append(EventRun(event: delivery.event, dispatched: dispatched, began: began,
                                               ended: Clock.now()))
                        DispatchQueue.main.async { finish(outcome) }
                    }
                },
                schedule: { delay, operation in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: operation)
                },
                showFeedback: { _ in },
                readView: { _, view in _ = try PluginViewDescription(parsing: view, settingsFields: settingsFields) }
            )
            if let grantStore {
                sessions.observe(registry: registry, grantStore: grantStore,
                                 on: { DispatchQueue.main.async(execute: $0) })
            }
        }
    }

    // MARK: The helper

    /// The live helper's process ID, if one is running.
    var helperProcessID: Int32? { processes.running()?.processIdentifier }

    /// Retires the Plugin's helper, as the Host does after it has been idle,
    /// and waits until the process has gone, so the next event starts cold.
    func retireHelper() throws {
        let running = processes.running()
        supervisor.terminate(pluginID: action.pluginID)
        try waitForExit(of: running, within: 2)
    }

    /// Waits until `process` has exited; nil has.
    func waitForExit(of process: Process?, within seconds: Double) throws {
        guard let process else { return }
        let deadline = Clock.now() + UInt64(seconds * 1_000_000_000)
        while process.isRunning {
            guard Clock.now() < deadline else {
                throw MeasurementError("The helper \(process.processIdentifier) was still running after \(seconds) s")
            }
            Clock.sleep(milliseconds: 2)
        }
    }

    func runningHelper() -> Process? { processes.running() }

    // MARK: The view

    var session: PluginViewSession? { onMain { sessions.session(for: action.pluginID) } }

    /// Starts the Action as a Menu Item would and times it until its view is
    /// presented. Presenting again, with a view already open, replaces it.
    func openView() throws -> Interaction {
        var interaction = Interaction()
        let done = DispatchSemaphore(value: 0)
        let launches = supervisor.launchCount
        interaction.lastInput = Clock.now()
        pluginQueue.async { [self] in
            let began = Clock.now()
            let outcome = runner.invoke(action, using: registry)
            interaction.runs = [EventRun(event: nil, dispatched: interaction.lastInput, began: began, ended: Clock.now())]
            DispatchQueue.main.async { [self] in
                defer { done.signal() }
                guard case .succeeded(let value) = outcome.terminal else {
                    interaction.failure = "The Action failed: \(outcome.terminal)"
                    return
                }
                do {
                    guard try sessions.actionAnswered(action, with: value) else {
                        interaction.failure = "The Action showed nothing"
                        return
                    }
                    interaction.answered = Clock.now()
                } catch {
                    interaction.failure = "The Action's answer is not one: \(error)"
                }
            }
        }
        guard done.wait(timeout: .now() + 10) == .success else { throw MeasurementError("The view did not open") }
        interaction.helperLaunches = supervisor.launchCount - launches
        return interaction
    }

    /// Why the last View Session ended, if one has.
    var lastEnd: PluginViewSessionEnd? { onMain { renderer.lastEnd } }

    func closeView() {
        onMain { sessions.session(for: action.pluginID)?.close() }
    }

    /// Sends `inputs` to the open view, each `offset` milliseconds after the
    /// first, and times the last until the view presents its answer to it.
    func interact(_ inputs: [(offset: Int, event: PluginViewEvent)], timeout: Double = 10) throws -> Interaction {
        guard let session, let last = inputs.last?.event else { throw MeasurementError("No view is open") }
        var interaction = Interaction()
        let done = DispatchSemaphore(value: 0)
        onMain {
            renderer.observe { presentation, presented in
                guard presented === session, !presentation.isBusy else { return false }
                if let error = presentation.error {
                    interaction.failure = "\(error.category.rawValue): \(error.message)"
                } else if presented.answeredEvent == last {
                    interaction.answered = Clock.now()
                } else {
                    return false
                }
                done.signal()
                return true
            } ended: { ended, reason in
                guard ended === session else { return false }
                interaction.failure = "The View Session ended: \(reason)"
                done.signal()
                return true
            }
        }
        let runs = runLog.count
        let launches = supervisor.launchCount
        let start = Clock.now()
        for (index, input) in inputs.enumerated() {
            Clock.sleep(until: start + UInt64(input.offset) * 1_000_000)
            let isLast = index == inputs.count - 1
            DispatchQueue.main.async {
                if isLast { interaction.lastInput = Clock.now() }
                session.send(input.event)
            }
        }
        let finished = done.wait(timeout: .now() + timeout) == .success
        onMain { renderer.stopObserving() }
        guard finished else { throw MeasurementError("No answer to \(last) within \(timeout) s") }
        interaction.runs = runLog.runs(since: runs)
        interaction.helperLaunches = supervisor.launchCount - launches
        return interaction
    }

    func runs(since count: Int) -> [EventRun] { runLog.runs(since: count) }
    var runCount: Int { runLog.count }

    func shutdown() {
        closeView()
        supervisor.shutdown()
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        precondition(!Thread.isMainThread, "The measurement drives the main queue from its own thread")
        return try DispatchQueue.main.sync(execute: body)
    }
}

struct MeasurementError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct NoHostCommands: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue {
        throw MeasurementError("The measurement runs no Host Commands")
    }
}

/// Every helper process the supervisor started, so their memory can be read.
private final class HelperProcesses {
    private let lock = NSLock()
    private var made: [Process] = []

    func make() -> Process {
        let process = Process()
        lock.withLock { made.append(process) }
        return process
    }

    /// The newest helper that is still running.
    func running() -> Process? {
        lock.withLock { made.last { $0.isRunning } }
    }
}

private final class RunLog {
    private let lock = NSLock()
    private var entries: [EventRun] = []

    func append(_ run: EventRun) { lock.withLock { entries.append(run) } }
    var count: Int { lock.withLock { entries.count } }
    func runs(since count: Int) -> [EventRun] { lock.withLock { Array(entries[count...]) } }
}

/// Stands in for `PluginViewWindows`: it draws nothing and tells one
/// observer about each presentation as it arrives. Main-queue confined.
private final class ObservingRenderer: PluginViewRenderer {
    typealias Presented = (PluginViewPresentation, PluginViewSession) -> Bool
    typealias Ended = (PluginViewSession, PluginViewSessionEnd) -> Bool
    private var presented: Presented?
    private var ended: Ended?
    private(set) var lastEnd: PluginViewSessionEnd?

    /// The observers answer true once they have seen what they waited for.
    func observe(_ presented: @escaping Presented, ended: @escaping Ended) {
        self.presented = presented
        self.ended = ended
    }

    func stopObserving() {
        presented = nil
        ended = nil
    }

    func present(_ presentation: PluginViewPresentation, of session: PluginViewSession) {
        if presented?(presentation, session) == true { stopObserving() }
    }

    func showToast(_ toast: String, in session: PluginViewSession) {}

    func close(_ session: PluginViewSession, because reason: PluginViewSessionEnd) {
        lastEnd = reason
        if ended?(session, reason) == true { stopObserving() }
    }
}
