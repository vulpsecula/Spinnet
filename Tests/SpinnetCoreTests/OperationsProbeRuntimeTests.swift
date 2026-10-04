import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The Operations Probe run the way its author runs it: through the public
/// test kit and the real helper, against the Host this repository builds.
/// Its picker names where text goes, requests insertion and copying from
/// its gestures and hears the outcome; its stamp inserts without a view,
/// which the Host refuses; and declaring Level 1 alone leaves every Level 1
/// path as it was.
final class OperationsProbeRuntimeTests: XCTestCase {
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

    private let plugin = { try! PluginUnderTest(packageAt: OperationsProbeFixture.package) }()

    /// The picker as it opens: its view, which asks for the target line, and
    /// its state.
    private func opened(_ helper: PluginTestHelper) throws -> PluginScriptAnswer {
        try helper.run(PluginTestInvocation("probe.pick"), of: plugin, answering: RecordedHostServices()).answer()
    }

    private func submit(_ query: String, after opened: PluginScriptAnswer, view: JSONValue? = nil) -> PluginTestInvocation {
        PluginTestInvocation("probe.pick", event: .submitted(values: .object(["query": .string(query)])),
                             state: opened.state, view: view ?? opened.view)
    }

    // MARK: Requests

    func testReturnRequestsAnInsertionThatCommitsWithItsAnswer() throws {
        let helper = try helper()
        let opened = try opened(helper)
        let view = try PluginViewDescription(parsing: XCTUnwrap(opened.view), settingsFields: [],
                                             permits: PluginInterfaceContracts.host.permitting(plugin.manifest))
        XCTAssertTrue(view.showsInsertionTarget, "ui.view takes showsInsertionTarget under the candidate")

        let invocation = submit("star", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices())
        let answer = try run.answer()

        XCTAssertEqual(answer.operation, RequestedHostOperation(perform: "selection.replace", input: .object(["text": .string("★")]),
                                                                id: "insert", closesView: true, notify: true))
        XCTAssertEqual(answer.state, .object(["count": .number(1), "last": .null]))
        XCTAssertEqual(run.requests, [], "Requesting asks the Host for nothing during the invocation")

        let operations = RecordedHostOperations()
        let performed = try XCTUnwrap(operations.perform(run, of: plugin, for: invocation))
        XCTAssertEqual(performed.outcome, .succeeded)
        XCTAssertEqual(performed.delivery, .operationFinished(id: "insert", perform: "selection.replace", outcome: .succeeded))
    }

    /// With `notify`, the outcome reaches the script as `operation_finished`,
    /// which names the operation and the reason but never the App.
    func testTheOutcomeReachesTheScriptAsOperationFinished() throws {
        let helper = try helper()
        let opened = try opened(helper)
        let invocation = submit("heart", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices())
        let operations = RecordedHostOperations(["selection.replace": .refused(.targetChanged)])
        let delivery = try XCTUnwrap(operations.perform(run, of: plugin, for: invocation)?.delivery)

        let finished = helper.run(PluginTestInvocation("probe.pick", event: delivery, state: try run.answer().state),
                                  of: plugin, answering: RecordedHostServices())

        let answer = try finished.answer()
        XCTAssertEqual(answer.state, .object(["count": .number(1), "last": .array([
            .string("insert"), .string("selection.replace"), .string("refused"), .string("target_changed")
        ])]))
        XCTAssertNil(answer.operation)
    }

    /// An answer to `operation_finished`, or to typing, that requests an
    /// operation is the protocol violation the Host ends the session with.
    func testOnlyAnAnswerToAGestureMayRequest() throws {
        let source = URL(fileURLWithPath: try OperationsProbeFixture.write(scripts: ["pick.js": """
            spinnet.ui.request(spinnet.clipboard.write.operation("x"))
            """]).path)
        let plugin = try PluginUnderTest(packageAt: source)
        let helper = try helper()
        for event: PluginViewEvent in [.fieldChanged(field: "query", values: .null),
                                       .operationFinished(id: nil, perform: "clipboard.write", outcome: .succeeded)] {
            let run = helper.run(PluginTestInvocation("probe.pick", event: event), of: plugin, answering: RecordedHostServices())
            XCTAssertThrowsError(try run.answer(), "\(event)") {
                XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation(
                    "The script's answer to \(event.typeName) requests an operation; only an answer to a gesture may"))
            }
        }
        let gesture = helper.run(PluginTestInvocation("probe.pick", event: .actionChosen("go")), of: plugin,
                                 answering: RecordedHostServices())
        XCTAssertEqual(try gesture.answer().operation?.perform, "clipboard.write")
    }

    /// A request without a view: copying commits with its toast; inserting
    /// was preceded by no target the Host showed, so it is refused.
    func testRequestsWithoutAView() throws {
        let helper = try helper()
        let opened = try opened(helper)
        let copy = PluginTestInvocation("probe.pick", event: .actionChosen("copy"), state: opened.state, view: opened.view)
        let copied = helper.run(copy, of: plugin, answering: RecordedHostServices())
        XCTAssertEqual(try copied.answer().toast, "Copying ♥")
        XCTAssertNil(try copied.answer().view)
        let operations = RecordedHostOperations()
        XCTAssertEqual(try operations.perform(copied, of: plugin, for: copy)?.outcome, .succeeded)

        let stamp = PluginTestInvocation("probe.stamp")
        let stamped = helper.run(stamp, of: plugin, answering: RecordedHostServices())
        XCTAssertEqual(try operations.perform(stamped, of: plugin, for: stamp)?.outcome, .refused(.targetNotShown))
        XCTAssertEqual(operations.performed.map(\.perform), ["clipboard.write", "selection.replace"])
    }

    /// A gesture in a view that showed no target cannot lead to an insertion.
    func testAnInsertionAfterAGestureInAViewWithoutTheTargetLineIsRefused() throws {
        let helper = try helper()
        let opened = try opened(helper)
        guard case .object(var view)? = opened.view else { return XCTFail("No view") }
        view["shows_insertion_target"] = nil
        let invocation = submit("star", after: opened, view: .object(view))
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices())
        XCTAssertEqual(try RecordedHostOperations().perform(run, of: plugin, for: invocation)?.outcome,
                       .refused(.targetNotShown))
    }

    /// Scenario 05: the Command must hold the operation's Capability, or the
    /// Host refuses the whole answer.
    func testADeniedCapabilityRefusesTheWholeAnswer() throws {
        let helper = try helper()
        let opened = try opened(helper)
        let invocation = submit("star", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices())
        XCTAssertThrowsError(try RecordedHostOperations(deniedCapabilities: [.insertIntoFocusedApp])
            .perform(run, of: plugin, for: invocation)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.insertIntoFocusedApp))
        }
    }

    // MARK: Synchronous insertion

    /// Scenario 04: a synchronous `selection.replace` inside a View Session
    /// goes ahead after a gesture made while the Host showed the target.
    func testASynchronousInsertionAfterAShownTargetReachesTheHost() throws {
        let helper = try helper()
        let opened = try opened(helper)
        let run = helper.run(PluginTestInvocation("probe.pick", event: .actionChosen("type-now"), state: opened.state,
                                                  view: opened.view),
                             of: plugin, answering: RecordedHostServices(operations: ["selection.replace": .value(.null)]))
        XCTAssertEqual(run.inputs(to: "selection.replace"), [.string("→")])
        XCTAssertEqual(try run.answer().view.flatMap { if case .object(let v) = $0 { return v["subtitle"] }; return nil },
                       .string("Typed →"))
    }

    /// Without a shown target, from the Action's start or a view without the
    /// line, the call is refused before it reaches the Host's services, and
    /// the invocation fails as a refused Host Service does.
    func testASynchronousInsertionWithoutAShownTargetFails() throws {
        let helper = try helper()
        let refused = PluginRuntimeError.hostServiceFailed("Nothing showed where the text would go, so nothing was inserted")
        let services = RecordedHostServices(operations: ["selection.replace": .value(.null)])
        let stamp = helper.run(PluginTestInvocation("probe.stamp", input: .object(["sync": .bool(true)])), of: plugin,
                               answering: services)
        XCTAssertThrowsError(try stamp.result.get()) { XCTAssertEqual($0 as? PluginRuntimeError, refused) }
        XCTAssertEqual(stamp.requests, [])

        let noLine = helper.run(PluginTestInvocation("probe.pick", event: .actionChosen("type-now"),
                                                     state: .object(["count": .number(0)])),
                                of: plugin, answering: services)
        XCTAssertThrowsError(try noLine.result.get()) { XCTAssertEqual($0 as? PluginRuntimeError, refused) }
    }

    /// A target that changed fails the invocation with the candidate's own
    /// category, which the script cannot catch.
    func testATargetChangeFailsTheInvocationWithItsOwnCategory() throws {
        let helper = try helper()
        let opened = try opened(helper)
        let run = helper.run(PluginTestInvocation("probe.pick", event: .actionChosen("type-now"), state: opened.state,
                                                  view: opened.view),
                             of: plugin, answering: RecordedHostServices(operations: [
                                 "selection.replace": .failure(.insertion(.changedWithoutNames))
                             ]))
        XCTAssertThrowsError(try run.result.get()) {
            XCTAssertEqual($0 as? PluginRuntimeError,
                           .insertionTargetChanged("The App in front is not the one Spinnet showed, so nothing was inserted"))
            XCTAssertEqual(($0 as? PluginRuntimeError)?.failureCategory, .insertionTargetChanged)
        }
    }

    // MARK: Helper retirement

    /// A helper retired between commit and the result is started again by
    /// `operation_finished`, which it answers once.
    func testAHelperRetiredAfterCommitIsStartedAgainForTheResult() throws {
        let helper = try helper()
        let opened = try opened(helper)
        let invocation = submit("arrow", after: opened)
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices())
        let delivery = try XCTUnwrap(RecordedHostOperations().perform(run, of: plugin, for: invocation)?.delivery)
        let launches = helper.launchCount

        helper.retireHelper(of: plugin)
        let finished = helper.run(PluginTestInvocation("probe.pick", event: delivery, state: try run.answer().state),
                                  of: plugin, answering: RecordedHostServices())

        XCTAssertEqual(helper.launchCount, launches + 1)
        XCTAssertEqual(try finished.answer().state, .object(["count": .number(1), "last": .array([
            .string("insert"), .string("selection.replace"), .string("succeeded"), .null
        ])]))
    }

    // MARK: Level 1

    /// Scenario 11: declaring Level 1 alone, the same script's `operation`
    /// is an unknown member, and a synchronous insertion is Level 1's,
    /// whatever was shown.
    func testALevelOnePluginKeepsLevelOne() throws {
        let levelOne = try PluginUnderTest(packageAt: OperationsProbeFixture.write(scripts: ["pick.js": """
            (() => {
              if (event && event.type === "action_chosen") {
                spinnet.selection.replace("→");
                return null;
              }
              return { operation: { perform: "selection.replace", input: "x" } };
            })()
            """], OperationsProbeFixture.levelOne))
        let helper = try helper()
        let start = helper.run(PluginTestInvocation("probe.pick"), of: levelOne, answering: RecordedHostServices())
        XCTAssertThrowsError(try start.answer()) {
            XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation("The script's answer has unknown member operation"))
        }
        let typed = helper.run(PluginTestInvocation("probe.pick", event: .actionChosen("type-now")), of: levelOne,
                               answering: RecordedHostServices([.insertText: .value(.null)]))
        XCTAssertEqual(try typed.result.get(), .null)
        XCTAssertEqual(typed.inputs(to: .insertText), [.string("→")], "Level 1's insert_text, with no shown target")
    }

    // MARK: The SDK

    /// `host_operations` adds a builder to each operation it lets an answer
    /// request, keeps the calls, and adds `host`, `ui.request` and the
    /// `operation` option of `ui.show`.
    func testTheSDKBuildsRequestsAndKeepsCalls() throws {
        let source = try OperationsProbeFixture.write(scripts: ["pick.js": """
            (() => {
              const s = spinnet;
              return {
                settings: s.host.showPluginSettings.operation(),
                insert: s.selection.replace.operation({ text: "a" }, { id: "i", closesView: true, notify: false }),
                link: s.open.url.operation("https://example.com"),
                deepLink: s.apps.openDeepLink.operation({ template: "t" }),
                callable: [typeof s.selection.replace, typeof s.clipboard.write, typeof s.selection.readText,
                           typeof s.host.showPluginSettings, typeof s.selection.readText.operation],
                request: s.ui.request(s.clipboard.write.operation("x"), { toast: "t" }),
                show: s.ui.show(s.ui.view({ title: "T", showsInsertionTarget: true, actions: [] }),
                                { state: 1, operation: s.clipboardHistory.show.operation() }),
                frozen: Object.isFrozen(s.selection) && Object.isFrozen(s.selection.replace) && Object.isFrozen(s.ui)
              };
            })()
            """])
        let run = try helper().run(PluginTestInvocation("probe.pick"), of: PluginUnderTest(packageAt: source),
                                   answering: RecordedHostServices())
        guard case .object(let built) = try run.result.get() else { return XCTFail("\(run.result)") }
        XCTAssertEqual(built["settings"], .object(["perform": .string("host.showPluginSettings")]))
        XCTAssertEqual(built["insert"], .object(["perform": .string("selection.replace"), "input": .object(["text": .string("a")]),
                                                 "id": .string("i"), "closes_view": .bool(true), "notify": .bool(false)]))
        XCTAssertEqual(built["link"], .object(["perform": .string("open.url"), "input": .string("https://example.com")]))
        XCTAssertEqual(built["deepLink"], .object(["perform": .string("apps.openDeepLink"), "input": .object(["template": .string("t")])]))
        XCTAssertEqual(built["callable"], .array(["function", "function", "function", "object", "undefined"].map(JSONValue.string)))
        XCTAssertEqual(built["request"], .object(["toast": .string("t"),
                                                  "operation": .object(["perform": .string("clipboard.write"), "input": .string("x")])]))
        XCTAssertEqual(built["show"], .object([
            "view": .object(["title": .string("T"), "shows_insertion_target": .bool(true), "actions": .array([])]),
            "state": .number(1), "operation": .object(["perform": .string("clipboardHistory.show")])
        ]))
        XCTAssertEqual(built["frozen"], .bool(true))
    }

    /// A Plugin declaring `namespaces` alone gets no request builders.
    func testTheBuildersNeedTheCandidate() throws {
        let source = try OperationsProbeFixture.write(scripts: ["pick.js": """
            [typeof spinnet.host, typeof spinnet.selection.replace.operation, typeof spinnet.ui.request]
            """]) { manifest in
            manifest["candidate_contracts"] = .array([.object(["name": .string("namespaces"), "revision": .number(1)])])
        }
        let run = try helper().run(PluginTestInvocation("probe.pick"), of: PluginUnderTest(packageAt: source),
                                   answering: RecordedHostServices())
        XCTAssertEqual(try run.result.get(), .array(["undefined", "undefined", "undefined"].map(JSONValue.string)))
    }
}
