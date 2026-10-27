import Foundation
import SpinnetCore
import SpinnetTestSupport
import SpinnetPluginTestKit
import XCTest
@testable import SpinnetHost

/// Additive onboarding baseline; the six historical Plugins' user data stays fixed.
final class KeepAwakeBundledRegressionTests: XCTestCase {
    private let baseline = TestRepository.tests.appendingPathComponent("RegressionBaseline/KeepAwake")

    func testStoredMenuActionsSettingsAndDecisionsSurviveLaunch() throws {
        let package = try ShippedPluginPackages.named("Keep Awake")
        let fixture = try BundledRegressionFixture(baseline: baseline)
        defer { try? fixture.cleanup() }
        let grants = try fixture.restoredGrants()
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(package)
        let directory = fixture.directory
        let store = HostConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json"))
        let before = try fixture.configuration()
        let settings = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: fixture.defaultsSuite))
        let migrated = try StoredDataMigration.migrate(before, registry: registry, pluginSettings: settings, defaults: defaults)
        XCTAssertEqual(migrated, before)
        XCTAssertEqual(Set(migrated.actions.map(\.commandID)), Set(package.manifest.commands.map(\.id)))
        for action in migrated.actions { XCTAssertEqual(registry.availability(for: action), .available) }
        try store.save(migrated)
        XCTAssertEqual(try store.load(), before)
        XCTAssertFalse(package.manifest.hasSettings)
        XCTAssertEqual(settings.values(for: package.manifest.id), [:])
        StoredDataMigration.reconcileCapabilityGrants(grants, with: [package.manifest], discardingOthers: true)
        XCTAssertEqual(grants.decision(for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .keepAwake, scope: package.manifest.scope(for: .keepAwake)), .granted)
        XCTAssertEqual(grants.decision(for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .readFrontmostApp, scope: package.manifest.scope(for: .readFrontmostApp)), .denied)
    }

    func testRemovingBundledCopyStopsItsEffectAndInstallingACopyAsksAgain() throws {
        let package = try ShippedPluginPackages.named("Keep Awake")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grants = PluginCapabilityGrantStore(), registry = PluginRegistry()
        let recorded = RecordedKeepAwake()
        let observation = registry.observeInvalidation { recorded.effects.invalidate($0) }
        defer { registry.removeInvalidationObserver(observation); recorded.effects.shutdown() }
        try registry.register(package)
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .keepAwake, scope: package.manifest.scope(for: .keepAwake))
        try recorded.effects.start(KeepAwakeRequest(), owner: package.manifest.id, pluginName: package.manifest.name)
        let store = PluginInstallationStore(directory: directory, registry: registry, grants: grants, persistGrants: {})
        try store.uninstall(package.manifest.id)
        XCTAssertEqual(recorded.power.count, 0)
        XCTAssertTrue(recorded.activities.list().isEmpty)
        XCTAssertNil(registry.package(for: package.manifest.id))
        let relaunched = PluginInstallationStore(directory: directory, registry: PluginRegistry(), grants: grants, persistGrants: {})
        XCTAssertTrue(try relaunched.removedPluginIDs().contains(package.manifest.id))
        XCTAssertEqual(Set(try store.review(package.rootURL).requestedAccess), [.keepAwake, .readFrontmostApp])
        try store.install(from: package.rootURL)
        XCTAssertEqual(registry.package(for: package.manifest.id)?.origin, .installed)
        XCTAssertTrue(try store.removedPluginIDs().contains(package.manifest.id))
        XCTAssertEqual(grants.decision(for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .keepAwake, scope: package.manifest.scope(for: .keepAwake)), .notDetermined)
        XCTAssertTrue(recorded.activities.list().isEmpty, "Installing a copy never restores an effect")
    }

    func testBundledOriginGrantsNoPowerAuthorityAndOwnerChangesReleaseResources() throws {
        let package = try ShippedPluginPackages.named("Keep Awake")
        for change in ["revoke", "disable", "replace", "host-exit"] {
            let grants = PluginCapabilityGrantStore(), registry = PluginRegistry()
            let recorded = RecordedKeepAwake()
            let mutation = registry.observeInvalidation { recorded.effects.invalidate($0) }
            let revocation = grants.observeCapabilityRevocation { recorded.effects.revoke($0) }
            defer {
                registry.removeInvalidationObserver(mutation)
                grants.removeRevocationObserver(revocation)
                recorded.effects.shutdown()
            }
            try registry.register(package)
            let broker = CapabilityCheckedHostServiceBroker(
                grantStore: grants,
                systemPermissionCheck: { _ in false },
                clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
                keepAwakeEffects: recorded.effects,
                activities: recorded.activities,
                pluginRegistry: registry
            )
            let plugin = try PluginUnderTest(packageAt: package.rootURL, origin: .bundled)
            let action = try plugin.action(for: PluginTestInvocation("coffee.manual"))
            let request = PluginRuntimeHostServiceRequest(invocationID: "manual", actionID: action.id,
                service: .keepAwakeEffect, input: KeepAwakeRequest().json, operation: "system.keepAwake")
            XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action))
            XCTAssertEqual(recorded.power.count, 0)
            grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                capability: .keepAwake, scope: package.manifest.scope(for: .keepAwake))
            _ = try broker.execute(request: request, for: package, action: action)
            XCTAssertEqual(recorded.power.count, 2)
            switch change {
            case "revoke": grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version,
                capability: .keepAwake, scope: package.manifest.scope(for: .keepAwake))
            case "disable": try registry.setEnabled(false, for: package.manifest.id)
            case "replace": try registry.replace(package)
            default: recorded.effects.shutdown()
            }
            XCTAssertEqual(recorded.power.count, 0, change)
            XCTAssertTrue(recorded.activities.list().isEmpty, change)
        }
    }
}
