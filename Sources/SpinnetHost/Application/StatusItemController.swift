import AppKit
import Combine
import SpinnetCore

final class StatusItemController: NSObject, NSMenuDelegate {
    private let actionTarget: StatusItemActionTarget
    private let activities: HostActivities?
    /// A newer Spinnet release is listed first and opens its release page.
    private let releases: SpinnetReleaseChecksModel?
    private var releaseObservation: AnyCancellable?
    private let services = ReviewedServicesMenuController()
    private var observation: UUID?
    private weak var openMenu: NSMenu?
    private var cancelTick: (() -> Void)?
    private let scheduleTick: (@escaping () -> Void) -> (() -> Void)

    /// Created once at install and then only shown or hidden, so it keeps the
    /// place the user Command-dragged it to.
    private(set) var statusItem: NSStatusItem?
    /// The saved Show Status Item preference. While it is off the Status Item
    /// still shows whenever a Host Activity is ongoing, so its Stop control
    /// stays reachable.
    private var showsStatusItem = true

    init(openSettings: @escaping () -> Void, quit: @escaping () -> Void, activities: HostActivities? = nil,
         releases: SpinnetReleaseChecksModel? = nil,
         scheduleTick: @escaping (@escaping () -> Void) -> (() -> Void) = HostActivityListModel.schedule) {
        self.scheduleTick = scheduleTick
        self.activities = activities
        self.releases = releases
        actionTarget = StatusItemActionTarget(openSettings: openSettings, quit: quit,
                                              stop: { activities?.stop($0) },
                                              openRelease: { releases?.openAvailableRelease() })
        super.init()
        releaseObservation = releases?.$status.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let menu = self.openMenu { self.replaceItems(in: menu) } else { self.statusItem?.menu = self.makeMenu() }
            }
        }
        observation = activities?.observeChanges { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let menu = self.openMenu { self.replaceItems(in: menu); self.reconcileTick() }
                else { self.statusItem?.menu = self.makeMenu() }
                self.reconcileVisibility()
            }
        }
    }

    deinit { cancelTick?(); if let observation { activities?.removeChangeObserver(observation) } }

    func install() {
        guard statusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "Spinnet Status Item"
        statusItem.button?.image = NSImage(
            systemSymbolName: "circle.hexagongrid.fill",
            accessibilityDescription: "Spinnet"
        )
        statusItem.button?.setAccessibilityLabel("Spinnet Status Item")
        statusItem.button?.setAccessibilityHelp("Open Settings, stop ongoing activities, or Quit Spinnet.")
        statusItem.button?.toolTip = "Spinnet Status Item"
        statusItem.menu = makeMenu()
        self.statusItem = statusItem
        reconcileVisibility()
    }

    func setShowsStatusItem(_ shows: Bool) {
        showsStatusItem = shows
        reconcileVisibility()
    }

    /// Shows or hides the Status Item. An open menu is never pulled away;
    /// the Status Item hides once the menu closes.
    private func reconcileVisibility() {
        guard let statusItem else { return }
        let shown = showsStatusItem || !ongoingActivities.isEmpty
        if shown { statusItem.isVisible = true }
        else if openMenu == nil { statusItem.isVisible = false }
    }

    /// Host Activities the Status Item lists: an ended Task is history, not
    /// ongoing.
    private var ongoingActivities: [HostActivity] {
        (activities?.list() ?? []).filter {
            !($0.kind == "task" && $0.detail?.value(atPointer: "/status") == .string("ended"))
        }
    }

    func showServices(_ model: ReviewedServicesSurface, owner: PluginID) {
        services.show(model, owner: owner)
        if let menu = openMenu { replaceItems(in: menu) }
        else { statusItem?.menu = makeMenu() }
    }
    func invalidateServices(_ owner: PluginID) {
        services.invalidate(owner)
        if let menu = openMenu { replaceItems(in: menu) }
        else { statusItem?.menu = makeMenu() }
    }
    func closeServices() {
        services.close()
        if let menu = openMenu { replaceItems(in: menu) }
        else { statusItem?.menu = makeMenu() }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Spinnet Status Item")
        menu.autoenablesItems = false
        menu.delegate = self
        menu.setAccessibilityLabel("Spinnet Status Item Menu")

        if let release = releases?.availableRelease {
            let releaseItem = NSMenuItem(title: "Spinnet \(release.version) Is Available…",
                                         action: #selector(StatusItemActionTarget.openRelease(_:)), keyEquivalent: "")
            releaseItem.target = actionTarget
            releaseItem.setAccessibilityHelp("Open the release page on GitHub. Nothing is downloaded.")
            menu.addItem(releaseItem)
            menu.addItem(.separator())
        }

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

        for activity in ongoingActivities {
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

        services.append(to: menu)
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
        services.hide()
        openMenu = nil
        cancelTick?(); cancelTick = nil
        reconcileVisibility()
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
    private let openReleaseAction: () -> Void

    init(openSettings: @escaping () -> Void, quit: @escaping () -> Void, stop: @escaping (String) -> Void,
         openRelease: @escaping () -> Void) {
        openSettingsAction = openSettings
        quitAction = quit
        stopAction = stop
        openReleaseAction = openRelease
    }

    @objc func openRelease(_ sender: Any?) {
        openReleaseAction()
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
