import AppKit
import ApplicationServices

/// The groups of targets, in the order a run visits them.
enum TargetGroup: String, CaseIterable {
    case fixture, textedit, terminal, safari, chrome, vscode, cursor, obsidian, notes, notion, discord
    /// The Host's call while a non-activating panel like the Plugin View's
    /// holds key, beside the same call without the panel.
    case panel
    /// The P3 flow: panel closed, target activated, Unicode keystrokes.
    case panelKeys = "panel-keys"
    /// The current Host only: a pinned view left open, the script path,
    /// line breaks and a tab, a long text, and Chinese input.
    case hostExtra = "host-extra"

    /// What a run visits unless told otherwise.
    static var defaults: [TargetGroup] {
        #if HOST_CURRENT
        allCases.filter { ![.panel, .panelKeys].contains($0) }
        #else
        allCases.filter { $0 != .hostExtra }
        #endif
    }
}

enum Variant {
    case asIs
    case experiment(attribute: String)
    /// No Host call: the text is typed as keyboard events carrying it as a
    /// Unicode string (evidence for product choice P3).
    case keystrokes
    /// The Host's call, as the Host makes it from a Plugin View, while the
    /// probe's stand-in for the Plugin View panel holds key.
    case panelHoldsKey
    /// No Host call: the stand-in panel is shown and closed, the target
    /// activated as Clipboard History's paster does, and the text typed as
    /// Unicode keyboard events through the HID tap (the P3 flow).
    case panelThenKeystrokes
    // The current Host (--host current).
    /// The Host's call from a pinned view that stays open.
    case hostStaysOpen
    /// The synchronous `insert_text`, into the App in front.
    case hostScript
    /// A text with line breaks (LF and CRLF) and a tab.
    case hostLines
    /// A text of several hundred characters, with CJK and emoji sequences.
    case hostLong
    /// With the named input source selected, restored afterwards.
    case hostIME(String)

    var label: String {
        switch self {
        case .asIs:
            #if HOST_CURRENT
            return "current Host, view closes on Insert"
            #else
            return "Host A2 as-is"
            #endif
        case .hostStaysOpen: return "current Host, pinned view stays open"
        case .hostScript: return "current Host, insert_text into the App in front"
        case .hostLines: return "current Host, line breaks and a tab"
        case .hostLong: return "current Host, long text"
        case .hostIME(let source): return "current Host, input source \(source)"
        case .experiment(let attribute): return "experiment: \(attribute) set first"
        case .keystrokes: return "experiment: Unicode keystrokes, no Host call"
        case .panelHoldsKey: return "Host A2 as-is while a non-activating panel holds key"
        case .panelThenKeystrokes: return "experiment: panel closed, App activated, Unicode keystrokes (P3 flow)"
        }
    }

    var tag: String {
        switch self {
        case .asIs: return "as-is"
        case .experiment(let attribute): return attribute
        case .keystrokes: return "keystrokes"
        case .panelHoldsKey: return "panel"
        case .panelThenKeystrokes: return "p3-keys"
        case .hostStaysOpen: return "open"
        case .hostScript: return "script"
        case .hostLines: return "lines"
        case .hostLong: return "long"
        case .hostIME(let source): return "ime-" + (source.split(separator: ".").last.map(String.init) ?? source)
        }
    }

    /// The suffix the row's text carries after the marker.
    var suffix: String {
        switch self {
        case .hostLines: return "\nline two\tafter a tab\r\nline three"
        case .hostLong:
            return String(repeating: " The quick brown fox, 中文输入测试 👨‍👩‍👧‍👦 café 🏳️‍🌈.", count: 14)
        default: return ""
        }
    }

    var isAsIs: Bool { if case .asIs = self { return true } else { return false } }
}

struct FixtureStatusRead: Decodable {
    let control: String
    let processID: Int32
    let windowTitle: String
    let isActive: Bool
    let controlHasKeyboardFocus: Bool
    let value: String
    let markedText: String?

    static func read(_ url: URL) -> FixtureStatusRead? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FixtureStatusRead.self, from: data)
    }
}

/// One run over the selected targets. Each target opens its own document,
/// page, window or separate App instance, inserts through the Host's code,
/// and closes what it opened without saving into anything of the user's.
final class ProbeRun {
    let insertion = HostInsertion()
    let marker: String
    let work: URL
    let fixtureAppURL: URL?
    let dryRun: Bool
    let trusted: Bool
    private(set) var rows: [ProbeRow] = []
    private(set) var notes: [String] = []
    private var counter = 0
    /// The variant of the row being run, which decides how the current
    /// Host is asked and what text it gets.
    private var activeVariant = Variant.asIs
    /// Serves the web pages and receives their own reports of their fields.
    private var server: ObservationServer?

    init(marker: String, work: URL, fixtureAppURL: URL?, dryRun: Bool) {
        self.marker = marker
        self.work = work
        self.fixtureAppURL = fixtureAppURL
        self.dryRun = dryRun
        self.trusted = AXIsProcessTrusted()
    }

    func log(_ message: String) {
        print(message)
        fflush(stdout)
    }

    /// A text unique to one row, so no read-back can see another row's.
    private func nextText() -> InsertionText {
        counter += 1
        return InsertionText(marker: marker + String(format: "%02d", counter), suffix: activeVariant.suffix)
    }

    func run(groups: [TargetGroup], record: (ProbeRow) -> Void) throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let server = ObservationServer(marker: marker)
        do {
            try server.start()
            self.server = server
        } catch {
            addNote("No web page rows: \(error.localizedDescription)")
        }
        for group in groups {
            log("== \(group.rawValue)")
            let before = rows.count
            switch group {
            case .fixture: runFixture()
            case .textedit: runTextEdit()
            case .terminal: runTerminal()
            #if HOST_CURRENT
            case .safari: runSafari(plan: WebFieldKind.allCases.map { ($0, Variant.asIs) })
            case .chrome: runChrome(plan: WebFieldKind.allCases.map { ($0, Variant.asIs) })
            case .vscode: runElectron(.vscode, variants: [.asIs])
            case .cursor: runElectron(.cursor, variants: [.asIs])
            case .obsidian: runElectron(.obsidian, variants: [.asIs])
            #else
            case .safari: runSafari()
            case .chrome: runChrome()
            case .vscode: runElectron(.vscode)
            case .cursor: runElectron(.cursor)
            case .obsidian: runElectron(.obsidian)
            #endif
            case .notes:
                add(skippedRow("notes", app: "Notes", bundleID: "com.apple.Notes", toolkit: "AppKit", control: "Note body",
                               reason: "skipped: a new note is stored in the user's Notes account and syncs, and a deleted one stays in Recently Deleted"))
            case .notion:
                add(skippedRow("notion", app: "Notion", bundleID: "notion.id", toolkit: "Electron", control: "Page editor",
                               reason: "skipped: needs account content"))
            case .discord:
                add(skippedRow("discord", app: "Discord", bundleID: "com.hnc.Discord", toolkit: "Electron", control: "Message box",
                               reason: "skipped: needs account content"))
            case .panel:
                addNote(Self.panelNote)
                runFixture(kinds: ["appkit-textfield"], variants: [.asIs, .panelHoldsKey])
                runTextEdit(kinds: ["plain"], variants: [.asIs, .panelHoldsKey])
                runSafari(plan: [(.addressBar, .asIs), (.addressBar, .panelHoldsKey)])
            case .panelKeys:
                addNote(Self.panelNote)
                addNote(Self.panelKeysNote)
                runFixture(kinds: ["appkit-textfield"], variants: [.panelThenKeystrokes])
                runTextEdit(kinds: ["plain"], variants: [.panelThenKeystrokes])
                runSafari(plan: [(.addressBar, .panelThenKeystrokes), (.input, .panelThenKeystrokes)])
                runChrome(plan: [(.input, .panelThenKeystrokes)])
                runElectron(.vscode, variants: [.panelThenKeystrokes])
            case .hostExtra:
                #if HOST_CURRENT
                addNote(Self.hostExtraNote)
                runFixture(kinds: ["appkit-textfield"], variants: [.hostStaysOpen, .hostScript])
                runFixture(kinds: ["appkit-textfield", "appkit-textview"],
                           variants: [.hostIME("com.apple.inputmethod.SCIM.ITABC"), .hostIME("com.apple.keylayout.ABC")])
                runFixture(kinds: ["appkit-textview"], variants: [.hostLines])
                runTextEdit(kinds: ["plain"], variants: [.hostStaysOpen, .hostLines, .hostLong])
                runSafari(plan: [(.input, .hostStaysOpen), (.textarea, .hostLines), (.contenteditable, .hostLong)])
                runChrome(plan: [(.textarea, .hostLines), (.textarea, .hostLong), (.input, .hostScript)])
                runElectron(.vscode, variants: [.hostLines, .hostLong])
                #else
                addNote("host-extra runs only with --host current")
                #endif
            }
            for row in rows[before...] {
                record(row)
                log("   \(row.id): \(row.status) \(row.finalStep?.rawValue ?? row.skipReason ?? "")")
            }
        }
    }

    private func add(_ row: ProbeRow) { rows.append(row) }

    func addNote(_ note: String) { notes.append(note) }

    // MARK: Rows

    private func newRow(_ id: String, app: String, bundleID: String, appURL: URL?, toolkit: String, control: String,
                        variant: Variant = .asIs, expected: String = "insert") -> ProbeRow {
        activeVariant = variant
        return ProbeRow(id: id, app: app, bundleID: bundleID, appVersion: appURL.flatMap(Apps.version), toolkit: toolkit,
                 control: control, variant: variant.label, expected: expected, status: "planned")
    }

    private func skippedRow(_ id: String, app: String, bundleID: String, toolkit: String, control: String,
                            reason: String) -> ProbeRow {
        var row = newRow(id, app: app, bundleID: bundleID, appURL: Apps.url(of: bundleID), toolkit: toolkit,
                         control: control, expected: "n/a")
        row.status = "skipped"
        row.skipReason = Apps.url(of: bundleID) == nil ? "not installed" : reason
        return row
    }

    private func skip(_ row: inout ProbeRow, _ reason: String) {
        row.status = "skipped"
        row.skipReason = reason
    }

    /// The Host's insertion, a retry after a failure, the read-back and the
    /// selection pass. `preQuery` reads the focused element before the Host
    /// does; it is off for Chromium and Electron as-is runs, where the
    /// probe's own query could switch on the App's accessibility before the
    /// Host's call and so change what is measured.
    ///
    /// `verify` checks the result without Accessibility, after the Host's
    /// last call and before the selection pass.
    @discardableResult
    private func insert(_ row: inout ProbeRow, into processIdentifier: pid_t, preQuery: Bool,
                        gate: (() -> String?)? = nil, fixtureStatus: URL? = nil,
                        verify: ((InsertionText) -> IndependentCheck)? = nil) -> InsertionText? {
        let started = Date()
        defer { row.durationSeconds = (Date().timeIntervalSince(started) * 10).rounded() / 10 }
        let text = nextText()
        if preQuery && trusted { row.focusedBefore = HostInsertion.describeFocus(in: processIdentifier).0 }
        if let gate, let reason = gate() {
            skip(&row, "not inserted: \(reason)")
            return nil
        }
        row.frontmostAtInsertion = Apps.frontmostDescription()
        #if HOST_CURRENT
        switch activeVariant {
        case .hostStaysOpen: insertion.mode = .viewStaysOpen
        case .hostScript: insertion.mode = .script
        default: insertion.mode = .viewCloses
        }
        #endif
        var restoreSource: (() -> String)?
        if case .hostIME(let source) = activeVariant {
            switch InputSources.select(source) {
            case .success(let restore):
                restoreSource = restore
                row.notes.append("input source \(InputSources.currentID() ?? "?") selected for the insertion")
            case .failure(let reason):
                skip(&row, "not inserted: \(reason)")
                return nil
            }
        }
        let first = insertion.attempt(text, into: processIdentifier)
        if let fixtureStatus, let marked = FixtureStatusRead.read(fixtureStatus)?.markedText {
            row.notes.append("fixture is composing \(ReportWriter.quoted(marked))")
        }
        if let restoreSource { row.notes.append(restoreSource()) }
        row.attempt = first
        row.status = "ran"
        if !first.step.isHostSuccess, first.step != .accessibilityNotGranted {
            Thread.sleep(forTimeInterval: 1)
            if let gate, let reason = gate() {
                row.notes.append("no retry: \(reason)")
            } else {
                row.retry = insertion.attempt(text, into: processIdentifier)
            }
        }
        if let verify { row.independentCheck = verify(text) }
        if trusted { row.focusedAfter = HostInsertion.describeFocus(in: processIdentifier).0 }
        if let fixtureStatus { row.fixtureValue = FixtureStatusRead.read(fixtureStatus)?.value }
        if row.finalStep == .inserted, row.focusedAfter?.selectedTextRangeSettable == "yes", gate?() == nil {
            row.selection = insertion.selectionPass(after: text, in: processIdentifier)
            if let fixtureStatus {
                Thread.sleep(forTimeInterval: 0.3)
                row.fixtureValue = FixtureStatusRead.read(fixtureStatus)?.value
            }
        }
        if row.expected == "refuse", row.finalStep?.isHostSuccess == true {
            row.notes.append("expected a refusal, but the Host reported success")
        }
        return text
    }

    /// Lets the Host insert only if the App's focused element is in the
    /// window the probe opened. With nothing focused the Host's own call
    /// finds nothing either, so that is allowed.
    private func windowGate(_ processIdentifier: pid_t, _ window: AXUIElement) -> () -> String? {
        {
            let app = AX.application(processIdentifier)
            guard let focused = AX.element(app, kAXFocusedUIElementAttribute) else { return nil }
            guard let focusedWindow = AX.window(containing: focused) else {
                return "the focused element is in no window the probe can identify"
            }
            if AX.equal(focusedWindow, window) { return nil }
            return "the focused element is in another window (\(AX.title(focusedWindow) ?? "untitled")), not the probe's"
        }
    }

    /// The keystroke experiment: no Host call. The text goes as Unicode
    /// keyboard events to the App's process; only if nothing of it arrived,
    /// a second text goes through the HID event tap, and only while
    /// `hidGate` confirms the probe's own window is in front. `verify` is
    /// the only check of what arrived.
    private func typeKeystrokes(_ row: inout ProbeRow, into processIdentifier: pid_t, gate: (() -> String?)?,
                                hidGate: () -> String?, verify: (InsertionText) -> IndependentCheck) {
        let started = Date()
        defer { row.durationSeconds = (Date().timeIntervalSince(started) * 10).rounded() / 10 }
        if let gate, let reason = gate() {
            skip(&row, "not typed: \(reason)")
            return
        }
        row.frontmostAtInsertion = Apps.frontmostDescription()
        row.status = "ran"
        func received(_ check: IndependentCheck) -> Bool? { check.observed ? check.containsInsertedText : nil }
        let text = nextText()
        let posted = SyntheticInput.typeUnicode(text.text, via: .process(processIdentifier))
        var check = verify(text)
        var channels = [KeystrokeChannel(channel: "pid", eventsPosted: posted, received: received(check), check: check)]
        if check.observed, !check.containsMarker, !check.containsEmoji {
            if let reason = hidGate() ?? gate?() {
                let reason = reason + " (frontmost: \(Apps.frontmostDescription() ?? "none"))"
                channels.append(KeystrokeChannel(channel: "HID", eventsPosted: 0, skipped: reason))
            } else {
                // A text of its own, so a late arrival of the first cannot
                // count for this one.
                let second = nextText()
                let posted = SyntheticInput.typeUnicode(second.text, via: .hid)
                check = verify(second)
                channels.append(KeystrokeChannel(channel: "HID", eventsPosted: posted, received: received(check), check: check))
            }
        }
        row.independentCheck = check
        row.keystrokes = KeystrokeExperiment(channels: channels)
    }

    private func isGone(_ window: AXUIElement, in app: AXUIElement) -> Bool {
        if AX.copy(window, kAXRoleAttribute).0 == .invalidUIElement { return true }
        return !AX.windows(app).contains { CFEqual($0, window) }
    }

    /// Presses the window's close button. A document of the probe's own is
    /// autosaved in place; anything that asks first is left for the user.
    private func close(_ window: AXUIElement, in app: AXUIElement) -> String {
        let title = AX.title(window) ?? "untitled"
        guard let button = AX.element(window, kAXCloseButtonAttribute) else {
            return "left open: no close button on \"\(title)\""
        }
        AX.press(button)
        if Apps.poll(4, { isGone(window, in: app) }) { return "closed" }
        return "left open: \"\(title)\" asked something on closing; close it without saving"
    }

    private func window(of processIdentifier: pid_t, titleContaining text: String, timeout: TimeInterval) -> AXUIElement? {
        let app = AX.application(processIdentifier)
        var found: AXUIElement?
        Apps.poll(timeout, interval: 0.3) {
            found = AX.windows(app).first { AX.title($0)?.contains(text) == true }
            return found != nil
        }
        return found
    }

    private func bringForward(_ processIdentifier: pid_t) {
        guard Apps.frontmost()?.processIdentifier != processIdentifier else { return }
        NSRunningApplication(processIdentifier: processIdentifier)?.activate(options: [.activateAllWindows])
        Apps.poll(2) { Apps.frontmost()?.processIdentifier == processIdentifier }
    }

    // MARK: Fixture

    private func runFixture(kinds: Set<String>? = nil, variants: [Variant] = [.asIs]) {
        let controls: [(kind: String, toolkit: String, control: String, expected: String)] = [
            ("appkit-textfield", "AppKit", "NSTextField", "insert"),
            ("appkit-textview", "AppKit", "NSTextView", "insert"),
            ("appkit-searchfield", "AppKit", "NSSearchField", "insert"),
            ("appkit-securefield", "AppKit", "NSSecureTextField", "refuse"),
            ("swiftui-textfield", "SwiftUI", "TextField", "insert"),
            ("swiftui-texteditor", "SwiftUI", "TextEditor", "insert")
        ]
        let bundleID = fixtureAppURL.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "AXProbeFixture"
        for item in controls where kinds?.contains(item.kind) ?? true {
          for variant in variants {
            let id = variant.isAsIs ? "fixture.\(item.kind)" : "fixture.\(item.kind).\(variant.tag)"
            var row = newRow(id, app: "AX Probe Fixture", bundleID: bundleID, appURL: fixtureAppURL,
                             toolkit: item.toolkit, control: item.control, variant: variant, expected: item.expected)
            defer { add(row) }
            guard let fixtureAppURL else {
                skip(&row, "the fixture App is not inside the probe")
                continue
            }
            let status = work.appendingPathComponent("fixture-\(item.kind)-\(variant.tag).json")
            let title = "AX Probe Fixture \(item.kind) \(marker)"
            guard let app = Apps.launchNewInstance(fixtureAppURL, arguments: ["--control", item.kind, "--title", title,
                                                                               "--status", status.path]) else {
                skip(&row, "the fixture App did not start")
                continue
            }
            let pid = app.processIdentifier
            OwnedProcesses.add(pid)
            let focused = Apps.poll(8) { FixtureStatusRead.read(status)?.controlHasKeyboardFocus == true }
            row.focusAction = focused ? "first responder, confirmed by the fixture" : "first responder not confirmed by the fixture"
            row.ownership = "the probe's own fixture process"
            switch variant {
            case .panelHoldsKey:
                insertWhilePanelHoldsKey(&row, into: pid, gate: nil, fixtureStatus: status,
                                         verify: IndependentChecks.fixture(status))
            case .panelThenKeystrokes:
                // The fixture is the probe's own process, so whatever it
                // holds focused may take the keys.
                keystrokesAfterPanel(&row, into: pid, axQueries: true, gate: frontmostGate(pid), fixtureStatus: status,
                                     verify: IndependentChecks.fixture(status))
            default:
                insert(&row, into: pid, preQuery: true, fixtureStatus: status, verify: IndependentChecks.fixture(status))
            }
            row.cleanup = Apps.end(pid, grace: 2) == "quit" ? "closed" : "fixture ended"
            OwnedProcesses.remove(pid)
          }
        }
    }

    // MARK: TextEdit

    private func runTextEdit(kinds: Set<String>? = nil, variants: [Variant] = [.asIs]) {
        let bundleID = "com.apple.TextEdit"
        let appURL = Apps.url(of: bundleID)
        let documents: [(kind: String, ext: String, content: String, control: String)] = [
            ("plain", "txt", "AX probe plain text document.\n", "Plain text document (NSTextView)"),
            ("rich", "rtf", "{\\rtf1\\ansi AX probe rich text document.\\par}", "Rich text document (NSTextView)")
        ]
        let wasRunning = !Apps.running(bundleID).isEmpty
        for document in documents where kinds?.contains(document.kind) ?? true {
          for variant in variants {
            let id = variant.isAsIs ? "textedit.\(document.kind)" : "textedit.\(document.kind).\(variant.tag)"
            var row = newRow(id, app: "TextEdit", bundleID: bundleID, appURL: appURL,
                             toolkit: "AppKit", control: document.control, variant: variant)
            defer { add(row) }
            guard let appURL else { skip(&row, "not installed"); continue }
            guard !dryRun else { continue }
            let name = "ax-probe-\(document.kind)-\(variant.tag)-\(marker)"
            let file = work.appendingPathComponent("\(name).\(document.ext)")
            do {
                try Data(document.content.utf8).write(to: file)
            } catch {
                skip(&row, "could not write the probe's document: \(error.localizedDescription)")
                continue
            }
            guard let app = Apps.open([file], with: appURL) else { skip(&row, "TextEdit did not open"); continue }
            let pid = app.processIdentifier
            let appElement = AX.application(pid)
            var window: AXUIElement?
            Apps.poll(10, interval: 0.3) {
                window = AX.windows(appElement).first { candidate in
                    AX.title(candidate)?.contains(name) == true
                        || AX.string(candidate, kAXDocumentAttribute)?.contains(name) == true
                }
                return window != nil
            }
            guard let window else { skip(&row, "TextEdit did not show the probe's new document"); continue }
            AX.set(window, kAXMainAttribute, kCFBooleanTrue)
            bringForward(pid)
            Thread.sleep(forTimeInterval: 0.5)
            row.focusAction = "text view focused on opening the probe's new document"
            row.ownership = "focused element checked to be in the probe's document window"
            let texts: [InsertionText]
            switch variant {
            case .panelHoldsKey:
                texts = insertWhilePanelHoldsKey(&row, into: pid, gate: windowGate(pid, window), verify: nil)
                    .map { [$0.first, $0.control] } ?? []
            case .panelThenKeystrokes:
                texts = keystrokesAfterPanel(&row, into: pid, axQueries: true, gate: keyGate(pid, window),
                                             verify: axReadBack(pid)).map { [$0] } ?? []
            default:
                texts = insert(&row, into: pid, preQuery: true, gate: windowGate(pid, window)).map { [$0] } ?? []
            }
            row.cleanup = close(window, in: appElement)
            // TextEdit saves the probe's document in place on closing; the
            // file is the check that does not go through Accessibility.
            if row.cleanup == "closed", let first = texts.first {
                let check = IndependentChecks.files({ [file] }, label: "file on disk",
                                                    source: "the probe's document as TextEdit saved it on closing", timeout: 3)
                row.independentCheck = check(first)
                if texts.count > 1 { row.panel?.afterCloseCheck = check(texts[1]) }
            }
          }
        }
        if !dryRun, let quit = Apps.quitIfStartedByProbe(bundleID, wasRunning: wasRunning) {
            addNote("TextEdit: \(quit)")
        }
    }

    // MARK: Terminal

    private func runTerminal() {
        let bundleID = "com.apple.Terminal"
        let appURL = Apps.url(of: bundleID)
        var row = newRow("terminal.window", app: "Terminal", bundleID: bundleID, appURL: appURL, toolkit: "AppKit",
                         control: "Shell prompt in a new window (not a text field)", expected: "control case")
        defer { add(row) }
        guard let appURL else { skip(&row, "not installed"); return }
        guard !dryRun else { return }
        let wasRunning = !Apps.running(bundleID).isEmpty
        guard let app = Apps.activate(appURL) else { skip(&row, "Terminal did not start"); return }
        let pid = app.processIdentifier
        let appElement = AX.application(pid)
        if !wasRunning { Thread.sleep(forTimeInterval: 2) }
        bringForward(pid)
        let before = AX.windows(appElement)
        var pressed = false
        if let item = AX.menuItem(of: appElement, commandCharacter: "N") { pressed = AX.press(item) == .success }
        var window: AXUIElement?
        func findNew() -> Bool {
            window = AX.windows(appElement).first { candidate in !before.contains { CFEqual($0, candidate) } }
            return window != nil
        }
        if !Apps.poll(5, findNew), Apps.frontmost()?.processIdentifier == pid {
            SyntheticInput.keystroke(SyntheticInput.keyN, command: true, to: pid)
            pressed = false
            Apps.poll(5, findNew)
        }
        guard let window else { skip(&row, "no new Terminal window appeared"); return }
        AX.set(window, kAXMainAttribute, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 1.5)
        row.focusAction = pressed ? "new window from the New Window menu item" : "new window from Cmd-N"
        row.ownership = "focused element checked to be in the probe's new window"
        row.notes.append("the text has no newline, so nothing runs in the shell")
        insert(&row, into: pid, preQuery: true, gate: windowGate(pid, window))
        row.cleanup = close(window, in: appElement)
        if let quit = Apps.quitIfStartedByProbe(bundleID, wasRunning: wasRunning) { addNote("Terminal: \(quit)") }
    }

    // MARK: Safari

    private func runSafari(plan customPlan: [(WebFieldKind, Variant)]? = nil) {
        let bundleID = "com.apple.Safari"
        let appURL = Apps.url(of: bundleID)
        let wasRunning = !Apps.running(bundleID).isEmpty
        let plan = customPlan ?? (WebFieldKind.allCases.map { ($0, Variant.asIs) }
            + WebFieldKind.allCases.filter { $0 != .addressBar }.map { ($0, Variant.keystrokes) })
        for (kind, variant) in plan {
            let id = variant.isAsIs ? "safari.\(kind.rawValue)" : "safari.\(kind.rawValue).\(variant.tag)"
            var row = newRow(id, app: "Safari", bundleID: bundleID, appURL: appURL,
                             toolkit: "WebKit", control: kind.control, variant: variant)
            defer { add(row) }
            guard let appURL else { skip(&row, "not installed"); continue }
            guard !dryRun else { continue }
            guard let server else { skip(&row, "the probe's page server is not running"); continue }
            guard let app = Apps.open([server.pageURL(kind, row: id)], with: appURL) else {
                skip(&row, "Safari did not open the probe's page")
                continue
            }
            let pid = app.processIdentifier
            let appElement = AX.application(pid)
            let title = Pages.title(kind, marker: marker)
            guard let window = window(of: pid, titleContaining: title, timeout: 15) else {
                skip(&row, "Safari did not show the probe's page")
                continue
            }
            AX.set(window, kAXMainAttribute, kCFBooleanTrue)
            bringForward(pid)
            Thread.sleep(forTimeInterval: 1)
            if kind == .addressBar {
                row.focusAction = focusAddressBar(pid: pid, window: window)
            } else {
                row.focusAction = focusWebTarget(pid: pid, window: window)
            }
            row.ownership = "focused element checked to be in the probe's page window"
            let verify = kind == .addressBar ? nil : IndependentChecks.page(server, row: id)
            if case .panelHoldsKey = variant {
                insertWhilePanelHoldsKey(&row, into: pid, gate: windowGate(pid, window), verify: verify)
            } else if case .panelThenKeystrokes = variant {
                let tabGate: () -> String? = {
                    if let reason = self.keyGate(pid, window)() { return reason }
                    return AX.title(window)?.contains(title) == true ? nil : "the probe's tab is not in front"
                }
                keystrokesAfterPanel(&row, into: pid, axQueries: true, gate: tabGate, verify: verify ?? axReadBack(pid))
            } else if case .keystrokes = variant, let verify {
                // The probe's tab must be the one in front of its window, since
                // Safari gives the keys to its key window's front tab.
                let gate: () -> String? = {
                    if let reason = self.windowGate(pid, window)() { return reason }
                    return AX.title(window)?.contains(title) == true ? nil : "the probe's tab is not in front"
                }
                let hidGate: () -> String? = {
                    Apps.frontmost()?.processIdentifier == pid ? nil : "Safari is not frontmost"
                }
                typeKeystrokes(&row, into: pid, gate: gate, hidGate: hidGate, verify: verify)
            } else {
                insert(&row, into: pid, preQuery: true, gate: windowGate(pid, window), verify: verify)
            }
            row.cleanup = closeSafariTab(window: window, title: title, app: appElement, pid: pid)
        }
        if !dryRun, let quit = Apps.quitIfStartedByProbe(bundleID, wasRunning: wasRunning) {
            addNote("Safari: \(quit)")
        }
    }

    /// Autofocus normally leaves the field focused; if not, focus it by its
    /// DOM id through Accessibility.
    private func focusWebTarget(pid: pid_t, window: AXUIElement) -> String {
        let (info, _) = HostInsertion.describeFocus(in: pid)
        if info.domIdentifier == "probe-target" { return "autofocus" }
        let target = AX.first(below: window, maxNodes: 3000) { AX.string($0, "AXDOMIdentifier") == "probe-target" }
        guard let target else { return "autofocus (field not found through Accessibility)" }
        let error = AX.set(target, kAXFocusedAttribute, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.4)
        return "focused #probe-target through Accessibility (\(AX.describe(error)))"
    }

    private func focusAddressBar(pid: pid_t, window: AXUIElement) -> String {
        let field = AX.first(below: window, maxNodes: 1500, skipping: ["AXWebArea"]) {
            AX.role($0) == kAXTextFieldRole && !AX.hasAncestor($0, role: "AXWebArea")
        }
        if let field {
            AX.set(field, kAXFocusedAttribute, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.4)
            if let focused = AX.element(AX.application(pid), kAXFocusedUIElementAttribute), CFEqual(focused, field) {
                return "address field focused through Accessibility"
            }
        }
        // The keystroke goes only to this App, and only while the probe's
        // window is its focused one.
        let focusedWindow = AX.element(AX.application(pid), kAXFocusedWindowAttribute)
        guard AX.equal(focusedWindow, window), Apps.frontmost()?.processIdentifier == pid else {
            return "address field not focused (the probe's window was not in front)"
        }
        SyntheticInput.keystroke(SyntheticInput.keyL, command: true, to: pid)
        Thread.sleep(forTimeInterval: 0.6)
        return "Cmd-L keystroke"
    }

    /// Closes only the probe's tab: through its own close button, or else
    /// through Close Tab after checking once more that the probe's tab is
    /// the one in front. The window is never closed as a whole, since it may
    /// hold the user's tabs.
    private func closeSafariTab(window: AXUIElement, title: String, app: AXUIElement, pid: pid_t) -> String {
        let closed = { self.isGone(window, in: app) || AX.title(window)?.contains(title) != true }
        let tabGroup = AX.first(below: window, maxNodes: 800, skipping: ["AXWebArea"]) { AX.role($0) == kAXTabGroupRole }
        let tabs = tabGroup.map { AX.elements($0, kAXChildrenAttribute) } ?? []
        if let tab = tabs.first(where: { AX.title($0)?.contains(title) == true }),
           let closeButton = AX.first(below: tab, maxNodes: 20, where: { AX.role($0) == kAXButtonRole }) {
            AX.press(closeButton)
            if Apps.poll(4, closed) { return "closed" }
        }
        if AX.title(window)?.contains(title) == true,
           AX.equal(AX.element(app, kAXFocusedWindowAttribute), window),
           let item = AX.menuItem(of: app, commandCharacter: "W") {
            AX.press(item)
            if Apps.poll(4, closed) { return "closed" }
        }
        return "left open: the probe's tab \"\(title)\""
    }

    // MARK: Chrome

    private func runChrome(plan customPlan: [(WebFieldKind, Variant)]? = nil) {
        let bundleID = "com.google.Chrome"
        let appURL = Apps.url(of: bundleID)
        // The address bar takes the Host's text as-is; the keystroke
        // experiment is for the page fields that do not.
        let plan = customPlan ?? [Variant.asIs, .experiment(attribute: "AXEnhancedUserInterface"), .keystrokes].flatMap { variant in
            WebFieldKind.allCases.filter { kind in
                if case .keystrokes = variant { return kind != .addressBar }
                return true
            }.map { (kind: $0, variant: variant) }
        }
        do {
            for (kind, variant) in plan {
                let id = "chrome.\(kind.rawValue).\(variant.tag)"
                var row = newRow(id, app: "Google Chrome", bundleID: bundleID,
                                 appURL: appURL, toolkit: "Chromium", control: kind.control, variant: variant)
                defer { add(row) }
                guard let appURL else { skip(&row, "not installed"); continue }
                guard !dryRun else { continue }
                guard let server else { skip(&row, "the probe's page server is not running"); continue }
                let profile = work.appendingPathComponent("chrome-\(variant.tag)-\(kind.rawValue)", isDirectory: true)
                let arguments = ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
                                 "--use-mock-keychain", "--disable-sync", "--new-window",
                                 server.pageURL(kind, row: id).absoluteString]
                let verify: (() -> (InsertionText) -> IndependentCheck)? =
                    kind == .addressBar ? nil : { IndependentChecks.page(server, row: id) }
                runIsolated(&row, appURL: appURL, bundleID: bundleID, arguments: arguments, variant: variant,
                            titleMarker: Pages.title(kind, marker: marker), settle: 2.5, verify: verify) { pid in
                    if kind == .addressBar {
                        SyntheticInput.keystroke(SyntheticInput.keyL, command: true, to: pid)
                        Thread.sleep(forTimeInterval: 0.6)
                        return "Cmd-L keystroke to the probe's own Chrome"
                    }
                    return "autofocus"
                }
                try? FileManager.default.removeItem(at: profile)
            }
        }
    }

    // MARK: Electron

    enum ElectronApp {
        case vscode, cursor, obsidian

        var bundleID: String {
            switch self {
            case .vscode: return "com.microsoft.VSCode"
            case .cursor: return "com.todesktop.230313mzl4w4u92"
            case .obsidian: return "md.obsidian"
            }
        }

        var name: String {
            switch self {
            case .vscode: return "Visual Studio Code"
            case .cursor: return "Cursor"
            case .obsidian: return "Obsidian"
            }
        }

        var control: String {
            switch self {
            case .vscode, .cursor: return "Editor of a new untitled-style file"
            case .obsidian: return "Note editor of a new note"
            }
        }
    }

    private func runElectron(_ electron: ElectronApp,
                             variants: [Variant] = [.asIs, .experiment(attribute: "AXManualAccessibility"), .keystrokes]) {
        let appURL = Apps.url(of: electron.bundleID)
        for variant in variants {
            var row = newRow("\(String(describing: electron)).editor.\(variant.tag)", app: electron.name,
                             bundleID: electron.bundleID, appURL: appURL, toolkit: "Electron",
                             control: electron.control, variant: variant)
            defer { add(row) }
            guard let appURL else { skip(&row, "not installed"); continue }
            guard !dryRun else { continue }
            // On macOS every Obsidian instance serves its CLI on
            // ~/.obsidian-cli.sock and deletes it on quitting, so a second
            // instance would take the user's running Obsidian's CLI away.
            if electron == .obsidian, !Apps.running(electron.bundleID).isEmpty {
                skip(&row, "skipped: Obsidian is running, and a second instance would take over and then delete its ~/.obsidian-cli.sock; quit Obsidian and run with --only obsidian")
                continue
            }
            // A short path: VS Code and Cursor put their IPC socket in the
            // user data directory, and a socket path over 103 bytes makes
            // the instance exit before it shows a window.
            let short: String
            switch variant {
            case .asIs: short = "a"
            case .experiment: short = "x"
            case .keystrokes: short = "k"
            case .panelHoldsKey: short = "h"
            case .panelThenKeystrokes: short = "p"
            case .hostStaysOpen: short = "o"
            case .hostScript: short = "s"
            case .hostLines: short = "l"
            case .hostLong: short = "g"
            case .hostIME: short = "i"
            }
            let root = URL(fileURLWithPath: "/tmp/\(marker)-\(String(describing: electron))-\(short)", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let launch: ElectronLaunch
            do {
                launch = try prepareElectron(electron, in: root)
            } catch {
                skip(&row, "could not prepare the probe's profile: \(error.localizedDescription)")
                continue
            }
            runIsolated(&row, appURL: appURL, bundleID: electron.bundleID, arguments: launch.arguments,
                        environment: launch.environment, variant: variant, titleMarker: launch.titleMarker,
                        settle: electron == .obsidian ? 5 : 6, verify: { launch.verify }) { pid in
                guard electron == .obsidian else { return "editor focused on opening the probe's file" }
                // Obsidian opens the note without focusing its editor: click
                // into the note, as a user would, if the window there is the
                // probe's own.
                guard let window = WindowList.mainWindow(of: pid) else { return "no window to click into" }
                let point = CGPoint(x: window.bounds.minX + window.bounds.width * 0.62,
                                    y: window.bounds.minY + window.bounds.height * 0.3)
                let clicked = SyntheticInput.click(at: point, ifTopWindowBelongsTo: pid)
                Thread.sleep(forTimeInterval: 0.8)
                return clicked ? "click into the note" : "not clicked (another window was in front)"
            }
        }
    }

    struct ElectronLaunch {
        var arguments: [String]
        var environment: [String: String]
        var titleMarker: String
        /// Reads the file the editor saves on its own, without Accessibility.
        var verify: (InsertionText) -> IndependentCheck
    }

    /// A throwaway profile, and for Obsidian a throwaway vault, so the
    /// separate instance never opens anything of the user's.
    private func prepareElectron(_ electron: ElectronApp, in root: URL) throws -> ElectronLaunch {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let userData = root.appendingPathComponent("u", isDirectory: true)
        switch electron {
        case .vscode, .cursor:
            let settings = userData.appendingPathComponent("User", isDirectory: true)
            try fileManager.createDirectory(at: settings, withIntermediateDirectories: true)
            // Auto save writes the probe's file to disk shortly after each
            // change, which is the check independent of Accessibility.
            let json = """
                {"workbench.startupEditor": "none", "telemetry.telemetryLevel": "off", "update.mode": "none",
                 "workbench.enableExperiments": false, "security.workspace.trust.enabled": false,
                 "workbench.tips.enabled": false, "window.restoreWindows": "none",
                 "files.autoSave": "afterDelay", "files.autoSaveDelay": 300}
                """
            try Data(json.utf8).write(to: settings.appendingPathComponent("settings.json"))
            let name = "ax-probe-\(marker).txt"
            let file = root.appendingPathComponent(name)
            try Data("AX probe file. The probe deletes it afterwards.\n".utf8).write(to: file)
            return ElectronLaunch(
                arguments: ["--user-data-dir", userData.path,
                            "--extensions-dir", root.appendingPathComponent("e").path,
                            "--disable-extensions", "--skip-welcome", "--skip-release-notes", "--disable-workspace-trust",
                            // Without these a fresh profile asks the keychain
                            // for its Safe Storage key, and macOS puts a
                            // keychain prompt in front of the instance.
                            "--use-mock-keychain", "--use-inmemory-secretstorage",
                            "--new-window", file.path],
                // VS Code keeps state shared by all its profiles under the
                // home directory (~/.vscode-shared); a throwaway home keeps
                // the instance out of the user's.
                environment: ["HOME": root.path],
                titleMarker: name,
                verify: IndependentChecks.files({ [file] }, label: "file on disk",
                                                source: "the probe's file as the editor's auto save wrote it to disk",
                                                timeout: 4))
        case .obsidian:
            let vaultName = "AX probe vault \(marker)"
            let vault = root.appendingPathComponent(vaultName, isDirectory: true)
            let config = vault.appendingPathComponent(".obsidian", isDirectory: true)
            try fileManager.createDirectory(at: config, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: userData, withIntermediateDirectories: true)
            try Data("# AX probe note\n\nThe probe deletes this vault afterwards.\n".utf8)
                .write(to: vault.appendingPathComponent("Probe.md"))
            let workspace = """
                {"main":{"id":"axprobemain","type":"split","children":[{"id":"axprobetabs","type":"tabs","children":[
                {"id":"axprobeleaf","type":"leaf","state":{"type":"markdown","state":{"file":"Probe.md","mode":"source","source":false}}}
                ]}],"direction":"vertical"},"active":"axprobeleaf","lastOpenFiles":["Probe.md"]}
                """
            try Data(workspace.utf8).write(to: config.appendingPathComponent("workspace.json"))
            let registry = """
                {"vaults":{"\(String(marker.prefix(16)).padding(toLength: 16, withPad: "0", startingAt: 0))":{"path":"\(vault.path)","ts":\(Int(Date().timeIntervalSince1970 * 1000)),"open":true}}}
                """
            try Data(registry.utf8).write(to: userData.appendingPathComponent("obsidian.json"))
            // Every note in the throwaway vault, in case the click made a
            // new one; Obsidian saves a note about 2 s after an edit.
            let notes: () -> [URL] = {
                let enumerator = fileManager.enumerator(at: vault, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
                return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "md" }
            }
            return ElectronLaunch(
                arguments: ["--user-data-dir=\(userData.path)"], environment: [:], titleMarker: vaultName,
                verify: IndependentChecks.files(notes, label: "note file on disk",
                                                source: "the throwaway vault's notes as Obsidian saved them to disk",
                                                timeout: 6))
        }
    }

    /// Runs one row in a separate instance of a Chromium or Electron App on
    /// the probe's own profile, which the probe ends afterwards. The instance
    /// must be a new process showing a window titled with the probe's marker;
    /// otherwise nothing is inserted. `verify` makes the check independent of
    /// Accessibility once the field is focused.
    private func runIsolated(_ row: inout ProbeRow, appURL: URL, bundleID: String, arguments: [String],
                             environment: [String: String] = [:], variant: Variant, titleMarker: String,
                             settle: TimeInterval, verify: (() -> (InsertionText) -> IndependentCheck)?,
                             focus: (pid_t) -> String) {
        let existing = Set(Apps.running(bundleID).map(\.processIdentifier))
        guard let app = Apps.launchNewInstance(appURL, arguments: arguments, environment: environment, timeout: 30) else {
            skip(&row, "a separate instance did not start")
            return
        }
        let pid = app.processIdentifier
        guard !existing.contains(pid) else {
            skip(&row, "the App handed the launch to the user's running instance; nothing inserted")
            return
        }
        OwnedProcesses.add(pid)
        // An instance that never showed the probe's window may not be on the
        // probe's profile after all, so it gets longer to quit on its own.
        var grace: TimeInterval = 4
        defer {
            row.cleanup = "separate instance " + Apps.end(pid, grace: grace) + "; its profile deleted"
            OwnedProcesses.remove(pid)
        }
        row.ownership = "separate instance on the probe's throwaway profile"
        // Only window titles are read before the Host's call: AppKit answers
        // them without asking the App's web content for its accessibility.
        guard window(of: pid, titleContaining: titleMarker, timeout: 30) != nil else {
            let titles = AX.windows(AX.application(pid)).compactMap(AX.title)
            let serverWindows = WindowList.onScreen().filter { $0.ownerPID == pid && $0.layer == 0 }.count
            grace = 15
            let alive = Apps.isAlive(pid) ? "running" : "exited"
            skip(&row, "no window titled with the probe's marker appeared (windows: \(titles.isEmpty ? "none" : titles.joined(separator: ", ")); window server: \(serverWindows) on screen; instance \(alive)); nothing inserted")
            return
        }
        bringForward(pid)
        Thread.sleep(forTimeInterval: settle)
        if case .experiment(let attribute) = variant {
            let appElement = AX.application(pid)
            let error = AX.set(appElement, attribute, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 2.5)
            row.experiment = ExperimentInfo(attribute: attribute, setResult: AX.describe(error),
                                            valueAfter: AX.bool(appElement, attribute).map { $0 ? "true" : "false" })
        }
        row.focusAction = focus(pid)
        bringForward(pid)
        let check = verify?()
        switch variant {
        case .asIs:
            row.notes.append("before the Host's call the probe read only window titles")
            insert(&row, into: pid, preQuery: false, verify: check)
        case .experiment:
            let gate: () -> String? = {
                let (info, _) = HostInsertion.describeFocus(in: pid)
                guard info.present else { return nil }
                return info.windowTitle?.contains(titleMarker) == true
                    ? nil : "the focused element is not in the probe's window (\(info.windowTitle ?? "no window"))"
            }
            insert(&row, into: pid, preQuery: true, gate: gate, verify: check)
        case .keystrokes:
            guard let check else {
                skip(&row, "no check independent of Accessibility for this control")
                return
            }
            row.notes.append("before and after typing the probe read only window titles")
            // Every window of this instance is the probe's own, so keys may
            // go to it through the HID tap while it is frontmost.
            typeKeystrokes(&row, into: pid, gate: nil, hidGate: {
                Apps.frontmost()?.processIdentifier == pid ? nil : "the probe's instance is not frontmost"
            }, verify: check)
        case .panelHoldsKey:
            insert(&row, into: pid, preQuery: false, verify: check)
            row.notes.append("the panel variant is not planned for separate instances; this is the as-is call")
        case .panelThenKeystrokes:
            guard let check else {
                skip(&row, "no check independent of Accessibility for this control")
                return
            }
            row.notes.append("the probe read only window titles; every window of this instance is the probe's own")
            keystrokesAfterPanel(&row, into: pid, axQueries: false, gate: frontmostGate(pid), verify: check)
        case .hostStaysOpen, .hostScript, .hostLines, .hostLong, .hostIME:
            insert(&row, into: pid, preQuery: false, verify: check)
        }
    }

    // MARK: Panel variants

    static let panelNote = "Panel variants: the probe shows its own NSPanel configured as Host A2's PluginViewPanelWindow (style mask titled, closable, fullSizeContentView, nonactivatingPanel; canBecomeKey true; floating; makeKeyAndOrderFront; a text field made first responder) while the probe runs as an accessory App, as the Host does. The origin is NSWorkspace's frontmost App captured just before the panel is shown, as the Host captures it at presentation; the row is skipped unless that is the target. The Host call is AppKitPluginHostServiceProvider.insertText(_:intoApplication: origin), as main.swift makes it. After the panel closes, the same call is made once more with a text of its own."

    static let panelKeysNote = "P3 flow rows: no Host call. The panel is shown and confirmed key, then closed; the target is activated with NSRunningApplication.activate() and the probe waits until it is frontmost (at most 1 s) and 50 ms more, as ClipboardHistoryPaster does; the text is then posted as Unicode keyboard events through the HID event tap, the tap the Host's paste keystroke uses, and only while the probe's gate confirms the target is frontmost and its focus is in the probe's own window (or nothing in it is focused). TextEdit and the Safari address bar are read back through Accessibility, TextEdit also from its saved file."

    static let hostExtraNote = "Current Host rows: before each Host call the probe shows its stand-in Plugin View panel (key, non-activating) over the target, whose origin is the target. \"view closes on Insert\" closes the panel, then calls HostTextInserter.insertAndWait(text, into: .application(origin)); \"pinned view stays open\" makes the same call with the panel left on screen; \"insert_text into the App in front\" calls it with .frontmost while the panel is key. Line-break rows type LF and CRLF (each one Shift-Return) and a tab (the Tab key); they count as found when the value holds the text with every line break as LF. IME rows select the input source with TISSelectInputSource and reselect the previous one afterwards; Pinyin's own Chinese/English mode is not visible to the probe."

    private func frontmostGate(_ processIdentifier: pid_t) -> () -> String? {
        { Apps.frontmost()?.processIdentifier == processIdentifier ? nil : "the target is not frontmost" }
    }

    /// For keys through the HID tap into an App that may hold the user's
    /// own windows: the App must be frontmost, and its focus in the probe's
    /// window. With nothing focused and no focused window, the keys have
    /// nowhere to land in the App, so they may go.
    private func keyGate(_ processIdentifier: pid_t, _ window: AXUIElement) -> () -> String? {
        {
            guard Apps.frontmost()?.processIdentifier == processIdentifier else { return "the target is not frontmost" }
            let app = AX.application(processIdentifier)
            if AX.element(app, kAXFocusedUIElementAttribute) != nil { return self.windowGate(processIdentifier, window)() }
            guard let focusedWindow = AX.element(app, kAXFocusedWindowAttribute) else { return nil }
            return AX.equal(focusedWindow, window)
                ? nil : "nothing focused, and the App's focused window (\(AX.title(focusedWindow) ?? "untitled")) is not the probe's"
        }
    }

    /// The target's focused element's value through Accessibility, for the
    /// controls with no check independent of it.
    private func axReadBack(_ processIdentifier: pid_t) -> (InsertionText) -> IndependentCheck {
        { text in
            let source = "kAXValue of the target's focused element (Accessibility; not independent)"
            var value: String?
            Apps.poll(1.5, interval: 0.1) {
                value = HostInsertion.focusedValue(in: processIdentifier)
                return value?.contains(text.text) == true
            }
            guard let value else {
                return IndependentCheck(label: "AX read-back", source: source, observed: false,
                                        detail: "no focused element value")
            }
            return IndependentCheck(label: "AX read-back", source: source, value: value, text: text)
        }
    }

    private func focusedWindowText(_ processIdentifier: pid_t) -> String {
        let (error, value) = AX.copy(AX.application(processIdentifier), kAXFocusedWindowAttribute)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return "none (\(AX.describe(error)))"
        }
        return "\"\(AX.title(value as! AXUIElement) ?? "untitled")\""
    }

    private func fixtureReport(_ status: URL?) -> String? {
        guard let status, let read = FixtureStatusRead.read(status) else { return nil }
        return "active \(read.isActive ? "yes" : "no"), its window key with the control focused \(read.controlHasKeyboardFocus ? "yes" : "no")"
    }

    /// Shows the stand-in panel over the target and records what holds the
    /// keyboard. Nil, with the row skipped, if the target was not frontmost
    /// first, since the Host would then take another App as the origin.
    private func showPanel(_ row: inout ProbeRow, over processIdentifier: pid_t, axQueries: Bool,
                           fixtureStatus: URL?) -> (ProbePanel, PanelObservation)? {
        var observation = PanelObservation(origin: Apps.frontmostDescription(),
                                           originIsTarget: Apps.frontmost()?.processIdentifier == processIdentifier)
        if axQueries && trusted {
            observation.targetFocusBeforePanel = HostInsertion.describeFocus(in: processIdentifier).0
        }
        if let report = fixtureReport(fixtureStatus) { observation.notes.append("fixture before panel: \(report)") }
        guard observation.originIsTarget else {
            row.panel = observation
            skip(&row, "the target was not frontmost before the panel")
            return nil
        }
        let panel = ProbePanel.show(title: "AX probe panel \(marker)")
        Apps.poll(2, interval: 0.1) { panel.state().isKey }
        // Long enough for the fixture's 200 ms status report to catch up.
        Thread.sleep(forTimeInterval: 0.5)
        observation.panelState = panel.state()
        observation.frontmostWhilePanelKey = Apps.frontmostDescription()
        observation.targetStillFrontmost = Apps.frontmost()?.processIdentifier == processIdentifier
        if axQueries && trusted {
            observation.targetFocusWhilePanelKey = HostInsertion.describeFocus(in: processIdentifier).0
            observation.targetFocusedWindowWhilePanelKey = focusedWindowText(processIdentifier)
        }
        if let report = fixtureReport(fixtureStatus) { observation.notes.append("fixture while panel key: \(report)") }
        if observation.targetStillFrontmost != true { observation.notes.append("the target lost frontmost to the panel") }
        return (panel, observation)
    }

    /// Task 1: the Host's call while the panel holds key, then the same call
    /// once it has closed. Returns the two texts.
    @discardableResult
    private func insertWhilePanelHoldsKey(_ row: inout ProbeRow, into processIdentifier: pid_t, gate: (() -> String?)?,
                                          fixtureStatus: URL? = nil, verify: ((InsertionText) -> IndependentCheck)?)
        -> (first: InsertionText, control: InsertionText)? {
        let started = Date()
        defer { row.durationSeconds = (Date().timeIntervalSince(started) * 10).rounded() / 10 }
        if let gate, let reason = gate() {
            skip(&row, "not inserted: \(reason)")
            return nil
        }
        guard let (panel, shown) = showPanel(&row, over: processIdentifier, axQueries: true, fixtureStatus: fixtureStatus) else {
            return nil
        }
        var observation = shown
        defer { row.panel = observation }
        row.focusedBefore = observation.targetFocusWhilePanelKey
        row.frontmostAtInsertion = Apps.frontmostDescription()
        row.status = "ran"
        let text = nextText()
        // The origin captured before the panel, which showPanel checked is
        // the target.
        row.attempt = insertion.attempt(text, into: processIdentifier)
        if let first = row.attempt, !first.step.isHostSuccess, first.step != .accessibilityNotGranted {
            Thread.sleep(forTimeInterval: 1)
            row.retry = insertion.attempt(text, into: processIdentifier)
        }
        if let verify { row.independentCheck = verify(text) }
        // The Host makes the call on its main thread, inside the panel's
        // key event; once more so, the panel still key.
        let onMain = nextText()
        if panel.state().isKey, gate?() == nil {
            observation.hostCallOnMainWhilePanelKey = insertion.attempt(onMain, into: processIdentifier, onMainThread: true)
            if let verify { observation.onMainCheck = verify(onMain) }
        }
        if let fixtureStatus { row.fixtureValue = FixtureStatusRead.read(fixtureStatus)?.value }
        panel.close()
        Thread.sleep(forTimeInterval: 0.6)
        observation.frontmostAfterClose = Apps.frontmostDescription()
        observation.targetFocusAfterClose = HostInsertion.describeFocus(in: processIdentifier).0
        if let report = fixtureReport(fixtureStatus) { observation.notes.append("fixture after panel closed: \(report)") }
        let control = nextText()
        if let gate, let reason = gate() {
            observation.notes.append("no Host call after close: \(reason)")
        } else {
            observation.hostCallAfterClose = insertion.attempt(control, into: processIdentifier)
            if let verify { observation.afterCloseCheck = verify(control) }
        }
        row.focusedAfter = HostInsertion.describeFocus(in: processIdentifier).0
        if let fixtureStatus { row.fixtureValue = FixtureStatusRead.read(fixtureStatus)?.value }
        return (text, control)
    }

    /// Task 2, the P3 flow: the panel shown then closed, the target
    /// activated as ClipboardHistoryPaster does, the text typed through the
    /// HID tap. No Host call. Returns the text typed.
    @discardableResult
    private func keystrokesAfterPanel(_ row: inout ProbeRow, into processIdentifier: pid_t, axQueries: Bool,
                                      gate: @escaping () -> String?, fixtureStatus: URL? = nil,
                                      verify: (InsertionText) -> IndependentCheck) -> InsertionText? {
        let started = Date()
        defer { row.durationSeconds = (Date().timeIntervalSince(started) * 10).rounded() / 10 }
        if let reason = gate() {
            skip(&row, "not typed: \(reason)")
            return nil
        }
        guard let (panel, shown) = showPanel(&row, over: processIdentifier, axQueries: axQueries,
                                             fixtureStatus: fixtureStatus) else {
            return nil
        }
        var observation = shown
        defer { row.panel = observation }
        if axQueries { row.focusedBefore = observation.targetFocusWhilePanelKey }
        row.status = "ran"
        panel.close()
        guard let target = NSRunningApplication(processIdentifier: processIdentifier) else {
            observation.activation = "the target is gone"
            return nil
        }
        let activationStarted = Date()
        let activated: Bool
        if #available(macOS 14, *) { activated = target.activate() } else { activated = target.activate(options: []) }
        let frontmost = Apps.poll(1, interval: 0.02) { Apps.frontmost()?.processIdentifier == processIdentifier }
        let waited = Int(Date().timeIntervalSince(activationStarted) * 1000)
        observation.activation = "activate() returned \(activated); "
            + (frontmost ? "frontmost after \(waited) ms" : "not frontmost within 1 s (the Host would fall back to Copy)")
        guard frontmost else {
            row.keystrokes = KeystrokeExperiment(channels: [KeystrokeChannel(channel: "HID", eventsPosted: 0,
                                                                             skipped: "the target was not frontmost within 1 s")])
            return nil
        }
        Thread.sleep(forTimeInterval: 0.05)
        observation.frontmostAfterClose = Apps.frontmostDescription()
        if axQueries && trusted { observation.targetFocusAfterClose = HostInsertion.describeFocus(in: processIdentifier).0 }
        if let report = fixtureReport(fixtureStatus) { observation.notes.append("fixture after activation: \(report)") }
        row.frontmostAtInsertion = Apps.frontmostDescription()
        if let reason = gate() {
            row.keystrokes = KeystrokeExperiment(channels: [KeystrokeChannel(channel: "HID", eventsPosted: 0,
                                                                             skipped: reason)])
            return nil
        }
        let text = nextText()
        let posted = SyntheticInput.typeUnicode(text.text, via: .hid)
        let check = verify(text)
        row.keystrokes = KeystrokeExperiment(channels: [KeystrokeChannel(
            channel: "HID", eventsPosted: posted, received: check.observed ? check.containsInsertedText : nil, check: check)])
        row.independentCheck = check
        if axQueries && trusted { row.focusedAfter = HostInsertion.describeFocus(in: processIdentifier).0 }
        if let fixtureStatus { row.fixtureValue = FixtureStatusRead.read(fixtureStatus)?.value }
        return text
    }
}
