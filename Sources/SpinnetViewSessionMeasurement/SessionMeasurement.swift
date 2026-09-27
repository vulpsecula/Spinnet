import Foundation
import SpinnetCore

/// One timed interaction, kept as it was measured.
struct LatencySample: Codable {
    /// `open` (the Action presents its view), `event` (a View Event round
    /// trip) or `typing` (the status after a pause in typing).
    let scenario: String
    /// `cold` (the helper was retired first), `warm` (kept alive), or
    /// `idle-exit` (it retired itself after its idle period).
    let helper: String
    let keystrokeIntervalMs: Int?
    let index: Int
    let query: String?
    /// Inputs sent: keystrokes when typing, else 1.
    let inputs: Int
    /// From the last input reaching the session to the view presenting its
    /// answer, not busy. For `typing` this is the time from the pause, and
    /// includes the debounce.
    let totalMs: Double?
    /// From the last input to its event being handed to the Plugin queue:
    /// the debounce, and any wait behind an event already in flight.
    let dispatchMs: Double?
    /// The runner's invocation of the last event, including a helper start.
    let invokeMs: Double?
    /// From the runner's outcome to the view presenting it.
    let applyMs: Double?
    /// Invocations the interaction caused.
    let eventsRun: Int
    let helperLaunches: Int
    /// For `idle-exit`: from the helper going idle to its process exiting.
    let helperExitMs: Double?
    let failure: String?
}

/// One reading of one process's `phys_footprint`.
struct MemorySample: Codable {
    let cycle: Int
    let phase: String
    /// `host` (this process, standing in for the Host) or `helper`.
    let process: String
    let processID: Int32
    let index: Int
    let bytes: UInt64
}

/// Runs every scenario over one rig and keeps each sample.
final class SessionMeasurement {
    /// Smart Jump-like queries: links, sums, a DOI, paths and searches.
    static let queries = [
        "github.com/vulpsecula", "12*(3+4)/2", "10.1038/nphys1170", "swift concurrency",
        "~/Documents/notes.txt", "2^10 - 24", "https://example.com/a?b=c", "radial menu macos"
    ]

    private let rig: ViewSessionRig
    private let options: MeasurementOptions
    private(set) var latency: [LatencySample] = []
    private(set) var memory: [MemorySample] = []

    init(rig: ViewSessionRig, options: MeasurementOptions) {
        self.rig = rig
        self.options = options
    }

    func run(progress: (String) -> Void) throws {
        progress("Opening the view, cold and warm (\(options.openSamples) each)")
        try measureOpening()
        progress("View Event round trips, cold and warm (\(options.eventSamples) each)")
        try measureEvents()
        for interval in options.keystrokeIntervals {
            progress("Typing every \(interval) ms, cold and warm (\(options.typingSamples) each)")
            try measureTyping(every: interval)
        }
        progress("Memory over \(options.memoryCycles) cycles")
        try measureMemory()
        if options.idleRetirements > 0 {
            progress("Idle retirement with the view open (\(options.idleRetirements), about 31 s each)")
            try measureIdleRetirement()
        }
        rig.closeView()
    }

    // MARK: Latency

    /// Cold and warm alternate, so drift in the machine's load reaches both.
    private func measureOpening() throws {
        for index in 0..<options.openSamples {
            for helper in ["cold", "warm"] {
                rig.closeView()
                if helper == "cold" { try rig.retireHelper() }
                settle()
                let interaction = try rig.openView()
                latency.append(sample("open", helper, index: index, inputs: 1, interaction))
            }
        }
    }

    private func measureEvents() throws {
        try ensureViewIsOpen()
        for index in 0..<options.eventSamples {
            for helper in ["cold", "warm"] {
                if helper == "cold" { try rig.retireHelper() }
                settle()
                let interaction = try rig.interact([(0, .actionChosen("again"))])
                latency.append(sample("event", helper, index: index, inputs: 1, interaction))
            }
        }
    }

    /// Types one query a keystroke at a time and times the status from the
    /// last keystroke. With a helper retired first, a burst faster than the
    /// debounce reaches the helper as one cold event; slower typing starts
    /// the helper on its first keystroke.
    private func measureTyping(every interval: Int) throws {
        try ensureViewIsOpen()
        for index in 0..<options.typingSamples {
            let query = Self.queries[index % Self.queries.count]
            for helper in ["cold", "warm"] {
                if helper == "cold" { try rig.retireHelper() }
                settle()
                let interaction = try type(query, every: interval)
                latency.append(sample("typing", helper, interval: interval, index: index, query: query,
                                      inputs: query.count, interaction))
            }
        }
    }

    /// With the view open, the helper is left to retire after its real idle
    /// period. The session must survive it, and the next event starts a
    /// fresh helper.
    private func measureIdleRetirement() throws {
        try ensureViewIsOpen()
        for index in 0..<options.idleRetirements {
            settle()
            let priming = try rig.interact([(0, .actionChosen("again"))])
            guard priming.failure == nil, let idleSince = priming.runs.last?.ended,
                  let helper = rig.runningHelper() else {
                throw MeasurementError("The event before the idle period failed: \(priming.failure ?? "no helper")")
            }
            let limit = ScriptedActionBudgets.helperIdleExit + ScriptedActionBudgets.helperGracefulExit + 15
            try rig.waitForExit(of: helper, within: limit)
            let exited = Clock.now()
            var interaction: Interaction
            if let session = rig.session, !session.isEnded {
                settle()
                interaction = try rig.interact([(0, .actionChosen("again"))])
            } else {
                interaction = Interaction()
                interaction.failure = "The View Session did not survive its helper's retirement"
            }
            latency.append(sample("event", "idle-exit", index: index, inputs: 1, interaction,
                                  helperExitMs: Clock.milliseconds(from: idleSince, to: exited)))
        }
    }

    private func type(_ query: String, every interval: Int) throws -> Interaction {
        var text = ""
        let keystrokes = query.enumerated().map { offset, character -> (offset: Int, event: PluginViewEvent) in
            text.append(character)
            return (offset * interval, .fieldChanged(field: "query", values: .object(["query": .string(text)])))
        }
        return try rig.interact(keystrokes)
    }

    // MARK: Memory

    /// Each cycle opens a fresh view from no helper, types into it, lets the
    /// helper retire with the view still open, and closes the view. This
    /// process stands in for the Host: it holds the sessions, but draws
    /// nothing, so a drawn view's own memory is measured with app-footprint.
    private func measureMemory() throws {
        for cycle in 0..<options.memoryCycles {
            rig.closeView()
            try rig.retireHelper()
            Clock.sleep(milliseconds: 500)
            sampleMemory(cycle: cycle, phase: "no-view")

            guard try rig.openView().failure == nil else { throw MeasurementError("The view did not open") }
            settle()
            sampleMemory(cycle: cycle, phase: "view-open")

            for query in Self.queries.prefix(3) {
                let typed = try type(query, every: 50)
                if let failure = typed.failure { throw MeasurementError("Typing failed: \(failure)") }
                settle()
            }
            sampleMemory(cycle: cycle, phase: "after-typing")

            try rig.retireHelper()
            guard let session = rig.session, !session.isEnded else {
                throw MeasurementError("The View Session did not survive its helper's retirement")
            }
            settle()
            sampleMemory(cycle: cycle, phase: "helper-retired")

            rig.closeView()
            // ADR 0007 reads post-teardown growth 250 ms after teardown.
            Clock.sleep(milliseconds: 250)
            sampleMemory(cycle: cycle, phase: "view-closed")
        }
    }

    private func sampleMemory(cycle: Int, phase: String) {
        let host = getpid()
        for index in 0..<options.memorySamples {
            if index > 0 { Clock.sleep(milliseconds: 100) }
            if let bytes = PluginHelperResourceSampler.physFootprint(processID: host) {
                memory.append(MemorySample(cycle: cycle, phase: phase, process: "host", processID: host,
                                           index: index, bytes: bytes))
            }
            if let helper = rig.helperProcessID,
               let bytes = PluginHelperResourceSampler.physFootprint(processID: helper) {
                memory.append(MemorySample(cycle: cycle, phase: phase, process: "helper", processID: helper,
                                           index: index, bytes: bytes))
            }
        }
    }

    // MARK: Helpers

    private func ensureViewIsOpen() throws {
        if let session = rig.session, !session.isEnded { return }
        let opened = try rig.openView()
        if let failure = opened.failure { throw MeasurementError("The view did not open: \(failure)") }
    }

    private func settle() { Clock.sleep(milliseconds: options.settleMilliseconds) }

    private func sample(_ scenario: String, _ helper: String, interval: Int? = nil, index: Int, query: String? = nil,
                        inputs: Int, _ interaction: Interaction, helperExitMs: Double? = nil) -> LatencySample {
        let ok = interaction.failure == nil && interaction.answered > 0
        // The run that answered the last input is the last one it caused.
        let final = interaction.runs.last
        return LatencySample(
            scenario: scenario, helper: helper, keystrokeIntervalMs: interval, index: index, query: query,
            inputs: inputs,
            totalMs: ok ? Clock.milliseconds(from: interaction.lastInput, to: interaction.answered) : nil,
            dispatchMs: final.map { Clock.milliseconds(from: interaction.lastInput, to: $0.dispatched) },
            invokeMs: final.map { Clock.milliseconds(from: $0.began, to: $0.ended) },
            applyMs: ok ? final.map { Clock.milliseconds(from: $0.ended, to: interaction.answered) } : nil,
            eventsRun: interaction.runs.count, helperLaunches: interaction.helperLaunches,
            helperExitMs: helperExitMs,
            failure: interaction.failure ?? (ok ? nil : "No answer was presented")
        )
    }
}
