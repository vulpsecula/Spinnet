import AppKit
import SpinnetCore

final class StatusItemController: NSObject, NSMenuDelegate {
    private let actionTarget: StatusItemActionTarget
    private let activities: HostActivities?
    private var observation: UUID?
    private weak var openMenu: NSMenu?
    private var cancelTick: (() -> Void)?
    private let scheduleTick: (@escaping () -> Void) -> (() -> Void)

    private(set) var statusItem: NSStatusItem?

    init(openSettings: @escaping () -> Void, quit: @escaping () -> Void, activities: HostActivities? = nil,
         scheduleTick: @escaping (@escaping () -> Void) -> (() -> Void) = HostActivityListModel.schedule) {
        self.scheduleTick = scheduleTick
        self.activities = activities
        actionTarget = StatusItemActionTarget(openSettings: openSettings, quit: quit,
                                              stop: { activities?.stop($0) })
        super.init()
        observation = activities?.observeChanges { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let menu = self.openMenu { self.replaceItems(in: menu); self.reconcileTick() }
                else { self.statusItem?.menu = self.makeMenu() }
            }
        }
    }

    deinit { cancelTick?(); if let observation { activities?.removeChangeObserver(observation) } }

    func install() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "circle.hexagongrid.fill",
            accessibilityDescription: "Spinnet"
        )
        statusItem.button?.setAccessibilityLabel("Spinnet Status Item")
        statusItem.button?.setAccessibilityHelp("Open Settings, stop ongoing activities, or Quit Spinnet.")
        statusItem.button?.toolTip = "Spinnet Status Item"
        statusItem.menu = makeMenu()
        self.statusItem = statusItem
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Spinnet Status Item")
        menu.autoenablesItems = false
        menu.delegate = self
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

        for activity in activities?.list() ?? [] {
            let heading = NSMenuItem(title: activity.name, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            let status = NSMenuItem(title: activity.status, action: nil, keyEquivalent: "")
            status.isEnabled = false; status.indentationLevel = 1
            status.identifier = NSUserInterfaceItemIdentifier("activity-status:" + activity.id)
            menu.addItem(status)
            if activity.kind == "keep_awake" {
                let scope = NSMenuItem(title: "Mac and display stay awake while idle", action: nil, keyEquivalent: "")
                scope.isEnabled = false; scope.indentationLevel = 1
                menu.addItem(scope)
                let limit = NSMenuItem(title: "Sleep, lid closure and low battery still apply", action: nil, keyEquivalent: "")
                limit.isEnabled = false; limit.indentationLevel = 1
                menu.addItem(limit)
            }
            let stop = NSMenuItem(title: "Stop \(activity.name)", action: #selector(StatusItemActionTarget.stop(_:)), keyEquivalent: "")
            stop.target = actionTarget; stop.representedObject = activity.id
            stop.setAccessibilityHelp("Stop this Host-owned activity.")
            stop.isEnabled = activity.canStop
            menu.addItem(stop)
            menu.addItem(.separator())
        }

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

    func menuWillOpen(_ menu: NSMenu) {
        openMenu = menu
        replaceItems(in: menu)
        reconcileTick()
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenu = nil
        cancelTick?(); cancelTick = nil
    }

    private func replaceItems(in menu: NSMenu) {
        let current = makeMenu()
        menu.removeAllItems()
        for item in current.items { current.removeItem(item); menu.addItem(item) }
    }

    private func reconcileTick() {
        guard openMenu != nil, activities?.list().contains(where: { $0.remainingSeconds != nil }) == true else {
            cancelTick?(); cancelTick = nil; return
        }
        if cancelTick == nil { cancelTick = scheduleTick { [weak self] in self?.refreshCountdowns() } }
    }

    private func refreshCountdowns() {
        guard let menu = openMenu else { return }
        let statuses = Dictionary(uniqueKeysWithValues: (activities?.list() ?? []).map { ("activity-status:" + $0.id, $0.status) })
        // Update titles in place: a second tick must not replace the menu
        // or disturb the user pointing at its Stop control.
        for item in menu.items {
            if let id = item.identifier?.rawValue, let status = statuses[id] { item.title = status }
        }
        reconcileTick()
    }

}

private final class StatusItemActionTarget: NSObject {
    private let openSettingsAction: () -> Void
    private let quitAction: () -> Void
    private let stopAction: (String) -> Void

    init(openSettings: @escaping () -> Void, quit: @escaping () -> Void, stop: @escaping (String) -> Void) {
        openSettingsAction = openSettings
        quitAction = quit
        stopAction = stop
    }

    @objc func openSettings(_ sender: Any?) {
        openSettingsAction()
    }

    @objc func quit(_ sender: Any?) {
        quitAction()
    }

    @objc func stop(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        stopAction(id)
    }
}
