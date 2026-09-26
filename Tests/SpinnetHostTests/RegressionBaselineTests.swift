import SpinnetCore
import XCTest
@testable import SpinnetHost

/// The regression baseline for the six Bundled Plugins (#48). The fixtures in
/// `Tests/RegressionBaseline` are user data in the formats the Host writes;
/// they go through the steps a launch takes and must come out as they went
/// in, and the checklist beside them must name every Command and Plugin
/// Setting the Plugins declare.
final class RegressionBaselineTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let baseline = repository.appendingPathComponent("Tests/RegressionBaseline")
    private static let pluginIDs = Set([
        "com.spinnet.translator", "com.spinnet.smart-jump", "com.spinnet.window-position",
        "com.spinnet.clipboard-history", "com.spinnet.bob", "com.spinnet.shottr"
    ].map { PluginID($0) })

    private var directory: URL!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RegressionBaselineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["configuration.json", "PluginSettings.json", "capability-grants.json"] {
            try FileManager.default.copyItem(at: Self.baseline.appendingPathComponent(name),
                                             to: directory.appendingPathComponent(name))
        }
        defaultsSuite = "RegressionBaselineTests-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    func testConfigurationLoadsThroughTheLaunchStepsUnchanged() throws {
        let grants = try restoredGrants()
        let registry = try registry(grantStore: grants)
        let settings = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        let settingsBefore = try Data(contentsOf: settings.fileURL)
        let store = HostConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json"))
        let stored = try XCTUnwrap(store.load())

        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let migrated = try StoredDataMigration.migrate(stored, registry: registry, pluginSettings: settings,
                                                       defaults: defaults)

        XCTAssertEqual(migrated, stored, "a launch would rewrite the configuration")
        XCTAssertEqual(try Data(contentsOf: settings.fileURL), settingsBefore, "a launch would rewrite Plugin Settings")
        XCTAssertTrue(defaults.persistentDomain(forName: defaultsSuite)?.isEmpty ?? true,
                      "a launch would seed Screenshot Plugin Settings")

        try store.save(migrated)
        XCTAssertEqual(try store.load(), stored)
        try assertSameJSON(directory.appendingPathComponent("configuration.json"), "configuration.json")
    }

    /// `TranslatorVersion1/` holds the baseline's Translator Menu Item and
    /// Plugin Settings as Translator 1 wrote them. The launch steps apply the
    /// Translator manifest's `migrations` and must turn them into exactly the
    /// baseline's Translator Actions, and a second launch must change nothing.
    func testTranslatorVersionOneDataMigratesToTheBaselineAndStaysThere() throws {
        let version1 = Self.baseline.appendingPathComponent("TranslatorVersion1")
        for name in ["configuration.json", "PluginSettings.json"] {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            try FileManager.default.copyItem(at: version1.appendingPathComponent(name),
                                             to: directory.appendingPathComponent(name))
        }
        let translator = PluginID("com.spinnet.translator")
        let registry = try registry(grantStore: try restoredGrants())
        let settings = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        let stored = try XCTUnwrap(HostConfigurationStore(
            fileURL: directory.appendingPathComponent("configuration.json")
        ).load())
        let baseline = try XCTUnwrap(HostConfigurationStore(
            fileURL: Self.baseline.appendingPathComponent("configuration.json")
        ).load())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))

        let migrated = try StoredDataMigration.migrate(stored, registry: registry, pluginSettings: settings,
                                                       defaults: defaults)

        XCTAssertEqual(migrated.actions, baseline.actions.filter { $0.pluginID == translator })
        XCTAssertEqual(migrated.menu, stored.menu, "Slots, aliases and Alternate Actions are kept")
        XCTAssertEqual(settings.values(for: translator), [
            "deepl_credential": .string("deepl"), "deepl_endpoint": .string("https://api.deepl.com"),
            "formality": .string("prefer_less"), "target_language": .string("ZH-HANS")
        ], "Version 1's DeepL endpoint and key reference carry over, and the target language stays in Plugin Settings")
        for action in migrated.actions {
            XCTAssertEqual(registry.availability(for: action), .available, action.commandID.rawValue)
        }

        let settingsAfterOneLaunch = try Data(contentsOf: settings.fileURL)
        XCTAssertEqual(try StoredDataMigration.migrate(migrated, registry: registry, pluginSettings: settings,
                                                       defaults: defaults), migrated)
        XCTAssertEqual(try Data(contentsOf: settings.fileURL), settingsAfterOneLaunch)
    }

    func testConfigurationHoldsAnActionForEveryCommandAndEveryOneIsAvailable() throws {
        let grants = try restoredGrants()
        let settings = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        let accounts = try keychainAccounts()
        let registry = try registry(grantStore: grants, pluginSettingsComplete: { manifest in
            manifest.missingSettings(in: manifest.resolvedSettings(stored: settings.values(for: manifest.id)), hasSecret: {
                accounts.contains(KeychainPluginCredentialStore.account(for: manifest.id, reference: $0))
            }).isEmpty
        })
        let configuration = try XCTUnwrap(HostConfigurationStore(
            fileURL: directory.appendingPathComponent("configuration.json")
        ).load())

        let declared = Set(bundledManifests(in: registry).flatMap { manifest in
            manifest.commands.map { "\(manifest.id.rawValue) \($0.id.rawValue)" }
        })
        XCTAssertEqual(Set(configuration.actions.map { "\($0.pluginID.rawValue) \($0.commandID.rawValue)" }), declared)
        for action in configuration.actions {
            XCTAssertEqual(registry.availability(for: action), .available, action.commandID.rawValue)
        }
    }

    func testPluginSettingsAreAllInUseAndWriteBackUnchanged() throws {
        let registry = try registry()
        let settings = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        for manifest in bundledManifests(in: registry) where manifest.hasSettings {
            let stored = settings.values(for: manifest.id)
            // A stored value a field no longer accepts would be silently
            // replaced by its default.
            XCTAssertEqual(manifest.resolvedSettings(stored: stored), stored, manifest.id.rawValue)
            try settings.setValues(stored, for: manifest.id)
        }
        try assertSameJSON(settings.fileURL, "PluginSettings.json")
    }

    func testCapabilityGrantsReconcileWithTheRegisteredPluginsUnchanged() throws {
        let grants = try restoredGrants()
        let registry = try registry(grantStore: grants)

        StoredDataMigration.reconcileCapabilityGrants(grants, with: registry.manifests(), discardingOthers: true)

        let written = directory.appendingPathComponent("capability-grants.json")
        try StoredDataMigration.encodeCapabilityGrants(grants).write(to: written)
        try assertSameJSON(written, "capability-grants.json")
        let translator = try XCTUnwrap(registry.package(for: PluginID("com.spinnet.translator"))?.manifest)
        let contact = try XCTUnwrap(translator.scope(for: .contactHTTPS))
        XCTAssertEqual(grants.consentedHTTPSHosts(for: translator.id, pluginVersion: translator.version,
                                                  declaredScope: contact), ["llm.example.org"])
    }

    func testCredentialReferencesNameTheRecordedKeychainItems() throws {
        let registry = try registry()
        let settings = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        let recorded = try JSONDecoder().decode(KeychainItems.self, from: Data(
            contentsOf: Self.baseline.appendingPathComponent("keychain-items.json")
        ))
        var accounts: [String] = []
        for manifest in bundledManifests(in: registry) {
            let values = manifest.resolvedSettings(stored: settings.values(for: manifest.id))
            for field in manifest.settingsFields where field.kind == .credential {
                guard let key = field.key, case .string(let reference)? = values[key] else { continue }
                accounts.append(KeychainPluginCredentialStore.account(for: manifest.id, reference: reference))
            }
        }
        XCTAssertEqual(recorded.service, KeychainPluginCredentialStore.defaultService)
        XCTAssertEqual(accounts.sorted(), recorded.accounts.sorted())
    }

    // MARK: Checklist

    func testChecklistNamesEveryCommandAndPluginSetting() throws {
        let checklist = try String(contentsOf: Self.baseline.appendingPathComponent("checklist.md"), encoding: .utf8)
        let manifests = bundledManifests(in: try registry())
        XCTAssertEqual(Set(manifests.map(\.id)), Self.pluginIDs)
        for manifest in manifests {
            for command in manifest.commands {
                XCTAssertTrue(checklist.contains("`\(command.id.rawValue)`"), "checklist misses \(command.id.rawValue)")
            }
            for key in manifest.settingsFields.compactMap(\.key) {
                XCTAssertTrue(checklist.contains("`\(key)`"), "checklist misses \(manifest.name) setting \(key)")
            }
        }
    }

    // MARK: Helpers

    private struct KeychainItems: Decodable {
        let service: String
        let accounts: [String]
    }

    private func restoredGrants() throws -> PluginCapabilityGrantStore {
        let grants = PluginCapabilityGrantStore()
        try StoredDataMigration.restoreCapabilityGrants(
            from: Data(contentsOf: directory.appendingPathComponent("capability-grants.json")), into: grants
        )
        return grants
    }

    private func keychainAccounts() throws -> Set<String> {
        Set(try JSONDecoder().decode(KeychainItems.self, from: Data(
            contentsOf: Self.baseline.appendingPathComponent("keychain-items.json")
        )).accounts)
    }

    /// What a launch registers: every shipped Plugin, read from the
    /// repository as a development run reads it.
    private func registry(
        grantStore: PluginCapabilityGrantStore? = nil,
        pluginSettingsComplete: @escaping (PluginManifest) -> Bool = { _ in true }
    ) throws -> PluginRegistry {
        let registry = PluginRegistry(grantStore: grantStore, externalAppExists: { _ in true },
                                      pluginSettingsComplete: pluginSettingsComplete)
        let plugins = Self.repository.appendingPathComponent("Plugins")
        for url in try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "spinnetplugin" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifest = try PluginManifestLoader.load(packageAt: url).manifest
            try registry.register(PluginPackage(rootURL: url, manifest: manifest, origin: .bundled))
        }
        return registry
    }

    private func bundledManifests(in registry: PluginRegistry) -> [PluginManifest] {
        registry.manifests().filter { Self.pluginIDs.contains($0.id) }
    }

    /// Compares as JSON, so the fixture may be laid out for reading while the
    /// Host writes its own layout.
    private func assertSameJSON(_ written: URL, _ fixture: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: written), options: [.fragmentsAllowed])
        let expected = try JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.baseline.appendingPathComponent(fixture)), options: [.fragmentsAllowed]
        )
        XCTAssertEqual(actual as? NSObject, expected as? NSObject, "\(fixture) did not write back unchanged",
                       file: file, line: line)
    }
}
