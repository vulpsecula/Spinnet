import SpinnetCore
import XCTest
@testable import SpinnetHost

/// A launch lines access decisions up with the Plugins it found. An installed
/// Plugin this Host cannot run is still the user's: its decisions stay for
/// the Host that can, unlike those of a Plugin that is gone.
final class UnavailablePluginLaunchTests: XCTestCase {
    private static let probe = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CandidateProbe.spinnetplugin", isDirectory: true)
    private static let probeID = PluginID("com.example.candidate-probe")

    func testDecisionsOfAnUnavailablePluginSurviveTheLaunchAndThoseOfAGoneOneDoNot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let grants = PluginCapabilityGrantStore()
        let candidate = try JSONDecoder().decode(CandidateContract.self, from: Data(contentsOf: Self.probe
            .deletingLastPathComponent().appendingPathComponent("Candidates/language_probe/r1/candidate.json")))
        let providing = PluginInterfaceContracts(levels: PluginInterfaceContracts.host.levels, candidates: [candidate])
        try PluginInstallationStore(directory: directory, registry: PluginRegistry(contracts: providing),
                                    grants: grants, persistGrants: {}).install(from: Self.probe)
        let gone = PluginID("com.example.gone")
        for pluginID in [Self.probeID, gone] {
            grants.setDecision(.granted, for: pluginID, pluginVersion: "1.0.0", capability: .readSelectedText)
        }

        let registry = PluginRegistry(contracts: .host)
        try PluginInstallationStore(directory: directory, registry: registry, grants: grants,
                                    persistGrants: {}).restore()
        StoredDataMigration.reconcileCapabilityGrants(grants, with: registry, discardingOthers: true)

        XCTAssertEqual(registry.unavailablePlugins().map(\.id), [Self.probeID])
        XCTAssertEqual(grants.decision(for: Self.probeID, pluginVersion: "1.0.0", capability: .readSelectedText),
                       .granted)
        XCTAssertEqual(grants.decision(for: gone, pluginVersion: "1.0.0", capability: .readSelectedText),
                       .notDetermined)
    }
}
