import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools
import SpinnetTestSupport
@testable import SpinnetHost

final class HomebrewRegressionTests: XCTestCase {
    private static let baseline = TestRepository.tests
        .appendingPathComponent("RegressionBaseline/Homebrew")

    private var fixture: SavedDataRegressionFixture!
    private var directory: URL { fixture.directory }
    private var defaultsSuite: String { fixture.defaultsSuite }

    override func setUpWithError() throws {
        fixture = try SavedDataRegressionFixture(baseline: Self.baseline)
    }

    override func tearDownWithError() throws {
        try fixture?.cleanup()
    }

    func testSavedHomebrewMenuItemMigratesRetiredEntrypointsKeepingBindingsAndDecisions() throws {
        let package = try OfficialPluginFixtures.named("Homebrew")
        let grants = try fixture.restoredGrants()
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(package)
        // The historical access fixture remains tied to its original version,
        // whose declaration never becomes an executable package.
        let previousData = try Data(contentsOf: Self.baseline.appendingPathComponent("historical-candidate-manifest.json"))
        XCTAssertThrowsError(try PluginManifestLoader.decode(previousData), "Historical metadata must never become an executable package")
        let priorDecisions = grants.allGrants
        for capability in package.manifest.capabilities {
            XCTAssertEqual(grants.decision(for: package.manifest.id, pluginVersion: package.manifest.version,
                capability: capability, scope: package.manifest.scope(for: capability)), .notDetermined,
                "Changed command/output scopes need fresh consent")
        }
        // Simulate the user's explicit read approval before exercising saved
        // Actions. The optional mutation grant remains undecided.
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .readReviewedTools, scope: package.manifest.scope(for: .readReviewedTools))
        let stored = try fixture.configuration()
        let expected = try XCTUnwrap(package.manifest.migrate(stored))
        XCTAssertEqual(expected.actions.map(\.id), stored.actions.map(\.id))
        XCTAssertEqual(expected.menu, stored.menu)
        XCTAssertTrue(Set(expected.actions.map(\.commandID)).isSubset(of: Set(package.manifest.commands.map(\.id))))
        XCTAssertEqual(package.manifest.commands.count, 9)
        XCTAssertEqual(stored.actions.count, 14)
        XCTAssertEqual(stored.menu.slots.first?.item?.alias, "Homebrew · development Mac")
        for action in expected.actions {
            XCTAssertEqual(registry.availability(for: action), .available)
        }
        let settingsURL = directory.appendingPathComponent("PluginSettings.json")
        let settingsBytes = try Data(contentsOf: settingsURL)
        let settings = try PluginSettingsStore(fileURL: settingsURL)
        XCTAssertTrue(package.manifest.settingsFields.isEmpty)
        XCTAssertEqual(settings.values(for: package.manifest.id), [:])
        StoredDataMigration.reconcileCapabilityGrants(grants, with: registry.manifests())
        let decisions = Set(grants.allGrants)
        XCTAssertTrue(Set(priorDecisions).isSubset(of: decisions))
        XCTAssertEqual(grants.decision(for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .runReviewedToolTasks, scope: package.manifest.scope(for: .runReviewedToolTasks)), .notDetermined)
        let migrated = try StoredDataMigration.migrate(stored, registry: registry, pluginSettings: settings,
                                                      defaults: XCTUnwrap(UserDefaults(suiteName: defaultsSuite)))
        XCTAssertEqual(migrated, expected)
        XCTAssertNil(try package.manifest.migrate(migrated), "Retired entrypoint migration is idempotent")
        XCTAssertEqual(try Data(contentsOf: settingsURL), settingsBytes)
        try HostConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json")).save(migrated)
        XCTAssertEqual(try fixture.configuration(), expected)
        let restored = PluginCapabilityGrantStore()
        try StoredDataMigration.restoreCapabilityGrants(from: StoredDataMigration.encodeCapabilityGrants(grants), into: restored)
        XCTAssertEqual(Set(restored.allGrants), decisions)
    }

    func testHistoricalCandidateActionsRetainIdentityWithoutRegisteringRetiredContracts() throws {
        let data = try Data(contentsOf: Self.baseline.appendingPathComponent("historical-candidate-manifest.json"))
        let historical = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(historical.value(atPointer: "/api_level"), .number(2))
        XCTAssertNotNil(historical.value(atPointer: "/candidate_contracts"))
        XCTAssertThrowsError(try PluginManifestLoader.decode(data)) {
            XCTAssertEqual($0.localizedDescription,
                ConfigurationError.invalidManifest(PluginManifest.compatibilityMigrationMessage).localizedDescription)
        }
        guard case .string(let rawID)? = historical.value(atPointer: "/id"),
              let commandValue = historical.value(atPointer: "/commands") else { return XCTFail("Missing historical commands") }
        let commands = try JSONDecoder().decode([CommandDeclaration].self, from: JSONEncoder().encode(commandValue))
        let stored = try fixture.configuration()
        XCTAssertEqual(stored.actions, try zip(stored.actions, commands).map { saved, command in
            try ActionConfiguration(id: saved.id, pluginID: PluginID(rawID), command: command, input: saved.input)
        })
        let package = try OfficialPluginFixtures.named("Homebrew")
        XCTAssertEqual(package.manifest.hostCompatibility, .current)
    }

    func testBrowserCannotUseUndeclaredAnalyticsReadsEvenWithAHistoricalGrant() throws {
        let package = try OfficialPluginFixtures.named("Homebrew")
        let grants = PluginCapabilityGrantStore()
        let profile = HomebrewReadProfile(executable: { throw PluginHostServiceError.tool(.missing) })
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in false },
            clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
            tools: .init(reader: profile)
        )
        let action = try XCTUnwrap(try fixture.configuration().actions.first)
        let request = PluginRuntimeHostServiceRequest(invocationID: "missing-homebrew", actionID: action.id,
            service: .reviewedToolRead,
            input: .object(["tool": .string("homebrew"), "operation": .string("packageAnalytics"),
                            "kind": .string("formula"), "names": .array([.string("wget")])]), operation: "tools.read")
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityScopeDenied(.readReviewedTools))
        }
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .readReviewedTools, scope: package.manifest.scope(for: .readReviewedTools))
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityScopeDenied(.readReviewedTools))
        }
    }
}
