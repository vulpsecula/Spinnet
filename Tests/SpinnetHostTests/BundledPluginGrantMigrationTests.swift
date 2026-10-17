import XCTest
import SpinnetCore
import SpinnetTestSupport
@testable import SpinnetHost

final class BundledPluginGrantMigrationTests: XCTestCase {
    private var directory: URL!
    private var shipped: PluginPackage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        shipped = try ShippedPluginPackages.named("System Monitor")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testUserInstalledCandidateGrantSurvivesMigrationToNewBundledVersion() throws {
        let previous = try package(version: "1.2.0", candidate: true)
        try seedInstalled(previous)
        try saveDecision(.granted, for: previous.manifest)

        let (registry, grants) = try launch(shipped)

        XCTAssertEqual(decision(grants, for: previous.manifest), .granted)
        XCTAssertEqual(decision(grants, for: shipped.manifest), .granted)
        XCTAssertEqual(registry.package(for: shipped.manifest.id)?.origin, .bundled)
        XCTAssertEqual(registry.availability(for: try action(shipped.manifest)), .available)
    }

    func testNextBundledVersionInheritsTheLastShippedVersionsDecision() throws {
        _ = try launch(shipped)
        try saveDecision(.granted, for: shipped.manifest)
        let replacement = try package(version: "1.4.0")

        let (registry, grants) = try launch(replacement)

        XCTAssertEqual(decision(grants, for: replacement.manifest), .granted)
        XCTAssertEqual(registry.availability(for: try action(replacement.manifest)), .available)
    }

    func testDeniedAccessSurvivesOnboardingAndTheNextBundledUpdate() throws {
        let previous = try package(version: "1.2.0", candidate: true)
        try seedInstalled(previous)
        try saveDecision(.denied, for: previous.manifest)
        let (_, onboarded) = try launch(shipped)
        XCTAssertEqual(decision(onboarded, for: shipped.manifest), .denied)

        let next = try package(version: "1.4.0")
        let (registry, grants) = try launch(next)
        XCTAssertEqual(decision(grants, for: next.manifest), .denied)
        XCTAssertEqual(registry.availability(for: try action(next.manifest)), .unavailable(.capabilityDenied))
    }

    func testAnExistingReplacementDecisionTakesPriorityOverThePredecessor() throws {
        let previous = try package(version: "1.2.0", candidate: true)
        try seedInstalled(previous)
        try saveDecision(.granted, for: previous.manifest)
        try saveDecision(.denied, for: shipped.manifest)

        let (_, denied) = try launch(shipped)
        XCTAssertEqual(decision(denied, for: shipped.manifest), .denied)

        try saveDecision(.denied, for: previous.manifest)
        try saveDecision(.granted, for: shipped.manifest)
        let (_, granted) = try launch(shipped)
        XCTAssertEqual(decision(granted, for: shipped.manifest), .granted)
    }

    func testChangedScopeRequiresConsentAndDoesNotResurrectAnOlderMatchingGrant() throws {
        _ = try launch(shipped)
        try saveDecision(.granted, for: shipped.manifest)
        let expanded = try package(version: "1.4.0", extraCommand: true)

        let (registry, grants) = try launch(expanded)
        XCTAssertEqual(decision(grants, for: expanded.manifest), .notDetermined)
        XCTAssertEqual(registry.availability(for: try action(expanded.manifest)), .unavailable(.capabilityDenied))

        try saveDecision(.denied, for: expanded.manifest)
        let contracted = try package(version: "1.5.0")
        let (_, later) = try launch(contracted)
        XCTAssertEqual(decision(later, for: contracted.manifest), .notDetermined,
                       "Compare against the last shipped declaration, not the older 1.3.0 grant")
    }

    func testFailureToPersistInheritedAccessLeavesTheTransitionRetryable() throws {
        _ = try launch(shipped)
        try saveDecision(.granted, for: shipped.manifest)
        let replacement = try package(version: "1.4.0")

        XCTAssertThrowsError(try launch(replacement, failingPersistence: true))

        let (_, retried) = try launch(replacement)
        XCTAssertEqual(decision(retried, for: replacement.manifest), .granted)
    }

    func testDevelopmentLaunchWithoutBundledPluginsKeepsTheKnownPredecessor() throws {
        _ = try launch(shipped)
        try saveDecision(.granted, for: shipped.manifest)
        _ = try launch(nil, discardingOthers: false)
        let replacement = try package(version: "1.4.0")

        let (_, grants) = try launch(replacement)

        XCTAssertEqual(decision(grants, for: replacement.manifest), .granted)
    }

    func testLegacyOnboardingDoesNotReviveAccessWhenThePredecessorIsAmbiguous() throws {
        let installed = try package(version: "1.2.0", candidate: true)
        try seedInstalled(installed)
        try saveDecision(.granted, for: installed.manifest)
        // An older Host may have shipped 1.3.0 without recording its manifest,
        // leaving the installed 1.2.0 copy underneath it after a revocation.
        try saveDecision(.denied, for: shipped.manifest)
        let replacement = try package(version: "1.4.0")

        let (registry, grants) = try launch(replacement)

        XCTAssertEqual(decision(grants, for: replacement.manifest), .notDetermined)
        XCTAssertEqual(registry.availability(for: try action(replacement.manifest)), .unavailable(.capabilityDenied))
    }

    private var pluginsDirectory: URL { directory.appendingPathComponent("Plugins") }
    private var grantsURL: URL { directory.appendingPathComponent("grants.json") }

    private func package(version: String, candidate: Bool = false, extraCommand: Bool = false) throws -> PluginPackage {
        let root = directory.appendingPathComponent("package-\(version).spinnetplugin")
        try FileManager.default.copyItem(at: shipped.rootURL, to: root)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(shipped.manifest)) as? [String: Any])
        object["version"] = version
        if candidate {
            object["api_level"] = 2
            object["candidate_contracts"] = [["name": "adaptive_layout", "revision": 2]]
        }
        if extraCommand {
            var commands = try XCTUnwrap(object["commands"] as? [[String: Any]])
            var extra = try XCTUnwrap(commands.first)
            extra["id"] = "monitor.extra"
            commands.append(extra)
            object["commands"] = commands
            var scopes = try XCTUnwrap(object["capability_scopes"] as? [[String: Any]])
            scopes[0]["command_ids"] = ["monitor.show", "monitor.extra"]
            object["capability_scopes"] = scopes
        }
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("manifest.json"))
        let loaded = try PluginManifestLoader.load(packageAt: root)
        return PluginPackage(rootURL: root, manifest: loaded.manifest, origin: .bundled)
    }

    private func seedInstalled(_ package: PluginPackage) throws {
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let name = "previous.spinnetplugin"
        try FileManager.default.copyItem(at: package.rootURL, to: pluginsDirectory.appendingPathComponent(name))
        try JSONEncoder().encode([package.manifest.id.rawValue: name])
            .write(to: pluginsDirectory.appendingPathComponent("installed.json"))
    }

    private func saveDecision(_ decision: PluginCapabilityGrantDecision, for manifest: PluginManifest) throws {
        let grants = PluginCapabilityGrantStore()
        if FileManager.default.fileExists(atPath: grantsURL.path) {
            try StoredDataMigration.restoreCapabilityGrants(from: Data(contentsOf: grantsURL), into: grants)
        }
        grants.setDecision(decision, for: manifest.id, pluginVersion: manifest.version,
                           capability: .readSystemStatus, scope: manifest.scope(for: .readSystemStatus))
        try StoredDataMigration.encodeCapabilityGrants(grants).write(to: grantsURL)
    }

    private enum PersistenceFailure: Error { case simulated }

    private func launch(_ package: PluginPackage?, failingPersistence: Bool = false,
                        discardingOthers: Bool = true) throws -> (PluginRegistry, PluginCapabilityGrantStore) {
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        if let package { try registry.register(package) }
        if FileManager.default.fileExists(atPath: grantsURL.path) {
            try StoredDataMigration.restoreCapabilityGrants(from: Data(contentsOf: grantsURL), into: grants)
        }
        let grantsURL = self.grantsURL
        let persist = {
            if failingPersistence { throw PersistenceFailure.simulated }
            try StoredDataMigration.encodeCapabilityGrants(grants).write(to: grantsURL, options: .atomic)
        }
        let store = PluginInstallationStore(directory: pluginsDirectory, registry: registry,
                                             grants: grants, persistGrants: persist)
        try store.restore()
        StoredDataMigration.reconcileCapabilityGrants(grants, with: registry.manifests(), discardingOthers: discardingOthers)
        try persist()
        return (registry, grants)
    }

    private func decision(_ grants: PluginCapabilityGrantStore, for manifest: PluginManifest) -> PluginCapabilityGrantDecision {
        grants.decision(for: manifest.id, pluginVersion: manifest.version, capability: .readSystemStatus,
                        scope: manifest.scope(for: .readSystemStatus))
    }

    private func action(_ manifest: PluginManifest) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("monitor"), pluginID: manifest.id,
                                command: XCTUnwrap(manifest.commands.first), input: .null)
    }
}
