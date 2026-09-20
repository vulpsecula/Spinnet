import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Translator 2 replaced Translate Selection and Copy, and Translate
/// Selection in Place, with Translate Selection and Translate Input. Their
/// Actions move onto the new Commands at launch with their IDs, so every
/// Slot and alias stays as the user arranged it, and a Menu Item made from
/// the old default Preset becomes the new default one.
final class TranslatorCommandMigrationTests: XCTestCase {
    private func manifest() throws -> PluginManifest {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Plugins/Translator.spinnetplugin")).manifest
    }

    private func retired(_ id: String, _ command: String, title: String, input: JSONValue = .object([:])) throws -> ActionConfiguration {
        try ActionConfiguration(
            id: ActionID(id), pluginID: TranslatorCommandMigration.pluginID,
            command: CommandDeclaration(id: CommandID(command), title: title, execution: .javascript, script: "translate.js"),
            input: input
        )
    }

    func testRetiredTranslatorActionsMoveOntoTheNewCommands() throws {
        let manifest = try manifest()
        let clipboardCommand = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == "translator.clipboard" })
        let clipboard = try ActionConfiguration(id: ActionID("clip"), pluginID: manifest.id, command: clipboardCommand,
                                                input: .null)
        let url = try ActionConfiguration(
            id: ActionID("url"), pluginID: BuiltInPresetCatalog.openURLPluginID,
            command: CommandDeclaration(id: CommandID("builtin.open_url"), title: "Open URL", hostCommand: .openURL),
            input: .string("https://example.com")
        )
        let configuration = try HostConfiguration(
            actions: [try retired("copy", "translator.copy", title: "Translate Selection and Copy",
                                  input: .object(["target_language": .string("FR")])),
                      try retired("replace", "translator.replace", title: "Translate Selection in Place"),
                      clipboard, url],
            menu: MenuConfiguration(slots: [
                .occupied(try MenuItemConfiguration(primaryActionID: ActionID("copy"),
                                                    alternateActionIDs: [ActionID("replace"), ActionID("clip")], alias: "Translate")),
                .occupied(try MenuItemConfiguration(primaryActionID: ActionID("url")))
            ])
        )

        let migrated = try XCTUnwrap(TranslatorCommandMigration.migrate(configuration, manifest: manifest))

        XCTAssertEqual(migrated.menu, configuration.menu, "Slots, aliases and bindings are kept")
        XCTAssertEqual(migrated.actions.map(\.id), configuration.actions.map(\.id))
        XCTAssertEqual(migrated.actions.map(\.commandID.rawValue),
                       ["translator.selection", "translator.input", "translator.clipboard", "builtin.open_url"])
        XCTAssertEqual(migrated.actions[0].input, .null, "Nothing is configured on a Menu Item any more")
        XCTAssertEqual(migrated.actions[3], url, "Another Plugin's Action is untouched")

        let grants = PluginCapabilityGrantStore()
        for capability in manifest.capabilities {
            grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                               capability: capability, scope: manifest.scope(for: capability))
        }
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in true })
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/translator"), manifest: manifest))
        for action in migrated.actions.prefix(3) {
            XCTAssertEqual(registry.availability(for: action), .available, "\(action.commandID) matches a registered Command")
        }
        XCTAssertNil(try TranslatorCommandMigration.migrate(migrated, manifest: manifest), "Nothing is left to move")
    }

    func testWithoutTheTranslatorNothingMoves() throws {
        let configuration = try HostConfiguration(
            actions: [try retired("copy", "translator.copy", title: "Translate Selection and Copy")],
            menu: MenuConfiguration(slots: [.occupied(try MenuItemConfiguration(primaryActionID: ActionID("copy")))])
        )
        XCTAssertNil(try TranslatorCommandMigration.migrate(configuration, manifest: nil),
                     "A removed Translator leaves its Menu Items unavailable, as any removed Plugin does")
    }

    /// Version 1 kept DeepL's endpoint and key reference as `endpoint` and
    /// `credential`; they carry over, so a Pro or self-hosted endpoint is kept.
    func testVersionOneDeepLSettingsCarryOver() {
        let stored: [String: JSONValue] = ["endpoint": .string("https://api.deepl.com"), "credential": .string("deepl"),
                                           "target_language": .string("FR")]
        XCTAssertEqual(TranslatorCommandMigration.migrateSettings(stored),
                       ["deepl_endpoint": .string("https://api.deepl.com"), "deepl_credential": .string("deepl"),
                        "target_language": .string("FR")])
        XCTAssertNil(TranslatorCommandMigration.migrateSettings(["deepl_endpoint": .string("https://api.deepl.com")]),
                     "Nothing is left to move")
        XCTAssertEqual(TranslatorCommandMigration.migrateSettings(["endpoint": .string("https://old.example"),
                                                                   "deepl_endpoint": .string("https://new.example")]),
                       ["deepl_endpoint": .string("https://new.example")], "A value saved by version 2 wins")
    }

    /// Version 2 let a Menu Item override the target language; version 2.1
    /// keeps every value in Plugin Settings, so those Actions drop what they
    /// carried and stay bound to their Commands.
    func testAnOverrideLeftOnAnActionIsDropped() throws {
        let manifest = try manifest()
        let command = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == "translator.selection" })
        let configuration = try HostConfiguration(
            actions: [try ActionConfiguration(id: ActionID("a"), pluginID: manifest.id, command: command,
                                              input: .object(["target_language": .string("FR")]))],
            menu: MenuConfiguration(slots: [.occupied(try MenuItemConfiguration(primaryActionID: ActionID("a")))])
        )
        let migrated = try XCTUnwrap(TranslatorCommandMigration.migrate(configuration, manifest: manifest))
        XCTAssertEqual(migrated.actions.map(\.input), [.null])
        XCTAssertTrue(manifest.acceptsActionInput(.null, for: command))
        XCTAssertNil(try TranslatorCommandMigration.migrate(migrated, manifest: manifest), "Nothing is left to move")
    }
}
