import Foundation
import XCTest
@testable import SpinnetCore

/// `PluginAPI/schemas/manifest.schema.json` is the published shape of a
/// manifest (ADR 0013). Every Bundled Plugin must satisfy it, and it must turn
/// away the mistakes a Plugin author is likely to make.
final class ManifestSchemaTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func validator() throws -> JSONSchemaSubsetValidator {
        try JSONSchemaSubsetValidator(schemaAt: Self.repositoryRoot
            .appendingPathComponent("PluginAPI/schemas/manifest.schema.json"))
    }

    private func bundledManifestURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: Self.repositoryRoot.appendingPathComponent("Plugins"), includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "spinnetplugin" }
        .map { $0.appendingPathComponent("manifest.json") }
        .sorted { $0.path < $1.path }
    }

    func testEveryBundledManifestValidatesAndDeclaresItsLevel() throws {
        let validator = try validator()
        let urls = try bundledManifestURLs()
        XCTAssertEqual(urls.count, 17, "Seventeen Bundled Plugins ship with Spinnet")

        for url in urls {
            let name = url.deletingLastPathComponent().lastPathComponent
            let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            XCTAssertEqual(validator.errors(for: manifest), [], name)
            guard case .object(let members) = manifest else { continue }
            XCTAssertEqual(members["api_level"], .number(1), "\(name) declares Plugin API Level 1")
        }
    }

    /// A small manifest using a Host Command, a JavaScript Command, a scoped
    /// Capability, a Plugin Setting and a migration, so each invalid case below
    /// changes one thing about something the schema otherwise accepts.
    private static let valid: JSONValue = try! JSONDecoder().decode(JSONValue.self, from: Data("""
    {
      "protocol_version": "1.0",
      "api_level": 1,
      "id": "com.example.plugin",
      "name": "Example",
      "version": "1.0.0",
      "capabilities": ["read_selected_text", "contact_https"],
      "capability_scopes": [{
        "capability": "contact_https", "command_ids": ["example.fetch"], "data_types": ["text"],
        "includes_existing_host_data": false, "https_hosts": ["api.example.com"], "external_apps": []
      }],
      "settings_fields": [{"key": "mode", "kind": "choice", "title": "Mode", "choices": ["fast", "slow"]}],
      "default_settings": {"mode": "fast"},
      "preset": {"readiness": "ready_to_use", "is_configurable": true, "default_primary_command_id": "example.fetch"},
      "commands": [
        {"id": "example.open", "title": "Open", "execution": "host", "is_configurable": true, "host_command": "url.open"},
        {"id": "example.fetch", "title": "Fetch", "execution": "javascript", "is_configurable": false, "script": "fetch.js"}
      ],
      "migrations": {
        "rename_commands": {"example.download": "example.fetch"},
        "rename_settings": {"speed": "mode"},
        "drop_input": ["example.fetch"]
      }
    }
    """.utf8))

    private func changed(_ change: (inout [String: JSONValue]) -> Void) -> JSONValue {
        guard case .object(var members) = Self.valid else { fatalError("The valid manifest is an object") }
        change(&members)
        return .object(members)
    }

    /// Replaces one member of the `index`th element of a top-level array.
    private func changed(_ array: String, _ index: Int, _ change: @escaping (inout [String: JSONValue]) -> Void) -> JSONValue {
        changed { members in
            guard case .array(var elements) = members[array], case .object(var element) = elements[index] else { return }
            change(&element)
            elements[index] = .object(element)
            members[array] = .array(elements)
        }
    }

    func testTheValidManifestValidates() throws {
        XCTAssertEqual(try validator().errors(for: Self.valid), [])
    }

    /// The validator implements only the keywords the schema uses, so a
    /// schema that starts using another must fail here rather than pass with
    /// the keyword ignored.
    func testTheValidatorRefusesAKeywordItDoesNotImplement() {
        let validator = JSONSchemaSubsetValidator(schema: .object(["oneOf": .array([.bool(true)])]))

        XCTAssertFalse(validator.errors(for: .null).isEmpty)
    }

    /// Each case names the value at fault as a JSON Pointer, so a manifest
    /// rejected for some other reason does not pass for this one.
    func testKnownInvalidManifestsAreRejected() throws {
        let validator = try validator()
        let cases: [(String, JSONValue, String)] = [
            ("no api_level", changed { $0["api_level"] = nil }, ""),
            ("api_level 0", changed { $0["api_level"] = .number(0) }, "/api_level"),
            ("fractional api_level", changed { $0["api_level"] = .number(1.5) }, "/api_level"),
            ("api_level as a string", changed { $0["api_level"] = .string("1") }, "/api_level"),
            ("another protocol_version", changed { $0["protocol_version"] = .string("2.0") }, "/protocol_version"),
            ("blank id", changed { $0["id"] = .string("  ") }, "/id"),
            ("name over 256 characters", changed { $0["name"] = .string(String(repeating: "n", count: 257)) }, "/name"),
            ("no commands", changed { $0["commands"] = .array([]) }, "/commands"),
            ("misspelt member", changed { $0["capabilites"] = .array([]) }, "/capabilites"),
            ("unknown Capability", changed { $0["capabilities"] = .array([.string("read_minds")]) }, "/capabilities/0"),
            ("repeated Capability", changed {
                $0["capabilities"] = .array([.string("read_selected_text"), .string("read_selected_text")])
            }, "/capabilities"),
            ("unknown execution", changed("commands", 1) { $0["execution"] = .string("python") }, "/commands/1/execution"),
            ("JavaScript Command without a script", changed("commands", 1) { $0["script"] = nil }, "/commands/1"),
            ("script outside the package", changed("commands", 1) { $0["script"] = .string("../escape.js") },
             "/commands/1/script"),
            ("Host Command without host_command", changed("commands", 0) { $0["host_command"] = nil }, "/commands/0"),
            ("Host Command with a script", changed("commands", 0) { $0["script"] = .string("open.js") },
             "/commands/0/script"),
            ("unknown host_command", changed("commands", 0) { $0["host_command"] = .string("disk.erase") },
             "/commands/0/host_command"),
            ("deep_link.open without its template", changed("commands", 0) {
                $0["host_command"] = .string("deep_link.open")
            }, "/commands/0"),
            ("a script naming a Deep Link Template", changed("commands", 1) {
                $0["deep_link_template"] = .string("open")
            }, "/commands/1/deep_link_template"),
            ("a Deep Link Template without a URL", changed("capability_scopes", 0) {
                $0["external_apps"] = .array([.object([
                    "bundle_id": .string("com.example.app"), "name": .string("App"),
                    "deep_link_templates": .array([.object(["id": .string("open")])])
                ])])
            }, "/capability_scopes/0/external_apps/0/deep_link_templates/0"),
            ("a text parameter without a bound", changed("capability_scopes", 0) {
                $0["external_apps"] = .array([.object([
                    "bundle_id": .string("com.example.app"), "name": .string("App"),
                    "deep_link_templates": .array([.object([
                        "id": .string("find"), "url": .string("example-app://find?q={q}"),
                        "parameters": .array([.object(["key": .string("q"), "kind": .string("text")])])
                    ])])
                ])])
            }, "/capability_scopes/0/external_apps/0/deep_link_templates/0/parameters/0"),
            ("unknown field kind", changed("settings_fields", 0) { $0["kind"] = .string("slider") },
             "/settings_fields/0/kind"),
            ("choice without choices", changed("settings_fields", 0) { $0["choices"] = nil }, "/settings_fields/0"),
            ("list without columns", changed("settings_fields", 0) {
                $0["kind"] = .string("list")
                $0["choices"] = nil
            }, "/settings_fields/0"),
            ("list column of an unknown kind", changed("settings_fields", 0) {
                $0["kind"] = .string("list")
                $0["choices"] = nil
                $0["columns"] = .array([.object(["key": .string("n"), "kind": .string("toggle")])])
            }, "/settings_fields/0/columns/0/kind"),
            ("list of over 100 rows", changed("settings_fields", 0) {
                $0["kind"] = .string("list")
                $0["choices"] = nil
                $0["columns"] = .array([.object(["key": .string("n"), "kind": .string("text")])])
                $0["max_rows"] = .number(101)
            }, "/settings_fields/0/max_rows"),
            ("max_length on a URL template column", changed("settings_fields", 0) {
                $0["kind"] = .string("list")
                $0["choices"] = nil
                $0["columns"] = .array([.object(["key": .string("u"), "kind": .string("url_template"),
                                                 "max_length": .number(20)])])
            }, "/settings_fields/0/columns/0/kind"),
            ("field key over 64 characters", changed("settings_fields", 0) {
                $0["key"] = .string(String(repeating: "k", count: 65))
            }, "/settings_fields/0/key"),
            ("scope naming user-consented hosts", changed("capability_scopes", 0) {
                $0["consented_https_hosts"] = .array([.string("self-hosted.example.com")])
            }, "/capability_scopes/0/consented_https_hosts"),
            ("scope without command_ids", changed("capability_scopes", 0) { $0["command_ids"] = nil },
             "/capability_scopes/0"),
            ("HTTPS host with a scheme", changed("capability_scopes", 0) {
                $0["https_hosts"] = .array([.string("https://api.example.com")])
            }, "/capability_scopes/0/https_hosts/0"),
            ("unknown readiness", changed { $0["preset"] = .object([
                "readiness": .string("sometimes"), "is_configurable": .bool(true)
            ]) }, "/preset/readiness"),
            ("migration granting a Capability", changed { $0["migrations"] = .object([
                "grant_capabilities": .array([.string("read_selected_text")])
            ]) }, "/migrations/grant_capabilities"),
            ("Command renamed to a non-string", changed { $0["migrations"] = .object([
                "rename_commands": .object(["example.download": .bool(true)])
            ]) }, "/migrations/rename_commands/example.download"),
            ("blank settings key rename", changed { $0["migrations"] = .object([
                "rename_settings": .object(["speed": .string(" ")])
            ]) }, "/migrations/rename_settings/speed"),
            ("drop_input as one Command ID", changed { $0["migrations"] = .object([
                "drop_input": .string("example.fetch")
            ]) }, "/migrations/drop_input")
        ]

        for (name, manifest, pointer) in cases {
            let errors = validator.errors(for: manifest)
            XCTAssertTrue(errors.contains { $0.hasPrefix(pointer + ": ") },
                          "A manifest with \(name) must be rejected at \"\(pointer)\", got \(errors)")
        }
    }
}

/// The manifest schema has to say what the Host reads and what
/// docs/plugin-interface.md promises. The Host side compares the schema with
/// the Swift types that decode a manifest; the prose side, like
/// `DocumentedBudgetsTests`, compares it with literals copied from the
/// document, so changing either means changing the other in the same commit.
final class DocumentedManifestSchemaTests: XCTestCase {
    private func schema() throws -> [String: JSONValue] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PluginAPI/schemas/manifest.schema.json")
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)) else {
            throw ConfigurationError.malformedValue("The manifest schema is not an object")
        }
        return schema
    }

    private func definition(_ name: String) throws -> [String: JSONValue] {
        guard case .object(let definitions)? = try schema()["$defs"],
              case .object(let definition)? = definitions[name] else {
            throw ConfigurationError.malformedValue("The manifest schema does not define \(name)")
        }
        return definition
    }

    private func allowedValues(of name: String) throws -> Set<String> {
        guard case .array(let values)? = try definition(name)["enum"] else { return [] }
        return Set(values.compactMap { if case .string(let value) = $0 { return value }; return nil })
    }

    func testTheSchemaAllowsWhatTheHostDecodes() throws {
        XCTAssertEqual(try allowedValues(of: "capability"), Set(PluginCapability.allCases.map(\.rawValue)))
        XCTAssertEqual(try allowedValues(of: "hostCommand"), Set(HostCommand.allCases.map(\.rawValue)))
        XCTAssertEqual(try allowedValues(of: "fieldKind"),
                       Set(CommandConfigurationFieldKind.allCases.map(\.rawValue)))
        guard case .object(let properties)? = try schema()["properties"],
              case .object(let protocolVersion)? = properties["protocol_version"] else {
            return XCTFail("The schema does not describe protocol_version")
        }
        XCTAssertEqual(protocolVersion["const"], .string(PluginManifest.supportedProtocolVersion))
    }

    /// docs/plugin-interface.md, "Manifest"
    func testTheSchemaMatchesTheDocumentedManifest() throws {
        // "`id`, `name`, `version`, Command IDs, and Command titles must be
        //  non-empty and no longer than 256 characters."
        XCTAssertEqual(try definition("text")["minLength"], .number(1))
        XCTAssertEqual(try definition("text")["maxLength"], .number(256))

        // "to select the Host-rendered field kind: `text`, `multiline_text`,
        //  `toggle`, `choice`, `application`, `file`, `folder`, `shortcut`,
        //  `keyboard_shortcut`, `url`, `size`, or `position`." Then
        //  "`configuration_fields` may also hold `multiline_text`, `credential`,
        //  and `https_endpoint`", and Plugin Settings "take the same kinds as
        //  `configuration_fields`, plus `ordered_choices` and `list`".
        XCTAssertEqual(try allowedValues(of: "fieldKind"), [
            "text", "multiline_text", "toggle", "choice", "application", "file", "folder", "shortcut",
            "keyboard_shortcut", "url", "size", "position", "credential", "https_endpoint",
            "ordered_choices", "list"
        ])

        // "The supported Host Command catalogue is:"
        XCTAssertEqual(try allowedValues(of: "hostCommand"), [
            "url.open", "application.open", "file.open", "folder.open", "keyboard_shortcut.invoke",
            "service.invoke", "shortcut.invoke", "clipboard.copy", "clipboard.paste", "clipboard.cut",
            "feedback.present", "screen.capture_area", "screen.capture_full_screen", "screen.capture_window",
            "deep_link.open"
        ])
    }
}
