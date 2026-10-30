import AppKit
import Combine
import SpinnetCore

final class StatusItemController: NSObject, NSMenuDelegate {
    private let actionTarget: StatusItemActionTarget
    private let activities: HostActivities?
    private let taskWindows: TaskDetailWindows?
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
        let taskWindows = activities.map { TaskDetailWindows(activities: $0) }
        self.taskWindows = taskWindows
        actionTarget = StatusItemActionTarget(openSettings: openSettings, quit: quit,
                                              stop: { activities?.stop($0) },
                                              openTask: { taskWindows?.show($0) },
                                              clearTask: { activities?.clearEndedTask($0) },
                                              clearEndedTasks: { activities?.clearEndedTasks() },
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
        statusItem.autosaveName = "Spinnet Status Item" // Not localized: the saved position's name
        statusItem.button?.image = NSImage(
            systemSymbolName: "circle.hexagongrid.fill",
            accessibilityDescription: "Spinnet"
        )
        statusItem.button?.setAccessibilityLabel(localized("Spinnet Status Item"))
        statusItem.button?.setAccessibilityHelp(localized("Open Settings, stop ongoing activities, or Quit Spinnet."))
        statusItem.button?.toolTip = localized("Spinnet Status Item")
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

    /// Ended Tasks remain listed but do not keep a hidden Status Item visible.
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
        let menu = NSMenu(title: localized("Spinnet Status Item"))
        menu.autoenablesItems = false
        menu.delegate = self
        menu.setAccessibilityLabel(localized("Spinnet Status Item Menu"))

        if let release = releases?.availableRelease {
            let releaseItem = NSMenuItem(title: localized("Spinnet \(release.version) Is Available…"),
                                         action: #selector(StatusItemActionTarget.openRelease(_:)), keyEquivalent: "")
            releaseItem.target = actionTarget
            releaseItem.setAccessibilityHelp(localized("Open the release page on GitHub. Nothing is downloaded."))
            menu.addItem(releaseItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(
            title: localized("Settings…"),
            action: #selector(StatusItemActionTarget.openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = actionTarget
        settingsItem.setAccessibilityLabel(localized("Settings"))
        settingsItem.setAccessibilityHelp(localized("Open Spinnet Settings."))
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let listedActivities = activities?.list() ?? []
        for activity in listedActivities {
            let ended = activity.kind == "task" && activity.detail?.value(atPointer: "/status") == .string("ended")
            let heading = NSMenuItem(title: activity.localizedName,
                action: activity.kind == "task" ? #selector(StatusItemActionTarget.openTask(_:)) : nil, keyEquivalent: "")
            heading.isEnabled = activity.kind == "task"
            if activity.kind == "task" {
                heading.target = actionTarget; heading.representedObject = activity.id
                heading.setAccessibilityLabel(localized("Open Task details for \(activity.localizedName)"))
            }
            menu.addItem(heading)
            let status = NSMenuItem(title: activity.localizedStatus, action: nil, keyEquivalent: "")
            status.isEnabled = false; status.indentationLevel = 1
            status.identifier = NSUserInterfaceItemIdentifier("activity-status:" + activity.id)
            menu.addItem(status)
            if activity.kind == "keep_awake" {
                let scope = NSMenuItem(title: localized("Mac and display stay awake while idle"), action: nil, keyEquivalent: "")
                scope.isEnabled = false; scope.indentationLevel = 1
                menu.addItem(scope)
                let limit = NSMenuItem(title: localized("Sleep, lid closure and low battery still apply"), action: nil, keyEquivalent: "")
                limit.isEnabled = false; limit.indentationLevel = 1
                menu.addItem(limit)
            }
            if ended {
                let clear = NSMenuItem(title: localized("Clear \(activity.localizedName)"), action: #selector(StatusItemActionTarget.clearTask(_:)), keyEquivalent: "")
                clear.target = actionTarget; clear.representedObject = activity.id
                clear.setAccessibilityHelp(localized("Clear this ended Task."))
                menu.addItem(clear)
            } else {
                let stop = NSMenuItem(title: localized("Stop \(activity.localizedName)"), action: #selector(StatusItemActionTarget.stop(_:)), keyEquivalent: "")
                stop.target = actionTarget; stop.representedObject = activity.id
                stop.setAccessibilityHelp(localized("Stop this Host-owned activity."))
                stop.isEnabled = activity.canStop
                menu.addItem(stop)
            }
            menu.addItem(.separator())
        }

        if listedActivities.contains(where: { $0.kind == "task" && $0.detail?.value(atPointer: "/status") == .string("ended") }) {
            let clear = NSMenuItem(title: localized("Clear Ended Tasks"), action: #selector(StatusItemActionTarget.clearEndedTasks(_:)), keyEquivalent: "")
            clear.target = actionTarget
            clear.setAccessibilityHelp(localized("Clear all ended Tasks."))
            menu.addItem(clear); menu.addItem(.separator())
        }

        services.append(to: menu)
        let quitItem = NSMenuItem(
            title: localized("Quit Spinnet"),
            action: #selector(StatusItemActionTarget.quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = actionTarget
        quitItem.setAccessibilityLabel(localized("Quit Spinnet"))
        quitItem.setAccessibilityHelp(localized("Quit the Spinnet Host."))
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
        let statuses = Dictionary(uniqueKeysWithValues: (activities?.list() ?? []).map { ("activity-status:" + $0.id, $0.localizedStatus) })
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
    private let openTaskAction: (String) -> Void
    private let clearTaskAction: (String) -> Void
    private let clearEndedTasksAction: () -> Void
    private let openReleaseAction: () -> Void

    init(openSettings: @escaping () -> Void, quit: @escaping () -> Void, stop: @escaping (String) -> Void,
         openTask: @escaping (String) -> Void, clearTask: @escaping (String) -> Void, clearEndedTasks: @escaping () -> Void,
         openRelease: @escaping () -> Void) {
        openSettingsAction = openSettings
        quitAction = quit
        stopAction = stop
        openTaskAction = openTask
        clearTaskAction = clearTask
        clearEndedTasksAction = clearEndedTasks
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
    @objc func openTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openTaskAction(id)
    }
    @objc func clearTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        clearTaskAction(id)
    }
    @objc func clearEndedTasks(_ sender: Any?) { clearEndedTasksAction() }
}
