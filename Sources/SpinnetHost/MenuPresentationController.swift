import AppKit
import Carbon
import SpinnetCore

final class MenuPresentationController {
    private var layout: RadialMenuLayout
    private let panel: NSPanel
    private var menuView: RadialMenuView
    private var slots: [MenuSlotPresentation]
    private var appearanceConfiguration: MenuAppearanceConfiguration
    private var outsideClickMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var alternateMenu: NSMenu?

    private(set) var isOpen = false
    var onPrimaryAction: ((ActionID) -> Void)?
    var onAlternateAction: ((ActionID) -> Void)?
    var onEmptySlotActivated: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    init(
        items: [MenuSlotPresentation],
        appearance: MenuAppearanceConfiguration = MenuAppearanceConfiguration()
    ) {
        self.slots = items
        self.appearanceConfiguration = appearance
        self.layout = appearance.layout(slotCount: items.count)
        self.menuView = RadialMenuView(slots: items)
        menuView.applyAppearance(appearance)
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
        panel.appearance = appearance.appearance

        configureMenuView()
    }

    func reload(items: [MenuSlotPresentation]) {
        if isOpen { dismiss() }
        self.slots = items
        self.layout = appearanceConfiguration.layout(slotCount: items.count)
        self.menuView = RadialMenuView(slots: items)
        menuView.applyAppearance(appearanceConfiguration)
        panel.contentView = menuView
        configureMenuView()
    }

    func applyAppearance(_ appearance: MenuAppearanceConfiguration) {
        if isOpen { dismiss() }
        appearanceConfiguration = appearance
        layout = appearance.layout(slotCount: slots.count)
        panel.appearance = appearance.appearance
        menuView.applyAppearance(appearance)
        panel.setContentSize(menuView.bounds.size)
    }

    var presentationSnapshot: (
        theme: String,
        accent: String,
        menuSize: String,
        outerRadius: CGFloat
    ) {
        (
            appearanceConfiguration.theme,
            appearanceConfiguration.accent,
            appearanceConfiguration.menuSize,
            layout.outerRadius
        )
    }

    private func configureMenuView() {
        menuView.onPrimarySelection = { [weak self] index in self?.activateSlot(at: index) }
        menuView.onAlternateSelection = { [weak self] index in self?.showAlternates(for: index) }
        menuView.onCancel = { [weak self] in self?.dismiss() }
    }

    func open(at pointer: CGPoint) {
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

    func updateGesture(at screenPoint: CGPoint) {
        guard isOpen else { return }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        menuView.updateRuntimeSelection(at: menuView.convert(windowPoint, from: nil))
    }

    func finishGesture(at screenPoint: CGPoint) {
        guard isOpen else { return }
        updateGesture(at: screenPoint)
        guard let index = menuView.selectedIndex else {
            dismiss()
            return
        }
        activateSlot(at: index)
    }

    func activateSlot(at index: Int) {
        guard slots.indices.contains(index) else { return }
        dismiss()
        guard let item = slots[index].item else {
            onEmptySlotActivated?(index)
            return
        }
        onPrimaryAction?(item.configuration.primaryActionID)
    }

    private func showAlternates(for index: Int) {
        guard slots.indices.contains(index) else { return }
        guard let item = slots[index].item else {
            activateSlot(at: index)
            return
        }

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
