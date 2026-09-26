import XCTest
@testable import SpinnetCore

/// A manifest's `migrations` block says how the data an earlier version of
/// the Plugin left behind maps onto this one: it renames Commands, renames
/// settings keys, and drops the input of Actions whose Command takes none. It
/// can do nothing else, so it never grants a Capability, and the Host applies
/// it every time it registers or updates the Plugin, so applying it again must
/// change nothing.
final class PluginMigrationsTests: XCTestCase {
    private func manifest(migrations: String, capabilities: String = "") throws -> PluginManifest {
        try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "api_level": 1, "id": "com.example.notes", "name": "Notes", "version": "2.0.0",
          "capabilities": [\(capabilities)],
          "settings_fields": [{"key": "server_endpoint", "kind": "https_endpoint", "title": "Endpoint"},
                              {"key": "tone", "kind": "choice", "title": "Tone", "choices": ["plain", "warm"]}],
          "default_settings": {"server_endpoint": "https://notes.example.com", "tone": "plain"},
          "commands": [
            {"id": "notes.save", "title": "Save Note", "execution": "javascript", "is_configurable": false,
             "script": "notes.js"},
            {"id": "notes.append", "title": "Append to Note", "execution": "javascript", "is_configurable": true,
             "script": "notes.js"}
          ],
          "migrations": \(migrations)
        }
        """.utf8))
    }

    private static let migrations = """
    {"rename_commands": {"notes.copy": "notes.save"},
     "rename_settings": {"endpoint": "server_endpoint"},
     "drop_input": ["notes.save"]}
    """

    private func retired(_ id: String, _ command: String, input: JSONValue) throws -> ActionConfiguration {
        try ActionConfiguration(
            id: ActionID(id), pluginID: PluginID("com.example.notes"),
            command: CommandDeclaration(id: CommandID(command), title: "Copy Note", execution: .javascript,
                                        isConfigurable: true, script: "notes.js"),
            input: input
        )
    }

    // MARK: - Manifest

    func testTheBlockDecodesAndRoundTrips() throws {
        let manifest = try manifest(migrations: Self.migrations)

        XCTAssertEqual(manifest.migrations.renamedCommands, [CommandID("notes.copy"): CommandID("notes.save")])
        XCTAssertEqual(manifest.migrations.renamedSettings, ["endpoint": "server_endpoint"])
        XCTAssertEqual(manifest.migrations.droppedInputs, [CommandID("notes.save")])
        XCTAssertEqual(try PluginManifestLoader.decode(JSONEncoder().encode(manifest)), manifest)
    }

    func testAManifestWithoutMigrationsHasNone() throws {
        let manifest = try manifest(migrations: "{}")

        XCTAssertTrue(manifest.migrations.isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self).contains("migrations"))
    }

    /// Only the three kinds of step exist. Anything else is refused when the
    /// manifest loads, before the Host could apply it.
    func testAMigrationThatTriesToGrantACapabilityIsRejected() {
        for attempt in [
            #"{"grant_capabilities": ["read_selected_text"]}"#,
            #"{"capabilities": {"read_selected_text": "granted"}}"#,
            #"{"rename_commands": {"notes.copy": "notes.save"}, "capability_grants": [{"capability": "read_selected_text"}]}"#
        ] {
            XCTAssertThrowsError(try manifest(migrations: attempt, capabilities: #""read_selected_text""#), attempt) { error in
                XCTAssertEqual(error as? ConfigurationError, .invalidManifest(
                    "A migration may only rename Commands, rename settings keys, and drop an Action's input; "
                        + "it never grants a Capability"
                ), attempt)
            }
        }
    }

    func testStepsMustLeadToWhatThisVersionDeclares() {
        let cases: [(String, String)] = [
            (#"{"rename_commands": {"notes.copy": "notes.paste"}}"#, "a rename to an undeclared Command"),
            (#"{"rename_commands": {"notes.append": "notes.save"}}"#, "a rename of a declared Command"),
            (#"{"rename_commands": {"notes.copy": "notes.save", "notes.cut": "notes.copy"}}"#, "a chain of renames"),
            (#"{"rename_settings": {"endpoint": "url"}}"#, "a rename to an undeclared setting"),
            (#"{"rename_settings": {"tone": "server_endpoint"}}"#, "a rename of a declared setting"),
            (#"{"drop_input": ["notes.paste"]}"#, "dropping the input of an undeclared Command"),
            (#"{"drop_input": ["notes.append"]}"#, "dropping the input of a configurable Command"),
            (#"{"drop_input": ["notes.save", "notes.save"]}"#, "dropping the same input twice")
        ]
        for (migrations, name) in cases {
            XCTAssertThrowsError(try manifest(migrations: migrations), name)
        }
    }

    // MARK: - Applying

    func testRetiredActionsMoveOntoTheRenamedCommandAndDropTheirInput() throws {
        let manifest = try manifest(migrations: Self.migrations)
        let append = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == "notes.append" })
        let kept = try ActionConfiguration(id: ActionID("append"), pluginID: manifest.id, command: append,
                                           input: .string("Groceries"))
        let other = try ActionConfiguration(
            id: ActionID("other"), pluginID: PluginID("com.example.other"),
            command: CommandDeclaration(id: CommandID("notes.copy"), title: "Copy", execution: .javascript,
                                        script: "copy.js"),
            input: .object(["tone": .string("warm")])
        )
        let configuration = try HostConfiguration(
            actions: [try retired("copy", "notes.copy", input: .object(["tone": .string("warm")])), kept, other],
            menu: MenuConfiguration(slots: [
                .occupied(try MenuItemConfiguration(primaryActionID: ActionID("copy"),
                                                    alternateActionIDs: [ActionID("append")], alias: "Notes")),
                .occupied(try MenuItemConfiguration(primaryActionID: ActionID("other")))
            ])
        )

        let migrated = try XCTUnwrap(manifest.migrate(configuration))

        XCTAssertEqual(migrated.menu, configuration.menu, "Slots, aliases and bindings are kept")
        XCTAssertEqual(migrated.actions.map(\.id), configuration.actions.map(\.id))
        XCTAssertEqual(migrated.actions[0], try ActionConfiguration(
            id: ActionID("copy"), pluginID: manifest.id, command: manifest.commands[0], input: .null
        ))
        XCTAssertEqual(migrated.actions[1], kept, "A configurable Command's Action keeps what the user set")
        XCTAssertEqual(migrated.actions[2], other, "Another Plugin's Action is untouched, whatever its Command ID")
    }

    func testRetiredSettingsKeysMoveAndAValueUnderTheNewKeyWins() throws {
        let manifest = try manifest(migrations: Self.migrations)

        XCTAssertEqual(manifest.migrateSettings(["endpoint": .string("https://old.example"), "tone": .string("warm")]),
                       ["server_endpoint": .string("https://old.example"), "tone": .string("warm")])
        XCTAssertEqual(manifest.migrateSettings(["endpoint": .string("https://old.example"),
                                                 "server_endpoint": .string("https://new.example")]),
                       ["server_endpoint": .string("https://new.example")])
        XCTAssertNil(manifest.migrateSettings(["server_endpoint": .string("https://new.example")]),
                     "Nothing is left to move")
    }

    func testApplyingTheMigrationsTwiceChangesNothing() throws {
        let manifest = try manifest(migrations: Self.migrations)
        let configuration = try HostConfiguration(
            actions: [try retired("copy", "notes.copy", input: .object([:]))],
            menu: MenuConfiguration(slots: [.occupied(try MenuItemConfiguration(primaryActionID: ActionID("copy")))])
        )
        let once = try XCTUnwrap(manifest.migrate(configuration))
        let settings = try XCTUnwrap(manifest.migrateSettings(["endpoint": .string("https://old.example")]))

        XCTAssertNil(try manifest.migrate(once))
        XCTAssertNil(manifest.migrateSettings(settings))
    }

    func testAManifestWithoutMigrationsMovesNothing() throws {
        let manifest = try manifest(migrations: "{}")
        let configuration = try HostConfiguration(
            actions: [try retired("copy", "notes.copy", input: .object([:]))],
            menu: MenuConfiguration(slots: [.occupied(try MenuItemConfiguration(primaryActionID: ActionID("copy")))])
        )

        XCTAssertNil(try manifest.migrate(configuration))
        XCTAssertNil(manifest.migrateSettings(["endpoint": .string("https://old.example")]))
    }
}
