import AppKit
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

/// Runtime Mode applies the Current App's App Overrides at invocation and
/// presents the default Menu otherwise (#113).
final class MenuAppOverridePresentationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private static func app(_ bundleIdentifier: String?, _ name: String) -> CurrentApp {
        CurrentApp(
            identity: RunningAppIdentity(processIdentifier: 40, bundleIdentifier: bundleIdentifier,
                                         launchDate: Date(timeIntervalSince1970: 1), name: name),
            bundleURL: nil)
    }

    func testOpeningTheMenuPresentsTheCurrentAppsOverridesAndTheDefaultMenuOtherwise() throws {
        let command = CommandDeclaration(id: CommandID("copy"), title: "Copy", hostServiceID: "open.url")
        let actions = try ["open", "safari"].map {
            try ActionConfiguration(id: ActionID($0), pluginID: PluginID("fixture"), command: command, input: .null)
        }
        let configuration = try HostConfiguration(actions: actions, menu: MenuConfiguration(slots: [
            MenuSlotConfiguration(
                item: try MenuItemConfiguration(primaryActionID: ActionID("open")),
                appOverrides: [AppBundleIdentifier(validating: "com.apple.Safari")!: .item(
                    try MenuItemConfiguration(primaryActionID: ActionID("safari")))]
            ),
            MenuSlotConfiguration(item: nil, appOverrides: [AppBundleIdentifier(validating: "com.apple.finder")!: .empty])
        ]))
        let menu = MenuPresentationController(
            items: MenuPresentationFactory.makeSlots(configuration: configuration) { _ in .available }
        )
        menu.onRefresh = { app in
            MenuPresentationFactory.makeSlots(configuration: configuration, app: app?.appBundleIdentifier) { _ in .available }
        }
        defer { menu.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main)
        let pointer = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        func primaryAction(inSlot index: Int) -> String? {
            menu.makeActionMenu(for: index)?.items.first?.representedObject as? String
        }

        menu.open(at: pointer, currentApp: Self.app("com.apple.Safari", "Safari"))
        XCTAssertEqual(primaryAction(inSlot: 0), "safari")
        menu.dismiss()

        for other in [Self.app("com.apple.finder", "Finder"), Self.app(nil, "Unbundled"), nil] {
            menu.open(at: pointer, currentApp: other)
            XCTAssertEqual(primaryAction(inSlot: 0), "open")
            menu.dismiss()
        }
    }
}
