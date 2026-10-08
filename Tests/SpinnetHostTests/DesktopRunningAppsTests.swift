import AppKit
import ApplicationServices
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

/// The desktop seam of `apps.frontmost`, `apps.quit` and `apps.close`
/// (#83), with fake running applications and fake menus in place of
/// `NSWorkspace` and Accessibility: the App in front, kept current by the
/// main thread so any thread reads it, its identity by process ID, bundle
/// identifier and launch date, Close and Quit found in the App's own menu
/// as an enabled ⌘W or ⌘Q item and performed by pressing it, Force Quit as
/// a forced termination, an exit performed only on the application
/// confirmed, never on another that reused its process ID, and each App
/// that quits told to the App Targets.
final class DesktopRunningAppsTests: XCTestCase {
    private final class FakeApplication: RunningApplication {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let launchDate: Date?
        let processStartDate: Date?
        let localizedName: String?
        var activationPolicy: NSApplication.ActivationPolicy = .regular
        var isTerminated = false
        var accepts = true
        /// Its top-level menus' items: by default an enabled ⌘W and ⌘Q.
        var menu: [(title: String, key: String?, modifiers: Int?, enabled: Bool)] = [
            ("About", nil, nil, true), ("Quit", "Q", 0, true), ("Close", "W", 0, true)
        ]
        /// What pressing an item answers.
        var press: DesktopRunningApps.MenuPress = .pressed
        /// Whether the menu answers at all.
        var answersMenu = true
        private(set) var terminations: [String] = []
        private(set) var pressed: [String] = []
        private(set) var menuReadsOnMain = 0

        init(_ pid: pid_t, _ bundle: String?, launched: TimeInterval?, started: TimeInterval? = nil, name: String?) {
            processIdentifier = pid
            bundleIdentifier = bundle
            launchDate = launched.map(Date.init(timeIntervalSince1970:))
            processStartDate = started.map(Date.init(timeIntervalSince1970:))
            localizedName = name
        }

        func forceTerminate() -> Bool { terminations.append("force"); return accepts }

        func menuItems() -> [DesktopRunningApps.MenuItem]? {
            if Thread.isMainThread { menuReadsOnMain += 1 }
            guard answersMenu else { return nil }
            return menu.map { item in
                DesktopRunningApps.MenuItem(commandCharacter: item.key, commandModifiers: item.modifiers,
                                            isEnabled: item.enabled) { [unowned self] in
                    pressed.append(item.title)
                    return press
                }
            }
        }
    }

    private var front: FakeApplication?
    private var byPID: [pid_t: FakeApplication] = [:]
    private var trusted = true
    private var activated: () -> Void = {}
    private var terminated: (RunningApplication) -> Void = { _ in }
    /// Reads of the App in front made off the main thread.
    private var offMainReads = 0

    private func desktop() -> DesktopRunningApps {
        DesktopRunningApps(environment: .init(
            frontmost: { [unowned self] in
                if !Thread.isMainThread { offMainReads += 1 }
                return front
            },
            application: { [unowned self] in byPID[$0] },
            ownProcessIdentifier: 7,
            observe: { [unowned self] activated, terminated in
                self.activated = activated
                self.terminated = terminated
                return NSObject()
            },
            isAccessibilityTrusted: { [unowned self] in trusted },
            menuItems: { [unowned self] in byPID[$0]?.menuItems() }))
    }

    private func run(_ app: FakeApplication) { byPID[app.processIdentifier] = app }

    func testTheAppInFrontIsReadWithItsIdentity() throws {
        let textEdit = FakeApplication(42, "com.apple.TextEdit", launched: 1, name: "TextEdit")
        run(textEdit)
        front = textEdit
        let facts = try XCTUnwrap(desktop().frontmost())
        XCTAssertEqual(facts.identity, RunningAppIdentity(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit",
                                                          launchDate: Date(timeIntervalSince1970: 1), name: "TextEdit"))
        XCTAssertTrue(facts.isRegular)

        textEdit.activationPolicy = .accessory
        XCTAssertEqual(desktop().frontmost()?.isRegular, false)
        front = nil
        XCTAssertNil(desktop().frontmost())
    }

    /// `apps.frontmost` runs on the broker's thread. It reads the App in
    /// front the main thread last saw, and that App's menu on its own
    /// thread, so it never waits on the main thread, which may itself be
    /// waiting.
    func testAnyThreadReadsTheAppInFrontAndItsMenuWithoutWaitingOnTheMainThread() throws {
        let textEdit = FakeApplication(42, "com.apple.TextEdit", launched: 1, name: "TextEdit")
        let safari = FakeApplication(43, "com.apple.Safari", launched: 2, name: "Safari")
        run(textEdit)
        run(safari)
        front = textEdit
        let desktop = desktop()
        let targets = AppTargets()

        func readOffMain() -> JSONValue? {
            let done = DispatchSemaphore(value: 0)
            var result: JSONValue?
            DispatchQueue.global().async {
                result = targets.identifyFrontmost(of: desktop, for: PluginID("p"))
                done.signal()
            }
            // The main thread blocks here, as it would waiting on the broker.
            XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
            return result
        }

        XCTAssertEqual(readOffMain()?.objectValue?["name"], .string("TextEdit"))
        XCTAssertEqual(readOffMain()?.objectValue?["exits"],
                       .array([.string("close"), .string("quit"), .string("force_quit")]))
        front = safari
        activated()
        XCTAssertEqual(readOffMain()?.objectValue?["name"], .string("Safari"))
        XCTAssertEqual(offMainReads, 0)
        XCTAssertEqual(textEdit.menuReadsOnMain + safari.menuReadsOnMain, 0)
    }

    // MARK: The App's own menu

    /// Quit is an enabled item whose shortcut is ⌘Q, Command alone; Close
    /// the same with ⌘W. Any other item, a disabled one, or ⇧⌘Q, ⌥⌘W or ⌃⌘Q
    /// is not it, whatever its title.
    func testQuitAndCloseAreTheEnabledCommandQAndCommandWItems() throws {
        let app = FakeApplication(42, "com.example.app", launched: 1, name: "App")
        run(app)
        let identity = DesktopRunningApps.identity(of: app)
        let desktop = desktop()
        XCTAssertEqual(try desktop.menuExits(of: identity), [.close, .quit])

        let shift = 1, option = 2, control = 4, noCommand = 8
        app.menu = [("Quit", "Q", shift, true), ("Quit", "Q", option, true), ("Close", "W", control, true),
                    ("Close", "W", noCommand, true), ("Quit", "Q", 0, false), ("Quit and Keep Windows", "Q", nil, true),
                    ("Quit", nil, nil, true)]
        XCTAssertEqual(try desktop.menuExits(of: identity), [])

        // Lowercase is the same key; the first enabled match is pressed.
        app.menu = [("Close All", "W", option, true), ("Close", "w", 0, false), ("Close Tab", "w", 0, true),
                    ("Close Window", "W", 0, true)]
        XCTAssertEqual(try desktop.menuExits(of: identity), [.close])
        XCTAssertEqual(try desktop.perform(.close, on: identity), .delivered)
        XCTAssertEqual(app.pressed, ["Close Tab"])
        XCTAssertEqual(try desktop.perform(.quit, on: identity), .notOffered)
        XCTAssertEqual(app.pressed, ["Close Tab"])
        XCTAssertEqual(app.terminations, [], "Quit is never a termination of the process")
    }

    /// Finder has no ⌘Q item, so it has no Quit, by what its menu says.
    func testAnAppWithoutCommandQHasNoQuitWhateverItIs() throws {
        let finder = FakeApplication(45, "com.apple.finder", launched: nil, started: 100, name: "Finder")
        finder.menu = [("About Finder", nil, nil, true), ("Close Window", "W", 0, true)]
        run(finder)
        front = finder
        XCTAssertEqual(AppTargets().identifyFrontmost(of: desktop(), for: PluginID("p")).objectValue?["exits"],
                       .array([.string("close"), .string("force_quit")]))
    }

    func testQuitPressesTheItemAndAPressWithoutReplyIsStillDelivered() throws {
        let app = FakeApplication(42, "com.apple.TextEdit", launched: 1, name: "TextEdit")
        run(app)
        let identity = DesktopRunningApps.identity(of: app)
        XCTAssertEqual(try desktop().perform(.quit, on: identity), .delivered)
        XCTAssertEqual(app.pressed, ["Quit"])

        // The App took the press but asked to save before answering.
        app.press = .noReply
        XCTAssertEqual(try desktop().perform(.quit, on: identity), .delivered)
        app.press = .failed
        XCTAssertEqual(try desktop().perform(.close, on: identity), .failed)
        app.answersMenu = false
        XCTAssertEqual(try desktop().menuExits(of: identity), [], "An App whose menu does not answer offers none")
        XCTAssertEqual(try desktop().perform(.quit, on: identity), .notOffered)
        XCTAssertEqual(app.terminations, [])
    }

    /// Without Accessibility the Host can neither read nor press a menu:
    /// Quit and Close are not offered and are refused, naming it; Force
    /// Quit does not need it.
    func testWithoutAccessibilityOnlyForceQuitIsOffered() throws {
        trusted = false
        let app = FakeApplication(42, "com.apple.TextEdit", launched: 1, name: "TextEdit")
        run(app)
        front = app
        let desktop = desktop()
        let identity = DesktopRunningApps.identity(of: app)
        XCTAssertEqual(AppTargets().identifyFrontmost(of: desktop, for: PluginID("p")).objectValue?["exits"],
                       .array([.string("force_quit")]))
        XCTAssertThrowsError(try desktop.menuExits(of: identity)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .systemPermissionDenied(.accessibility))
        }
        XCTAssertThrowsError(try desktop.perform(.quit, on: identity))
        XCTAssertEqual(app.pressed, [])
        XCTAssertEqual(try desktop.perform(.forceQuit, on: identity), .delivered)
        XCTAssertEqual(app.terminations, ["force"])
    }

    // MARK: Identity

    func testAnApplicationThatQuitsIsToldWithItsIdentityAndLeavesTheFront() {
        let textEdit = FakeApplication(42, "com.apple.TextEdit", launched: 1, name: "TextEdit")
        run(textEdit)
        front = textEdit
        let desktop = desktop()
        let targets = AppTargets()
        targets.forgetTerminatedApps(of: desktop)
        _ = targets.identifyFrontmost(of: desktop, for: PluginID("p"))
        XCTAssertEqual(targets.count(for: PluginID("p")), 1)

        textEdit.isTerminated = true
        front = nil
        terminated(textEdit)
        XCTAssertEqual(targets.count(for: PluginID("p")), 0)
        XCTAssertNil(desktop.frontmost())
    }

    /// Finder, started at login by the system rather than Launch Services,
    /// has no launch date; its process's start time identifies it instead,
    /// still never matching another process that reuses its ID.
    func testAnApplicationWithoutALaunchDateIsIdentifiedByItsProcessStart() throws {
        let finder = FakeApplication(45, "com.apple.finder", launched: nil, started: 100, name: "Finder")
        run(finder)
        front = finder
        let desktop = desktop()
        let identity = DesktopRunningApps.identity(of: finder)
        XCTAssertTrue(identity.isComplete)
        XCTAssertEqual(desktop.facts(of: identity)?.identity.name, "Finder")
        if case .null = AppTargets().identifyFrontmost(of: desktop, for: PluginID("p")) { XCTFail("Finder is not named") }

        let reused = FakeApplication(45, "com.apple.finder", launched: nil, started: 200, name: "Finder")
        run(reused)
        XCTAssertNil(desktop.facts(of: identity), "Another process with the same ID")
        XCTAssertEqual(try desktop.perform(.close, on: identity), .failed)
        XCTAssertEqual(try desktop.perform(.forceQuit, on: identity), .failed)
        XCTAssertEqual(reused.pressed, [])
        XCTAssertEqual(reused.terminations, [])
    }

    /// The live start time of a real process: this one, and Finder's.
    func testARealProcessHasAStartTime() throws {
        let own = try XCTUnwrap(DesktopRunningApps.processStartDate(of: getpid()))
        XCTAssertLessThan(own.timeIntervalSinceNow, 0)
        XCTAssertGreaterThan(own.timeIntervalSinceNow, -ProcessInfo.processInfo.systemUptime - 1)
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            XCTAssertNotNil(finder.processStartDate)
        }
    }

    func testAnApplicationWithoutALaunchDateOrStartIsNeitherNamedNorFound() throws {
        let tool = FakeApplication(44, nil, launched: nil, name: "Tool")
        run(tool)
        front = tool
        let desktop = desktop()
        XCTAssertEqual(AppTargets().identifyFrontmost(of: desktop, for: PluginID("p")), .null)
        XCTAssertNil(desktop.facts(of: DesktopRunningApps.identity(of: tool)))
        XCTAssertEqual(try desktop.perform(.quit, on: DesktopRunningApps.identity(of: tool)), .failed)
        XCTAssertEqual(tool.pressed, [])
    }

    func testAnExitGoesOnlyToTheSameApplication() throws {
        let original = FakeApplication(42, "com.apple.TextEdit", launched: 1, name: "TextEdit")
        run(original)
        let identity = DesktopRunningApps.identity(of: original)
        XCTAssertEqual(try desktop().perform(.quit, on: identity), .delivered)
        XCTAssertEqual(original.pressed, ["Quit"])

        // TextEdit quit and another application now has process ID 42.
        let reused = FakeApplication(42, "com.example.other", launched: 9, name: "Other")
        run(reused)
        XCTAssertNil(desktop().facts(of: identity))
        XCTAssertEqual(try desktop().perform(.forceQuit, on: identity), .failed)
        XCTAssertEqual(try desktop().perform(.quit, on: identity), .failed)
        XCTAssertEqual(reused.terminations, [], "A reused process ID is never the confirmed App")
        XCTAssertEqual(reused.pressed, [])

        // The same App relaunched is another App too.
        let relaunched = FakeApplication(42, "com.apple.TextEdit", launched: 5, name: "TextEdit")
        run(relaunched)
        XCTAssertEqual(try desktop().perform(.forceQuit, on: identity), .failed)
        XCTAssertEqual(relaunched.terminations, [])

        let terminated = FakeApplication(43, "com.apple.Safari", launched: 2, name: "Safari")
        terminated.isTerminated = true
        run(terminated)
        XCTAssertNil(desktop().facts(of: DesktopRunningApps.identity(of: terminated)))
    }

    func testAForceQuitIsAForcedTerminationAndARefusedOneFails() throws {
        let app = FakeApplication(44, "com.example.hung", launched: 3, name: "Hung")
        run(app)
        XCTAssertEqual(try desktop().perform(.forceQuit, on: DesktopRunningApps.identity(of: app)), .delivered)
        XCTAssertEqual(app.terminations, ["force"])
        app.accepts = false
        XCTAssertEqual(try desktop().perform(.forceQuit, on: DesktopRunningApps.identity(of: app)), .failed)
        XCTAssertEqual(app.pressed, [])
    }

    /// The Host's App Targets over the desktop: Spinnet in front is no App.
    func testSpinnetInFrontIdentifiesNothing() {
        let spinnet = FakeApplication(7, "com.vulpsecula.Spinnet", launched: 1, name: "Spinnet")
        run(spinnet)
        front = spinnet
        XCTAssertEqual(AppTargets().identifyFrontmost(of: desktop(), for: PluginID("p")), .null)
    }

    // MARK: The live menus

    /// Reads the real menus of the regular Apps running now through
    /// Accessibility and records how long each read takes, which bounds
    /// `apps.frontmost` and every Quit and Close. It needs this test
    /// process to be trusted for Accessibility; otherwise it is skipped,
    /// and the reading is measured by hand in the Host.
    func testTheLiveMenuReadingFindsQuitWithinItsBound() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("This process is not trusted for Accessibility, so no App's menu can be read")
        }
        let own = ProcessInfo.processInfo.processIdentifier
        var slowest: TimeInterval = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app.processIdentifier != own {
            let start = Date()
            let items = DesktopRunningApps.AccessibilityMenus.items(of: app.processIdentifier)
            let elapsed = Date().timeIntervalSince(start)
            slowest = max(slowest, elapsed)
            let keys = (items ?? []).filter { $0.isEnabled && $0.commandModifiers == 0 }
                .compactMap(\.commandCharacter).filter { ["Q", "W"].contains($0.uppercased()) }
            print("Menu of \(app.bundleIdentifier ?? "?"): \(items?.count ?? -1) items, ⌘\(keys.joined(separator: " ⌘")),"
                  + " \(Int(elapsed * 1000)) ms")
            XCTAssertLessThanOrEqual(elapsed, DesktopRunningApps.AccessibilityMenus.readingBound + 0.25,
                                     app.bundleIdentifier ?? "?")
        }
        print("Slowest menu reading: \(Int(slowest * 1000)) ms")
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }
}
