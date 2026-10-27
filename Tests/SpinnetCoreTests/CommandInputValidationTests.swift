import Foundation
import XCTest
@testable import SpinnetCore

final class CommandInputValidationTests: XCTestCase {
    func testKeyboardPresetAndEditorRejectTheSameMalformedInputs() throws {
        let inputs: [JSONValue] = [
            .string("A+"), .string("+A"),
            .object(["key": .string("C"), "modifiers": .string("")]),
            .object(["key": .string("C"), "modifiers": .string("+")]),
            .object(["key": .string("F01")]),
            .object(["key_code": .number(128)]),
            .object(["key": .string("C"), "modifiers": .number(-1)])
        ]
        for input in inputs {
            XCTAssertFalse(HostCommand.invokeKeyboardShortcut.isValidInput(input), "\(input)")
            let command = keyboardCommand()
            XCTAssertThrowsError(try manifest(command, input: input), "\(input)")
            XCTAssertThrowsError(try configured(command, input: input), "\(input)")
        }
    }

    func testKeyboardPresetAndEditorPreserveSupportedInputForms() throws {
        let inputs: [JSONValue] = [
            .string("⌘⇧P"), .string("cmd+shift+P"), .string(" option + F20 "),
            .string("cmd++P"),
            .object(["key": .string("C"), "modifiers": .array([])]),
            .object(["character": .string("P"), "modifier_flags": .string("cmd+shift")]),
            .object(["key_code": .number(0), "modifiers": .number(0)]),
            .object(["key_code": .number(127), "modifiers": .number(4294967296)])
        ]
        for input in inputs {
            XCTAssertTrue(HostCommand.invokeKeyboardShortcut.isValidInput(input), "\(input)")
            let command = keyboardCommand()
            XCTAssertNoThrow(try manifest(command, input: input), "\(input)")
            let configuration = try configured(command, input: input)
            XCTAssertEqual(configuration.actions.first?.input, input)
        }
    }

    func testDeepLinkConfigurationUsesItsDeclaredFieldsAtBothEntryPoints() throws {
        let manifest = try DeepLinkTemplateTests.manifest(primary: "notes.open")
        let command = try XCTUnwrap(manifest.commands.first { $0.id == CommandID("notes.open") })
        let registry = PluginRegistry()
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/notes.spinnetplugin"), manifest: manifest))
        let editor = HostConfigurationEditor(registry: registry,
            configuration: try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty])))
        let input = JSONValue.object(["folder": .string("inbox")])
        let candidate = try editor.configuredMenuItem(at: 0, pluginID: manifest.id,
            primaryCommandID: command.id, inputs: [command.id: input], replacingEmptySlot: true)
        XCTAssertEqual(candidate.actions.first?.input, input)
        XCTAssertThrowsError(try editor.configuredMenuItem(at: 0, pluginID: manifest.id,
            primaryCommandID: command.id, inputs: [command.id: .object(["folder": .string("unknown")])],
            replacingEmptySlot: true))
    }

    func testTheSharedParserKeepsNumericBitsAndNormalizesOnlyNamedInputs() throws {
        let numeric = try CommandKeyboardShortcutInput(.object([
            "key_code": .number(127), "modifiers": .number(4294967296)
        ]))
        XCTAssertEqual(numeric.key, .virtualCode(127))
        XCTAssertEqual(numeric.rawModifierFlags, 4294967296)
        XCTAssertEqual(numeric.modifiers, [])
        let named = try CommandKeyboardShortcutInput(.object([
            "character": .string(" p "), "modifier_flags": .array([.string("cmd"), .string("fn"), .string("caps lock")])
        ]))
        XCTAssertEqual(named.key, .named("P"))
        XCTAssertEqual(named.rawModifierFlags, 0)
        XCTAssertEqual(named.modifiers, [.command, .function, .capsLock])
    }

    func testScriptPresetAndEditorBothRejectUnencodableInput() throws {
        let command = CommandDeclaration(id: CommandID("script"), title: "Script", scriptPath: "run.js")
        let input = JSONValue.number(.nan)
        XCTAssertThrowsError(try manifest(command, input: input))
        XCTAssertThrowsError(try configured(command, input: input))
    }

    private func keyboardCommand() -> CommandDeclaration {
        CommandDeclaration(id: CommandID("keyboard"), title: "Keyboard", hostServiceID: "keyboard.press")
    }

    private func manifest(_ command: CommandDeclaration, input: JSONValue? = nil) throws -> PluginManifest {
        try PluginManifest(id: PluginID("example.input"), name: "Input", version: "1",
            commands: [command], preset: MenuItemPresetDeclaration(
                readiness: input == nil ? .setupRequired : .readyToUse,
                defaultPrimaryCommandID: command.id,
                defaultInputs: input.map { [command.id: $0] } ?? [:]))
    }

    private func configured(_ command: CommandDeclaration, input: JSONValue) throws -> HostConfiguration {
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/input.spinnetplugin"),
                                    manifest: try manifest(command))
        let registry = PluginRegistry()
        try registry.register(package)
        let configuration = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)
        return try editor.configuredMenuItem(at: 0, pluginID: package.manifest.id,
            primaryCommandID: command.id, inputs: [command.id: input], replacingEmptySlot: true)
    }
}
