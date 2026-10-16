import Foundation
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// An isolated copy of a Bundled Plugin's saved user data for one test.
/// Each suite keeps its own semantic assertions about migration and removal.
final class BundledRegressionFixture {
    let directory: URL
    let defaultsSuite: String

    init(baseline: URL) throws {
        let name = "\(baseline.lastPathComponent)Baseline-\(UUID())"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defaultsSuite = name
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for name in ["configuration.json", "capability-grants.json", "PluginSettings.json"] {
                try FileManager.default.copyItem(at: baseline.appendingPathComponent(name),
                                                to: directory.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func cleanup() throws {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try FileManager.default.removeItem(at: directory)
    }

    func restoredGrants() throws -> PluginCapabilityGrantStore {
        let grants = PluginCapabilityGrantStore()
        try StoredDataMigration.restoreCapabilityGrants(
            from: Data(contentsOf: directory.appendingPathComponent("capability-grants.json")), into: grants)
        return grants
    }

    func configuration() throws -> HostConfiguration {
        try XCTUnwrap(HostConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json")).load())
    }
}
