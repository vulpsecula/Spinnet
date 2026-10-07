import AppKit
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

/// The desktop seam of `apps.frontmost` and `apps.quit` (#83), with fake
/// running applications in place of `NSWorkspace`: the App in front, its
/// identity by process ID, bundle identifier and launch date, and an exit
/// performed only on the application confirmed, never on another that
/// reused its process ID.
final class DesktopRunningAppsTests: XCTestCase {
    private final class FakeApplication: RunningApplication {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let launchDate: Date?
        let localizedName: String?
        var activationPolicy: NSApplication.ActivationPolicy = .regular
        var isTerminated = false
        var accepts = true
        private(set) var terminations: [String] = []

        init(_ pid: pid_t, _ bundle: String?, launched: TimeInterval, name: String?) {
            processIdentifier = pid
            bundleIdentifier = bundle
            launchDate = Date(timeIntervalSince1970: launched)
            localizedName = name
        }

        func terminate() -> Bool { terminations.append("quit"); return accepts }
        func forceTerminate() -> Bool { terminations.append("force"); return accepts }
    }

    private var front: FakeApplication?
    private var byPID: [pid_t: FakeApplication] = [:]

    private func desktop() -> DesktopRunningApps {
        DesktopRunningApps(environment: .init(frontmost: { [unowned self] in front },
                                              application: { [unowned self] in byPID[$0] },
                                              ownProcessIdentifier: 7))
    }

    private func run(_ app: FakeApplication) { byPID[app.processIdentifier] = app }

    func testTheAppInFrontIsReadWithItsIdentity() throws {
        let textEdit = FakeApplication(42, "com.apple.TextEdit", launched: 1, name: "TextEdit")
        run(textEdit)
        front = textEdit
        let facts = try XCTUnwrap(desktop().frontmost())
        XCTAssertEqual(facts.app, InsertionTargetApp(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit",
                                                     launchDate: Date(timeIntervalSince1970: 1), name: "TextEdit"))
        XCTAssertTrue(facts.isRegular)

        textEdit.activationPolicy = .accessory
        XCTAssertEqual(desktop().frontmost()?.isRegular, false)
        front = nil
        XCTAssertNil(desktop().frontmost())
    }

    func testAnExitGoesOnlyToTheSameApplication() throws {
        let original = FakeApplication(42, "com.apple.TextEdit", launched: 1, name: "TextEdit")
        run(original)
        let identity = DesktopRunningApps.identity(of: original)
        XCTAssertTrue(desktop().perform(.quit, on: identity))
        XCTAssertEqual(original.terminations, ["quit"])

        // TextEdit quit and another application now has process ID 42.
        let reused = FakeApplication(42, "com.example.other", launched: 9, name: "Other")
        run(reused)
        XCTAssertNil(desktop().facts(of: identity))
        XCTAssertFalse(desktop().perform(.forceQuit, on: identity))
        XCTAssertEqual(reused.terminations, [], "A reused process ID is never the confirmed App")

        // The same App relaunched is another App too.
        let relaunched = FakeApplication(42, "com.apple.TextEdit", launched: 5, name: "TextEdit")
        run(relaunched)
        XCTAssertFalse(desktop().perform(.forceQuit, on: identity))
        XCTAssertEqual(relaunched.terminations, [])

        let terminated = FakeApplication(43, "com.apple.Safari", launched: 2, name: "Safari")
        terminated.isTerminated = true
        run(terminated)
        XCTAssertNil(desktop().facts(of: DesktopRunningApps.identity(of: terminated)))
    }

    func testAForceQuitIsAForcedTerminationAndARefusedOneFails() {
        let app = FakeApplication(44, "com.example.hung", launched: 3, name: "Hung")
        run(app)
        XCTAssertTrue(desktop().perform(.forceQuit, on: DesktopRunningApps.identity(of: app)))
        XCTAssertEqual(app.terminations, ["force"])
        app.accepts = false
        XCTAssertFalse(desktop().perform(.quit, on: DesktopRunningApps.identity(of: app)))
    }

    /// The Host's App Targets over the desktop: Spinnet in front is no App.
    func testSpinnetInFrontIdentifiesNothing() {
        let spinnet = FakeApplication(7, "com.vulpsecula.Spinnet", launched: 1, name: "Spinnet")
        run(spinnet)
        front = spinnet
        XCTAssertEqual(AppTargets().identifyFrontmost(of: desktop(), for: PluginID("p")), .null)
    }
}
