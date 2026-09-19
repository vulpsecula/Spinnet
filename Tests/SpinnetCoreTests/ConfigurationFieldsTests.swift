import XCTest
@testable import SpinnetCore

/// A Command can declare several named Host-rendered fields. Its Action input
/// is then an object with one member per field, which the Host checks before
/// the Configuration Sheet saves.
final class ConfigurationFieldsTests: XCTestCase {

    private func manifest(fields: String, extra: String = "", configurable: Bool = true) throws -> PluginManifest {
        try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "id": "com.example.remote", "name": "Remote", "version": "1.0.0",
          "capabilities": ["contact_https"],
          "capability_scopes": [{
            "capability": "contact_https", "command_ids": ["remote.run"], "data_types": [],
            "includes_existing_host_data": false, "https_hosts": ["api.example.com"], "external_apps": []
          }],
          "preset": {"readiness": "setup_required", "is_configurable": true, "default_primary_command_id": "remote.run"},
          "commands": [
            {"id": "remote.run", "title": "Run", "execution": "javascript", "is_configurable": \(configurable),
             "script": "run.js", "configuration_fields": \(fields) \(extra)},
            {"id": "local.run", "title": "Local", "execution": "javascript", "is_configurable": true,
             "script": "run.js", "configuration_fields": [{"key": "endpoint", "kind": "https_endpoint", "title": "Endpoint"}]}
          ]
        }
        """.utf8))
    }

    private let remoteFields = """
    [{"key": "endpoint", "kind": "https_endpoint", "title": "Endpoint"},
     {"key": "credential", "kind": "credential", "title": "API Key"},
     {"key": "target", "kind": "choice", "title": "Target", "choices": ["DE", "FR"]},
     {"key": "enabled", "kind": "toggle"}]
    """

    private func validInput(endpoint: String = "https://api.example.com") -> JSONValue {
        .object(["endpoint": .string(endpoint), "credential": .string("primary"),
                 "target": .string("DE"), "enabled": .bool(true)])
    }

    func testFieldsDecodeInOrderWithTheirKeys() throws {
        let command = try XCTUnwrap(try manifest(fields: remoteFields).commands.first)
        XCTAssertEqual(command.configurationFields.map(\.key), ["endpoint", "credential", "target", "enabled"])
        XCTAssertEqual(command.configurationFields.map(\.kind), [.httpsEndpoint, .credential, .choice, .toggle])
        // Round-trips through a persisted Action snapshot.
        let decoded = try JSONDecoder().decode(CommandDeclaration.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded, command)
    }

    func testManifestsWithAmbiguousFieldsAreRejected() throws {
        XCTAssertThrowsError(try manifest(fields: #"[{"key": "a", "kind": "text"}, {"key": "a", "kind": "text"}]"#),
                             "Duplicate keys")
        XCTAssertThrowsError(try manifest(fields: #"[{"kind": "text"}]"#), "Missing key")
        XCTAssertThrowsError(try manifest(fields: #"[{"key": " ", "kind": "text"}]"#), "Blank key")
        XCTAssertThrowsError(try manifest(fields: #"[{"key": "a", "kind": "application"}]"#), "Unsupported kind")
        XCTAssertThrowsError(try manifest(fields: #"[{"key": "a", "kind": "text"}]"#,
                                          extra: #", "configuration_field": {"kind": "text"}"#), "Both field styles")
        XCTAssertThrowsError(try manifest(fields: #"[{"key": "a", "kind": "text"}]"#, configurable: false))
    }

    func testTheEditorChecksEveryFieldBeforeSaving() throws {
        let manifest = try manifest(fields: remoteFields)
        let registry = PluginRegistry()
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/remote"), manifest: manifest))
        let editor = HostConfigurationEditor(registry: registry,
                                             configuration: try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty])))
        func save(_ input: JSONValue) throws {
            _ = try editor.configuredMenuItem(at: 0, pluginID: manifest.id, primaryCommandID: CommandID("remote.run"),
                                              alternateCommandIDs: [], inputs: [CommandID("remote.run"): input],
                                              replacingEmptySlot: true, validateInputs: true)
        }
        XCTAssertNoThrow(try save(validInput()))
        XCTAssertNoThrow(try save(validInput(endpoint: "https://translate.self-hosted.test/base")))
        var invalid: [JSONValue] = [
            .string("https://api.example.com"),
            validInput(endpoint: "http://api.example.com"),
            validInput(endpoint: "https://user:pw@api.example.com"),
            validInput(endpoint: "not a url")
        ]
        if case .object(var fields) = validInput() {
            fields["target"] = .string("XX"); invalid.append(.object(fields))
            fields["target"] = .string("DE"); fields["credential"] = .string("a secret with spaces"); invalid.append(.object(fields))
            fields["credential"] = .string("primary"); fields["extra"] = .string("x"); invalid.append(.object(fields))
            fields.removeValue(forKey: "extra"); fields.removeValue(forKey: "enabled"); invalid.append(.object(fields))
        }
        for input in invalid {
            XCTAssertThrowsError(try save(input), "\(input)")
        }
    }

    /// `url` keeps accepting any link; only `https_endpoint` is an endpoint,
    /// and it, like a credential, exists only as a named field.
    func testOnlyHTTPSEndpointFieldsAreEndpointsAndBothRequestKindsNeedAFieldSet() throws {
        let link = CommandDeclaration(id: CommandID("open"), title: "Open", execution: .javascript, script: "o.js",
                                      configurationFields: [CommandConfigurationField(kind: .url, key: "link")])
        XCTAssertTrue(link.acceptsConfigurationFieldsInput(.object(["link": .string("http://example.com")])))
        XCTAssertEqual(link.configuredEndpointHosts(in: .object(["link": .string("https://example.com")])), [])
        for kind in [CommandConfigurationFieldKind.credential, .httpsEndpoint] {
            let lone = CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript, script: "r.js",
                                          configurationField: CommandConfigurationField(kind: kind))
            XCTAssertThrowsError(try PluginManifest(id: PluginID("com.example.lone"), name: "Lone", version: "1",
                                                    commands: [lone]), kind.rawValue)
        }
    }

    // MARK: Self-hosted endpoints

    func testASelfHostedEndpointNeedsConsentBeforeSaveAndIsThenPartOfTheContactScope() throws {
        let manifest = try manifest(fields: remoteFields)
        let grants = PluginCapabilityGrantStore()
        let declared = try XCTUnwrap(manifest.scope(for: .contactHTTPS))
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                           capability: .contactHTTPS, scope: declared)
        let run = CommandID("remote.run")

        let declaredOnly = HTTPSEndpointConsent(manifest: manifest, inputs: [run: validInput()], grantStore: grants)
        XCTAssertEqual(declaredOnly.newHosts, [])
        XCTAssertNoThrow(try declaredOnly.approve(allowedHosts: [], grantStore: grants))

        let selfHosted = HTTPSEndpointConsent(
            manifest: manifest, inputs: [run: validInput(endpoint: "https://Translate.Self-Hosted.test/v2")], grantStore: grants
        )
        XCTAssertEqual(selfHosted.newHosts, ["translate.self-hosted.test"])
        XCTAssertThrowsError(try selfHosted.approve(allowedHosts: [], grantStore: grants)) { error in
            XCTAssertTrue(error.localizedDescription.contains("translate.self-hosted.test"))
        }
        XCTAssertEqual(grants.consentedHTTPSHosts(for: manifest.id, pluginVersion: manifest.version, declaredScope: declared), [],
                       "Refusing consent records nothing")

        // Allowing one host is not consent to another: an endpoint edited
        // after the box was ticked names a host the user never allowed.
        let edited = HTTPSEndpointConsent(
            manifest: manifest, inputs: [run: validInput(endpoint: "https://other.self-hosted.test")], grantStore: grants
        )
        XCTAssertThrowsError(try edited.approve(allowedHosts: ["translate.self-hosted.test"], grantStore: grants))
        XCTAssertEqual(grants.consentedHTTPSHosts(for: manifest.id, pluginVersion: manifest.version, declaredScope: declared), [])

        try selfHosted.approve(allowedHosts: ["translate.self-hosted.test"], grantStore: grants)
        XCTAssertEqual(grants.consentedHTTPSHosts(for: manifest.id, pluginVersion: manifest.version, declaredScope: declared),
                       ["translate.self-hosted.test"])
        XCTAssertEqual(grants.decision(for: manifest.id, pluginVersion: manifest.version,
                                       capability: .contactHTTPS, scope: declared), .granted)
        XCTAssertEqual(HTTPSEndpointConsent(manifest: manifest, inputs: [run: validInput(endpoint: "https://translate.self-hosted.test")],
                                            grantStore: grants).newHosts, [], "Consent is asked once per host")
    }

    func testOnlyEndpointsOfCommandsThatContactTheNetworkNeedConsent() throws {
        let manifest = try manifest(fields: remoteFields)
        let consent = HTTPSEndpointConsent(
            manifest: manifest,
            inputs: [CommandID("local.run"): .object(["endpoint": .string("https://elsewhere.test")])],
            grantStore: PluginCapabilityGrantStore()
        )
        XCTAssertEqual(consent.newHosts, [])
    }

    // MARK: Fields used only for some choices

    /// A field may declare the choices that use it. Validation holds it to a
    /// choice field in the same set and to that field's own choices.
    func testUsedWhenMustNameAChoiceFieldAndItsChoices() throws {
        func manifest(usedWhen: String) -> Data {
            Data("""
            {
              "protocol_version": "1.0", "id": "com.example.conditional", "name": "Conditional", "version": "1.0.0",
              "commands": [{"id": "run", "title": "Run", "execution": "javascript", "script": "run.js",
                "configuration_fields": [
                  {"key": "mode", "kind": "choice", "choices": ["Copy", "Save"]},
                  {"key": "note", "kind": "text"},
                  {"key": "folder", "kind": "folder", "used_when": \(usedWhen)}
                ]}]
            }
            """.utf8)
        }
        let valid = try PluginManifestLoader.decode(manifest(usedWhen: #"{"key": "mode", "values": ["Save"]}"#))
        let folder = try XCTUnwrap(valid.commands[0].configurationFields.last)
        XCTAssertEqual(folder.usedWhen, CommandConfigurationFieldCondition(key: "mode", values: ["Save"]))
        XCTAssertTrue(folder.isUsed(by: ["mode": .string("Save")]))
        XCTAssertFalse(folder.isUsed(by: ["mode": .string("Copy")]))

        for invalid in [#"{"key": "missing", "values": ["Save"]}"#, #"{"key": "note", "values": ["Save"]}"#,
                        #"{"key": "mode", "values": ["Print"]}"#, #"{"key": "mode", "values": []}"#,
                        #"{"key": "folder", "values": ["Save"]}"#] {
            XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(usedWhen: invalid)), invalid)
        }
    }

    /// The input is an object with exactly one value of the declared kind per
    /// key, and a choice must be one of its choices.
    func testConfigurationFieldsInputIsAnObjectOfDeclaredValues() throws {
        let command = try XCTUnwrap(PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "id": "com.example.fields", "name": "Fields", "version": "1.0.0",
          "commands": [{"id": "run", "title": "Run", "execution": "javascript", "is_configurable": true, "script": "run.js",
                        "configuration_fields": [{"key": "format", "kind": "choice", "choices": ["PNG", "JPEG"]},
                                                 {"key": "folder", "kind": "folder"}]}]
        }
        """.utf8)).commands.first)
        XCTAssertTrue(command.acceptsConfigurationFieldsInput(.object(["format": .string("PNG"), "folder": .string("/tmp")])))
        XCTAssertTrue(command.acceptsConfigurationFieldsInput(.object(["format": .string("JPEG"), "folder": .string("")])))
        XCTAssertFalse(command.acceptsConfigurationFieldsInput(.object(["format": .string("GIF"), "folder": .string("/tmp")])))
        XCTAssertFalse(command.acceptsConfigurationFieldsInput(.string("/tmp")))
        XCTAssertFalse(command.acceptsConfigurationFieldsInput(.object(["format": .string("PNG")])))
        XCTAssertFalse(command.acceptsConfigurationFieldsInput(.object(["format": .string("PNG"), "folder": .number(1)])))
        XCTAssertFalse(command.acceptsConfigurationFieldsInput(.object([
            "format": .string("PNG"), "folder": .string("/tmp"), "extra": .string("x")
        ])))
    }
}
