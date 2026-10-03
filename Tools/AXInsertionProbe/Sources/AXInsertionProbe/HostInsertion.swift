import AppKit
import ApplicationServices
import SpinnetCore

/// The text one run inserts: a distinctive emoji pair and a marker unique to
/// the run, so a read-back can tell this insertion from anything already
/// there and can tell a dropped emoji from a dropped insertion.
struct InsertionText: Equatable {
    static let emoji = "😀🎉"
    let marker: String
    /// More text after the marker, for the current Host's line-break and
    /// long-text rows.
    var suffix = ""

    init(marker: String, suffix: String = "") {
        self.marker = marker
        self.suffix = suffix
    }

    static func random() -> InsertionText {
        InsertionText(marker: "axp" + String(UInt32.random(in: 0x100000...0xFFFFFF), radix: 16))
    }

    var text: String { Self.emoji + marker + suffix }
    /// The second insertion of a selection pass.
    var replacement: InsertionText { InsertionText(marker: marker + "r") }
}

#if HOST_CURRENT
/// How the probe asks the current Host to insert, standing in for what
/// surrounds the Host's call.
enum HostCallMode: String, Codable {
    /// A Plugin View's standard insert with `closes_view`: the view closes,
    /// then the Host inserts into the view's origin.
    case viewCloses = "view closes on Insert"
    /// A standard insert in a pinned view: the Host inserts into the origin
    /// while the panel is still on screen.
    case viewStaysOpen = "view stays open (pinned)"
    /// The synchronous `insert_text` Host Service from a View Event, while
    /// the panel is key: the Host inserts into the App in front.
    case script = "insert_text from a View Event"
}
#endif


/// The current Host's insertion, called as main.swift calls it:
/// `HostTextInserter.insertAndWait(_:into:)` (the script path's call; the
/// view's asynchronous call runs the same sequence). Before each call the
/// probe shows its stand-in Plugin View panel, key and non-activating, over
/// the target, as the Host's view is when the user chooses Insert.
///
/// Without HOST_CURRENT:
/// The Host A2 insertion, called exactly as the Host calls it for a Plugin
/// View's standard insert action: `provider.insertText(text, intoApplication:
/// origin.processIdentifier)` (Sources/SpinnetHost/main.swift at af1a450).
/// `AppKitPluginHostServiceProvider` is the Host's own class, compiled from
/// Host A2 into this probe; the probe adds nothing to its sequence.
final class HostInsertion {
#if HOST_CURRENT
    private let inserter = HostTextInserter()
    var mode: HostCallMode = .viewCloses

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func attempt(_ text: InsertionText, into processIdentifier: pid_t, settle: TimeInterval = 0.35,
                 onMainThread: Bool = false) -> Attempt {
        var notes = ["Host asked: \(mode.rawValue)"]
        let origin = Apps.frontmost()
        notes.append("origin \(Apps.frontmostDescription() ?? "none")\(origin?.processIdentifier == processIdentifier ? " (the target)" : " (NOT the target)")")
        // The Host would insert into the origin, or the App in front; the
        // probe never lets that be anything but its own target.
        guard origin?.processIdentifier == processIdentifier else {
            return Attempt(step: .otherError, hostError: "probe: the target was not in front, so nothing was asked of the Host",
                           readBack: nil, elapsedMilliseconds: 0, hostNotes: notes)
        }
        let panel = ProbePanel.show(title: "Plugin View stand-in")
        Apps.poll(2, interval: 0.05) { panel.state().isKey }
        let shown = panel.state()
        notes.append("panel key \(shown.isKey ? "yes" : "no"), probe active \(shown.probeIsActive ? "yes" : "no"), target in front while panel key \(Apps.frontmost()?.processIdentifier == processIdentifier ? "yes" : "no")")
        if mode == .viewCloses { panel.close() }
        let started = Date()
        var hostError: PluginHostServiceError?
        do {
            try inserter.insertAndWait(text.text, into: mode == .script ? .frontmost : .application(processIdentifier))
        } catch let error as PluginHostServiceError {
            hostError = error
        } catch {
            hostError = .failed(error.localizedDescription)
        }
        let elapsed = Date().timeIntervalSince(started) * 1000
        if mode != .viewCloses {
            let after = panel.state()
            notes.append("after the call: panel visible \(after.isVisible ? "yes" : "no"), key \(after.isKey ? "yes" : "no"), probe active \(after.probeIsActive ? "yes" : "no")")
        }
        notes.append("in front after the call: \(Apps.frontmostDescription() ?? "none")")
        if let hostError {
            panel.close()
            return Attempt(step: Self.step(for: hostError), hostError: hostError.description, readBack: nil,
                           elapsedMilliseconds: elapsed, hostNotes: notes)
        }
        Thread.sleep(forTimeInterval: settle)
        panel.close()
        let readBack = Self.readBack(text, in: processIdentifier)
        return Attempt(step: Self.step(afterSuccess: readBack), hostError: nil, readBack: readBack,
                       elapsedMilliseconds: elapsed, hostNotes: notes)
    }

    /// The current Host's own messages (`HostTextInserter.swift`).
    static func step(for error: PluginHostServiceError) -> InsertionStep {
        switch error {
        case .systemPermissionDenied(.accessibility): return .accessibilityNotGranted
        case .unavailable("The focused field is a password field; nothing was inserted"): return .refusedPasswordField
        case .unavailable("The App to insert into did not come to the front; nothing was inserted"): return .refusedNotFrontmost
        case .unavailable("The App to insert into is no longer open"): return .refusedTargetGone
        case .unavailable("Spinnet does not insert text into itself"): return .refusedSpinnetItself
        case .failed("The App to insert into left the front while the text was typed; only part of it was inserted"):
            return .stoppedLostFront
        default: return .otherError
        }
    }

    static func step(afterSuccess readBack: ReadBack) -> InsertionStep {
        guard readBack.readable else { return .deliveredUnverified }
        return readBack.containsInsertedText ? .delivered : .deliveredTextNotFound
    }
#else
    private let provider = AppKitPluginHostServiceProvider()

    var accessibilityGranted: Bool { provider.isGranted(.accessibility) }

    /// One Host call, then the read-back after `settle`. `onMainThread`
    /// makes the call on the main thread, where the Host makes it while
    /// handling the Plugin View's key event; the probe's run is on another.
    func attempt(_ text: InsertionText, into processIdentifier: pid_t, settle: TimeInterval = 0.35,
                 onMainThread: Bool = false) -> Attempt {
        let started = Date()
        var hostError: PluginHostServiceError?
        let call = {
            do {
                try self.provider.insertText(text.text, intoApplication: processIdentifier)
            } catch let error as PluginHostServiceError {
                hostError = error
            } catch {
                hostError = .failed(error.localizedDescription)
            }
        }
        if onMainThread && !Thread.isMainThread { DispatchQueue.main.sync(execute: call) } else { call() }
        let elapsed = Date().timeIntervalSince(started) * 1000
        if let hostError {
            return Attempt(step: Self.step(for: hostError), hostError: hostError.description, readBack: nil,
                           elapsedMilliseconds: elapsed)
        }
        Thread.sleep(forTimeInterval: settle)
        let readBack = Self.readBack(text, in: processIdentifier)
        return Attempt(step: Self.step(afterSuccess: readBack), hostError: nil, readBack: readBack,
                       elapsedMilliseconds: elapsed)
    }

    /// Which step failed, from the error the Host threw. The messages are
    /// Host A2's own (`PluginHostServices.swift`, `insertText(_:into:)`).
    static func step(for error: PluginHostServiceError) -> InsertionStep {
        switch error {
        case .systemPermissionDenied(.accessibility):
            return .accessibilityNotGranted
        case .unavailable("No focused text field"):
            return .noFocusedElement
        case .unavailable("The focused App does not accept inserted text"):
            return .selectedTextNotSettable
        case .failed("The focused App did not accept the text"):
            return .setSelectedTextError
        default:
            return .otherError
        }
    }

    static func step(afterSuccess readBack: ReadBack) -> InsertionStep {
        guard readBack.readable else { return .setOKUnverified }
        return readBack.containsInsertedText ? .inserted : .setOKTextNotFound
    }
#endif

    static func readBack(_ text: InsertionText, in processIdentifier: pid_t) -> ReadBack {
        let app = AX.application(processIdentifier)
        let (focusError, focused) = AX.copy(app, kAXFocusedUIElementAttribute)
        guard focusError == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return ReadBack(source: "kAXValue of the focused element", readable: false,
                            axError: "focused element: \(AX.describe(focusError))", valueLength: nil,
                            containsInsertedText: false, containsMarker: false, containsEmoji: false, excerpt: nil)
        }
        let element = focused as! AXUIElement
        let (valueError, value) = AX.copy(element, kAXValueAttribute)
        guard valueError == .success, let string = value as? String else {
            return ReadBack(source: "kAXValue of the focused element", readable: false,
                            axError: valueError == .success ? "value is not text" : AX.describe(valueError),
                            valueLength: nil, containsInsertedText: false, containsMarker: false,
                            containsEmoji: false, excerpt: nil)
        }
        return evaluate(string, for: text, source: "kAXValue of the focused element")
    }

    static func evaluate(_ value: String, for text: InsertionText, source: String) -> ReadBack {
        var excerpt: String?
        if let range = value.range(of: text.marker) {
            let start = value.index(range.lowerBound, offsetBy: -40, limitedBy: value.startIndex) ?? value.startIndex
            let end = value.index(range.upperBound, offsetBy: 40, limitedBy: value.endIndex) ?? value.endIndex
            excerpt = String(value[start..<end])
        }
        // Each line break is typed as one Shift-Return, which Apps store as
        // LF, so a CRLF in the text is found as LF.
        func lines(_ string: String) -> String {
            string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        return ReadBack(source: source, readable: true, axError: nil, valueLength: (value as NSString).length,
                        containsInsertedText: lines(value).contains(lines(text.text)), containsMarker: value.contains(text.marker),
                        containsEmoji: value.contains(InsertionText.emoji), excerpt: excerpt)
    }

    /// Selects the first insertion and inserts again through the Host, to
    /// see whether the Host's set replaces a selection as typing would.
    func selectionPass(after first: InsertionText, in processIdentifier: pid_t) -> SelectionResult {
        let app = AX.application(processIdentifier)
        guard let element = AX.element(app, kAXFocusedUIElementAttribute),
              let value = AX.string(element, kAXValueAttribute) else {
            return SelectionResult(result: "not_verifiable", hostError: nil, detail: "value unreadable")
        }
        let range = (value as NSString).range(of: first.text)
        guard range.location != NSNotFound else {
            return SelectionResult(result: "not_verifiable", hostError: nil, detail: "first insertion not found")
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            return SelectionResult(result: "not_verifiable", hostError: nil, detail: "range not encodable")
        }
        let setError = AX.set(element, kAXSelectedTextRangeAttribute, rangeValue)
        Thread.sleep(forTimeInterval: 0.2)
        let selected = AX.string(element, kAXSelectedTextAttribute)
        guard setError == .success, selected == first.text else {
            return SelectionResult(result: "selection_not_set", hostError: nil,
                                   detail: "set range: \(AX.describe(setError)); selected text \(selected.map { "\"\($0)\"" } ?? "unreadable")")
        }
        let second = first.replacement
        let attempt = self.attempt(second, into: processIdentifier)
        guard attempt.step.isHostSuccess else {
            return SelectionResult(result: "host_failed", hostError: attempt.hostError, detail: attempt.step.rawValue)
        }
        guard let after = AX.string(element, kAXValueAttribute) ?? Self.focusedValue(in: processIdentifier) else {
            return SelectionResult(result: "not_verifiable", hostError: nil, detail: "value unreadable after insert")
        }
        let hasSecond = after.contains(second.text)
        // The second marker extends the first, so look for the first one
        // standing alone.
        let hasFirst = after.replacingOccurrences(of: second.text, with: "").contains(first.text)
        switch (hasSecond, hasFirst) {
        case (true, false): return SelectionResult(result: "replaced_selection", hostError: nil, detail: nil)
        case (true, true): return SelectionResult(result: "inserted_beside_selection", hostError: nil, detail: nil)
        default: return SelectionResult(result: "not_verifiable", hostError: nil, detail: "second insertion not found")
        }
    }

    static func focusedValue(in processIdentifier: pid_t) -> String? {
        AX.element(AX.application(processIdentifier), kAXFocusedUIElementAttribute)
            .flatMap { AX.string($0, kAXValueAttribute) }
    }

    /// The focused element as Accessibility reports it, read by the probe
    /// (not by the Host) before or after the Host's call.
    static func describeFocus(in processIdentifier: pid_t) -> (ElementInfo, AXUIElement?) {
        let app = AX.application(processIdentifier)
        let (error, value) = AX.copy(app, kAXFocusedUIElementAttribute)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (ElementInfo(present: false, focusedElementError: AX.describe(error)), nil)
        }
        let element = value as! AXUIElement
        func settable(_ attribute: String) -> String {
            let (error, settable) = AX.settable(element, attribute)
            return error == .success ? (settable ? "yes" : "no") : AX.describe(error)
        }
        let window = AX.window(containing: element)
        let info = ElementInfo(
            present: true, focusedElementError: nil,
            role: AX.role(element), subrole: AX.string(element, kAXSubroleAttribute),
            domIdentifier: AX.string(element, "AXDOMIdentifier"),
            windowTitle: window.flatMap(AX.title),
            selectedTextSettable: settable(kAXSelectedTextAttribute),
            selectedTextRangeSettable: settable(kAXSelectedTextRangeAttribute),
            valueLength: AX.string(element, kAXValueAttribute).map { ($0 as NSString).length }
        )
        return (info, element)
    }
}
