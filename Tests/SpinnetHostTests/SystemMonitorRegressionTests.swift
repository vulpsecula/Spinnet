import XCTest
import SpinnetCore
import SpinnetTestSupport
@testable import SpinnetHost

final class SystemMonitorRegressionTests: XCTestCase {
    private static let baseline = TestRepository.tests
        .appendingPathComponent("RegressionBaseline/SystemMonitor")

    private var fixture: SavedDataRegressionFixture!
    private var directory: URL { fixture.directory }
    private var defaultsSuite: String { fixture.defaultsSuite }

    override func setUpWithError() throws {
        fixture = try SavedDataRegressionFixture(baseline: Self.baseline)
    }

    override func tearDownWithError() throws {
        try fixture?.cleanup()
    }

    func testSavedSystemMonitorMenuItemRestoresItsActionAliasAndDecisionUnchanged() throws {
        let package = try OfficialPluginFixtures.named("System Monitor")
        let grants = try fixture.restoredGrants()
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(package)
        let stored = try fixture.configuration()
        XCTAssertEqual(Set(stored.actions.map(\.commandID)), Set(package.manifest.commands.map(\.id)))
        XCTAssertEqual(stored.actions.count, 1)
        XCTAssertEqual(stored.menu.slots.first?.item?.alias, "Machine status")
        for action in stored.actions {
            XCTAssertEqual(registry.availability(for: action), .available)
        }
        let settingsURL = directory.appendingPathComponent("PluginSettings.json")
        let settingsBytes = try Data(contentsOf: settingsURL)
        let settings = try PluginSettingsStore(fileURL: settingsURL)
        XCTAssertTrue(package.manifest.settingsFields.isEmpty)
        XCTAssertEqual(settings.values(for: package.manifest.id), [:])
        let decisions = Set(grants.allGrants)
        StoredDataMigration.reconcileCapabilityGrants(grants, with: registry.manifests())
        XCTAssertEqual(Set(grants.allGrants), decisions)
        let migrated = try StoredDataMigration.migrate(stored, registry: registry, pluginSettings: settings,
                                                      defaults: XCTUnwrap(UserDefaults(suiteName: defaultsSuite)))
        XCTAssertEqual(migrated, stored)
        XCTAssertEqual(try Data(contentsOf: settingsURL), settingsBytes)
        try HostConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json")).save(migrated)
        XCTAssertEqual(try fixture.configuration(), stored)
        let restored = PluginCapabilityGrantStore()
        try StoredDataMigration.restoreCapabilityGrants(from: StoredDataMigration.encodeCapabilityGrants(grants), into: restored)
        XCTAssertEqual(Set(restored.allGrants), decisions)
    }

    func testSavedDeniedMetricAccessSurvivesLaunchWithoutOriginPrivilege() throws {
        let package = try OfficialPluginFixtures.named("System Monitor")
        let grants = try fixture.restoredGrants()
        grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .readSystemStatus, scope: package.manifest.scope(for: .readSystemStatus))
        let encoded = try StoredDataMigration.encodeCapabilityGrants(grants)
        let restored = PluginCapabilityGrantStore()
        try StoredDataMigration.restoreCapabilityGrants(from: encoded, into: restored)
        StoredDataMigration.reconcileCapabilityGrants(restored, with: [package.manifest])
        let registry = PluginRegistry(grantStore: restored)
        try registry.register(package)
        XCTAssertEqual(restored.decision(for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .readSystemStatus, scope: package.manifest.scope(for: .readSystemStatus)), .denied)
        for action in try fixture.configuration().actions {
            XCTAssertEqual(registry.availability(for: action), .unavailable(.capabilityDenied))
        }
    }

    func testRemovingSystemMonitorCleansItsOwnerAndKeepsTheConfiguredMenuItem() throws {
        let package = try OfficialPluginFixtures.named("System Monitor")
        let grants = try fixture.restoredGrants()
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(package)
        let stored = try fixture.configuration()
        let storage = PluginStorage(directory: directory.appendingPathComponent("Storage"))
        try storage.setValue(.string("transient business state"), forKey: "state", of: package.manifest.id)
        var forgotten: [PluginID] = []
        var invalidated: [PluginID] = []
        let observation = registry.observeInvalidation { invalidated.append($0) }
        defer { registry.removeInvalidationObserver(observation) }
        let installedDirectory = directory.appendingPathComponent("Plugins")
        let store = PluginInstallationStore(directory: installedDirectory, registry: registry, grants: grants,
                                             persistGrants: {}, storage: storage,
                                             forgetHostPreferences: { forgotten.append($0) })
        try store.uninstall(package.manifest.id)
        XCTAssertEqual(invalidated, [package.manifest.id])
        XCTAssertEqual(forgotten, [package.manifest.id])
        XCTAssertEqual(try storage.keys(of: package.manifest.id), [])
        XCTAssertTrue(grants.allGrants.isEmpty)
        XCTAssertEqual(try fixture.configuration(), stored)
        for action in stored.actions {
            XCTAssertEqual(registry.availability(for: action), .unavailable(.pluginMissing))
        }
        let relaunchedRegistry = PluginRegistry(grantStore: grants)
        let relaunchedStore = PluginInstallationStore(directory: installedDirectory, registry: relaunchedRegistry,
                                                       grants: grants, persistGrants: {})
        try relaunchedStore.restore()
        XCTAssertNil(relaunchedRegistry.package(for: package.manifest.id))
        let review = try relaunchedStore.review(package.rootURL)
        XCTAssertEqual(Set(review.requestedAccess), [.readSystemStatus])
        try relaunchedStore.install(from: package.rootURL)
        XCTAssertNotNil(relaunchedRegistry.package(for: package.manifest.id))
        XCTAssertTrue(grants.allGrants.allSatisfy { $0.decision == .notDetermined })
        for action in stored.actions {
            XCTAssertEqual(relaunchedRegistry.availability(for: action), .unavailable(.capabilityDenied))
        }
    }
}
