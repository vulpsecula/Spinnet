import AppKit
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

/// The desktop seam of `apps.frontmost` and `apps.quit` (#83), with fake
/// running applications in place of `NSWorkspace`: the App in front, kept
/// current by the main thread so any thread reads it, its identity by
/// process ID, bundle identifier and launch date, an exit performed only on
/// the application confirmed, never on another that reused its process ID,
/// and each App that quits told to the App Targets.
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

        init(_ pid: pid_t, _ bundle: String?, launched: TimeInterval?, name: String?) {
            processIdentifier = pid
            bundleIdentifier = bundle
            launchDate = launched.map(Date.init(timeIntervalSince1970:))
            localizedName = name
        }

        func terminate() -> Bool { terminations.append("quit"); return accepts }
        func forceTerminate() -> Bool { terminations.append("force"); return accepts }
    }

    private var front: FakeApplication?
    private var byPID: [pid_t: FakeApplication] = [:]
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
            }))
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
    /// front the main thread last saw, so it never waits on the main thread,
    /// which may itself be waiting.
    func testAnyThreadReadsTheAppInFrontWithoutWaitingOnTheMainThread() throws {
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
        front = safari
        activated()
        XCTAssertEqual(readOffMain()?.objectValue?["name"], .string("Safari"))
        XCTAssertEqual(offMainReads, 0)
    }

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

    func testAnApplicationWithoutALaunchDateIsNeitherNamedNorFound() {
        let tool = FakeApplication(44, nil, launched: nil, name: "Tool")
        run(tool)
        front = tool
        let desktop = desktop()
        XCTAssertEqual(AppTargets().identifyFrontmost(of: desktop, for: PluginID("p")), .null)
        XCTAssertNil(desktop.facts(of: DesktopRunningApps.identity(of: tool)))
        XCTAssertFalse(desktop.perform(.quit, on: DesktopRunningApps.identity(of: tool)))
        XCTAssertEqual(tool.terminations, [])
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

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }
}
