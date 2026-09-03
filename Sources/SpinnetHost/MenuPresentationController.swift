import AppKit
import Carbon
import SpinnetCore

final class MenuPresentationController {
    private var layout: RadialMenuLayout
    private let panel: NSPanel
    private var menuView: RadialMenuView
    private var items: [MenuItemPresentation]
    private var outsideClickMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var alternateMenu: NSMenu?

    private(set) var isOpen = false
    var onPrimaryAction: ((ActionID) -> Void)?
    var onAlternateAction: ((ActionID) -> Void)?
    var onDismiss: (() -> Void)?

    init(items: [MenuItemPresentation]) {
        self.items = items
        self.layout = RadialMenuLayout(itemCount: max(items.count, 1))
        self.menuView = RadialMenuView(items: items)
        self.panel = NSPanel(
            contentRect: menuView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = menuView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true

        configureMenuView()
    }

    func reload(items: [MenuItemPresentation]) {
        if isOpen { dismiss() }
        self.items = items
        self.layout = RadialMenuLayout(itemCount: max(items.count, 1))
        self.menuView = RadialMenuView(items: items)
        panel.contentView = menuView
        configureMenuView()
    }

    private func configureMenuView() {
        menuView.onPrimarySelection = { [weak self] index in self?.select(index: index) }
        menuView.onAlternateSelection = { [weak self] index in self?.showAlternates(for: index) }
        menuView.onCancel = { [weak self] in self?.dismiss() }
    }

    func open(at pointer: CGPoint) {
        guard !items.isEmpty else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
            return
        }
        let frame = layout.overlayFrame(for: pointer, in: screen.visibleFrame)
        menuView.clearSelection()
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(menuView)
        isOpen = true
        installDismissalMonitors()
    }

    func dismiss() {
        guard isOpen else { return }
        removeDismissalMonitors()
        panel.orderOut(nil)
        isOpen = false
        onDismiss?()
    }

    private func select(index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        dismiss()
        onPrimaryAction?(item.configuration.primaryActionID)
    }

    private func showAlternates(for index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]

        let menu = NSMenu(title: "Alternate Actions")
        menu.autoenablesItems = false
        for alternate in item.alternateActions {
            let menuItem = NSMenuItem(
                title: alternate.displayTitle,
                action: #selector(selectAlternate(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = alternate.actionID.rawValue
            menuItem.isEnabled = alternate.isAvailable
            menuItem.toolTip = alternate.accessibilityLabel
            menu.addItem(menuItem)
        }
        if item.alternateActions.isEmpty {
            let emptyItem = NSMenuItem(
                title: "No Alternate Actions configured",
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        }

        alternateMenu = menu
        let center = CGPoint(x: menuView.bounds.midX, y: menuView.bounds.midY)
        menu.popUp(positioning: nil, at: center, in: menuView)
        alternateMenu = nil
    }

    @objc private func selectAlternate(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String else { return }
        let actionID = ActionID(rawID)
        dismiss()
        onAlternateAction?(actionID)
    }

    private func installDismissalMonitors() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self, self.isOpen else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) {
                self.dismiss()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isOpen else { return event }
            let point = self.menuView.convert(event.locationInWindow, from: nil)
            let center = CGPoint(
                x: self.menuView.bounds.midX,
                y: self.menuView.bounds.midY
            )
            guard self.layout.hitTest(point: point, center: center) != nil else {
                self.dismiss()
                return nil
            }
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.dismiss()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.isOpen, event.keyCode == UInt16(kVK_Escape) else { return }
            self.dismiss()
        }
    }

    private func removeDismissalMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        outsideClickMonitor = nil
        localMouseMonitor = nil
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }
}
