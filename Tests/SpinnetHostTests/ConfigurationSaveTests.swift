import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class ConfigurationSaveTests: XCTestCase {
    private let owner = PluginID("example.save")
    private enum Failure: Error { case injected }

    private final class Credentials: PluginCredentialStore, CredentialSaveNotifications {
        var items = ["a": "old-a", "b": "old-b"]
        var failingRead: String?
        var failingSecret: String?
        var writes = 0
        var publications = 0
        private var batching = false
        func secret(for pluginID: PluginID, reference: String) throws -> String? {
            if reference == failingRead { throw Failure.injected }
            return items[reference]
        }
        func setSecret(_ secret: String, for pluginID: PluginID, reference: String) throws {
            writes += 1
            if secret == failingSecret { throw Failure.injected }
            items[reference] = secret
            if !batching { publications += 1 }
        }
        func removeSecret(for pluginID: PluginID, reference: String) throws { items[reference] = nil }
        func beginSave() { batching = true }
        func endSave(publishingChanges: Bool) {
            batching = false
            if publishingChanges, writes > 0 { publications += 1 }
        }
    }

    func testReadFailureDoesNotTreatAnExistingSecretAsAbsent() throws {
        let credentials = Credentials()
        credentials.failingRead = "b"
        var saved = false
        XCTAssertThrowsError(try ConfigurationSave.perform(
            pluginID: owner, secrets: ["a": "new-a", "b": "new-b"], credentialStore: credentials,
            consent: nil, allowedHosts: [], values: .init(write: { saved = true }, restore: {}), commitConsent: { _, _ in }
        ))
        XCTAssertFalse(saved)
        XCTAssertEqual(credentials.writes, 0)
        XCTAssertEqual(credentials.items, ["a": "old-a", "b": "old-b"])
    }

    func testSecondCredentialFailureRestoresTheFirstWithoutNotifications() throws {
        let credentials = Credentials()
        credentials.failingSecret = "new-b"
        var saved = false
        XCTAssertThrowsError(try ConfigurationSave.perform(
            pluginID: owner, secrets: ["a": "new-a", "b": "new-b"], credentialStore: credentials,
            consent: nil, allowedHosts: [], values: .init(write: { saved = true }, restore: {}), commitConsent: { _, _ in }
        ))
        XCTAssertFalse(saved)
        XCTAssertEqual(credentials.items, ["a": "old-a", "b": "old-b"])
        XCTAssertEqual(credentials.publications, 0)
    }

    func testFileFailureRestoresCredentialsAndNeverCommitsConsent() throws {
        let credentials = Credentials()
        let (consent, _) = try endpoint()
        var approved = false
        XCTAssertThrowsError(try ConfigurationSave.perform(
            pluginID: owner, secrets: ["a": "new-a"], credentialStore: credentials,
            consent: consent, allowedHosts: ["self.example"],
            values: .init(write: { throw Failure.injected }, restore: { XCTFail("An atomic write that failed changed nothing") }),
            commitConsent: { _, _ in approved = true }
        ))
        XCTAssertFalse(approved)
        XCTAssertEqual(credentials.items["a"], "old-a")
        XCTAssertEqual(credentials.publications, 0)
    }

    func testMissingConsentIsRejectedBeforeAnyCredentialOrFileWrite() throws {
        let credentials = Credentials()
        let (consent, _) = try endpoint()
        XCTAssertThrowsError(try ConfigurationSave.perform(
            pluginID: owner, secrets: ["a": "new-a"], credentialStore: credentials,
            consent: consent, allowedHosts: [],
            values: .init(write: { XCTFail("Consent must be checked first") }, restore: {}), commitConsent: { _, _ in XCTFail() }
        ))
        XCTAssertEqual(credentials.writes, 0)
    }

    func testGrantPersistenceFailureRestoresOnlyThisPluginsValuesAndCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PluginSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        try store.setValues(["target": .string("untouched")], for: PluginID("example.other"))
        let credentials = Credentials()
        let (consent, grants) = try endpoint()
        grants.setDecision(.granted, for: PluginID("example.other"), pluginVersion: "1", capability: .writeClipboard)
        let previousGrants = grants.allGrants
        var notifications = 0
        let observation = grants.observeChanges { notifications += 1 }
        defer { grants.removeChangeObserver(observation) }
        XCTAssertThrowsError(try ConfigurationSave.perform(
            pluginID: owner, secrets: ["a": "new-a"], credentialStore: credentials,
            consent: consent, allowedHosts: ["self.example"],
            values: .init(write: { try store.setValues(["endpoint": .string("https://self.example")], for: self.owner) },
                          restore: { try store.restoreValues(nil, for: self.owner) }),
            commitConsent: { consent, allowed in
                try consent.commit(allowedHosts: allowed, grantStore: grants, persisting: { _ in throw Failure.injected })
            }
        ))
        XCTAssertFalse(store.hasValues(for: owner))
        let reread = try PluginSettingsStore(fileURL: store.fileURL)
        XCTAssertFalse(reread.hasValues(for: owner))
        XCTAssertEqual(reread.values(for: PluginID("example.other")), ["target": .string("untouched")])
        XCTAssertEqual(grants.allGrants, previousGrants)
        XCTAssertEqual(credentials.items["a"], "old-a")
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(credentials.publications, 0)
    }

    func testCompensationFailureReportsPartialSaveAndPublishesRemainingChange() throws {
        let credentials = Credentials()
        credentials.failingSecret = "old-a"
        let (consent, _) = try endpoint()
        var restoredValues = false
        XCTAssertThrowsError(try ConfigurationSave.perform(
            pluginID: owner, secrets: ["a": "new-a"], credentialStore: credentials,
            consent: consent, allowedHosts: ["self.example"],
            values: .init(write: {}, restore: { restoredValues = true }),
            commitConsent: { _, _ in throw Failure.injected }
        )) { error in
            guard case ConfigurationSaveError.partiallySaved = error else { return XCTFail("Expected explicit partial-save result") }
        }
        XCTAssertTrue(restoredValues)
        XCTAssertEqual(credentials.items["a"], "new-a")
        XCTAssertEqual(credentials.publications, 1)
    }

    func testValueCompensationFailureReportsTheRemainingSavedValue() throws {
        let (consent, _) = try endpoint()
        var storedValue = "previous"
        XCTAssertThrowsError(try ConfigurationSave.perform(
            pluginID: owner, secrets: [:], credentialStore: nil,
            consent: consent, allowedHosts: ["self.example"],
            values: .init(write: { storedValue = "edited" }, restore: { throw Failure.injected }),
            commitConsent: { _, _ in throw Failure.injected }
        )) { error in
            guard case ConfigurationSaveError.partiallySaved = error else {
                return XCTFail("A failed value compensation must report a partial save")
            }
        }
        XCTAssertEqual(storedValue, "edited", "Do not claim the previous value was restored")
    }

    func testFailedSaveRemovesANewCredentialThatPreviouslyDidNotExist() throws {
        let credentials = Credentials()
        let previous = credentials.items
        let (consent, _) = try endpoint()
        var restoredValues = false
        XCTAssertThrowsError(try ConfigurationSave.perform(
            pluginID: owner, secrets: ["new": "new-secret"], credentialStore: credentials,
            consent: consent, allowedHosts: ["self.example"],
            values: .init(write: {}, restore: { restoredValues = true }),
            commitConsent: { _, _ in throw Failure.injected }
        )) { error in
            guard case ConfigurationSaveError.restored = error else {
                return XCTFail("A removed new credential should leave a fully restored save")
            }
        }
        XCTAssertTrue(restoredValues)
        XCTAssertNil(credentials.items["new"])
        XCTAssertEqual(credentials.items, previous)
        XCTAssertEqual(credentials.publications, 0)
    }

    func testSuccessPublishesTheGrantAfterValuesAndCredentialsAreSaved() throws {
        let credentials = Credentials()
        let (consent, grants) = try endpoint()
        var saved = false
        var notifications = 0
        let observation = grants.observeChanges {
            XCTAssertTrue(saved)
            XCTAssertEqual(credentials.items["a"], "new-a")
            notifications += 1
        }
        defer { grants.removeChangeObserver(observation) }
        try ConfigurationSave.perform(
            pluginID: owner, secrets: ["a": "new-a", "b": "new-b"], credentialStore: credentials,
            consent: consent, allowedHosts: ["self.example"],
            values: .init(write: { saved = true }, restore: { saved = false }),
            commitConsent: { consent, allowed in
                try consent.commit(allowedHosts: allowed, grantStore: grants, persisting: { proposed in
                    XCTAssertTrue(saved)
                    XCTAssertTrue(proposed.contains { $0.scope?.consentedHTTPSHosts.contains("self.example") == true })
                })
            }
        )
        XCTAssertTrue(saved)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(credentials.publications, 1)
    }

    func testSheetPersistenceFailureKeepsTheDraftEditorAndUndoUnchanged() throws {
        _ = NSApplication.shared
        let editor = try makeEditor()
        let model = SettingsWindowModel(editor: editor, metadata: .current,
                                        accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        model.menuEditor.requestEdit(at: 0)
        let previous = editor.configuration
        var slots = previous.menu.slots
        slots[0] = .occupied(try XCTUnwrap(slots[0].item).withAlias("Changed"))
        let next = try HostConfiguration(actions: previous.actions, menu: MenuConfiguration(slots: slots))
        model.menuEditor.persistConfiguration = { _ in throw Failure.injected }
        var published = false
        model.menuEditor.onConfigurationSaved = { _ in published = true }
        XCTAssertThrowsError(try model.saveMenuItem(.init(configuration: next)))
        XCTAssertEqual(editor.configuration, previous)
        XCTAssertEqual(model.menuEditor.editingMenuIndex, 0)
        XCTAssertFalse(model.menuEditor.canUndoSlotEdit)
        XCTAssertFalse(published)
        model.menuEditor.persistConfiguration = { XCTAssertEqual($0, next) }
        try model.saveMenuItem(.init(configuration: next))
        XCTAssertEqual(editor.configuration, next)
        XCTAssertNil(model.menuEditor.editingMenuIndex)
        XCTAssertTrue(model.menuEditor.canUndoSlotEdit)
        XCTAssertTrue(published)
    }

    func testPluginSettingsCredentialFailureKeepsTheStoredValuesAndOpenDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try PluginManifestLoader.decode(Data(#"""
        {"protocol_version":"1.0","engines":{"spinnet":"^1.0.0"},"id":"example.save","name":"Save","version":"1",
         "settings_fields":[{"key":"enabled","kind":"toggle"},{"key":"credential","kind":"credential"}],
         "default_settings":{"enabled":false,"credential":"a"},
         "commands":[{"id":"run","title":"Run","execution":"javascript","script":"run.js"}]}
        """#.utf8))
        let store = try PluginSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        try store.setValues(["enabled": .bool(false), "credential": .string("a")], for: owner)
        let credentials = Credentials()
        credentials.failingSecret = "new-a"
        let grants = PluginCapabilityGrantStore()
        var published = false
        let model = PluginSettingsModel(manifest: manifest, store: store, credentialStore: credentials,
            approveConsent: { _, _ in XCTFail("No endpoint consent was requested") },
            consent: { HTTPSEndpointConsent(manifest: manifest, settings: $0, grantStore: grants) },
            onSaved: { published = true })
        model.values["enabled"] = .bool(true)
        model.secrets["a"] = "new-a"
        XCTAssertFalse(model.save())
        XCTAssertEqual(store.values(for: owner)["enabled"], .bool(false))
        XCTAssertEqual(try PluginSettingsStore(fileURL: store.fileURL).values(for: owner)["enabled"], .bool(false))
        XCTAssertEqual(model.values["enabled"], .bool(true), "Keep the user's unsaved draft")
        XCTAssertEqual(model.secrets["a"], "new-a")
        XCTAssertNotNil(model.error)
        XCTAssertFalse(published)
        XCTAssertEqual(credentials.publications, 0)
    }

    func testCredentialOnlySheetSaveRefreshesAvailabilityWithoutCreatingAnUndoEdit() throws {
        _ = NSApplication.shared
        let editor = try makeEditor()
        let model = SettingsWindowModel(editor: editor, metadata: .current,
                                        accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        model.menuEditor.requestEdit(at: 0)
        let credentials = Credentials()
        model.credentialStore = credentials
        var saves = 0
        model.menuEditor.persistConfiguration = { _ in saves += 1 }
        var publications = 0
        model.menuEditor.onConfigurationSaved = { _ in publications += 1 }
        try model.saveMenuItem(.init(configuration: editor.configuration, pluginID: owner, secrets: ["a": "new-a"]))
        XCTAssertEqual(credentials.items["a"], "new-a")
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(publications, 1)
        XCTAssertNil(model.menuEditor.editingMenuIndex)
        XCTAssertFalse(model.menuEditor.canUndoSlotEdit)
    }

    private func endpoint() throws -> (HTTPSEndpointConsent, PluginCapabilityGrantStore) {
        let command = CommandDeclaration(id: CommandID("run"), title: "Run", scriptPath: "run.js")
        let scope = PluginCapabilityScope(capability: .contactHTTPS, commandIDs: [command.id], dataTypes: ["text"], httpsHosts: ["api.example"])
        let manifest = try PluginManifest(id: owner, name: "Save", version: "1", capabilities: [.contactHTTPS],
                                          capabilityScopes: [scope], commands: [command])
        // The normal consent parser reads declared endpoint fields. This test
        // uses those real rules rather than manufacturing a consent object.
        let fields = CommandConfigurationField(kind: .httpsEndpoint, title: "Endpoint", key: "endpoint")
        let endpointCommand = CommandDeclaration(id: command.id, title: "Run", execution: .javascript, script: "run.js", configurationFields: [fields])
        let configured = try PluginManifest(id: manifest.id, name: manifest.name, version: manifest.version,
                                            capabilities: manifest.capabilities, capabilityScopes: [scope], commands: [endpointCommand])
        let grants = PluginCapabilityGrantStore()
        let consent = HTTPSEndpointConsent(manifest: configured, inputs: [command.id: .object(["endpoint": .string("https://self.example")])], grantStore: grants)
        XCTAssertEqual(consent.newHosts, ["self.example"])
        return (consent, grants)
    }
}
