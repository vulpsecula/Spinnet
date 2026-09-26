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
                          capabilities: String = "", scopes: String = "") throws -> PluginManifest {
        try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "id": "com.example.remote", "name": "Remote", "version": "1.0.0",
          "capabilities": [\(capabilities)],
          "capability_scopes": [\(scopes)],
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
            ("used_when naming a text field", { try self.manifest(settings: #"[{"key": "m", "kind": "text"}, {"key": "a", "kind": "text", "used_when": {"key": "m", "values": ["x"]}}]"#, defaults: "{}") }),
            ("used_when naming an unknown choice", { try self.manifest(settings: #"[{"key": "m", "kind": "choice", "choices": ["x"]}, {"key": "a", "kind": "text", "used_when": {"key": "m", "values": ["y"]}}]"#, defaults: "{}") }),
            ("ordered choices without choices", { try self.manifest(settings: #"[{"key": "s", "kind": "ordered_choices"}]"#, defaults: "{}") }),
            ("ordered choices overridable", { try self.manifest(settings: #"[{"key": "s", "kind": "ordered_choices", "choices": ["a"], "overridable": true}]"#, defaults: "{}") }),
            ("ordered choices default repeating a choice", { try self.manifest(settings: #"[{"key": "s", "kind": "ordered_choices", "choices": ["a", "b"]}]"#, defaults: #"{"s": ["a", "a"]}"#) }),
            ("ordered choices on a Command", { try self.manifest(commandFields: #", "configuration_fields": [{"key": "s", "kind": "ordered_choices", "choices": ["a"]}]"#) }),
            ("a group on a Command field", { try self.manifest(commandFields: #", "configuration_fields": [{"key": "m", "kind": "text", "group": "Server"}]"#) }),
            ("choice titles that miss a choice", { try self.manifest(settings: #"[{"key": "a", "kind": "choice", "choices": ["x", "y"], "choice_titles": ["Ex"]}]"#, defaults: "{}") }),
            ("a list on a Command", { try self.manifest(commandFields: #", "configuration_fields": [{"key": "s", "kind": "list", "columns": [{"key": "n", "kind": "text"}]}]"#) }),
            ("a list as a Command's lone field", { try self.manifest(commandFields: #", "configuration_field": {"key": "s", "kind": "list", "columns": [{"key": "n", "kind": "text"}]}"#) }),
            ("a list overridable", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": [{"key": "n", "kind": "text"}], "overridable": true}]"#, defaults: "{}") }),
            ("a list without columns", { try self.manifest(settings: #"[{"key": "s", "kind": "list"}]"#, defaults: "{}") }),
            ("a list with no columns", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": []}]"#, defaults: "{}") }),
            ("a list repeating a column key", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": [{"key": "n", "kind": "text"}, {"key": "n", "kind": "url_template"}]}]"#, defaults: "{}") }),
            ("a list column without a key", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": [{"key": " ", "kind": "text"}]}]"#, defaults: "{}") }),
            ("a list column of an unknown kind", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": [{"key": "n", "kind": "toggle"}]}]"#, defaults: "{}") }),
            ("a length on a URL template column", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": [{"key": "u", "kind": "url_template", "max_length": 20}]}]"#, defaults: "{}") }),
            ("a text column length of 0", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": [{"key": "n", "kind": "text", "max_length": 0}]}]"#, defaults: "{}") }),
            ("a list of 0 rows at most", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": [{"key": "n", "kind": "text"}], "max_rows": 0}]"#, defaults: "{}") }),
            ("a list of over 100 rows", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": [{"key": "n", "kind": "text"}], "max_rows": 101}]"#, defaults: "{}") }),
            ("columns on a text field", { try self.manifest(settings: #"[{"key": "s", "kind": "text", "columns": [{"key": "n", "kind": "text"}]}]"#, defaults: "{}") }),
            ("max_rows on a text field", { try self.manifest(settings: #"[{"key": "s", "kind": "text", "max_rows": 3}]"#, defaults: "{}") }),
            ("a list default that breaks its columns", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": [{"key": "u", "kind": "url_template"}]}]"#, defaults: #"{"s": [{"u": "http://example.com/?q={query}"}]}"#) }),
            ("a list default written as text", { try self.manifest(settings: #"[{"key": "s", "kind": "list", "columns": [{"key": "n", "kind": "text"}]}]"#, defaults: #"{"s": "a"}"#) }),
            ("default for an unknown key", { try self.manifest(defaults: #"{"other": "x"}"#) }),
            ("invalid default", { try self.manifest(defaults: #"{"target": "IT"}"#) }),
            ("clashes with a Command field", { try self.manifest(commandFields: #", "configuration_fields": [{"key": "target", "kind": "text"}]"#) }),
            ("overridable on a Command field", { try self.manifest(commandFields: #", "configuration_fields": [{"key": "mode", "kind": "text", "overridable": true}]"#) })
        ]
        for (name, make) in cases {
            XCTAssertThrowsError(try make(), name)
        }
    }

    // MARK: - Ordered choices and conditional settings

    private static let sourceSettings = """
    [{"key": "sources", "kind": "ordered_choices", "title": "Sources", "choices": ["DeepL", "Google", "OpenAI"]},
     {"key": "deepl_key", "kind": "credential", "used_when": {"key": "sources", "values": ["DeepL"]}},
     {"key": "deepl_endpoint", "kind": "https_endpoint", "used_when": {"key": "sources", "values": ["DeepL"]}},
     {"key": "openai_model", "kind": "text", "used_when": {"key": "sources", "values": ["OpenAI"]}}]
    """

    /// An `ordered_choices` setting holds some of its choices, each once, in
    /// the order the user put them: which sources are on, and in what order.
    func testAnOrderedChoicesSettingHoldsSomeOfItsChoicesInOrder() throws {
        let manifest = try manifest(settings: Self.sourceSettings, defaults: #"{"sources": ["DeepL"], "deepl_key": "deepl"}"#)
        let field = manifest.settingsFields[0]
        XCTAssertEqual(field.kind, .orderedChoices)
        XCTAssertTrue(field.acceptsMemberValue(.array([.string("OpenAI"), .string("DeepL")])))
        XCTAssertTrue(field.acceptsMemberValue(.array([])))
        XCTAssertFalse(field.acceptsMemberValue(.array([.string("DeepL"), .string("DeepL")])), "each choice once")
        XCTAssertFalse(field.acceptsMemberValue(.array([.string("Bing")])))
        XCTAssertFalse(field.acceptsMemberValue(.string("DeepL")))
        XCTAssertEqual(manifest.resolvedSettings(stored: ["sources": .array([.string("OpenAI"), .string("DeepL")])])["sources"],
                       .array([.string("OpenAI"), .string("DeepL")]))
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
    }

    /// A setting used only while a source is on needs no value while it is
    /// off, and an empty list of sources is itself missing.
    func testASettingUsedOnlyForAChoiceIsNotNeededWhileThatChoiceIsOff() throws {
        let manifest = try manifest(settings: Self.sourceSettings, defaults: #"{"sources": ["DeepL"], "deepl_key": "deepl"}"#)
        var values = manifest.resolvedSettings(stored: [:])
        values["deepl_endpoint"] = .string("https://api-free.deepl.com")
        XCTAssertEqual(manifest.missingSettings(in: values, hasSecret: { _ in true }), [], "the OpenAI model is not used")
        values["sources"] = .array([.string("OpenAI")])
        XCTAssertEqual(manifest.missingSettings(in: values, hasSecret: { _ in false }).map(\.key), ["openai_model"],
                       "DeepL is off, so its key and endpoint are not needed")
        values["sources"] = .array([])
        XCTAssertEqual(manifest.missingSettings(in: values, hasSecret: { _ in true }).map(\.key), ["sources"],
                       "at least one source is needed")
        XCTAssertTrue(manifest.settingsFields[1].isUsed(by: ["sources": .array([.string("Google"), .string("DeepL")])]))
        XCTAssertFalse(manifest.settingsFields[1].isUsed(by: ["sources": .array([.string("Google")])]))
    }

    /// An endpoint for a source that is off sends nothing, so it needs no consent.
    func testAnEndpointForASourceThatIsOffNeedsNoConsent() throws {
        let scoped = try manifest(settings: Self.sourceSettings, defaults: #"{"sources": ["DeepL"]}"#,
                                  capabilities: #""contact_https""#,
                                  scopes: #"{"capability": "contact_https", "command_ids": ["remote.run"], "data_types": ["text"], "includes_existing_host_data": false, "https_hosts": ["api.deepl.com"], "external_apps": []}"#)
        let grants = PluginCapabilityGrantStore()
        let selfHosted: [String: JSONValue] = ["deepl_endpoint": .string("https://deepl.example.org")]
        XCTAssertEqual(HTTPSEndpointConsent(manifest: scoped, settings: selfHosted.merging(["sources": .array([.string("DeepL")])]) { $1 },
                                            grantStore: grants).newHosts, ["deepl.example.org"])
        XCTAssertEqual(HTTPSEndpointConsent(manifest: scoped, settings: selfHosted.merging(["sources": .array([.string("OpenAI")])]) { $1 },
                                            grantStore: grants).newHosts, [])
    }

    /// A Plugin with many settings reads as a few short groups, and a choice
    /// may show a name in place of the code it stores.
    func testSettingsCarryTheirGroupAndTheirChoiceTitles() throws {
        let manifest = try manifest(settings: """
        [{"key": "sources", "kind": "ordered_choices", "choices": ["DeepL"]},
         {"key": "target", "kind": "choice", "title": "Target", "group": "Languages",
          "choices": ["EN-US", "ZH-HANS"], "choice_titles": ["English", "Simplified Chinese"]},
         {"key": "endpoint", "kind": "https_endpoint", "title": "Endpoint", "group": "DeepL"}]
        """, defaults: "{}")
        XCTAssertEqual(manifest.settingsFields.map(\.group), [nil, "Languages", "DeepL"])
        let target = manifest.settingsFields[1]
        XCTAssertEqual(target.displayTitle(forChoice: "ZH-HANS"), "Simplified Chinese")
        XCTAssertEqual(target.displayTitle(forChoice: "DE"), "DE", "An unknown choice shows itself")
        XCTAssertEqual(manifest.settingsFields[0].displayTitle(forChoice: "DeepL"), "DeepL",
                       "Without titles a choice shows itself")
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
    }

    // MARK: - Lists

    private static let listSettings = """
    [{"key": "sites", "kind": "list", "title": "Sites", "max_rows": 3, "columns": [
       {"key": "name", "kind": "text", "title": "Name", "unique": true, "max_length": 10},
       {"key": "url", "kind": "url_template", "title": "URL", "placeholder": "https://example.com/?q={query}"}]}]
    """

    private func row(_ name: String, _ url: String) -> JSONValue {
        .object(["name": .string(name), "url": .string(url)])
    }

    /// A `list` setting holds rows of typed cells in the order the user put
    /// them: a JSON array of objects holding one string per column.
    func testAListSettingHoldsRowsOfTypedCellsInOrder() throws {
        let manifest = try manifest(settings: Self.listSettings,
                                    defaults: #"{"sites": [{"name": "A", "url": "https://a.example/?q={query}"}]}"#)
        let field = manifest.settingsFields[0]
        XCTAssertEqual(field.kind, .list)
        XCTAssertEqual(field.columns.map(\.key), ["name", "url"])
        XCTAssertEqual(field.columns.map(\.kind), [.text, .urlTemplate])
        XCTAssertEqual(field.columns.map(\.unique), [true, false])
        XCTAssertEqual(field.columns.map(\.maxLength), [10, nil])
        XCTAssertEqual(field.columns[1].placeholder, "https://example.com/?q={query}")
        XCTAssertEqual(field.maxRows, 3)

        let rows: JSONValue = .array([row("B", "https://b.example/search/{query}"), row("A", "https://a.example/?q={query}")])
        XCTAssertTrue(field.acceptsMemberValue(rows))
        XCTAssertTrue(field.acceptsMemberValue(.array([])), "an empty list is a list, though it is missing")
        XCTAssertEqual(manifest.resolvedSettings(stored: ["sites": rows])["sites"], rows)
        XCTAssertEqual(manifest.missingSettings(in: ["sites": .array([])], hasSecret: { _ in true }).map(\.key), ["sites"])
        XCTAssertEqual(manifest.missingSettings(in: ["sites": rows], hasSecret: { _ in true }), [])

        let decoded = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
    }

    /// Each cell is checked against its column. A stored list that fails is
    /// not used and the default stands in, as for any other invalid value.
    func testAListRefusesRowsThatBreakItsColumns() throws {
        let manifest = try manifest(settings: Self.listSettings,
                                    defaults: #"{"sites": [{"name": "D", "url": "https://d.example/?q={query}"}]}"#)
        let field = manifest.settingsFields[0]
        let good = "https://a.example/?q={query}"
        let cases: [(String, JSONValue)] = [
            ("a row that is not an object", .array([.string("A")])),
            ("a missing cell", .array([.object(["name": .string("A")])])),
            ("an extra cell", .array([.object(["name": .string("A"), "url": .string(good), "x": .string("")])])),
            ("a cell that is not text", .array([.object(["name": .number(1), "url": .string(good)])])),
            ("a blank text cell", .array([row("  ", good)])),
            ("a text cell over its length", .array([row(String(repeating: "n", count: 11), good)])),
            ("a text cell of two lines", .array([row("A\nB", good)])),
            ("a repeated unique cell", .array([row("A", good), row(" A ", "https://b.example/?q={query}")])),
            ("more rows than max_rows", .array((1...4).map { row("N\($0)", good) })),
            ("an invalid URL template", .array([row("A", "https://example.com")]))
        ]
        for (name, value) in cases {
            XCTAssertFalse(field.acceptsMemberValue(value), name)
            XCTAssertNotNil(field.listProblem(value), name)
            XCTAssertEqual(manifest.resolvedSettings(stored: ["sites": value])["sites"],
                           .array([row("D", "https://d.example/?q={query}")]), name)
        }
        XCTAssertNil(field.listProblem(.array([row("A", good)])))
        XCTAssertEqual(field.listProblem(.array([row("A", good), row("A", "https://b.example/?q={query}")])),
                       "Row 2 of Sites repeats the Name of row 1.")
        XCTAssertEqual(field.listProblem(.array([row("A", "http://a.example/?q={query}")])),
                       "Row 1 of Sites: URL must be an https address with {query} once in its path or query, such as https://example.com/search?q={query}.")
    }

    /// A `url_template` cell is an https address holding `{query}` exactly
    /// once, in its path or query, never where it could change the host.
    func testAURLTemplateCellHoldsOneQueryInAnHTTPSPathOrQuery() throws {
        let column = try manifest(settings: Self.listSettings, defaults: "{}").settingsFields[0].columns[1]
        for template in ["https://example.com/search?q={query}", "https://example.com/wiki/{query}",
                         "https://example.com/?a=1&q={query}&b=2", "HTTPS://Example.com/{query}"] {
            XCTAssertTrue(column.accepts(template), template)
        }
        for template in ["", "https://example.com", "https://example.com/?q={query}&r={query}",
                         "javascript:{query}", "http://example.com/search?q={query}", "https://{query}.com/",
                         "https://example.com:{query}/", "https://user:secret@example.com/?q={query}",
                         "https://example.com/#{query}", "https://example.com/?q={query} x",
                         "https://example.com/?q={QUERY}",
                         "https://example.com/?q=" + String(repeating: "x", count: 2048) + "{query}"] {
            XCTAssertFalse(column.accepts(template), template)
        }
    }

    /// Settings saved before `list` existed held the rows as text, one per
    /// line with cells separated by `|`. They load as rows in their order,
    /// and are written as a list the next time the settings save.
    func testAListStoredAsTextLoadsAsRowsInItsOrder() throws {
        let manifest = try manifest(settings: Self.listSettings,
                                    defaults: #"{"sites": [{"name": "D", "url": "https://d.example/?q={query}"}]}"#)
        let stored: JSONValue = .string("B | https://b.example/search/{query}\n\n  A|https://a.example/?q={query}  \n")
        XCTAssertEqual(manifest.resolvedSettings(stored: ["sites": stored])["sites"], .array([
            row("B", "https://b.example/search/{query}"), row("A", "https://a.example/?q={query}")
        ]))
        for invalid in ["", "A", "A | http://a.example/?q={query}", "A | https://a.example/?q={query} | x",
                        "A | https://a.example/?q={query}\nA | https://b.example/?q={query}"] {
            XCTAssertEqual(manifest.resolvedSettings(stored: ["sites": .string(invalid)])["sites"],
                           .array([row("D", "https://d.example/?q={query}")]), invalid)
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
