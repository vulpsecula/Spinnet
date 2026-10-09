import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class ReviewedToolsProbeRuntimeTests: XCTestCase {
    private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/ReviewedToolsProbe.spinnetplugin")

    func testOptionalReviewedToolGrantDoesNotRecoverAnOutOfScopeRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".spinnetplugin")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: fixture, to: directory)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any])
        manifest["optional_capabilities"] = ["read_reviewed_tools"]
        var scopes = try XCTUnwrap(manifest["capability_scopes"] as? [[String: Any]])
        scopes[0]["reviewed_tools"] = [["tool": "homebrew", "operations": ["installed"], "kinds": ["formula"]]]
        manifest["capability_scopes"] = scopes
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try """
        (() => { try { spinnet.tools.read(input); } catch (error) {
          spinnet.storage.set("continued", true); return error.code;
        } return "read"; })()
        """.write(to: directory.appendingPathComponent("read.js"), atomically: true, encoding: .utf8)
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        var continuations = 0
        let broker = RecordedHostServices(operations: ["tools.read": .value(.null), "storage.set": .answer { _ in continuations += 1; return .null }])
        for input in [
            JSONValue.object(["tool": .string("homebrew"), "operation": .string("search"), "kind": .string("formula"), "query": .string("wget")]),
            .object(["tool": .string("homebrew"), "operation": .string("installed"), "kind": .string("cask")])
        ] {
            let run = helper.run(PluginTestInvocation("probe.read", input: input), of: plugin, answering: broker)
            guard case .failure(let error) = run.result, case .capabilityDenied = error as? PluginRuntimeError else {
                return XCTFail("An out-of-scope request must terminate with capability_denied")
            }
        }
        XCTAssertEqual(continuations, 0, "A caught scope refusal cannot continue the invocation")
        let grants = PluginCapabilityGrantStore()
        var discovered = 0
        let profile = HomebrewReadProfile(executable: { discovered += 1; throw PluginHostServiceError.tool(.missing) })
        let checked = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true }, selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, reviewedTools: profile)
        for decision in [PluginCapabilityGrantDecision.granted, .denied] {
            grants.setDecision(decision, for: plugin.manifest.id, pluginVersion: plugin.manifest.version, capability: .readReviewedTools, scope: plugin.manifest.scope(for: .readReviewedTools))
            let run = helper.run(PluginTestInvocation("probe.read", input: .object(["tool": .string("homebrew"), "operation": .string("installed"), "kind": .string("cask")])), of: plugin, answering: checked)
            guard case .failure(let error) = run.result, case .capabilityDenied = error as? PluginRuntimeError else { return XCTFail("Scope must be terminal with either grant decision") }
        }
        XCTAssertEqual(discovered, 0)
        let denied = helper.run(PluginTestInvocation("probe.read", input: .object(["tool": .string("homebrew"), "operation": .string("installed"), "kind": .string("formula")])), of: plugin,
            answering: RecordedHostServices(operations: ["tools.read": .failure(.capabilityDenied(.readReviewedTools)), "storage.set": .answer { _ in continuations += 1; return .null }]))
        XCTAssertEqual(try denied.result.get(), .string("capability_denied"))
        XCTAssertEqual(continuations, 1, "A valid request may recover a denied optional grant")
    }

    func testPublishedPackageReadsInstalledDataThroughTheRealHelper() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let result: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("installed"), "packages": .array([.object(["kind": .string("formula"), "name": .string("wget"), "version": .string("1.25")])])])
        let invocation = PluginTestInvocation("probe.read", input: .object(["tool": .string("homebrew"), "operation": .string("installed")]))
        let answer = try helper.run(invocation, of: plugin, answering: RecordedHostServices(operations: ["tools.read": .value(result)])).answer()
        XCTAssertEqual(answer.state, result)
        XCTAssertEqual(answer.page?.id, "packages")
    }

    func testReviewedToolSourceCancelsOnHideAndResumesWithoutPublishingTheOldResult() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(plugin.package)
        grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
            capability: .readReviewedTools, scope: plugin.manifest.scope(for: .readReviewedTools))
        let action = try plugin.action(for: PluginTestInvocation("probe.read"))
        let page: JSONValue = .object(["id": .string("brew"), "title": .string("Packages"),
            "sources": .array([.object(["id": .string("local"), "perform": .string("tools.read"), "input": .object(["tool": .string("homebrew"), "operation": .string("installed"), "kind": .string("formula")]), "deliver": .object([:])])]),
            "content": .array([.object(["kind": .string("text"), "id": .string("name"), "text": .string("Waiting"), "bind": .object(["source": .string("local"), "pointer": .string("/packages/0/name")])])])])
        var engine: HostRunSources!
        var runs = 0, cancelled = 0
        var clock = 0.0
        var scheduled: [(Double, () -> Void)] = []
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, executeCancellable: { _, arguments, _, deadline, token in
            runs += 1
            XCTAssertEqual(arguments, ["info", "--json=v2", "--installed", "--formula"])
            XCTAssertGreaterThan(deadline.timeIntervalSinceNow, 14)
            XCTAssertLessThanOrEqual(deadline.timeIntervalSinceNow, 15)
            let forget = token.onCancel { cancelled += 1 }; defer { forget() }
            if runs == 1 { engine.setVisible(false, pluginID: plugin.manifest.id) }
            return HomebrewReadOutput(status: 0, stdout: Data((runs == 1 ? #"{"formulae":[{"name":"old"}],"casks":[]}"# : #"{"formulae":[{"name":"current"}],"casks":[]}"#).utf8))
        })
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true }, selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, pluginRegistry: registry, reviewedTools: profile)
        var deliveries: [PluginViewEvent] = []
        engine = HostRunSources(adapters: ["tools.read": broker.reviewedToolSourceAdapter(using: registry)], now: { clock }, schedule: { scheduled.append((clock + $0, $1)) }, background: { $0() }, executor: { $0() })
        engine.onDelivery = { _, event, current in if current() { deliveries.append(event) } }
        try engine.present(PluginPage(parsing: page, permits: registry.contracts.permitting(plugin.manifest)), for: action)
        engine.setVisible(true, pluginID: plugin.manifest.id)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(engine.shown(component: "name", pluginID: plugin.manifest.id)?.text, "Waiting")
        XCTAssertTrue(deliveries.isEmpty)
        clock = 1
        engine.setVisible(true, pluginID: plugin.manifest.id)
        XCTAssertEqual(engine.shown(component: "name", pluginID: plugin.manifest.id)?.text, "current")
        XCTAssertEqual(deliveries.count, 1)
        engine.end(pluginID: plugin.manifest.id)
    }

    func testMissingHomebrewIsTypedAtTheExternalPackageBoundary() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let run = helper.run(PluginTestInvocation("probe.read", input: .object(["tool": .string("homebrew"), "operation": .string("installed")])), of: plugin, answering: RecordedHostServices(operations: ["tools.read": .failure(.tool(.missing))]))
        XCTAssertEqual(try run.answer().state, .object(["error": .string("tool_missing")]))
    }

    func testAReadRevokedAndRegrantedDuringExecutionCannotReturnOldData() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let grants = PluginCapabilityGrantStore()
        let scope = plugin.manifest.scope(for: .readReviewedTools)
        grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version, capability: .readReviewedTools, scope: scope)
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }) { _, _, _, _ in
            grants.setDecision(.denied, for: plugin.manifest.id, pluginVersion: plugin.manifest.version, capability: .readReviewedTools, scope: scope)
            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version, capability: .readReviewedTools, scope: scope)
            return HomebrewReadOutput(status: 0, stdout: Data(#"{"formulae":[],"casks":[]}"#.utf8))
        }
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false }, selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, reviewedTools: profile)
        let invocation = PluginTestInvocation("probe.read")
        let action = try plugin.action(for: invocation)
        let request = PluginRuntimeHostServiceRequest(invocationID: "read", actionID: action.id, service: .reviewedToolRead, input: .object(["tool": .string("homebrew"), "operation": .string("installed")]), operation: "tools.read")
        XCTAssertThrowsError(try broker.execute(request: request, for: plugin.package, action: action)) { XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.readReviewedTools)) }
    }
}
