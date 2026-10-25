import SpinnetTestSupport
import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// A package outside Host implementation reaches effects only through the
/// published SDK, real bounded helper and test-kit OS seam.
final class KeepAwakeProbeRuntimeTests: XCTestCase {
    private let fixture = TestRepository.tests
        .appendingPathComponent("Fixtures/KeepAwakeProbe.spinnetplugin")

    func testARequestedEffectSurvivesHelperRetirementAndCanBeStoppedFromItsOwnersList() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let recorded = RecordedKeepAwake()
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let invocation = PluginTestInvocation("probe.coffee", input: .object(["mode": .string("manual")]))
        let run = helper.run(invocation, of: plugin, answering: RecordedHostServices(keepAwake: recorded))
        let operations = RecordedHostOperations(keepAwake: recorded)
        XCTAssertEqual(try operations.perform(run, of: plugin, for: invocation)?.outcome, .succeeded)
        helper.shutdown()
        XCTAssertEqual(recorded.power.held, [.idleSystem, .idleDisplay])
        let nextHelper = try PluginTestHelper()
        defer { nextHelper.shutdown() }
        let list = try nextHelper.run(PluginTestInvocation("probe.list"), of: plugin,
            answering: RecordedHostServices(keepAwake: recorded)).answer()
        guard case .array(let entries) = list.state, case .object(let entry)? = entries.first,
              let id = entry["id"] else { return XCTFail("The effect is absent from its owner's list") }
        let stop = PluginTestInvocation("probe.stop", input: .object(["id": id]))
        let stopped = nextHelper.run(stop, of: plugin, answering: RecordedHostServices(keepAwake: recorded))
        XCTAssertEqual(try operations.perform(stopped, of: plugin, for: stop)?.outcome, .succeeded)
        XCTAssertEqual(recorded.power.held, [])
    }

    func testScriptlessCommandNeedsARealGrantAndRevokingItReleasesBothAssertions() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let recorded = RecordedKeepAwake()
        let grants = PluginCapabilityGrantStore()
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            keepAwakeEffects: recorded.effects, activities: recorded.activities)
        let token = grants.observeCapabilityRevocation { recorded.effects.revoke($0) }
        defer { grants.removeRevocationObserver(token); recorded.effects.shutdown() }
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let invocation = PluginTestInvocation("probe.direct")
        XCTAssertThrowsError(try helper.run(invocation, of: plugin, answering: broker).answer())
        XCTAssertEqual(recorded.power.count, 0)
        grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                           capability: .keepAwake, scope: plugin.manifest.scope(for: .keepAwake))
        _ = try helper.run(invocation, of: plugin, answering: broker).answer()
        XCTAssertEqual(recorded.power.held, [.idleSystem, .idleDisplay])
        grants.setDecision(.denied, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                           capability: .keepAwake, scope: plugin.manifest.scope(for: .keepAwake))
        XCTAssertEqual(recorded.power.count, 0)
        XCTAssertEqual(recorded.activities.list(), [])
    }

    func testRevokingAppIdentityStopsOnlyTheAppBoundEffect() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let recorded = RecordedKeepAwake()
        let grants = PluginCapabilityGrantStore()
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            keepAwakeEffects: recorded.effects, activities: recorded.activities)
        let token = grants.observeCapabilityRevocation { recorded.apps.targets.forget($0.pluginID); recorded.effects.revoke($0) }
        defer { grants.removeRevocationObserver(token); recorded.effects.shutdown() }
        for capability in [PluginCapability.keepAwake, .readFrontmostApp] {
            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                capability: capability, scope: plugin.manifest.scope(for: capability))
        }
        guard case .object(let front) = recorded.apps.targets.identifyFrontmost(of: recorded.apps, for: plugin.manifest.id),
              case .string(let target)? = front["target"] else { return XCTFail("No App Target") }
        let action = try plugin.action(for: PluginTestInvocation("probe.coffee"))
        for mode in [KeepAwakeRequest.Mode.manual, .duration(60), .appAlive(target)] {
            let request = PluginRuntimeHostServiceRequest(invocationID: "start", actionID: action.id,
                service: .keepAwakeEffect, input: KeepAwakeRequest(mode: mode).json, operation: "system.keepAwake")
            _ = try broker.execute(request: request, for: plugin.package, action: action)
        }
        XCTAssertEqual(recorded.power.count, 6)
        grants.setDecision(.denied, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
            capability: .readFrontmostApp, scope: plugin.manifest.scope(for: .readFrontmostApp))
        XCTAssertEqual(recorded.power.count, 4, "Revoking App identity must preserve manual and timed effects")
        XCTAssertEqual(recorded.activities.list(for: plugin.manifest.id).map(\.status).sorted(), ["1m 00s remaining", "Until stopped"])
        recorded.advance(by: 60)
        XCTAssertEqual(recorded.power.count, 2, "The preserved timer still expires normally")
    }

    func testUnrelatedRevocationPreservesEffectsButRemovingAllGrantsStopsThem() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let recorded = RecordedKeepAwake()
        let grants = PluginCapabilityGrantStore()
        let token = grants.observeCapabilityRevocation { recorded.effects.revoke($0) }
        defer { grants.removeRevocationObserver(token); recorded.effects.shutdown() }
        for capability in [PluginCapability.keepAwake, .contactHTTPS] {
            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                capability: capability, scope: plugin.manifest.scope(for: capability))
        }
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            keepAwakeEffects: recorded.effects, activities: recorded.activities)
        let action = try plugin.action(for: PluginTestInvocation("probe.direct"))
        let request = PluginRuntimeHostServiceRequest(invocationID: "start", actionID: action.id,
            service: .keepAwakeEffect, input: KeepAwakeRequest().json, operation: "system.keepAwake")
        _ = try broker.execute(request: request, for: plugin.package, action: action)
        grants.setDecision(.denied, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
            capability: .contactHTTPS, scope: plugin.manifest.scope(for: .contactHTTPS))
        XCTAssertEqual(recorded.power.count, 2)
        XCTAssertEqual(recorded.activities.list(for: plugin.manifest.id).count, 1)
        grants.removeGrants(for: plugin.manifest.id)
        XCTAssertEqual(recorded.power.count, 0)
        XCTAssertEqual(recorded.activities.list(), [])
    }

    func testAppAuthorityRegrantCannotReviveAnAcceptedAppStartButManualStartRemainsCurrent() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let recorded = RecordedKeepAwake()
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry()
        try registry.register(plugin.package)
        // Keep the target here to isolate authority-lifetime protection from
        // App Target forgetting, which the production observer also performs.
        let token = grants.observeCapabilityRevocation { recorded.effects.revoke($0) }
        defer { grants.removeRevocationObserver(token); recorded.effects.shutdown() }
        for capability in [PluginCapability.keepAwake, .readFrontmostApp] {
            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                capability: capability, scope: plugin.manifest.scope(for: capability))
        }
        guard case .object(let front) = recorded.apps.targets.identifyFrontmost(of: recorded.apps, for: plugin.manifest.id),
              case .string(let target)? = front["target"] else { return XCTFail("No App Target") }
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            keepAwakeEffects: recorded.effects, activities: recorded.activities, pluginRegistry: registry)
        let action = try plugin.action(for: PluginTestInvocation("probe.coffee"))
        let admitted = try XCTUnwrap(broker.keepAwakeAdmission(for: plugin.package))
        let appRequest = PluginRuntimeHostServiceRequest(invocationID: "paused", actionID: action.id,
            service: .keepAwakeEffect, input: KeepAwakeRequest(mode: .appAlive(target)).json, operation: "system.keepAwake")
        for decision in [PluginCapabilityGrantDecision.denied, .granted] {
            grants.setDecision(decision, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                capability: .readFrontmostApp, scope: plugin.manifest.scope(for: .readFrontmostApp))
        }
        XCTAssertThrowsError(try broker.execute(request: appRequest, for: plugin.package, action: action, admittedOwner: admitted))
        XCTAssertEqual(recorded.power.count, 0)
        let manualRequest = PluginRuntimeHostServiceRequest(invocationID: "paused-manual", actionID: action.id,
            service: .keepAwakeEffect, input: KeepAwakeRequest().json, operation: "system.keepAwake")
        _ = try broker.execute(request: manualRequest, for: plugin.package, action: action, admittedOwner: admitted)
        XCTAssertEqual(recorded.power.count, 2)
        _ = try broker.execute(request: appRequest, for: plugin.package, action: action)
        XCTAssertEqual(recorded.power.count, 4, "Only a new App-bound call may use the new authority lifetime")
    }

    func testPausedAcceptedEffectCannotStartAfterReplacementReenableOrRegrant() throws {
        for change in ["replace", "enable", "regrant"] {
            let plugin = try PluginUnderTest(packageAt: fixture)
            let recorded = RecordedKeepAwake()
            let grants = PluginCapabilityGrantStore()
            let registry = PluginRegistry()
            try registry.register(plugin.package)
            let observation = registry.observeInvalidation { recorded.effects.invalidate($0) }
            let revocation = grants.observeCapabilityRevocation { recorded.effects.revoke($0) }
            defer { registry.removeInvalidationObserver(observation); grants.removeRevocationObserver(revocation); recorded.effects.shutdown() }
            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                capability: .keepAwake, scope: plugin.manifest.scope(for: .keepAwake))
            let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false },
                selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
                keepAwakeEffects: recorded.effects, activities: recorded.activities, pluginRegistry: registry)
            let invocation = PluginTestInvocation("probe.direct")
            let action = try plugin.action(for: invocation)
            let request = PluginRuntimeHostServiceRequest(invocationID: "paused", actionID: action.id,
                service: .keepAwakeEffect, input: KeepAwakeRequest().json, operation: "system.keepAwake")
            let admitted = try XCTUnwrap(broker.keepAwakeAdmission(for: plugin.package))
            // The public boundary stands for a dispatch queue paused after
            // accepting the owner but before any OS resource starts.
            let resume = { try broker.execute(request: request, for: plugin.package, action: action, admittedOwner: admitted) }
            if change == "replace" { try registry.replace(plugin.package) }
            else if change == "enable" {
                try registry.setEnabled(false, for: plugin.manifest.id)
                try registry.setEnabled(true, for: plugin.manifest.id)
            } else {
                grants.setDecision(.denied, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                    capability: .keepAwake, scope: plugin.manifest.scope(for: .keepAwake))
                grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                    capability: .keepAwake, scope: plugin.manifest.scope(for: .keepAwake))
            }
            XCTAssertThrowsError(try resume(), "The same manifest/version must not make stale accepted work current")
            XCTAssertEqual(recorded.power.count, 0)
            XCTAssertEqual(recorded.activities.list(), [])
            // A new user call may start under the new registration.
            _ = try broker.execute(request: request, for: plugin.package, action: action)
            XCTAssertEqual(recorded.power.count, 2)
        }
    }

    func testPreparedDirectHostCommandCannotStartAfterReplacementReenableOrRegrant() throws {
        for change in ["replace", "enable", "regrant"] {
            let plugin = try PluginUnderTest(packageAt: fixture)
            let recorded = RecordedKeepAwake()
            let grants = PluginCapabilityGrantStore()
            let registry = PluginRegistry()
            try registry.register(plugin.package)
            let mutation = registry.observeInvalidation { recorded.effects.invalidate($0) }
            let revocation = grants.observeCapabilityRevocation { recorded.effects.revoke($0) }
            defer { registry.removeInvalidationObserver(mutation); grants.removeRevocationObserver(revocation); recorded.effects.shutdown() }
            grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                capability: .keepAwake, scope: plugin.manifest.scope(for: .keepAwake))
            let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in false },
                selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
                keepAwakeEffects: recorded.effects, activities: recorded.activities, pluginRegistry: registry)
            let runner = HostActionRunner(executor: NoLegacyCommand(), hostServiceBroker: broker)
            let action = try plugin.action(for: PluginTestInvocation("probe.direct"))
            // Exactly the production direct Host Command entry: prepare on
            // the click's thread, then pause its dispatch queue before run.
            let resume = runner.prepareInvocation(action, using: registry)
            if change == "replace" { try registry.replace(plugin.package) }
            else if change == "enable" {
                try registry.setEnabled(false, for: plugin.manifest.id)
                try registry.setEnabled(true, for: plugin.manifest.id)
            } else {
                grants.setDecision(.denied, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                    capability: .keepAwake, scope: plugin.manifest.scope(for: .keepAwake))
                grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
                    capability: .keepAwake, scope: plugin.manifest.scope(for: .keepAwake))
            }
            guard case .failed = resume().terminal else { return XCTFail("Stale direct click started after \(change)") }
            XCTAssertEqual(recorded.power.count, 0)
            XCTAssertEqual(recorded.activities.list(), [])
            guard case .succeeded = runner.prepareInvocation(action, using: registry)().terminal else {
                return XCTFail("Fresh direct click failed after \(change)")
            }
            XCTAssertEqual(recorded.power.count, 2)
        }
    }
}

private struct NoLegacyCommand: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue {
        throw HostCommandExecutionError.unavailable("This test runs the catalogue Host Command through the real broker")
    }
}
