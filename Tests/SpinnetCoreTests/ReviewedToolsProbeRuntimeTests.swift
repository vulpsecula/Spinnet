import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class ReviewedToolsProbeRuntimeTests: XCTestCase {
    private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/ReviewedToolsProbe.spinnetplugin")

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
