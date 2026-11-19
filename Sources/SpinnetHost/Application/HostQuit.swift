import AppKit
import Darwin

/// Every way Spinnet quits goes through here: the Status Item's Quit, a
/// restart, and a quit Apple Event such as System Settings' Quit & Reopen.
///
/// AppKit silently ignores `terminate(_:)`, and the quit Apple Event that
/// would call it, while any window has a sheet attached; the delegate is
/// never asked. So Spinnet first takes down its own sheets and terminates
/// once none is left.
final class HostQuit: NSObject {
    static let shared = HostQuit()

    /// Takes down Settings' sheets and alerts. Each keeps its state, so
    /// `restorePresentations` can bring it back. True when Spinnet reopens
    /// itself, so Settings can show again as it was.
    var dismissPresentations: (_ relaunching: Bool) -> Void = { _ in }
    /// Brings Settings' sheets back after a quit was cancelled.
    var restorePresentations: () -> Void = {}

    private var quitting = false
    private var terminationAsked = false
    private var cancellationHandlers: [() -> Void] = []
    private var suspendedQuitEvent: NSAppleEventManager.SuspensionID?

    /// Quits once no sheet blocks it. `onCancel` runs if the quit does not
    /// happen, such as when the user keeps Spinnet open for a running Task.
    func quit(relaunching: Bool = false, onCancel: (() -> Void)? = nil) {
        if let onCancel { cancellationHandlers.append(onCancel) }
        guard !quitting else { return }
        quitting = true
        terminationAsked = false
        dismissPresentations(relaunching)
        // AppKit sheets end here; SwiftUI ones went with their state above.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        SheetDrain(
            hasAttachedSheet: { NSApp.windows.contains { $0.attachedSheet != nil } },
            schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
            finish: { [weak self] in self?.terminate() }
        ).start()
    }

    private func terminate() {
        NSApp.terminate(nil)
        // A quit the delegate never heard of was refused by AppKit; one it
        // answered later decides through `terminationCancelled()`.
        if !terminationAsked { terminationCancelled() }
    }

    /// The delegate was asked whether to terminate.
    func terminationRequested() { terminationAsked = true }

    /// The quit did not happen: Settings shows what it showed before, and a
    /// waiting relaunch or quit Apple Event hears so.
    func terminationCancelled() {
        guard quitting else { return }
        quitting = false
        restorePresentations()
        let handlers = cancellationHandlers
        cancellationHandlers = []
        handlers.forEach { $0() }
        resumeQuitEvent(cancelled: true)
    }

    /// Spinnet is about to exit: answer a waiting quit Apple Event.
    func terminationProceeds() {
        resumeQuitEvent(cancelled: false)
    }

    // MARK: Quit Apple Event

    /// Replaces AppKit's quit Apple Event handler, which calls
    /// `terminate(_:)` and so is refused while a sheet is attached.
    func installQuitEventHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication)
        )
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        let sender = Self.senderBundleIdentifier(of: event)
        let reopens = Self.reopensAfterQuit(requestedBy: sender) && HostRelaunch.isAvailable
        HostLog.lifecycle.info("Quit Apple Event from \(sender ?? "unknown", privacy: .public); reopening: \(reopens, privacy: .public)")
        guard !quitting else { return }
        // Answered once the quit happens or is cancelled, as AppKit's own
        // handler does, so a logout hears that Spinnet stayed open.
        suspendedQuitEvent = NSAppleEventManager.shared().suspendCurrentAppleEvent()
        if reopens { HostRelaunch.relaunch() } else { quit() }
    }

    private func resumeQuitEvent(cancelled: Bool) {
        guard let id = suspendedQuitEvent else { return }
        suspendedQuitEvent = nil
        let manager = NSAppleEventManager.shared()
        if cancelled {
            manager.replyAppleEvent(forSuspensionID: id)
                .setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: keyErrorNumber)
        }
        manager.resume(withSuspensionID: id)
    }

    /// System Settings quits an App to apply a System Permission and means to
    /// reopen it, but does not always bring an accessory App back, so Spinnet
    /// reopens itself. Its Privacy & Security pane runs as an extension.
    static func reopensAfterQuit(requestedBy bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.apple.systempreferences" || bundleIdentifier.hasPrefix("com.apple.settings.")
    }

    private static func senderBundleIdentifier(of event: NSAppleEventDescriptor) -> String? {
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
              pid > 0 else { return nil }
        if let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { return identifier }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              let bundle = bundlePath(containing: String(cString: buffer)) else { return nil }
        return Bundle(path: bundle)?.bundleIdentifier
    }

    /// The innermost App or extension bundle holding an executable, for a
    /// sender that is not a running App, such as a System Settings pane.
    static func bundlePath(containing executablePath: String) -> String? {
        var components = (executablePath as NSString).pathComponents
        while let last = components.last {
            if last.hasSuffix(".app") || last.hasSuffix(".appex") {
                return NSString.path(withComponents: components)
            }
            components.removeLast()
        }
        return nil
    }
}

/// Waits for every attached sheet to go, then finishes; after `attempts`
/// checks it finishes anyway, so a quit never hangs on a sheet.
struct SheetDrain {
    let hasAttachedSheet: () -> Bool
    let schedule: (TimeInterval, @escaping () -> Void) -> Void
    let finish: () -> Void
    var interval: TimeInterval = 0.05
    var attempts = 40

    func start() { check(remaining: attempts) }

    private func check(remaining: Int) {
        guard hasAttachedSheet(), remaining > 0 else { finish(); return }
        schedule(interval) { check(remaining: remaining - 1) }
    }
}
