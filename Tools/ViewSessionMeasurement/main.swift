import Foundation
import SpinnetCore

// Measures View Session latency and memory over the real helper (W13 #60).
// ADR 0007 asks every measurement to keep its raw samples and report p50,
// p95 and max with the conditions it ran under; this writes all three.
// Run it through script/measure_view_sessions.sh, which builds release first.

func runSessions(_ options: MeasurementOptions) throws {
    guard let helperURL = options.helperURL ?? defaultHelperURL(),
          FileManager.default.isExecutableFile(atPath: helperURL.path) else {
        throw MeasurementError("SpinnetPluginHelper was not found; build it and pass --helper")
    }
    guard let fixtureURL = options.fixtureURL ?? defaultFixtureURL() else {
        throw MeasurementError("Tests/Fixtures/TypingProbe.spinnetplugin was not found; pass --fixture")
    }
    let output = try ResultsDirectory(options.outputURL ?? ResultsDirectory.defaultURL(named: "view-sessions"))
    var conditions = RunConditions(options: options, helperPath: helperURL.path, fixturePath: fixtureURL.path)
    print(conditions.lines.prefix(3).joined(separator: "\n"))
    if conditions.buildConfiguration != "release" {
        print("warning: this is a \(conditions.buildConfiguration) build; budgets are read from release builds")
    }

    let rig = try ViewSessionRig(helperURL: helperURL, fixtureURL: fixtureURL)
    let measurement = SessionMeasurement(rig: rig, options: options)
    defer { rig.shutdown() }
    try measurement.run { print("- \($0)") }
    conditions.finish()

    try output.writeCSV(
        "samples.csv",
        header: ["scenario", "helper", "keystroke_interval_ms", "index", "query", "inputs", "total_ms", "dispatch_ms",
                 "invoke_ms", "apply_ms", "events_run", "helper_launches", "helper_exit_ms", "failure", "answer_bytes"],
        rows: measurement.latency.map { sample in
            [sample.scenario, sample.helper, optional(sample.keystrokeIntervalMs), "\(sample.index)",
             sample.query ?? "", "\(sample.inputs)", optional(sample.totalMs), optional(sample.dispatchMs),
             optional(sample.invokeMs), optional(sample.applyMs), "\(sample.eventsRun)", "\(sample.helperLaunches)",
             optional(sample.helperExitMs), sample.failure ?? "", sample.answerBytes.map { "\($0)" } ?? ""]
        }
    )
    try output.writeCSV(
        "memory.csv", header: ["cycle", "phase", "process", "pid", "index", "bytes"],
        rows: measurement.memory.map { ["\($0.cycle)", $0.phase, $0.process, "\($0.processID)", "\($0.index)", "\($0.bytes)"] }
    )
    let report = SessionReport(conditions: conditions, options: options, latency: measurement.latency,
                               memory: measurement.memory)
    try output.writeJSON("summary.json", report)
    try output.writeText("summary.txt", report.text)
    print("")
    print(report.text)
    print("Raw samples and summaries: \(output.url.path)")
}

func runAppFootprint(_ options: MeasurementOptions) throws {
    let output = try ResultsDirectory(options.outputURL ?? ResultsDirectory.defaultURL(named: "app-footprint"))
    let conditions = RunConditions(options: options, helperPath: "the app's own", fixturePath: "opened by hand")
    let text = try AppFootprint(options: options).run(conditions: conditions, output: output)
    print("")
    print(text)
    print("Raw samples and summaries: \(output.url.path)")
}

/// The helper built beside this tool, as SwiftPM builds both.
func defaultHelperURL() -> URL? {
    Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("SpinnetPluginHelper")
}

/// The fixture in the repository holding the current directory.
func defaultFixtureURL() -> URL? {
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    while true {
        let candidate = directory.appendingPathComponent("Tests/Fixtures/TypingProbe.spinnetplugin", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
            return candidate
        }
        guard directory.pathComponents.count > 1 else { return nil }
        directory.deleteLastPathComponent()
    }
}

let options: MeasurementOptions
do {
    options = try MeasurementOptions(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as MeasurementOptions.UsageError {
    if !error.description.isEmpty { FileHandle.standardError.write(Data("error: \(error)\n\n".utf8)) }
    print(MeasurementOptions.usage)
    exit(error.description.isEmpty ? 0 : 64)
}

// The sessions live on the main queue, as the Host's do, so the measurement
// drives them from its own thread while the main queue runs.
let driver = Thread {
    do {
        switch options.mode {
        case .sessions: try runSessions(options)
        case .appFootprint: try runAppFootprint(options)
        case .authority: try runAuthority(options)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
driver.qualityOfService = .userInitiated
driver.start()
dispatchMain()
