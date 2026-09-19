import XCTest
@testable import SpinnetCore

/// Plugin Settings are configuration a Plugin shares across the Menu Items
/// created from its Preset. A Plugin declares them as `settings_fields`; the
/// user fills them in from the Library before placing anything, and a field
/// marked `overridable` may be set again on one Menu Item. These tests pin
/// the manifest shape, how settings and an Action's input combine, when
/// settings are incomplete, how they are stored, and how existing Actions
/// that carried the values themselves move onto them.
final class PluginSettingsTests: XCTestCase {

    private func manifest(settings: String = PluginSettingsTests.settings, defaults: String = #"{"target": "DE"}"#,
                          commandFields: String = "", defaultInput: String = "{}",
                          capabilities: String = "") throws -> PluginManifest {
        try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "id": "com.example.remote", "name": "Remote", "version": "1.0.0",
          "capabilities": [\(capabilities)],
          "settings_fields": \(settings),
          "default_settings": \(defaults),
          "preset": {"readiness": "ready_to_use", "is_configurable": true, "default_primary_command_id": "remote.run",
                     "default_inputs": {"remote.run": \(defaultInput)}},
          "commands": [{"id": "remote.run", "title": "Run", "execution": "javascript", "is_configurable": true,
                        "script": "run.js"\(commandFields)}]
        }
        """.utf8))
    }

    private static let settings = """
    [{"key": "endpoint", "kind": "https_endpoint", "title": "Endpoint"},
     {"key": "credential", "kind": "credential", "title": "API Key"},
     {"key": "target", "kind": "choice", "title": "Translate Into", "choices": ["DE", "FR"], "overridable": true},
     {"key": "note", "kind": "text", "title": "Note"}]
    """

    // MARK: - Manifest

    func testSettingsFieldsAndDefaultsDecodeAndRoundTrip() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.settingsFields.map(\.key), ["endpoint", "credential", "target", "note"])
        XCTAssertEqual(manifest.settingsFields.map(\.overridable), [false, false, true, false])
        XCTAssertEqual(manifest.defaultSettings, ["target": .string("DE")])
        XCTAssertTrue(manifest.hasSettings)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
    }

    func testInvalidSettingsAreRejected() {
        let cases: [(String, () throws -> PluginManifest)] = [
            ("duplicate key", { try self.manifest(settings: #"[{"key": "a", "kind": "text"}, {"key": "a", "kind": "text"}]"#, defaults: "{}") }),
            ("missing key", { try self.manifest(settings: #"[{"kind": "text"}]"#, defaults: "{}") }),
            ("unsupported kind", { try self.manifest(settings: #"[{"key": "a", "kind": "keyboard_shortcut"}]"#, defaults: "{}") }),
            ("used_when", { try self.manifest(settings: #"[{"key": "m", "kind": "choice", "choices": ["x"]}, {"key": "a", "kind": "text", "used_when": {"key": "m", "values": ["x"]}}]"#, defaults: "{}") }),
            ("default for an unknown key", { try self.manifest(defaults: #"{"other": "x"}"#) }),
            ("invalid default", { try self.manifest(defaults: #"{"target": "IT"}"#) }),
            ("clashes with a Command field", { try self.manifest(commandFields: #", "configuration_fields": [{"key": "target", "kind": "text"}]"#) }),
            ("overridable on a Command field", { try self.manifest(commandFields: #", "configuration_fields": [{"key": "mode", "kind": "text", "overridable": true}]"#) })
        ]
        for (name, make) in cases {
            XCTAssertThrowsError(try make(), name)
        }
    }

    // MARK: - Combining settings with an Action

    func testTheScriptSeesTheSettingsWithTheMenuItemsOverridesAndOwnFields() throws {
        let manifest = try manifest(commandFields: #", "configuration_fields": [{"key": "mode", "kind": "choice", "choices": ["a", "b"]}]"#,
                                    defaultInput: #"{"mode": "a"}"#)
        let command = manifest.commands[0]
        let settings: [String: JSONValue] = ["endpoint": .string("https://api.example.com"), "credential": .string("key"),
                                             "target": .string("DE"), "note": .string("n")]

        XCTAssertEqual(manifest.effectiveInput(for: command, actionInput: .object(["mode": .string("b")]), settings: settings),
                       .object(settings.merging(["mode": .string("b")]) { $1 }))
        XCTAssertEqual(manifest.effectiveInput(for: command, actionInput: .object(["mode": .string("a"), "target": .string("FR")]),
                                               settings: settings)["target"], .string("FR"), "An override wins")
        // A value the Menu Item may not override is the Plugin's, whatever the Action holds.
        XCTAssertEqual(manifest.effectiveInput(for: command, actionInput: .object(["mode": .string("a"), "endpoint": .string("https://evil.example")]),
                                               settings: settings)["endpoint"], .string("https://api.example.com"))

        let plain = try PluginManifest(id: PluginID("p"), name: "P", version: "1",
            commands: [CommandDeclaration(id: CommandID("c"), title: "C", execution: .javascript, script: "c.js")])
        XCTAssertEqual(plain.effectiveInput(for: plain.commands[0], actionInput: .string("x"), settings: [:]), .string("x"),
                       "A Plugin without settings is untouched")
    }

    func testAnActionHoldsItsOwnFieldsAndOnlyOverridableSettings() throws {
        let manifest = try manifest()
        let command = manifest.commands[0]
        XCTAssertTrue(manifest.acceptsActionInput(.object([:]), for: command))
        XCTAssertTrue(manifest.acceptsActionInput(.null, for: command))
        XCTAssertTrue(manifest.acceptsActionInput(.object(["target": .string("FR")]), for: command))
        XCTAssertFalse(manifest.acceptsActionInput(.object(["target": .string("IT")]), for: command), "not a choice")
        XCTAssertFalse(manifest.acceptsActionInput(.object(["endpoint": .string("https://a.example")]), for: command),
                       "not overridable")
        XCTAssertFalse(manifest.acceptsActionInput(.object(["unknown": .string("x")]), for: command))

        let withField = try self.manifest(commandFields: #", "configuration_fields": [{"key": "mode", "kind": "choice", "choices": ["a"]}]"#,
                                          defaultInput: #"{"mode": "a"}"#)
        let fielded = withField.commands[0]
        XCTAssertTrue(withField.acceptsActionInput(.object(["mode": .string("a"), "target": .string("DE")]), for: fielded))
        XCTAssertFalse(withField.acceptsActionInput(.object(["target": .string("DE")]), for: fielded), "its own field is required")
    }

    // MARK: - Resolving and completeness

    func testStoredValuesOverlayTheDefaultsAndOnlyValidDeclaredOnesCount() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.resolvedSettings(stored: [:]), ["target": .string("DE")])
        XCTAssertEqual(manifest.resolvedSettings(stored: ["target": .string("FR"), "note": .string("n"),
                                                          "unknown": .string("x"), "endpoint": .string("http://plain.example")]),
                       ["target": .string("FR"), "note": .string("n")])
    }

    func testSettingsAreIncompleteUntilEveryFieldHasAUsableValue() throws {
        let manifest = try manifest()
        var values = manifest.resolvedSettings(stored: [:])
        XCTAssertEqual(manifest.missingSettings(in: values, hasSecret: { _ in true }).map(\.key), ["endpoint", "credential", "note"])
        values["endpoint"] = .string("https://api.example.com")
        values["credential"] = .string("key")
        values["note"] = .string("  ")
        XCTAssertEqual(manifest.missingSettings(in: values, hasSecret: { _ in true }).map(\.key), ["note"], "blank text is missing")
        values["note"] = .string("n")
        XCTAssertEqual(manifest.missingSettings(in: values, hasSecret: { _ in false }).map(\.key), ["credential"],
                       "a credential needs its secret")
        XCTAssertEqual(manifest.missingSettings(in: values, hasSecret: { $0 == "key" }), [])
    }

    func testIncompleteSettingsLeaveTheMenuItemInPlaceWithThePluginSettingsRepair() throws {
        let manifest = try manifest()
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/remote"), manifest: manifest)
        var complete = false
        let registry = PluginRegistry(grantStore: PluginCapabilityGrantStore(), pluginSettingsComplete: { _ in complete })
        try registry.register(package)
        let action = try ActionConfiguration(id: ActionID("a"), pluginID: manifest.id, command: manifest.commands[0], input: .object([:]))
        XCTAssertEqual(registry.availability(for: action), .unavailable(.pluginSettingsIncomplete))
        XCTAssertTrue(ActionUnavailableReason.pluginSettingsIncomplete.description.contains("Plugin Settings"))
        complete = true
        XCTAssertEqual(registry.availability(for: action), .available)
    }

    // MARK: - Running

    func testTheRunnerHandsTheScriptTheCombinedInput() throws {
        let manifest = try manifest()
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/remote"), manifest: manifest)
        let registry = PluginRegistry()
        try registry.register(package)
        let recorder = RecordingScriptedExecutor()
        let runner = HostActionRunner(executor: NoopHostExecutor(), scriptedExecutor: recorder,
                                      pluginSettings: { _ in ["target": .string("DE"), "note": .string("n")] })
        let action = try ActionConfiguration(id: ActionID("a"), pluginID: manifest.id, command: manifest.commands[0],
                                             input: .object(["target": .string("FR")]))
        guard case .succeeded = runner.invoke(action, using: registry).terminal else { return XCTFail() }
        XCTAssertEqual(recorder.inputs, [.object(["target": .string("FR"), "note": .string("n")])])
        XCTAssertEqual(recorder.actionIDs, [action.id], "the same Action, with its settings applied")
    }

    // MARK: - Endpoint consent

    /// An endpoint in Plugin Settings reaches every Command in the contact
    /// scope, so a host the Plugin did not declare needs consent there.
    func testASettingsEndpointOnAnUndeclaredHostNeedsConsent() throws {
        let manifest = try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "id": "com.example.remote", "name": "Remote", "version": "1.0.0",
          "capabilities": ["contact_https"],
          "capability_scopes": [{"capability": "contact_https", "command_ids": ["remote.run"], "data_types": ["text"],
                                 "includes_existing_host_data": false, "https_hosts": ["api.example.com"], "external_apps": []}],
          "settings_fields": [{"key": "endpoint", "kind": "https_endpoint"}],
          "commands": [{"id": "remote.run", "title": "Run", "execution": "javascript", "is_configurable": true, "script": "run.js"}]
        }
        """.utf8))
        let grants = PluginCapabilityGrantStore()
        XCTAssertEqual(HTTPSEndpointConsent(manifest: manifest, settings: ["endpoint": .string("https://api.example.com")],
                                            grantStore: grants).newHosts, [])
        let consent = HTTPSEndpointConsent(manifest: manifest, settings: ["endpoint": .string("https://self.example.org/v2")],
                                           grantStore: grants)
        XCTAssertEqual(consent.newHosts, ["self.example.org"])
        XCTAssertThrowsError(try consent.approve(allowedHosts: [], grantStore: grants))
        try consent.approve(allowedHosts: ["self.example.org"], grantStore: grants)
        XCTAssertEqual(HTTPSEndpointConsent(manifest: manifest, settings: ["endpoint": .string("https://self.example.org")],
                                            grantStore: grants).newHosts, [])
    }

    // MARK: - Storage

    func testTheStoreKeepsEachPluginsValuesAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PluginSettings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PluginSettingsStore(fileURL: url)
        XCTAssertEqual(store.values(for: PluginID("a")), [:])
        try store.setValues(["target": .string("FR")], for: PluginID("a"))
        try store.setValues(["x": .bool(true)], for: PluginID("b"))
        let reopened = try PluginSettingsStore(fileURL: url)
        XCTAssertEqual(reopened.values(for: PluginID("a")), ["target": .string("FR")])
        XCTAssertEqual(reopened.values(for: PluginID("b")), ["x": .bool(true)])
        XCTAssertFalse(reopened.hasValues(for: PluginID("c")))
        XCTAssertTrue(reopened.hasValues(for: PluginID("a")))
    }

    // MARK: - Moving existing Actions onto Plugin Settings

    /// Before Plugin Settings, each Action carried every value. The first
    /// Menu Item's Primary Action seeds the settings; Actions then keep only
    /// their own fields, plus an overridable value where it differs.
    func testActionsThatCarriedTheValuesMoveOntoPluginSettings() throws {
        let manifest = try manifest()
        func action(_ id: String, _ values: [String: String]) throws -> ActionConfiguration {
            try ActionConfiguration(id: ActionID(id), pluginID: manifest.id, command: manifest.commands[0],
                                    input: .object(values.mapValues(JSONValue.string)))
        }
        let old = ["endpoint": "https://api.example.com", "credential": "key", "note": "n"]
        let loose = try action("loose", old.merging(["target": "FR"]) { $1 })
        let primary = try action("primary", old.merging(["target": "DE"]) { $1 })
        let other = try action("other", old.merging(["target": "FR"]) { $1 })
        let configuration = try HostConfiguration(actions: [loose, primary, other], menu: MenuConfiguration(slots: [
            .empty,
            .occupied(try MenuItemConfiguration(primaryActionID: primary.id)),
            .occupied(try MenuItemConfiguration(primaryActionID: other.id))
        ]))

        let result = try XCTUnwrap(PluginSettingsMigration.migrate(configuration, manifest: manifest, storedSettings: nil))
        XCTAssertEqual(result.settings, ["endpoint": .string("https://api.example.com"), "credential": .string("key"),
                                         "note": .string("n"), "target": .string("DE")])
        XCTAssertEqual(result.configuration.menu, configuration.menu)
        let inputs = Dictionary(uniqueKeysWithValues: result.configuration.actions.map { ($0.id.rawValue, $0.input) })
        XCTAssertEqual(inputs["primary"], .object([:]))
        XCTAssertEqual(inputs["other"], .object(["target": .string("FR")]), "kept as an override")
        XCTAssertEqual(inputs["loose"], .object(["target": .string("FR")]))
        for action in result.configuration.actions {
            XCTAssertTrue(manifest.acceptsActionInput(action.input, for: manifest.commands[0]))
        }

        // Stored settings stand; the Actions still shed what they may not hold.
        let kept = try XCTUnwrap(PluginSettingsMigration.migrate(configuration, manifest: manifest,
                                                                 storedSettings: ["target": .string("FR")]))
        XCTAssertNil(kept.settings)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: kept.configuration.actions.map { ($0.id.rawValue, $0.input) })["primary"],
                       .object(["target": .string("DE")]))
        XCTAssertNil(try PluginSettingsMigration.migrate(result.configuration, manifest: manifest, storedSettings: result.settings),
                     "nothing left to move")
    }
}

private final class RecordingScriptedExecutor: ScriptedActionExecutor {
    private(set) var inputs: [JSONValue] = []
    private(set) var actionIDs: [ActionID] = []

    func execute(_ action: ActionConfiguration, in package: PluginPackage, using hostServiceBroker: PluginHostServiceBroker?,
                 control: ActionExecutionControl) throws -> JSONValue {
        inputs.append(action.input)
        actionIDs.append(action.id)
        return .null
    }

    func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue {
        try execute(action, in: package, using: nil, control: ActionExecutionControl())
    }
}

private struct NoopHostExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }
}
