import AppKit

final class StatusItemController {
    private let actionTarget: StatusItemActionTarget

    private(set) var statusItem: NSStatusItem?

    init(openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        actionTarget = StatusItemActionTarget(openSettings: openSettings, quit: quit)
    }

    func install() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "◉"
        statusItem.button?.setAccessibilityLabel("Spinnet Status Item")
        statusItem.button?.setAccessibilityHelp("Open Settings or Quit Spinnet.")
        statusItem.button?.toolTip = "Spinnet Status Item"
        statusItem.menu = makeMenu()
        self.statusItem = statusItem
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Spinnet Status Item")
        menu.autoenablesItems = false
        menu.setAccessibilityLabel("Spinnet Status Item Menu")

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(StatusItemActionTarget.openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = actionTarget
        settingsItem.setAccessibilityLabel("Settings")
        settingsItem.setAccessibilityHelp("Open Spinnet Settings.")
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Spinnet",
            action: #selector(StatusItemActionTarget.quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = actionTarget
        quitItem.setAccessibilityLabel("Quit Spinnet")
        quitItem.setAccessibilityHelp("Quit the Spinnet Host.")
        menu.addItem(quitItem)
        return menu
    }
}

private final class StatusItemActionTarget: NSObject {
    private let openSettingsAction: () -> Void
    private let quitAction: () -> Void

    init(openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        openSettingsAction = openSettings
        quitAction = quit
    }

    @objc func openSettings(_ sender: Any?) {
        openSettingsAction()
    }

    @objc func quit(_ sender: Any?) {
        quitAction()
    }
}
