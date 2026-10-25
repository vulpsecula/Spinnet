import AppKit
import SpinnetCore

/// A Host-generated section, not Plugin-supplied menu content or a resident helper.
final class ReviewedServicesMenuController: NSObject, NSMenuDelegate {
    private var model: ReviewedServicesSurface?
    private var owner: PluginID?
    private let menu = NSMenu(title: "Homebrew Services")
    private var isOpen = false
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var sessionActive = true
    private var displaysAwake = true

    override init() {
        super.init()
        menu.autoenablesItems = false; menu.delegate = self
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if note.name == NSWorkspace.sessionDidBecomeActiveNotification { self.sessionActive = true }
                if note.name == NSWorkspace.sessionDidResignActiveNotification { self.sessionActive = false }
                if note.name == NSWorkspace.screensDidSleepNotification { self.displaysAwake = false }
                if note.name == NSWorkspace.screensDidWakeNotification { self.displaysAwake = true }
                self.model?.setVisible(self.isOpen && self.sessionActive && self.displaysAwake)
            })
        }
    }
    func show(_ model: ReviewedServicesSurface, owner: PluginID) {
        self.model?.close(); generation = UUID()
        self.model = model; self.owner = owner
        model.onChange = { [weak self] in self?.update() }
        update()
        model.setVisible(isOpen && sessionActive && displaysAwake)
    }
    func invalidate(_ owner: PluginID) {
        guard self.owner == owner else { return }
        close()
    }
    func close() {
        model?.close(); model = nil; self.owner = nil; generation = UUID(); update()
    }
    func append(to parent: NSMenu) {
        guard model != nil else { return }
        // Transfer the submenu without changing its delegate or its controls.
        menu.supermenu?.items.first(where: { $0.submenu === menu })?.submenu = nil
        let item = NSMenuItem(title: "Homebrew Services", action: nil, keyEquivalent: "")
        item.submenu = menu; parent.addItem(item); parent.addItem(.separator())
    }
    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true; model?.setVisible(sessionActive && displaysAwake); update()
    }
    func menuDidClose(_ menu: NSMenu) { hide() }
    func hide() {
        isOpen = false
        let token = generation
        // AppKit delivers a selected item's action after menuDidClose. Allow
        // that one synchronous selection to enter Host Confirmation first.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isOpen, self.generation == token else { return }
            self.model?.setVisible(false)
        }
    }
    private func update() {
        menu.removeAllItems()
        guard let model else { return }
        let message = NSMenuItem(title: model.message.isEmpty ? "Open to read service status" : model.message, action: nil, keyEquivalent: "")
        message.isEnabled = false; menu.addItem(message)
        for row in model.rows {
            let item = NSMenuItem(title: row.name + " · " + row.status + (row.userOwned ? "" : " · Other account"), action: nil, keyEquivalent: "")
            if row.userOwned {
                let controls = NSMenu(title: row.name); controls.autoenablesItems = false
                for operation in ReviewedServicesSurface.Operation.allCases {
                    let title = operation == .start ? "Start" : operation == .stop ? "Stop" : "Restart"
                    let control = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
                    control.target = self; control.representedObject = Selection(generation: generation, name: row.name, operation: operation)
                    control.isEnabled = model.canChoose(operation, name: row.name); controls.addItem(control)
                }
                item.submenu = controls
            } else { item.isEnabled = false }
            menu.addItem(item)
        }
    }
    private struct Selection { let generation: UUID; let name: String; let operation: ReviewedServicesSurface.Operation }
    @objc private func choose(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? Selection, selection.generation == generation, let model else { return }
        do { try model.choose(selection.operation, name: selection.name) }
        catch { menu.removeAllItems(); let errorItem = NSMenuItem(title: error.localizedDescription, action: nil, keyEquivalent: ""); errorItem.isEnabled = false; menu.addItem(errorItem) }
    }
    deinit { model?.close(); observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
}
