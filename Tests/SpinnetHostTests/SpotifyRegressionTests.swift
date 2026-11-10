import XCTest
import SpinnetCore
import SpinnetTestSupport
import SpinnetPluginTestKit
@testable import SpinnetHost

final class SpotifyRegressionTests: XCTestCase {
    private static let baseline = TestRepository.tests
        .appendingPathComponent("RegressionBaseline/Spotify")

    private var fixture: SavedDataRegressionFixture!

    override func setUpWithError() throws {
        fixture = try SavedDataRegressionFixture(baseline: Self.baseline)
    }

    override func tearDownWithError() throws {
        try fixture?.cleanup()
    }

    func testMissingSpotifyOrUnreadyConnectionNeverStartsTheHelperOrPlayback() throws {
        let package = try OfficialPluginFixtures.named("Spotify")
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
