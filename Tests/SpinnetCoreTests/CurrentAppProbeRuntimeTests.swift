import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// `Tests/Fixtures/CurrentAppProbe.spinnetplugin`, a Current App-shaped
/// external Plugin, run the way its author runs it: through the public test
/// kit and the real helper. It identifies the App in front by an App Target,
/// separately from asking to close its window, quit or force quit it; the
/// Host offers Close and Quit only as the App's own menu does, resolves and
/// re-checks every exit, and confirms each one but a Close or graceful Quit
/// of the App in front when it accepted the request (#83).
final class CurrentAppProbeRuntimeTests: XCTestCase {
    static let package = NamespacesProbeFixture.fixtures.appendingPathComponent("CurrentAppProbe.spinnetplugin",
                                                                               isDirectory: true)
    private var helpers: [PluginTestHelper] = []

    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        helpers = []
    }

    private func helper() throws -> PluginTestHelper {
        let helper = try PluginTestHelper()
        helpers.append(helper)
        return helper
    }

    private let plugin = { try! PluginUnderTest(packageAt: CurrentAppProbeRuntimeTests.package) }()

    /// The probe as it opens over `apps`.
    private func opened(_ helper: PluginTestHelper, over apps: RecordedApps) throws -> PluginScriptAnswer {
        try helper.run(PluginTestInvocation("probe.current"), of: plugin,
                       answering: RecordedHostServices(apps: apps)).answer()
    }

    private func choose(_ action: String, after opened: PluginScriptAnswer) -> PluginTestInvocation {
        PluginTestInvocation("probe.current", event: .pageActionChosen(page: "current", action: action,
                                                                        values: .object([:]), selection: .object([:])),
                             state: opened.state, view: opened.pageJSON)
    }

    private func app(in state: JSONValue) -> [String: JSONValue]? {
        guard case .object(let members) = state, case .object(let app)? = members["app"] else { return nil }
        return app
    }

    // MARK: Identity

    func testItIdentifiesTheAppInFrontByAnOpaqueTargetAndNoProcessID() throws {
        let apps = RecordedApps(front: .textEdit, running: [.safari])
        let opened = try opened(try helper(), over: apps)
        let app = try XCTUnwrap(app(in: opened.state))
        XCTAssertEqual(app["name"], .string("TextEdit"))
        XCTAssertEqual(app["bundle_id"], .string("com.apple.TextEdit"))
        XCTAssertEqual(app["exits"], .array([.string("close"), .string("quit"), .string("force_quit")]))
        guard case .string(let target)? = app["target"] else { return XCTFail("No App Target") }
        XCTAssertTrue(AppTargets.isWellFormed(target))
        XCTAssertEqual(Set(app.keys), ["target", "name", "bundle_id", "exits"], "Nothing else about the App")

        // The Host's result follows the published schema.
        let validator = try JSONSchemaSubsetValidator(
            definition: "apps.frontmost.result",
            inSchemaAt: NamespacesProbeFixture.fixtures.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("PluginAPI/schemas/namespaces.schema.json"))
        XCTAssertEqual(validator.errors(for: .object(app)), [])
    }

    func testNothingIsInFrontWhileSpinnetIs() throws {
        let opened = try opened(try helper(), over: RecordedApps(front: .spinnet))
        XCTAssertNil(app(in: opened.state))
        guard case .object(let state) = opened.state else { return XCTFail() }
        XCTAssertEqual(state["app"], .null)
    }

    /// What the App's own menu offers: Finder has ⌘W but no ⌘Q, so the
    /// probe shows Close Window and Force Quit for it; the Dock, which is no
    /// regular App, gets nothing.
    func testTheExitsAreWhatTheAppsMenuOffersSoFinderHasNoQuit() throws {
        let helper = try helper()
        let finder = try opened(helper, over: RecordedApps(front: .finder))
        XCTAssertEqual(app(in: finder.state)?["exits"], .array([.string("close"), .string("force_quit")]))
        XCTAssertEqual(buttons(of: finder), ["Close Window", "Force Quit", "Quit App in Front"])
        XCTAssertEqual(app(in: try opened(helper, over: RecordedApps(front: .dock)).state)?["exits"], .array([]))

        let closed = RecordedApps(front: .textEdit)
        closed.offer([.quit], in: .textEdit)  // no window left to close
        XCTAssertEqual(app(in: try opened(helper, over: closed).state)?["exits"],
                       .array([.string("quit"), .string("force_quit")]))
    }

    /// Quit and Close need Accessibility, to read and press the App's menu;
    /// without it only Force Quit is offered, and a quit is refused.
    func testWithoutAccessibilityOnlyForceQuitIsOffered() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .textEdit)
        apps.isAccessibilityTrusted = false
        XCTAssertEqual(app(in: try opened(helper, over: apps).state)?["exits"], .array([.string("force_quit")]))

        let invocation = PluginTestInvocation("probe.quit_front")
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices())
        let refused = try XCTUnwrap(RecordedHostOperations(apps: apps).perform(run, of: plugin, for: invocation))
        XCTAssertEqual(refused.outcome, .refused(.systemPermissionDenied))
        XCTAssertTrue(refused.message?.contains("Accessibility") == true, "\(refused.message ?? "")")
        XCTAssertEqual(apps.exits, [])
    }

    private func buttons(of answer: PluginScriptAnswer) -> [String] {
        guard let page = answer.page else { return [] }
        return page.components.compactMap { component -> [PluginPageAction]? in
            if case .actions(_, let actions) = component { return actions }
            return nil
        }.flatMap { $0 }.map(\.title)
    }

    /// Close Window presses the App's own ⌘W item: its front window closes
    /// as it would for the user, asking nothing for the App in front, and
    /// the App keeps running.
    func testClosingTheAppInFrontClosesItsWindowWithoutAConfirmation() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .textEdit)
        let opened = try opened(helper, over: apps)
        let invocation = choose("close", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices(apps: apps))
        XCTAssertEqual(try run.answer().operation?.perform, "apps.close")
        XCTAssertEqual(try run.answer().operation?.closesView, true, "Its work done, the view closes, unless pinned")
        let performed = try XCTUnwrap(RecordedHostOperations(apps: apps).perform(run, of: plugin, for: invocation))
        XCTAssertNil(performed.confirmation)
        XCTAssertEqual(performed.outcome, .succeeded)
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .close)])
        XCTAssertTrue(apps.isRunning(.textEdit))
    }

    /// Its view closed on success, the probe is told without a view and
    /// answers with nothing, as a viewless invocation must.
    func testToldAfterItsViewClosedItAnswersNothing() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .textEdit)
        let opened = try opened(helper, over: apps)
        let told = PluginTestInvocation("probe.current",
                                        event: .operationFinished(id: "close", perform: "apps.close", outcome: .succeeded,
                                                                  viewClosed: true),
                                        state: opened.state)
        let answer = try helper.run(told, of: plugin, answering: RecordedHostServices(apps: apps)).answer()
        XCTAssertNil(answer.page)
        XCTAssertNil(answer.description)
        XCTAssertNil(answer.operation)
        XCTAssertFalse(answer.close)
    }

    // MARK: Quitting

    /// The App in front when the Host accepts the request is the one the
    /// user sees: quitting it gracefully, by its target or with none, asks
    /// nothing, as the App's own save prompts still apply.
    func testQuittingTheTargetInFrontRunsWithoutAConfirmation() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .textEdit, running: [.safari])
        let opened = try opened(helper, over: apps)
        let invocation = choose("quit", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices(apps: apps))
        let operations = RecordedHostOperations(apps: apps, confirmation: .declined)
        var asked = false
        operations.whileConfirming = { asked = true }
        let performed = try XCTUnwrap(operations.perform(run, of: plugin, for: invocation))
        XCTAssertNil(performed.confirmation)
        XCTAssertFalse(asked)
        XCTAssertEqual(performed.outcome, .succeeded)
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .quit)])
        XCTAssertTrue(apps.isRunning(.safari))
    }

    /// A target naming an App no longer in front when the Host accepts the
    /// request asks a Host Confirmation naming that App.
    func testQuitThroughATargetNotInFrontAsksAHostConfirmationNamingTheAppAndQuitsExactlyIt() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .textEdit, running: [.safari])
        let opened = try opened(helper, over: apps)
        let invocation = choose("quit", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices(apps: apps))
        XCTAssertEqual(run.requests, [], "Requesting an exit asks the Host for nothing during the invocation")

        // The user switched to Safari before the Host acted: the target
        // still names TextEdit, which the confirmation names.
        apps.bringToFront(.safari)
        let operations = RecordedHostOperations(apps: apps)
        let performed = try XCTUnwrap(operations.perform(run, of: plugin, for: invocation))
        XCTAssertEqual(performed.confirmation?.title, "Quit TextEdit?")
        XCTAssertTrue(performed.confirmation?.message.contains("Current App Probe") == true)
        XCTAssertEqual(performed.outcome, .succeeded)
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .quit)])
        XCTAssertTrue(apps.isRunning(.safari))

        // The outcome reaches the script without naming the App.
        let delivery = try XCTUnwrap(performed.delivery)
        XCTAssertFalse("\(delivery.json)".contains("TextEdit"))
        let finished = try helper.run(PluginTestInvocation("probe.current", event: delivery, state: try run.answer().state,
                                                           view: opened.pageJSON),
                                      of: plugin, answering: RecordedHostServices(apps: apps)).answer()
        guard case .object(let state) = finished.state else { return XCTFail() }
        XCTAssertEqual(state["outcomes"], .array([.array([.string("quit"), .string("succeeded"), .null])]))
    }

    func testForceQuitNamesTheLossAndQuitIsRefusedForAnAppWithoutCommandQ() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .textEdit)
        let opened = try opened(helper, over: apps)
        let invocation = choose("force", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices(apps: apps))
        let performed = try XCTUnwrap(RecordedHostOperations(apps: apps).perform(run, of: plugin, for: invocation))
        XCTAssertEqual(performed.confirmation?.title, "Force Quit TextEdit?")
        XCTAssertTrue(performed.confirmation?.message.contains("unsaved changes") == true)
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .textEdit, exit: .forceQuit)])

        // A Plugin cannot quit Finder, whose menu has no ⌘Q, even by
        // asking with its target.
        let finderApps = RecordedApps(front: .finder)
        let finder = try self.opened(helper, over: finderApps)
        var state = finder.state
        if case .object(var members) = state, case .object(var app)? = members["app"] {
            app["exits"] = .array([.string("close"), .string("quit"), .string("force_quit")])
            members["app"] = .object(app)
            state = .object(members)
        }
        let quit = PluginTestInvocation("probe.current", event: .pageActionChosen(
            page: "current", action: "quit", values: .object([:]), selection: .object([:])), state: state, view: finder.pageJSON)
        let refused = try XCTUnwrap(RecordedHostOperations(apps: finderApps).perform(
            helper.run(quit, of: plugin, answering: RecordedHostServices(apps: finderApps)), of: plugin, for: quit))
        XCTAssertEqual(refused.outcome, .refused(.targetProtected))
        XCTAssertNil(refused.confirmation, "Nothing is asked for an exit the App does not offer")
        XCTAssertEqual(finderApps.exits, [])
    }

    func testDecliningOrLeavingTheConfirmationUnansweredQuitsNothing() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .textEdit)
        let opened = try opened(helper, over: apps)
        let invocation = choose("force", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices(apps: apps))
        XCTAssertEqual(try RecordedHostOperations(apps: apps, confirmation: .declined)
            .perform(run, of: plugin, for: invocation)?.outcome, .declined)
        XCTAssertEqual(try RecordedHostOperations(apps: apps, confirmation: nil)
            .perform(run, of: plugin, for: invocation)?.outcome, .expired)
        XCTAssertEqual(apps.exits, [])
    }

    // MARK: Target exit and change

    /// A target outlives neither its App nor a relaunch reusing its process
    /// ID: the Host refuses rather than quit another App.
    func testATargetWhoseAppQuitOrRelaunchedIsRefused() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .textEdit)
        let opened = try opened(helper, over: apps)
        let invocation = choose("quit", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices(apps: apps))

        apps.relaunch(.textEdit)
        let relaunched = try XCTUnwrap(RecordedHostOperations(apps: apps).perform(run, of: plugin, for: invocation))
        XCTAssertEqual(relaunched.outcome, .refused(.noTarget))
        XCTAssertNil(relaunched.confirmation)

        apps.quit(.textEdit)
        XCTAssertEqual(try RecordedHostOperations(apps: apps).perform(run, of: plugin, for: invocation)?.outcome,
                       .refused(.noTarget))
        XCTAssertEqual(apps.exits, [])
    }

    /// What changes while the confirmation is on screen is checked again
    /// once the user confirms: nothing is retargeted.
    func testTheAppQuittingOrTheGrantGoingWhileConfirmingIsRefused() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .textEdit, running: [.safari])
        let opened = try opened(helper, over: apps)
        let invocation = choose("quit", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices(apps: apps))

        // Safari is in front when the Host accepts the request, so it asks.
        apps.bringToFront(.safari)
        let quitting = RecordedHostOperations(apps: apps)
        quitting.whileConfirming = { apps.quit(.textEdit) }
        let gone = try XCTUnwrap(quitting.perform(run, of: plugin, for: invocation))
        XCTAssertEqual(gone.outcome, .refused(.noTarget))
        XCTAssertTrue(gone.message?.contains("TextEdit") == true, "The Host's own message may name it")
        XCTAssertEqual(apps.exits, [], "Safari, now in front, is not quit")

        apps.bringToFront(.textEdit)
        let reopened = try self.opened(helper, over: apps)
        let again = choose("force", after: reopened)
        let second = helper.run(again, of: plugin, answering: RecordedHostServices(apps: apps))
        let revoking = RecordedHostOperations(apps: apps)
        revoking.whileConfirming = { revoking.deniedCapabilities.insert(.quitFrontmostApp) }
        XCTAssertEqual(try revoking.perform(second, of: plugin, for: again)?.outcome, .refused(.capabilityDenied))
        XCTAssertEqual(apps.exits, [])
    }

    // MARK: Separate authority

    func testQuittingTheAppInFrontNeedsNoIdentityRead() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .safari)
        let invocation = PluginTestInvocation("probe.quit_front")
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices())
        XCTAssertEqual(run.requests, [])
        XCTAssertEqual(try run.answer().operation, RequestedHostOperation(perform: "apps.quit", id: "front"))
        let performed = try XCTUnwrap(RecordedHostOperations(apps: apps).perform(run, of: plugin, for: invocation))
        XCTAssertNil(performed.confirmation, "A graceful quit of the App in front asks nothing")
        XCTAssertEqual(apps.exits, [RecordedApps.Exit(app: .safari, exit: .quit)])

        apps.bringToFront(.spinnet)
        XCTAssertEqual(try RecordedHostOperations(apps: apps).perform(run, of: plugin, for: invocation)?.outcome,
                       .refused(.noTarget), "Spinnet itself is never the App in front to quit")
    }

    func testIdentifyingAnAppGrantsNoExit() throws {
        let helper = try helper()
        let apps = RecordedApps(front: .textEdit)
        let invocation = PluginTestInvocation("probe.peek")
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices(apps: apps))
        XCTAssertEqual(try run.answer().toast, "Peeked at TextEdit")
        XCTAssertThrowsError(try RecordedHostOperations(apps: apps).perform(run, of: plugin, for: invocation)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.quitFrontmostApp))
        }
        XCTAssertEqual(apps.exits, [])
    }

    func testReadingTheAppInFrontNeedsItsCapability() throws {
        let helper = try helper()
        let invocation = PluginTestInvocation("probe.quit_front")
        let copy = try writeProbe(scripts: ["quit-front.js": "spinnet.apps.frontmost();"])
        let run = helper.run(invocation, of: try PluginUnderTest(packageAt: copy),
                             answering: RecordedHostServices(apps: RecordedApps()))
        XCTAssertThrowsError(try run.answer()) { error in
            XCTAssertTrue("\(error)".contains("read_frontmost_app"), "\(error)")
        }
    }

    /// A page action performs the same request, Quit App in Front by its
    /// title, which the Host performs like any other.
    func testThePageActionQuitsTheAppInFront() throws {
        let opened = try opened(try helper(), over: RecordedApps())
        let page = try XCTUnwrap(opened.page)
        let actions = page.components.compactMap { component -> [PluginPageAction]? in
            if case .actions(_, let actions) = component { return actions }
            return nil
        }.flatMap { $0 }
        let performed = actions.compactMap { action -> (String, RequestedHostOperation)? in
            if case .perform(let operation) = action.kind { return (action.title, operation) }
            return nil
        }
        XCTAssertEqual(performed.map(\.0), ["Quit App in Front"])
        XCTAssertEqual(performed.first?.1, RequestedHostOperation(perform: "apps.quit", id: "quit-front", notify: true))
    }

    // MARK: Level 1

    func testALevelOneManifestMayNotDeclareTheCapabilities() throws {
        let copy = try writeProbe { $0["api_level"] = .number(1) }
        XCTAssertThrowsError(try PluginManifestLoader.load(packageAt: copy)) { error in
            XCTAssertTrue("\(error)".contains("Plugin API Level 2"), "\(error)")
        }
    }

    private func writeProbe(scripts: [String: String] = [:],
                            _ change: (inout [String: JSONValue]) -> Void = { _ in }) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("CurrentAppProbe.spinnetplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.package, to: root)
        guard case .object(var manifest) = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json"))) else {
            throw ConfigurationError.malformedValue("The probe's manifest is not an object")
        }
        change(&manifest)
        try JSONEncoder().encode(JSONValue.object(manifest)).write(to: root.appendingPathComponent("manifest.json"))
        for (name, source) in scripts { try Data(source.utf8).write(to: root.appendingPathComponent(name)) }
        return root
    }
}
