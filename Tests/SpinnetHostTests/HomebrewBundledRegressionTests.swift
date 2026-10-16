import XCTest
import SpinnetCore
import SpinnetTestSupport
@testable import SpinnetHost

final class HomebrewBundledRegressionTests: XCTestCase {
    private static let baseline = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("RegressionBaseline/Homebrew")

    private var fixture: BundledRegressionFixture!
    private var directory: URL { fixture.directory }
    private var defaultsSuite: String { fixture.defaultsSuite }

    override func setUpWithError() throws {
        fixture = try BundledRegressionFixture(baseline: Self.baseline)
    }

    override func tearDownWithError() throws {
        try fixture?.cleanup()
    }

    func testSavedHomebrewMenuItemRestoresItsActionsAliasAndDecisionsUnchanged() throws {
        let package = try ShippedPluginPackages.named("Homebrew")
        let grants = try fixture.restoredGrants()
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(package)
        let stored = try fixture.configuration()
        XCTAssertEqual(Set(stored.actions.map(\.commandID)), Set(package.manifest.commands.map(\.id)))
        XCTAssertEqual(stored.actions.count, 14)
        XCTAssertEqual(stored.menu.slots.first?.item?.alias, "Homebrew · development Mac")
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

    func testHistoricalCandidateActionsRetainIdentityWithoutRegisteringRetiredContracts() throws {
        let historical = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf:
            Self.baseline.appendingPathComponent("historical-candidate-manifest.json")))
        XCTAssertEqual(historical.apiLevel, 2)
        XCTAssertEqual(historical.candidateContracts, [AdaptiveViewportLayout.declaration, HomebrewAutoremove.declaration])
        let stored = try fixture.configuration()
        XCTAssertEqual(stored.actions, try zip(stored.actions, historical.commands).map { saved, command in
            try ActionConfiguration(id: saved.id, pluginID: historical.id, command: command, input: saved.input)
        })
        let package = try ShippedPluginPackages.named("Homebrew")
        XCTAssertEqual(package.manifest.apiLevel, 3)
        XCTAssertTrue(package.manifest.candidateContracts.isEmpty)
    }

    func testBundledOriginRechecksReadAuthorityBeforeReportingMissingHomebrew() throws {
        let package = try ShippedPluginPackages.named("Homebrew")
        let grants = PluginCapabilityGrantStore()
        let profile = HomebrewReadProfile(executable: { throw PluginHostServiceError.tool(.missing) })
        let broker = CapabilityCheckedHostServiceBroker(grantStore: grants,
            systemPermissionCheck: { _ in false }, selectedTextProvider: { _ in "" },
            clipboardWriter: { _ in }, reviewedTools: profile)
        let action = try XCTUnwrap(try fixture.configuration().actions.first)
        let request = PluginRuntimeHostServiceRequest(invocationID: "missing-homebrew", actionID: action.id,
            service: .reviewedToolRead,
            input: .object(["tool": .string("homebrew"), "operation": .string("installed")]), operation: "tools.read")
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.readReviewedTools))
        }
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .readReviewedTools, scope: package.manifest.scope(for: .readReviewedTools))
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.missing))
        }
    }

    func testRemovingHomebrewCleansItsOwnerAndKeepsTheConfiguredMenuItem() throws {
        let package = try ShippedPluginPackages.named("Homebrew")
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
        let suppressed = try relaunchedStore.removedPluginIDs()
        XCTAssertTrue(suppressed.contains(package.manifest.id))
        for shipped in try ShippedPluginPackages.all() where !suppressed.contains(shipped.manifest.id) {
            try relaunchedRegistry.register(shipped)
        }
        try relaunchedStore.restore()
        XCTAssertNil(relaunchedRegistry.package(for: package.manifest.id))
        let review = try relaunchedStore.review(package.rootURL)
        XCTAssertEqual(Set(review.requestedAccess), Set(package.manifest.capabilities))
        try relaunchedStore.install(from: package.rootURL)
        XCTAssertEqual(relaunchedRegistry.package(for: package.manifest.id)?.origin, .installed)
        XCTAssertTrue(try relaunchedStore.removedPluginIDs().contains(package.manifest.id))
        XCTAssertTrue(grants.allGrants.allSatisfy { $0.decision == .notDetermined })
        for action in stored.actions {
            XCTAssertEqual(relaunchedRegistry.availability(for: action), .available)
        }
    }
}
