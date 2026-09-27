import Foundation
import Darwin
import SpinnetCore

/// Samples a running Spinnet app and its helpers while the user opens and
/// uses a Plugin View by hand, so the Host's memory includes the drawn view.
/// The sessions mode cannot: it holds sessions but draws nothing.
struct AppFootprint {
    struct Phase {
        let name: String
        let instruction: String
    }

    struct Report: Codable {
        struct Group: Codable {
            let phase: String
            let process: String
            let bytes: Distribution
            let growthOverNoViewBytes: Distribution?
        }

        var conditions: RunConditions
        let hostProcessID: Int32
        let samplesPerPhase: Int
        let groups: [Group]
    }

    static let phases = [
        Phase(name: "no-view", instruction: "Close every Plugin View and leave Spinnet alone for 31 seconds, "
              + "so no helper runs."),
        Phase(name: "view-open", instruction: "Open the Typing Probe view from the Menu and pin it, so it stays "
              + "open while this Terminal has the keyboard."),
        Phase(name: "after-typing", instruction: "Type a few queries into it, pausing between them."),
        Phase(name: "helper-retired", instruction: "Leave the view open and untouched for 31 seconds, so its "
              + "helper retires."),
        Phase(name: "view-closed", instruction: "Close the view.")
    ]

    let options: MeasurementOptions

    func run(conditions: RunConditions, output: ResultsDirectory) throws -> String {
        let host = try hostProcessID()
        print("Sampling \(options.hostProcessName) (\(host)) and its \(options.helperProcessName) children, "
              + "\(options.memorySamples) samples 100 ms apart per phase.")
        var samples: [MemorySample] = []
        for phase in Self.phases {
            print("\n\(phase.instruction)\nThen press Return here.", terminator: " ")
            guard readLine() != nil else {
                throw MeasurementError("Input ended before every phase was sampled; run app-footprint in a Terminal")
            }
            guard PluginHelperResourceSampler.physFootprint(processID: host) != nil else {
                throw MeasurementError("\(options.hostProcessName) (\(host)) is no longer running")
            }
            for index in 0..<options.memorySamples {
                if index > 0 { Clock.sleep(milliseconds: 100) }
                if let bytes = PluginHelperResourceSampler.physFootprint(processID: host) {
                    samples.append(MemorySample(cycle: 0, phase: phase.name, process: "host", processID: host,
                                                index: index, bytes: bytes))
                }
                for helper in Self.processIDs(named: options.helperProcessName, parent: host) {
                    guard let bytes = PluginHelperResourceSampler.physFootprint(processID: helper) else { continue }
                    samples.append(MemorySample(cycle: 0, phase: phase.name, process: "helper", processID: helper,
                                                index: index, bytes: bytes))
                }
            }
            let helpers = Set(samples.filter { $0.phase == phase.name && $0.process == "helper" }.map(\.processID))
            print("Sampled \(phase.name): \(helpers.count) helper\(helpers.count == 1 ? "" : "s") running.")
        }

        var conditions = conditions
        conditions.finish()
        let baseline = Distribution(samples.filter { $0.phase == "no-view" && $0.process == "host" }
            .map { Double($0.bytes) }).p50
        let groups = Self.phases.flatMap { phase in
            ["host", "helper"].compactMap { process -> Report.Group? in
                let values = samples.filter { $0.phase == phase.name && $0.process == process }.map { Double($0.bytes) }
                guard !values.isEmpty else { return nil }
                let growth = process == "host" ? baseline.map { base in values.map { $0 - base } } : nil
                return Report.Group(phase: phase.name, process: process, bytes: Distribution(values),
                                    growthOverNoViewBytes: growth.map(Distribution.init))
            }
        }
        let report = Report(conditions: conditions, hostProcessID: host, samplesPerPhase: options.memorySamples,
                            groups: groups)
        try output.writeCSV("app-memory.csv", header: ["phase", "process", "pid", "index", "bytes"],
                            rows: samples.map { [$0.phase, $0.process, "\($0.processID)", "\($0.index)", "\($0.bytes)"] })
        try output.writeJSON("summary.json", report)

        var lines = ["Spinnet app memory with a Plugin View (W13 #60)", ""] + conditions.lines + [""]
        lines.append("Memory in MiB (phys_footprint) of \(options.hostProcessName) (\(host)) and each helper it "
                     + "started; growth is over the no-view median. Helper rows pool every helper sampled.")
        lines.append(table(
            ["Phase", "Process", "n", "p50", "p95", "max", "Growth p50", "Growth p95", "Growth max"],
            groups.map { group in
                [group.phase, group.process, "\(group.bytes.count)",
                 mebibytes(group.bytes.p50), mebibytes(group.bytes.p95), mebibytes(group.bytes.max),
                 mebibytes(group.growthOverNoViewBytes?.p50), mebibytes(group.growthOverNoViewBytes?.p95),
                 mebibytes(group.growthOverNoViewBytes?.max)]
            }
        ))
        let text = lines.joined(separator: "\n") + "\n"
        try output.writeText("summary.txt", text)
        return text
    }

    private func hostProcessID() throws -> Int32 {
        if let pid = options.hostProcessID { return pid }
        let hosts = Self.processIDs(named: options.hostProcessName, parent: nil)
        guard hosts.count == 1 else {
            throw MeasurementError(hosts.isEmpty
                ? "No \(options.hostProcessName) is running. Start Spinnet, or name another with --host-name."
                : "\(hosts.count) \(options.hostProcessName) processes are running (\(hosts)); choose one with --host-pid.")
        }
        return hosts[0]
    }

    /// The processes called `name`, and only `parent`'s children when given.
    static func processIDs(named name: String, parent: Int32?) -> [Int32] {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity * Int32(MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0 else { return false }
            var buffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == name else { return false }
            guard let parent else { return true }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
            return Int32(info.pbi_ppid) == parent
        }.sorted()
    }
}
