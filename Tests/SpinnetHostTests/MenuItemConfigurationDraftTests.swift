import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// The Menu Item Configuration a Configuration Sheet edits, before it is
/// saved or cancelled.
final class MenuItemConfigurationDraftTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private let windows = PluginID("com.example.windows")
    private let speech = PluginID("com.example.speech")

    private func windowsManifest() throws -> PluginManifest {
        try PluginManifest(
            id: windows, name: "Windows", version: "1.0.0", icon: .symbol("macwindow"),
            commands: [
                CommandDeclaration(id: CommandID("left"), title: "Left", execution: .javascript, isConfigurable: false,
                                   script: "run.js", icon: .symbol("rectangle.lefthalf.filled")),
                CommandDeclaration(id: CommandID("right"), title: "Right", execution: .javascript, isConfigurable: false,
                                   script: "run.js", icon: .symbol("rectangle.righthalf.filled")),
            ],
            preset: MenuItemPresetDeclaration(readiness: .readyToUse, isConfigurable: false)
        )
    }

    /// A Setup-Required Preset whose Commands share no ID with Windows'.
    private func speechManifest() throws -> PluginManifest {
        try PluginManifest(
            id: speech, name: "Speech", version: "1.0.0", icon: .symbol("waveform"),
            commands: [
                CommandDeclaration(id: CommandID("speak"), title: "Speak", execution: .javascript, isConfigurable: false,
                                   script: "run.js", icon: .symbol("speaker.wave.2")),
                CommandDeclaration(id: CommandID("listen"), title: "Listen", execution: .javascript, isConfigurable: false,
                                   script: "run.js"),
            ],
            preset: MenuItemPresetDeclaration(readiness: .setupRequired, defaultAlternateCommandIDs: [CommandID("listen")])
        )
    }

    /// Slot 0 holds a Windows Menu Item running `left`; slot 1 is empty.
    private func makeModel() throws -> MenuEditorModel {
        let registry = PluginRegistry()
        let windows = try windowsManifest()
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/Windows.spinnetplugin"), manifest: windows))
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/Speech.spinnetplugin"),
                                            manifest: speechManifest()))
        let left = try ActionConfiguration(id: ActionID("left"), pluginID: self.windows,
                                           command: windows.commands[0], input: .null)
        let configuration = try HostConfiguration(actions: [left], menu: MenuConfiguration(slots: [
            .occupied(MenuItemConfiguration(primaryActionID: left.id)), .empty
        ]))
        return MenuEditorModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration))
    }

    /// Replacing an occupied Slot with another Plugin's Setup-Required
    /// Preset edits the new Plugin, so its icons are the new Plugin's.
    func testReplacingAMenuItemWithAnotherPluginsPresetOffersThatPluginsIcons() throws {
        let model = try makeModel()
        XCTAssertFalse(model.placePreset(pluginID: speech.rawValue, at: 0))
        model.confirmPresetReplacement()
        let setup = try XCTUnwrap(model.pendingPresetSetup)
        XCTAssertTrue(setup.replacing)

        let draft = MenuItemConfigurationDraft(editor: model.editor, slotIndex: setup.slotIndex,
                                               presetPluginID: setup.pluginID)
        XCTAssertEqual(draft.pluginID, speech)
        XCTAssertEqual(draft.commands.map(\.id), [CommandID("speak"), CommandID("listen")])
        XCTAssertEqual(draft.primaryCommandID, CommandID("speak"))
        XCTAssertEqual(draft.icon(for: CommandID("speak")), MenuItemIcon(symbolName: "speaker.wave.2"))
        XCTAssertEqual(draft.icon(for: CommandID("listen")), MenuItemIcon(symbolName: "waveform"))
        XCTAssertEqual(draft.defaultIcon, MenuItemIcon(symbolName: "speaker.wave.2"))

        try model.saveMenuItemConfiguration(draft.makeConfiguration())
        XCTAssertEqual(model.menuSlots[0].item?.icon, draft.defaultIcon, "The sheet showed what the Menu Item shows")
    }

    /// A Menu Item replaced by a Setup-Required Preset keeps nothing of the
    /// old one: the draft starts from the Preset, and saving leaves no alias,
    /// own icon or Action of the replaced Menu Item.
    func testReplacingAMenuItemStartsFromThePresetAlone() throws {
        let model = try makeModel()
        let item = try XCTUnwrap(model.editor.configuration.menu.slots[0].item)
        model.editor.restore(try HostConfiguration(
            actions: model.editor.configuration.actions,
            menu: MenuConfiguration(slots: [.occupied(item.withAlias("Tile").withIcon("star")), .empty])))
        XCTAssertFalse(model.placePreset(pluginID: speech.rawValue, at: 0))
        model.confirmPresetReplacement()
        let setup = try XCTUnwrap(model.pendingPresetSetup)

        let draft = MenuItemConfigurationDraft(editor: model.editor, slotIndex: setup.slotIndex,
                                               presetPluginID: setup.pluginID)
        XCTAssertEqual(draft.alias, "")
        XCTAssertNil(draft.ownIcon)
        XCTAssertTrue(draft.isAlternateEnabled(CommandID("listen")), "The Preset's default Alternate Actions are on")

        try model.saveMenuItemConfiguration(draft.makeConfiguration())
        let saved = try XCTUnwrap(model.editor.configuration.menu.slots[0].item)
        XCTAssertNil(saved.alias)
        XCTAssertNil(saved.icon)
        XCTAssertEqual(Set(model.editor.configuration.actions.map(\.pluginID)), [speech])
        XCTAssertEqual(saved.boundActionIDs.count, 2)
    }

    /// Replacing a Menu Item with its own Plugin's Preset also starts over:
    /// the old Actions, their inputs and choices go.
    func testReplacingAMenuItemWithItsOwnPluginsPresetStartsOver() throws {
        let model = try makeModel()
        let speechManifest = try speechManifest()
        let speak = try ActionConfiguration(id: ActionID("speak"), pluginID: speech,
                                            command: speechManifest.commands[0], input: .null)
        model.editor.restore(try HostConfiguration(actions: [speak], menu: MenuConfiguration(slots: [
            .occupied(MenuItemConfiguration(primaryActionID: speak.id).withAlias("Talk")), .empty
        ])))
        XCTAssertFalse(model.placePreset(pluginID: speech.rawValue, at: 0))
        model.confirmPresetReplacement()
        let setup = try XCTUnwrap(model.pendingPresetSetup)

        let draft = MenuItemConfigurationDraft(editor: model.editor, slotIndex: setup.slotIndex,
                                               presetPluginID: setup.pluginID)
        XCTAssertEqual(draft.alias, "")
        XCTAssertTrue(draft.isAlternateEnabled(CommandID("listen")))

        try model.saveMenuItemConfiguration(draft.makeConfiguration())
        let saved = try XCTUnwrap(model.editor.configuration.menu.slots[0].item)
        XCTAssertNil(saved.alias)
        XCTAssertFalse(model.editor.configuration.actions.contains { $0.id == speak.id }, "The old Action is replaced")
        XCTAssertEqual(model.editor.configuration.actions.count, 2)
    }

    /// Opening the sheet on a Menu Item shows its own configuration.
    func testADraftStartsFromTheMenuItemsConfiguration() throws {
        let model = try makeModel()
        let item = try XCTUnwrap(model.editor.configuration.menu.slots[0].item)
        let configured = try HostConfiguration(
            actions: model.editor.configuration.actions,
            menu: MenuConfiguration(slots: [.occupied(item.withAlias("Tile").withIcon("star")), .empty]))
        model.editor.restore(configured)

        let draft = MenuItemConfigurationDraft(editor: model.editor, slotIndex: 0)
        XCTAssertEqual(draft.pluginID, windows)
        XCTAssertEqual(draft.alias, "Tile")
        XCTAssertEqual(draft.ownIcon, "star")
        XCTAssertEqual(draft.primaryCommandID, CommandID("left"))
        XCTAssertEqual(draft.alternateCommands.map(\.id), [CommandID("right")])
        XCTAssertFalse(draft.isAlternateEnabled(CommandID("right")))
        XCTAssertEqual(draft.selectedCommands.map(\.id), [CommandID("left")])
    }

    /// Choosing another Primary Action makes the former one the last
    /// Alternate Action, off; the draft saves the order and choices.
    func testChoosingActionsAndSavingThem() throws {
        let model = try makeModel()
        let draft = MenuItemConfigurationDraft(editor: model.editor, slotIndex: 0)
        draft.primaryCommandID = CommandID("right")
        XCTAssertEqual(draft.alternateCommands.map(\.id), [CommandID("left")])
        XCTAssertFalse(draft.isAlternateEnabled(CommandID("left")))
        XCTAssertEqual(draft.defaultIcon, MenuItemIcon(symbolName: "rectangle.righthalf.filled"))
        draft.setAlternate(CommandID("left"), enabled: true)
        draft.alias = "  Tiles  "

        try model.saveMenuItemConfiguration(draft.makeConfiguration())

        let item = try XCTUnwrap(model.editor.configuration.menu.slots[0].item)
        let actions = Dictionary(uniqueKeysWithValues: model.editor.configuration.actions.map { ($0.id, $0) })
        XCTAssertEqual(actions[item.primaryActionID]?.commandID, CommandID("right"))
        XCTAssertEqual(item.alternateActionIDs.compactMap { actions[$0]?.commandID }, [CommandID("left")])
        XCTAssertEqual(item.alias, "Tiles")
        XCTAssertEqual(model.menuSlots[0].title, "Tiles")
    }

    func testAlternateActionsMoveWithinTheirOrder() throws {
        let model = try makeModel()
        let draft = MenuItemConfigurationDraft(editor: model.editor, slotIndex: 1, presetPluginID: speech)
        XCTAssertEqual(draft.alternateCommands.map(\.id), [CommandID("listen")])
        XCTAssertTrue(draft.isAlternateEnabled(CommandID("listen")), "An empty Slot starts from the Preset's defaults")
        XCTAssertFalse(draft.canMoveAlternate(CommandID("listen"), by: -1))
        draft.primaryCommandID = CommandID("listen")
        XCTAssertEqual(draft.alternateCommands.map(\.id), [CommandID("speak")])
        XCTAssertEqual(draft.selectedCommands.map(\.id), [CommandID("listen")])
    }

    /// A Menu Item whose Plugin is gone keeps its Actions; only its alias
    /// and icon can change.
    func testAMenuItemOfAMissingPluginSavesOnlyItsAliasAndIcon() throws {
        let registry = PluginRegistry()
        let windows = try windowsManifest()
        let left = try ActionConfiguration(id: ActionID("left"), pluginID: self.windows,
                                           command: windows.commands[0], input: .null)
        let configuration = try HostConfiguration(actions: [left], menu: MenuConfiguration(slots: [
            .occupied(MenuItemConfiguration(primaryActionID: left.id))
        ]))
        let model = MenuEditorModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration))

        let draft = MenuItemConfigurationDraft(editor: model.editor, slotIndex: 0)
        XCTAssertNil(draft.manifest)
        XCTAssertNil(draft.pluginID)
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.defaultIcon, .neutral)
        draft.ownIcon = "star"
        let saved = try draft.makeSaveDraft(typedSecrets: ["key": "secret"])
        XCTAssertNil(saved.pluginID)
        XCTAssertTrue(saved.secrets.isEmpty)
        XCTAssertEqual(saved.configuration.actions, configuration.actions)
        XCTAssertEqual(saved.configuration.menu.slots[0].item?.icon, "star")
    }
}
