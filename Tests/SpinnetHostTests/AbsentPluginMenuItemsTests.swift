import XCTest
import SpinnetCore
import SpinnetTestSupport
@testable import SpinnetHost

/// Saved data from a Host that carried official Plugins inside the app meets
/// a Host that carries none. Nothing is migrated: the Menu Items stay in
/// their Slots as unavailable, and installing a Plugin with the same identity
/// restores them like any other absent Plugin.
final class AbsentPluginMenuItemsTests: XCTestCase {
    private static let baseline = TestRepository.tests
        .appendingPathComponent("RegressionBaseline/SystemMonitor")

    private var fixture: SavedDataRegressionFixture!

    override func setUpWithError() throws {
        fixture = try SavedDataRegressionFixture(baseline: Self.baseline)
    }

    override func tearDownWithError() throws {
        try fixture?.cleanup()
    }

    func testMenuItemsOfAPluginThatIsNotInstalledStayUntilItIsInstalledAgain() throws {
        let package = try OfficialPluginFixtures.named("System Monitor")
        let grants = try fixture.restoredGrants()
        let registry = PluginRegistry(grantStore: grants)
        let installed = fixture.directory.appendingPathComponent("Plugins")
        let store = PluginInstallationStore(directory: installed, registry: registry, grants: grants, persistGrants: {})
        let stored = try fixture.configuration()
        XCTAssertFalse(stored.actions.isEmpty)
        XCTAssertTrue(stored.actions.allSatisfy { $0.pluginID == package.manifest.id })

        // A launch: nothing is installed, so the Plugin is simply absent.
        try store.restore()
        StoredDataMigration.reconcileCapabilityGrants(grants, with: registry.manifests(),
                                                      keeping: registry.refusedPlugins().map(\.id))
        let settings = try PluginSettingsStore(fileURL: fixture.directory.appendingPathComponent("PluginSettings.json"))
        let launched = try StoredDataMigration.migrate(stored, registry: registry, pluginSettings: settings,
                                                      defaults: XCTUnwrap(UserDefaults(suiteName: fixture.defaultsSuite)))

        XCTAssertEqual(launched, stored, "The Menu Items keep their Slots, alias and Actions")
        XCTAssertNil(registry.package(for: package.manifest.id))
        for action in launched.actions {
            XCTAssertEqual(registry.availability(for: action), .unavailable(.pluginMissing))
        }
        XCTAssertTrue(grants.allGrants.allSatisfy { $0.pluginID != package.manifest.id },
                      "An absent Plugin's decisions are forgotten like a removed one's")

        // Installing the same identity restores them, asking for access again.
        XCTAssertEqual(Set(try store.review(package.rootURL).requestedAccess), [.readSystemStatus])
        try store.install(from: package.rootURL)
        for action in launched.actions {
            XCTAssertEqual(registry.availability(for: action), .unavailable(.capabilityDenied))
        }
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                           capability: .readSystemStatus, scope: package.manifest.scope(for: .readSystemStatus))
        for action in launched.actions {
            XCTAssertEqual(registry.availability(for: action), .available)
        }
        XCTAssertEqual(launched.menu, stored.menu)
    }
}
