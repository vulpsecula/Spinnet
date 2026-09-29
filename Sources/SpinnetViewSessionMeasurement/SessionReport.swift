import Foundation
import SpinnetCore

/// The summary of one sessions run, written beside its raw samples.
struct SessionReport: Codable {
    struct LatencyGroup: Codable {
        let scenario: String
        let helper: String
        let keystrokeIntervalMs: Int?
        let failures: Int
        /// Last input to answered view, the figure a target is read against.
        let totalMs: Distribution
        let dispatchMs: Distribution
        let invokeMs: Distribution
        let helperExitMs: Distribution?
        /// ADR 0010's target for this group, if it has one.
        let targetMs: Double?
        let p95WithinTarget: Bool?
        let maxWithinTarget: Bool?
    }

    struct MemoryGroup: Codable {
        let phase: String
        let process: String
        let bytes: Distribution
        /// For the host: each sample less the median of its cycle's
        /// `no-view` samples.
        let growthOverNoViewBytes: Distribution?
    }

    struct Options: Codable {
        let openSamples: Int
        let eventSamples: Int
        let typingSamples: Int
        let keystrokeIntervalsMs: [Int]
        let memoryCycles: Int
        let memorySamplesPerPhase: Int
        let idleRetirements: Int
        let settleMs: Int
        let fieldChangeDebounceMs: Double
        let helperIdleExitMs: Double
    }

    var conditions: RunConditions
    let options: Options
    let latency: [LatencyGroup]
    let memory: [MemoryGroup]

    /// ADR 0010's budgets for a view's answer after a typing pause, in ms.
    static func target(scenario: String, helper: String) -> Double? {
        guard scenario == "typing" else { return nil }
        switch helper {
        case "warm": return ScriptedActionBudgets.viewUpdateAfterPauseWarm * 1000
        case "cold": return ScriptedActionBudgets.viewUpdateAfterPauseCold * 1000
        default: return nil
        }
    }

    init(conditions: RunConditions, options: MeasurementOptions, latency: [LatencySample], memory: [MemorySample]) {
        self.conditions = conditions
        self.options = Options(
            openSamples: options.openSamples, eventSamples: options.eventSamples,
            typingSamples: options.typingSamples, keystrokeIntervalsMs: options.keystrokeIntervals,
            memoryCycles: options.memoryCycles, memorySamplesPerPhase: options.memorySamples,
            idleRetirements: options.idleRetirements, settleMs: options.settleMilliseconds,
            fieldChangeDebounceMs: ScriptedActionBudgets.fieldChangeDebounce * 1000,
            helperIdleExitMs: ScriptedActionBudgets.helperIdleExit * 1000
        )

        var keys: [String] = []
        var groups: [String: [LatencySample]] = [:]
        for sample in latency {
            let key = "\(sample.scenario)|\(sample.helper)|\(optional(sample.keystrokeIntervalMs))"
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(sample)
        }
        self.latency = keys.map { key in
            let samples = groups[key]!
            let first = samples[0]
            let total = Distribution(samples.compactMap(\.totalMs))
            let exits = samples.compactMap(\.helperExitMs)
            let target = Self.target(scenario: first.scenario, helper: first.helper)
            return LatencyGroup(
                scenario: first.scenario, helper: first.helper, keystrokeIntervalMs: first.keystrokeIntervalMs,
                failures: samples.filter { $0.failure != nil }.count,
                totalMs: total,
                dispatchMs: Distribution(samples.compactMap(\.dispatchMs)),
                invokeMs: Distribution(samples.compactMap(\.invokeMs)),
                helperExitMs: exits.isEmpty ? nil : Distribution(exits),
                targetMs: target,
                p95WithinTarget: target.flatMap { target in total.p95.map { $0 <= target } },
                maxWithinTarget: target.flatMap { target in total.max.map { $0 <= target } }
            )
        }

        var baselines: [Int: Double] = [:]
        for cycle in Set(memory.map(\.cycle)) {
            let noView = memory.filter { $0.cycle == cycle && $0.process == "host" && $0.phase == "no-view" }
            baselines[cycle] = Distribution(noView.map { Double($0.bytes) }).p50
        }
        var phases: [String] = []
        for sample in memory where !phases.contains(sample.phase) { phases.append(sample.phase) }
        self.memory = phases.flatMap { phase in
            ["host", "helper"].compactMap { process -> MemoryGroup? in
                let samples = memory.filter { $0.phase == phase && $0.process == process }
                guard !samples.isEmpty else { return nil }
                let growth = process == "host"
                    ? samples.compactMap { sample in baselines[sample.cycle].map { Double(sample.bytes) - $0 } }
                    : []
                return MemoryGroup(phase: phase, process: process, bytes: Distribution(samples.map { Double($0.bytes) }),
                                   growthOverNoViewBytes: growth.isEmpty ? nil : Distribution(growth))
            }
        }
    }

    var text: String {
        var lines = ["View Session measurement (W13 #60)", ""] + conditions.lines + [""]
        lines.append("Latency in ms. Total runs from the last input reaching the session to the view presenting")
        lines.append("its answer; for typing that is from the pause, debounce included. Invoke is the helper's part.")
        lines.append(table(
            ["Scenario", "Helper", "Keys every", "n", "Failed", "p50", "p95", "max", "Invoke p50", "Invoke p95",
             "Target", "p95 ok", "max ok"],
            latency.map { group in
                [group.scenario, group.helper, group.keystrokeIntervalMs.map { "\($0) ms" } ?? "",
                 "\(group.totalMs.count)", "\(group.failures)",
                 milliseconds(group.totalMs.p50), milliseconds(group.totalMs.p95), milliseconds(group.totalMs.max),
                 milliseconds(group.invokeMs.p50), milliseconds(group.invokeMs.p95),
                 group.targetMs.map { milliseconds($0) } ?? "",
                 group.p95WithinTarget.map { $0 ? "yes" : "NO" } ?? "",
                 group.maxWithinTarget.map { $0 ? "yes" : "NO" } ?? ""]
            }
        ))
        for group in latency {
            guard let exits = group.helperExitMs else { continue }
            lines.append("Idle helper exited \(milliseconds(exits.p50)) ms p50, \(milliseconds(exits.max)) ms max "
                         + "after going idle, with the view open (\(exits.count) samples).")
        }
        if !memory.isEmpty {
            lines.append("")
            lines.append("Memory in MiB (phys_footprint). Host is this process, which holds the sessions but draws")
            lines.append("nothing; growth is over the same cycle's no-view median.")
            lines.append(table(
                ["Phase", "Process", "n", "p50", "p95", "max", "Growth p50", "Growth p95", "Growth max"],
                memory.map { group in
                    [group.phase, group.process, "\(group.bytes.count)",
                     mebibytes(group.bytes.p50), mebibytes(group.bytes.p95), mebibytes(group.bytes.max),
                     mebibytes(group.growthOverNoViewBytes?.p50), mebibytes(group.growthOverNoViewBytes?.p95),
                     mebibytes(group.growthOverNoViewBytes?.max)]
                }
            ))
        }
        if let comparison = keptAliveComparison { lines += ["", comparison] }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What keeping a session's helper alive would buy and cost, from this
    /// run's own figures.
    private var keptAliveComparison: String? {
        func group(_ scenario: String, _ helper: String) -> LatencyGroup? {
            latency.first { $0.scenario == scenario && $0.helper == helper && $0.keystrokeIntervalMs == nil }
        }
        // A helper that has answered some typing holds more than a fresh one.
        let held = ["after-typing", "view-open"].lazy.compactMap { phase in
            self.memory.first { $0.phase == phase && $0.process == "helper" }?.bytes.p95
        }.first
        guard let cold = group("event", "cold")?.totalMs.p95, let warm = group("event", "warm")?.totalMs.p95,
              let held else {
            return nil
        }
        return "Keeping the helper alive while a view is open would save \(milliseconds(cold - warm)) ms at p95 "
            + "on an event that would otherwise start cold, and hold \(mebibytes(held)) MiB (p95 after typing) "
            + "for as long as the view stays open."
    }
}
