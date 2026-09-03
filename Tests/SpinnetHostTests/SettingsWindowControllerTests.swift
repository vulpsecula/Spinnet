import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class SettingsWindowControllerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testSettingsNavigationKeepsEditorModeOnlyOnMenuAndAppearance() throws {
        let controller = try makeController()

        XCTAssertEqual(
            controller.presentationSnapshot.navigationPages,
            [.menu, .appearance, .privacyAndPermissions, .about]
        )
        XCTAssertEqual(controller.presentationSnapshot.page, .menu)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .editorMode, .pageContent]
        )

        controller.select(page: .appearance)

        XCTAssertEqual(controller.presentationSnapshot.page, .appearance)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .editorMode, .pageContent]
        )
        XCTAssertTrue(controller.presentationSnapshot.editorModeIsNonExecuting)
        XCTAssertTrue(controller.presentationSnapshot.accessibleNames.contains("Appearance"))

        controller.select(page: .privacyAndPermissions)

        XCTAssertEqual(controller.presentationSnapshot.page, .privacyAndPermissions)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .pageContent]
        )
        for expectedName in [
            "System Permissions",
            "Sensitive Data Collection",
            "Plugin Access",
            "Open macOS System Settings"
        ] {
            XCTAssertTrue(
                controller.presentationSnapshot.accessibleNames.contains(expectedName),
                "Missing accessible Privacy & Permissions content: \(expectedName)"
            )
        }

        controller.select(page: .about)

        XCTAssertEqual(controller.presentationSnapshot.page, .about)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .pageContent]
        )
        XCTAssertFalse(controller.presentationSnapshot.visibleRegions.contains(.editorMode))
    }

    func testAboutPageExposesApplicationIdentityAndLinksAtSettingsBoundary() throws {
        let controller = try makeController()
        controller.select(page: .about)

        let names = controller.presentationSnapshot.accessibleNames
        for expectedName in [
            "Spinnet",
            "Version 0.1 (Build Development)",
            "A mouse-first macOS action environment centered on a radial Menu.",
            "Source on GitHub",
            "Licence",
            "Acknowledgements",
            "Copyright"
        ] {
            XCTAssertTrue(names.contains(expectedName), "Missing accessible About content: \(expectedName)")
        }
    }

    func testSettingsNavigationPublishesPredictableFocusOrderAndNames() throws {
        let controller = try makeController()

        XCTAssertEqual(
            controller.presentationSnapshot.focusOrder,
            [
                .navigation(.menu),
                .navigation(.appearance),
                .navigation(.privacyAndPermissions),
                .navigation(.about),
                .pageContent
            ]
        )
        XCTAssertEqual(
            controller.presentationSnapshot.initialFocus,
            .navigation(.menu)
        )
        XCTAssertEqual(
            Array(controller.presentationSnapshot.accessibleNames.prefix(4)),
            ["Menu", "Appearance", "Privacy & Permissions", "About"]
        )
    }

    func testStatusItemMenuOnlyOffersSettingsAndQuitWithAccessibleNames() {
        let statusItem = StatusItemController(openSettings: {}, quit: {})
        let menu = statusItem.makeMenu()

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Settings…", "Quit Spinnet"]
        )
        XCTAssertEqual(menu.items.first(where: { $0.title == "Settings…" })?.keyEquivalent, ",")
        XCTAssertEqual(menu.items.first(where: { $0.title == "Quit Spinnet" })?.keyEquivalent, "q")
        XCTAssertEqual(
            menu.items.first(where: { $0.title == "Settings…" })?.accessibilityLabel(),
            "Settings"
        )
        XCTAssertEqual(
            menu.items.first(where: { $0.title == "Quit Spinnet" })?.accessibilityLabel(),
            "Quit Spinnet"
        )
    }

    private func makeController() throws -> SettingsWindowController {
        let registry = PluginRegistry()
        let manifest = try PluginManifest(
            id: PluginID("com.spinnet.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [CommandDeclaration(
                id: CommandID("fixture.open"),
                title: "Open URL",
                hostCommand: .openURL
            )]
        )
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        ))
        let action = try ActionConfiguration(
            id: ActionID("open-url"),
            pluginID: manifest.id,
            command: manifest.commands[0],
            input: .string("https://example.com")
        )
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(primaryActionID: action.id)
            ])
        )
        let controller = SettingsWindowController(
            editor: HostConfigurationEditor(registry: registry, configuration: configuration)
        )
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }
}
