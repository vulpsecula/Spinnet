import XCTest
import SpinnetCore
import SpinnetTestSupport
@testable import SpinnetHost

final class SystemMonitorRegressionTests: XCTestCase {
    private static let baseline = TestRepository.tests
        .appendingPathComponent("RegressionBaseline/SystemMonitor")

    private var fixture: SavedDataRegressionFixture!

    override func setUpWithError() throws {
        fixture = try SavedDataRegressionFixture(baseline: Self.baseline)
    }

    override func tearDownWithError() throws {
        try fixture?.cleanup()
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
}
