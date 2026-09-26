import SpinnetCore
import XCTest
@testable import SpinnetHost

/// The settings section of a Plugin's Plugin Settings sheet: the user fills
/// in what every Menu Item from the Plugin shares, from the Library, before
/// placing anything. Saving checks each value, keeps a typed secret in the
/// credential store, and asks for consent to an endpoint host the Plugin did
/// not declare.
final class PluginSettingsModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PluginSettings-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func manifest() throws -> PluginManifest {
        try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "id": "com.example.remote", "name": "Remote", "version": "1.0.0",
          "capabilities": ["contact_https"],
          "capability_scopes": [{"capability": "contact_https", "command_ids": ["remote.run"], "data_types": ["text"],
                                 "includes_existing_host_data": false, "https_hosts": ["api.example.com"], "external_apps": []}],
          "settings_fields": [
            {"key": "endpoint", "kind": "https_endpoint", "title": "Endpoint"},
            {"key": "credential", "kind": "credential", "title": "API Key"},
            {"key": "target", "kind": "choice", "title": "Translate Into", "choices": ["DE", "FR"], "overridable": true}],
          "default_settings": {"endpoint": "https://api.example.com", "credential": "main", "target": "DE"},
          "preset": {"readiness": "ready_to_use", "is_configurable": true, "default_primary_command_id": "remote.run",
                     "default_inputs": {"remote.run": {}}},
          "commands": [{"id": "remote.run", "title": "Run", "execution": "javascript", "is_configurable": true, "script": "run.js"}]
        }
        """.utf8))
    }

    private struct Fixture {
        let model: PluginSettingsModel
        let store: PluginSettingsStore
        let credentials: InMemoryPluginCredentialStore
        let grants: PluginCapabilityGrantStore
        let saves: () -> Int
    }

    private func makeModel(credentials: InMemoryPluginCredentialStore = InMemoryPluginCredentialStore()) throws -> Fixture {
        let manifest = try manifest()
        let store = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        let grants = PluginCapabilityGrantStore()
        var saves = 0
        let model = PluginSettingsModel(
            manifest: manifest, store: store, credentialStore: credentials,
            approveConsent: { consent, allowed in try consent.approve(allowedHosts: allowed, grantStore: grants) },
            consent: { HTTPSEndpointConsent(manifest: manifest, settings: $0, grantStore: grants) },
            onSaved: { saves += 1 }
        )
        return Fixture(model: model, store: store, credentials: credentials, grants: grants, saves: { saves })
    }

    func testTheFormStartsFromTheDefaultsAndNamesWhatIsMissing() throws {
        let fixture = try makeModel()
        XCTAssertEqual(fixture.model.values, ["endpoint": .string("https://api.example.com"), "credential": .string("main"),
                                              "target": .string("DE")])
        XCTAssertEqual(fixture.model.missingTitles, ["API Key"])
        fixture.model.secrets["main"] = "s3cret"
        XCTAssertEqual(fixture.model.missingTitles, [], "a typed secret counts")
    }

    func testSavingStoresTheValuesAndTheSecret() throws {
        let fixture = try makeModel()
        fixture.model.values["target"] = .string("FR")
        fixture.model.secrets["main"] = "s3cret"
        XCTAssertTrue(fixture.model.save())

        XCTAssertEqual(fixture.store.values(for: PluginID("com.example.remote"))["target"], .string("FR"))
        XCTAssertEqual(try fixture.credentials.secret(for: PluginID("com.example.remote"), reference: "main"), "s3cret")
        XCTAssertNil(fixture.store.values(for: PluginID("com.example.remote"))["secret"], "the secret is not a setting")
        XCTAssertEqual(fixture.saves(), 1)
        XCTAssertNil(fixture.model.error)
    }

    func testAnInvalidValueIsRefusedAndNothingIsSaved() throws {
        let fixture = try makeModel()
        fixture.model.values["endpoint"] = .string("http://plain.example")
        XCTAssertFalse(fixture.model.save())
        XCTAssertNotNil(fixture.model.error)
        XCTAssertFalse(fixture.store.hasValues(for: PluginID("com.example.remote")))
        XCTAssertEqual(fixture.saves(), 0)
    }

    /// An endpoint on a host the Plugin did not declare reaches every Menu
    /// Item, so saving waits for the user to allow that host.
    func testAnUndeclaredEndpointHostNeedsConsentBeforeSaving() throws {
        let fixture = try makeModel()
        fixture.model.values["endpoint"] = .string("https://self.example.org")
        XCTAssertEqual(fixture.model.endpointConsent?.newHosts, ["self.example.org"])
        XCTAssertFalse(fixture.model.save())
        XCTAssertFalse(fixture.store.hasValues(for: PluginID("com.example.remote")))

        fixture.model.allowedEndpointHosts = ["self.example.org"]
        XCTAssertTrue(fixture.model.save())
        let manifest = try manifest()
        XCTAssertEqual(fixture.grants.consentedHTTPSHosts(for: manifest.id, pluginVersion: manifest.version,
                                                          declaredScope: try XCTUnwrap(manifest.scope(for: .contactHTTPS))),
                       ["self.example.org"])
        XCTAssertNil(fixture.model.endpointConsent)
    }

    func testTheLibraryMarksAPresetWhoseSettingsAreIncompleteWithoutBlockingIt() throws {
        let manifest = try manifest()
        var complete = false
        let registry = PluginRegistry(pluginSettingsComplete: { _ in complete })
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/remote"), manifest: manifest))
        var preset = try XCTUnwrap(registry.menuItemPreset(for: manifest.id))
        XCTAssertTrue(preset.needsPluginSettings)
        XCTAssertTrue(preset.isAvailable, "it can still be placed")
        XCTAssertEqual(preset.stateLabel, "Needs Plugin Settings")
        complete = true
        preset = try XCTUnwrap(registry.menuItemPreset(for: manifest.id))
        XCTAssertFalse(preset.needsPluginSettings)
        XCTAssertEqual(preset.stateLabel, MenuItemPresetReadiness.readyToUse.label)
    }

    // MARK: - Sources the user turns on and orders

    private func translatorModel() throws -> (PluginSettingsModel, PluginSettingsStore) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Plugins/Translator.spinnetplugin")).manifest
        let store = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        let grants = PluginCapabilityGrantStore()
        let model = PluginSettingsModel(
            manifest: manifest, store: store, credentialStore: InMemoryPluginCredentialStore(),
            approveConsent: { consent, allowed in try consent.approve(allowedHosts: allowed, grantStore: grants) },
            consent: { HTTPSEndpointConsent(manifest: manifest, settings: $0, grantStore: grants) },
            onSaved: {}
        )
        return (model, store)
    }

    func testTurningASourceOnAddsItLastAndItCanBeMovedUp() throws {
        let (model, _) = try translatorModel()
        XCTAssertEqual(model.orderedChoices(for: "sources"), ["Google"])
        model.setChoice("OpenAI", enabled: true, for: "sources")
        model.setChoice("DeepL", enabled: true, for: "sources")
        XCTAssertEqual(model.orderedChoices(for: "sources"), ["Google", "OpenAI", "DeepL"])
        model.moveChoice("DeepL", by: -1, for: "sources")
        XCTAssertEqual(model.orderedChoices(for: "sources"), ["Google", "DeepL", "OpenAI"])
        model.moveChoice("Google", by: -1, for: "sources")
        XCTAssertEqual(model.orderedChoices(for: "sources"), ["Google", "DeepL", "OpenAI"], "The first cannot move up")
        model.setChoice("Google", enabled: false, for: "sources")
        XCTAssertEqual(model.orderedChoices(for: "sources"), ["DeepL", "OpenAI"])
        XCTAssertEqual(model.values["sources"], .array([.string("DeepL"), .string("OpenAI")]))
    }

    /// Only the settings of the sources that are on are shown, and a value
    /// left behind in one that is off does not stop the sheet saving.
    func testOnlyTheSettingsOfSourcesThatAreOnAreShownOrChecked() throws {
        let (model, store) = try translatorModel()
        let shared = ["sources", "source_language", "target_language", "auto_detect"]
        XCTAssertEqual(model.visibleFields.compactMap(\.key), shared + ["google_endpoint"],
                       "Google needs only its address")
        model.values["openai_endpoint"] = .string("not an address")
        model.setChoice("DeepL", enabled: true, for: "sources")
        XCTAssertEqual(model.visibleFields.compactMap(\.key),
                       shared + ["google_endpoint", "deepl_endpoint", "deepl_credential", "formality"])
        model.secrets["deepl"] = "key"
        XCTAssertTrue(model.save(), model.error ?? "")
        XCTAssertEqual(store.values(for: model.manifest.id)["sources"],
                       .array([.string("Google"), .string("DeepL")]))

        model.setChoice("OpenAI", enabled: true, for: "sources")
        XCTAssertFalse(model.save(), "An address in use must be valid")
    }

    /// A key the user saved is shown again when the sheet reopens, so it can
    /// be checked and corrected rather than only replaced.
    func testAStoredKeyIsShownAgainAndCanBeEdited() throws {
        let keychain = InMemoryPluginCredentialStore()
        let fixture = try makeModel(credentials: keychain)
        fixture.model.secrets["main"] = "sk-first"
        XCTAssertTrue(fixture.model.save(), fixture.model.error ?? "")

        let reopened = try makeModel(credentials: keychain)
        XCTAssertEqual(reopened.model.secret(for: "main"), "sk-first")
        XCTAssertEqual(reopened.model.secrets, [:], "Nothing is rewritten until the user edits it")
        reopened.model.setSecret("sk-second", for: "main")
        XCTAssertTrue(reopened.model.save(), reopened.model.error ?? "")
        XCTAssertEqual(try makeModel(credentials: keychain).model.secret(for: "main"), "sk-second")
    }

    /// The sheet shows each source's settings under its own heading, and says
    /// which group a missing value belongs to, since two groups both have a key.
    func testSettingsAreShownUnderTheirGroupsAndMissingOnesNameTheirs() throws {
        let (model, _) = try translatorModel()
        model.setChoice("DeepL", enabled: true, for: "sources")
        model.setChoice("OpenAI", enabled: true, for: "sources")
        XCTAssertEqual(model.visibleGroups.map(\.name), [nil, "Languages", "Google", "DeepL", "OpenAI"])
        XCTAssertEqual(model.visibleGroups.first?.fields.compactMap(\.key), ["sources"],
                       "Settings with no group come first")
        XCTAssertEqual(model.visibleGroups.last?.fields.compactMap(\.key),
                       ["openai_endpoint", "openai_model", "openai_credential"])
        XCTAssertEqual(model.missingTitles, ["DeepL API Key", "OpenAI API Key"])
        XCTAssertTrue(model.showsCredential)

        model.setChoice("DeepL", enabled: false, for: "sources")
        model.setChoice("OpenAI", enabled: false, for: "sources")
        XCTAssertEqual(model.visibleGroups.map(\.name), [nil, "Languages", "Google"])
        XCTAssertFalse(model.showsCredential, "Google keeps no key")
    }

    // MARK: - Rows of a list setting

    private func smartJumpModel(stored: [String: JSONValue]? = nil) throws -> (PluginSettingsModel, PluginSettingsStore) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Plugins/SmartJump.spinnetplugin")).manifest
        let store = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        if let stored { try store.setValues(stored, for: manifest.id) }
        let grants = PluginCapabilityGrantStore()
        let model = PluginSettingsModel(
            manifest: manifest, store: store, credentialStore: nil,
            approveConsent: { consent, allowed in try consent.approve(allowedHosts: allowed, grantStore: grants) },
            consent: { HTTPSEndpointConsent(manifest: manifest, settings: $0, grantStore: grants) },
            onSaved: {}
        )
        return (model, store)
    }

    /// Engines saved as text before the `list` kind open as rows in their
    /// order, the first still the default, and save back as a list.
    func testEnginesStoredAsTextOpenAsRowsAndSaveAsAList() throws {
        let (model, store) = try smartJumpModel(stored: ["search_engines": .string(
            "DuckDuckGo | https://duckduckgo.com/?q={query}\nScholar | https://scholar.google.com/scholar?q={query}"
        )])
        XCTAssertEqual(model.rows(for: "search_engines"), [
            ["name": "DuckDuckGo", "url": "https://duckduckgo.com/?q={query}"],
            ["name": "Scholar", "url": "https://scholar.google.com/scholar?q={query}"]
        ])
        XCTAssertTrue(model.save(), model.error ?? "")
        XCTAssertEqual(store.values(for: model.manifest.id)["search_engines"], .array([
            .object(["name": .string("DuckDuckGo"), "url": .string("https://duckduckgo.com/?q={query}")]),
            .object(["name": .string("Scholar"), "url": .string("https://scholar.google.com/scholar?q={query}")])
        ]))
    }

    /// The generic row editor adds an empty row last, edits one cell, moves a
    /// row within the list, and removes one.
    func testRowsAreAddedEditedMovedAndRemoved() throws {
        let (model, store) = try smartJumpModel()
        XCTAssertEqual(model.rows(for: "search_engines").map { $0["name"] }, ["Google", "Bing", "DuckDuckGo"])
        model.addRow(to: "search_engines")
        XCTAssertEqual(model.rows(for: "search_engines").last, ["name": "", "url": ""])
        XCTAssertEqual(model.missingTitles, ["Search Engines (first is default)"], "an empty row is not yet usable")
        model.setCell("Wiki", column: "name", row: 3, in: "search_engines")
        model.setCell("https://en.wikipedia.org/wiki/{query}", column: "url", row: 3, in: "search_engines")
        XCTAssertEqual(model.missingTitles, [])
        model.moveRow(at: 3, by: -1, in: "search_engines")
        model.moveRow(at: 0, by: -1, in: "search_engines")
        XCTAssertEqual(model.rows(for: "search_engines").map { $0["name"] }, ["Google", "Bing", "Wiki", "DuckDuckGo"],
                       "the first cannot move up")
        model.moveRow(at: 2, by: -2, in: "search_engines")
        model.removeRow(at: 1, from: "search_engines")
        XCTAssertEqual(model.rows(for: "search_engines").map { $0["name"] }, ["Wiki", "Bing", "DuckDuckGo"])
        XCTAssertTrue(model.save(), model.error ?? "")
        guard case .array(let saved)? = store.values(for: model.manifest.id)["search_engines"] else {
            return XCTFail("the engines are saved as a list")
        }
        XCTAssertEqual(saved.first, .object(["name": .string("Wiki"), "url": .string("https://en.wikipedia.org/wiki/{query}")]),
                       "the first row is the default")
    }

    /// A row the columns refuse stops the save and says which row is at fault.
    func testAnInvalidRowIsRefusedByRow() throws {
        let (model, store) = try smartJumpModel()
        model.setCell("http://www.bing.com/search?q={query}", column: "url", row: 1, in: "search_engines")
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.error, "Invalid Action: Row 2 of Search Engines (first is default): Search URL must be an https address "
                       + "with {query} once in its path or query, such as https://example.com/search?q={query}.")
        XCTAssertFalse(store.hasValues(for: model.manifest.id))
        model.setCell("https://www.bing.com/search?q={query}", column: "url", row: 1, in: "search_engines")
        model.setCell("Google", column: "name", row: 1, in: "search_engines")
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.error, "Invalid Action: Row 2 of Search Engines (first is default) repeats the Name of row 1.")
    }
}
