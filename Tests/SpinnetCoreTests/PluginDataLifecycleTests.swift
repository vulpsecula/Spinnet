import Foundation
import SpinnetTestSupport
import XCTest
@testable import SpinnetCore

final class PluginDataLifecycleTests: XCTestCase {
    private final class FailingCredentials: PluginCredentialStore {
        let backing: InMemoryPluginCredentialStore
        var failRemoval = true
        init(_ backing: InMemoryPluginCredentialStore) { self.backing = backing }
        func secret(for pluginID: PluginID, reference: String) throws -> String? { try backing.secret(for: pluginID, reference: reference) }
        func setSecret(_ secret: String, for pluginID: PluginID, reference: String) throws { try backing.setSecret(secret, for: pluginID, reference: reference) }
        func removeSecret(for pluginID: PluginID, reference: String) throws { try backing.removeSecret(for: pluginID, reference: reference) }
        func removeAllSecrets(for pluginID: PluginID) throws {
            if failRemoval { throw ConfigurationError.persistence("Test failure") }
            try backing.removeAllSecrets(for: pluginID)
        }
        func pluginIDsWithSecrets() throws -> [PluginID] { try backing.pluginIDsWithSecrets() }
    }
    private var directory: URL!
    private var registry: PluginRegistry!
    private var grants: PluginCapabilityGrantStore!
    private var storage: PluginStorage!
    private var settings: PluginSettingsStore!
    private var credentials: InMemoryPluginCredentialStore!
    private var store: PluginInstallationStore!
    private let id = PluginReleaseFixture.pluginID

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        credentials = InMemoryPluginCredentialStore()
        try launch()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func launch() throws {
        registry = PluginRegistry()
        grants = PluginCapabilityGrantStore()
        storage = PluginStorage(directory: directory.appendingPathComponent("Storage"))
        settings = try PluginSettingsStore(fileURL: directory.appendingPathComponent("Settings.json"))
        store = PluginInstallationStore(directory: directory.appendingPathComponent("Plugins"), registry: registry,
                                        grants: grants, persistGrants: {}, storage: storage,
                                        settings: settings, credentials: credentials)
        try store.restore()
    }

    private func package(_ version: String = "1.0.0") throws -> URL {
        try PluginReleaseFixture.package(PluginReleaseFixture.manifest(version: version), in: directory)
    }

    private func populate() throws {
        try settings.setValues(["language": .string("zh")], for: id)
        try storage.setValue(.string("saved"), forKey: "item", of: id)
        try credentials.setSecret("secret", for: id, reference: "key")
        grants.setDecision(.granted, for: id, pluginVersion: "1.0.0", capability: .writeClipboard)
    }

    func testSourceIsPersistedAndLegacyInstallDoesNotPretendItsUpdateSourceWasItsSource() throws {
        let path = try package()
        let installed = directory.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: path, to: installed.appendingPathComponent("legacy.spinnetplugin"))
        try JSONEncoder().encode([id.rawValue: "legacy.spinnetplugin"]).write(to: installed.appendingPathComponent("installed.json"))
        try launch()
        XCTAssertEqual(store.installationSource(for: id), .unknown)

        let github = try PluginUpdateSource(github: PluginReleaseFixture.repository)
        try store.install(from: path, source: .github(github))
        try launch()
        XCTAssertEqual(store.installationSource(for: id), .github(github))
        try store.install(from: path, source: .localFile)
        try launch()
        XCTAssertEqual(store.installationSource(for: id), .localFile)
    }

    func testRemovalCanKeepDataAcrossLaunchAndReinstallButForgetsAccess() throws {
        try store.install(from: package())
        try populate()
        let oldGeneration = storage.generation(for: id)
        try store.uninstall(id, keepingData: true)
        XCTAssertNil(registry.package(for: id))
        XCTAssertEqual(grants.decision(for: id, pluginVersion: "1.0.0", capability: .writeClipboard), .notDetermined)
        let lateWrite: JSONValue = .object(["key": .string("late"), "value": .string("old")])
        XCTAssertThrowsError(try storage.answer(.setStorageValue, input: lateWrite, for: id, generation: oldGeneration))

        try launch()
        XCTAssertEqual(try store.retainedPluginData().map(\.id), [id])
        try store.install(from: package("1.1.0"))
        XCTAssertEqual(settings.values(for: id)["language"], .string("zh"))
        XCTAssertEqual(try storage.value(forKey: "item", of: id), .string("saved"))
        XCTAssertEqual(try credentials.secret(for: id, reference: "key"), "secret")
        XCTAssertEqual(grants.decision(for: id, pluginVersion: "1.1.0", capability: .writeClipboard), .notDetermined)
        XCTAssertEqual(try store.retainedPluginData(), [])
    }

    func testRemovalWithoutKeepingDataClearsSettingsStorageCredentialsAndAccess() throws {
        try store.install(from: package())
        try populate()
        try store.uninstall(id, keepingData: false)
        XCTAssertFalse(settings.hasValues(for: id))
        XCTAssertEqual(try storage.keys(of: id), [])
        XCTAssertNil(try credentials.secret(for: id, reference: "key"))
        XCTAssertEqual(grants.decision(for: id, pluginVersion: "1.0.0", capability: .writeClipboard), .notDetermined)
        try launch()
        XCTAssertEqual(try store.retainedPluginData(), [])
    }

    func testClearingInstalledPluginDataKeepsThePackageAndRevokesItsRunningWork() throws {
        try store.install(from: package())
        try populate()
        var invalidated: [PluginID] = []
        let observation = registry.observeInvalidation { invalidated.append($0) }
        defer { registry.removeInvalidationObserver(observation) }

        try store.clearPluginData(id)

        XCTAssertNotNil(registry.package(for: id))
        XCTAssertTrue(registry.isEnabled(for: id))
        XCTAssertEqual(invalidated, [id])
        XCTAssertFalse(settings.hasValues(for: id))
        XCTAssertEqual(try storage.keys(of: id), [])
        XCTAssertNil(try credentials.secret(for: id, reference: "key"))
        XCTAssertEqual(grants.decision(for: id, pluginVersion: "1.0.0", capability: .writeClipboard), .notDetermined)
        XCTAssertEqual(store.installationSource(for: id), .localFile)
    }

    func testKeptDataCanBeClearedAfterRemovalAndAnotherLaunch() throws {
        try store.install(from: package())
        try populate()
        try store.uninstall(id, keepingData: true)
        try launch()
        try store.clearPluginData(id)
        XCTAssertEqual(try store.retainedPluginData(), [])
        XCTAssertFalse(settings.hasValues(for: id))
        XCTAssertEqual(try storage.keys(of: id), [])
        XCTAssertNil(try credentials.secret(for: id, reference: "key"))
    }

    func testHistoricalSettingsAndCredentialsRemainDiscoverableAfterOldRemoval() throws {
        let settingsID = PluginID("old.settings")
        let credentialsID = PluginID("old.credentials")
        try settings.setValues(["value": .string("saved")], for: settingsID)
        try credentials.setSecret("secret", for: credentialsID, reference: "key")
        XCTAssertEqual(Set(try store.retainedPluginData().map(\.id)), [settingsID, credentialsID])
        try store.clearPluginData(settingsID)
        try store.clearPluginData(credentialsID)
        XCTAssertEqual(try store.retainedPluginData(), [])
    }

    func testRemovalCleanupFailureRemainsVisibleAndCanBeRetried() throws {
        try store.install(from: package())
        try populate()
        let failing = FailingCredentials(credentials)
        store = PluginInstallationStore(directory: directory.appendingPathComponent("Plugins"), registry: registry,
                                        grants: grants, persistGrants: {}, storage: storage,
                                        settings: settings, credentials: failing)
        XCTAssertThrowsError(try store.uninstall(id))
        XCTAssertNil(registry.package(for: id))
        XCTAssertEqual(try store.retainedPluginData().map(\.id), [id])
        XCTAssertEqual(try credentials.secret(for: id, reference: "key"), "secret")
        failing.failRemoval = false
        try store.clearPluginData(id)
        XCTAssertNil(try credentials.secret(for: id, reference: "key"))
        XCTAssertEqual(try store.retainedPluginData(), [])
    }

    func testClearingDataDoesNotEnableADisabledPlugin() throws {
        try store.install(from: package())
        try registry.setEnabled(false, for: id)
        try store.clearPluginData(id)
        XCTAssertFalse(registry.isEnabled(for: id))
        XCTAssertNotNil(registry.package(for: id))
    }

    func testLateStorageWriteCannotRecreateDataAfterHostClearsIt() throws {
        try store.install(from: package())
        try populate()
        let oldGeneration = storage.generation(for: id)
        try store.clearPluginData(id)
        let input: JSONValue = .object(["key": .string("late"), "value": .string("old")])
        XCTAssertThrowsError(try storage.answer(.setStorageValue, input: input, for: id, generation: oldGeneration))
        XCTAssertEqual(try storage.keys(of: id), [])
        let newGeneration = storage.generation(for: id)
        _ = try storage.answer(.setStorageValue, input: input, for: id, generation: newGeneration)
        XCTAssertEqual(try storage.value(forKey: "late", of: id), .string("old"))
    }

    func testPluginCanKeepUsingStorageAfterItsOwnClearRequest() throws {
        let generation = storage.generation(for: id)
        _ = try storage.answer(.clearStorage, input: .null, for: id, generation: generation)
        let input: JSONValue = .object(["key": .string("new"), "value": .string("value")])
        _ = try storage.answer(.setStorageValue, input: input, for: id, generation: generation)
        XCTAssertEqual(try storage.value(forKey: "new", of: id), .string("value"))
    }
}
