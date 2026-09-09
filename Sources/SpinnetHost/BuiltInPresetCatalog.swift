import Foundation
import SpinnetCore

/// The Host-owned Presets that are useful without installing a Plugin. Each
/// operation is its own Library entry so a user can add it directly to a
/// Menu Slot without first creating a fixture Plugin Action.
enum BuiltInPresetCatalog {
    static let openURLPluginID = PluginID("com.spinnet.builtin.open-url")

    static func pluginID(for hostCommand: HostCommand) -> PluginID? {
        switch hostCommand {
        case .openURL: return openURLPluginID
        case .openApplication: return PluginID("com.spinnet.builtin.open-application")
        case .openFile: return PluginID("com.spinnet.builtin.open-file")
        case .openFolder: return PluginID("com.spinnet.builtin.open-folder")
        case .invokeShortcut: return PluginID("com.spinnet.builtin.run-shortcut")
        case .invokeKeyboardShortcut: return PluginID("com.spinnet.builtin.keyboard-shortcut")
        case .invokeService: return PluginID("com.spinnet.builtin.service")
        case .copyText: return PluginID("com.spinnet.builtin.copy-selected-text")
        case .presentFeedback: return nil
        }
    }

    static func makePackages() throws -> [PluginPackage] {
        [
            try package(
                id: openURLPluginID,
                name: "Open URL",
                commandID: "builtin.open_url",
                commandTitle: "Open URL",
                hostCommand: .openURL,
                readiness: .readyToUse,
                defaultInput: .string("https://github.com/vulpsecula/Spinnet")
            ),
            try package(
                id: PluginID("com.spinnet.builtin.open-application"),
                name: "Open Application",
                commandID: "builtin.open_application",
                commandTitle: "Open Application",
                hostCommand: .openApplication
            ),
            try package(
                id: PluginID("com.spinnet.builtin.open-file"),
                name: "Open File",
                commandID: "builtin.open_file",
                commandTitle: "Open File",
                hostCommand: .openFile
            ),
            try package(
                id: PluginID("com.spinnet.builtin.open-folder"),
                name: "Open Folder",
                commandID: "builtin.open_folder",
                commandTitle: "Open Folder",
                hostCommand: .openFolder
            ),
            try package(
                id: PluginID("com.spinnet.builtin.run-shortcut"),
                name: "Run Shortcut",
                commandID: "builtin.run_shortcut",
                commandTitle: "Run Shortcut",
                hostCommand: .invokeShortcut
            ),
            try package(
                id: PluginID("com.spinnet.builtin.keyboard-shortcut"),
                name: "Run Keyboard Shortcut",
                commandID: "builtin.run_keyboard_shortcut",
                commandTitle: "Run Keyboard Shortcut",
                hostCommand: .invokeKeyboardShortcut
            ),
            try package(
                id: PluginID("com.spinnet.builtin.service"),
                name: "Run macOS Service",
                commandID: "builtin.run_service",
                commandTitle: "Run macOS Service",
                hostCommand: .invokeService
            ),
            try package(
                id: PluginID("com.spinnet.builtin.copy-selected-text"),
                name: "Copy Selected Text",
                commandID: "builtin.copy_selected_text",
                commandTitle: "Copy Selected Text",
                hostCommand: .copyText,
                capabilities: [.readSelectedText, .writeClipboard],
                isConfigurable: false,
                readiness: .readyToUse
            )
        ]
    }

    private static func package(
        id: PluginID,
        name: String,
        commandID: String,
        commandTitle: String,
        hostCommand: HostCommand,
        capabilities: [PluginCapability] = [],
        isConfigurable: Bool = true,
        readiness: MenuItemPresetReadiness = .setupRequired,
        defaultInput: JSONValue? = nil
    ) throws -> PluginPackage {
        let command = CommandDeclaration(
            id: CommandID(commandID),
            title: commandTitle,
            isConfigurable: isConfigurable,
            hostCommand: hostCommand
        )
        var defaults: [CommandID: JSONValue] = [:]
        if let defaultInput {
            defaults[command.id] = defaultInput
        }
        let preset = MenuItemPresetDeclaration(
            readiness: readiness,
            isConfigurable: isConfigurable,
            defaultPrimaryCommandID: command.id,
            defaultInputs: defaults
        )
        let manifest = try PluginManifest(
            id: id,
            name: name,
            version: "1.0.0",
            capabilities: capabilities,
            commands: [command],
            preset: preset
        )
        return PluginPackage(
            rootURL: URL(fileURLWithPath: "/System/Library/CoreServices/SpinnetBuiltInPresets"),
            manifest: manifest,
            presetSource: .builtIn
        )
    }
}
