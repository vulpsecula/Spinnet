import XCTest
import SpinnetCore
import SpinnetTestSupport
@testable import SpinnetHost

final class CurrentAppBundledRegressionTests: XCTestCase {
    private static let baseline = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("RegressionBaseline/CurrentApp")

    private var directory: URL!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CurrentAppBaseline-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["configuration.json", "capability-grants.json", "PluginSettings.json"] {
            try FileManager.default.copyItem(at: Self.baseline.appendingPathComponent(name),
                                            to: directory.appendingPathComponent(name))
        }
        defaultsSuite = "CurrentAppBaseline-\(UUID())"
    }

    override func tearDownWithError() throws {
        if let defaultsSuite { UserDefaults().removePersistentDomain(forName: defaultsSuite) }
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func restoredGrants() throws -> PluginCapabilityGrantStore {
        let grants = PluginCapabilityGrantStore()
        try StoredDataMigration.restoreCapabilityGrants(
            from: Data(contentsOf: directory.appendingPathComponent("capability-grants.json")), into: grants)
        return grants
    }

    private func configuration() throws -> HostConfiguration {
        try XCTUnwrap(HostConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json")).load())
    }

    func testSavedCurrentAppMenuItemRestoresItsActionsAliasAndDecisionsUnchanged() throws {
        let package = try ShippedPluginPackages.named("Current App")
        let grants = try restoredGrants()
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(package)
        let stored = try configuration()
        XCTAssertEqual(Set(stored.actions.map(\.commandID)), Set(package.manifest.commands.map(\.id)))
        XCTAssertEqual(stored.actions.count, 3)
        XCTAssertEqual(stored.menu.slots.first?.item?.alias, "Working App")
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
        XCTAssertEqual(try configuration(), stored)
        let restored = PluginCapabilityGrantStore()
        try StoredDataMigration.restoreCapabilityGrants(from: StoredDataMigration.encodeCapabilityGrants(grants), into: restored)
        XCTAssertEqual(Set(restored.allGrants), decisions)
    }

    func testRemovingCurrentAppCleansItsOwnerAndKeepsTheConfiguredMenuItem() throws {
        let package = try ShippedPluginPackages.named("Current App")
        let grants = try restoredGrants()
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(package)
        let stored = try configuration()
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
        XCTAssertEqual(try configuration(), stored)
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
        XCTAssertEqual(Set(review.requestedAccess), [.readFrontmostApp, .quitFrontmostApp])
        try relaunchedStore.install(from: package.rootURL)
        XCTAssertEqual(relaunchedRegistry.package(for: package.manifest.id)?.origin, .installed)
        XCTAssertTrue(try relaunchedStore.removedPluginIDs().contains(package.manifest.id))
        XCTAssertTrue(grants.allGrants.allSatisfy { $0.decision == .notDetermined })
        for action in stored.actions {
            XCTAssertEqual(relaunchedRegistry.availability(for: action), .unavailable(.capabilityDenied))
        }
    }
}
