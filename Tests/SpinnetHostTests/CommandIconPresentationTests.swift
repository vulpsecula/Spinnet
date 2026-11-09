import AppKit
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// What a Menu Item and its Alternate Actions show once Commands declare
/// Command Icons: the Command Icon of the Action's own Command, else the
/// Plugin Icon, else the neutral symbol, with the user's own icon first.
final class CommandIconPresentationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private let pluginID = PluginID("com.example.windows")

    private func manifest(pluginIcon: IconDeclaration? = .symbol("macwindow"),
                          icons: [String: IconDeclaration] = ["left": .symbol("rectangle.lefthalf.filled"),
                                                              "right": .symbol("rectangle.righthalf.filled")],
                          version: String = "1.0.0") throws -> PluginManifest {
        try PluginManifest(
            id: pluginID, name: "Windows", version: version, icon: pluginIcon,
            commands: ["left", "right", "plain"].map { id in
                CommandDeclaration(id: CommandID(id), title: id.capitalized, execution: .javascript,
                                   isConfigurable: false, script: "run.js", icon: icons[id])
            },
            preset: MenuItemPresetDeclaration(readiness: .readyToUse, isConfigurable: false)
        )
    }

    private struct Fixture {
        let model: MenuEditorModel
        let registry: PluginRegistry
        let root: URL
    }

    /// Slot 0 runs `left` with `right` and `plain` as Alternate Actions,
    /// slot 1 runs `right`, slot 2 runs `plain`.
    private func makeFixture(_ manifest: PluginManifest, ownIcon: String? = nil, files: [String: Data] = [:]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Windows.spinnetplugin")
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let registry = PluginRegistry()
        try registry.register(PluginPackage(rootURL: root, manifest: manifest))
        // An Action is bound once, so each Slot has its own.
        let bindings: [(String, String)] = [("left", "left"), ("right", "right"), ("plain", "plain"),
                                            ("right", "right-1"), ("plain", "plain-2")]
        let actions = try bindings.map { command, id in
            try ActionConfiguration(id: ActionID(id), pluginID: pluginID,
                                    command: XCTUnwrap(manifest.commands.first { $0.id.rawValue == command }), input: .null)
        }
        let configuration = try HostConfiguration(actions: actions, menu: MenuConfiguration(slots: [
            .occupied(MenuItemConfiguration(primaryActionID: ActionID("left"),
                                            alternateActionIDs: [ActionID("right"), ActionID("plain")], icon: ownIcon)),
            .occupied(MenuItemConfiguration(primaryActionID: ActionID("right-1"))),
            .occupied(MenuItemConfiguration(primaryActionID: ActionID("plain-2"))),
            .empty
        ]))
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)
        return Fixture(model: MenuEditorModel(editor: editor), registry: registry, root: root)
    }

    // MARK: Menu Items

    func testMenuItemsFromOnePluginShowTheCommandIconsOfTheirPrimaryActions() throws {
        let slots = try makeFixture(manifest()).model.menuSlots
        XCTAssertEqual(slots[0].item?.icon, MenuItemIcon(symbolName: "rectangle.lefthalf.filled"))
        XCTAssertEqual(slots[1].item?.icon, MenuItemIcon(symbolName: "rectangle.righthalf.filled"))
        XCTAssertEqual(slots[2].item?.icon, MenuItemIcon(symbolName: "macwindow"),
                       "A Command without an icon inherits the Plugin Icon")
    }

    func testACommandIconShowsEvenWhenThePluginDeclaresNoIcon() throws {
        let slots = try makeFixture(manifest(pluginIcon: nil)).model.menuSlots
        XCTAssertEqual(slots[0].item?.icon, MenuItemIcon(symbolName: "rectangle.lefthalf.filled"))
        XCTAssertEqual(slots[2].item?.icon, .neutral)
    }

    func testTheUsersOwnIconComesBeforeTheCommandIcon() throws {
        let slots = try makeFixture(manifest(), ownIcon: "star").model.menuSlots
        XCTAssertEqual(slots[0].item?.icon, MenuItemIcon(symbolName: "star"))
    }

    func testAnUnavailableMenuItemShowsTheNeutralSymbolNotItsCommandIcon() throws {
        let fixture = try makeFixture(manifest())
        fixture.registry.unregister(pluginID)
        fixture.model.refreshMenuSlots()
        let item = try XCTUnwrap(fixture.model.menuSlots[0].item)
        XCTAssertEqual(item.icon, .neutral)
        XCTAssertEqual(item.alternateActions.map(\.icon), [.neutral, .neutral])
        for reason: ActionUnavailableReason in [.pluginMissing, .pluginRefused("Refused"), .commandMissing] {
            XCTAssertEqual(MenuItemIcon.resolve(commandIcon: .symbol("play"), pluginIcon: .symbol("music.note"),
                                                primaryAvailability: .unavailable(reason)), .neutral, "\(reason)")
        }
        XCTAssertEqual(MenuItemIcon.resolve(commandIcon: .symbol("play"), pluginIcon: .symbol("music.note"),
                                            primaryAvailability: .unavailable(.capabilityDenied)),
                       MenuItemIcon(symbolName: "play"), "An installed Plugin waiting on access keeps its icons")
    }

    func testACommandIconPictureIsLocatedInTheInstalledPackage() throws {
        let fixture = try makeFixture(manifest(icons: ["left": .picture(IconPicture(path: "icons/left.pdf", isTemplate: true))]),
                                      files: ["icons/left.pdf": IconPictureFixtures.pdf()])
        XCTAssertEqual(fixture.model.menuSlots[0].item?.icon.picture,
                       MenuItemIcon.Picture(url: fixture.root.appendingPathComponent("icons/left.pdf"), darkURL: nil,
                                            isTemplate: true))
    }

    // MARK: Alternate Actions

    func testAlternateActionsShowTheirOwnCommandIcons() throws {
        let item = try XCTUnwrap(makeFixture(manifest()).model.menuSlots[0].item)
        XCTAssertEqual(item.primaryAction.icon, MenuItemIcon(symbolName: "rectangle.lefthalf.filled"))
        XCTAssertEqual(item.alternateActions.map(\.icon),
                       [MenuItemIcon(symbolName: "rectangle.righthalf.filled"), MenuItemIcon(symbolName: "macwindow")])
    }

    func testTheUsersOwnIconDoesNotReplaceAlternateActionIcons() throws {
        let item = try XCTUnwrap(makeFixture(manifest(), ownIcon: "star").model.menuSlots[0].item)
        XCTAssertEqual(item.alternateActions.first?.icon, MenuItemIcon(symbolName: "rectangle.righthalf.filled"))
    }

    func testTheAlternateRingDrawsEachAlternateActionsIcon() throws {
        let slots = try makeFixture(manifest()).model.menuSlots
        let view = RadialMenuView(slots: slots, mode: .runtime)
        view.alternateActionMode = .alternateRing
        XCTAssertNil(view.alternateRingIcon(at: 0), "No ring is open")
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let layout = view.geometryLayout
        view.updateRuntimeSelection(at: CGPoint(x: center.x, y: center.y + layout.itemCenterRadius))
        let ring = try XCTUnwrap(layout.alternateRing(itemIndex: 0, actionCount: 2))
        view.updateRuntimeSelection(at: ring.actionCenter(index: 0, center: center))
        XCTAssertEqual(view.alternateRingItemIndex, 0)
        XCTAssertEqual(view.alternateRingIcon(at: 0)?.symbolName, "rectangle.righthalf.filled")
        XCTAssertEqual(view.alternateRingIcon(at: 1)?.symbolName, "macwindow")
        XCTAssertNil(view.alternateRingIcon(at: 2))
        let drawing = try XCTUnwrap(view.alternateRingIcon(at: 1))
        XCTAssertGreaterThan(drawing.rect.width, 6)
        let segmentCenter = ring.actionCenter(index: 1, center: center)
        XCTAssertLessThan(hypot(drawing.rect.midX - segmentCenter.x, drawing.rect.midY - segmentCenter.y),
                          ring.outerRadius - ring.innerRadius, "The icon sits in its own segment")
    }

    func testTheRuntimeActionsMenuShowsEachActionsCommandIcon() throws {
        let slots = try makeFixture(manifest()).model.menuSlots
        let controller = MenuPresentationController(items: slots)
        let menu = try XCTUnwrap(controller.makeActionMenu(for: 0))
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.map(\.title), ["Left", "Right", "Plain"])
        let images = try items.map { try XCTUnwrap($0.image, $0.title) }
        XCTAssertNotEqual(images[0].tiffRepresentation, images[1].tiffRepresentation)
        XCTAssertNotEqual(images[1].tiffRepresentation, images[2].tiffRepresentation)
        XCTAssertTrue(images.allSatisfy { $0.size.width > 0 && $0.size.width <= 20 })
    }

    // MARK: Plugin Update

    /// Changing only Command Icons keeps every Action available, edits no
    /// Menu Item, and the Menu Items show the new icons.
    func testACommandIconOnlyPluginUpdateKeepsActionsAvailable() throws {
        let fixture = try makeFixture(manifest())
        let arranged = fixture.model.editor.configuration
        try fixture.registry.replace(PluginPackage(rootURL: fixture.root, manifest: manifest(
            icons: ["left": .symbol("arrow.left"), "plain": .symbol("square")], version: "1.1.0")))
        fixture.model.refreshMenuSlots()
        XCTAssertEqual(fixture.model.editor.configuration, arranged)
        let item = try XCTUnwrap(fixture.model.menuSlots[0].item)
        XCTAssertTrue(([item.primaryAction] + item.alternateActions).allSatisfy(\.isAvailable))
        XCTAssertEqual(item.icon, MenuItemIcon(symbolName: "arrow.left"))
        XCTAssertEqual(item.alternateActions.map(\.icon), [MenuItemIcon(symbolName: "macwindow"), MenuItemIcon(symbolName: "square")])
    }

    // MARK: Configuration Sheet

    func testTheConfigurationSheetDefaultIconIsThePrimaryActionsCommandIcon() throws {
        let fixture = try makeFixture(manifest(), ownIcon: "star")
        let draft = MenuItemConfigurationDraft(editor: fixture.model.editor, slotIndex: 0)
        XCTAssertEqual(draft.ownIcon, "star")
        XCTAssertEqual(draft.defaultIcon, MenuItemIcon(symbolName: "rectangle.lefthalf.filled"))
        XCTAssertEqual(MenuItemConfigurationDraft(editor: fixture.model.editor, slotIndex: 2).defaultIcon,
                       MenuItemIcon(symbolName: "macwindow"))
    }

    /// The Primary Action picker and the Alternate Action list show each
    /// Command's icon, and the default follows the Primary Action chosen.
    func testTheConfigurationSheetShowsEachCommandsIcon() throws {
        let fixture = try makeFixture(manifest())
        let draft = MenuItemConfigurationDraft(editor: fixture.model.editor, slotIndex: 0)
        XCTAssertEqual(draft.icon(for: CommandID("left")), MenuItemIcon(symbolName: "rectangle.lefthalf.filled"))
        XCTAssertEqual(draft.icon(for: CommandID("right")), MenuItemIcon(symbolName: "rectangle.righthalf.filled"))
        XCTAssertEqual(draft.icon(for: CommandID("plain")), MenuItemIcon(symbolName: "macwindow"))
        draft.primaryCommandID = CommandID("right")
        XCTAssertEqual(draft.defaultIcon, MenuItemIcon(symbolName: "rectangle.righthalf.filled"))

        // A Preset being placed into an empty Slot offers the same icons.
        let placing = MenuItemConfigurationDraft(editor: fixture.model.editor, slotIndex: 3, presetPluginID: pluginID)
        XCTAssertNil(placing.ownIcon)
        XCTAssertEqual(placing.icon(for: CommandID("right")), MenuItemIcon(symbolName: "rectangle.righthalf.filled"))
    }
}
