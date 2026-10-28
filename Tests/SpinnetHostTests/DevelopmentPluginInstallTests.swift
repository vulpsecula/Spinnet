#if DEBUG
import XCTest
import SpinnetCore
import SpinnetTestSupport
@testable import SpinnetHost

/// The launcher's development install: every package in a directory goes
/// through the install-and-update path the Library takes, into the saved data
/// a launch then reads.
final class DevelopmentPluginInstallTests: XCTestCase {
    private var dataDirectory: URL!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        dataDirectory = temporary("SpinnetData")
        defaultsSuite = "DevelopmentPluginInstallTests-\(UUID())"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    private func temporary(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func installer() throws -> DevelopmentPluginInstall {
        DevelopmentPluginInstall(dataDirectory: dataDirectory,
                                 defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuite)))
    }

    /// A directory holding copies of official Plugin fixtures, each with the
    /// given version.
    private func packages(_ versions: [String: String], in directory: URL? = nil) throws -> URL {
        let directory = directory ?? temporary("Packages")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, version) in versions {
            let source = try OfficialPluginFixtures.named(name).rootURL
            let copy = directory.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: source, to: copy)
            let manifest = copy.appendingPathComponent("manifest.json")
            var fields = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            fields["version"] = version
            try JSONSerialization.data(withJSONObject: fields).write(to: manifest)
        }
        return directory
    }

    /// What a launch would register from the saved data.
    private func launchedRegistry() throws -> PluginRegistry {
        let registry = PluginRegistry()
        try PluginInstallationStore(directory: dataDirectory.appendingPathComponent("Plugins"), registry: registry,
                                    grants: PluginCapabilityGrantStore(), persistGrants: {}).restore()
        return registry
    }

    func testEveryPackageInTheDirectoryIsInstalledAndReportedWithItsVersion() throws {
        let directory = try packages(["Keep Awake": "1.0.0", "Screenshot": "1.0.0"])

        let report = try installer().installPackages(in: directory)

        XCTAssertEqual(report.lines, [
            "installed com.spinnet.coffee 1.0.0, asks for keep_awake, read_frontmost_app",
            "installed com.spinnet.builtin.screenshot 1.0.0, asks for capture_screen"
        ], "Packages install in the order of their file names")
        XCTAssertFalse(report.failed)
        let registry = try launchedRegistry()
        XCTAssertEqual(registry.package(for: PluginID("com.spinnet.coffee"))?.manifest.version, "1.0.0")
        XCTAssertEqual(registry.package(for: PluginID("com.spinnet.builtin.screenshot"))?.manifest.version, "1.0.0")
        XCTAssertEqual(try installer().installedPlugins().lines, [
            "com.spinnet.builtin.screenshot 1.0.0 Screenshot",
            "com.spinnet.coffee 1.0.0 Keep Awake"
        ])
    }

    /// A SpinnetPlugins checkout keeps its packages under `Plugins/`.
    func testACheckoutsPluginsFolderIsRead() throws {
        let checkout = temporary("SpinnetPlugins")
        _ = try packages(["Screenshot": "1.0.0"], in: checkout.appendingPathComponent("Plugins"))

        let report = try installer().installPackages(in: checkout)

        XCTAssertEqual(report.lines, ["installed com.spinnet.builtin.screenshot 1.0.0, asks for capture_screen"])
    }

    func testANewerPackageUpdatesThePluginKeepingItsStorageAndDecisions() throws {
        _ = try installer().installPackages(in: packages(["Keep Awake": "1.0.0"]))
        let pluginID = PluginID("com.spinnet.coffee")
        let storage = PluginStorage(directory: dataDirectory.appendingPathComponent("PluginStorage"))
        try storage.setValue(.string("kept"), forKey: "state", of: pluginID)
        let package = try OfficialPluginFixtures.named("Keep Awake")
        let grants = PluginCapabilityGrantStore()
        let grantsURL = dataDirectory.appendingPathComponent("capability-grants.json")
        try StoredDataMigration.restoreCapabilityGrants(from: Data(contentsOf: grantsURL), into: grants)
        grants.setDecision(.granted, for: pluginID, pluginVersion: "1.0.0", capability: .keepAwake,
                           scope: package.manifest.scope(for: .keepAwake))
        try StoredDataMigration.encodeCapabilityGrants(grants).write(to: grantsURL)

        let report = try installer().installPackages(in: packages(["Keep Awake": "1.1.0"]))

        XCTAssertEqual(report.lines, ["updated com.spinnet.coffee 1.0.0 -> 1.1.0, asks for read_frontmost_app"],
                       "Only the Capability nobody decided on is left to ask for")
        XCTAssertEqual(try launchedRegistry().package(for: pluginID)?.manifest.version, "1.1.0")
        XCTAssertEqual(try storage.value(forKey: "state", of: pluginID), .string("kept"))
        let saved = PluginCapabilityGrantStore()
        try StoredDataMigration.restoreCapabilityGrants(from: Data(contentsOf: grantsURL), into: saved)
        XCTAssertEqual(saved.decision(for: pluginID, pluginVersion: "1.1.0", capability: .keepAwake,
                                      scope: package.manifest.scope(for: .keepAwake)), .granted)
    }

    func testARefusedPackageIsReportedAndTheOthersStillInstall() throws {
        let directory = try packages(["Screenshot": "1.0.0"])
        let broken = directory.appendingPathComponent("Broken.spinnetplugin")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: broken.appendingPathComponent("manifest.json"))

        let report = try installer().installPackages(in: directory)

        XCTAssertTrue(report.failed)
        XCTAssertEqual(report.lines.count, 2)
        XCTAssertTrue(report.lines[0].hasPrefix("refused Broken.spinnetplugin: "), report.lines[0])
        XCTAssertEqual(report.lines[1], "installed com.spinnet.builtin.screenshot 1.0.0, asks for capture_screen")
        XCTAssertNotNil(try launchedRegistry().package(for: PluginID("com.spinnet.builtin.screenshot")))
    }

    func testADirectoryWithoutPackagesIsAnError() throws {
        XCTAssertThrowsError(try installer().installPackages(in: temporary("Empty")))
    }
}
#endif
