import SpinnetCore
import XCTest
@testable import SpinnetHost

final class CommandDescriptionPresentationTests: XCTestCase {

    func testTheRuntimeActionsMenuShowsEachDescriptionAsItsToolTip() throws {
        let primaryID = ActionID("maximise")
        let alternateID = ActionID("left-half")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: primaryID, alternateActionIDs: [alternateID]),
            primaryAction: MenuActionPresentation(
                actionID: primaryID, title: "Maximise Window", availability: .available,
                explanation: "Fills the screen, leaving the menu bar and Dock visible."
            ),
            alternateActions: [MenuActionPresentation(
                actionID: alternateID, title: "Left Half",
                availability: .unavailable(.systemPermissionDenied),
                explanation: "Fills the left half of the screen."
            )]
        )
        let menu = try XCTUnwrap(MenuPresentationController(items: [.occupied(item)]).makeActionMenu(for: 0))
        let items = menu.items.filter { !$0.isSeparatorItem }

        XCTAssertEqual(items[0].toolTip, "Fills the screen, leaving the menu bar and Dock visible.")
        // An unavailable Action still says why before what it does.
        XCTAssertEqual(
            items[1].toolTip,
            "Unavailable: \(ActionUnavailableReason.systemPermissionDenied.description)\nFills the left half of the screen."
        )
    }

    func testAnActionWithoutADescriptionKeepsItsFormerToolTip() {
        let action = MenuActionPresentation(actionID: ActionID("a"), title: "Open URL", availability: .available)
        XCTAssertEqual(action.toolTip, "Open URL")
    }

    /// The description comes from the Command registered now, so Actions
    /// configured before a Plugin described its Commands still show one.
    func testSlotsTakeDescriptionsFromTheRegisteredCommand() throws {
        let saved = CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript,
                                       isConfigurable: false, script: "run.js")
        let described = CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript,
                                           isConfigurable: false, script: "run.js", explanation: "Runs the example.")
        let pluginID = PluginID("com.example.described")
        let registry = PluginRegistry()
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/described.spinnetplugin"), manifest: PluginManifest(
            id: pluginID, name: "Described", version: "1.0.0", commands: [described],
            preset: MenuItemPresetDeclaration(readiness: .readyToUse, isConfigurable: false))))
        let action = try ActionConfiguration(id: ActionID("run"), pluginID: pluginID, command: saved, input: .null)
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(slots: [.occupied(MenuItemConfiguration(primaryActionID: action.id))])
        )
        let slots = MenuPresentationFactory.makeSlots(configuration: configuration,
                                                      plugins: InstalledPlugins(registry: registry))
        XCTAssertEqual(slots[0].item?.primaryAction.explanation, "Runs the example.")
        XCTAssertTrue(try XCTUnwrap(slots[0].item).primaryAction.isAvailable,
                      "A description is display-only, so the saved Action still matches its Command")
    }
}
