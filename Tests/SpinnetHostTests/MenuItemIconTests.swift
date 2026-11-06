import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// What icon a Menu Item shows, in the Library, the Menu Editor and on the
/// radial Menu: its Plugin's Plugin Icon, else a neutral Host symbol.
final class MenuItemIconTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private let pluginID = PluginID("com.example.iconic")

    private func manifest(icon: IconDeclaration?, version: String = "1.0.0", name: String = "Iconic",
                          id: PluginID? = nil) throws -> PluginManifest {
        try PluginManifest(
            id: id ?? pluginID, name: name, version: version, icon: icon,
            commands: [CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript,
                                          isConfigurable: false, script: "run.js")],
            preset: MenuItemPresetDeclaration(readiness: .readyToUse, isConfigurable: false)
        )
    }

    private func makeEditor(icon: IconDeclaration?) throws -> (MenuEditorModel, PluginRegistry) {
        let registry = PluginRegistry()
        let manifest = try manifest(icon: icon)
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/iconic.spinnetplugin"), manifest: manifest))
        let action = try ActionConfiguration(id: ActionID("run"), pluginID: pluginID,
                                             command: manifest.commands[0], input: .null)
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(slots: [.occupied(MenuItemConfiguration(primaryActionID: action.id)), .empty])
        )
        return (MenuEditorModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration)), registry)
    }

    // MARK: Resolution

    func testAMenuItemShowsItsPluginIcon() throws {
        let (model, _) = try makeEditor(icon: .symbol("music.note"))
        XCTAssertEqual(model.menuSlots[0].item?.icon, MenuItemIcon(symbolName: "music.note"))
    }

    func testAMenuItemFromAPluginWithoutAnIconShowsTheNeutralSymbol() throws {
        let (model, _) = try makeEditor(icon: nil)
        XCTAssertEqual(model.menuSlots[0].item?.icon, .neutral)
        XCTAssertFalse(MenuItemIcon.neutral.symbolName.isEmpty)
    }

    func testAMenuItemOfARemovedPluginShowsTheNeutralSymbolWhileUnavailable() throws {
        let (model, registry) = try makeEditor(icon: .symbol("music.note"))
        registry.unregister(pluginID)
        model.refreshMenuSlots()
        let item = try XCTUnwrap(model.menuSlots[0].item)
        XCTAssertEqual(item.icon, .neutral)
        XCTAssertFalse(item.primaryAction.isAvailable)
    }

    /// The resolution itself, for every unavailable state that leaves no
    /// Plugin to take an icon from.
    func testUnavailablePluginsAndCommandsResolveToTheNeutralSymbol() {
        let icon = IconDeclaration.symbol("music.note")
        XCTAssertEqual(MenuItemIcon.resolve(pluginIcon: icon, primaryAvailability: .available),
                       MenuItemIcon(symbolName: "music.note"))
        for reason: ActionUnavailableReason in [.pluginMissing, .pluginRefused("Needs a newer Spinnet"), .commandMissing] {
            XCTAssertEqual(MenuItemIcon.resolve(pluginIcon: icon, primaryAvailability: .unavailable(reason)),
                           .neutral, "\(reason)")
        }
        // An installed Plugin whose Action waits on access keeps its icon.
        XCTAssertEqual(MenuItemIcon.resolve(pluginIcon: icon, primaryAvailability: .unavailable(.capabilityDenied)),
                       MenuItemIcon(symbolName: "music.note"))
        XCTAssertEqual(MenuItemIcon.resolve(pluginIcon: nil, primaryAvailability: .available), .neutral)
    }

    func testARefusedPluginsMenuItemShowsTheNeutralSymbol() throws {
        let (model, registry) = try makeEditor(icon: .symbol("music.note"))
        registry.unregister(pluginID)
        registry.recordRefused(RefusedPlugin(id: pluginID, manifest: nil, reason: "Needs a newer Spinnet"))
        model.refreshMenuSlots()
        let item = try XCTUnwrap(model.menuSlots[0].item)
        XCTAssertEqual(item.primaryAction.availability.reason, .pluginRefused("Needs a newer Spinnet"))
        XCTAssertEqual(item.icon, .neutral)
    }

    func testTheLibraryShowsEachPresetWithItsPluginIconOrTheNeutralSymbol() throws {
        let (model, registry) = try makeEditor(icon: .symbol("music.note"))
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/plain.spinnetplugin"),
                                            manifest: manifest(icon: nil, name: "Plain", id: PluginID("com.example.plain"))))
        let presets = model.libraryPresets(matching: "")
        XCTAssertEqual(presets.map(\.name), ["Iconic", "Plain"])
        XCTAssertEqual(presets.map(MenuItemIcon.init(preset:)), [MenuItemIcon(symbolName: "music.note"), .neutral])
    }

    // MARK: Plugin Update and installation

    /// An icon-only Plugin Update keeps every configured Action available,
    /// edits no Menu Item, and the Menu Item shows the new icon.
    func testAnIconOnlyPluginUpdateKeepsActionsAvailableAndEditsNoMenuItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginRegistry()
        let store = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"), registry: registry,
                                            grants: PluginCapabilityGrantStore(), persistGrants: {})
        func package(_ manifest: PluginManifest, _ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name).appendingPathComponent("Iconic.spinnetplugin")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("manifest.json"))
            try Data("null".utf8).write(to: url.appendingPathComponent("run.js"))
            return url
        }
        try store.install(from: package(manifest(icon: nil), "v1"))
        let editor = HostConfigurationEditor(
            registry: registry, configuration: try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty, .empty])))
        let model = MenuEditorModel(editor: editor)
        model.reviewPluginInstallation = { try store.review($0) }
        model.installPlugin = { try store.install(from: $0) }
        XCTAssertTrue(model.placePreset(pluginID: pluginID.rawValue, at: 0))
        let arranged = model.editor.configuration
        XCTAssertEqual(model.menuSlots[0].item?.icon, .neutral)

        model.installPluginPackage(at: try package(manifest(icon: .symbol("star"), version: "1.1.0"), "v2"))
        if let pending = model.pendingInstallation { try model.installReviewed(pending) }

        XCTAssertEqual(registry.package(for: pluginID)?.manifest.version, "1.1.0")
        XCTAssertEqual(model.editor.configuration, arranged, "Installing or updating edits no Menu Items")
        let item = try XCTUnwrap(model.menuSlots[0].item)
        XCTAssertTrue(item.primaryAction.isAvailable)
        XCTAssertEqual(item.icon, MenuItemIcon(symbolName: "star"))
        XCTAssertNil(model.menuSlots[1].item, "Installing places nothing into an empty Slot")
    }

    // MARK: The radial Menu

    private func iconicItem(available: Bool = true, symbol: String = "music.note") throws -> MenuSlotPresentation {
        let id = ActionID("run")
        return .occupied(MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: id),
            primaryAction: MenuActionPresentation(actionID: id, title: "Play Music",
                                                  availability: available ? .available : .unavailable(.pluginMissing)),
            alternateActions: [],
            icon: MenuItemIcon(symbolName: symbol)
        ))
    }

    func testTheMenuDrawsEachMenuItemsIconWithItsTitle() throws {
        for mode in [RadialMenuPresentationMode.runtime, .editor] {
            let view = RadialMenuView(slots: [try iconicItem(), .empty, try iconicItem(symbol: "star"), .empty], mode: mode)
            XCTAssertNil(view.menuIcon(at: 1), "An empty Slot draws no icon")
            let drawn = try XCTUnwrap(view.menuIcon(at: 0))
            XCTAssertEqual(drawn.symbolName, "music.note")
            XCTAssertEqual(view.menuIcon(at: 2)?.symbolName, "star")
            let title = view.menuTitleRect(at: 0)
            XCTAssertFalse(drawn.rect.intersects(title), "\(mode): the icon sits clear of the title")
            XCTAssertGreaterThanOrEqual(drawn.rect.minY, title.maxY, "\(mode): the icon sits above the title")
            XCTAssertEqual(drawn.rect.midX, title.midX, accuracy: 1)
            XCTAssertTrue(view.bounds.contains(drawn.rect))
        }
    }

    func testAnUnknownSymbolStillDrawsTheNeutralSymbol() throws {
        let view = RadialMenuView(slots: [try iconicItem(symbol: "no.such.symbol.anywhere")], mode: .runtime)
        XCTAssertEqual(view.menuIcon(at: 0)?.symbolName, MenuItemIcon.neutral.symbolName)
    }

    func testIconsScaleWithTheMenuSize() throws {
        func side(_ size: String) throws -> CGFloat {
            let view = RadialMenuView(slots: [try iconicItem(), .empty, .empty, .empty], mode: .runtime)
            view.applyAppearance(MenuAppearanceConfiguration(menuSize: size))
            return try XCTUnwrap(view.menuIcon(at: 0)).rect.width
        }
        let small = try side("Small"), large = try side("Large")
        XCTAssertGreaterThan(small, 10)
        XCTAssertEqual(large / small, 2, accuracy: 0.15)
        XCTAssertGreaterThan(try side("Medium"), small)
    }

    func testIconsFollowTheAccentAndTheLightOrDarkTheme() throws {
        func colour(theme: String, accent: String, available: Bool = true) throws -> NSColor {
            let view = RadialMenuView(slots: [try iconicItem(available: available)], mode: .runtime)
            view.applyAppearance(MenuAppearanceConfiguration(theme: theme, accent: accent))
            return try XCTUnwrap(view.menuIcon(at: 0)).color
        }
        XCTAssertNotEqual(try colour(theme: "Light", accent: "Green"), try colour(theme: "Light", accent: "Pink"),
                          "An available icon takes the Menu's accent")
        XCTAssertNotEqual(try colour(theme: "Light", accent: "Green", available: false),
                          try colour(theme: "Dark", accent: "Green", available: false),
                          "An unavailable icon follows the Menu's Light or Dark theme")
        XCTAssertEqual(try colour(theme: "Light", accent: "Green", available: false),
                       try colour(theme: "Light", accent: "Pink", available: false),
                       "An unavailable icon keeps the unavailable treatment whatever the accent")
    }

    func testVoiceOverKeepsReadingTitles() throws {
        let view = RadialMenuView(slots: [try iconicItem(), .empty], mode: .editor)
        view.selectEditorItem(at: 0)
        XCTAssertEqual(view.accessibilityValue() as? String, "Play Music")
    }
}
