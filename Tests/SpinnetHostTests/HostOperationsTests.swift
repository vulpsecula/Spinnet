import AppKit
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

/// The Host's side of Candidate Contract `host_operations` r1 (ADR 0018):
/// the insertion target it shows and keeps current, the insertion that goes
/// only to the App it showed, and the performer that checks authority at
/// commit and again at execution. A fake desktop stands in for macOS, so no
/// real App is touched.
final class HostOperationsTests: XCTestCase {
    private var desktop: FakeDesktop!
    private var apps: FakeApps!
    private var tracker: InsertionTargetTracker!
    private var inserter: TargetedTextInserter!

    override func setUp() {
        desktop = FakeDesktop()
        apps = FakeApps(desktop: desktop)
        desktop.frontmost = 42
        tracker = InsertionTargetTracker(environment: apps.environment)
        inserter = TargetedTextInserter(tracker: tracker, inserter: HostTextInserter(environment: desktop.environment))
    }

    private func insert(_ text: String = "😀", shown: InsertionTargetCapture,
                        naming: Bool = true) -> InsertionFailure?? {
        var outcome: InsertionFailure??
        inserter.insert(text, shown: shown, naming: naming) { outcome = .some($0) }
        return outcome
    }

    // MARK: - The target the Host shows

    func testTheTargetFollowsTheAppInFrontAndIsNoAppWhileSpinnetIs() {
        XCTAssertEqual(tracker.current?.name, "TextEdit")
        desktop.frontmost = 99
        apps.activate()
        XCTAssertEqual(tracker.current?.name, "Notes")
        desktop.frontmost = desktop.ownProcess
        apps.activate()
        XCTAssertNil(tracker.current, "Spinnet in front is shown as no App")
        desktop.frontmost = nil
        apps.activate()
        XCTAssertNil(tracker.current)
    }

    /// A gesture captures the App shown and, where Accessibility exposes
    /// one, the element focused in it.
    func testAGestureCapturesTheAppShownAndItsFocusedElement() {
        apps.focus[42] = "field 1"
        XCTAssertEqual(tracker.capture(), .shown(app: apps.textEdit, focus: "field 1"))
        apps.focus[42] = nil
        XCTAssertEqual(tracker.capture(), .shown(app: apps.textEdit, focus: nil))
        desktop.frontmost = desktop.ownProcess
        apps.activate()
        XCTAssertEqual(tracker.capture(), .shown(app: nil, focus: nil))
    }

    // MARK: - Inserting into the App shown

    func testTextGoesIntoTheAppShownWhenItIsStillInFront() {
        XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: nil)), .some(nil))
        XCTAssertEqual(desktop.posted.map(\.pid), [42])
        XCTAssertEqual(desktop.activated, [42])
    }

    /// Scenario 02: another App in front refuses without typing, names both
    /// for the user, and the target the Host shows follows the App in front.
    func testAnotherAppInFrontRefusesAndTheTargetFollowsIt() {
        desktop.frontmost = 99
        XCTAssertEqual(tracker.current?.name, "TextEdit", "The activation is not yet processed")
        XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: nil)),
                       .some(InsertionFailure(.targetChanged, message: "Spinnet showed TextEdit, but Notes is in front. Nothing was inserted.")))
        XCTAssertEqual(desktop.posted.count, 0)
        XCTAssertEqual(desktop.activated, [])
        XCTAssertEqual(tracker.current?.name, "Notes", "The hint updates")
    }

    /// The same process ID under another launch is another App.
    func testAReusedProcessIDIsNotTheAppShown() {
        let earlier = InsertionTargetApp(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit",
                                         launchDate: Date(timeIntervalSince1970: 0), name: "TextEdit")
        XCTAssertEqual(insert(shown: .shown(app: earlier, focus: nil))??.reason, .noTarget,
                       "The App shown is no longer running")
        XCTAssertEqual(desktop.posted.count, 0)
    }

    func testTheAppShownHavingQuitRefusesWithNoTarget() {
        desktop.frontmost = 99
        apps.quit(42)
        XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: nil)),
                       .some(InsertionFailure(.noTarget, message: "TextEdit has quit. Nothing was inserted.")))
    }

    func testSpinnetOrNoAppInFrontRefusesWithNoTarget() {
        for front in [desktop.ownProcess, nil] {
            desktop.frontmost = front
            XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: nil))??.reason, .noTarget)
        }
        XCTAssertEqual(desktop.posted.count, 0)
    }

    /// The Host showed no App, so an App in front now was not what the user saw.
    func testNoAppShownRefusesWhateverIsInFrontNow() {
        XCTAssertEqual(insert(shown: .shown(app: nil, focus: nil))??.reason, .targetChanged)
        XCTAssertEqual(desktop.posted.count, 0)
    }

    func testNothingShownRefusesWithTargetNotShown() {
        XCTAssertEqual(insert(shown: .notShown), .some(.notShown))
        XCTAssertEqual(desktop.activated, [])
    }

    /// Scenario 14: where Accessibility exposed the focused element at the
    /// gesture, focus moving to another element of the App refuses; where it
    /// exposed none, as in many web and Electron Apps, the App alone is
    /// compared (#69).
    func testFocusMovingInsideTheAppRefusesOnlyWhereTheElementWasExposed() {
        apps.focus[42] = "field 2"
        XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: "field 1")),
                       .some(InsertionFailure(.targetChanged, message: "Focus moved to another field of TextEdit. Nothing was inserted.")))
        apps.focus[42] = nil
        XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: "field 1"))??.reason, .targetChanged,
                       "The element shown at the gesture is no longer focused")
        XCTAssertEqual(desktop.posted.count, 0)

        apps.focus[42] = "field 1"
        XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: "field 1")), .some(nil), "Focus did not move")
        apps.focus[42] = "anything"
        XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: nil)), .some(nil),
                       "Nothing was exposed at the gesture, so the App alone is compared")
        XCTAssertEqual(desktop.posted.count, 2)
    }

    func testTheInserterFailuresBecomeReasons() {
        desktop.secure = true
        XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: nil)),
                       .some(InsertionFailure(.secureInput, message: "The focused field is a password field. Nothing was inserted.")))
        desktop.secure = false
        desktop.loseFrontAfterPosts = 1
        XCTAssertEqual(insert(String(repeating: "a", count: 50), shown: .shown(app: apps.textEdit, focus: nil)),
                       .some(InsertionFailure(.targetChanged, refused: false,
                                              message: "TextEdit left the front while the text was typed. Only part of it was inserted.")))
        desktop.frontmost = 42
        desktop.loseFrontAfterPosts = .max
        desktop.trusted = false
        XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: nil))??.reason, .systemPermissionDenied)
    }

    func testAnAppThatDoesNotComeForwardFailsAsUnresponsive() {
        desktop.frontmost = 42
        desktop.keyboardHeldPolls = .max
        XCTAssertEqual(insert(shown: .shown(app: apps.textEdit, focus: nil)),
                       .some(InsertionFailure(.targetUnresponsive, refused: false,
                                              message: "TextEdit did not come to the front. Nothing was inserted.")))
    }

    /// A synchronous call fails the invocation with the candidate's own
    /// category, in words that name no App, since they reach the helper.
    func testTheSynchronousPathThrowsWithoutNamingTheApp() throws {
        desktop.frontmost = 99
        let thrown = expectation(description: "thrown")
        let shown = InsertionTargetCapture.shown(app: apps.textEdit, focus: nil)
        let inserter: TargetedTextInserter = self.inserter
        var error: Error?
        DispatchQueue.global().async {
            do { try inserter.insertAndWait("x", shown: shown) } catch let failure { error = failure }
            thrown.fulfill()
        }
        wait(for: [thrown], timeout: 5)
        XCTAssertEqual(error as? PluginHostServiceError, .insertion(.changedWithoutNames))
        XCTAssertEqual((error as? PluginHostServiceError)?.runtimeFailureCategory, .insertionTargetChanged)
        XCTAssertFalse("\(String(describing: error))".contains("TextEdit") || "\(String(describing: error))".contains("Notes"))
        XCTAssertThrowsError(try inserter.insertAndWait("x", shown: .notShown), "Not from the main thread")
        for failure in [insert(shown: .shown(app: apps.textEdit, focus: nil), naming: false),
                        insert(shown: .shown(app: nil, focus: nil), naming: false)] {
            let message = failure??.message ?? ""
            XCTAssertFalse(message.contains("TextEdit") || message.contains("Notes"), message)
        }
    }

    // MARK: - The performer

    private func performer(grants: PluginCapabilityGrantStore, registry: PluginRegistry,
                           copied: @escaping (String) -> Void = { _ in },
                           settings: @escaping (PluginID) -> Void = { _ in },
                           accessibility: Bool = true) -> HostOperationsPerformer {
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in accessibility },
                                                        selectedTextProvider: { _ in "" },
                                                        clipboardWriter: copied)
        return HostOperationsPerformer(registry: registry, broker: { broker }, inserter: inserter,
                                       openPluginSettings: settings)
    }

    private func probe() throws -> (PluginRegistry, PluginCapabilityGrantStore, ActionConfiguration) {
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        let manifest = try registry.register(packageAt: Self.probePackage)
        for capability in manifest.capabilities {
            grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: capability,
                               scope: manifest.scope(for: capability))
        }
        let command = try XCTUnwrap(manifest.commands.first { $0.id == CommandID("probe.pick") })
        return (registry, grants, try ActionConfiguration(id: ActionID("pick"), pluginID: manifest.id, command: command,
                                                          input: .null))
    }

    static let probePackage = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/OperationsProbe.spinnetplugin", isDirectory: true)

    private func perform(_ performer: HostOperationsPerformer, _ operation: RequestedHostOperation,
                         for action: ActionConfiguration, target: InsertionTargetCapture = .notShown) -> HostOperationResult? {
        let done = expectation(description: operation.perform)
        var result: HostOperationResult?
        performer.perform(operation, for: action, target: target,
                          accepted: performer.accept(operation, for: action)) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    /// Authority is the requesting Action's, checked through the broker at
    /// commit and again at execution.
    func testTheBrokerAuthorizesARequestAtCommitAndAgainAtExecution() throws {
        let (registry, grants, action) = try probe()
        var copied: [String] = []
        let performer = performer(grants: grants, registry: registry, copied: { copied.append($0) })
        let copy = RequestedHostOperation(perform: "clipboard.write", input: .string("♥"))

        XCTAssertNoThrow(try performer.authorize(copy, for: action))
        XCTAssertEqual(perform(performer, copy, for: action), HostOperationResult(.succeeded))
        XCTAssertEqual(copied, ["♥"])

        let manifest = try XCTUnwrap(registry.package(for: action.pluginID)?.manifest)
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version, capability: .writeClipboard)
        XCTAssertThrowsError(try performer.authorize(copy, for: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.writeClipboard))
        }
        XCTAssertEqual(perform(performer, copy, for: action)?.outcome, .refused(.capabilityDenied),
                       "Revoked between commit and execution")
        XCTAssertEqual(copied, ["♥"])

        let undeclared = RequestedHostOperation(perform: "open.url", input: .string("https://example.com"))
        XCTAssertThrowsError(try performer.authorize(undeclared, for: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.openURL))
        }
    }

    func testAnInsertionIsRefusedAtExecutionWithoutAccessibility() throws {
        let (registry, grants, action) = try probe()
        let performer = performer(grants: grants, registry: registry, accessibility: false)
        let insert = RequestedHostOperation(perform: "selection.replace", input: .string("x"))
        XCTAssertThrowsError(try performer.authorize(insert, for: action))
        XCTAssertEqual(perform(performer, insert, for: action, target: .shown(app: apps.textEdit, focus: nil))?.outcome,
                       .refused(.systemPermissionDenied))
        XCTAssertEqual(desktop.posted.count, 0)
    }

    /// A Plugin removed or disabled after commit refuses its request.
    func testARemovedPluginsRequestIsRefusedAsUnavailable() throws {
        let (registry, grants, action) = try probe()
        let performer = performer(grants: grants, registry: registry)
        registry.unregister(action.pluginID)
        XCTAssertEqual(perform(performer, RequestedHostOperation(perform: "clipboard.write", input: .string("x")),
                               for: action)?.outcome, .refused(.commandUnavailable))
    }

    /// The requested insertion goes through the same targeted path, so
    /// every way of inserting agrees on the App in front.
    func testARequestedInsertionUsesTheTargetShownAtTheGesture() throws {
        let (registry, grants, action) = try probe()
        let performer = performer(grants: grants, registry: registry)
        let insert = RequestedHostOperation(perform: "selection.replace", input: .object(["text": .string("★")]))
        XCTAssertEqual(perform(performer, insert, for: action, target: .notShown)?.outcome, .refused(.targetNotShown))
        desktop.frontmost = 99
        XCTAssertEqual(perform(performer, insert, for: action, target: .shown(app: apps.textEdit, focus: nil))?.outcome,
                       .refused(.targetChanged))
        XCTAssertEqual(perform(performer, insert, for: action, target: .shown(app: apps.notes, focus: nil)),
                       HostOperationResult(.succeeded))
        XCTAssertEqual(desktop.posted.map(\.pid), [99])
    }

    /// `apps.quit`'s input is read when its answer commits; should the Host
    /// fail to read it when the operation starts, it says so rather than
    /// that it cannot quit Apps.
    func testAQuitWhoseInputTheHostCannotReadSaysSo() throws {
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        let manifest = try registry.register(packageAt: Self.probePackage.deletingLastPathComponent()
            .appendingPathComponent("CurrentAppProbe.spinnetplugin", isDirectory: true))
        for capability in manifest.capabilities {
            grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: capability,
                               scope: manifest.scope(for: capability))
        }
        let command = try XCTUnwrap(manifest.commands.first { $0.id == CommandID("probe.quit_front") })
        let action = try ActionConfiguration(id: ActionID("quit"), pluginID: manifest.id, command: command, input: .null)
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
                                                        selectedTextProvider: { _ in "" }, clipboardWriter: { _ in })
        let desktop = DesktopRunningApps(environment: .init(frontmost: { nil }, application: { _ in nil },
                                                            ownProcessIdentifier: 1, observe: { _, _ in NSObject() },
                                                            isAccessibilityTrusted: { true }, menuItems: { _ in [] }))
        let exits = AppExitPerformer(apps: desktop, targets: AppTargets(), confirmations: HostConfirmationPanel(),
                                     schedule: { _, _ in })
        let performer = HostOperationsPerformer(registry: registry, broker: { broker }, inserter: inserter, exits: exits,
                                                openPluginSettings: { _ in })

        let unread = RequestedHostOperation(perform: "apps.quit", input: .string("frontmost"))
        let result = try XCTUnwrap(perform(performer, unread, for: action))
        XCTAssertEqual(result.outcome, .refused(.hostServiceFailed))
        XCTAssertNotEqual(result.message, "This Host cannot close or quit Apps")
        XCTAssertTrue(result.message?.contains("apps.quit's input") == true, result.message ?? "")
    }

    func testShowingPluginSettingsNeedsOnlyThePluginsOwnCommand() throws {
        let (registry, grants, action) = try probe()
        var shown: [PluginID] = []
        let performer = performer(grants: grants, registry: registry, settings: { shown.append($0) })
        let settings = RequestedHostOperation(perform: "host.showPluginSettings")
        XCTAssertNoThrow(try performer.authorize(settings, for: action))
        XCTAssertEqual(perform(performer, settings, for: action), HostOperationResult(.succeeded))
        XCTAssertEqual(shown, [action.pluginID])
    }
}

/// The Apps the fake desktop runs, as the tracker sees them.
final class FakeApps {
    let desktop: FakeDesktop
    let mail = InsertionTargetApp(processIdentifier: 7, bundleIdentifier: "com.apple.mail",
                                  launchDate: Date(timeIntervalSince1970: 7), name: "Mail")
    let textEdit = InsertionTargetApp(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit",
                                      launchDate: Date(timeIntervalSince1970: 42), name: "TextEdit")
    let notes = InsertionTargetApp(processIdentifier: 99, bundleIdentifier: "com.apple.Notes",
                                   launchDate: Date(timeIntervalSince1970: 99), name: "Notes")
    /// The element focused in each App, where Accessibility exposes one.
    var focus: [pid_t: AnyHashable] = [:]
    private var activations: [() -> Void] = []

    init(desktop: FakeDesktop) { self.desktop = desktop }

    var apps: [InsertionTargetApp] { [mail, textEdit, notes] }

    /// Sends the activation notification for whatever is in front now.
    func activate() { activations.forEach { $0() } }

    func quit(_ processIdentifier: pid_t) { desktop.running.remove(processIdentifier) }

    var environment: InsertionTargetTracker.Environment {
        InsertionTargetTracker.Environment(
            frontmost: { [unowned self] in
                guard let front = desktop.frontmost else { return nil }
                if front == desktop.ownProcess {
                    return InsertionTargetApp(processIdentifier: front, bundleIdentifier: "com.vulpsecula.Spinnet",
                                              launchDate: nil, name: "Spinnet")
                }
                return apps.first { $0.processIdentifier == front }
            },
            ownProcessIdentifier: desktop.ownProcess,
            focusedElement: { [unowned self] in focus[$0] },
            isRunning: { [unowned self] app in
                desktop.running.contains(app.processIdentifier) && apps.contains { $0 == app }
            },
            observeActivation: { [unowned self] changed in
                activations.append(changed)
                return NSObject()
            }
        )
    }
}
