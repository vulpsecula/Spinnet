import AppKit

/// Starting, finding and ending the Apps the probe drives.
enum Apps {
    static func url(of bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func version(at url: URL) -> String? {
        guard let info = Bundle(url: url)?.infoDictionary else { return nil }
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where build != short: return "\(short) (\(build))"
        case let (short?, _): return short
        default: return build
        }
    }

    static func running(_ bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }

    static func isAlive(_ processIdentifier: pid_t) -> Bool {
        kill(processIdentifier, 0) == 0 || errno == EPERM
    }

    static func frontmost() -> NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

    static func frontmostDescription() -> String? {
        frontmost().map { "\($0.bundleIdentifier ?? $0.localizedName ?? "?") pid \($0.processIdentifier)" }
    }

    /// Starts a separate instance of an App, as `open -n` does. The App
    /// decides whether it really runs separately; the caller checks.
    static func launchNewInstance(_ appURL: URL, arguments: [String], timeout: TimeInterval = 20) -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        return wait(timeout) { done in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in done(app) }
        }
    }

    /// Opens files with an App, starting it if needed and bringing it
    /// forward, as `open -a` does.
    static func open(_ files: [URL], with appURL: URL, timeout: TimeInterval = 20) -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        return wait(timeout) { done in
            NSWorkspace.shared.open(files, withApplicationAt: appURL, configuration: configuration) { app, _ in done(app) }
        }
    }

    /// Starts an App or brings the running one forward, opening nothing.
    static func activate(_ appURL: URL, timeout: TimeInterval = 20) -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        return wait(timeout) { done in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in done(app) }
        }
    }

    private static func wait(_ timeout: TimeInterval,
                             _ start: (@escaping (NSRunningApplication?) -> Void) -> Void) -> NSRunningApplication? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<NSRunningApplication?>(nil)
        start { app in
            box.value = app
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return box.value
    }

    /// Asks a process the probe started to quit, then kills it. Only ever
    /// used on the probe's own fixture and on separate instances running on
    /// the probe's own throwaway profiles.
    static func end(_ processIdentifier: pid_t, grace: TimeInterval = 4) -> String {
        guard isAlive(processIdentifier) else { return "exited" }
        if let app = NSRunningApplication(processIdentifier: processIdentifier) { app.terminate() }
        if poll(grace, { !isAlive(processIdentifier) }) { return "quit" }
        kill(processIdentifier, SIGKILL)
        return poll(3, { !isAlive(processIdentifier) }) ? "killed (it did not quit within \(Int(grace)) s)" : "still running"
    }

    /// Quits an App the probe started that the user was not running before.
    static func quitIfStartedByProbe(_ bundleID: String, wasRunning: Bool) -> String? {
        guard !wasRunning else { return nil }
        for app in running(bundleID) { app.terminate() }
        return poll(6, { running(bundleID).isEmpty }) ? "quit (the probe had started it)" : "left running"
    }

    @discardableResult
    static func poll(_ timeout: TimeInterval, interval: TimeInterval = 0.2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Every separate instance the probe started, so an interrupted run can
/// still end them.
enum OwnedProcesses {
    private static let pids = Box<Set<pid_t>>([])

    static func add(_ processIdentifier: pid_t) { pids.value.insert(processIdentifier) }
    static func remove(_ processIdentifier: pid_t) { pids.value.remove(processIdentifier) }

    static func killAll() {
        for pid in pids.value { kill(pid, SIGKILL) }
        pids.value = []
    }
}
