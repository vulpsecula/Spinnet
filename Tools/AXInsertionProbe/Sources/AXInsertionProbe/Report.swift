import Foundation

/// Which step of the Host A2 insertion sequence an attempt ended at. The
/// sequence is `AXIsProcessTrusted` → the App's `kAXFocusedUIElement` →
/// `kAXSelectedText` settable? → set it; the probe adds the read-back.
enum InsertionStep: String, Codable, CaseIterable {
    /// The Host reported success and the focused element's `kAXValue` holds
    /// the inserted text.
    case inserted
    /// The Host reported success, but the value read back lacks the text.
    case setOKTextNotFound = "set_ok_text_not_found"
    /// The Host reported success and the value could not be read back.
    case setOKUnverified = "set_ok_unverified"
    case noFocusedElement = "no_focused_element"
    case selectedTextNotSettable = "selected_text_not_settable"
    case setSelectedTextError = "set_selected_text_error"
    case accessibilityNotGranted = "accessibility_not_granted"
    /// A Host error the probe does not recognise, which means the pinned
    /// insertion code is not the one this probe was written against.
    case otherError = "other_error"

    var isHostSuccess: Bool { [.inserted, .setOKTextNotFound, .setOKUnverified].contains(self) }

    var summary: String {
        switch self {
        case .inserted: return "inserted"
        case .setOKTextNotFound: return "set OK, text not found"
        case .setOKUnverified: return "set OK, unverified"
        case .noFocusedElement: return "no focused element"
        case .selectedTextNotSettable: return "selected text not settable"
        case .setSelectedTextError: return "set error"
        case .accessibilityNotGranted: return "Accessibility not granted"
        case .otherError: return "other error"
        }
    }
}

/// What one Host call did.
struct Attempt: Codable, Equatable {
    var step: InsertionStep
    /// Exactly what the Host shows for this failure
    /// (`PluginHostServiceError.description`), nil on success.
    var hostError: String?
    var readBack: ReadBack?
    var elapsedMilliseconds: Double
}

struct ReadBack: Codable, Equatable {
    /// Where the value came from, such as "kAXValue of the focused element".
    var source: String
    var readable: Bool
    var axError: String?
    var valueLength: Int?
    var containsInsertedText: Bool
    var containsMarker: Bool
    var containsEmoji: Bool
    /// Up to 40 characters either side of the marker, only when found.
    var excerpt: String?
}

/// The focused element as Accessibility describes it.
struct ElementInfo: Codable, Equatable {
    var present: Bool
    var focusedElementError: String?
    var role: String?
    var subrole: String?
    var domIdentifier: String?
    var windowTitle: String?
    var selectedTextSettable: String?
    var selectedTextRangeSettable: String?
    var valueLength: Int?
}

struct SelectionResult: Codable, Equatable {
    /// replaced_selection, inserted_beside_selection, selection_not_set,
    /// host_failed or not_verifiable.
    var result: String
    var hostError: String?
    var detail: String?
}

/// An insertion checked without Accessibility: what the page, the saved
/// file or the fixture itself holds.
struct IndependentCheck: Codable, Equatable {
    /// page, file on disk, note file on disk or fixture.
    var label: String
    var source: String
    /// Whether the source reported a value at all.
    var observed: Bool
    var valueLength: Int?
    var containsInsertedText = false
    var containsMarker = false
    var containsEmoji = false
    /// Up to 40 characters either side of the marker, or the start of the
    /// value when the marker is not in it.
    var excerpt: String?
    /// Pages only: whether the field had the page's focus, and the page the
    /// window's, before the insertion and when the value was read.
    var targetFocusedBefore: Bool?
    var targetFocusedAfter: Bool?
    /// Pages only: the last DOM events on the field.
    var events: [String]?
    var detail: String?

    init(label: String, source: String, observed: Bool, detail: String?) {
        self.label = label
        self.source = source
        self.observed = observed
        self.detail = detail
    }

    init(label: String, source: String, value: String, text: InsertionText) {
        let readBack = HostA2Insertion.evaluate(value, for: text, source: source)
        self.label = label
        self.source = source
        observed = true
        valueLength = readBack.valueLength
        containsInsertedText = readBack.containsInsertedText
        containsMarker = readBack.containsMarker
        containsEmoji = readBack.containsEmoji
        excerpt = readBack.excerpt ?? (value.isEmpty ? nil : String(value.prefix(80)))
    }

    var summary: String {
        guard observed else { return "\(label): no observation" + (detail.map { " (\($0))" } ?? "") }
        if containsInsertedText { return "\(label): text present" }
        if containsMarker { return "\(label): marker without emoji" }
        return "\(label): text absent (\(valueLength ?? 0) chars)"
    }
}

/// The Unicode keystroke experiment: no Host call, the text posted as
/// keyboard events carrying it as a Unicode string, one key down and up per
/// character. No clipboard is involved.
struct KeystrokeExperiment: Codable, Equatable {
    var channels: [KeystrokeChannel]

    var summary: String {
        if let received = channels.first(where: { $0.received == true }) { return "received (\(received.channel))" }
        if channels.contains(where: { $0.received == nil && $0.skipped == nil }) { return "unverified" }
        return "not received"
    }
}

struct KeystrokeChannel: Codable, Equatable {
    /// "pid" (CGEventPostToPid to the App) or "HID" (the HID event tap,
    /// only while the App is frontmost).
    var channel: String
    var eventsPosted: Int
    /// What the independent check saw after this channel; nil when it could
    /// not tell.
    var received: Bool?
    var check: IndependentCheck?
    var skipped: String?
}

struct ExperimentInfo: Codable, Equatable {
    var attribute: String
    var setResult: String
    var valueAfter: String?
}

struct ProbeRow: Codable, Equatable {
    var id: String
    var app: String
    var bundleID: String
    var appVersion: String?
    var toolkit: String
    var control: String
    /// "Host A2 as-is", or the experiment that changed the App first.
    var variant: String
    var expected: String
    /// ran, skipped, planned (dry run)
    var status: String
    var skipReason: String?
    var focusAction: String?
    var ownership: String?
    var frontmostAtInsertion: String?
    var focusedBefore: ElementInfo?
    var attempt: Attempt?
    /// A second Host call 1 s after a failed first one, as a user pressing
    /// Insert again would make.
    var retry: Attempt?
    var focusedAfter: ElementInfo?
    var fixtureValue: String?
    /// The insertion checked without Accessibility, after the Host's last
    /// call (or after the keystrokes).
    var independentCheck: IndependentCheck?
    var keystrokes: KeystrokeExperiment?
    var selection: SelectionResult?
    var experiment: ExperimentInfo?
    var cleanup: String?
    var notes: [String] = []
    var durationSeconds: Double?

    var finalStep: InsertionStep? { retry?.step ?? attempt?.step }
}

struct HostBuild: Codable, Equatable {
    var commit: String
    var spinnetCoreTree: String
    var files: [String: String]
    var headIdentical: Bool
}

struct ProbeReport: Codable {
    var tool = "AXInsertionProbe"
    var mode: String
    var hostBuild: HostBuild
    var hostCall = "AppKitPluginHostServiceProvider.insertText(_:intoApplication:) compiled from Host A2"
    var startedAt: String
    var finishedAt: String?
    var machine: String
    var accessibilityTrusted: Bool
    var insertedTextPattern: String
    var rows: [ProbeRow]
    var notes: [String]
}

enum ReportWriter {
    static func write(_ report: ProbeReport, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: directory.appendingPathComponent("results.json"), options: .atomic)
        try Data(markdown(report).utf8).write(to: directory.appendingPathComponent("results.md"), options: .atomic)
    }

    static func markdown(_ report: ProbeReport) -> String {
        var lines: [String] = []
        lines.append("# AX insertion matrix (\(report.mode))")
        lines.append("")
        lines.append("Host build: `\(report.hostBuild.commit)` (Host A2). Every insertion is a call of the Host's own")
        lines.append("`AppKitPluginHostServiceProvider.insertText(_:intoApplication:)`, compiled from that commit;")
        lines.append("`PluginHostServices.swift` blob `\(report.hostBuild.files["Sources/SpinnetHost/PluginHostServices.swift"] ?? "?")`.")
        lines.append("")
        lines.append("| Item | Value |")
        lines.append("| --- | --- |")
        lines.append("| Started | \(report.startedAt) |")
        lines.append("| Finished | \(report.finishedAt ?? "not finished") |")
        lines.append("| Machine | \(report.machine) |")
        lines.append("| Probe trusted for Accessibility | \(report.accessibilityTrusted ? "yes" : "no") |")
        lines.append("| Inserted text | `\(report.insertedTextPattern)` |")
        lines.append("")
        lines.append("Result is the Host's outcome then the read-back of `kAXValue`; for a keystroke experiment it is")
        lines.append("whether the text arrived. \"Independent check\" is what holds the text without asking Accessibility:")
        lines.append("the page's own script (the DOM value, reported to the probe's local endpoint), the file the editor")
        lines.append("saved, or the fixture's own report. \"Retry\" is a second Host call 1 s after a failed first one.")
        lines.append("\"Host error shown\" is the exact text the Host shows.")
        lines.append("")
        lines.append("| App (version) | Toolkit | Control | Variant | Focused role / subrole | Result | Independent check | Host error shown | Retry | Selection | Expected | Notes |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for row in report.rows {
            let app = row.appVersion.map { "\(row.app) (\($0))" } ?? row.app
            let element = row.focusedBefore ?? row.focusedAfter
            var role: String
            if let element, element.present {
                role = [element.role, element.subrole].compactMap { $0 }.joined(separator: " / ")
            } else if element != nil {
                role = "none"
            } else {
                role = ""
            }
            // Chromium and Electron as-is rows are described only after the
            // Host's call.
            if row.focusedBefore == nil, row.focusedAfter != nil { role += " (read after)" }
            let result: String
            let error: String
            switch row.status {
            case "ran" where row.keystrokes != nil:
                result = "keystrokes " + row.keystrokes!.summary
                error = ""
            case "ran":
                result = row.attempt.map(resultText) ?? ""
                error = row.attempt?.hostError.map { "`\($0)`" } ?? ""
            case "skipped":
                result = "skipped"
                error = ""
            default:
                result = row.status
                error = ""
            }
            let retry = row.retry.map(resultText) ?? ""
            let selection = row.selection?.result.replacingOccurrences(of: "_", with: " ") ?? ""
            var notes = row.notes
            if let reason = row.skipReason { notes.insert(reason, at: 0) }
            if let experiment = row.experiment {
                notes.append("\(experiment.attribute) set: \(experiment.setResult)")
            }
            if let fixture = row.fixtureValue { notes.append("fixture holds \(quoted(fixture))") }
            if let check = row.independentCheck {
                if let before = check.targetFocusedBefore { notes.append("page: field focused before \(before ? "yes" : "no")") }
                if let events = check.events, !events.isEmpty { notes.append("page events: \(events.suffix(6).joined(separator: ", "))") }
                if check.observed, !check.containsInsertedText, let excerpt = check.excerpt {
                    notes.append("\(check.label) holds \(quoted(excerpt))")
                }
            }
            for channel in row.keystrokes?.channels ?? [] {
                if let skipped = channel.skipped {
                    notes.append("\(channel.channel): not tried, \(skipped)")
                } else {
                    let seen = channel.received.map { $0 ? "received" : "not received" } ?? "unverified"
                    notes.append("\(channel.channel): \(channel.eventsPosted) events, \(seen)")
                }
            }
            if let action = row.focusAction { notes.append("focus: \(action)") }
            if let cleanup = row.cleanup, cleanup != "closed" { notes.append("cleanup: \(cleanup)") }
            let control = row.control.contains("<") ? "`\(row.control)`" : row.control
            let independent = row.independentCheck?.summary ?? ""
            lines.append("| " + [app, row.toolkit, control, row.variant, role, result, independent, error, retry, selection,
                                  row.expected, notes.joined(separator: "; ")].map(cell).joined(separator: " | ") + " |")
        }
        if !report.notes.isEmpty {
            lines.append("")
            lines.append("## Notes")
            lines.append("")
            lines.append(contentsOf: report.notes.map { "- \($0)" })
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func resultText(_ attempt: Attempt) -> String {
        var text = attempt.step.summary
        if attempt.step.isHostSuccess, let readBack = attempt.readBack, attempt.step != .inserted {
            if readBack.containsMarker && !readBack.containsEmoji { text += " (marker without emoji)" }
        }
        return text
    }

    static func quoted(_ text: String) -> String {
        let shown = text.count > 40 ? String(text.prefix(40)) + "…" : text
        return "\"\(shown)\""
    }

    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
