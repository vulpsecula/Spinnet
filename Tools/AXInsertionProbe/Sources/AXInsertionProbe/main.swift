import AppKit
import ApplicationServices
import SpinnetCore

// The AX insertion probe for #69. See script/ax_insertion_matrix.sh, which
// builds it from Host A2, signs it and runs it through LaunchServices so the
// Accessibility grant belongs to this App and not to the terminal.
//
//   AXInsertionProbe check-trust [--prompt] [--out FILE]
//   AXInsertionProbe run --out DIR [--only g1,g2] [--skip g1,g2] [--dry-run] [--keep-work]
//   AXInsertionProbe selftest [--out DIR]
//
// Groups: fixture, textedit, terminal, safari, chrome, vscode, cursor,
// obsidian, notes, notion, discord, panel, panel-keys.

setlinebuf(stdout)

let usage = """
    usage: AXInsertionProbe check-trust [--prompt] [--out FILE]
           AXInsertionProbe run --out DIR [--only GROUPS] [--skip GROUPS] [--dry-run] [--keep-work]
           AXInsertionProbe selftest [--out DIR]
    groups: \(TargetGroup.allCases.map(\.rawValue).joined(separator: ","))
    """

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func groups(_ name: String) -> [TargetGroup]? {
    guard let list = option(name) else { return nil }
    return list.split(separator: ",").map { item in
        guard let group = TargetGroup(rawValue: String(item)) else {
            FileHandle.standardError.write(Data("unknown group \(item)\n\(usage)\n".utf8))
            exit(2)
        }
        return group
    }
}

func machineDescription() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return "\(String(cString: model)), \(ProcessInfo.processInfo.operatingSystemVersionString)"
}

func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

let hostBuild = HostBuild(commit: HostA2Provenance.commit, spinnetCoreTree: HostA2Provenance.spinnetCoreTree,
                          files: HostA2Provenance.files, headIdentical: HostA2Provenance.headIdentical)

switch arguments.first {
case "check-trust":
    let trusted: Bool
    if arguments.contains("--prompt") {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
    } else {
        trusted = AXIsProcessTrusted()
    }
    let answer = trusted ? "trusted" : "untrusted"
    print(answer)
    if let path = option("--out") { try? Data((answer + "\n").utf8).write(to: URL(fileURLWithPath: path)) }
    exit(trusted ? 0 : 1)

case "selftest":
    let output = option("--out").map { URL(fileURLWithPath: $0, isDirectory: true) }
    exit(SelfTest.run(writingSampleTo: output) ? 0 : 1)

case "run":
    guard let out = option("--out") else {
        FileHandle.standardError.write(Data("run needs --out DIR\n\(usage)\n".utf8))
        exit(2)
    }
    let output = URL(fileURLWithPath: out, isDirectory: true)
    let dryRun = arguments.contains("--dry-run")
    let keepWork = arguments.contains("--keep-work")
    var selected = groups("--only") ?? TargetGroup.allCases
    if let skipped = groups("--skip") { selected.removeAll { skipped.contains($0) } }
    let trusted = AXIsProcessTrusted()
    if !trusted && !dryRun {
        print("untrusted: grant Accessibility to this App first (see script/ax_insertion_matrix.sh)")
        exit(3)
    }
    let marker = InsertionText.random().marker
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("ax-insertion-probe-\(marker)", isDirectory: true)
    let fixture = Bundle.main.url(forResource: "AXProbeFixture", withExtension: "app")
    let probe = ProbeRun(marker: marker, work: work, fixtureAppURL: fixture, dryRun: dryRun)
    var report = ProbeReport(
        mode: dryRun ? "dry run" : "run", hostBuild: hostBuild, startedAt: timestamp(), machine: machineDescription(),
        accessibilityTrusted: trusted, insertedTextPattern: "\(InsertionText.emoji)\(marker)NN", rows: [],
        notes: [
            "Pre-Host queries: in Chromium and Electron as-is runs the probe reads only window titles before the Host's call; elsewhere it reads the focused element first to check it is in the probe's own window.",
            "Each Chromium or Electron row runs in a new separate instance on a throwaway profile, so one row's accessibility state cannot carry into another.",
            "Independent check: Safari and Chrome pages are served by the probe on 127.0.0.1 and report their field's DOM value to it on load, on each input event and on each change a 200 ms poll sees; VS Code and Cursor auto save the probe's file and Obsidian saves the throwaway note, which the probe reads from disk; the fixture reports its control's value. None of these asks Accessibility.",
            "Unicode keystroke experiment (evidence for P3, no Host change): no Host call; the text is posted as key down/up events carrying it as a Unicode string, one character per pair, first to the App's process (CGEventPostToPid); only if nothing arrived, a fresh text through the HID event tap while the probe's own window is frontmost. No clipboard is involved."
        ]
    )
    if dryRun {
        report.notes.append("Dry run: only the probe's own fixture App is driven (through the real Host call); every other row is planned and nothing else is opened.")
    }
    let lock = NSLock()
    func save(finished: Bool) {
        lock.lock()
        defer { lock.unlock() }
        report.rows = probe.rows
        report.notes = Array(NSOrderedSet(array: report.notes + probe.notes)) as! [String]
        if finished { report.finishedAt = timestamp() }
        do {
            try ReportWriter.write(report, to: output)
        } catch {
            print("could not write results: \(error)")
        }
    }

    NSApplication.shared.setActivationPolicy(.prohibited)
    var signalSources: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            print("interrupted: ending the probe's own instances")
            OwnedProcesses.killAll()
            report.notes.append("The run was interrupted; rows after the last one recorded did not run.")
            save(finished: true)
            exit(130)
        }
        source.resume()
        signalSources.append(source)
    }

    Thread.detachNewThread {
        print("AX insertion probe on Host A2 \(HostA2Provenance.commit)")
        print("marker \(marker), Accessibility \(trusted ? "trusted" : "not trusted"), \(dryRun ? "dry run" : "live run")")
        // The App in front when the run began, usually the terminal running
        // the script, comes back to the front afterwards.
        let originalFrontmost = Apps.frontmost()?.bundleURL
        do {
            try probe.run(groups: selected) { _ in save(finished: false) }
        } catch {
            probe.addNote("The run stopped: \(error.localizedDescription)")
        }
        OwnedProcesses.killAll()
        save(finished: true)
        if let originalFrontmost { _ = Apps.activate(originalFrontmost, timeout: 5) }
        if !keepWork { try? FileManager.default.removeItem(at: work) }
        print("results: \(output.appendingPathComponent("results.json").path)")
        print("table:   \(output.appendingPathComponent("results.md").path)")
        exit(0)
    }
    NSApplication.shared.run()

default:
    print(usage)
    exit(arguments.isEmpty ? 0 : 2)
}
