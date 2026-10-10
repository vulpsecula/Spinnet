import AppKit
import SpinnetCore

/// Controlled Host Surface: names/status come from a reviewed profile and
/// every native control enters the existing confirmed Task admission path.
final class ReviewedServicesWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: NSPanel?
    private var model: ReviewedServicesSurface?
    private var owner: PluginID?
    private var sessionActive = true
    private var displaysAwake = true
    private var selectedName: String?
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var buttons: [ReviewedServicesSurface.Operation: NSButton] = [:]
    private var refreshButton: NSButton?
    private var observations: [NSObjectProtocol] = []

    func show(_ model: ReviewedServicesSurface, owner: PluginID) {
        self.model?.close()
        self.model = model; self.owner = owner; selectedName = nil
        if panel == nil { makePanel() }
        model.onChange = { [weak self] in self?.update() }
        panel?.title = "Homebrew Services"
        panel?.center(); panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.setVisible(true); update()
    }
    func invalidate(_ owner: PluginID) { if self.owner == owner { close() } }
    func close() { model?.close(); model = nil; panel?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { model?.close(); model = nil }
    func numberOfRows(in tableView: NSTableView) -> Int { model?.rows.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model, model.rows.indices.contains(row) else { return nil }
        let service = model.rows[row]
        let text = tableColumn?.identifier.rawValue == "name" ? service.name : service.status + (service.userOwned ? "" : " · Other account")
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedName = model.flatMap { $0.rows.indices.contains(table.selectedRow) ? $0.rows[table.selectedRow].name : nil }
        updateButtons()
    }

    private func makePanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.delegate = self; panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 440, height: 280)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let heading = NSTextField(labelWithString: "User-owned Homebrew Services")
        heading.font = .boldSystemFont(ofSize: 15)
        root.addArrangedSubview(heading)
        let detail = NSTextField(wrappingLabelWithString: "Start, stop or restart a selected service after Spinnet confirms its target. Status refreshes while this surface is visible.")
        detail.textColor = .secondaryLabelColor
        root.addArrangedSubview(detail)
        table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = false
        for (id, title, width) in [("name", "Service", 320.0), ("status", "Status", 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        root.addArrangedSubview(scroll)
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8
        for operation in ReviewedServicesSurface.Operation.allCases {
            let title: String = operation == .start ? "Start" : operation == .stop ? "Stop" : "Restart"
            let button = NSButton(title: title, target: self, action: #selector(changeService(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(operation.rawValue)
            buttons[operation] = button; actions.addArrangedSubview(button)
        }
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refresh(_:)))
        refreshButton = refresh; actions.addArrangedSubview(refresh)
        root.addArrangedSubview(actions)
        root.addArrangedSubview(status)
        panel.contentView = root
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([detail.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32), status.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32), scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)])
        self.panel = panel
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in self?.reconcileVisibility() })
        for notification in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if note.name == NSWorkspace.sessionDidResignActiveNotification { self.sessionActive = false }
                if note.name == NSWorkspace.sessionDidBecomeActiveNotification { self.sessionActive = true }
                if note.name == NSWorkspace.screensDidSleepNotification { self.displaysAwake = false }
                if note.name == NSWorkspace.screensDidWakeNotification { self.displaysAwake = true }
                self.reconcileVisibility()
            })
        }
    }
    private func reconcileVisibility() { model?.setVisible(sessionActive && displaysAwake && panel?.isVisible == true && panel?.occlusionState.contains(.visible) == true) }
    private func update() {
        let selected = selectedName
        table.reloadData()
        if let selected, let index = model?.rows.firstIndex(where: { $0.name == selected }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        selectedName = selected
        status.stringValue = model?.message ?? ""
        refreshButton?.isEnabled = model?.isLoading == false
        updateButtons()
    }
    private func updateButtons() {
        guard let model, model.rows.indices.contains(table.selectedRow) else { buttons.values.forEach { $0.isEnabled = false }; return }
        let name = model.rows[table.selectedRow].name
        for (operation, button) in buttons { button.isEnabled = model.canChoose(operation, name: name) }
    }
    @objc private func changeService(_ sender: NSButton) {
        guard let model, model.rows.indices.contains(table.selectedRow), let operation = sender.identifier.flatMap({ ReviewedServicesSurface.Operation(rawValue: $0.rawValue) }) else { return }
        do { try model.choose(operation, name: model.rows[table.selectedRow].name) }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func refresh(_ sender: Any?) { model?.refresh() }
    deinit {
        model?.close()
        for observation in observations { NotificationCenter.default.removeObserver(observation); NSWorkspace.shared.notificationCenter.removeObserver(observation) }
    }
}
