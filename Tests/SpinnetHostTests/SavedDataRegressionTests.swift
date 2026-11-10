import XCTest
import SpinnetCore
import SpinnetTestSupport
@testable import SpinnetHost

/// Saved user data of official Plugins, in the formats the Host writes
/// (`Tests/RegressionBaseline`): a launch leaves it as it was, and removing
/// the Plugin cleans up after it while its Menu Item stays. One body runs
/// over every baseline, since the Host treats them alike; what only one
/// Plugin does is in that Plugin's own regression tests.
final class SavedDataRegressionTests: XCTestCase {
    private struct Baseline {
        /// The official Plugin's name, and its directory in
        /// `Tests/RegressionBaseline`.
        let plugin: String
        let directory: String
        let actionCount: Int
        let alias: String
        /// What the installation review asks for when the Plugin is
        /// installed again.
        let requestedAccess: Set<PluginCapability>
        /// More that the saved configuration holds.
        var holds: (HostConfiguration) throws -> Void = { _ in }
        /// What the saved Actions can do once the Plugin is installed again.
        var afterInstallingAgain: (Reinstalled) throws -> Void = SavedDataRegressionTests.actionsWaitForAccess
    }

    /// A Plugin removed and installed again after a relaunch.
    private struct Reinstalled {
        let package: PluginPackage
        let stored: HostConfiguration
        let registry: PluginRegistry
        let grants: PluginCapabilityGrantStore
    }

    private static let currentApp = Baseline(
        plugin: "Current App", directory: "CurrentApp", actionCount: 3, alias: "Working App",
        requestedAccess: [.readFrontmostApp, .quitFrontmostApp])
    private static let systemMonitor = Baseline(
        plugin: "System Monitor", directory: "SystemMonitor", actionCount: 1, alias: "Machine status",
        requestedAccess: [.readSystemStatus])
    private static let keepAwake = Baseline(
        plugin: "Keep Awake", directory: "KeepAwake", actionCount: 5, alias: "Stay awake · workshop",
        requestedAccess: [.keepAwake, .readFrontmostApp])
    private static let spotify = Baseline(
        plugin: "Spotify", directory: "Spotify", actionCount: 9, alias: "Desk Music",
        requestedAccess: [.controlExternalApp],
        holds: { stored in
            let item = try XCTUnwrap(stored.menu.slots.first?.item)
            let primary = try XCTUnwrap(stored.actions.first { $0.id == item.primaryActionID })
            XCTAssertEqual(primary.commandID, CommandID("spotify.volume"))
            XCTAssertEqual(primary.input, .string("37"))
            XCTAssertEqual(item.disabledAlternateActionIDs.count, 1)
        },
        afterInstallingAgain: SavedDataRegressionTests.spotifyStaysUnconnected)
    private static let homebrew = Baseline(
        plugin: "Homebrew", directory: "Homebrew", actionCount: 14, alias: "Homebrew · development Mac",
        requestedAccess: [.readReviewedTools, .runReviewedToolTasks],
        afterInstallingAgain: SavedDataRegressionTests.homebrewReadsOnceAllowed)

    /// A registry that finds every External App installed and connected.
    private static func registry(_ grants: PluginCapabilityGrantStore) -> PluginRegistry {
        PluginRegistry(grantStore: grants, externalAppExists: { _ in true },
                       externalAppConnectionStatus: { _ in .ready })
    }

    private func forEach(_ baselines: [Baseline],
                         _ body: (Baseline, SavedDataRegressionFixture, PluginPackage) throws -> Void) throws {
        for baseline in baselines {
            try XCTContext.runActivity(named: baseline.plugin) { _ in
                let fixture = try SavedDataRegressionFixture(baseline: TestRepository.tests
                    .appendingPathComponent("RegressionBaseline/\(baseline.directory)"))
                defer { try? fixture.cleanup() }
                try body(baseline, fixture, try OfficialPluginFixtures.named(baseline.plugin))
            }
        }
    }

    /// Homebrew's saved data moves off retired entrypoints at launch, so its
    /// own tests follow that.
    func testALaunchRestoresASavedMenuItemItsActionsAliasAndDecisionsUnchanged() throws {
        try forEach([Self.currentApp, Self.systemMonitor, Self.keepAwake, Self.spotify]) { baseline, fixture, package in
            let name = baseline.plugin
            let grants = try fixture.restoredGrants()
            let registry = Self.registry(grants)
            try registry.register(package)
            let stored = try fixture.configuration()
            XCTAssertEqual(Set(stored.actions.map(\.commandID)), Set(package.manifest.commands.map(\.id)), name)
            XCTAssertEqual(stored.actions.count, baseline.actionCount, name)
            XCTAssertEqual(stored.menu.slots.first?.item?.alias, baseline.alias, name)
            try baseline.holds(stored)
            for action in stored.actions {
                XCTAssertEqual(registry.availability(for: action), .available, name)
            }
            let settingsURL = fixture.directory.appendingPathComponent("PluginSettings.json")
            let settingsBytes = try Data(contentsOf: settingsURL)
            let settings = try PluginSettingsStore(fileURL: settingsURL)
            XCTAssertTrue(package.manifest.settingsFields.isEmpty, name)
            XCTAssertEqual(settings.values(for: package.manifest.id), [:], name)
            let decisions = Set(grants.allGrants)
            XCTAssertFalse(decisions.isEmpty, name)
            StoredDataMigration.reconcileCapabilityGrants(grants, with: registry.manifests())
            XCTAssertEqual(Set(grants.allGrants), decisions, name)
            let migrated = try StoredDataMigration.migrate(
                stored, registry: registry, pluginSettings: settings,
                defaults: XCTUnwrap(UserDefaults(suiteName: fixture.defaultsSuite)))
            XCTAssertEqual(migrated, stored, name)
            XCTAssertEqual(try Data(contentsOf: settingsURL), settingsBytes, name)
            try HostConfigurationStore(fileURL: fixture.directory.appendingPathComponent("configuration.json")).save(migrated)
            XCTAssertEqual(try fixture.configuration(), stored, name)
            let restored = PluginCapabilityGrantStore()
            try StoredDataMigration.restoreCapabilityGrants(
                from: StoredDataMigration.encodeCapabilityGrants(grants), into: restored)
            XCTAssertEqual(Set(restored.allGrants), decisions, name)
        }
    }

    /// Keep Awake also holds an effect to stop, which its own tests follow.
    func testRemovingAPluginCleansUpAfterItAndKeepsTheConfiguredMenuItem() throws {
        try forEach([Self.currentApp, Self.systemMonitor, Self.spotify, Self.homebrew]) { baseline, fixture, package in
            let name = baseline.plugin
            let id = package.manifest.id
            let grants = try fixture.restoredGrants()
            let registry = Self.registry(grants)
            try registry.register(package)
            let stored = try fixture.configuration()
            let storage = PluginStorage(directory: fixture.directory.appendingPathComponent("Storage"))
            try storage.setValue(.string("transient business state"), forKey: "state", of: id)
            var forgotten: [PluginID] = []
            var invalidated: [PluginID] = []
            let observation = registry.observeInvalidation { invalidated.append($0) }
            defer { registry.removeInvalidationObserver(observation) }
            let installedDirectory = fixture.directory.appendingPathComponent("Plugins")
            let store = PluginInstallationStore(directory: installedDirectory, registry: registry, grants: grants,
                                                persistGrants: {}, storage: storage,
                                                forgetHostPreferences: { forgotten.append($0) })

            try store.uninstall(id)

            XCTAssertEqual(invalidated, [id], name)
            XCTAssertEqual(forgotten, [id], name)
            XCTAssertEqual(try storage.keys(of: id), [], name)
            XCTAssertTrue(grants.allGrants.isEmpty, name)
            XCTAssertEqual(try fixture.configuration(), stored, name)
            for action in stored.actions {
                XCTAssertEqual(registry.availability(for: action), .unavailable(.pluginMissing), name)
            }

            // The next launch does not bring it back; installing it again
            // asks for its access again.
            let relaunchedRegistry = Self.registry(grants)
            let relaunchedStore = PluginInstallationStore(directory: installedDirectory, registry: relaunchedRegistry,
                                                          grants: grants, persistGrants: {})
            try relaunchedStore.restore()
            XCTAssertNil(relaunchedRegistry.package(for: id), name)
            XCTAssertEqual(Set(try relaunchedStore.review(package.rootURL).requestedAccess), baseline.requestedAccess, name)
            try relaunchedStore.install(from: package.rootURL)
            let reinstalled = try XCTUnwrap(relaunchedRegistry.package(for: id), name)
            XCTAssertTrue(grants.allGrants.allSatisfy { $0.decision == .notDetermined }, name)
            try baseline.afterInstallingAgain(Reinstalled(package: reinstalled, stored: stored,
                                                          registry: relaunchedRegistry, grants: grants))
        }
    }

    private static func actionsWaitForAccess(_ plugin: Reinstalled) throws {
        for action in plugin.stored.actions {
            XCTAssertEqual(plugin.registry.availability(for: action), .unavailable(.capabilityDenied),
                           plugin.package.manifest.name)
        }
    }

    /// Spotify's Capability is optional in the accepted package; the broker
    /// refuses playback until a new scoped grant is given.
    private static func spotifyStaysUnconnected(_ plugin: Reinstalled) throws {
        let action = try XCTUnwrap(plugin.stored.actions.first)
        XCTAssertEqual(plugin.registry.availability(for: action), .unavailable(.capabilityDenied))
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: plugin.grants,
            systemPermissionCheck: { _ in true },
            clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
            externalApps: .init(reviewedAppPerformer: { _, _ in
                XCTFail("Reinstallation must not authorize Spotify"); return .null
            }),
            pluginRegistry: plugin.registry
        )
        let request = PluginRuntimeHostServiceRequest(
            invocationID: "reinstalled", actionID: action.id, service: .performAppOperation,
            input: .object(["bundle_id": .string("com.spotify.client"), "operation": .string("play_pause")]),
            operation: "apps.perform")
        XCTAssertThrowsError(try broker.execute(request: request, for: plugin.package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError,
                           .unavailable("Connect the External App in Plugin Settings before using this Command"))
        }
    }

    /// Homebrew's saved Actions, moved off their retired entrypoints, are
    /// available as soon as reading is allowed again.
    private static func homebrewReadsOnceAllowed(_ plugin: Reinstalled) throws {
        let manifest = plugin.package.manifest
        plugin.grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                                  capability: .readReviewedTools, scope: manifest.scope(for: .readReviewedTools))
        let migrated = try manifest.migrate(plugin.stored) ?? plugin.stored
        for action in migrated.actions {
            XCTAssertEqual(plugin.registry.availability(for: action), .available)
        }
    }
}
