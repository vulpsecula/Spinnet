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

    /// The only change a launch makes: Shottr's Commands open Deep Link
    /// Templates now instead of running a script (W8, #55), so its Actions
    /// move onto them, keeping their IDs and inputs.
    func testConfigurationLoadsThroughTheLaunchStepsWithOnlyShottrsActionsMoved() throws {
        let grants = try restoredGrants()
        let registry = try registry(grantStore: grants)
        let settings = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        let settingsBefore = try Data(contentsOf: settings.fileURL)
        let store = HostConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json"))
        let stored = try XCTUnwrap(store.load())

        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let migrated = try StoredDataMigration.migrate(stored, registry: registry, pluginSettings: settings,
                                                       defaults: defaults)

        let expected = try shottrActionsMovedOntoTemplates(stored, registry: registry)
        XCTAssertEqual(migrated, expected, "a launch would rewrite the configuration")
        XCTAssertEqual(migrated.actions.filter { $0.pluginID == PluginID("com.spinnet.shottr") }.count, 8)
        XCTAssertEqual(try Data(contentsOf: settings.fileURL), settingsBefore, "a launch would rewrite Plugin Settings")
        XCTAssertTrue(defaults.persistentDomain(forName: defaultsSuite)?.isEmpty ?? true,
                      "a launch would seed Screenshot Plugin Settings")
        XCTAssertEqual(try StoredDataMigration.migrate(migrated, registry: registry, pluginSettings: settings,
                                                       defaults: defaults), migrated, "a second launch changes nothing")

        try store.save(migrated)
        XCTAssertEqual(try store.load(), expected)
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
        // As a launch does: decisions line up with the Plugins, then the
        // stored Actions are brought up to date.
        StoredDataMigration.reconcileCapabilityGrants(grants, with: registry.manifests(), discardingOthers: true)
        let configuration = try StoredDataMigration.migrate(
            XCTUnwrap(HostConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json")).load()),
            registry: registry, pluginSettings: settings, defaults: XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        )

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
            // replaced by its default. A `list` saved as text before that
            // kind existed loads as its rows instead (#53).
            var expected = stored
            for field in manifest.settingsFields where field.kind == .list {
                guard let key = field.key, case .string(let text)? = stored[key] else { continue }
                expected[key] = try XCTUnwrap(field.listRows(fromText: text), "\(manifest.name) \(key) does not load")
            }
            XCTAssertEqual(manifest.resolvedSettings(stored: stored), expected, manifest.id.rawValue)
            try settings.setValues(stored, for: manifest.id)
        }
        try assertSameJSON(settings.fileURL, "PluginSettings.json")
    }

    /// Smart Jump's engines were stored as text before the `list` kind (#53).
    /// They load as rows in their order, so the first is still the default.
    func testStoredSearchEnginesLoadInTheirOrder() throws {
        let registry = try registry()
        let settings = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        let smartJump = try XCTUnwrap(registry.package(for: PluginID("com.spinnet.smart-jump"))?.manifest)
        let values = smartJump.resolvedSettings(stored: settings.values(for: smartJump.id))
        let engines = try SmartJumpSearchEngine.engines(from: values["search_engines"])
        XCTAssertEqual(engines.map(\.name), ["DuckDuckGo", "Google", "Scholar"])
        XCTAssertEqual(engines.map(\.template), [
            "https://duckduckgo.com/?q={query}", "https://www.google.com/search?q={query}",
            "https://scholar.google.com/scholar?q={query}"
        ])
    }

    /// Every decision survives. Bob's scope is persisted as it was; Shottr's
    /// grant on its reviewed capture routes carries over to its Deep Link
    /// Templates, which open the same links, and is stored with them.
    func testCapabilityGrantsReconcileWithTheRegisteredPluginsAndShottrsCarriesOver() throws {
        let grants = try restoredGrants()
        let registry = try registry(grantStore: grants)

        StoredDataMigration.reconcileCapabilityGrants(grants, with: registry.manifests(), discardingOthers: true)

        let written = directory.appendingPathComponent("capability-grants.json")
        try StoredDataMigration.encodeCapabilityGrants(grants).write(to: written)
        let shottr = try XCTUnwrap(registry.package(for: PluginID("com.spinnet.shottr"))?.manifest)
        let templates = try XCTUnwrap(shottr.scope(for: .controlExternalApp))
        XCTAssertEqual(grants.decision(for: shottr.id, pluginVersion: shottr.version, capability: .controlExternalApp,
                                       scope: templates), .granted)
        var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
            contentsOf: Self.baseline.appendingPathComponent("capability-grants.json")
        )) as? [[String: Any]])
        let index = try XCTUnwrap(expected.firstIndex {
            $0["pluginID"] as? String == shottr.id.rawValue && $0["capability"] as? String == "control_external_app"
        })
        expected[index]["scope"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(templates))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? NSArray,
                       expected as NSArray, "capability-grants.json did not write back as expected")
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

    /// `stored` with each Shottr Action rebuilt from its registered Command,
    /// written out here rather than taken from the migration under test.
    private func shottrActionsMovedOntoTemplates(_ stored: HostConfiguration,
                                                 registry: PluginRegistry) throws -> HostConfiguration {
        try HostConfiguration(actions: stored.actions.map { action in
            guard action.pluginID == PluginID("com.spinnet.shottr") else { return action }
            let command = try XCTUnwrap(registry.command(for: action.pluginID, commandID: action.commandID))
            XCTAssertEqual(command.hostCommand, .openDeepLink)
            return try ActionConfiguration(id: action.id, pluginID: action.pluginID, command: command, input: action.input)
        }, menu: stored.menu)
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
