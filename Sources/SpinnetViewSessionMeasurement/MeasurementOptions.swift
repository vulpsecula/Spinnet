import Foundation

/// What one run measures and where it writes, read from the command line.
struct MeasurementOptions {
    enum Mode: String {
        /// Drives View Sessions over the real helper from this process.
        case sessions
        /// Samples a running Spinnet app and its helpers while the user opens
        /// and uses a Plugin View by hand.
        case appFootprint = "app-footprint"
    }

    var mode = Mode.sessions
    var helperURL: URL?
    var fixtureURL: URL?
    var outputURL: URL?
    var openSamples = 20
    var eventSamples = 50
    var typingSamples = 20
    /// Time between keystrokes. One faster than the debounce delivers a
    /// single event per pause; a slower one delivers every keystroke.
    var keystrokeIntervals: [Int] = [50, 160]
    var memoryCycles = 5
    /// Each lets the helper retire after its real idle period, so each costs
    /// about 31 seconds.
    var idleRetirements = 2
    /// Samples per memory phase, 100 ms apart.
    var memorySamples = 10
    /// Quiet time between samples, longer than the debounce.
    var settleMilliseconds = 300
    /// Whether the machine was otherwise idle, as whoever ran it says.
    var machineIdle = "unknown"
    var note = ""
    var gitRevision = "unknown"
    /// The process the app-footprint mode samples, and its helpers.
    var hostProcessName = "SpinnetHost"
    var hostProcessID: Int32?
    var helperProcessName = "SpinnetPluginHelper"

    static let usage = """
        usage: SpinnetViewSessionMeasurement [app-footprint] [options]

        Measures View Session latency and memory over the real SpinnetPluginHelper
        (W13 #60), keeps every raw sample and reports p50, p95 and max with the run
        conditions. Run it through script/measure_view_sessions.sh, which builds
        the release configuration first.

          --helper PATH               SpinnetPluginHelper to run (default: next to this tool)
          --fixture PATH              Plugin package with a Smart Jump-like form
                                      (default: Tests/Fixtures/TypingProbe.spinnetplugin)
          --output DIR                Where samples and summaries go
                                      (default: tmp/measurements/view-sessions/<time>)
          --quick                     A short trial: 5 samples each, 1 memory cycle,
                                      no idle retirement
          --open-samples N            Views opened, cold and warm each (default 20)
          --event-samples N           View Event round trips, cold and warm each (default 50)
          --typing-samples N          Typed queries per interval, cold and warm each (default 20)
          --keystroke-intervals MS,…  Time between keystrokes (default 50,160)
          --memory-cycles N           Open-type-retire-close cycles sampled (default 5)
          --memory-samples N          Samples per memory phase, 100 ms apart (default 10)
          --idle-retirements N        Helpers left to retire after 30 s idle (default 2)
          --settle-ms N               Quiet time between samples (default 300)
          --machine-idle yes|no|unknown
                                      Whether nothing else ran, recorded with the results
          --note TEXT                 Anything else about the run
          --git-revision SHA          The revision measured

        app-footprint samples a running Spinnet app instead:
          --host-name NAME            Host process name (default SpinnetHost)
          --host-pid PID              The Host's process ID, when more than one runs
          --helper-name NAME          Helper process name (default SpinnetPluginHelper)
          --memory-samples N          Samples per phase, 100 ms apart (default 20)
        """

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    init(arguments: [String]) throws {
        var remaining = arguments[...]
        var sawMemorySamples = false
        func value(for flag: String) throws -> String {
            guard let next = remaining.popFirst() else { throw UsageError(description: "\(flag) needs a value") }
            return next
        }
        func count(for flag: String, minimum: Int = 0) throws -> Int {
            let text = try value(for: flag)
            guard let number = Int(text), number >= minimum else {
                throw UsageError(description: "\(flag) needs a whole number of at least \(minimum), not \(text)")
            }
            return number
        }
        // `--quick` sets smaller counts first, wherever it is written, so a
        // count given beside it is kept.
        if arguments.contains("--quick") {
            openSamples = 5
            eventSamples = 5
            typingSamples = 5
            memoryCycles = 1
            idleRetirements = 0
        }
        while let argument = remaining.popFirst() {
            switch argument {
            case "app-footprint": mode = .appFootprint
            case "--helper": helperURL = URL(fileURLWithPath: try value(for: argument))
            case "--fixture": fixtureURL = URL(fileURLWithPath: try value(for: argument), isDirectory: true)
            case "--output": outputURL = URL(fileURLWithPath: try value(for: argument), isDirectory: true)
            case "--quick": break
            case "--open-samples": openSamples = try count(for: argument)
            case "--event-samples": eventSamples = try count(for: argument)
            case "--typing-samples": typingSamples = try count(for: argument)
            case "--keystroke-intervals":
                let text = try value(for: argument)
                let intervals = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard !intervals.isEmpty, intervals.allSatisfy({ $0 > 0 }) else {
                    throw UsageError(description: "--keystroke-intervals needs milliseconds such as 50,160, not \(text)")
                }
                keystrokeIntervals = intervals
            case "--memory-cycles": memoryCycles = try count(for: argument)
            case "--memory-samples":
                memorySamples = try count(for: argument, minimum: 1)
                sawMemorySamples = true
            case "--idle-retirements": idleRetirements = try count(for: argument)
            case "--settle-ms": settleMilliseconds = try count(for: argument)
            case "--machine-idle":
                machineIdle = try value(for: argument)
                guard ["yes", "no", "unknown"].contains(machineIdle) else {
                    throw UsageError(description: "--machine-idle is yes, no or unknown")
                }
            case "--note": note = try value(for: argument)
            case "--git-revision": gitRevision = try value(for: argument)
            case "--host-name": hostProcessName = try value(for: argument)
            case "--helper-name": helperProcessName = try value(for: argument)
            case "--host-pid": hostProcessID = Int32(try count(for: argument, minimum: 1))
            case "-h", "--help": throw UsageError(description: "")
            default: throw UsageError(description: "Unknown argument \(argument)")
            }
        }
        if mode == .appFootprint, !sawMemorySamples { memorySamples = 20 }
    }
}
