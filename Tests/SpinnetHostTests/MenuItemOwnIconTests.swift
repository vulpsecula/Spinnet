import AppKit
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// The user's own Menu Item Icon (#131): chosen and reset in the
/// Configuration Sheet, owned by the Menu Item like its alias, and shown
/// ahead of every icon the Plugin declares.
final class MenuItemOwnIconTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private let pluginID = PluginID("com.example.iconic")
    private let safari = AppBundleIdentifier(validating: "com.apple.Safari")!

    private func manifest() throws -> PluginManifest {
        try PluginManifest(
            id: pluginID, name: "Iconic", version: "1.0.0", icon: .symbol("music.note"),
            commands: [CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript,
                                          isConfigurable: false, script: "run.js")],
            preset: MenuItemPresetDeclaration(readiness: .readyToUse, isConfigurable: false)
        )
    }

    private func makeModel(ownIcon: String? = nil) throws -> (MenuEditorModel, PluginRegistry) {
        let registry = PluginRegistry()
        let manifest = try manifest()
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/iconic.spinnetplugin"), manifest: manifest))
        let action = try ActionConfiguration(id: ActionID("run"), pluginID: pluginID,
                                             command: manifest.commands[0], input: .null)
        let item = try MenuItemConfiguration(primaryActionID: action.id, icon: ownIcon)
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(slots: [.occupied(item), .empty, .empty])
        )
        return (MenuEditorModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration)), registry)
    }

    /// Saves the Configuration Sheet's draft of the Menu Item at `index`
    /// with its Actions unchanged, given `alias` and `icon`.
    private func saveSheet(_ model: MenuEditorModel, at index: Int = 0, alias: String? = nil, icon: String?) throws {
        let draft = MenuItemConfigurationDraft(editor: model.editor, app: model.editedAppID, slotIndex: index)
        draft.alias = alias ?? ""
        draft.ownIcon = icon
        model.saveMenuItemConfiguration(try draft.makeConfiguration())
    }

    // MARK: Resolution

    func testTheUsersOwnIconComesBeforeThePluginIcon() {
        let pluginIcon = IconDeclaration.symbol("music.note")
        XCTAssertEqual(MenuItemIcon.resolve(ownIcon: "star", pluginIcon: pluginIcon, primaryAvailability: .available),
                       MenuItemIcon(symbolName: "star"))
        XCTAssertEqual(MenuItemIcon.resolve(ownIcon: nil, pluginIcon: pluginIcon, primaryAvailability: .available),
                       MenuItemIcon(symbolName: "music.note"))
    }

    func testUnavailableMenuItemsKeepShowingTheUsersOwnIcon() {
        for reason: ActionUnavailableReason in [.pluginMissing, .pluginRefused("Needs a newer Spinnet"), .commandMissing] {
            XCTAssertEqual(MenuItemIcon.resolve(ownIcon: "star", pluginIcon: .symbol("music.note"),
                                                primaryAvailability: .unavailable(reason)),
                           MenuItemIcon(symbolName: "star"), "\(reason)")
            XCTAssertEqual(MenuItemIcon.resolve(ownIcon: nil, pluginIcon: .symbol("music.note"),
                                                primaryAvailability: .unavailable(reason)),
                           .neutral, "\(reason)")
        }
    }

    func testAMenuItemOfARemovedOrRefusedPluginKeepsItsOwnIcon() throws {
        let (model, registry) = try makeModel(ownIcon: "star")
        registry.unregister(pluginID)
        model.refreshMenuSlots()
        XCTAssertFalse(try XCTUnwrap(model.menuSlots[0].item).primaryAction.isAvailable)
        XCTAssertEqual(model.menuSlots[0].item?.icon, MenuItemIcon(symbolName: "star"))

        registry.recordRefused(RefusedPlugin(id: pluginID, manifest: nil, reason: "Needs a newer Spinnet"))
        model.refreshMenuSlots()
        XCTAssertEqual(model.menuSlots[0].item?.icon, MenuItemIcon(symbolName: "star"))
    }

    // MARK: The Configuration Sheet

    func testTheConfigurationSheetChoosesAnIconAndResetsItToThePluginsDefault() throws {
        let (model, _) = try makeModel()
        XCTAssertEqual(model.menuSlots[0].item?.icon, MenuItemIcon(symbolName: "music.note"))

        try saveSheet(model, alias: "Mine", icon: "star")
        XCTAssertEqual(model.editor.configuration.menu.slots[0].item?.icon, "star")
        XCTAssertEqual(model.editor.configuration.menu.slots[0].item?.alias, "Mine")
        XCTAssertEqual(model.menuSlots[0].item?.icon, MenuItemIcon(symbolName: "star"))

        try saveSheet(model, alias: "Mine", icon: nil)
        XCTAssertNil(model.editor.configuration.menu.slots[0].item?.icon)
        XCTAssertEqual(model.menuSlots[0].item?.icon, MenuItemIcon(symbolName: "music.note"))

        model.undoSlotEdit()
        XCTAssertEqual(model.menuSlots[0].item?.icon, MenuItemIcon(symbolName: "star"), "Choosing an icon is an edit")
    }

    func testTheSheetsDefaultIconIsWhatTheMenuItemShowsWithoutTheUsersChoice() throws {
        let (model, registry) = try makeModel(ownIcon: "star")
        XCTAssertEqual(MenuItemConfigurationDraft(editor: model.editor, slotIndex: 0).defaultIcon,
                       MenuItemIcon(symbolName: "music.note"))
        XCTAssertEqual(MenuItemConfigurationDraft(editor: model.editor, slotIndex: 0).ownIcon, "star")
        registry.unregister(pluginID)
        XCTAssertEqual(MenuItemConfigurationDraft(editor: model.editor, slotIndex: 0).defaultIcon, .neutral)
    }

    func testTheSymbolPickerSearchesItsSymbolsAndAcceptsAnyKnownSymbolName() {
        XCTAssertFalse(MenuItemIconPicker.symbols(matching: "").isEmpty)
        XCTAssertTrue(MenuItemIconPicker.symbols(matching: "").allSatisfy {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }, "Every offered symbol draws on this macOS")
        XCTAssertTrue(MenuItemIconPicker.symbols(matching: "STAR").contains("star"))
        XCTAssertFalse(MenuItemIconPicker.symbols(matching: "star").contains("folder"))
        XCTAssertEqual(MenuItemIconPicker.symbols(matching: "  airplane.departure "), ["airplane.departure"],
                       "A symbol name typed in full is offered even when the list lacks it")
        XCTAssertEqual(MenuItemIconPicker.symbols(matching: "no.such.symbol.anywhere"), [])
    }

    // MARK: Ownership

    func testTheIconMovesWithTheMenuItemToAnotherMenuSlot() throws {
        let (model, _) = try makeModel()
        try saveSheet(model, icon: "star")

        XCTAssertTrue(model.moveSlot(from: 0, to: 2))

        XCTAssertNil(model.editor.configuration.menu.slots[0].item)
        XCTAssertEqual(model.editor.configuration.menu.slots[2].item?.icon, "star")
        XCTAssertEqual(model.menuSlots[2].item?.icon, MenuItemIcon(symbolName: "star"))
    }

    func testAnAppSeesTheDefaultMenuItemsIconAndKeepsItWhenItOverridesTheMenuItem() throws {
        let (model, _) = try makeModel(ownIcon: "star")
        model.addApp(bundleIdentifier: safari.rawValue, name: "Safari")
        XCTAssertEqual(model.menuSlots[0].appOverride, .inherited)
        XCTAssertEqual(model.menuSlots[0].item?.icon, MenuItemIcon(symbolName: "star"))

        try saveSheet(model, alias: "Safari's", icon: "star")
        XCTAssertEqual(model.menuSlots[0].appOverride, .overridden)
        XCTAssertEqual(model.editor.configuration.menu.slots(for: safari)[0].item?.icon, "star")
        XCTAssertEqual(model.menuSlots[0].item?.icon, MenuItemIcon(symbolName: "star"))
    }

    func testChoosingAnIconForAnAppOverridesOnlyThatAppsMenuItem() throws {
        let (model, _) = try makeModel()
        model.addApp(bundleIdentifier: safari.rawValue, name: "Safari")

        try saveSheet(model, icon: "safari")

        XCTAssertEqual(model.menuSlots[0].appOverride, .overridden)
        XCTAssertEqual(model.editor.configuration.menu.slots(for: safari)[0].item?.icon, "safari")
        XCTAssertNil(model.editor.configuration.menu.slots(for: nil)[0].item?.icon)

        // Choosing the inherited icon again saves no override.
        let (inherited, _) = try makeModel(ownIcon: "star")
        inherited.addApp(bundleIdentifier: safari.rawValue, name: "Safari")
        let before = inherited.editor.configuration
        try saveSheet(inherited, icon: "star")
        XCTAssertEqual(inherited.editor.configuration, before)
        XCTAssertEqual(inherited.menuSlots[0].appOverride, .inherited)
    }

    // MARK: Saved data

    /// Saved data written before the member existed loads and saves back
    /// unchanged, with no `icon`; new data keeps the user's icon.
    func testSavedConfigurationWithAndWithoutTheIconMember() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwnIcon-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("configuration.json")
        try FileManager.default.copyItem(
            at: TestRepository.root.appendingPathComponent("Tests/RegressionBaseline/configuration.json"), to: url)
        let original = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: original, as: UTF8.self).contains(#""icon""#), "The baseline predates the member")

        let store = HostConfigurationStore(fileURL: url)
        let old = try XCTUnwrap(store.load())
        let items = old.menu.slots.flatMap(\.allItems)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.icon == nil })
        try store.save(old)
        XCTAssertEqual(try store.load(), old)
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(#""icon""#),
                       "Saving old data writes no icon member")

        var slots = old.menu.slots
        let index = try XCTUnwrap(slots.firstIndex { $0.item?.alias != nil })
        let item = try XCTUnwrap(slots[index].item)
        slots[index] = slots[index].withItem(item.withIcon("star"))
        let new = try HostConfiguration(actions: old.actions, menu: MenuConfiguration(slots: slots))
        try store.save(new)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded, new)
        XCTAssertEqual(loaded.menu.slots[index].item?.icon, "star")
        XCTAssertEqual(loaded.menu.slots[index].item?.alias, item.alias)
    }

    func testASavedIconThatIsNotASymbolNameIsDroppedRatherThanFailingTheLoad() throws {
        let data = Data(#"{"primary_action_id": "run", "icon": "  "}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MenuItemConfiguration.self, from: data).icon)
        let bad = Data(#"{"primary_action_id": "run", "icon": "Not A Symbol!"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MenuItemConfiguration.self, from: bad).icon)
        let good = Data(#"{"primary_action_id": "run", "icon": "star.fill"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MenuItemConfiguration.self, from: good).icon, "star.fill")
    }
}
