import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// `apps.quit` in View Sessions (#83): its Host Confirmation holds the
/// Plugin's operation slot, closing the view declines it without a word,
/// a Plugin change or revocation cancels it with one, it expires unanswered,
/// and a late answer after any of these does nothing. Driven through the
/// sessions' seams with recorded Apps and a confirmation the test answers.
final class CurrentAppSessionTests: XCTestCase {
    private var clock: ManualClock!
    private var renderer: RecordingRenderer!
    private var runner: HeldEventRunner!
    private var apps: RecordedApps!
    private var confirmations: HeldConfirmations!
    private var exits: AppExitPerformer!
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
        let performer = ExitOnlyPerformer(exits: exits, authorize: { [unowned self] in
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

    private func requestQuit(_ session: PluginViewSession, force: Bool = false, notify: Bool = true) {
        session.send(.submitted(values: .null))
        let quit = RequestedHostOperation(perform: "apps.quit", input: force ? .object(["force": .bool(true)]) : .null,
                                          id: "quit", notify: notify)
        runner.runs.last!.finish(.succeeded(.object(["view": .object(["title": .string("Current")]), "state": .null,
                                                    "operation": quit.json])))
    }

    func testConfirmingQuitsTheAppItNamedAndTellsTheScript() throws {
        let session = try start()
        requestQuit(session)
        XCTAssertEqual(confirmations.shown.map(\.title), ["Quit TextEdit?"])
        XCTAssertTrue(exits.isConfirming(Self.pluginID))

        // A gesture waits behind the confirmation.
        session.send(.submitted(values: .null))
        XCTAssertEqual(runner.runs.count, 1)

        apps.bringToFront(.safari)
        confirmations.answer(.confirmed)
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .quit)])
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

    func testClosingTheViewDeclinesTheConfirmationSilentlyAndALateAnswerDoesNothing() throws {
        let session = try start()
        requestQuit(session)
        session.close()
        XCTAssertTrue(confirmations.dismissed)
        XCTAssertFalse(exits.isConfirming(Self.pluginID))
        XCTAssertEqual(reported, [])
        XCTAssertEqual(runner.runs.count, 1, "A declined confirmation is not delivered after the view closed")

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
        requestQuit(session, force: true)
        XCTAssertEqual(confirmations.shown.map(\.title), ["Force Quit TextEdit?"])
        revoked = true
        confirmations.answer(.confirmed)
        XCTAssertEqual(apps.exits, [])
        XCTAssertEqual(renderer.presentations.last?.error?.category, .capabilityDenied)
    }

    private static func action() throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("current"), pluginID: pluginID,
                                command: CommandDeclaration(id: CommandID("current"), title: "Current App",
                                                            execution: .javascript, script: "current.js"),
                                input: .null)
    }
}

/// Holds each Host Confirmation until the test answers it.
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
/// authority check the test controls.
private final class ExitOnlyPerformer: HostOperationPerformer {
    let exits: AppExitPerformer
    let check: () throws -> Void

    init(exits: AppExitPerformer, authorize: @escaping () throws -> Void) {
        self.exits = exits
        self.check = authorize
    }

    func authorize(_ operation: RequestedHostOperation, for action: ActionConfiguration) throws { try check() }

    func perform(_ operation: RequestedHostOperation, for action: ActionConfiguration, target: InsertionTargetCapture,
                 completion: @escaping (HostOperationResult) -> Void) {
        exits.perform(try! AppQuitRequest(input: operation.input), for: action, pluginName: "Current App",
                      authorize: check, completion: completion)
    }

    func abandon(_ pluginID: PluginID, because reason: PluginViewSessionEnd) {
        exits.abandon(pluginID, because: reason)
    }
}
