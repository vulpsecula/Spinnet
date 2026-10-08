import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// `apps.quit` in View Sessions (#83): a graceful quit of the App in front
/// when the Host accepted the request runs without a Host Confirmation;
/// Force Quit, and a quit through a target naming an App that was not in
/// front then, ask one. A confirmation holds the Plugin's operation slot,
/// closing the view cancels it without a word, a Plugin change or
/// revocation cancels it with one, it expires unanswered, and a late answer
/// after any of these does nothing. Without a target it quits the App in
/// front when the Host accepted the request, and one confirmation is on
/// screen at a time, whichever Plugin asked. Driven through the sessions'
/// seams with recorded Apps and a confirmation the test answers.
final class CurrentAppSessionTests: XCTestCase {
    private var clock: ManualClock!
    private var renderer: RecordingRenderer!
    private var runner: HeldEventRunner!
    private var apps: RecordedApps!
    private var confirmations: HeldConfirmations!
    private var exits: AppExitPerformer!
    private var performer: ExitOnlyPerformer!
    private var reported: [String] = []
    private var sessions: PluginViewSessions!
    private var revoked = false

    private static let pluginID = PluginID("com.example.current-app")

    override func setUp() {
        clock = ManualClock()
        renderer = RecordingRenderer()
        runner = HeldEventRunner()
        apps = RecordedApps(front: .textEdit, running: [.safari])
        confirmations = HeldConfirmations()
        exits = AppExitPerformer(apps: apps, targets: apps.targets, confirmations: confirmations, schedule: clock.schedule)
        reported = []
        revoked = false
        performer = ExitOnlyPerformer(exits: exits, authorize: { [unowned self] in
            if revoked { throw PluginHostServiceError.capabilityDenied(.quitFrontmostApp) }
        })
        sessions = PluginViewSessions(
            renderer: renderer, runEvent: runner.run, schedule: clock.schedule, showFeedback: { _ in },
            permitting: { _ in { PluginInterfaceContracts.levelTwoMembers.contains($0) } },
            operations: performer,
            reportOperation: { [unowned self] _, message in reported.append(message) }
        )
    }

    private func start() throws -> PluginViewSession {
        try sessions.actionAnswered(Self.action(), with: .object(["view": .object(["title": .string("Current")]),
                                                                  "state": .null]))
        return try XCTUnwrap(sessions.session(for: Self.pluginID))
    }

    /// Asks to force quit the App in front, which always asks a Host
    /// Confirmation, or to quit it gracefully, which does not.
    private func requestQuit(_ session: PluginViewSession, force: Bool = true, target: String? = nil,
                             notify: Bool = true) {
        session.send(.submitted(values: .null))
        var input: [String: JSONValue] = [:]
        if force { input["force"] = .bool(true) }
        if let target { input["target"] = .string(target) }
        let quit = RequestedHostOperation(perform: "apps.quit", input: input.isEmpty ? .null : .object(input),
                                          id: "quit", notify: notify)
        runner.runs.last!.finish(.succeeded(.object(["view": .object(["title": .string("Current")]), "state": .null,
                                                    "operation": quit.json])))
    }

    /// The App in front at acceptance is the App the user is looking at:
    /// quitting it gracefully needs no Host Confirmation, as its own save
    /// prompts still apply.
    func testAGracefulQuitOfTheAppInFrontRunsWithoutAConfirmation() throws {
        let session = try start()
        requestQuit(session, force: false)
        XCTAssertEqual(confirmations.shown, [])
        XCTAssertFalse(exits.isConfirming(Self.pluginID))
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .quit)])
        XCTAssertEqual(runner.runs.last?.delivery.event?.json, .object([
            "type": .string("operation_finished"), "operation": .string("quit"), "perform": .string("apps.quit"),
            "outcome": .string("succeeded")
        ]))
        XCTAssertEqual(reported, [])
    }

    /// A target naming the App in front at acceptance is that App: no
    /// confirmation, even when another App is in front by execution, and
    /// the App the target names is the one quit.
    func testAGracefulQuitThroughATargetNamingTheAppInFrontRunsWithoutAConfirmation() throws {
        let session = try start()
        let target = try XCTUnwrap(frontTarget())
        requestQuit(session, force: false, target: target)
        XCTAssertEqual(confirmations.shown, [])
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .quit)])
    }

    /// A target naming an App that is not in front when the Host accepts the
    /// request still asks, whichever App is in front by execution.
    func testAGracefulQuitThroughATargetNamingAnAppNotInFrontAsksAConfirmation() throws {
        let session = try start()
        let target = try XCTUnwrap(frontTarget())
        apps.bringToFront(.safari)
        requestQuit(session, force: false, target: target)
        XCTAssertEqual(confirmations.shown.map(\.title), ["Quit TextEdit?"])
        XCTAssertEqual(apps.exits, [])
        apps.bringToFront(.textEdit)
        confirmations.answer(.confirmed)
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .quit)])
    }

    private func frontTarget() -> String? {
        guard case .object(let app) = apps.targets.identifyFrontmost(of: apps, for: Self.pluginID),
              case .string(let target)? = app["target"] else { return nil }
        return target
    }

    func testConfirmingForceQuitsTheAppItNamedAndTellsTheScript() throws {
        let session = try start()
        requestQuit(session)
        XCTAssertEqual(confirmations.shown.map(\.title), ["Force Quit TextEdit?"])
        XCTAssertTrue(exits.isConfirming(Self.pluginID))

        // A gesture waits behind the confirmation.
        session.send(.submitted(values: .null))
        XCTAssertEqual(runner.runs.count, 1)

        apps.bringToFront(.safari)
        confirmations.answer(.confirmed)
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .forceQuit)])
        XCTAssertEqual(runner.runs[1].delivery.event?.json, .object([
            "type": .string("operation_finished"), "operation": .string("quit"), "perform": .string("apps.quit"),
            "outcome": .string("succeeded")
        ]))
        XCTAssertEqual(reported, [])
    }

    func testDecliningShowsNothingAndQuitsNothing() throws {
        let session = try start()
        requestQuit(session)
        confirmations.answer(.declined)
        XCTAssertEqual(apps.exits, [])
        XCTAssertNil(renderer.presentations.last?.error, "The user's own answer needs no word")
        XCTAssertEqual(runner.runs.last?.delivery.event?.json, .object([
            "type": .string("operation_finished"), "operation": .string("quit"), "perform": .string("apps.quit"),
            "outcome": .string("declined")
        ]))
    }

    /// As the published outcome table says: an operation whose view closed
    /// before it ran is `cancelled`, and the user's own close needs no word.
    func testClosingTheViewCancelsTheConfirmationSilentlyAndALateAnswerDoesNothing() throws {
        let session = try start()
        requestQuit(session)
        session.close()
        XCTAssertTrue(confirmations.dismissed)
        XCTAssertFalse(exits.isConfirming(Self.pluginID))
        XCTAssertEqual(performer.results, [HostOperationResult(.cancelled)])
        XCTAssertEqual(reported, [])
        XCTAssertEqual(runner.runs.count, 1, "A cancelled operation is not delivered after the view closed")

        confirmations.answer(.confirmed)
        XCTAssertEqual(apps.exits, [], "A late click does nothing")
    }

    func testAPluginChangeOrRevocationCancelsTheConfirmationAndSaysSo() throws {
        for reason in [PluginViewSessionEnd.pluginChanged, .capabilityRevoked] {
            setUp()
            let session = try start()
            requestQuit(session)
            sessions.end(pluginID: Self.pluginID, because: reason)
            XCTAssertTrue(session.isEnded)
            XCTAssertTrue(confirmations.dismissed)
            XCTAssertEqual(performer.results.map(\.outcome), [.cancelled])
            XCTAssertEqual(reported.count, 1, "\(reason)")
            XCTAssertTrue(reported.first?.hasPrefix("Nothing was quit") == true, "\(reported)")
            confirmations.answer(.confirmed)
            XCTAssertEqual(apps.exits, [])
        }
    }

    func testAnUnansweredConfirmationExpiresAfterSixtySeconds() throws {
        let session = try start()
        requestQuit(session)
        clock.advance(by: HostConfirmation.expiry - 1)
        XCTAssertTrue(exits.isConfirming(Self.pluginID))
        clock.advance(by: 1)
        XCTAssertFalse(exits.isConfirming(Self.pluginID))
        XCTAssertTrue(confirmations.dismissed)
        XCTAssertEqual(renderer.presentations.last?.error?.category, .cancelled)
        XCTAssertEqual(runner.runs.last?.delivery.event?.json, .object([
            "type": .string("operation_finished"), "operation": .string("quit"), "perform": .string("apps.quit"),
            "outcome": .string("expired")
        ]))
        confirmations.answer(.confirmed)
        XCTAssertEqual(apps.exits, [])
    }

    func testARevocationDuringTheConfirmationRefusesAfterTheUserConfirms() throws {
        let session = try start()
        requestQuit(session)
        XCTAssertEqual(confirmations.shown.map(\.title), ["Force Quit TextEdit?"])
        revoked = true
        confirmations.answer(.confirmed)
        XCTAssertEqual(apps.exits, [])
        XCTAssertEqual(renderer.presentations.last?.error?.category, .capabilityDenied)
    }

    /// #70's design: the working App is the one in front at the gesture,
    /// re-validated by identity at execution. A request that waits for the
    /// slot still quits the App in front when the Host accepted it, and,
    /// having been that App, without a confirmation.
    func testWithoutATargetItQuitsTheAppInFrontWhenTheHostAcceptedTheRequest() throws {
        let session = try start()
        requestQuit(session, notify: false)
        // Chosen while TextEdit is in front; it waits behind the first.
        session.perform(RequestedHostOperation(perform: "apps.quit", id: "again"), insertionTarget: .notShown)
        apps.bringToFront(.safari)
        confirmations.answer(.declined)
        XCTAssertEqual(confirmations.shown.map(\.title), ["Force Quit TextEdit?"])
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .quit)],
                       "Never the App in front when the operation started")
    }

    /// Nothing is ever retargeted: the App in front at acceptance that quit
    /// and relaunched before execution is another App.
    func testAGracefulQuitOfAnAppThatRelaunchedBeforeExecutionIsRefused() throws {
        let session = try start()
        requestQuit(session, notify: false)
        session.perform(RequestedHostOperation(perform: "apps.quit", id: "again"), insertionTarget: .notShown)
        apps.relaunch(.textEdit)
        confirmations.answer(.declined)
        XCTAssertEqual(performer.results.map(\.outcome), [.declined, .refused(.noTarget)])
        XCTAssertEqual(apps.exits, [])
    }

    // MARK: One confirmation at a time

    private func quitFront(for action: ActionConfiguration, named name: String,
                           _ completion: @escaping (HostOperationResult) -> Void) {
        let request = AppQuitRequest(force: true)
        exits.perform(request, accepted: exits.accept(request), for: action, pluginName: name, authorize: {},
                      completion: completion)
    }

    func testAnotherPluginsConfirmationWaitsItsTurnAndExpiresOnlyAfterItIsShown() throws {
        var first: [HostOperationResult] = [], second: [HostOperationResult] = []
        quitFront(for: try Self.action(), named: "Current App") { first.append($0) }
        apps.bringToFront(.safari)
        let other = try Self.action(of: PluginID("com.example.other"))
        quitFront(for: other, named: "Other") { second.append($0) }

        XCTAssertEqual(confirmations.shown.map(\.title), ["Force Quit TextEdit?"])
        XCTAssertFalse(confirmations.dismissed, "Another Plugin's request never removes the first one's")
        XCTAssertTrue(exits.isConfirming(other.pluginID))
        XCTAssertFalse(exits.isShowing(other.pluginID))

        clock.advance(by: 50)
        confirmations.answer(.declined)
        XCTAssertEqual(first, [HostOperationResult(.declined)])
        XCTAssertEqual(confirmations.shown.map(\.title), ["Force Quit TextEdit?", "Force Quit Safari?"])
        XCTAssertTrue(exits.isShowing(other.pluginID))

        clock.advance(by: HostConfirmation.expiry - 1)
        XCTAssertEqual(second, [], "Its 60 seconds run from when it was shown")
        clock.advance(by: 1)
        XCTAssertEqual(second.map(\.outcome), [.expired])
        XCTAssertEqual(first.count, 1)
    }

    func testAConfirmationWaitingItsTurnIsCancelledUnseenWhenItsOwnerEnds() throws {
        var first: [HostOperationResult] = [], second: [HostOperationResult] = []
        quitFront(for: try Self.action(), named: "Current App") { first.append($0) }
        let other = try Self.action(of: PluginID("com.example.other"))
        quitFront(for: other, named: "Other") { second.append($0) }

        exits.abandon(other.pluginID, because: .pluginChanged)
        XCTAssertEqual(second.map(\.outcome), [.cancelled])
        XCTAssertFalse(confirmations.dismissed, "The one on screen stays")
        confirmations.answer(.confirmed)
        XCTAssertEqual(first, [HostOperationResult(.succeeded)])
        XCTAssertEqual(confirmations.shown.count, 1, "The cancelled one was never shown")
    }

    private static func action(of pluginID: PluginID = pluginID) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("current"), pluginID: pluginID,
                                command: CommandDeclaration(id: CommandID("current"), title: "Current App",
                                                            execution: .javascript, script: "current.js"),
                                input: .null)
    }
}

/// Holds each Host Confirmation until the test answers the one shown last.
final class HeldConfirmations: HostConfirming {
    private(set) var shown: [HostConfirmation] = []
    private(set) var dismissed = false
    private var respond: ((HostConfirmationAnswer) -> Void)?

    func confirm(_ confirmation: HostConfirmation, for action: ActionConfiguration,
                 answer: @escaping (HostConfirmationAnswer) -> Void) -> () -> Void {
        shown.append(confirmation)
        respond = answer
        dismissed = false
        return { [weak self] in self?.dismissed = true }
    }

    func answer(_ answer: HostConfirmationAnswer) { respond?(answer) }
}

/// Performs only `apps.quit`, as the Host's performer does, with an
/// authority check the test controls, and records each result.
private final class ExitOnlyPerformer: HostOperationPerformer {
    let exits: AppExitPerformer
    let check: () throws -> Void
    private(set) var results: [HostOperationResult] = []

    init(exits: AppExitPerformer, authorize: @escaping () throws -> Void) {
        self.exits = exits
        self.check = authorize
    }

    func authorize(_ operation: RequestedHostOperation, for action: ActionConfiguration) throws { try check() }

    func accept(_ operation: RequestedHostOperation, for action: ActionConfiguration) -> AcceptedHostOperationTarget {
        exits.accept(try! AppQuitRequest(input: operation.input))
    }

    func perform(_ operation: RequestedHostOperation, for action: ActionConfiguration, target: InsertionTargetCapture,
                 accepted: AcceptedHostOperationTarget, completion: @escaping (HostOperationResult) -> Void) {
        exits.perform(try! AppQuitRequest(input: operation.input), accepted: accepted, for: action,
                      pluginName: "Current App", authorize: check) { [weak self] result in
            self?.results.append(result)
            completion(result)
        }
    }

    func abandon(_ pluginID: PluginID, because reason: PluginViewSessionEnd) {
        exits.abandon(pluginID, because: reason)
    }
}
