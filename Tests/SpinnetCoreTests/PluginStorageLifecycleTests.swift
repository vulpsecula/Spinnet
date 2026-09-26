import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// What happens to a Plugin's Plugin Storage as the Plugin is installed,
/// updated, removed and installed again, shown with the Storage Counter
/// fixture Plugin used for the manual check.
final class PluginStorageLifecycleTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/StorageCounter.spinnetplugin", isDirectory: true)
    private let counterID = PluginID("com.example.storage-counter")

    private func temporaryDirectory(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeInstallation() -> (PluginRegistry, PluginStorage, PluginInstallationStore) {
        let registry = PluginRegistry()
        let storage = PluginStorage(directory: temporaryDirectory("PluginStorage"))
        return (registry, storage, PluginInstallationStore(
            directory: temporaryDirectory("Plugins"), registry: registry, grants: PluginCapabilityGrantStore(),
            persistGrants: {}, storage: storage
        ))
    }

    /// A copy of the fixture at `version`, as an update would bring it.
    private func fixture(version: String) throws -> URL {
        let copy = temporaryDirectory("StorageCounter").appendingPathComponent("StorageCounter.spinnetplugin")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixture, to: copy)
        let manifest = copy.appendingPathComponent("manifest.json")
        try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(of: "\"version\": \"1.0.0\"", with: "\"version\": \"\(version)\"")
            .write(to: manifest, atomically: true, encoding: .utf8)
        return copy
    }

    // MARK: - The fixture Plugin

    /// The user installs the fixture through the Library, so it must be a
    /// package any Plugin author could write.
    func testTheFixtureIsAnOrdinaryPackage() throws {
        let schema = try JSONSchemaSubsetValidator(schemaAt: Self.fixture
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PluginAPI/schemas/manifest.schema.json"))
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(
            contentsOf: Self.fixture.appendingPathComponent("manifest.json")
        ))
        XCTAssertEqual(schema.errors(for: manifest), [])
        XCTAssertEqual(try PluginManifestLoader.load(packageAt: Self.fixture).manifest.id, counterID)
    }

    func testTheFixtureCountsItsRunsAcrossLaunches() throws {
        let plugin = try PluginUnderTest(packageAt: Self.fixture)
        let directory = temporaryDirectory("PluginStorage")
        var helper = try PluginTestHelper()
        defer { helper.shutdown() }
        func count() throws -> String? {
            try helper.run(PluginTestInvocation("counter.count"), of: plugin,
                           answering: RecordedHostServices(storage: PluginStorage(directory: directory))).answer().toast
        }

        XCTAssertEqual(try count(), "Storage Counter has run 1 time")
        XCTAssertEqual(try count(), "Storage Counter has run 2 times")
        helper.shutdown()
        helper = try PluginTestHelper()
        XCTAssertEqual(try count(), "Storage Counter has run 3 times")
    }

    /// A View Event is an invocation like the Action's start, through the
    /// same runner and broker, so it reaches the same Plugin Storage.
    func testAViewEventReachesTheSameStorageThroughTheHostsBroker() throws {
        let plugin = try PluginUnderTest(packageAt: Self.fixture)
        let registry = PluginRegistry()
        try registry.register(plugin.package)
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let storage = PluginStorage(directory: temporaryDirectory("PluginStorage"))
        let runner = HostActionRunner(
            executor: NoHostCommands(), scriptedExecutor: helper,
            hostServiceBroker: CapabilityCheckedHostServiceBroker(
                grantStore: PluginCapabilityGrantStore(), systemPermissionCheck: { _ in false },
                selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, pluginStorage: storage
            )
        )
        let action = try plugin.action(for: PluginTestInvocation("counter.count"))
        func toast(delivering delivery: ViewEventDelivery) throws -> String? {
            guard case .succeeded(let answer) = runner.invoke(action, using: registry, delivering: delivery).terminal else {
                XCTFail("The fixture failed")
                return nil
            }
            return try PluginScriptAnswer(parsing: answer).toast
        }

        XCTAssertEqual(try toast(delivering: .actionStart), "Storage Counter has run 1 time")
        XCTAssertEqual(try toast(delivering: ViewEventDelivery(event: .submitted(values: .null), state: .null)),
                       "Storage Counter has run 2 times")
        XCTAssertEqual(try storage.value(forKey: "runs", of: counterID), .number(2))
    }

    func testTheFixtureCatchesTheRefusalOfAValueOverTheLimit() throws {
        let plugin = try PluginUnderTest(packageAt: Self.fixture)
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let storage = PluginStorage(directory: temporaryDirectory("PluginStorage"))

        let answer = try helper.run(PluginTestInvocation("counter.overfill"), of: plugin,
                                    answering: RecordedHostServices(storage: storage)).answer()

        let toast = try XCTUnwrap(answer.toast)
        XCTAssertTrue(toast.hasPrefix("Storage Counter was refused (storage_limit_exceeded): "), toast)
        XCTAssertTrue(toast.contains("512 KiB"), toast)
        XCTAssertEqual(try storage.keys(of: counterID), [])
    }

    // MARK: - Installation

    func testRemovingAPluginDeletesItsStorageAndLeavesOthers() throws {
        let (_, storage, installation) = makeInstallation()
        let manifest = try installation.install(from: Self.fixture)
        try storage.setValue(.number(3), forKey: "runs", of: manifest.id)
        let other = PluginID("com.example.other")
        try storage.setValue(.number(1), forKey: "runs", of: other)

        try installation.uninstall(manifest.id)

        XCTAssertEqual(try storage.keys(of: manifest.id), [])
        XCTAssertEqual(storage.usage(of: manifest.id), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.directory(of: manifest.id).path))
        XCTAssertEqual(try storage.value(forKey: "runs", of: other), .number(1))
    }

    func testRemovingABundledPluginDeletesItsStorage() throws {
        let (registry, storage, installation) = makeInstallation()
        let loaded = try PluginManifestLoader.load(packageAt: Self.fixture)
        try registry.register(PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled))
        try storage.setValue(.number(3), forKey: "runs", of: counterID)

        try installation.uninstall(counterID)

        XCTAssertEqual(try storage.keys(of: counterID), [])
    }

    func testAnUpdateKeepsTheStorage() throws {
        let (registry, storage, installation) = makeInstallation()
        try installation.install(from: Self.fixture)
        try storage.setValue(.number(3), forKey: "runs", of: counterID)

        try installation.install(from: fixture(version: "1.1.0"))

        XCTAssertEqual(registry.package(for: counterID)?.manifest.version, "1.1.0")
        XCTAssertEqual(try storage.value(forKey: "runs", of: counterID), .number(3))
        // Installing the same version again is an update too.
        try installation.install(from: fixture(version: "1.1.0"))
        XCTAssertEqual(try storage.value(forKey: "runs", of: counterID), .number(3))
    }

    /// A removed Plugin brought back by installing it again starts empty,
    /// even if something was written for it after it was removed, such as by
    /// a write already on its way when the user removed it.
    func testRestoringARemovedPluginStartsEmpty() throws {
        let (registry, storage, installation) = makeInstallation()
        try installation.install(from: Self.fixture)
        try storage.setValue(.number(3), forKey: "runs", of: counterID)
        try installation.uninstall(counterID)
        try storage.setValue(.number(4), forKey: "late", of: counterID)

        try installation.install(from: Self.fixture)

        XCTAssertNotNil(registry.package(for: counterID))
        XCTAssertEqual(try storage.keys(of: counterID), [])
    }

    /// A refused install leaves what the registered Plugin keeps alone.
    func testARefusedInstallLeavesTheStorageAlone() throws {
        let (registry, storage, installation) = makeInstallation()
        let loaded = try PluginManifestLoader.load(packageAt: Self.fixture)
        try registry.register(PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled))
        try storage.setValue(.number(3), forKey: "runs", of: counterID)

        XCTAssertThrowsError(try installation.install(from: Self.fixture))

        XCTAssertEqual(try storage.value(forKey: "runs", of: counterID), .number(3))
    }
}

private struct NoHostCommands: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}
