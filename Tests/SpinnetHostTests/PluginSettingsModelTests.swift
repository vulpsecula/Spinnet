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

    private func makeModel() throws -> Fixture {
        let manifest = try manifest()
        let store = try PluginSettingsStore(fileURL: directory.appendingPathComponent("PluginSettings.json"))
        let credentials = InMemoryPluginCredentialStore()
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
}
