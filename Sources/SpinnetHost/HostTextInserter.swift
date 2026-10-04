import AppKit
import ApplicationServices
import SpinnetCore

/// How the Host inserts text into another App, for `insert_text` and a
/// Plugin View's standard insert (#69, product choice P3). It follows
/// Clipboard History's paste flow: bring the target App to the front, wait
/// until it is, then deliver. The text is typed as Unicode keyboard events
/// posted to that App's process, never through the clipboard, because
/// Accessibility writes silently do nothing in web content and Electron
/// editors.
///
/// Success means the events were posted while the App was in front, not
/// that the App took them.
final class HostTextInserter {
    enum Target: Equatable {
        /// A Plugin View's origin: the App in front when it was presented.
        case application(pid_t)
        /// The App in front when the Host Service runs.
        case frontmost
    }

    /// One key press.
    enum Keystroke: Equatable {
        /// Whole characters, at most `maximumUnitsPerEvent` UTF-16 units.
        case text(String)
        /// Shift-Return: a new line in editors, and in chat-style fields a
        /// new line rather than sending.
        case lineBreak
        case tab
    }

    /// The most UTF-16 units one event carries: the limit
    /// `CGEvent.keyboardSetUnicodeString` documents.
    static let maximumUnitsPerEvent = 20
    /// How long the target may take to come to the front, as Clipboard
    /// History allows a paste.
    static let activationTimeout: TimeInterval = 1
    /// A moment once it is, for its key window and focus to come back.
    static let settleDelay: TimeInterval = 0.05
    static let pollInterval: TimeInterval = 0.02
    /// Between key presses, so a busy App's event queue keeps up.
    static let strokeInterval: TimeInterval = 0.002

    // What a failed insertion says. The candidate path (`host_operations`)
    // reads its reason from which one it is.
    static let noAppInFront = PluginHostServiceError.unavailable("No App is in front to insert into")
    static let intoItself = PluginHostServiceError.unavailable("Spinnet does not insert text into itself")
    static let notOpen = PluginHostServiceError.unavailable("The App to insert into is no longer open")
    static let didNotComeForward = PluginHostServiceError.unavailable(
        "The App to insert into did not come to the front; nothing was inserted")
    static let passwordField = PluginHostServiceError.unavailable("The focused field is a password field; nothing was inserted")
    static let leftTheFront = PluginHostServiceError.failed(
        "The App to insert into left the front while the text was typed; only part of it was inserted")
    static let noKeyboardEvents = PluginHostServiceError.failed("The keyboard events could not be created")

    /// What the inserter touches of the desktop. Everything but `post` and
    /// `pause` runs on the main thread; those two run where `deliver` puts
    /// them.
    struct Environment {
        var isTrusted: () -> Bool
        var ownProcessIdentifier: pid_t
        var isRunning: (pid_t) -> Bool
        var frontmost: () -> pid_t?
        /// Brings the App to the front, which takes the keyboard from a
        /// Plugin View's non-activating panel.
        var activate: (pid_t) -> Void
        /// Whether a window of Spinnet's own still has the keyboard.
        var holdsKeyboard: () -> Bool
        var focusedFieldIsSecure: (pid_t) -> Bool
        var post: (Keystroke, pid_t) -> Bool
        var pause: (TimeInterval) -> Void
        /// Runs work on the main thread after a delay.
        var schedule: (TimeInterval, @escaping () -> Void) -> Void
        /// Runs the typing off the main thread, so a long text never stalls
        /// the UI.
        var deliver: (@escaping () -> Void) -> Void
        var now: () -> Date
    }

    private let environment: Environment

    init(environment: Environment = .live) {
        self.environment = environment
    }

    /// Inserts `text` into `target`. Call on the main thread; `completion`
    /// runs there once, with nil when every key press was posted.
    func insert(_ text: String, into target: Target, completion: @escaping (PluginHostServiceError?) -> Void) {
        guard environment.isTrusted() else { return completion(.systemPermissionDenied(.accessibility)) }
        let strokes: [Keystroke]
        do {
            strokes = try Self.keystrokes(for: text)
        } catch {
            return completion(error as? PluginHostServiceError ?? .invalidInput("\(error)"))
        }
        let processIdentifier: pid_t
        switch target {
        case .application(let origin):
            processIdentifier = origin
        case .frontmost:
            guard let frontmost = environment.frontmost() else { return completion(Self.noAppInFront) }
            processIdentifier = frontmost
        }
        guard processIdentifier != environment.ownProcessIdentifier else { return completion(Self.intoItself) }
        guard environment.isRunning(processIdentifier) else { return completion(Self.notOpen) }
        guard !strokes.isEmpty else { return completion(nil) }
        // Always activated, even when already in front: a Plugin View's
        // panel holds the keyboard without taking the front from it.
        environment.activate(processIdentifier)
        let deadline = environment.now().addingTimeInterval(Self.activationTimeout)
        waitUntilReady(processIdentifier, deadline: deadline) { [environment] ready in
            guard ready else { return completion(Self.didNotComeForward) }
            environment.deliver {
                let outcome = Self.type(strokes, into: processIdentifier, environment: environment)
                environment.schedule(0) { completion(outcome) }
            }
        }
    }

    /// `insert`, for the synchronous `insert_text` Host Service: blocks the
    /// calling thread, which must not be the main thread, while the main
    /// thread brings the App forward.
    func insertAndWait(_ text: String, into target: Target, timeout: TimeInterval = 60) throws {
        guard !Thread.isMainThread else {
            throw PluginHostServiceError.failed("Text cannot be inserted from the main thread")
        }
        let finished = DispatchSemaphore(value: 0)
        let outcome = OutcomeBox()
        DispatchQueue.main.async {
            self.insert(text, into: target) { error in
                outcome.error = error
                finished.signal()
            }
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            throw PluginHostServiceError.failed("Inserting the text took too long")
        }
        if let error = outcome.error { throw error }
    }

    private final class OutcomeBox: @unchecked Sendable {
        var error: PluginHostServiceError?
    }

    /// Activation is asynchronous: a key press sent before the App is in
    /// front, or while Spinnet's panel still has the keyboard, would land in
    /// the wrong place.
    private func waitUntilReady(_ processIdentifier: pid_t, deadline: Date, then: @escaping (Bool) -> Void) {
        if environment.frontmost() == processIdentifier, !environment.holdsKeyboard() {
            environment.schedule(Self.settleDelay) { then(true) }
        } else if environment.now() >= deadline {
            then(false)
        } else {
            environment.schedule(Self.pollInterval) { [weak self] in
                guard let self else { return then(false) }
                self.waitUntilReady(processIdentifier, deadline: deadline, then: then)
            }
        }
    }

    /// Posts every key press, each only while the App is still in front.
    private static func type(_ strokes: [Keystroke], into processIdentifier: pid_t,
                             environment: Environment) -> PluginHostServiceError? {
        if environment.focusedFieldIsSecure(processIdentifier) { return passwordField }
        for (index, stroke) in strokes.enumerated() {
            guard environment.frontmost() == processIdentifier else {
                return index == 0 ? didNotComeForward : leftTheFront
            }
            guard environment.post(stroke, processIdentifier) else { return noKeyboardEvents }
            environment.pause(strokeInterval)
        }
        return nil
    }

    // MARK: - Keystrokes

    /// The key presses that type `text`. Each line break (LF, CR or CRLF)
    /// is one Shift-Return and each tab one Tab; any other control
    /// character is refused, since a Backspace or Escape would act on the
    /// App rather than insert. Characters are never split across events
    /// unless one alone is longer than an event carries, and then only
    /// between its scalars.
    static func keystrokes(for text: String) throws -> [Keystroke] {
        var strokes: [Keystroke] = []
        var chunk = ""
        var chunkUnits = 0
        func flush() {
            if !chunk.isEmpty { strokes.append(.text(chunk)) }
            chunk = ""
            chunkUnits = 0
        }
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                flush()
                strokes.append(.lineBreak)
                continue
            }
            if character == "\t" {
                flush()
                strokes.append(.tab)
                continue
            }
            if character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                throw PluginHostServiceError.invalidInput(
                    "insert_text types tabs and line breaks but no other control characters")
            }
            let units = character.utf16.count
            if units > maximumUnitsPerEvent {
                flush()
                strokes += splitBetweenScalars(character).map(Keystroke.text)
                continue
            }
            if chunkUnits + units > maximumUnitsPerEvent { flush() }
            chunk.append(character)
            chunkUnits += units
        }
        flush()
        return strokes
    }

    private static func splitBetweenScalars(_ character: Character) -> [String] {
        var pieces: [String] = []
        var piece = String.UnicodeScalarView()
        var pieceUnits = 0
        for scalar in character.unicodeScalars {
            let units = UTF16.width(scalar)
            if pieceUnits + units > maximumUnitsPerEvent {
                pieces.append(String(piece))
                piece = String.UnicodeScalarView()
                pieceUnits = 0
            }
            piece.append(scalar)
            pieceUnits += units
        }
        if !piece.isEmpty { pieces.append(String(piece)) }
        return pieces
    }
}

extension HostTextInserter {
    /// The element focused in the App, as Accessibility exposes it, or nil
    /// when it exposes none, as many web and Electron Apps do. Two reads
    /// compare equal when they name the same element (`CFEqual`), so the
    /// candidate path can tell whether focus moved inside the App between
    /// the user's gesture and the insertion.
    static func focusedElement(of processIdentifier: pid_t) -> AnyHashable? {
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return AnyHashable(focused as! AXUIElement)
    }
}

extension HostTextInserter.Environment {
    private static let deliveryQueue = DispatchQueue(label: "com.vulpsecula.Spinnet.text-insertion", qos: .userInitiated)

    /// The real desktop.
    static var live: HostTextInserter.Environment {
        HostTextInserter.Environment(
            isTrusted: { AXIsProcessTrusted() },
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            isRunning: { processIdentifier in
                guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return false }
                return !app.isTerminated
            },
            frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            activate: { processIdentifier in
                guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return }
                if #available(macOS 14, *) {
                    // Cooperative activation: Spinnet, active while its panel
                    // is key, hands activation over explicitly.
                    NSApp.yieldActivation(to: app)
                    app.activate()
                } else {
                    app.activate(options: [])
                }
                // A Plugin View's panel can keep the keyboard while the App
                // is already reported in front, and activating that App then
                // changes nothing; Spinnet steps back itself so the App's own
                // window takes the keyboard again.
                if NSApp.keyWindow != nil { NSApp.deactivate() }
            },
            holdsKeyboard: { NSApp.keyWindow != nil },
            focusedFieldIsSecure: { processIdentifier in
                let app = AXUIElementCreateApplication(processIdentifier)
                AXUIElementSetMessagingTimeout(app, 0.25)
                var focused: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
                let element = focused as! AXUIElement
                AXUIElementSetMessagingTimeout(element, 0.25)
                var subrole: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
                return subrole as? String == kAXSecureTextFieldSubrole
            },
            post: { stroke, processIdentifier in KeyboardEvents.post(stroke, to: processIdentifier) },
            pause: { Thread.sleep(forTimeInterval: $0) },
            schedule: { delay, work in
                if delay <= 0 { DispatchQueue.main.async(execute: work) } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                }
            },
            deliver: { deliveryQueue.async(execute: $0) },
            now: { Date() }
        )
    }
}

/// Synthesized key presses carrying their text as a Unicode string, posted
/// to one process so they can never reach another App.
enum KeyboardEvents {
    private static let returnKey: CGKeyCode = 0x24
    private static let tabKey: CGKeyCode = 0x30

    static func post(_ stroke: HostTextInserter.Keystroke, to processIdentifier: pid_t) -> Bool {
        let (key, flags, text): (CGKeyCode, CGEventFlags, String) = {
            switch stroke {
            case .text(let characters):
                // The key code is not used for text: the App reads the
                // Unicode string the event carries.
                return (0, [], characters)
            case .lineBreak:
                return (returnKey, .maskShift, "\r")
            case .tab:
                return (tabKey, [], "\t")
            }
        }()
        // A private source, so keys the user still holds, such as the
        // Command of the shortcut that chose Insert, do not combine with
        // these.
        let source = CGEventSource(stateID: .privateState)
        let units = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return false }
            event.flags = flags
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.postToPid(processIdentifier)
        }
        return true
    }
}
