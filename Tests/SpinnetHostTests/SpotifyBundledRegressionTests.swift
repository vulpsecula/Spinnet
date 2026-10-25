import XCTest
import SpinnetCore
import SpinnetTestSupport
import SpinnetPluginTestKit
@testable import SpinnetHost

final class SpotifyBundledRegressionTests: XCTestCase {
    private static let baseline = TestRepository.tests
        .appendingPathComponent("RegressionBaseline/Spotify")

    private var fixture: BundledRegressionFixture!
    private var directory: URL { fixture.directory }
    private var defaultsSuite: String { fixture.defaultsSuite }

    override func setUpWithError() throws {
        fixture = try BundledRegressionFixture(baseline: Self.baseline)
    }

    override func tearDownWithError() throws {
        try fixture?.cleanup()
    }

    func testSavedSpotifyMenuItemRestoresItsActionsAliasAndDecisionsUnchanged() throws {
        let package = try ShippedPluginPackages.named("Spotify")
        let grants = try fixture.restoredGrants()
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true }, externalAppConnectionStatus: { _ in .ready })
        try registry.register(package)
        let stored = try fixture.configuration()
        XCTAssertEqual(Set(stored.actions.map(\.commandID)), Set(package.manifest.commands.map(\.id)))
        XCTAssertEqual(stored.actions.count, 9)
        XCTAssertEqual(stored.menu.slots.first?.item?.alias, "Desk Music")
        let primary = try XCTUnwrap(stored.actions.first { $0.id == stored.menu.slots.first?.item?.primaryActionID })
        XCTAssertEqual(primary.commandID, CommandID("spotify.volume"))
        XCTAssertEqual(primary.input, .string("37"))
        XCTAssertEqual(stored.menu.slots.first?.item?.disabledAlternateActionIDs.count, 1)
        for action in stored.actions {
            XCTAssertEqual(registry.availability(for: action), .available)
        }
        let settingsURL = directory.appendingPathComponent("PluginSettings.json")
        let settingsBytes = try Data(contentsOf: settingsURL)
        let settings = try PluginSettingsStore(fileURL: settingsURL)
        XCTAssertTrue(package.manifest.settingsFields.isEmpty)
        XCTAssertEqual(settings.values(for: package.manifest.id), [:])
        let decisions = Set(grants.allGrants)
        StoredDataMigration.reconcileCapabilityGrants(grants, with: registry.manifests(), discardingOthers: true)
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

    func testRemovingSpotifyCleansItsOwnerAndKeepsTheConfiguredMenuItem() throws {
        let package = try ShippedPluginPackages.named("Spotify")
        let grants = try fixture.restoredGrants()
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true }, externalAppConnectionStatus: { _ in .ready })
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
        let relaunchedRegistry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true }, externalAppConnectionStatus: { _ in .ready })
        let relaunchedStore = PluginInstallationStore(directory: installedDirectory, registry: relaunchedRegistry,
                                                       grants: grants, persistGrants: {})
        let suppressed = try relaunchedStore.removedPluginIDs()
        XCTAssertTrue(suppressed.contains(package.manifest.id))
        for shipped in try ShippedPluginPackages.all() where !suppressed.contains(shipped.manifest.id) {
            try relaunchedRegistry.register(shipped)
        }
        try relaunchedStore.restore()
        XCTAssertNil(relaunchedRegistry.package(for: package.manifest.id))
        let review = try relaunchedStore.review(package.rootURL)
        XCTAssertEqual(Set(review.requestedAccess), [.controlExternalApp])
        try relaunchedStore.install(from: package.rootURL)
        XCTAssertEqual(relaunchedRegistry.package(for: package.manifest.id)?.origin, .installed)
        XCTAssertTrue(try relaunchedStore.removedPluginIDs().contains(package.manifest.id))
        XCTAssertTrue(grants.allGrants.allSatisfy { $0.decision == .notDetermined })
        // The Capability is optional in the accepted package; the broker rejects
        // any attempted playback until a new scoped grant is given.
        let action = try XCTUnwrap(stored.actions.first)
        let reinstalled = try XCTUnwrap(relaunchedRegistry.package(for: package.manifest.id))
        XCTAssertEqual(relaunchedRegistry.availability(for: action), .unavailable(.capabilityDenied))
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            reviewedAppPerformer: { _, _ in XCTFail("Reinstallation must not authorize Spotify"); return .null },
            pluginRegistry: relaunchedRegistry)
        let request = PluginRuntimeHostServiceRequest(invocationID: "reinstalled", actionID: action.id,
            service: .performAppOperation, input: .object(["bundle_id": .string("com.spotify.client"),
                "operation": .string("play_pause")]), operation: "apps.perform")
        XCTAssertThrowsError(try broker.execute(request: request, for: reinstalled, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError,
                           .unavailable("Connect the External App in Plugin Settings before using this Command"))
        }
    }
}

extension SpotifyBundledRegressionTests {
    func testMissingSpotifyOrUnreadyConnectionNeverStartsTheHelperOrPlayback() throws {
        let package = try ShippedPluginPackages.named("Spotify")
        let stored = try fixture.configuration()
        let action = try XCTUnwrap(stored.actions.first)
        for status in [ExternalAppConnectionStatus.notInstalled, .notRunning, .permissionNeeded, .permissionDenied] {
            let grants = try fixture.restoredGrants()
            let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in status != .notInstalled },
                externalAppConnectionStatus: { _ in status })
            try registry.register(package)
            let helper = try PluginTestHelper()
            defer { helper.shutdown() }
            var performed = false
            let services = RecordedHostServices(operations: ["apps.perform": .answer { _ in
                performed = true
                return .null
            }])
            let runner = HostActionRunner(executor: services, scriptedExecutor: helper, hostServiceBroker: services)
            guard case .failed(let failure) = runner.invoke(action, using: registry).terminal else {
                return XCTFail("Spotify must wait for Host-owned dependency and connection repair")
            }
            XCTAssertEqual(failure.category, .commandUnavailable)
            XCTAssertEqual(helper.launchCount, 0)
            XCTAssertFalse(performed)
            XCTAssertEqual(try fixture.configuration(), stored)
        }
    }
}
